/* verilator lint_off UNUSEDSIGNAL */
// tb_memory.sv — Simple synchronous RAM model for testbench
// Supports byte/half/word access with byte enables.
// Memory contents loadable from binary file via DPI.

module tb_memory #(
    parameter int DATA_WIDTH = 16,
    parameter int ADDR_WIDTH = 24,
    parameter int MEM_SIZE   = 1 << 20  // 1MB default
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Bus signals
    input  logic [ADDR_WIDTH-1:0]   bus_addr,
    input  logic                    bus_rd_n,
    input  logic                    bus_wr_n,
    input  logic [DATA_WIDTH-1:0]   bus_wdata,
    output logic [DATA_WIDTH-1:0]   bus_rdata,
    input  logic [(DATA_WIDTH/8)-1:0] bus_be,
    input  logic                    bus_as_n,
    output logic                    bus_ready
);

    localparam int BUS_BYTES = DATA_WIDTH / 8;

    // Byte-addressable memory
    logic [7:0] mem [MEM_SIZE];

    // Ready one cycle after AS asserted
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            bus_ready <= 1'b0;
        else
            bus_ready <= ~bus_as_n;
    end

    // Address mapping: wrap to memory size
    localparam int ADDR_BITS = $clog2(MEM_SIZE);
    logic [ADDR_BITS-1:0] masked_addr;
    assign masked_addr = bus_addr[ADDR_BITS-1:0];

    // Read logic (combinational)
    always_comb begin
        bus_rdata = '0;
        if (!bus_rd_n) begin
            for (int i = 0; i < BUS_BYTES; i++) begin
                if (bus_be[i])
                    bus_rdata[i*8 +: 8] = mem[ADDR_BITS'(masked_addr + ADDR_BITS'(i))];
            end
        end
    end

    // Write logic
    always_ff @(posedge clk) begin
        if (!bus_wr_n && !bus_as_n) begin
            for (int i = 0; i < BUS_BYTES; i++) begin
                if (bus_be[i])
                    mem[ADDR_BITS'(masked_addr + ADDR_BITS'(i))] <= bus_wdata[i*8 +: 8];
            end
        end
    end

    // DPI functions for memory access from C++
    export "DPI-C" task mem_write_byte;
    task mem_write_byte(input int addr, input int data);
        if (addr >= 0 && addr < MEM_SIZE)
            mem[addr] = data[7:0];
    endtask

    export "DPI-C" function mem_read_byte;
    function int mem_read_byte(input int addr);
        if (addr >= 0 && addr < MEM_SIZE)
            return {24'h0, mem[addr]};
        else
            return 0;
    endfunction

    // Initialize memory to NOP (0xCD) pattern
    initial begin
        for (int i = 0; i < MEM_SIZE; i++)
            mem[i] = 8'hCD;  // NOP
    end

endmodule
