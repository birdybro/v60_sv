// v60_regfile.sv — V60 Register File
// 32 GPRs (R0-R31), plus privileged registers accessed via separate port.
// R31 (SP) is cached — the actual stack pointer depends on execution level.

module v60_regfile
    import v60_pkg::*;
#(
    parameter int PIR_VALUE = 32'h00006000
)(
    input  logic        clk,
    input  logic        rst_n,

    // GPR read ports (two simultaneous reads)
    input  logic [4:0]  rd_addr_a,
    output logic [31:0] rd_data_a,
    input  logic [4:0]  rd_addr_b,
    output logic [31:0] rd_data_b,

    // GPR write port
    input  logic        wr_en,
    input  logic [4:0]  wr_addr,
    input  logic [31:0] wr_data,

    // PC
    input  logic        pc_wr_en,
    input  logic [31:0] pc_wr_data,
    output logic [31:0] pc,

    // PSW
    input  logic        psw_wr_en,
    input  logic [31:0] psw_wr_data,
    input  logic        psw_cc_wr_en,       // Write only lower 4 bits (Z,S,OV,CY)
    input  logic [3:0]  psw_cc_wr_data,
    output logic [31:0] psw,

    // Privileged register access (for LDPR/STPR)
    input  logic        preg_wr_en,
    input  logic [4:0]  preg_addr,
    input  logic [31:0] preg_wr_data,
    output logic [31:0] preg_rd_data,

    // Current stack pointer output (based on EL and IS)
    output logic [31:0] current_sp
);

    // =========================================================================
    // General purpose registers
    // =========================================================================
    logic [31:0] gpr [32];

    // =========================================================================
    // Privileged registers
    // =========================================================================
    logic [31:0] isp;           // Interrupt Stack Pointer
    logic [31:0] l0sp;          // Level 0 Stack Pointer
    logic [31:0] l1sp;          // Level 1 Stack Pointer
    logic [31:0] l2sp;          // Level 2 Stack Pointer
    logic [31:0] l3sp;          // Level 3 Stack Pointer
    logic [31:0] sbr;           // System Base Register
    logic [31:0] tr;            // Task Register
    logic [31:0] sycw;          // System Control Word
    logic [31:0] tkcw;          // Task Control Word
    // PIR is read-only, value set by parameter
    logic [31:0] psw2;          // V20/V30 emulation PSW
    logic [31:0] atbr [4];      // Area Table Base Registers
    logic [31:0] atlr [4];      // Area Table Length Registers
    logic [31:0] trmod;         // Trap Mode Register
    logic [31:0] adtr [2];      // Address Trap Registers
    logic [31:0] adtmr [2];     // Address Trap Mask Registers

    // =========================================================================
    // Internal signals
    // =========================================================================
    logic [31:0] pc_reg;
    logic [31:0] psw_reg;

    assign pc  = pc_reg;
    assign psw = psw_reg;

    // Current execution level from PSW
    logic [1:0] el;
    assign el = psw_reg[PSW_EL1:PSW_EL0];

    // Determine current stack pointer based on IS bit and execution level
    always_comb begin
        if (psw_reg[PSW_IS])
            current_sp = isp;
        else begin
            case (el)
                2'b00:   current_sp = l0sp;
                2'b01:   current_sp = l1sp;
                2'b10:   current_sp = l2sp;
                2'b11:   current_sp = l3sp;
                default: current_sp = l0sp;
            endcase
        end
    end

    // =========================================================================
    // GPR reads — R31 returns the current cached SP
    // =========================================================================
    always_comb begin
        rd_data_a = (rd_addr_a == 5'(REG_SP)) ? current_sp : gpr[rd_addr_a];
        rd_data_b = (rd_addr_b == 5'(REG_SP)) ? current_sp : gpr[rd_addr_b];
    end

    // =========================================================================
    // Privileged register read mux
    // =========================================================================
    always_comb begin
        case (preg_addr)
            PREG_ISP[4:0]:    preg_rd_data = isp;
            PREG_L0SP[4:0]:   preg_rd_data = l0sp;
            PREG_L1SP[4:0]:   preg_rd_data = l1sp;
            PREG_L2SP[4:0]:   preg_rd_data = l2sp;
            PREG_L3SP[4:0]:   preg_rd_data = l3sp;
            PREG_SBR[4:0]:    preg_rd_data = sbr;
            PREG_TR[4:0]:     preg_rd_data = tr;
            PREG_SYCW[4:0]:   preg_rd_data = sycw;
            PREG_TKCW[4:0]:   preg_rd_data = tkcw;
            PREG_PIR[4:0]:    preg_rd_data = PIR_VALUE;
            PREG_PSW2[4:0]:   preg_rd_data = psw2;
            PREG_ATBR0[4:0]:  preg_rd_data = atbr[0];
            PREG_ATLR0[4:0]:  preg_rd_data = atlr[0];
            PREG_ATBR1[4:0]:  preg_rd_data = atbr[1];
            PREG_ATLR1[4:0]:  preg_rd_data = atlr[1];
            PREG_ATBR2[4:0]:  preg_rd_data = atbr[2];
            PREG_ATLR2[4:0]:  preg_rd_data = atlr[2];
            PREG_ATBR3[4:0]:  preg_rd_data = atbr[3];
            PREG_ATLR3[4:0]:  preg_rd_data = atlr[3];
            PREG_TRMOD[4:0]:  preg_rd_data = trmod;
            PREG_ADTR0[4:0]:  preg_rd_data = adtr[0];
            PREG_ADTMR0[4:0]: preg_rd_data = adtmr[0];
            PREG_ADTR1[4:0]:  preg_rd_data = adtr[1];
            PREG_ADTMR1[4:0]: preg_rd_data = adtmr[1];
            default:           preg_rd_data = 32'h0;
        endcase
    end

    // =========================================================================
    // Write logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++)
                gpr[i] <= 32'h0;
            pc_reg  <= 32'h0;
            psw_reg <= 32'h0;
            isp     <= 32'h0;
            l0sp    <= 32'h0;
            l1sp    <= 32'h0;
            l2sp    <= 32'h0;
            l3sp    <= 32'h0;
            sbr     <= 32'h0;
            tr      <= 32'h0;
            sycw    <= 32'h0;
            tkcw    <= 32'h0;
            psw2    <= 32'h0;
            trmod   <= 32'h0;
            for (int i = 0; i < 4; i++) begin
                atbr[i] <= 32'h0;
                atlr[i] <= 32'h0;
            end
            for (int i = 0; i < 2; i++) begin
                adtr[i]  <= 32'h0;
                adtmr[i] <= 32'h0;
            end
        end else begin
            // GPR write — writing R31 updates the appropriate stack pointer
            if (wr_en) begin
                if (wr_addr == 5'(REG_SP)) begin
                    if (psw_reg[PSW_IS])
                        isp <= wr_data;
                    else begin
                        case (el)
                            2'b00:   l0sp <= wr_data;
                            2'b01:   l1sp <= wr_data;
                            2'b10:   l2sp <= wr_data;
                            2'b11:   l3sp <= wr_data;
                            default: ;
                        endcase
                    end
                end else begin
                    gpr[wr_addr] <= wr_data;
                end
            end

            // PC write
            if (pc_wr_en)
                pc_reg <= pc_wr_data;

            // PSW write (full word)
            if (psw_wr_en)
                psw_reg <= psw_wr_data;
            else if (psw_cc_wr_en)
                psw_reg[3:0] <= psw_cc_wr_data;

            // Privileged register write
            if (preg_wr_en) begin
                case (preg_addr)
                    PREG_ISP[4:0]:    isp      <= preg_wr_data;
                    PREG_L0SP[4:0]:   l0sp     <= preg_wr_data;
                    PREG_L1SP[4:0]:   l1sp     <= preg_wr_data;
                    PREG_L2SP[4:0]:   l2sp     <= preg_wr_data;
                    PREG_L3SP[4:0]:   l3sp     <= preg_wr_data;
                    PREG_SBR[4:0]:    sbr      <= preg_wr_data;
                    PREG_TR[4:0]:     tr       <= preg_wr_data;
                    PREG_SYCW[4:0]:   sycw     <= preg_wr_data;
                    PREG_TKCW[4:0]:   tkcw     <= preg_wr_data;
                    // PIR is read-only
                    PREG_PSW2[4:0]:   psw2     <= preg_wr_data;
                    PREG_ATBR0[4:0]:  atbr[0]  <= preg_wr_data;
                    PREG_ATLR0[4:0]:  atlr[0]  <= preg_wr_data;
                    PREG_ATBR1[4:0]:  atbr[1]  <= preg_wr_data;
                    PREG_ATLR1[4:0]:  atlr[1]  <= preg_wr_data;
                    PREG_ATBR2[4:0]:  atbr[2]  <= preg_wr_data;
                    PREG_ATLR2[4:0]:  atlr[2]  <= preg_wr_data;
                    PREG_ATBR3[4:0]:  atbr[3]  <= preg_wr_data;
                    PREG_ATLR3[4:0]:  atlr[3]  <= preg_wr_data;
                    PREG_TRMOD[4:0]:  trmod    <= preg_wr_data;
                    PREG_ADTR0[4:0]:  adtr[0]  <= preg_wr_data;
                    PREG_ADTMR0[4:0]: adtmr[0] <= preg_wr_data;
                    PREG_ADTR1[4:0]:  adtr[1]  <= preg_wr_data;
                    PREG_ADTMR1[4:0]: adtmr[1] <= preg_wr_data;
                    default: ;
                endcase
            end
        end
    end

endmodule
