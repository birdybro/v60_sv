/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
// v60_control.sv — Main FSM controller
// Phase 6: Control flow instructions (JMP, JSR, BSR, RET, PREPARE, DISPOSE,
//          PUSH, POP, PUSHM, POPM)

module v60_control
    import v60_pkg::*;
#(
    parameter int ADDR_WIDTH = 24
)(
    input  logic        clk,
    input  logic        rst_n,

    // Decoded instruction from decoder
    input  decoded_inst_t decoded,
    input  logic          decode_valid,

    // Register file
    output logic [4:0]  rf_rd_addr_a,
    output logic [4:0]  rf_rd_addr_b,
    input  logic [31:0] rf_rd_data_a,
    input  logic [31:0] rf_rd_data_b,
    output logic        rf_wr_en,
    output logic [4:0]  rf_wr_addr,
    output logic [31:0] rf_wr_data,

    // PC
    output logic        pc_wr_en,
    output logic [31:0] pc_wr_data,
    input  logic [31:0] pc,

    // PSW
    output logic        psw_wr_en,
    output logic [31:0] psw_wr_data,
    output logic        psw_cc_wr_en,
    output logic [3:0]  psw_cc_wr_data,
    input  logic [31:0] psw,

    // Fetch unit control
    output logic        fetch_flush,
    output logic [31:0] fetch_flush_addr,
    output logic [5:0]  fetch_consume_count,
    output logic        fetch_consume_valid,
    input  logic [4:0]  fetch_ibuf_valid_count,

    // ALU
    output alu_op_t     alu_op,
    output data_size_t  alu_size,
    output logic [31:0] alu_a,
    output logic [31:0] alu_b,
    output logic        alu_carry_in,
    input  logic [31:0] alu_result,
    input  logic        alu_flag_z,
    input  logic        alu_flag_s,
    input  logic        alu_flag_ov,
    input  logic        alu_flag_cy,

    // Branch condition evaluation
    output logic [3:0]  flags_cond,
    input  logic        flags_cond_met,

    // Bus interface (for data access)
    output bus_req_t    data_bus_req,
    output logic [31:0] data_bus_addr,
    output data_size_t  data_bus_size,
    output logic [31:0] data_bus_wdata,
    input  logic [31:0] data_bus_rdata,
    input  logic        data_bus_valid,
    input  logic        data_bus_busy,

    // Interrupt interface
    input  logic        int_pending,
    input  logic [7:0]  int_vector,

    // Status outputs
    output fsm_state_t  state_out,
    output logic         halted
);

    fsm_state_t state, next_state;

    // Latched decoded instruction for multi-cycle execution
    decoded_inst_t inst_r;

    // Temporary registers for memory access
    logic [31:0] temp_addr;
    logic [31:0] temp_data;
    logic        needs_mem_write;  // Track if ST_EXECUTE2 should go to ST_MEM_WRITE
    logic        indirect_active;  // Currently performing pointer dereference
    logic [31:0] temp_src;         // Saved source value during indirect MOV-to-mem

    // Control flow multi-step registers
    logic [2:0]  multi_step;       // Step counter for multi-cycle instructions
    logic [31:0] multi_bitmap;     // PUSHM/POPM register bitmap
    logic [4:0]  multi_reg_idx;    // Current register being pushed/popped
    logic [31:0] return_addr;      // Saved return address for RET

    assign state_out = state;
    assign halted    = (state == ST_HALT);

    // =========================================================================
    // Size in bytes helper (from data_size_t)
    // =========================================================================
    logic [2:0] size_bytes;
    always_comb begin
        case (inst_r.data_size)
            SZ_BYTE: size_bytes = 3'd1;
            SZ_HALF: size_bytes = 3'd2;
            SZ_WORD: size_bytes = 3'd4;
            default: size_bytes = 3'd4;
        endcase
    end

    // =========================================================================
    // Effective address computation (combinational)
    // Uses rf_rd_data_a for the addressing register
    // =========================================================================
    logic [31:0] eff_addr_comb;
    // Which addressing mode are we computing for? Depends on which operand is memory.
    addr_mode_t  mem_am;
    always_comb begin
        if (inst_r.is_mem_src)
            mem_am = inst_r.am_src;
        else
            mem_am = inst_r.am_dst;
    end

    always_comb begin
        case (mem_am)
            AM_REG_INDIRECT:     eff_addr_comb = rf_rd_data_a;
            AM_REG_INDIRECT_INC: eff_addr_comb = rf_rd_data_a;
            AM_REG_INDIRECT_DEC: eff_addr_comb = rf_rd_data_a - {29'h0, size_bytes};
            AM_DISP16_REG:       eff_addr_comb = rf_rd_data_a + inst_r.imm_value;
            AM_DISP32_REG:       eff_addr_comb = rf_rd_data_a + inst_r.imm_value;
            AM_PC_DISP16:        eff_addr_comb = pc + inst_r.imm_value;
            AM_PC_DISP32:        eff_addr_comb = pc + inst_r.imm_value;
            AM_DIRECT_ADDR:      eff_addr_comb = inst_r.imm_value;
            default:             eff_addr_comb = 32'h0;
        endcase
    end

    // =========================================================================
    // PUSHM priority encoder: find highest set bit (for descending push)
    // =========================================================================
    logic [5:0] bitmap_highest;  // 32 = no bits set
    always_comb begin
        bitmap_highest = 6'd32;
        for (int i = 31; i >= 0; i--) begin
            if (multi_bitmap[i] && bitmap_highest == 6'd32)
                bitmap_highest = i[5:0];
        end
    end

    // =========================================================================
    // POPM priority encoder: find lowest set bit (for ascending pop)
    // =========================================================================
    logic [5:0] bitmap_lowest;   // 32 = no bits set
    always_comb begin
        bitmap_lowest = 6'd32;
        for (int i = 0; i < 32; i++) begin
            if (multi_bitmap[i] && bitmap_lowest == 6'd32)
                bitmap_lowest = i[5:0];
        end
    end

    // =========================================================================
    // Control flow operand value (register or immediate, for EXECUTE)
    // =========================================================================
    logic [31:0] cf_operand_val;
    always_comb begin
        case (inst_r.am_dst)
            AM_REGISTER:  cf_operand_val = rf_rd_data_a;
            AM_IMMEDIATE: cf_operand_val = inst_r.imm_value;
            AM_IMM_QUICK: cf_operand_val = inst_r.imm_value;
            default:      cf_operand_val = rf_rd_data_a;
        endcase
    end

    // =========================================================================
    // FSM State Register
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_RESET;
            inst_r          <= '0;
            temp_addr       <= 32'h0;
            temp_data       <= 32'h0;
            needs_mem_write <= 1'b0;
            indirect_active <= 1'b0;
            temp_src        <= 32'h0;
            multi_step      <= 3'd0;
            multi_bitmap    <= 32'h0;
            multi_reg_idx   <= 5'd0;
            return_addr     <= 32'h0;
        end else begin
            state <= next_state;

            // Latch decoded instruction when transitioning from DECODE
            if (state == ST_DECODE && decode_valid) begin
                inst_r <= decoded;
            end

            // ================================================================
            // ST_EXECUTE sequential updates
            // ================================================================
            if (state == ST_EXECUTE) begin
                // --- Standard memory operand handling (Phase 5 logic) ---
                if (inst_r.ctrl_flow == CF_NONE) begin
                    if (inst_r.is_mem_src || inst_r.is_mem_dst) begin
                        temp_addr <= eff_addr_comb;
                        indirect_active <= inst_r.needs_indirect;

                        if (inst_r.is_mem_dst && inst_r.alu_op == ALU_MOV) begin
                            case (inst_r.am_src)
                                AM_REGISTER:  begin temp_data <= rf_rd_data_b; temp_src <= rf_rd_data_b; end
                                AM_IMMEDIATE: begin temp_data <= inst_r.imm_value; temp_src <= inst_r.imm_value; end
                                AM_IMM_QUICK: begin temp_data <= inst_r.imm_value; temp_src <= inst_r.imm_value; end
                                default:      begin temp_data <= rf_rd_data_b; temp_src <= rf_rd_data_b; end
                            endcase
                        end

                        if (inst_r.is_mem_dst && inst_r.alu_op != ALU_MOV && inst_r.alu_op != ALU_CMP)
                            needs_mem_write <= 1'b1;
                        else
                            needs_mem_write <= 1'b0;
                    end

                    if (inst_r.format == FMT_III && inst_r.is_mem_dst) begin
                        temp_addr <= eff_addr_comb;
                        indirect_active <= inst_r.needs_indirect;
                        needs_mem_write <= 1'b1;
                    end
                end

                // --- Control flow instructions ---
                case (inst_r.ctrl_flow)
                    CF_JMP: begin
                        if (inst_r.is_mem_dst && inst_r.needs_indirect) begin
                            // Indirect JMP: need to read pointer first
                            temp_addr <= eff_addr_comb;
                            indirect_active <= 1'b1;
                        end
                        // Non-indirect, non-mem: handled in comb (PC set directly)
                        // Non-indirect mem: eff_addr IS the target (comb sets PC)
                    end

                    CF_JSR: begin
                        if (inst_r.is_mem_dst && inst_r.needs_indirect) begin
                            temp_addr <= eff_addr_comb;
                            indirect_active <= 1'b1;
                            temp_data <= pc + {26'h0, inst_r.inst_len};
                            temp_src  <= rf_rd_data_b - 32'd4; // SP-4 (port_b=SP)
                        end else begin
                            // Direct address modes: eff_addr is target
                            temp_addr <= rf_rd_data_b - 32'd4; // SP-4 for write
                            temp_data <= pc + {26'h0, inst_r.inst_len}; // return addr
                            temp_src  <= eff_addr_comb; // jump target
                        end
                    end

                    CF_BSR: begin
                        temp_addr <= rf_rd_data_b - 32'd4; // SP-4
                        temp_data <= pc + 32'd3; // return addr (PC+3)
                        temp_src  <= pc + inst_r.imm_value; // jump target
                    end

                    CF_RET: begin
                        // Read cleanup operand, then start popping
                        temp_addr <= rf_rd_data_b; // SP (port_b)
                        temp_src  <= cf_operand_val; // cleanup value
                        multi_step <= 3'd2; // 2=pop RA, 1=pop AP, 0=done
                    end

                    CF_PREPARE: begin
                        // Push FP to [SP-4], set FP=SP-4, SP-=4+operand
                        temp_addr <= rf_rd_data_b - 32'd4; // SP-4 (write addr)
                        temp_data <= rf_rd_data_a; // FP value (port_a=FP)
                        temp_src  <= cf_operand_val; // frame size
                        multi_step <= 3'd1; // two-phase writeback
                    end

                    CF_DISPOSE: begin
                        // SP=FP, read [FP] to get old FP
                        temp_addr <= rf_rd_data_a; // FP value (port_a=FP)
                    end

                    CF_PUSH: begin
                        temp_addr <= rf_rd_data_b - 32'd4; // SP-4
                        temp_data <= cf_operand_val; // value to push
                    end

                    CF_POP: begin
                        temp_addr <= rf_rd_data_b; // SP
                    end

                    CF_PUSHM: begin
                        multi_bitmap <= cf_operand_val;
                        temp_addr <= rf_rd_data_b; // SP
                        multi_step <= 3'd1; // signal we're in PUSHM loop
                    end

                    CF_POPM: begin
                        multi_bitmap <= cf_operand_val;
                        temp_addr <= rf_rd_data_b; // SP
                        multi_step <= 3'd0; // 0=find next bit, 1=read done
                    end

                    default: ;
                endcase
            end

            // ================================================================
            // Latch memory read data
            // ================================================================
            if (state == ST_MEM_READ_WAIT && data_bus_valid) begin
                temp_data <= data_bus_rdata;
            end

            // ================================================================
            // ST_EXECUTE2 sequential updates
            // ================================================================
            if (state == ST_EXECUTE2) begin
                if (inst_r.ctrl_flow == CF_NONE) begin
                    // Standard indirect / ALU result handling
                    if (indirect_active) begin
                        temp_addr <= temp_data + inst_r.imm_value2;
                        indirect_active <= 1'b0;
                        if (inst_r.is_mem_dst && inst_r.alu_op == ALU_MOV)
                            temp_data <= temp_src;
                    end else if (needs_mem_write) begin
                        temp_data <= alu_result;
                    end
                end else if (inst_r.ctrl_flow == CF_JMP) begin
                    if (indirect_active) begin
                        // Pointer fetched — jump target is temp_data
                        indirect_active <= 1'b0;
                    end
                    // PC set in combinational logic
                end else if (inst_r.ctrl_flow == CF_JSR) begin
                    if (indirect_active) begin
                        // Pointer fetched — target is temp_data, need to push ret addr
                        indirect_active <= 1'b0;
                        temp_src <= temp_data + inst_r.imm_value2; // actual jump target
                        temp_addr <= rf_rd_data_b - 32'd4; // SP-4
                        temp_data <= pc + {26'h0, inst_r.inst_len}; // return addr
                    end
                end else if (inst_r.ctrl_flow == CF_RET) begin
                    case (multi_step)
                        3'd2: begin
                            return_addr <= temp_data; // save RA
                            temp_addr <= temp_addr + 32'd4; // next stack slot
                            multi_step <= 3'd1;
                        end
                        3'd1: begin
                            // AP = temp_data (written in comb)
                            temp_addr <= temp_addr + 32'd4;
                            multi_step <= 3'd0;
                        end
                        default: ;
                    endcase
                end else if (inst_r.ctrl_flow == CF_DISPOSE) begin
                    // temp_data has old FP (written in comb)
                    // temp_addr already has FP value
                end else if (inst_r.ctrl_flow == CF_POP) begin
                    // temp_data has popped value (written in comb)
                end else if (inst_r.ctrl_flow == CF_PUSHM) begin
                    // Latch which register we're about to push
                    if (bitmap_highest < 6'd32)
                        multi_reg_idx <= bitmap_highest[4:0];
                end else if (inst_r.ctrl_flow == CF_POPM) begin
                    case (multi_step)
                        3'd0: begin
                            // Find next bit — done in comb, set up read
                            if (bitmap_lowest < 6'd32) begin
                                multi_reg_idx <= bitmap_lowest[4:0];
                                multi_step <= 3'd1;
                            end
                        end
                        3'd1: begin
                            // Read done — write register and advance
                            // Register write done in comb
                            multi_bitmap <= multi_bitmap & ~(32'd1 << multi_reg_idx);
                            temp_addr <= temp_addr + 32'd4;
                            multi_step <= 3'd0;
                        end
                        default: ;
                    endcase
                end
            end

            // ================================================================
            // ST_MEM_WRITE_WAIT sequential updates
            // ================================================================
            if (state == ST_MEM_WRITE_WAIT && data_bus_valid) begin
                needs_mem_write <= 1'b0;

                if (inst_r.ctrl_flow == CF_PUSHM) begin
                    // Decrement temp_addr and clear the bit we just pushed
                    temp_addr <= temp_addr - 32'd4;
                    multi_bitmap <= multi_bitmap & ~(32'd1 << multi_reg_idx);
                end
            end

            // ================================================================
            // ST_WRITEBACK sequential updates for multi-step
            // ================================================================
            if (state == ST_WRITEBACK) begin
                if (multi_step > 0 && inst_r.ctrl_flow == CF_PREPARE) begin
                    multi_step <= multi_step - 3'd1;
                end
            end
        end
    end

    // =========================================================================
    // Next State Logic
    // =========================================================================
    always_comb begin
        next_state = state;

        case (state)
            ST_RESET: begin
                next_state = ST_RESET_VEC;
            end

            ST_RESET_VEC: begin
                if (!data_bus_busy)
                    next_state = ST_RESET_VEC_WAIT;
            end

            ST_RESET_VEC_WAIT: begin
                if (data_bus_valid)
                    next_state = ST_FETCH;
            end

            ST_FETCH: begin
                if (fetch_ibuf_valid_count >= 5'd1)
                    next_state = ST_DECODE;
            end

            ST_DECODE: begin
                if (decode_valid) begin
                    if (decoded.is_halt)
                        next_state = ST_HALT;
                    else
                        next_state = ST_EXECUTE;
                end
            end

            ST_EXECUTE: begin
                case (inst_r.ctrl_flow)
                    CF_JMP: begin
                        if (inst_r.is_mem_dst && inst_r.needs_indirect)
                            next_state = ST_MEM_READ; // read pointer
                        else
                            next_state = ST_WRITEBACK; // PC set in comb
                    end

                    CF_JSR: begin
                        if (inst_r.is_mem_dst && inst_r.needs_indirect)
                            next_state = ST_MEM_READ; // read pointer first
                        else
                            next_state = ST_MEM_WRITE; // write return addr
                    end

                    CF_BSR: next_state = ST_MEM_WRITE; // write return addr

                    CF_RET: next_state = ST_MEM_READ; // pop return addr

                    CF_PREPARE: next_state = ST_MEM_WRITE; // push FP

                    CF_DISPOSE: next_state = ST_MEM_READ; // read old FP

                    CF_PUSH: next_state = ST_MEM_WRITE; // push value

                    CF_POP: next_state = ST_MEM_READ; // pop value

                    CF_PUSHM: next_state = ST_EXECUTE2; // start bitmap scan

                    CF_POPM: next_state = ST_EXECUTE2; // start bitmap scan

                    default: begin
                        // Original Phase 5 logic
                        if (inst_r.is_mem_src) begin
                            next_state = ST_MEM_READ;
                        end else if (inst_r.is_mem_dst) begin
                            if (inst_r.alu_op == ALU_MOV && !inst_r.needs_indirect)
                                next_state = ST_MEM_WRITE;
                            else
                                next_state = ST_MEM_READ;
                        end else if (inst_r.format == FMT_III && inst_r.is_mem_dst) begin
                            next_state = ST_MEM_READ;
                        end else begin
                            next_state = ST_WRITEBACK;
                        end
                    end
                endcase
            end

            ST_MEM_READ: begin
                if (!data_bus_busy)
                    next_state = ST_MEM_READ_WAIT;
            end

            ST_MEM_READ_WAIT: begin
                if (data_bus_valid)
                    next_state = ST_EXECUTE2;
            end

            ST_EXECUTE2: begin
                case (inst_r.ctrl_flow)
                    CF_JMP: begin
                        // Pointer fetched (was indirect)
                        next_state = ST_WRITEBACK;
                    end

                    CF_JSR: begin
                        if (indirect_active)
                            next_state = ST_EXECUTE2; // will clear indirect, set up write
                        else
                            next_state = ST_MEM_WRITE; // write return addr
                    end

                    CF_RET: begin
                        case (multi_step)
                            3'd2: next_state = ST_MEM_READ; // pop AP next
                            3'd1: next_state = ST_WRITEBACK; // done
                            default: next_state = ST_WRITEBACK;
                        endcase
                    end

                    CF_DISPOSE: next_state = ST_WRITEBACK;

                    CF_POP: next_state = ST_WRITEBACK;

                    CF_PUSHM: begin
                        // Find highest set bit and push it
                        if (bitmap_highest < 6'd32)
                            next_state = ST_MEM_WRITE; // push this register
                        else
                            next_state = ST_WRITEBACK; // no more bits
                    end

                    CF_POPM: begin
                        case (multi_step)
                            3'd0: begin
                                // Find next bit to pop
                                if (bitmap_lowest < 6'd32)
                                    next_state = ST_MEM_READ; // read this register
                                else
                                    next_state = ST_WRITEBACK; // no more bits
                            end
                            3'd1: begin
                                // Just read a value — go back to scan
                                next_state = ST_EXECUTE2;
                            end
                            default: next_state = ST_WRITEBACK;
                        endcase
                    end

                    default: begin
                        // Standard Phase 5 logic
                        if (indirect_active) begin
                            if (inst_r.is_mem_dst && inst_r.alu_op == ALU_MOV)
                                next_state = ST_MEM_WRITE;
                            else
                                next_state = ST_MEM_READ;
                        end else if (needs_mem_write)
                            next_state = ST_MEM_WRITE;
                        else
                            next_state = ST_WRITEBACK;
                    end
                endcase
            end

            ST_MEM_WRITE: begin
                if (!data_bus_busy)
                    next_state = ST_MEM_WRITE_WAIT;
            end

            ST_MEM_WRITE_WAIT: begin
                if (data_bus_valid) begin
                    case (inst_r.ctrl_flow)
                        CF_PUSHM: next_state = ST_EXECUTE2; // scan for next bit
                        default:  next_state = ST_WRITEBACK;
                    endcase
                end
            end

            ST_WRITEBACK: begin
                if (inst_r.ctrl_flow == CF_PREPARE && multi_step > 3'd0)
                    next_state = ST_WRITEBACK; // loopback for second writeback
                else
                    next_state = ST_FETCH;
            end

            ST_HALT: begin
                if (int_pending)
                    next_state = ST_INT_CHECK;
            end

            ST_INT_CHECK: begin
                next_state = ST_FETCH;
            end

            default: next_state = ST_RESET;
        endcase
    end

    // =========================================================================
    // Datapath Control Outputs
    // =========================================================================
    always_comb begin
        // Defaults — no actions
        rf_wr_en          = 1'b0;
        rf_wr_addr        = 5'd0;
        rf_wr_data        = 32'h0;
        rf_rd_addr_a      = 5'd0;
        rf_rd_addr_b      = 5'd0;
        pc_wr_en          = 1'b0;
        pc_wr_data        = 32'h0;
        psw_wr_en         = 1'b0;
        psw_wr_data       = 32'h0;
        psw_cc_wr_en      = 1'b0;
        psw_cc_wr_data    = 4'h0;
        fetch_flush        = 1'b0;
        fetch_flush_addr   = 32'h0;
        fetch_consume_count = 6'd0;
        fetch_consume_valid = 1'b0;
        alu_op            = ALU_NOP;
        alu_size          = SZ_WORD;
        alu_a             = 32'h0;
        alu_b             = 32'h0;
        alu_carry_in      = 1'b0;
        flags_cond        = 4'h0;
        data_bus_req      = BUS_IDLE;
        data_bus_addr     = 32'h0;
        data_bus_size     = SZ_WORD;
        data_bus_wdata    = 32'h0;

        case (state)
            ST_RESET: begin
                // Nothing
            end

            ST_RESET_VEC: begin
                data_bus_req  = BUS_READ;
                data_bus_addr = RESET_VECTOR_ADDR;
                data_bus_size = SZ_WORD;
            end

            ST_RESET_VEC_WAIT: begin
                if (data_bus_valid) begin
                    pc_wr_en   = 1'b1;
                    pc_wr_data = data_bus_rdata;
                    fetch_flush      = 1'b1;
                    fetch_flush_addr = data_bus_rdata;
                    psw_wr_en   = 1'b1;
                    psw_wr_data = 32'h0;
                    psw_wr_data[PSW_IS] = 1'b1;
                end
            end

            ST_DECODE: begin
                // Let the decoder work
            end

            // =================================================================
            // ST_EXECUTE
            // =================================================================
            ST_EXECUTE: begin
                case (inst_r.ctrl_flow)
                    // =========================================================
                    // Control flow instructions
                    // =========================================================
                    CF_JMP: begin
                        rf_rd_addr_a = inst_r.reg_dst; // addressing register
                        if (!(inst_r.is_mem_dst && inst_r.needs_indirect)) begin
                            // Direct: PC = effective address
                            pc_wr_en         = 1'b1;
                            pc_wr_data       = eff_addr_comb;
                            fetch_flush      = 1'b1;
                            fetch_flush_addr = eff_addr_comb;
                        end
                    end

                    CF_JSR: begin
                        rf_rd_addr_a = inst_r.reg_dst; // addressing register
                        rf_rd_addr_b = 5'd31; // SP
                    end

                    CF_BSR: begin
                        rf_rd_addr_b = 5'd31; // SP
                    end

                    CF_RET: begin
                        rf_rd_addr_a = inst_r.reg_dst; // operand register
                        rf_rd_addr_b = 5'd31; // SP
                    end

                    CF_PREPARE: begin
                        rf_rd_addr_a = 5'd30; // FP
                        rf_rd_addr_b = 5'd31; // SP
                    end

                    CF_DISPOSE: begin
                        rf_rd_addr_a = 5'd30; // FP
                    end

                    CF_PUSH: begin
                        rf_rd_addr_a = inst_r.reg_dst; // operand register
                        rf_rd_addr_b = 5'd31; // SP
                    end

                    CF_POP: begin
                        rf_rd_addr_b = 5'd31; // SP
                    end

                    CF_PUSHM: begin
                        rf_rd_addr_a = inst_r.reg_dst; // operand register (bitmap)
                        rf_rd_addr_b = 5'd31; // SP
                    end

                    CF_POPM: begin
                        rf_rd_addr_a = inst_r.reg_dst; // operand register (bitmap)
                        rf_rd_addr_b = 5'd31; // SP
                    end

                    // =========================================================
                    // Non-control-flow (standard Phase 5 logic)
                    // =========================================================
                    default: begin
                        case (inst_r.format)
                            FMT_V: begin
                                // NOP / DISPOSE — do nothing here for NOP
                            end

                            FMT_IV: begin
                                // Branch instructions
                                flags_cond = inst_r.cond;
                                if (flags_cond_met) begin
                                    pc_wr_en   = 1'b1;
                                    pc_wr_data = pc + inst_r.imm_value;
                                    fetch_flush      = 1'b1;
                                    fetch_flush_addr = pc + inst_r.imm_value;
                                end
                            end

                            FMT_I: begin
                                if (inst_r.is_mem_src || inst_r.is_mem_dst) begin
                                    if (inst_r.is_mem_src)
                                        rf_rd_addr_a = inst_r.reg_src;
                                    else
                                        rf_rd_addr_a = inst_r.reg_dst;

                                    if (inst_r.is_mem_dst)
                                        rf_rd_addr_b = inst_r.reg_src;

                                    if (inst_r.auto_dec) begin
                                        rf_wr_en   = 1'b1;
                                        rf_wr_addr = inst_r.is_mem_src ? inst_r.reg_src : inst_r.reg_dst;
                                        rf_wr_data = eff_addr_comb;
                                    end
                                end else begin
                                    rf_rd_addr_a = inst_r.reg_src;
                                    rf_rd_addr_b = inst_r.reg_dst;

                                    case (inst_r.am_src)
                                        AM_REGISTER:  alu_a = rf_rd_data_a;
                                        AM_IMMEDIATE: alu_a = inst_r.imm_value;
                                        AM_IMM_QUICK: alu_a = inst_r.imm_value;
                                        default:      alu_a = 32'h0;
                                    endcase

                                    alu_b        = rf_rd_data_b;
                                    alu_op       = inst_r.alu_op;
                                    alu_size     = inst_r.data_size;
                                    alu_carry_in = psw[PSW_CY];

                                    if (inst_r.am_dst == AM_REGISTER && inst_r.alu_op != ALU_CMP) begin
                                        rf_wr_en   = 1'b1;
                                        rf_wr_addr = inst_r.reg_dst;
                                        rf_wr_data = alu_result;
                                    end

                                    if (inst_r.writes_flags) begin
                                        psw_cc_wr_en   = 1'b1;
                                        psw_cc_wr_data = {alu_flag_cy, alu_flag_ov, alu_flag_s, alu_flag_z};
                                    end
                                end
                            end

                            FMT_III: begin
                                if (inst_r.is_mem_dst) begin
                                    rf_rd_addr_a = inst_r.reg_dst;
                                    if (inst_r.auto_dec) begin
                                        rf_wr_en   = 1'b1;
                                        rf_wr_addr = inst_r.reg_dst;
                                        rf_wr_data = eff_addr_comb;
                                    end
                                end else begin
                                    if (inst_r.is_getpsw) begin
                                        if (inst_r.am_dst == AM_REGISTER) begin
                                            rf_wr_en   = 1'b1;
                                            rf_wr_addr = inst_r.reg_dst;
                                            rf_wr_data = psw;
                                        end
                                    end else if (inst_r.alu_op == ALU_INC || inst_r.alu_op == ALU_DEC) begin
                                        rf_rd_addr_a = inst_r.reg_dst;
                                        alu_a        = rf_rd_data_a;
                                        alu_op       = inst_r.alu_op;
                                        alu_size     = inst_r.data_size;

                                        if (inst_r.am_dst == AM_REGISTER) begin
                                            rf_wr_en   = 1'b1;
                                            rf_wr_addr = inst_r.reg_dst;
                                            rf_wr_data = alu_result;
                                        end

                                        psw_cc_wr_en   = 1'b1;
                                        psw_cc_wr_data = {alu_flag_cy, alu_flag_ov, alu_flag_s, alu_flag_z};
                                    end
                                end
                            end

                            default: ;
                        endcase
                    end
                endcase
            end

            // =================================================================
            // ST_MEM_READ
            // =================================================================
            ST_MEM_READ: begin
                data_bus_req  = BUS_READ;
                data_bus_addr = temp_addr;
                // Pointer reads (indirect) and control flow stack ops are always 32-bit
                if (indirect_active || inst_r.ctrl_flow != CF_NONE)
                    data_bus_size = SZ_WORD;
                else
                    data_bus_size = inst_r.data_size;
            end

            ST_MEM_READ_WAIT: begin
                // Wait for data_bus_valid; temp_data latched in always_ff
            end

            // =================================================================
            // ST_EXECUTE2
            // =================================================================
            ST_EXECUTE2: begin
                case (inst_r.ctrl_flow)
                    CF_JMP: begin
                        // Indirect JMP: temp_data has the pointer value
                        pc_wr_en         = 1'b1;
                        pc_wr_data       = temp_data + inst_r.imm_value2;
                        fetch_flush      = 1'b1;
                        fetch_flush_addr = temp_data + inst_r.imm_value2;
                    end

                    CF_JSR: begin
                        if (indirect_active) begin
                            // Pointer fetched; set up for write in next cycle
                            rf_rd_addr_b = 5'd31; // SP
                        end
                        // Non-indirect: nothing special here
                    end

                    CF_RET: begin
                        if (multi_step == 3'd1) begin
                            // Write AP
                            rf_wr_en   = 1'b1;
                            rf_wr_addr = 5'd29; // AP
                            rf_wr_data = temp_data;
                        end
                    end

                    CF_DISPOSE: begin
                        // Old FP read; write it
                        rf_wr_en   = 1'b1;
                        rf_wr_addr = 5'd30; // FP
                        rf_wr_data = temp_data;
                    end

                    CF_POP: begin
                        // Write popped value to destination register
                        if (inst_r.am_dst == AM_REGISTER) begin
                            rf_wr_en   = 1'b1;
                            rf_wr_addr = inst_r.reg_dst;
                            rf_wr_data = temp_data;
                        end
                    end

                    CF_PUSHM: begin
                        // Set up read of next register to push
                        if (bitmap_highest < 6'd32) begin
                            rf_rd_addr_a = bitmap_highest[4:0];
                        end
                    end

                    CF_POPM: begin
                        if (multi_step == 3'd1) begin
                            // Just read a value — write to register or PSW
                            if (multi_reg_idx == 5'd31) begin
                                // PSW: write lower 16 bits only
                                psw_wr_en  = 1'b1;
                                psw_wr_data = (psw & 32'hFFFF0000) | (temp_data & 32'h0000FFFF);
                            end else begin
                                rf_wr_en   = 1'b1;
                                rf_wr_addr = multi_reg_idx;
                                rf_wr_data = temp_data;
                            end
                        end
                    end

                    default: begin
                        // Standard Phase 5 logic
                        if (!indirect_active) begin
                            case (inst_r.format)
                                FMT_I: begin
                                    if (inst_r.is_mem_src) begin
                                        alu_a = temp_data;
                                        rf_rd_addr_b = inst_r.reg_dst;
                                        alu_b = rf_rd_data_b;
                                    end else begin
                                        rf_rd_addr_a = inst_r.reg_src;
                                        case (inst_r.am_src)
                                            AM_REGISTER:  alu_a = rf_rd_data_a;
                                            AM_IMMEDIATE: alu_a = inst_r.imm_value;
                                            AM_IMM_QUICK: alu_a = inst_r.imm_value;
                                            default:      alu_a = rf_rd_data_a;
                                        endcase
                                        alu_b = temp_data;
                                    end

                                    alu_op       = inst_r.alu_op;
                                    alu_size     = inst_r.data_size;
                                    alu_carry_in = psw[PSW_CY];

                                    if (inst_r.is_mem_src && inst_r.alu_op != ALU_CMP) begin
                                        rf_wr_en   = 1'b1;
                                        rf_wr_addr = inst_r.reg_dst;
                                        rf_wr_data = alu_result;
                                    end

                                    if (inst_r.writes_flags) begin
                                        psw_cc_wr_en   = 1'b1;
                                        psw_cc_wr_data = {alu_flag_cy, alu_flag_ov, alu_flag_s, alu_flag_z};
                                    end
                                end

                                FMT_III: begin
                                    alu_a    = temp_data;
                                    alu_op   = inst_r.alu_op;
                                    alu_size = inst_r.data_size;

                                    if (inst_r.writes_flags) begin
                                        psw_cc_wr_en   = 1'b1;
                                        psw_cc_wr_data = {alu_flag_cy, alu_flag_ov, alu_flag_s, alu_flag_z};
                                    end
                                end

                                default: ;
                            endcase
                        end
                    end
                endcase
            end

            // =================================================================
            // ST_MEM_WRITE
            // =================================================================
            ST_MEM_WRITE: begin
                data_bus_req   = BUS_WRITE;
                data_bus_addr  = temp_addr;
                data_bus_size  = SZ_WORD;
                data_bus_wdata = temp_data;

                case (inst_r.ctrl_flow)
                    CF_PUSHM: begin
                        // Write current register value to [SP-4]
                        data_bus_addr = temp_addr - 32'd4;
                        rf_rd_addr_a = multi_reg_idx;
                        if (multi_reg_idx == 5'd31) begin
                            data_bus_wdata = psw;
                        end else begin
                            data_bus_wdata = rf_rd_data_a;
                        end
                    end

                    CF_NONE: begin
                        // Standard write uses inst_r.data_size
                        data_bus_size  = inst_r.data_size;
                        data_bus_wdata = temp_data;
                    end

                    default: begin
                        // Control flow writes are always 32-bit
                        data_bus_wdata = temp_data;
                    end
                endcase
            end

            ST_MEM_WRITE_WAIT: begin
                // Wait for data_bus_valid
                if (data_bus_valid && inst_r.ctrl_flow == CF_PUSHM) begin
                    // Update temp_addr for next push
                end
            end

            // =================================================================
            // ST_WRITEBACK
            // =================================================================
            ST_WRITEBACK: begin
                // Default: consume instruction and advance PC
                flags_cond = inst_r.cond;

                case (inst_r.ctrl_flow)
                    CF_JMP: begin
                        // PC already set in EXECUTE or EXECUTE2
                        // Don't consume or advance PC
                    end

                    CF_JSR: begin
                        // SP -= 4, PC = target
                        rf_wr_en   = 1'b1;
                        rf_wr_addr = 5'd31; // SP
                        rf_wr_data = temp_addr; // SP-4 value
                        pc_wr_en         = 1'b1;
                        pc_wr_data       = temp_src; // jump target
                        fetch_flush      = 1'b1;
                        fetch_flush_addr = temp_src;
                    end

                    CF_BSR: begin
                        rf_wr_en   = 1'b1;
                        rf_wr_addr = 5'd31; // SP
                        rf_wr_data = temp_addr; // SP-4 value
                        pc_wr_en         = 1'b1;
                        pc_wr_data       = temp_src; // jump target
                        fetch_flush      = 1'b1;
                        fetch_flush_addr = temp_src;
                    end

                    CF_RET: begin
                        // SP = temp_addr + temp_src (cleanup)
                        rf_wr_en   = 1'b1;
                        rf_wr_addr = 5'd31; // SP
                        rf_wr_data = temp_addr + temp_src;
                        pc_wr_en         = 1'b1;
                        pc_wr_data       = return_addr;
                        fetch_flush      = 1'b1;
                        fetch_flush_addr = return_addr;
                    end

                    CF_PREPARE: begin
                        if (multi_step > 3'd0) begin
                            // First writeback: set FP = temp_addr (SP-4)
                            rf_wr_en   = 1'b1;
                            rf_wr_addr = 5'd30; // FP
                            rf_wr_data = temp_addr;
                        end else begin
                            // Second writeback: set SP = temp_addr - temp_src
                            rf_wr_en   = 1'b1;
                            rf_wr_addr = 5'd31; // SP
                            rf_wr_data = temp_addr - temp_src;
                            fetch_consume_count = inst_r.inst_len;
                            fetch_consume_valid = 1'b1;
                            pc_wr_en   = 1'b1;
                            pc_wr_data = pc + {26'h0, inst_r.inst_len};
                        end
                    end

                    CF_DISPOSE: begin
                        // SP = temp_addr + 4 (FP + 4)
                        rf_wr_en   = 1'b1;
                        rf_wr_addr = 5'd31; // SP
                        rf_wr_data = temp_addr + 32'd4;
                        fetch_consume_count = inst_r.inst_len;
                        fetch_consume_valid = 1'b1;
                        pc_wr_en   = 1'b1;
                        pc_wr_data = pc + {26'h0, inst_r.inst_len};
                    end

                    CF_PUSH: begin
                        // SP = temp_addr (SP-4)
                        rf_wr_en   = 1'b1;
                        rf_wr_addr = 5'd31; // SP
                        rf_wr_data = temp_addr;
                        fetch_consume_count = inst_r.inst_len;
                        fetch_consume_valid = 1'b1;
                        pc_wr_en   = 1'b1;
                        pc_wr_data = pc + {26'h0, inst_r.inst_len};
                    end

                    CF_POP: begin
                        // SP = temp_addr + 4
                        rf_wr_en   = 1'b1;
                        rf_wr_addr = 5'd31; // SP
                        rf_wr_data = temp_addr + 32'd4;
                        fetch_consume_count = inst_r.inst_len;
                        fetch_consume_valid = 1'b1;
                        pc_wr_en   = 1'b1;
                        pc_wr_data = pc + {26'h0, inst_r.inst_len};
                    end

                    CF_PUSHM: begin
                        // SP = temp_addr (decremented during pushes)
                        rf_wr_en   = 1'b1;
                        rf_wr_addr = 5'd31; // SP
                        rf_wr_data = temp_addr;
                        fetch_consume_count = inst_r.inst_len;
                        fetch_consume_valid = 1'b1;
                        pc_wr_en   = 1'b1;
                        pc_wr_data = pc + {26'h0, inst_r.inst_len};
                    end

                    CF_POPM: begin
                        // SP = temp_addr (incremented during pops)
                        rf_wr_en   = 1'b1;
                        rf_wr_addr = 5'd31; // SP
                        rf_wr_data = temp_addr;
                        fetch_consume_count = inst_r.inst_len;
                        fetch_consume_valid = 1'b1;
                        pc_wr_en   = 1'b1;
                        pc_wr_data = pc + {26'h0, inst_r.inst_len};
                    end

                    default: begin
                        // Standard writeback
                        if (!(inst_r.is_branch && flags_cond_met)) begin
                            fetch_consume_count = inst_r.inst_len;
                            fetch_consume_valid = 1'b1;
                            pc_wr_en   = 1'b1;
                            pc_wr_data = pc + {26'h0, inst_r.inst_len};
                        end

                        if (inst_r.auto_inc) begin
                            rf_wr_en   = 1'b1;
                            rf_wr_addr = inst_r.is_mem_src ? inst_r.reg_src : inst_r.reg_dst;
                            rf_wr_data = temp_addr + {29'h0, size_bytes};
                        end
                    end
                endcase
            end

            default: ;
        endcase
    end

endmodule
