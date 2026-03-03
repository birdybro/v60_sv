// tb_v60_top.sv — Top-level Verilator testbench wrapper
// Instantiates V60 CPU and memory, provides DPI interface for sim_main.cpp

module tb_v60_top
    import v60_pkg::*;
#(
    parameter int DATA_WIDTH = 16,
    parameter int ADDR_WIDTH = 24,
    parameter int MEM_SIZE   = 1 << 20  // 1MB
)(
    input  logic clk,
    input  logic rst_n
);

    // Bus signals
    logic [ADDR_WIDTH-1:0]      bus_addr;
    logic                       bus_rd_n;
    logic                       bus_wr_n;
    logic [DATA_WIDTH-1:0]      bus_wdata;
    logic [DATA_WIDTH-1:0]      bus_rdata;
    logic [(DATA_WIDTH/8)-1:0]  bus_be;
    logic                       bus_as_n;
    logic                       bus_ready;

    // Interrupts (active low, inactive by default)
    logic       nmi_n;
    logic [3:0] irq_n;

    assign nmi_n = 1'b1;
    assign irq_n = 4'hF;

    // Status
    logic       halted;
    fsm_state_t cpu_state;

    // CPU instance
    v60_cpu #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .PIR_VALUE(32'h00006000)
    ) u_cpu (
        .clk      (clk),
        .rst_n    (rst_n),
        .bus_addr (bus_addr),
        .bus_rd_n (bus_rd_n),
        .bus_wr_n (bus_wr_n),
        .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata),
        .bus_be   (bus_be),
        .bus_as_n (bus_as_n),
        .bus_ready(bus_ready),
        .nmi_n    (nmi_n),
        .irq_n    (irq_n),
        .halted   (halted),
        .cpu_state(cpu_state)
    );

    // Memory instance
    tb_memory #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .MEM_SIZE(MEM_SIZE)
    ) u_mem (
        .clk      (clk),
        .rst_n    (rst_n),
        .bus_addr (bus_addr),
        .bus_rd_n (bus_rd_n),
        .bus_wr_n (bus_wr_n),
        .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata),
        .bus_be   (bus_be),
        .bus_as_n (bus_as_n),
        .bus_ready(bus_ready)
    );

    // DPI functions for trace output from C++
    export "DPI-C" function get_pc;
    function int get_pc();
        return int'(u_cpu.pc);
    endfunction

    export "DPI-C" function get_psw;
    function int get_psw();
        return int'(u_cpu.psw);
    endfunction

    export "DPI-C" function get_gpr;
    function int get_gpr(input int idx);
        if (idx >= 0 && idx < 32)
            return int'(u_cpu.u_regfile.gpr[idx]);
        else
            return 0;
    endfunction

    export "DPI-C" function get_cpu_state;
    function int get_cpu_state();
        return int'(cpu_state);
    endfunction

    export "DPI-C" function is_halted;
    function int is_halted();
        return int'(halted);
    endfunction

endmodule
