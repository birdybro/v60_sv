/* verilator lint_off UNUSEDSIGNAL */
// v60_addr_mode.sv — Addressing mode resolver (skeleton)
// Phase 1: Only AM_REGISTER and AM_IMMEDIATE are functional.
// Full 21-mode implementation in Phase 5.

module v60_addr_mode
    import v60_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Control
    input  logic        start,       // Begin address resolution
    input  addr_mode_t  mode,        // Which addressing mode
    input  data_size_t  data_size,   // Operand size
    input  logic [4:0]  reg_idx,     // Register index (for register modes)
    input  logic [31:0] disp,        // Displacement/immediate value
    input  logic [31:0] pc,          // Current PC (for PC-relative)

    // Register file read
    output logic [4:0]  rf_rd_addr,
    input  logic [31:0] rf_rd_data,

    // Bus interface (for memory-indirect modes)
    output bus_req_t    bus_req,
    output logic [31:0] bus_addr,
    output data_size_t  bus_size,
    input  logic [31:0] bus_rdata,
    input  logic        bus_valid,
    input  logic        bus_busy,

    // Output
    output logic [31:0] eff_addr,    // Effective address (for memory modes)
    output logic [31:0] operand_val, // Operand value (for register/immediate)
    output logic        is_memory,   // True if result is a memory address
    output logic        done         // Resolution complete
);

    typedef enum logic [1:0] {
        AMS_IDLE,
        AMS_RESOLVE,
        AMS_MEM_WAIT,
        AMS_DONE
    } am_state_t;

    am_state_t state;

    assign rf_rd_addr = reg_idx;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= AMS_IDLE;
            eff_addr    <= 32'h0;
            operand_val <= 32'h0;
            is_memory   <= 1'b0;
            done        <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                AMS_IDLE: begin
                    if (start) begin
                        state <= AMS_RESOLVE;
                    end
                end

                AMS_RESOLVE: begin
                    case (mode)
                        AM_REGISTER: begin
                            operand_val <= rf_rd_data;
                            is_memory   <= 1'b0;
                            done        <= 1'b1;
                            state       <= AMS_IDLE;
                        end

                        AM_IMMEDIATE, AM_IMM_QUICK: begin
                            operand_val <= disp;
                            is_memory   <= 1'b0;
                            done        <= 1'b1;
                            state       <= AMS_IDLE;
                        end

                        AM_REG_INDIRECT: begin
                            eff_addr  <= rf_rd_data;
                            is_memory <= 1'b1;
                            done      <= 1'b1;
                            state     <= AMS_IDLE;
                        end

                        AM_DISP16_REG, AM_DISP32_REG: begin
                            eff_addr  <= rf_rd_data + disp;
                            is_memory <= 1'b1;
                            done      <= 1'b1;
                            state     <= AMS_IDLE;
                        end

                        AM_DIRECT_ADDR: begin
                            eff_addr  <= disp;
                            is_memory <= 1'b1;
                            done      <= 1'b1;
                            state     <= AMS_IDLE;
                        end

                        AM_PC_DISP16, AM_PC_DISP32: begin
                            eff_addr  <= pc + disp;
                            is_memory <= 1'b1;
                            done      <= 1'b1;
                            state     <= AMS_IDLE;
                        end

                        default: begin
                            // Unsupported mode — complete with zero
                            operand_val <= 32'h0;
                            eff_addr    <= 32'h0;
                            is_memory   <= 1'b0;
                            done        <= 1'b1;
                            state       <= AMS_IDLE;
                        end
                    endcase
                end

                AMS_MEM_WAIT: begin
                    if (bus_valid) begin
                        operand_val <= bus_rdata;
                        done        <= 1'b1;
                        state       <= AMS_IDLE;
                    end
                end

                AMS_DONE: begin
                    state <= AMS_IDLE;
                end

                default: state <= AMS_IDLE;
            endcase
        end
    end

    // Bus request defaults (no memory access in Phase 1 basic modes)
    assign bus_req  = BUS_IDLE;
    assign bus_addr = eff_addr;
    assign bus_size = data_size;

endmodule
