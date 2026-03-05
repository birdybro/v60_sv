// v60_interrupt.sv — Interrupt/exception handler (skeleton)
// Phase 1: Priority encoder and pending flag only.
// Full interrupt entry/exit sequence in Phase 9.

module v60_interrupt
    import v60_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // External interrupt inputs
    input  logic        nmi_n,       // Non-maskable interrupt (active low)
    input  logic [3:0]  irq_n,       // Maskable interrupts (active low)

    // PSW for mask checking
    input  logic [31:0] psw,

    // Interrupt acknowledge from control FSM
    input  logic        int_ack,

    // Outputs to control FSM
    output logic        int_pending,
    output logic [7:0]  int_vector,
    output logic        is_nmi
);

    // Edge detect for NMI
    logic nmi_prev;
    logic nmi_edge;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            nmi_prev <= 1'b1;
        else
            nmi_prev <= nmi_n;
    end

    assign nmi_edge = nmi_prev & ~nmi_n;  // Falling edge

    // NMI pending latch
    logic nmi_pending;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            nmi_pending <= 1'b0;
        else if (nmi_edge)
            nmi_pending <= 1'b1;
        else if (int_ack && is_nmi)
            nmi_pending <= 1'b0;
    end

    // Maskable interrupt pending (active low inputs, masked by PSW.ID)
    logic [3:0] irq_active;
    assign irq_active = ~irq_n;  // Convert to active high

    logic irq_enabled;
    assign irq_enabled = psw[PSW_ID];  // Interrupts enabled when IE=1 (MAME: PSW & (1<<18))

    logic irq_any;
    assign irq_any = irq_enabled && (irq_active != 4'h0);

    // Priority: NMI > IRQ3 > IRQ2 > IRQ1 > IRQ0
    always_comb begin
        int_pending = 1'b0;
        int_vector  = 8'h00;
        is_nmi      = 1'b0;

        if (nmi_pending) begin
            int_pending = 1'b1;
            int_vector  = 8'h02;  // NMI vector
            is_nmi      = 1'b1;
        end else if (irq_any) begin
            int_pending = 1'b1;
            if (irq_active[3])      int_vector = 8'h1F;  // IRQ3
            else if (irq_active[2]) int_vector = 8'h1E;  // IRQ2
            else if (irq_active[1]) int_vector = 8'h1D;  // IRQ1
            else                    int_vector = 8'h1C;  // IRQ0
        end
    end

endmodule
