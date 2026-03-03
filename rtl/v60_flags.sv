// v60_flags.sv — Flag computation helpers
// Evaluates branch conditions from PSW flags

module v60_flags
    import v60_pkg::*;
(
    input  logic [31:0] psw,
    input  logic [3:0]  cond,
    output logic        cond_met
);

    logic z, s, ov, cy;
    assign z  = psw[PSW_Z];
    assign s  = psw[PSW_S];
    assign ov = psw[PSW_OV];
    assign cy = psw[PSW_CY];

    always_comb begin
        case (cond)
            CC_BV:   cond_met = ov;
            CC_BNV:  cond_met = ~ov;
            CC_BL:   cond_met = cy;
            CC_BNL:  cond_met = ~cy;
            CC_BE:   cond_met = z;
            CC_BNE:  cond_met = ~z;
            CC_BNH:  cond_met = cy | z;
            CC_BH:   cond_met = ~cy & ~z;
            CC_BN:   cond_met = s;
            CC_BP:   cond_met = ~s;
            CC_BR:   cond_met = 1'b1;   // Always
            CC_NOP:  cond_met = 1'b0;   // Never
            CC_BLT:  cond_met = s ^ ov;
            CC_BGE:  cond_met = ~(s ^ ov);
            CC_BLE:  cond_met = (s ^ ov) | z;
            CC_BGT:  cond_met = ~((s ^ ov) | z);
            default: cond_met = 1'b0;
        endcase
    end

endmodule
