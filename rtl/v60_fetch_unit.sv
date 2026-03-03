/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
// v60_fetch_unit.sv — Instruction fetch buffer
// 24-byte circular buffer with sequential prefetch.
// Provides decoded bytes to the decode stage.

module v60_fetch_unit
    import v60_pkg::*;
#(
    parameter int DATA_WIDTH = 16,
    parameter int ADDR_WIDTH = 24
)(
    input  logic        clk,
    input  logic        rst_n,

    // PC from register file
    input  logic [31:0] pc,

    // Flush control (on branch/exception)
    input  logic        flush,
    input  logic [31:0] flush_addr,

    // Bus interface
    output bus_req_t    bus_req,
    output logic [31:0] bus_addr,
    output data_size_t  bus_size,
    input  logic [31:0] bus_rdata,
    input  logic        bus_valid,
    input  logic        bus_busy,

    // Decode interface — window of bytes available
    output logic [7:0]  ibuf_data [FETCH_WINDOW],
    output logic [4:0]  ibuf_valid_count,  // Bytes available for decode
    input  logic [5:0]  consume_count,     // Bytes consumed by decode
    input  logic        consume_valid,     // Pulse to consume bytes

    // Status
    output logic        fetch_active
);

    localparam int BUS_BYTES = DATA_WIDTH / 8;

    // Circular buffer
    logic [7:0] buffer [IBUF_SIZE];
    logic [4:0] wr_ptr;        // Next write position
    logic [4:0] rd_ptr;        // Next read position
    logic [4:0] fill_level;    // Bytes in buffer
    logic [31:0] fetch_addr;   // Next address to fetch from memory

    // Fetch state
    typedef enum logic [1:0] {
        FS_IDLE,
        FS_REQUEST,
        FS_WAIT
    } fetch_state_t;

    fetch_state_t fstate;

    // How much room is available
    logic [4:0] room;
    assign room = IBUF_SIZE[4:0] - fill_level;

    // Can we issue a fetch?
    logic can_fetch;
    assign can_fetch = (room >= BUS_BYTES[4:0]) && !bus_busy && (fstate == FS_IDLE);

    assign fetch_active = (fstate != FS_IDLE);

    // Provide decode window from buffer
    always_comb begin
        for (int i = 0; i < FETCH_WINDOW; i++) begin
            logic [4:0] idx;
            idx = (rd_ptr + i[4:0]) % IBUF_SIZE[4:0];
            ibuf_data[i] = buffer[idx];
        end
        ibuf_valid_count = (fill_level > FETCH_WINDOW[4:0]) ? FETCH_WINDOW[4:0] : fill_level;
    end

    // Bus request outputs — always issue aligned reads
    logic [31:0] aligned_fetch_addr;
    always_comb begin
        if (BUS_BYTES == 2)
            aligned_fetch_addr = {fetch_addr[31:1], 1'b0};
        else
            aligned_fetch_addr = {fetch_addr[31:2], 2'b00};
    end

    always_comb begin
        bus_req  = BUS_IDLE;
        bus_addr = aligned_fetch_addr;
        bus_size = (BUS_BYTES == 2) ? SZ_HALF : SZ_WORD;

        if (fstate == FS_REQUEST) begin
            bus_req  = BUS_READ;
            bus_addr = aligned_fetch_addr;
        end
    end

    // Main sequencing
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr     <= 5'd0;
            rd_ptr     <= 5'd0;
            fill_level <= 5'd0;
            fetch_addr <= 32'h0;
            fstate     <= FS_IDLE;
            for (int i = 0; i < IBUF_SIZE; i++)
                buffer[i] <= 8'h0;
        end else if (flush) begin
            // Flush the buffer and restart from new address
            wr_ptr     <= 5'd0;
            rd_ptr     <= 5'd0;
            fill_level <= 5'd0;
            fetch_addr <= flush_addr;
            fstate     <= FS_IDLE;
        end else begin
            // Consume bytes from decode
            if (consume_valid && consume_count > 0) begin
                rd_ptr     <= (rd_ptr + consume_count[4:0]) % IBUF_SIZE[4:0];
                fill_level <= fill_level - consume_count[4:0];
            end

            // Fetch state machine
            case (fstate)
                FS_IDLE: begin
                    if (can_fetch)
                        fstate <= FS_REQUEST;
                end

                FS_REQUEST: begin
                    if (!bus_busy)
                        fstate <= FS_WAIT;
                end

                FS_WAIT: begin
                    if (bus_valid) begin
                        // Store fetched bytes into buffer.
                        // When fetch_addr is unaligned, we fetched from the
                        // aligned address; only store the relevant bytes.
                        if (BUS_BYTES == 2) begin
                            if (fetch_addr[0]) begin
                                // Odd address: aligned read got {byte_at_addr, prev_byte}.
                                // We only need the high byte (byte at our target address).
                                buffer[(wr_ptr) % IBUF_SIZE[4:0]] <= bus_rdata[15:8];
                                wr_ptr     <= (wr_ptr + 5'd1) % IBUF_SIZE[4:0];
                                fill_level <= fill_level + 5'd1;
                                fetch_addr <= fetch_addr + 32'd1;
                            end else begin
                                // Even address: normal 2-byte fetch
                                buffer[(wr_ptr) % IBUF_SIZE[4:0]]     <= bus_rdata[7:0];
                                buffer[(wr_ptr + 1) % IBUF_SIZE[4:0]] <= bus_rdata[15:8];
                                wr_ptr     <= (wr_ptr + 5'd2) % IBUF_SIZE[4:0];
                                fill_level <= fill_level + 5'd2;
                                fetch_addr <= fetch_addr + 32'd2;
                            end
                        end else begin
                            // 32-bit bus: TODO handle unaligned
                            buffer[(wr_ptr) % IBUF_SIZE[4:0]]     <= bus_rdata[7:0];
                            buffer[(wr_ptr + 1) % IBUF_SIZE[4:0]] <= bus_rdata[15:8];
                            buffer[(wr_ptr + 2) % IBUF_SIZE[4:0]] <= bus_rdata[23:16];
                            buffer[(wr_ptr + 3) % IBUF_SIZE[4:0]] <= bus_rdata[31:24];
                            wr_ptr     <= (wr_ptr + 5'd4) % IBUF_SIZE[4:0];
                            fill_level <= fill_level + 5'd4;
                            fetch_addr <= fetch_addr + 32'd4;
                        end
                        fstate     <= FS_IDLE;
                    end
                end

                default: fstate <= FS_IDLE;
            endcase

            // Adjust fill_level if both consuming and filling this cycle
            if (consume_valid && consume_count > 0 && fstate == FS_WAIT && bus_valid) begin
                if (BUS_BYTES == 2 && fetch_addr[0])
                    fill_level <= fill_level - consume_count[4:0] + 5'd1;
                else
                    fill_level <= fill_level - consume_count[4:0] + BUS_BYTES[4:0];
            end
        end
    end

endmodule
