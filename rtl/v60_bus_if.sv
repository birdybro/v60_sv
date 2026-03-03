/* verilator lint_off UNUSEDSIGNAL */
// v60_bus_if.sv — Parameterized bus interface
// Handles read/write requests with unaligned access support.
// External bus is DATA_WIDTH wide; internal interface is always 32-bit.

module v60_bus_if
    import v60_pkg::*;
#(
    parameter int DATA_WIDTH = 16,
    parameter int ADDR_WIDTH = 24
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Internal (CPU-side) interface
    input  bus_req_t                req_type,
    input  logic [31:0]             req_addr,
    input  data_size_t              req_size,
    input  logic [31:0]             req_wdata,
    output logic [31:0]             resp_rdata,
    output logic                    resp_valid,
    output logic                    busy,

    // External bus signals
    output logic [ADDR_WIDTH-1:0]   bus_addr,
    output logic                    bus_rd_n,
    output logic                    bus_wr_n,
    output logic [DATA_WIDTH-1:0]   bus_wdata,
    input  logic [DATA_WIDTH-1:0]   bus_rdata,
    output logic [(DATA_WIDTH/8)-1:0] bus_be,
    output logic                    bus_as_n,    // Address strobe
    input  logic                    bus_ready    // Bus ready/ack
);

    localparam int BUS_BYTES = DATA_WIDTH / 8;

    // Transfer FSM
    typedef enum logic [2:0] {
        BIF_IDLE,
        BIF_CYCLE1,
        BIF_CYCLE1_WAIT,
        BIF_CYCLE2,
        BIF_CYCLE2_WAIT,
        BIF_DONE
    } bif_state_t;

    bif_state_t state, next_state;

    // Latched request
    logic [31:0]    lat_addr;
    data_size_t     lat_size;
    logic [31:0]    lat_wdata;
    bus_req_t       lat_type;
    logic [31:0]    read_accum;  // Accumulated read data
    logic           need_second; // Need a second bus cycle (unaligned or wide)

    // Number of bytes for the request
    logic [2:0] req_bytes;
    always_comb begin
        case (req_size)
            SZ_BYTE: req_bytes = 3'd1;
            SZ_HALF: req_bytes = 3'd2;
            SZ_WORD: req_bytes = 3'd4;
            default: req_bytes = 3'd1;
        endcase
    end

    // Determine if second cycle is needed
    // For 16-bit bus: word access always needs 2 cycles;
    //                 half-word at odd address needs 2 cycles
    logic second_needed;
    always_comb begin
        if (BUS_BYTES == 2) begin
            second_needed = (req_size == SZ_WORD) ||
                            (req_size == SZ_HALF && req_addr[0]);
        end else begin
            // 32-bit bus: only if crossing 4-byte boundary
            second_needed = (req_size == SZ_WORD && req_addr[1:0] != 2'b00) ||
                            (req_size == SZ_HALF && req_addr[1:0] == 2'b11);
        end
    end

    // FSM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= BIF_IDLE;
            lat_addr     <= 32'h0;
            lat_size     <= SZ_BYTE;
            lat_wdata    <= 32'h0;
            lat_type     <= BUS_IDLE;
            read_accum   <= 32'h0;
            need_second  <= 1'b0;
        end else begin
            state <= next_state;

            case (state)
                BIF_IDLE: begin
                    if (req_type != BUS_IDLE) begin
                        lat_addr    <= req_addr;
                        lat_size    <= req_size;
                        lat_wdata   <= req_wdata;
                        lat_type    <= req_type;
                        need_second <= second_needed;
                        read_accum  <= 32'h0;
                    end
                end

                BIF_CYCLE1_WAIT: begin
                    if (bus_ready && lat_type == BUS_READ) begin
                        // Capture first read data
                        if (BUS_BYTES == 2)
                            read_accum[15:0] <= bus_rdata[15:0];
                        else
                            read_accum <= {{(32-DATA_WIDTH){1'b0}}, bus_rdata};
                    end
                end

                BIF_CYCLE2_WAIT: begin
                    if (bus_ready && lat_type == BUS_READ) begin
                        if (BUS_BYTES == 2)
                            read_accum[31:16] <= bus_rdata[15:0];
                        else
                            read_accum[31:16] <= bus_rdata[15:0];
                    end
                end

                default: ;
            endcase
        end
    end

    // Next state logic
    always_comb begin
        next_state = state;
        case (state)
            BIF_IDLE:
                if (req_type != BUS_IDLE)
                    next_state = BIF_CYCLE1;

            BIF_CYCLE1:
                next_state = BIF_CYCLE1_WAIT;

            BIF_CYCLE1_WAIT:
                if (bus_ready)
                    next_state = need_second ? BIF_CYCLE2 : BIF_DONE;

            BIF_CYCLE2:
                next_state = BIF_CYCLE2_WAIT;

            BIF_CYCLE2_WAIT:
                if (bus_ready)
                    next_state = BIF_DONE;

            BIF_DONE:
                next_state = BIF_IDLE;

            default:
                next_state = BIF_IDLE;
        endcase
    end

    // Bus output signals
    always_comb begin
        bus_addr  = lat_addr[ADDR_WIDTH-1:0];
        bus_rd_n  = 1'b1;
        bus_wr_n  = 1'b1;
        bus_wdata = '0;
        bus_be    = '0;
        bus_as_n  = 1'b1;

        case (state)
            BIF_CYCLE1, BIF_CYCLE1_WAIT: begin
                bus_addr = lat_addr[ADDR_WIDTH-1:0];
                bus_as_n = 1'b0;
                if (lat_type == BUS_READ) begin
                    bus_rd_n = 1'b0;
                    // Byte enables based on address alignment and size
                    if (BUS_BYTES == 2) begin
                        case (lat_size)
                            SZ_BYTE: bus_be = lat_addr[0] ? 2'b10 : 2'b01;
                            SZ_HALF: bus_be = lat_addr[0] ? 2'b01 : 2'b11;
                            SZ_WORD: bus_be = 2'b11;
                            default: bus_be = 2'b01;
                        endcase
                    end else begin
                        bus_be = '1;  // Simplified for 32-bit bus
                    end
                end else if (lat_type == BUS_WRITE) begin
                    bus_wr_n = 1'b0;
                    if (BUS_BYTES == 2) begin
                        bus_wdata = lat_wdata[15:0];
                        case (lat_size)
                            SZ_BYTE: begin
                                bus_wdata = lat_addr[0] ? {lat_wdata[7:0], 8'h0} : {8'h0, lat_wdata[7:0]};
                                bus_be    = lat_addr[0] ? 2'b10 : 2'b01;
                            end
                            SZ_HALF: begin
                                bus_wdata = lat_wdata[15:0];
                                bus_be    = 2'b11;
                            end
                            SZ_WORD: begin
                                bus_wdata = lat_wdata[15:0];
                                bus_be    = 2'b11;
                            end
                            default: begin
                                bus_wdata = lat_wdata[15:0];
                                bus_be    = 2'b01;
                            end
                        endcase
                    end else begin
                        bus_wdata = lat_wdata[DATA_WIDTH-1:0];
                        bus_be    = '1;
                    end
                end
            end

            BIF_CYCLE2, BIF_CYCLE2_WAIT: begin
                bus_addr = lat_addr[ADDR_WIDTH-1:0] + ADDR_WIDTH'(BUS_BYTES);
                bus_as_n = 1'b0;
                if (lat_type == BUS_READ) begin
                    bus_rd_n = 1'b0;
                    bus_be   = '1;
                end else if (lat_type == BUS_WRITE) begin
                    bus_wr_n = 1'b0;
                    if (BUS_BYTES == 2) begin
                        bus_wdata = lat_wdata[31:16];
                        bus_be    = 2'b11;
                    end else begin
                        bus_wdata = lat_wdata[DATA_WIDTH-1:0];
                        bus_be    = '1;
                    end
                end
            end

            default: ;
        endcase
    end

    // Response signals
    assign resp_valid = (state == BIF_DONE);
    assign busy       = (state != BIF_IDLE);

    // Read data output with size masking
    always_comb begin
        case (lat_size)
            SZ_BYTE: resp_rdata = {24'h0, read_accum[7:0]};
            SZ_HALF: resp_rdata = {16'h0, read_accum[15:0]};
            SZ_WORD: resp_rdata = read_accum;
            default: resp_rdata = read_accum;
        endcase
    end

endmodule
