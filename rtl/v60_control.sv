/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
// v60_control.sv — Main FSM controller
// Phase 11: Floating point (0x5C, 0x5F) with dual-AM FSM

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
    output data_size_t  rf_wr_size,

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
    output logic [3:0]  alu_flags_in,
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

    // Privileged register interface
    output logic        preg_wr_en,
    output logic [4:0]  preg_addr,
    output logic [31:0] preg_wr_data,
    input  logic [31:0] preg_rd_data,

    // Interrupt interface
    input  logic        int_pending,
    input  logic [7:0]  int_vector,
    input  logic        is_nmi,
    output logic        int_ack,
    input  logic [31:0] current_sp,

    // FPU interface
    output fp_op_t      fpu_op,
    output logic [31:0] fpu_a,
    output logic [31:0] fpu_b,
    output logic [2:0]  fpu_rounding,
    input  logic [31:0] fpu_result,
    input  logic        fpu_flag_z,
    input  logic        fpu_flag_s,
    input  logic        fpu_flag_ov,
    input  logic        fpu_flag_cy,

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

    // FP dual-AM state
    logic [1:0]  fp_phase;         // 0=reading AM1, 1=reading AM2
    logic [31:0] fp_src_val;       // AM1 value (saved across phases)
    logic [31:0] temp_addr2;       // AM2 effective address

    // Interrupt/exception state
    logic [31:0] saved_psw;        // Old PSW during interrupt/exception
    logic [7:0]  saved_vector;     // Vector number for IVT lookup
    logic [31:0] exc_code;         // Exception code word (TRAP/BRKV)
    logic        int_active;       // In interrupt/exception push sequence
    logic [1:0]  int_type;         // 0=none, 1=hw, 2=trap, 3=brkv

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
    // Format II FP operation classification (from latched inst_r)
    // =========================================================================
    logic fmt2_is_cmpf_r;
    logic fmt2_is_mov_like_r;
    logic fmt2_is_rmw_r;
    assign fmt2_is_cmpf_r     = (inst_r.fp_op == FP_CMPF);
    assign fmt2_is_mov_like_r = (inst_r.fp_op == FP_MOVF || inst_r.fp_op == FP_CVTWS || inst_r.fp_op == FP_CVTSW);
    assign fmt2_is_rmw_r      = (inst_r.fp_op == FP_ADDF || inst_r.fp_op == FP_SUBF ||
                                  inst_r.fp_op == FP_MULF || inst_r.fp_op == FP_DIVF ||
                                  inst_r.fp_op == FP_NEGF || inst_r.fp_op == FP_ABSF ||
                                  inst_r.fp_op == FP_SCLF);

    // =========================================================================
    // Format II AM2 effective address (uses rf_rd_data_b for base register)
    // =========================================================================
    logic [31:0] eff_addr_comb2;
    always_comb begin
        case (inst_r.am_dst)
            AM_REG_INDIRECT:     eff_addr_comb2 = rf_rd_data_b;
            AM_REG_INDIRECT_INC: eff_addr_comb2 = rf_rd_data_b;
            AM_REG_INDIRECT_DEC: eff_addr_comb2 = rf_rd_data_b - 32'd4; // always word
            AM_DISP16_REG:       eff_addr_comb2 = rf_rd_data_b + inst_r.imm_value_dst;
            AM_DISP32_REG:       eff_addr_comb2 = rf_rd_data_b + inst_r.imm_value_dst;
            AM_PC_DISP16:        eff_addr_comb2 = pc + inst_r.imm_value_dst;
            AM_PC_DISP32:        eff_addr_comb2 = pc + inst_r.imm_value_dst;
            AM_DIRECT_ADDR:      eff_addr_comb2 = inst_r.imm_value_dst;
            default:             eff_addr_comb2 = 32'h0;
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
    // Exception PSW computation (combinational)
    // =========================================================================
    logic [31:0] exc_new_psw;
    always_comb begin
        exc_new_psw = psw;
        exc_new_psw[25:24] = 2'b00;       // EL = 0
        exc_new_psw[PSW_ID] = 1'b0;       // IE = 0 (disable interrupts)
        exc_new_psw[PSW_NP] = 1'b0;       // bit 16
        exc_new_psw[PSW_TE] = 1'b0;       // bit 17
        exc_new_psw[PSW_TP] = 1'b0;       // bit 27
        exc_new_psw[PSW_EM] = 1'b0;       // bit 29
        exc_new_psw[PSW_ASA] = 1'b1;      // bit 31
    end

    // Exception PSW for hardware interrupt (also sets IS=1)
    logic [31:0] exc_hw_psw;
    always_comb begin
        exc_hw_psw = exc_new_psw;
        exc_hw_psw[PSW_IS] = 1'b1;        // Switch to interrupt stack
    end

    // Push sequence done detection
    logic int_push_done;
    always_comb begin
        case (int_type)
            2'd1:    int_push_done = (multi_step == 3'd1); // HW: 2 pushes
            2'd2:    int_push_done = (multi_step == 3'd2); // TRAP: 3 pushes
            2'd3:    int_push_done = (multi_step == 3'd3); // BRKV: 4 pushes
            default: int_push_done = 1'b1;
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
            saved_psw       <= 32'h0;
            saved_vector    <= 8'h0;
            exc_code        <= 32'h0;
            int_active      <= 1'b0;
            int_type        <= 2'd0;
            fp_phase        <= 2'd0;
            fp_src_val      <= 32'h0;
            temp_addr2      <= 32'h0;
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
                        end else if (inst_r.is_mem_dst && inst_r.alu_op == ALU_RVBIT) begin
                            temp_data <= {24'h0, rf_rd_data_b[0], rf_rd_data_b[1], rf_rd_data_b[2], rf_rd_data_b[3],
                                                 rf_rd_data_b[4], rf_rd_data_b[5], rf_rd_data_b[6], rf_rd_data_b[7]};
                            temp_src  <= rf_rd_data_b;
                        end else if (inst_r.is_mem_dst && inst_r.alu_op == ALU_RVBYT) begin
                            temp_data <= {rf_rd_data_b[7:0], rf_rd_data_b[15:8], rf_rd_data_b[23:16], rf_rd_data_b[31:24]};
                            temp_src  <= rf_rd_data_b;
                        end

                        // Cross-size MOV / sys ops writing to memory: compute result here
                        if (inst_r.is_mem_dst && inst_r.sys_op != SYS_NONE &&
                            inst_r.sys_op != SYS_TASI && inst_r.sys_op != SYS_UPDPSW &&
                            inst_r.sys_op != SYS_LDPR) begin
                            case (inst_r.am_src)
                                AM_REGISTER:  temp_src <= rf_rd_data_b;
                                AM_IMMEDIATE: temp_src <= inst_r.imm_value;
                                AM_IMM_QUICK: temp_src <= inst_r.imm_value;
                                default:      temp_src <= rf_rd_data_b;
                            endcase
                            // Compute the converted value for direct write
                            case (inst_r.sys_op)
                                SYS_MOVSB: begin
                                    case (inst_r.am_src)
                                        AM_REGISTER:  temp_data <= {{24{rf_rd_data_b[7]}}, rf_rd_data_b[7:0]};
                                        AM_IMMEDIATE: temp_data <= {{24{inst_r.imm_value[7]}}, inst_r.imm_value[7:0]};
                                        default:      temp_data <= {{24{rf_rd_data_b[7]}}, rf_rd_data_b[7:0]};
                                    endcase
                                end
                                SYS_MOVZB: begin
                                    case (inst_r.am_src)
                                        AM_REGISTER:  temp_data <= {24'h0, rf_rd_data_b[7:0]};
                                        AM_IMMEDIATE: temp_data <= {24'h0, inst_r.imm_value[7:0]};
                                        default:      temp_data <= {24'h0, rf_rd_data_b[7:0]};
                                    endcase
                                end
                                SYS_MOVSH: begin
                                    case (inst_r.am_src)
                                        AM_REGISTER:  temp_data <= {{16{rf_rd_data_b[15]}}, rf_rd_data_b[15:0]};
                                        AM_IMMEDIATE: temp_data <= {{16{inst_r.imm_value[15]}}, inst_r.imm_value[15:0]};
                                        default:      temp_data <= {{16{rf_rd_data_b[15]}}, rf_rd_data_b[15:0]};
                                    endcase
                                end
                                SYS_MOVZH: begin
                                    case (inst_r.am_src)
                                        AM_REGISTER:  temp_data <= {16'h0, rf_rd_data_b[15:0]};
                                        AM_IMMEDIATE: temp_data <= {16'h0, inst_r.imm_value[15:0]};
                                        default:      temp_data <= {16'h0, rf_rd_data_b[15:0]};
                                    endcase
                                end
                                SYS_MOVT: begin
                                    case (inst_r.am_src)
                                        AM_REGISTER:  temp_data <= rf_rd_data_b;
                                        AM_IMMEDIATE: temp_data <= inst_r.imm_value;
                                        default:      temp_data <= rf_rd_data_b;
                                    endcase
                                    // Truncation happens naturally in write via dst_size
                                end
                                default: begin
                                    case (inst_r.am_src)
                                        AM_REGISTER:  temp_data <= rf_rd_data_b;
                                        AM_IMMEDIATE: temp_data <= inst_r.imm_value;
                                        default:      temp_data <= rf_rd_data_b;
                                    endcase
                                end
                            endcase
                        end

                        if (inst_r.is_mem_dst && inst_r.alu_op != ALU_MOV && inst_r.alu_op != ALU_CMP && inst_r.alu_op != ALU_TEST1
                            && inst_r.sys_op == SYS_NONE)
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

                    CF_RSR: begin
                        temp_addr <= rf_rd_data_b; // SP (port_b=31)
                    end

                    CF_TRAP: begin
                        if (inst_r.is_mem_dst) begin
                            // Memory operand: read first
                            temp_addr <= eff_addr_comb;
                            indirect_active <= inst_r.needs_indirect;
                        end else if (flags_cond_met) begin
                            // Condition met: fire trap
                            saved_psw <= psw;
                            saved_vector <= 8'd48 + {4'h0, cf_operand_val[3:0]};
                            exc_code <= {4'h3, cf_operand_val[3:0], 8'h00, 16'h0004};
                            return_addr <= pc + {26'h0, inst_r.inst_len};
                            int_active <= 1'b1;
                            int_type <= 2'd2;
                            multi_step <= 3'd0;
                        end
                    end

                    CF_BRKV: begin
                        saved_psw <= psw;
                        saved_vector <= 8'd21;
                        exc_code <= 32'h15010004;
                        return_addr <= pc + 32'd1;
                        temp_src <= pc; // Save current PC for BRKV push
                        int_active <= 1'b1;
                        int_type <= 2'd3;
                        multi_step <= 3'd0;
                    end

                    CF_RETIU: begin
                        temp_addr <= rf_rd_data_b; // SP (port_b=31)
                        temp_src  <= cf_operand_val; // frame size
                        multi_step <= 3'd0;
                    end

                    default: ;
                endcase

                // --- Format II FP dual-AM handling ---
                if (inst_r.format == FMT_II && inst_r.fp_op != FP_NONE) begin
                    fp_phase <= 2'd0;
                    temp_addr2 <= eff_addr_comb2;
                    needs_mem_write <= 1'b0;
                    indirect_active <= 1'b0;

                    // Grab AM1 value if it's register or immediate
                    if (!inst_r.is_mem_src) begin
                        case (inst_r.am_src)
                            AM_REGISTER:  fp_src_val <= rf_rd_data_a;
                            AM_IMMEDIATE: fp_src_val <= inst_r.imm_value;
                            AM_IMM_QUICK: fp_src_val <= inst_r.imm_value;
                            default:      fp_src_val <= rf_rd_data_a;
                        endcase
                    end

                    // Compute temp_addr for AM1 read if needed
                    if (inst_r.is_mem_src) begin
                        temp_addr <= eff_addr_comb;
                    end

                    // Auto-decrement AM2 base register
                    // (handled in writeback via auto_dec2)
                end
            end

            // ================================================================
            // Latch memory read data
            // ================================================================
            if (state == ST_MEM_READ_WAIT && data_bus_valid) begin
                temp_data <= data_bus_rdata;
                // Vector fetch complete — clear int_active
                if (int_active) begin
                    int_active <= 1'b0;
                end
            end

            // ================================================================
            // ST_INT_CHECK sequential (hardware interrupt entry)
            // ================================================================
            if (state == ST_INT_CHECK) begin
                saved_psw    <= psw;
                saved_vector <= int_vector;
                return_addr  <= pc;
                int_active   <= 1'b1;
                int_type     <= 2'd1; // HW interrupt
                multi_step   <= 3'd0;
            end

            // ================================================================
            // ST_INT_ACK sequential (set up first push)
            // ================================================================
            if (state == ST_INT_ACK) begin
                temp_addr <= current_sp - 32'd4; // First push addr = new SP - 4
                case (int_type)
                    2'd1: temp_data <= saved_psw;    // HW: push saved_psw first
                    2'd2: temp_data <= exc_code;     // TRAP: push exc_code first
                    2'd3: temp_data <= temp_src;     // BRKV: push PC first
                    default: temp_data <= 32'h0;
                endcase
            end

            // ================================================================
            // ST_MEM_WRITE_WAIT sequential (int_active push chain)
            // ================================================================
            if (state == ST_MEM_WRITE_WAIT && data_bus_valid && int_active) begin
                if (int_push_done) begin
                    // All pushes complete — set up vector read
                    temp_src <= temp_addr; // Save final SP
                    // Vector address computed in combinational via preg_addr/preg_rd_data
                    temp_addr <= (preg_rd_data & 32'hFFFFF000) + {22'h0, saved_vector, 2'b00};
                end else begin
                    // Next push
                    multi_step <= multi_step + 3'd1;
                    temp_addr <= temp_addr - 32'd4;
                    case (int_type)
                        2'd1: begin // HW: step 0→1
                            temp_data <= return_addr; // Push PC
                        end
                        2'd2: begin // TRAP
                            case (multi_step)
                                3'd0: temp_data <= saved_psw;    // step 0→1
                                3'd1: temp_data <= return_addr;  // step 1→2
                                default: ;
                            endcase
                        end
                        2'd3: begin // BRKV
                            case (multi_step)
                                3'd0: temp_data <= exc_code;     // step 0→1
                                3'd1: temp_data <= saved_psw;    // step 1→2
                                3'd2: temp_data <= return_addr;  // step 2→3
                                default: ;
                            endcase
                        end
                        default: ;
                    endcase
                end
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
                        if (inst_r.sys_op == SYS_TASI)
                            temp_data <= 32'h000000FF;
                        else
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
                end else if (inst_r.ctrl_flow == CF_RSR) begin
                    // RSR: temp_data has return address
                    return_addr <= temp_data;
                end else if (inst_r.ctrl_flow == CF_TRAP) begin
                    if (indirect_active) begin
                        // Indirect resolution
                        temp_addr <= temp_data + inst_r.imm_value2;
                        indirect_active <= 1'b0;
                    end else begin
                        // temp_data has operand byte — evaluate condition
                        if (flags_cond_met) begin
                            saved_psw <= psw;
                            saved_vector <= 8'd48 + {4'h0, temp_data[3:0]};
                            exc_code <= {4'h3, temp_data[3:0], 8'h00, 16'h0004};
                            return_addr <= pc + {26'h0, inst_r.inst_len};
                            int_active <= 1'b1;
                            int_type <= 2'd2;
                            multi_step <= 3'd0;
                        end
                    end
                end else if (inst_r.ctrl_flow == CF_RETIU) begin
                    case (multi_step)
                        3'd0: begin
                            // Popped PC
                            return_addr <= temp_data;
                            temp_addr <= temp_addr + 32'd4;
                            multi_step <= 3'd1;
                        end
                        3'd1: begin
                            // Popped PSW
                            saved_psw <= temp_data;
                        end
                        default: ;
                    endcase
                end

                // --- Format II FP EXECUTE2 sequential ---
                if (inst_r.format == FMT_II && inst_r.fp_op != FP_NONE) begin
                    if (fp_phase == 2'd0) begin
                        // AM1 data ready in temp_data
                        fp_src_val <= temp_data;
                        fp_phase <= 2'd1;

                        // If R-M-W or CMPF with mem AM2: set up read of AM2
                        if (inst_r.is_mem_dst) begin
                            temp_addr <= temp_addr2;
                        end

                        // For MOV-like to mem: compute result immediately
                        // (fpu_result available combinationally in comb block)
                    end else if (fp_phase == 2'd1) begin
                        // AM2 data ready in temp_data (for R-M-W / CMPF)
                        // FPU result computed combinationally
                        // For R-M-W mem write: set up write
                        if (inst_r.is_mem_dst) begin
                            temp_data <= fpu_result;
                            temp_addr <= temp_addr2;
                        end
                    end
                end
            end

            // ================================================================
            // ST_MEM_WRITE_WAIT sequential updates (non-interrupt)
            // ================================================================
            if (state == ST_MEM_WRITE_WAIT && data_bus_valid && !int_active) begin
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

                    CF_RSR: next_state = ST_MEM_READ; // pop return addr

                    CF_TRAP: begin
                        if (inst_r.is_mem_dst)
                            next_state = ST_MEM_READ; // read operand
                        else if (flags_cond_met)
                            next_state = ST_INT_ACK;  // fire trap
                        else
                            next_state = ST_WRITEBACK; // condition not met
                    end

                    CF_BRKV: next_state = ST_INT_ACK; // always fire

                    CF_RETIU: next_state = ST_MEM_READ; // pop PC

                    CF_DBCC: next_state = ST_WRITEBACK; // no memory access

                    default: begin
                        // Format II FP: dual-AM next state
                        if (inst_r.format == FMT_II && inst_r.fp_op != FP_NONE) begin
                            if (inst_r.is_mem_src)
                                // Need to read AM1 from memory first
                                next_state = ST_MEM_READ;
                            else if (inst_r.is_mem_dst && (fmt2_is_rmw_r || fmt2_is_cmpf_r))
                                // AM1 is reg/imm, need to read AM2 from memory
                                next_state = ST_MEM_READ;
                            else if (inst_r.is_mem_dst && fmt2_is_mov_like_r)
                                // MOV-like to memory: write FPU result directly
                                next_state = ST_MEM_WRITE;
                            else
                                // Both register/immediate: straight to writeback
                                next_state = ST_WRITEBACK;
                        end
                        // MOVEA with non-indirect memory source: address is already computed
                        else if (inst_r.sys_op == SYS_MOVEA && inst_r.is_mem_src && !inst_r.needs_indirect)
                            next_state = ST_WRITEBACK;
                        // TASI Format III: register path goes straight to writeback
                        else if (inst_r.sys_op == SYS_TASI && !inst_r.is_mem_dst)
                            next_state = ST_WRITEBACK;
                        // TASI Format III with memory: need to read byte first
                        else if (inst_r.sys_op == SYS_TASI && inst_r.is_mem_dst)
                            next_state = ST_MEM_READ;
                        // Original Phase 5 logic
                        else if (inst_r.is_mem_src) begin
                            next_state = ST_MEM_READ;
                        end else if (inst_r.is_mem_dst) begin
                            // Cross-size MOV/RVBIT/RVBYT to mem: direct write (like MOV)
                            if ((inst_r.alu_op == ALU_MOV || inst_r.alu_op == ALU_RVBIT || inst_r.alu_op == ALU_RVBYT ||
                                 inst_r.sys_op != SYS_NONE) && !inst_r.needs_indirect)
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
                if (data_bus_valid) begin
                    if (int_active)
                        next_state = ST_FETCH; // vector fetched
                    else
                        next_state = ST_EXECUTE2;
                end
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

                    CF_RSR: next_state = ST_WRITEBACK;

                    CF_TRAP: begin
                        if (indirect_active)
                            next_state = ST_MEM_READ; // continue indirect
                        else if (flags_cond_met)
                            next_state = ST_INT_ACK;  // fire trap
                        else
                            next_state = ST_WRITEBACK; // condition not met
                    end

                    CF_RETIU: begin
                        case (multi_step)
                            3'd0: next_state = ST_MEM_READ;  // pop PSW
                            3'd1: next_state = ST_WRITEBACK;  // done
                            default: next_state = ST_WRITEBACK;
                        endcase
                    end

                    default: begin
                        // Format II FP: dual-AM next state in EXECUTE2
                        if (inst_r.format == FMT_II && inst_r.fp_op != FP_NONE) begin
                            if (fp_phase == 2'd0) begin
                                // AM1 data just arrived
                                if (inst_r.is_mem_dst && (fmt2_is_rmw_r || fmt2_is_cmpf_r))
                                    next_state = ST_MEM_READ; // read AM2
                                else if (inst_r.is_mem_dst && fmt2_is_mov_like_r)
                                    next_state = ST_MEM_WRITE; // write result to AM2
                                else
                                    next_state = ST_WRITEBACK; // AM2 is register
                            end else begin
                                // fp_phase==1: AM2 data arrived
                                if (inst_r.is_mem_dst && !fmt2_is_cmpf_r)
                                    next_state = ST_MEM_WRITE; // write R-M-W result
                                else
                                    next_state = ST_WRITEBACK; // CMPF or register dest
                            end
                        end
                        // Standard Phase 5 logic
                        else if (indirect_active) begin
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
                    if (int_active) begin
                        if (int_push_done)
                            next_state = ST_MEM_READ;  // read vector
                        else
                            next_state = ST_MEM_WRITE;  // next push
                    end else begin
                        case (inst_r.ctrl_flow)
                            CF_PUSHM: next_state = ST_EXECUTE2; // scan for next bit
                            default:  next_state = ST_WRITEBACK;
                        endcase
                    end
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
                next_state = ST_INT_ACK;
            end

            ST_INT_ACK: begin
                next_state = ST_MEM_WRITE; // start push sequence
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
        rf_wr_size        = SZ_WORD;
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
        alu_flags_in      = 4'h0;
        flags_cond        = 4'h0;
        data_bus_req      = BUS_IDLE;
        data_bus_addr     = 32'h0;
        data_bus_size     = SZ_WORD;
        data_bus_wdata    = 32'h0;
        preg_wr_en        = 1'b0;
        preg_addr         = 5'd0;
        preg_wr_data      = 32'h0;
        int_ack           = 1'b0;
        fpu_op            = FP_NONE;
        fpu_a             = 32'h0;
        fpu_b             = 32'h0;
        fpu_rounding      = 3'd0;

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

                    CF_RSR: begin
                        rf_rd_addr_b = 5'd31; // SP
                    end

                    CF_TRAP: begin
                        rf_rd_addr_a = inst_r.reg_dst; // operand register or addr register
                        if (!inst_r.is_mem_dst) begin
                            // Evaluate condition from operand byte
                            case (inst_r.am_dst)
                                AM_REGISTER:  flags_cond = rf_rd_data_a[7:4];
                                AM_IMMEDIATE: flags_cond = inst_r.imm_value[7:4];
                                AM_IMM_QUICK: flags_cond = inst_r.imm_value[7:4];
                                default:      flags_cond = rf_rd_data_a[7:4];
                            endcase
                            if (flags_cond_met) begin
                                psw_wr_en   = 1'b1;
                                psw_wr_data = exc_new_psw;
                            end
                        end
                    end

                    CF_BRKV: begin
                        psw_wr_en   = 1'b1;
                        psw_wr_data = exc_new_psw;
                    end

                    CF_RETIU: begin
                        rf_rd_addr_a = inst_r.reg_dst; // operand register
                        rf_rd_addr_b = 5'd31; // SP
                    end

                    CF_DBCC: begin
                        rf_rd_addr_a = inst_r.reg_dst; // counter register
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

                                    // MOVEA non-indirect mem source: address is the result
                                    if (inst_r.sys_op == SYS_MOVEA && inst_r.is_mem_src && !inst_r.needs_indirect) begin
                                        rf_wr_en   = 1'b1;
                                        rf_wr_addr = inst_r.reg_dst;
                                        rf_wr_data = eff_addr_comb;
                                    end
                                end else if (inst_r.sys_op != SYS_NONE) begin
                                    // Phase 8: sys_op register-register dispatch
                                    rf_rd_addr_a = inst_r.reg_src;
                                    rf_rd_addr_b = inst_r.reg_dst;
                                    rf_wr_size   = inst_r.dst_size;

                                    case (inst_r.sys_op)
                                        SYS_MOVSB: begin
                                            // Sign-extend byte
                                            case (inst_r.am_src)
                                                AM_REGISTER:  rf_wr_data = {{24{rf_rd_data_a[7]}}, rf_rd_data_a[7:0]};
                                                AM_IMMEDIATE: rf_wr_data = {{24{inst_r.imm_value[7]}}, inst_r.imm_value[7:0]};
                                                AM_IMM_QUICK: rf_wr_data = {{24{inst_r.imm_value[7]}}, inst_r.imm_value[7:0]};
                                                default:      rf_wr_data = {{24{rf_rd_data_a[7]}}, rf_rd_data_a[7:0]};
                                            endcase
                                            rf_wr_en   = 1'b1;
                                            rf_wr_addr = inst_r.reg_dst;
                                        end
                                        SYS_MOVZB: begin
                                            // Zero-extend byte
                                            case (inst_r.am_src)
                                                AM_REGISTER:  rf_wr_data = {24'h0, rf_rd_data_a[7:0]};
                                                AM_IMMEDIATE: rf_wr_data = {24'h0, inst_r.imm_value[7:0]};
                                                AM_IMM_QUICK: rf_wr_data = {24'h0, inst_r.imm_value[7:0]};
                                                default:      rf_wr_data = {24'h0, rf_rd_data_a[7:0]};
                                            endcase
                                            rf_wr_en   = 1'b1;
                                            rf_wr_addr = inst_r.reg_dst;
                                        end
                                        SYS_MOVSH: begin
                                            // Sign-extend half
                                            case (inst_r.am_src)
                                                AM_REGISTER:  rf_wr_data = {{16{rf_rd_data_a[15]}}, rf_rd_data_a[15:0]};
                                                AM_IMMEDIATE: rf_wr_data = {{16{inst_r.imm_value[15]}}, inst_r.imm_value[15:0]};
                                                default:      rf_wr_data = {{16{rf_rd_data_a[15]}}, rf_rd_data_a[15:0]};
                                            endcase
                                            rf_wr_en   = 1'b1;
                                            rf_wr_addr = inst_r.reg_dst;
                                        end
                                        SYS_MOVZH: begin
                                            // Zero-extend half
                                            case (inst_r.am_src)
                                                AM_REGISTER:  rf_wr_data = {16'h0, rf_rd_data_a[15:0]};
                                                AM_IMMEDIATE: rf_wr_data = {16'h0, inst_r.imm_value[15:0]};
                                                default:      rf_wr_data = {16'h0, rf_rd_data_a[15:0]};
                                            endcase
                                            rf_wr_en   = 1'b1;
                                            rf_wr_addr = inst_r.reg_dst;
                                        end
                                        SYS_MOVT: begin
                                            // Truncate with OV detection
                                            case (inst_r.am_src)
                                                AM_REGISTER:  alu_a = rf_rd_data_a;
                                                AM_IMMEDIATE: alu_a = inst_r.imm_value;
                                                default:      alu_a = rf_rd_data_a;
                                            endcase
                                            // Compute truncated result and OV
                                            if (inst_r.dst_size == SZ_BYTE) begin
                                                rf_wr_data = {24'h0, alu_a[7:0]};
                                                // OV=1 if high bits don't match sign extension
                                                if (inst_r.data_size == SZ_HALF) // MOVTHB
                                                    psw_cc_wr_data[2] = (alu_a[7] ? (alu_a[15:8] != 8'hFF) : (alu_a[15:8] != 8'h00));
                                                else // MOVTWB
                                                    psw_cc_wr_data[2] = (alu_a[7] ? (alu_a[31:8] != 24'hFFFFFF) : (alu_a[31:8] != 24'h000000));
                                            end else begin // SZ_HALF (MOVTWH)
                                                rf_wr_data = {16'h0, alu_a[15:0]};
                                                psw_cc_wr_data[2] = (alu_a[15] ? (alu_a[31:16] != 16'hFFFF) : (alu_a[31:16] != 16'h0000));
                                            end
                                            // Preserve Z, S, CY from current PSW
                                            psw_cc_wr_data[0] = psw[PSW_Z];
                                            psw_cc_wr_data[1] = psw[PSW_S];
                                            psw_cc_wr_data[3] = psw[PSW_CY];
                                            psw_cc_wr_en = 1'b1;
                                            rf_wr_en   = 1'b1;
                                            rf_wr_addr = inst_r.reg_dst;
                                        end
                                        SYS_MOVEA: begin
                                            // Register source: return register index, not value
                                            rf_wr_en   = 1'b1;
                                            rf_wr_addr = inst_r.reg_dst;
                                            case (inst_r.am_src)
                                                AM_REGISTER:  rf_wr_data = {27'h0, inst_r.reg_src};
                                                AM_IMMEDIATE: rf_wr_data = inst_r.imm_value;
                                                AM_IMM_QUICK: rf_wr_data = inst_r.imm_value;
                                                default:      rf_wr_data = {27'h0, inst_r.reg_src};
                                            endcase
                                        end
                                        SYS_SETF: begin
                                            // Source byte gives condition code 0-15
                                            case (inst_r.am_src)
                                                AM_REGISTER:  flags_cond = rf_rd_data_a[3:0];
                                                AM_IMMEDIATE: flags_cond = inst_r.imm_value[3:0];
                                                AM_IMM_QUICK: flags_cond = inst_r.imm_value[3:0];
                                                default:      flags_cond = rf_rd_data_a[3:0];
                                            endcase
                                            rf_wr_en   = 1'b1;
                                            rf_wr_addr = inst_r.reg_dst;
                                            rf_wr_data = {31'h0, flags_cond_met};
                                        end
                                        SYS_UPDPSW: begin
                                            // op1=value (src), op2=mask (dst reg)
                                            case (inst_r.am_src)
                                                AM_REGISTER:  alu_a = rf_rd_data_a;
                                                AM_IMMEDIATE: alu_a = inst_r.imm_value;
                                                AM_IMM_QUICK: alu_a = inst_r.imm_value;
                                                default:      alu_a = rf_rd_data_a;
                                            endcase
                                            alu_b = rf_rd_data_b; // mask
                                            // Apply mask limit based on dst_size
                                            if (inst_r.dst_size == SZ_HALF)
                                                psw_wr_data = (psw & ~(rf_rd_data_b & 32'h0000FFFF)) | (alu_a & (rf_rd_data_b & 32'h0000FFFF));
                                            else
                                                psw_wr_data = (psw & ~(rf_rd_data_b & 32'h00FFFFFF)) | (alu_a & (rf_rd_data_b & 32'h00FFFFFF));
                                            psw_wr_en = 1'b1;
                                        end
                                        SYS_LDPR: begin
                                            // op1=value (from src), op2=preg index (from dst reg)
                                            case (inst_r.am_src)
                                                AM_REGISTER:  preg_wr_data = rf_rd_data_a;
                                                AM_IMMEDIATE: preg_wr_data = inst_r.imm_value;
                                                AM_IMM_QUICK: preg_wr_data = inst_r.imm_value;
                                                default:      preg_wr_data = rf_rd_data_a;
                                            endcase
                                            preg_addr  = rf_rd_data_b[4:0];
                                            preg_wr_en = 1'b1;
                                        end
                                        SYS_STPR: begin
                                            // op1=preg index (from src), op2=dest register
                                            case (inst_r.am_src)
                                                AM_REGISTER:  preg_addr = rf_rd_data_a[4:0];
                                                AM_IMMEDIATE: preg_addr = inst_r.imm_value[4:0];
                                                AM_IMM_QUICK: preg_addr = inst_r.imm_value[4:0];
                                                default:      preg_addr = rf_rd_data_a[4:0];
                                            endcase
                                            rf_wr_en   = 1'b1;
                                            rf_wr_addr = inst_r.reg_dst;
                                            rf_wr_data = preg_rd_data;
                                        end
                                        default: ;
                                    endcase
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
                                    alu_flags_in = psw[3:0];

                                    if (inst_r.am_dst == AM_REGISTER && inst_r.alu_op != ALU_CMP && inst_r.alu_op != ALU_TEST1) begin
                                        rf_wr_en   = 1'b1;
                                        rf_wr_addr = inst_r.reg_dst;
                                        rf_wr_data = alu_result;
                                        rf_wr_size = inst_r.data_size;
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
                                    end else if (inst_r.sys_op == SYS_TASI) begin
                                        // TASI register: SUB(val, 0xFF) for flags, write 0xFF back
                                        rf_rd_addr_a = inst_r.reg_dst;
                                        alu_a        = 32'h000000FF;
                                        alu_b        = {24'h0, rf_rd_data_a[7:0]};
                                        alu_op       = ALU_SUB;
                                        alu_size     = SZ_BYTE;
                                        alu_flags_in = psw[3:0];
                                        psw_cc_wr_en   = 1'b1;
                                        psw_cc_wr_data = {alu_flag_cy, alu_flag_ov, alu_flag_s, alu_flag_z};
                                        rf_wr_en   = 1'b1;
                                        rf_wr_addr = inst_r.reg_dst;
                                        rf_wr_data = 32'h000000FF;
                                        rf_wr_size = SZ_BYTE;
                                    end else if (inst_r.alu_op == ALU_INC || inst_r.alu_op == ALU_DEC) begin
                                        rf_rd_addr_a = inst_r.reg_dst;
                                        alu_a        = rf_rd_data_a;
                                        alu_op       = inst_r.alu_op;
                                        alu_size     = inst_r.data_size;
                                        alu_flags_in = psw[3:0];

                                        if (inst_r.am_dst == AM_REGISTER) begin
                                            rf_wr_en   = 1'b1;
                                            rf_wr_addr = inst_r.reg_dst;
                                            rf_wr_data = alu_result;
                                            rf_wr_size = inst_r.data_size;
                                        end

                                        psw_cc_wr_en   = 1'b1;
                                        psw_cc_wr_data = {alu_flag_cy, alu_flag_ov, alu_flag_s, alu_flag_z};
                                    end
                                end
                            end

                            FMT_II: begin
                                // FP dual-AM: set up register reads for both AMs
                                rf_rd_addr_a = inst_r.reg_src; // AM1 base register
                                rf_rd_addr_b = inst_r.reg_dst; // AM2 base register

                                // AM2 auto-decrement: write back decremented register now
                                if (inst_r.auto_dec2) begin
                                    rf_wr_en   = 1'b1;
                                    rf_wr_addr = inst_r.reg_dst;
                                    rf_wr_data = eff_addr_comb2;
                                end
                                // AM1 auto-decrement
                                if (inst_r.auto_dec) begin
                                    rf_wr_en   = 1'b1;
                                    rf_wr_addr = inst_r.reg_src;
                                    rf_wr_data = eff_addr_comb;
                                end

                                // For !is_mem_src && !is_mem_dst: compute in comb and write
                                if (!inst_r.is_mem_src && !inst_r.is_mem_dst) begin
                                    // Both operands are register/immediate
                                    fpu_op = inst_r.fp_op;
                                    case (inst_r.am_src)
                                        AM_REGISTER:  fpu_a = rf_rd_data_a;
                                        AM_IMMEDIATE: fpu_a = inst_r.imm_value;
                                        AM_IMM_QUICK: fpu_a = inst_r.imm_value;
                                        default:      fpu_a = rf_rd_data_a;
                                    endcase
                                    fpu_b = rf_rd_data_b; // AM2 register value (for R-M-W/CMPF)

                                    // Write result to AM2 register (except CMPF)
                                    if (!fmt2_is_cmpf_r) begin
                                        rf_wr_en   = 1'b1;
                                        rf_wr_addr = inst_r.reg_dst;
                                        rf_wr_data = fpu_result;
                                    end

                                    // Update flags
                                    if (inst_r.writes_flags) begin
                                        psw_cc_wr_en   = 1'b1;
                                        psw_cc_wr_data = {fpu_flag_cy, fpu_flag_ov, fpu_flag_s, fpu_flag_z};
                                    end
                                end

                                // For !is_mem_src && is_mem_dst && mov_like: compute FPU for mem write
                                if (!inst_r.is_mem_src && inst_r.is_mem_dst && fmt2_is_mov_like_r) begin
                                    fpu_op = inst_r.fp_op;
                                    case (inst_r.am_src)
                                        AM_REGISTER:  fpu_a = rf_rd_data_a;
                                        AM_IMMEDIATE: fpu_a = inst_r.imm_value;
                                        AM_IMM_QUICK: fpu_a = inst_r.imm_value;
                                        default:      fpu_a = rf_rd_data_a;
                                    endcase
                                    fpu_b = 32'h0;
                                end

                                // For !is_mem_src && is_mem_dst && (rmw/cmpf):
                                // Need to read AM2 mem first — set temp_addr in sequential
                            end

                            default: ;
                        endcase
                    end
                endcase
            end

            // =================================================================
            // ST_INT_CHECK — Hardware interrupt entry
            // =================================================================
            ST_INT_CHECK: begin
                // Write exception PSW (IS=1 for hardware)
                psw_wr_en   = 1'b1;
                psw_wr_data = exc_hw_psw;
                int_ack     = 1'b1;
            end

            // =================================================================
            // ST_INT_ACK — Read new SP, set up first push
            // =================================================================
            ST_INT_ACK: begin
                // current_sp is from regfile, already reflects new PSW
                // (sequential block will set temp_addr = current_sp - 4)
            end

            // =================================================================
            // ST_MEM_READ
            // =================================================================
            ST_MEM_READ: begin
                data_bus_req  = BUS_READ;
                data_bus_addr = temp_addr;
                // Pointer reads, control flow, and interrupt vector reads are always 32-bit
                if (indirect_active || inst_r.ctrl_flow != CF_NONE || int_active)
                    data_bus_size = SZ_WORD;
                // FP: SCLF AM1 is half, everything else word
                else if (inst_r.format == FMT_II && inst_r.fp_op != FP_NONE) begin
                    if (inst_r.fp_op == FP_SCLF && fp_phase == 2'd0)
                        data_bus_size = SZ_HALF;
                    else
                        data_bus_size = SZ_WORD;
                end
                // Shift/rotate source (count) is always byte when reading source from memory
                else if (inst_r.src_is_byte && inst_r.is_mem_src)
                    data_bus_size = SZ_BYTE;
                else
                    data_bus_size = inst_r.data_size;
            end

            ST_MEM_READ_WAIT: begin
                // Wait for data_bus_valid; temp_data latched in always_ff
                if (data_bus_valid && int_active) begin
                    // Vector fetched — jump to vector, write final SP
                    pc_wr_en         = 1'b1;
                    pc_wr_data       = data_bus_rdata;
                    fetch_flush      = 1'b1;
                    fetch_flush_addr = data_bus_rdata;
                    rf_wr_en         = 1'b1;
                    rf_wr_addr       = 5'd31; // SP
                    rf_wr_data       = temp_src; // saved final SP
                end
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

                    CF_TRAP: begin
                        // Memory operand: evaluate condition from temp_data
                        if (!indirect_active) begin
                            flags_cond = temp_data[7:4];
                            if (flags_cond_met) begin
                                psw_wr_en   = 1'b1;
                                psw_wr_data = exc_new_psw;
                            end
                        end
                    end

                    default: begin
                        // Standard Phase 5 logic
                        if (!indirect_active) begin
                            case (inst_r.format)
                                FMT_I: begin
                                    if (inst_r.sys_op != SYS_NONE && inst_r.is_mem_src) begin
                                        // Phase 8: sys ops after memory read
                                        rf_wr_size = inst_r.dst_size;
                                        case (inst_r.sys_op)
                                            SYS_MOVSB: begin
                                                rf_wr_en   = 1'b1;
                                                rf_wr_addr = inst_r.reg_dst;
                                                rf_wr_data = {{24{temp_data[7]}}, temp_data[7:0]};
                                            end
                                            SYS_MOVZB: begin
                                                rf_wr_en   = 1'b1;
                                                rf_wr_addr = inst_r.reg_dst;
                                                rf_wr_data = {24'h0, temp_data[7:0]};
                                            end
                                            SYS_MOVSH: begin
                                                rf_wr_en   = 1'b1;
                                                rf_wr_addr = inst_r.reg_dst;
                                                rf_wr_data = {{16{temp_data[15]}}, temp_data[15:0]};
                                            end
                                            SYS_MOVZH: begin
                                                rf_wr_en   = 1'b1;
                                                rf_wr_addr = inst_r.reg_dst;
                                                rf_wr_data = {16'h0, temp_data[15:0]};
                                            end
                                            SYS_MOVT: begin
                                                rf_wr_en   = 1'b1;
                                                rf_wr_addr = inst_r.reg_dst;
                                                if (inst_r.dst_size == SZ_BYTE) begin
                                                    rf_wr_data = {24'h0, temp_data[7:0]};
                                                    if (inst_r.data_size == SZ_HALF)
                                                        psw_cc_wr_data[2] = (temp_data[7] ? (temp_data[15:8] != 8'hFF) : (temp_data[15:8] != 8'h00));
                                                    else
                                                        psw_cc_wr_data[2] = (temp_data[7] ? (temp_data[31:8] != 24'hFFFFFF) : (temp_data[31:8] != 24'h000000));
                                                end else begin
                                                    rf_wr_data = {16'h0, temp_data[15:0]};
                                                    psw_cc_wr_data[2] = (temp_data[15] ? (temp_data[31:16] != 16'hFFFF) : (temp_data[31:16] != 16'h0000));
                                                end
                                                psw_cc_wr_data[0] = psw[PSW_Z];
                                                psw_cc_wr_data[1] = psw[PSW_S];
                                                psw_cc_wr_data[3] = psw[PSW_CY];
                                                psw_cc_wr_en = 1'b1;
                                            end
                                            SYS_MOVEA: begin
                                                // Indirect MOVEA: target address = temp_data + imm_value2
                                                rf_wr_en   = 1'b1;
                                                rf_wr_addr = inst_r.reg_dst;
                                                rf_wr_data = temp_data + inst_r.imm_value2;
                                            end
                                            SYS_SETF: begin
                                                flags_cond = temp_data[3:0];
                                                rf_wr_en   = 1'b1;
                                                rf_wr_addr = inst_r.reg_dst;
                                                rf_wr_data = {31'h0, flags_cond_met};
                                            end
                                            SYS_UPDPSW: begin
                                                // mem src: temp_data=value, dst reg=mask
                                                rf_rd_addr_b = inst_r.reg_dst;
                                                if (inst_r.dst_size == SZ_HALF)
                                                    psw_wr_data = (psw & ~(rf_rd_data_b & 32'h0000FFFF)) | (temp_data & (rf_rd_data_b & 32'h0000FFFF));
                                                else
                                                    psw_wr_data = (psw & ~(rf_rd_data_b & 32'h00FFFFFF)) | (temp_data & (rf_rd_data_b & 32'h00FFFFFF));
                                                psw_wr_en = 1'b1;
                                            end
                                            SYS_LDPR: begin
                                                rf_rd_addr_b = inst_r.reg_dst;
                                                preg_addr    = rf_rd_data_b[4:0];
                                                preg_wr_data = temp_data;
                                                preg_wr_en   = 1'b1;
                                            end
                                            SYS_STPR: begin
                                                preg_addr  = temp_data[4:0];
                                                rf_wr_en   = 1'b1;
                                                rf_wr_addr = inst_r.reg_dst;
                                                rf_wr_data = preg_rd_data;
                                            end
                                            default: ;
                                        endcase
                                    end else if (inst_r.is_mem_src) begin
                                        alu_a = temp_data;
                                        rf_rd_addr_b = inst_r.reg_dst;
                                        alu_b = rf_rd_data_b;

                                        alu_op       = inst_r.alu_op;
                                        alu_size     = inst_r.data_size;
                                        alu_flags_in = psw[3:0];

                                        if (inst_r.alu_op != ALU_CMP && inst_r.alu_op != ALU_TEST1) begin
                                            rf_wr_en   = 1'b1;
                                            rf_wr_addr = inst_r.reg_dst;
                                            rf_wr_data = alu_result;
                                            rf_wr_size = inst_r.data_size;
                                        end

                                        if (inst_r.writes_flags) begin
                                            psw_cc_wr_en   = 1'b1;
                                            psw_cc_wr_data = {alu_flag_cy, alu_flag_ov, alu_flag_s, alu_flag_z};
                                        end
                                    end else begin
                                        rf_rd_addr_a = inst_r.reg_src;
                                        case (inst_r.am_src)
                                            AM_REGISTER:  alu_a = rf_rd_data_a;
                                            AM_IMMEDIATE: alu_a = inst_r.imm_value;
                                            AM_IMM_QUICK: alu_a = inst_r.imm_value;
                                            default:      alu_a = rf_rd_data_a;
                                        endcase
                                        alu_b = temp_data;

                                        alu_op       = inst_r.alu_op;
                                        alu_size     = inst_r.data_size;
                                        alu_flags_in = psw[3:0];

                                        if (inst_r.writes_flags) begin
                                            psw_cc_wr_en   = 1'b1;
                                            psw_cc_wr_data = {alu_flag_cy, alu_flag_ov, alu_flag_s, alu_flag_z};
                                        end
                                    end
                                end

                                FMT_III: begin
                                    if (inst_r.sys_op == SYS_TASI) begin
                                        // TASI memory: SUB(val, 0xFF) for flags, write 0xFF back
                                        alu_a        = 32'h000000FF;
                                        alu_b        = {24'h0, temp_data[7:0]};
                                        alu_op       = ALU_SUB;
                                        alu_size     = SZ_BYTE;
                                        alu_flags_in = psw[3:0];
                                        psw_cc_wr_en   = 1'b1;
                                        psw_cc_wr_data = {alu_flag_cy, alu_flag_ov, alu_flag_s, alu_flag_z};
                                    end else begin
                                        alu_a        = temp_data;
                                        alu_op       = inst_r.alu_op;
                                        alu_size     = inst_r.data_size;
                                        alu_flags_in = psw[3:0];

                                        if (inst_r.writes_flags) begin
                                            psw_cc_wr_en   = 1'b1;
                                            psw_cc_wr_data = {alu_flag_cy, alu_flag_ov, alu_flag_s, alu_flag_z};
                                        end
                                    end
                                end

                                FMT_II: begin
                                    // FP dual-AM EXECUTE2 datapath
                                    fpu_op = inst_r.fp_op;
                                    fpu_a  = fp_src_val;
                                    fpu_b  = temp_data; // AM2 value (for R-M-W/CMPF)

                                    if (fp_phase == 2'd0) begin
                                        // AM1 data just arrived in temp_data
                                        fpu_a = temp_data;
                                        // For MOV-like to register: compute and write
                                        if (!inst_r.is_mem_dst && fmt2_is_mov_like_r) begin
                                            rf_rd_addr_b = inst_r.reg_dst;
                                            fpu_b = rf_rd_data_b;
                                            rf_wr_en   = 1'b1;
                                            rf_wr_addr = inst_r.reg_dst;
                                            rf_wr_data = fpu_result;
                                            if (inst_r.writes_flags) begin
                                                psw_cc_wr_en   = 1'b1;
                                                psw_cc_wr_data = {fpu_flag_cy, fpu_flag_ov, fpu_flag_s, fpu_flag_z};
                                            end
                                        end
                                        // For R-M-W/CMPF to register: need AM2 value
                                        if (!inst_r.is_mem_dst && (fmt2_is_rmw_r || fmt2_is_cmpf_r)) begin
                                            rf_rd_addr_b = inst_r.reg_dst;
                                            fpu_b = rf_rd_data_b;
                                            // Write result
                                            if (!fmt2_is_cmpf_r) begin
                                                rf_wr_en   = 1'b1;
                                                rf_wr_addr = inst_r.reg_dst;
                                                rf_wr_data = fpu_result;
                                            end
                                            if (inst_r.writes_flags) begin
                                                psw_cc_wr_en   = 1'b1;
                                                psw_cc_wr_data = {fpu_flag_cy, fpu_flag_ov, fpu_flag_s, fpu_flag_z};
                                            end
                                        end
                                    end else begin
                                        // fp_phase==1: AM2 data in temp_data
                                        fpu_a = fp_src_val;
                                        fpu_b = temp_data;
                                        // CMPF: flags only
                                        if (fmt2_is_cmpf_r) begin
                                            if (inst_r.writes_flags) begin
                                                psw_cc_wr_en   = 1'b1;
                                                psw_cc_wr_data = {fpu_flag_cy, fpu_flag_ov, fpu_flag_s, fpu_flag_z};
                                            end
                                        end
                                        // R-M-W to register: write result
                                        if (!inst_r.is_mem_dst && !fmt2_is_cmpf_r) begin
                                            rf_wr_en   = 1'b1;
                                            rf_wr_addr = inst_r.reg_dst;
                                            rf_wr_data = fpu_result;
                                            if (inst_r.writes_flags) begin
                                                psw_cc_wr_en   = 1'b1;
                                                psw_cc_wr_data = {fpu_flag_cy, fpu_flag_ov, fpu_flag_s, fpu_flag_z};
                                            end
                                        end
                                        // R-M-W to memory: flags set here, data written in MEM_WRITE
                                        if (inst_r.is_mem_dst && !fmt2_is_cmpf_r) begin
                                            if (inst_r.writes_flags) begin
                                                psw_cc_wr_en   = 1'b1;
                                                psw_cc_wr_data = {fpu_flag_cy, fpu_flag_ov, fpu_flag_s, fpu_flag_z};
                                            end
                                        end
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
                        if (inst_r.format == FMT_II && inst_r.fp_op != FP_NONE) begin
                            // FP writes are always word-sized
                            data_bus_size = SZ_WORD;
                            // For MOV-like: compute FPU result here
                            if (fmt2_is_mov_like_r && fp_phase == 2'd0) begin
                                fpu_op = inst_r.fp_op;
                                fpu_a  = fp_src_val;
                                fpu_b  = 32'h0;
                                data_bus_wdata = fpu_result;
                                // Set flags
                                if (inst_r.writes_flags) begin
                                    psw_cc_wr_en   = 1'b1;
                                    psw_cc_wr_data = {fpu_flag_cy, fpu_flag_ov, fpu_flag_s, fpu_flag_z};
                                end
                            end else begin
                                data_bus_wdata = temp_data;
                            end
                        end else begin
                            // Cross-size MOV: write uses dst_size; others use data_size
                            data_bus_size  = (inst_r.sys_op != SYS_NONE) ? inst_r.dst_size : inst_r.data_size;
                            data_bus_wdata = temp_data;
                        end
                    end

                    default: begin
                        // Control flow writes are always 32-bit
                        data_bus_wdata = temp_data;
                    end
                endcase
            end

            ST_MEM_WRITE_WAIT: begin
                // Wait for data_bus_valid
                if (data_bus_valid && int_active && int_push_done) begin
                    // All pushes done — read SBR for vector address computation
                    preg_addr = PREG_SBR[4:0];
                end
                if (data_bus_valid && !int_active && inst_r.ctrl_flow == CF_PUSHM) begin
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

                    CF_RSR: begin
                        // SP += 4, PC = return_addr
                        rf_wr_en   = 1'b1;
                        rf_wr_addr = 5'd31; // SP
                        rf_wr_data = temp_addr + 32'd4;
                        pc_wr_en         = 1'b1;
                        pc_wr_data       = return_addr;
                        fetch_flush      = 1'b1;
                        fetch_flush_addr = return_addr;
                    end

                    CF_TRAP: begin
                        // Condition not met — normal advance
                        fetch_consume_count = inst_r.inst_len;
                        fetch_consume_valid = 1'b1;
                        pc_wr_en   = 1'b1;
                        pc_wr_data = pc + {26'h0, inst_r.inst_len};
                    end

                    CF_RETIU: begin
                        // Restore PC, PSW, and adjust SP
                        pc_wr_en         = 1'b1;
                        pc_wr_data       = return_addr;
                        psw_wr_en        = 1'b1;
                        psw_wr_data      = saved_psw;
                        rf_wr_en         = 1'b1;
                        rf_wr_addr       = 5'd31; // SP
                        rf_wr_data       = temp_addr + 32'd4 + temp_src;
                        fetch_flush      = 1'b1;
                        fetch_flush_addr = return_addr;
                    end

                    CF_DBCC: begin
                        rf_rd_addr_a = inst_r.reg_dst; // counter register
                        if (inst_r.cond == CC_NOP) begin
                            // TB: branch if register == 0, no decrement
                            if (rf_rd_data_a == 32'd0) begin
                                pc_wr_en   = 1'b1;
                                pc_wr_data = pc + inst_r.imm_value;
                                fetch_flush      = 1'b1;
                                fetch_flush_addr = pc + inst_r.imm_value;
                            end else begin
                                fetch_consume_count = inst_r.inst_len;
                                fetch_consume_valid = 1'b1;
                                pc_wr_en   = 1'b1;
                                pc_wr_data = pc + {26'h0, inst_r.inst_len};
                            end
                        end else begin
                            // DBCC: always decrement counter
                            rf_wr_en   = 1'b1;
                            rf_wr_addr = inst_r.reg_dst;
                            rf_wr_data = rf_rd_data_a - 32'd1;
                            rf_wr_size = SZ_WORD;
                            // Branch if decremented != 0 AND condition met
                            flags_cond = inst_r.cond;
                            if ((rf_rd_data_a - 32'd1) != 32'd0 && flags_cond_met) begin
                                pc_wr_en   = 1'b1;
                                pc_wr_data = pc + inst_r.imm_value;
                                fetch_flush      = 1'b1;
                                fetch_flush_addr = pc + inst_r.imm_value;
                            end else begin
                                fetch_consume_count = inst_r.inst_len;
                                fetch_consume_valid = 1'b1;
                                pc_wr_en   = 1'b1;
                                pc_wr_data = pc + {26'h0, inst_r.inst_len};
                            end
                        end
                    end

                    default: begin
                        // Standard writeback
                        if (!(inst_r.is_branch && flags_cond_met)) begin
                            fetch_consume_count = inst_r.inst_len;
                            fetch_consume_valid = 1'b1;
                            pc_wr_en   = 1'b1;
                            pc_wr_data = pc + {26'h0, inst_r.inst_len};
                        end

                        if (inst_r.format == FMT_II && inst_r.fp_op != FP_NONE) begin
                            // FP auto-inc: AM1 uses temp_addr, AM2 uses temp_addr2
                            if (inst_r.auto_inc) begin
                                rf_wr_en   = 1'b1;
                                rf_wr_addr = inst_r.reg_src;
                                rf_wr_data = temp_addr + 32'd4; // always word
                            end
                            // AM2 auto_inc2: different register port needed
                            // Note: both auto_inc and auto_inc2 in same instruction unlikely
                            // but handle auto_inc2 via second write if no auto_inc
                            if (inst_r.auto_inc2 && !inst_r.auto_inc) begin
                                rf_wr_en   = 1'b1;
                                rf_wr_addr = inst_r.reg_dst;
                                rf_wr_data = temp_addr2 + 32'd4; // always word
                            end
                        end else if (inst_r.auto_inc) begin
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
