/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
// v60_control.sv — Main FSM controller
// Phase 1: RESET → FETCH → DECODE → EXECUTE → WRITEBACK → FETCH
// Handles NOP, HALT, and Bcc/BR instructions

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

    // Temporary registers
    logic [31:0] temp_addr;
    logic [31:0] temp_data;

    assign state_out = state;
    assign halted    = (state == ST_HALT);

    // =========================================================================
    // FSM State Register
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= ST_RESET;
            inst_r <= '0;
        end else begin
            state <= next_state;

            // Latch decoded instruction when transitioning from DECODE
            if (state == ST_DECODE && decode_valid) begin
                inst_r <= decoded;
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
                // Read reset vector from 0xFFFFFFF0
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
                // Wait until fetch buffer has enough bytes
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
                // If not enough bytes yet, stay in DECODE
            end

            ST_EXECUTE: begin
                next_state = ST_WRITEBACK;
            end

            ST_WRITEBACK: begin
                next_state = ST_FETCH;
            end

            ST_HALT: begin
                // Stay halted until interrupt
                if (int_pending)
                    next_state = ST_INT_CHECK;
            end

            ST_INT_CHECK: begin
                // Stub: go back to fetch after interrupt handling
                next_state = ST_FETCH;
            end

            ST_MEM_READ: begin
                if (!data_bus_busy)
                    next_state = ST_MEM_READ_WAIT;
            end

            ST_MEM_READ_WAIT: begin
                if (data_bus_valid)
                    next_state = ST_EXECUTE;
            end

            ST_MEM_WRITE: begin
                if (!data_bus_busy)
                    next_state = ST_MEM_WRITE_WAIT;
            end

            ST_MEM_WRITE_WAIT: begin
                if (data_bus_valid)
                    next_state = ST_WRITEBACK;
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
                // Nothing — transition happens in next_state logic
            end

            ST_RESET_VEC: begin
                // Initiate read of reset vector
                data_bus_req  = BUS_READ;
                data_bus_addr = RESET_VECTOR_ADDR;
                data_bus_size = SZ_WORD;
            end

            ST_RESET_VEC_WAIT: begin
                if (data_bus_valid) begin
                    // Set PC to the reset vector value
                    pc_wr_en   = 1'b1;
                    pc_wr_data = data_bus_rdata;
                    // Flush fetch to start from new PC
                    fetch_flush      = 1'b1;
                    fetch_flush_addr = data_bus_rdata;
                    // Initialize PSW: interrupts disabled, EL=0, IS=1
                    psw_wr_en   = 1'b1;
                    psw_wr_data = 32'h0;
                    psw_wr_data[PSW_ID] = 1'b1;  // Interrupts disabled
                    psw_wr_data[PSW_IS] = 1'b1;  // Interrupt stack
                end
            end

            ST_DECODE: begin
                // Just let the decoder work — transition is in next_state
            end

            ST_EXECUTE: begin
                case (inst_r.format)
                    FMT_V: begin
                        // NOP — do nothing
                        // HALT handled in state transition
                    end

                    FMT_IV: begin
                        // Branch instructions
                        flags_cond = inst_r.cond;

                        if (flags_cond_met) begin
                            // Branch taken: PC = PC + displacement
                            // Note: displacement is relative to start of instruction
                            pc_wr_en   = 1'b1;
                            pc_wr_data = pc + inst_r.imm_value;
                            // Flush fetch buffer for new PC
                            fetch_flush      = 1'b1;
                            fetch_flush_addr = pc + inst_r.imm_value;
                        end
                    end

                    default: ;
                endcase
            end

            ST_WRITEBACK: begin
                // Consume instruction bytes from fetch buffer
                fetch_consume_count = inst_r.inst_len;
                fetch_consume_valid = 1'b1;

                // Advance PC if not a taken branch (branch already set PC)
                if (!(inst_r.is_branch && flags_cond_met)) begin
                    pc_wr_en   = 1'b1;
                    pc_wr_data = pc + {26'h0, inst_r.inst_len};
                end

                // Reconfigure flags_cond for the taken-branch check above
                flags_cond = inst_r.cond;
            end

            default: ;
        endcase
    end

endmodule
