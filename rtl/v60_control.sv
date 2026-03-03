/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
// v60_control.sv — Main FSM controller
// Phase 5A: Memory addressing modes — [Rn], [Rn]+, -[Rn], Disp[Rn], PCDisp, DirectAddr
// Handles NOP, HALT, Bcc/BR, MOV, ADD, SUB, CMP, AND, OR, XOR, ADDC, SUBC,
// NOT, NEG, GETPSW, INC, DEC — with register, immediate, AND memory operands

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
    // FSM State Register
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_RESET;
            inst_r          <= '0;
            temp_addr       <= 32'h0;
            temp_data       <= 32'h0;
            needs_mem_write <= 1'b0;
        end else begin
            state <= next_state;

            // Latch decoded instruction when transitioning from DECODE
            if (state == ST_DECODE && decode_valid) begin
                inst_r <= decoded;
            end

            // Latch temp_addr in ST_EXECUTE when memory operand
            if (state == ST_EXECUTE && (inst_r.is_mem_src || inst_r.is_mem_dst)) begin
                temp_addr <= eff_addr_comb;

                // For auto-decrement, update the register value in inst_r
                // (the actual register write happens in the datapath below)

                // For MOV to memory (write-only): latch source data
                if (inst_r.is_mem_dst && inst_r.alu_op == ALU_MOV) begin
                    // Source value: either register or immediate
                    case (inst_r.am_src)
                        AM_REGISTER:  temp_data <= rf_rd_data_b;
                        AM_IMMEDIATE: temp_data <= inst_r.imm_value;
                        AM_IMM_QUICK: temp_data <= inst_r.imm_value;
                        default:      temp_data <= rf_rd_data_b;
                    endcase
                end

                // Set needs_mem_write for RMW operations
                if (inst_r.is_mem_dst && inst_r.alu_op != ALU_MOV && inst_r.alu_op != ALU_CMP)
                    needs_mem_write <= 1'b1;
                else
                    needs_mem_write <= 1'b0;
            end

            // For Format III memory (INC/DEC [mem]): set needs_mem_write
            if (state == ST_EXECUTE && inst_r.format == FMT_III && inst_r.is_mem_dst) begin
                temp_addr <= eff_addr_comb;
                needs_mem_write <= 1'b1;
            end

            // Latch memory read data
            if (state == ST_MEM_READ_WAIT && data_bus_valid) begin
                temp_data <= data_bus_rdata;
            end

            // Latch ALU result in ST_EXECUTE2 for memory write
            if (state == ST_EXECUTE2 && needs_mem_write) begin
                temp_data <= alu_result;
            end

            // Clear needs_mem_write after write completes
            if (state == ST_MEM_WRITE_WAIT && data_bus_valid) begin
                needs_mem_write <= 1'b0;
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
                if (inst_r.is_mem_src) begin
                    // Need to read source from memory
                    next_state = ST_MEM_READ;
                end else if (inst_r.is_mem_dst) begin
                    if (inst_r.alu_op == ALU_MOV) begin
                        // MOV to memory: write-only
                        next_state = ST_MEM_WRITE;
                    end else begin
                        // ALU to memory: read-modify-write (or CMP flags-only)
                        next_state = ST_MEM_READ;
                    end
                end else if (inst_r.format == FMT_III && inst_r.is_mem_dst) begin
                    // Format III memory (INC/DEC): read-modify-write
                    next_state = ST_MEM_READ;
                end else begin
                    // Register-only: go straight to writeback
                    next_state = ST_WRITEBACK;
                end
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
                if (needs_mem_write)
                    next_state = ST_MEM_WRITE;
                else
                    next_state = ST_WRITEBACK;
            end

            ST_MEM_WRITE: begin
                if (!data_bus_busy)
                    next_state = ST_MEM_WRITE_WAIT;
            end

            ST_MEM_WRITE_WAIT: begin
                if (data_bus_valid)
                    next_state = ST_WRITEBACK;
            end

            ST_WRITEBACK: begin
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
                    psw_wr_data[PSW_ID] = 1'b1;
                    psw_wr_data[PSW_IS] = 1'b1;
                end
            end

            ST_DECODE: begin
                // Let the decoder work
            end

            ST_EXECUTE: begin
                case (inst_r.format)
                    FMT_V: begin
                        // NOP — do nothing
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
                            // Memory operand: compute effective address
                            // Read the addressing register via port A
                            if (inst_r.is_mem_src)
                                rf_rd_addr_a = inst_r.reg_src;
                            else
                                rf_rd_addr_a = inst_r.reg_dst;

                            // For d=0 with mem dst: read source register via port B
                            if (inst_r.is_mem_dst) begin
                                rf_rd_addr_b = inst_r.reg_src;
                            end

                            // Auto-decrement: write decremented address back to register
                            if (inst_r.auto_dec) begin
                                rf_wr_en   = 1'b1;
                                rf_wr_addr = inst_r.is_mem_src ? inst_r.reg_src : inst_r.reg_dst;
                                rf_wr_data = eff_addr_comb;  // Already decremented
                            end
                        end else begin
                            // Register-only path (unchanged from Phase 4)
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
                            // Memory operand: compute effective address
                            rf_rd_addr_a = inst_r.reg_dst;

                            // Auto-decrement
                            if (inst_r.auto_dec) begin
                                rf_wr_en   = 1'b1;
                                rf_wr_addr = inst_r.reg_dst;
                                rf_wr_data = eff_addr_comb;
                            end
                        end else begin
                            // Register-only (unchanged)
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

            ST_MEM_READ: begin
                data_bus_req  = BUS_READ;
                data_bus_addr = temp_addr;
                data_bus_size = inst_r.data_size;
            end

            ST_MEM_READ_WAIT: begin
                // Wait for data_bus_valid; temp_data latched in always_ff
            end

            ST_EXECUTE2: begin
                // Post-memory-read ALU execution
                case (inst_r.format)
                    FMT_I: begin
                        if (inst_r.is_mem_src) begin
                            // Source from memory, dest is register
                            alu_a = temp_data;
                            rf_rd_addr_b = inst_r.reg_dst;
                            alu_b = rf_rd_data_b;
                        end else begin
                            // Source is register/immediate, dest is memory (RMW)
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

                        // Write result to register if dest is register
                        if (inst_r.is_mem_src && inst_r.alu_op != ALU_CMP) begin
                            rf_wr_en   = 1'b1;
                            rf_wr_addr = inst_r.reg_dst;
                            rf_wr_data = alu_result;
                        end

                        // Update flags
                        if (inst_r.writes_flags) begin
                            psw_cc_wr_en   = 1'b1;
                            psw_cc_wr_data = {alu_flag_cy, alu_flag_ov, alu_flag_s, alu_flag_z};
                        end
                    end

                    FMT_III: begin
                        // INC/DEC on memory value
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

            ST_MEM_WRITE: begin
                data_bus_req   = BUS_WRITE;
                data_bus_addr  = temp_addr;
                data_bus_size  = inst_r.data_size;
                data_bus_wdata = temp_data;
            end

            ST_MEM_WRITE_WAIT: begin
                // Wait for data_bus_valid
            end

            ST_WRITEBACK: begin
                // Reconfigure flags_cond so the taken-branch check is correct
                flags_cond = inst_r.cond;

                // For taken branches: fetch buffer was already flushed and PC set
                // in EXECUTE, so skip consume and PC update.
                if (!(inst_r.is_branch && flags_cond_met)) begin
                    fetch_consume_count = inst_r.inst_len;
                    fetch_consume_valid = 1'b1;
                    pc_wr_en   = 1'b1;
                    pc_wr_data = pc + {26'h0, inst_r.inst_len};
                end

                // Auto-increment side effect: write Rn += size_bytes
                if (inst_r.auto_inc) begin
                    rf_wr_en   = 1'b1;
                    rf_wr_addr = inst_r.is_mem_src ? inst_r.reg_src : inst_r.reg_dst;
                    rf_wr_data = temp_addr + {29'h0, size_bytes};
                end
            end

            default: ;
        endcase
    end

endmodule
