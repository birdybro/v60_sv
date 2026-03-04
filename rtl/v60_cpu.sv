// v60_cpu.sv — Top-level NEC V60 CPU module
// Parameterized for V60 (16-bit bus, 24-bit addr) and V70 (32-bit bus, 32-bit addr)

/* verilator lint_off UNUSEDSIGNAL */
module v60_cpu
    import v60_pkg::*;
#(
    parameter int DATA_WIDTH = 16,
    parameter int ADDR_WIDTH = 24,
    parameter int PIR_VALUE  = 32'h00006000
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // External bus
    output logic [ADDR_WIDTH-1:0]   bus_addr,
    output logic                    bus_rd_n,
    output logic                    bus_wr_n,
    output logic [DATA_WIDTH-1:0]   bus_wdata,
    input  logic [DATA_WIDTH-1:0]   bus_rdata,
    output logic [(DATA_WIDTH/8)-1:0] bus_be,
    output logic                    bus_as_n,
    input  logic                    bus_ready,

    // Interrupts
    input  logic                    nmi_n,
    input  logic [3:0]              irq_n,

    // Status
    output logic                    halted,
    output fsm_state_t              cpu_state
);

    // =========================================================================
    // Internal signal declarations
    // =========================================================================

    // Register file signals
    logic [4:0]  rf_rd_addr_a, rf_rd_addr_b;
    logic [31:0] rf_rd_data_a, rf_rd_data_b;
    logic        rf_wr_en;
    logic [4:0]  rf_wr_addr;
    logic [31:0] rf_wr_data;
    data_size_t  rf_wr_size;
    logic        pc_wr_en;
    logic [31:0] pc_wr_data, pc;
    logic        psw_wr_en;
    logic [31:0] psw_wr_data, psw;
    logic        psw_cc_wr_en;
    logic [3:0]  psw_cc_wr_data;
    logic        preg_wr_en;
    logic [4:0]  preg_addr;
    logic [31:0] preg_wr_data, preg_rd_data;
    logic [31:0] current_sp;

    // Fetch unit signals
    logic        fetch_flush;
    logic [31:0] fetch_flush_addr;
    bus_req_t    fetch_bus_req;
    logic [31:0] fetch_bus_addr;
    data_size_t  fetch_bus_size;
    logic [7:0]  ibuf_data [FETCH_WINDOW];
    logic [4:0]  ibuf_valid_count;
    logic [5:0]  fetch_consume_count;
    logic        fetch_consume_valid;
    logic        fetch_active;

    // Decode signals
    decoded_inst_t decoded;
    logic          decode_valid;

    // ALU signals
    alu_op_t     alu_op;
    data_size_t  alu_size;
    logic [31:0] alu_a, alu_b, alu_result;
    logic [3:0]  alu_flags_in;
    logic        alu_flag_z, alu_flag_s, alu_flag_ov, alu_flag_cy;

    // Flags
    logic [3:0]  flags_cond;
    logic        flags_cond_met;

    // Control → data bus
    bus_req_t    data_bus_req;
    logic [31:0] data_bus_addr;
    data_size_t  data_bus_size;
    logic [31:0] data_bus_wdata;

    // Interrupt
    logic        int_pending;
    logic [7:0]  int_vector;
    logic        int_ack;
    logic        is_nmi;

    // Bus arbitration: fetch vs data
    bus_req_t    arb_bus_req;
    logic [31:0] arb_bus_addr;
    data_size_t  arb_bus_size;
    logic [31:0] arb_bus_wdata;

    // Bus interface outputs
    logic [31:0] bus_if_rdata;
    logic        bus_if_valid;
    logic        bus_if_busy;

    // Route bus response to fetch or data
    logic        fetch_bus_valid;
    logic [31:0] fetch_bus_rdata;
    logic        data_bus_valid;
    logic [31:0] data_bus_rdata;

    // Bus arbitration: data bus has priority over fetch.
    // response_to_data tracks WHO submitted the in-flight bus request so
    // responses are routed correctly even when a data bus request arrives
    // while a fetch is already in-flight.
    logic data_bus_active;
    logic response_to_data;

    assign data_bus_active = (data_bus_req != BUS_IDLE);

    // Latch who submitted the request when bus_if accepts it (idle→busy).
    // Cleared when bus returns to idle with no new request pending.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            response_to_data <= 1'b0;
        else if (!bus_if_busy && arb_bus_req != BUS_IDLE)
            response_to_data <= data_bus_active;  // Latch at submission time
        else if (!bus_if_busy)
            response_to_data <= 1'b0;
    end

    always_comb begin
        if (data_bus_active) begin
            arb_bus_req   = data_bus_req;
            arb_bus_addr  = data_bus_addr;
            arb_bus_size  = data_bus_size;
            arb_bus_wdata = data_bus_wdata;
        end else begin
            arb_bus_req   = fetch_bus_req;
            arb_bus_addr  = fetch_bus_addr;
            arb_bus_size  = fetch_bus_size;
            arb_bus_wdata = 32'h0;
        end
    end

    // Route responses based on who submitted the in-flight request
    assign fetch_bus_valid = bus_if_valid && !response_to_data;
    assign fetch_bus_rdata = bus_if_rdata;
    assign data_bus_valid  = bus_if_valid && response_to_data;
    assign data_bus_rdata  = bus_if_rdata;

    // Fetch is blocked when bus is busy (any transaction) or data bus wants priority
    logic fetch_bus_busy;
    assign fetch_bus_busy = bus_if_busy || data_bus_active;

    // Tie off unused signals
    assign int_ack      = 1'b0;

    // =========================================================================
    // Module Instantiations
    // =========================================================================

    v60_regfile #(
        .PIR_VALUE(PIR_VALUE)
    ) u_regfile (
        .clk            (clk),
        .rst_n          (rst_n),
        .rd_addr_a      (rf_rd_addr_a),
        .rd_data_a      (rf_rd_data_a),
        .rd_addr_b      (rf_rd_addr_b),
        .rd_data_b      (rf_rd_data_b),
        .wr_en          (rf_wr_en),
        .wr_addr        (rf_wr_addr),
        .wr_data        (rf_wr_data),
        .wr_size        (rf_wr_size),
        .pc_wr_en       (pc_wr_en),
        .pc_wr_data     (pc_wr_data),
        .pc             (pc),
        .psw_wr_en      (psw_wr_en),
        .psw_wr_data    (psw_wr_data),
        .psw_cc_wr_en   (psw_cc_wr_en),
        .psw_cc_wr_data (psw_cc_wr_data),
        .psw            (psw),
        .preg_wr_en     (preg_wr_en),
        .preg_addr      (preg_addr),
        .preg_wr_data   (preg_wr_data),
        .preg_rd_data   (preg_rd_data),
        .current_sp     (current_sp)
    );

    v60_bus_if #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_bus_if (
        .clk       (clk),
        .rst_n     (rst_n),
        .req_type  (arb_bus_req),
        .req_addr  (arb_bus_addr),
        .req_size  (arb_bus_size),
        .req_wdata (arb_bus_wdata),
        .resp_rdata(bus_if_rdata),
        .resp_valid(bus_if_valid),
        .busy      (bus_if_busy),
        .bus_addr  (bus_addr),
        .bus_rd_n  (bus_rd_n),
        .bus_wr_n  (bus_wr_n),
        .bus_wdata (bus_wdata),
        .bus_rdata (bus_rdata),
        .bus_be    (bus_be),
        .bus_as_n  (bus_as_n),
        .bus_ready (bus_ready)
    );

    v60_fetch_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_fetch (
        .clk              (clk),
        .rst_n            (rst_n),
        .pc               (pc),
        .flush            (fetch_flush),
        .flush_addr       (fetch_flush_addr),
        .bus_req          (fetch_bus_req),
        .bus_addr         (fetch_bus_addr),
        .bus_size         (fetch_bus_size),
        .bus_rdata        (fetch_bus_rdata),
        .bus_valid        (fetch_bus_valid),
        .bus_busy         (fetch_bus_busy),
        .ibuf_data        (ibuf_data),
        .ibuf_valid_count (ibuf_valid_count),
        .consume_count    (fetch_consume_count),
        .consume_valid    (fetch_consume_valid),
        .fetch_active     (fetch_active)
    );

    v60_decode u_decode (
        .ibuf_data        (ibuf_data),
        .ibuf_valid_count (ibuf_valid_count),
        .decoded          (decoded),
        .decode_valid     (decode_valid)
    );

    v60_alu u_alu (
        .op       (alu_op),
        .size     (alu_size),
        .a        (alu_a),
        .b        (alu_b),
        .flags_in (alu_flags_in),
        .result   (alu_result),
        .flag_z   (alu_flag_z),
        .flag_s   (alu_flag_s),
        .flag_ov  (alu_flag_ov),
        .flag_cy  (alu_flag_cy)
    );

    v60_flags u_flags (
        .psw      (psw),
        .cond     (flags_cond),
        .cond_met (flags_cond_met)
    );

    v60_interrupt u_interrupt (
        .clk         (clk),
        .rst_n       (rst_n),
        .nmi_n       (nmi_n),
        .irq_n       (irq_n),
        .psw         (psw),
        .int_ack     (int_ack),
        .int_pending (int_pending),
        .int_vector  (int_vector),
        .is_nmi      (is_nmi)
    );

    v60_control #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_control (
        .clk                 (clk),
        .rst_n               (rst_n),
        .decoded             (decoded),
        .decode_valid        (decode_valid),
        .rf_rd_addr_a        (rf_rd_addr_a),
        .rf_rd_addr_b        (rf_rd_addr_b),
        .rf_rd_data_a        (rf_rd_data_a),
        .rf_rd_data_b        (rf_rd_data_b),
        .rf_wr_en            (rf_wr_en),
        .rf_wr_addr          (rf_wr_addr),
        .rf_wr_data          (rf_wr_data),
        .rf_wr_size          (rf_wr_size),
        .pc_wr_en            (pc_wr_en),
        .pc_wr_data          (pc_wr_data),
        .pc                  (pc),
        .psw_wr_en           (psw_wr_en),
        .psw_wr_data         (psw_wr_data),
        .psw_cc_wr_en        (psw_cc_wr_en),
        .psw_cc_wr_data      (psw_cc_wr_data),
        .psw                 (psw),
        .fetch_flush         (fetch_flush),
        .fetch_flush_addr    (fetch_flush_addr),
        .fetch_consume_count (fetch_consume_count),
        .fetch_consume_valid (fetch_consume_valid),
        .fetch_ibuf_valid_count(ibuf_valid_count),
        .alu_op              (alu_op),
        .alu_size            (alu_size),
        .alu_a               (alu_a),
        .alu_b               (alu_b),
        .alu_flags_in        (alu_flags_in),
        .alu_result          (alu_result),
        .alu_flag_z          (alu_flag_z),
        .alu_flag_s          (alu_flag_s),
        .alu_flag_ov         (alu_flag_ov),
        .alu_flag_cy         (alu_flag_cy),
        .flags_cond          (flags_cond),
        .flags_cond_met      (flags_cond_met),
        .preg_wr_en          (preg_wr_en),
        .preg_addr           (preg_addr),
        .preg_wr_data        (preg_wr_data),
        .preg_rd_data        (preg_rd_data),
        .data_bus_req        (data_bus_req),
        .data_bus_addr       (data_bus_addr),
        .data_bus_size       (data_bus_size),
        .data_bus_wdata      (data_bus_wdata),
        .data_bus_rdata      (data_bus_rdata),
        .data_bus_valid      (data_bus_valid),
        .data_bus_busy       (bus_if_busy),
        .int_pending         (int_pending),
        .int_vector          (int_vector),
        .state_out           (cpu_state),
        .halted              (halted)
    );

endmodule
