// v60_alu.sv — Combinational ALU
// Phase 7: ADD, SUB, CMP, AND, OR, XOR, NOT, NEG, MOV, INC, DEC,
//          ADDC, SUBC, MUL, MULU, DIV, DIVU, REM, REMU,
//          SHL, SHA, ROT, ROTC, SET1, CLR1, NOT1, TEST1

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
module v60_alu
    import v60_pkg::*;
(
    input  alu_op_t     op,
    input  data_size_t  size,
    input  logic [31:0] a,          // Source operand (op1 in MAME)
    input  logic [31:0] b,          // Destination operand (op2 in MAME)
    input  logic [3:0]  flags_in,   // PSW[3:0] = {CY, OV, S, Z}

    output logic [31:0] result,
    output logic        flag_z,     // Zero
    output logic        flag_s,     // Sign
    output logic        flag_ov,    // Overflow
    output logic        flag_cy     // Carry
);

    // Sized operand masks
    logic [31:0] mask;
    logic [4:0]  msb_pos;
    logic [32:0] sum;
    logic [5:0]  bitsize;

    always_comb begin
        case (size)
            SZ_BYTE: begin mask = 32'h000000FF; msb_pos = 5'd7;  bitsize = 6'd8;  end
            SZ_HALF: begin mask = 32'h0000FFFF; msb_pos = 5'd15; bitsize = 6'd16; end
            SZ_WORD: begin mask = 32'hFFFFFFFF; msb_pos = 5'd31; bitsize = 6'd32; end
            default: begin mask = 32'hFFFFFFFF; msb_pos = 5'd31; bitsize = 6'd32; end
        endcase
    end

    logic [31:0] a_sized, b_sized;
    assign a_sized = a & mask;
    assign b_sized = b & mask;

    // Carry-in from PSW
    logic carry_in;
    assign carry_in = flags_in[3];

    // Sign-extended operands for signed operations
    logic signed [31:0] a_sext, b_sext;
    always_comb begin
        case (size)
            SZ_BYTE: begin a_sext = {{24{a[7]}},  a[7:0]};  b_sext = {{24{b[7]}},  b[7:0]};  end
            SZ_HALF: begin a_sext = {{16{a[15]}}, a[15:0]}; b_sext = {{16{b[15]}}, b[15:0]}; end
            default: begin a_sext = a;                        b_sext = b;                        end
        endcase
    end

    // Hoisted working variables
    logic signed [63:0] mul_s_product;
    logic        [63:0] mul_u_product;
    logic signed [7:0]  shift_count;
    logic [7:0]         abs_count;
    logic [4:0]         bit_idx;
    logic [31:0]        rot_val;
    logic               rot_cy;
    logic               old_cy;
    logic [31:0]        shl_tmp32;
    logic [63:0]        shl_tmp64;
    logic [31:0]        ov_mask;
    logic signed [31:0] sha_tmp;

    // ALU core
    always_comb begin
        result  = 32'h0;
        flag_z  = 1'b0;
        flag_s  = 1'b0;
        flag_ov = 1'b0;
        flag_cy = 1'b0;
        sum     = 33'h0;
        mul_s_product = 64'h0;
        mul_u_product = 64'h0;
        shift_count = 8'h0;
        abs_count   = 8'h0;
        bit_idx     = 5'd0;
        rot_val     = 32'h0;
        rot_cy      = 1'b0;
        old_cy      = 1'b0;
        shl_tmp32   = 32'h0;
        shl_tmp64   = 64'h0;
        ov_mask     = 32'h0;
        sha_tmp     = 32'sh0;

        case (op)
            ALU_ADD: begin
                sum     = {1'b0, b_sized} + {1'b0, a_sized};
                result  = sum[31:0] & mask;
                flag_cy = sum[msb_pos + 1];
                flag_ov = (a_sized[msb_pos] == b_sized[msb_pos]) &&
                          (result[msb_pos] != a_sized[msb_pos]);
            end

            ALU_ADDC: begin
                sum     = {1'b0, b_sized} + {1'b0, a_sized} + {32'h0, carry_in};
                result  = sum[31:0] & mask;
                flag_cy = sum[msb_pos + 1];
                flag_ov = (a_sized[msb_pos] == b_sized[msb_pos]) &&
                          (result[msb_pos] != a_sized[msb_pos]);
            end

            ALU_SUB, ALU_CMP: begin
                sum     = {1'b0, b_sized} - {1'b0, a_sized};
                result  = sum[31:0] & mask;
                flag_cy = sum[msb_pos + 1];
                flag_ov = (a_sized[msb_pos] != b_sized[msb_pos]) &&
                          (result[msb_pos] != b_sized[msb_pos]);
            end

            ALU_SUBC: begin
                sum     = {1'b0, b_sized} - {1'b0, a_sized} - {32'h0, carry_in};
                result  = sum[31:0] & mask;
                flag_cy = sum[msb_pos + 1];
                flag_ov = (a_sized[msb_pos] != b_sized[msb_pos]) &&
                          (result[msb_pos] != b_sized[msb_pos]);
            end

            ALU_AND: begin
                result = a_sized & b_sized;
            end

            ALU_OR: begin
                result = a_sized | b_sized;
            end

            ALU_XOR: begin
                result = a_sized ^ b_sized;
            end

            ALU_NOT: begin
                result = (~a_sized) & mask;
            end

            ALU_NEG: begin
                sum     = {1'b0, 32'h0} - {1'b0, a_sized};
                result  = sum[31:0] & mask;
                flag_cy = (a_sized != 0);
                flag_ov = (a_sized[msb_pos] && result[msb_pos]);
            end

            ALU_MOV: begin
                result = a_sized;
            end

            ALU_INC: begin
                sum     = {1'b0, a_sized} + 33'h1;
                result  = sum[31:0] & mask;
                flag_cy = sum[msb_pos + 1];
                flag_ov = (!a_sized[msb_pos]) && result[msb_pos] &&
                          (a_sized == (mask >> 1));
            end

            ALU_DEC: begin
                sum     = {1'b0, a_sized} - 33'h1;
                result  = sum[31:0] & mask;
                flag_cy = sum[msb_pos + 1];
                flag_ov = a_sized[msb_pos] && (!result[msb_pos]);
            end

            // =================================================================
            // MUL (signed multiply)
            // MAME: tmp = (signed)b * (signed)a; OV = (tmp >> bitsize) != 0
            // =================================================================
            ALU_MUL: begin
                mul_s_product = $signed({{32{a_sext[31]}}, a_sext}) *
                                $signed({{32{b_sext[31]}}, b_sext});
                result  = mul_s_product[31:0] & mask;
                flag_cy = carry_in;
                case (size)
                    SZ_BYTE: flag_ov = (mul_s_product[63:8]  != 56'h0);
                    SZ_HALF: flag_ov = (mul_s_product[63:16] != 48'h0);
                    default: flag_ov = (mul_s_product[63:32] != 32'h0);
                endcase
            end

            // =================================================================
            // MULU (unsigned multiply)
            // =================================================================
            ALU_MULU: begin
                mul_u_product = {32'h0, a_sized} * {32'h0, b_sized};
                result  = mul_u_product[31:0] & mask;
                flag_cy = carry_in;
                case (size)
                    SZ_BYTE: flag_ov = (mul_u_product[63:8]  != 56'h0);
                    SZ_HALF: flag_ov = (mul_u_product[63:16] != 48'h0);
                    default: flag_ov = (mul_u_product[63:32] != 32'h0);
                endcase
            end

            // =================================================================
            // DIV (signed divide)
            // =================================================================
            ALU_DIV: begin
                flag_cy = carry_in;
                case (size)
                    SZ_BYTE: flag_ov = (b_sized[7:0]  == 8'h80)    && (a_sized[7:0]  == 8'hFF);
                    SZ_HALF: flag_ov = (b_sized[15:0] == 16'h8000) && (a_sized[15:0] == 16'hFFFF);
                    default: flag_ov = (b_sized == 32'h80000000)    && (a_sized == 32'hFFFFFFFF);
                endcase
                if (a_sized != 0 && !flag_ov)
                    result = ($signed(b_sext) / $signed(a_sext)) & mask;
                else
                    result = b_sized;
            end

            // =================================================================
            // DIVU (unsigned divide)
            // =================================================================
            ALU_DIVU: begin
                flag_cy = carry_in;
                flag_ov = 1'b0;
                if (a_sized != 0)
                    result = (b_sized / a_sized) & mask;
                else
                    result = b_sized;
            end

            // =================================================================
            // REM (signed remainder)
            // =================================================================
            ALU_REM: begin
                flag_cy = carry_in;
                flag_ov = 1'b0;
                if (a_sized != 0)
                    result = ($signed(b_sext) % $signed(a_sext)) & mask;
                else
                    result = b_sized;
            end

            // =================================================================
            // REMU (unsigned remainder)
            // =================================================================
            ALU_REMU: begin
                flag_cy = carry_in;
                flag_ov = 1'b0;
                if (a_sized != 0)
                    result = (b_sized % a_sized) & mask;
                else
                    result = b_sized;
            end

            // =================================================================
            // SHL (logical shift)
            // Source is signed byte count: positive=left, negative=right
            // =================================================================
            ALU_SHL: begin
                shift_count = a[7:0];
                if ($signed(shift_count) > 0) begin
                    flag_ov = 1'b0;
                    case (size)
                        SZ_BYTE: begin
                            shl_tmp32 = {24'h0, b_sized[7:0]} << shift_count;
                            flag_cy = shl_tmp32[8];
                            result  = shl_tmp32[7:0];
                        end
                        SZ_HALF: begin
                            shl_tmp32 = {16'h0, b_sized[15:0]} << shift_count;
                            flag_cy = shl_tmp32[16];
                            result  = shl_tmp32[15:0];
                        end
                        default: begin
                            shl_tmp64 = {32'h0, b_sized} << shift_count;
                            flag_cy = shl_tmp64[32];
                            result  = shl_tmp64[31:0];
                        end
                    endcase
                end else if (shift_count == 8'h0) begin
                    flag_cy = 1'b0;
                    flag_ov = 1'b0;
                    result  = b_sized;
                end else begin
                    abs_count = -shift_count;
                    flag_ov = 1'b0;
                    // MAME: tmp = val >> (count - 1); CY = tmp & 1
                    shl_tmp32 = b_sized >> (abs_count - 8'd1);
                    flag_cy = shl_tmp32[0];
                    result  = (b_sized >> abs_count) & mask;
                end
            end

            // =================================================================
            // SHA (arithmetic shift)
            // =================================================================
            ALU_SHA: begin
                shift_count = a[7:0];
                if (shift_count == 8'h0) begin
                    flag_cy = 1'b0;
                    flag_ov = 1'b0;
                    result  = b_sized;
                end else if ($signed(shift_count) > 0) begin
                    // Left arithmetic shift
                    // CY: SHIFTLEFT_CY = (val >> (bitsize - count)) & 1
                    flag_cy = b_sized[bitsize[4:0] - {2'b0, shift_count[5:0]}];
                    // OV: SHIFTLEFT_OV macro
                    if ({2'b0, shift_count[5:0]} >= bitsize)
                        ov_mask = 32'hFFFFFFFF;
                    else
                        ov_mask = ((32'h1 << shift_count) - 32'h1) << (bitsize[4:0] - {2'b0, shift_count[5:0]});
                    if (b_sized[msb_pos])
                        flag_ov = ((b_sized & ov_mask) != ov_mask);
                    else
                        flag_ov = ((b_sized & ov_mask) != 32'h0);
                    // Actual shift
                    if ({2'b0, shift_count[5:0]} >= bitsize)
                        result = 32'h0;
                    else
                        result = (b_sized << shift_count) & mask;
                end else begin
                    // Right arithmetic shift
                    abs_count = -shift_count;
                    flag_ov = 1'b0;
                    // CY: (val >> (count - 1)) & 1
                    flag_cy = b_sized[abs_count - 8'd1];
                    if ({2'b0, abs_count[5:0]} >= bitsize)
                        result = b_sized[msb_pos] ? mask : 32'h0;
                    else begin
                        sha_tmp = b_sext >>> abs_count;
                        result = sha_tmp & mask;
                    end
                end
            end

            // =================================================================
            // ROT (rotate without carry)
            // Iterative loop matching MAME behavior
            // =================================================================
            ALU_ROT: begin
                shift_count = a[7:0];
                flag_ov = 1'b0;
                rot_val = b_sized;
                if ($signed(shift_count) > 0) begin
                    for (int i = 0; i < 128; i++) begin
                        if (i[7:0] < shift_count)
                            rot_val = ((rot_val << 1) | {31'h0, rot_val[msb_pos]}) & mask;
                    end
                    result  = rot_val;
                    flag_cy = rot_val[0];
                end else if (shift_count == 8'h0) begin
                    flag_cy = 1'b0;
                    result  = b_sized;
                end else begin
                    abs_count = -shift_count;
                    for (int i = 0; i < 128; i++) begin
                        if (i < {24'd0, abs_count})
                            rot_val = ((rot_val >> 1) | ({31'h0, rot_val[0]} << msb_pos)) & mask;
                    end
                    result  = rot_val;
                    flag_cy = rot_val[msb_pos];
                end
            end

            // =================================================================
            // ROTC (rotate through carry)
            // Carry participates in the rotation ring
            // =================================================================
            ALU_ROTC: begin
                shift_count = a[7:0];
                flag_ov = 1'b0;
                rot_val = b_sized;
                rot_cy  = carry_in;
                if ($signed(shift_count) > 0) begin
                    for (int i = 0; i < 128; i++) begin
                        if (i[7:0] < shift_count) begin
                            old_cy  = rot_cy;
                            rot_cy  = rot_val[msb_pos];
                            rot_val = ((rot_val << 1) | {31'h0, old_cy}) & mask;
                        end
                    end
                    result  = rot_val;
                    flag_cy = rot_cy;
                end else if (shift_count == 8'h0) begin
                    flag_cy = 1'b0;
                    result  = b_sized;
                end else begin
                    abs_count = -shift_count;
                    for (int i = 0; i < 128; i++) begin
                        if (i < {24'd0, abs_count}) begin
                            old_cy  = rot_cy;
                            rot_cy  = rot_val[0];
                            rot_val = ((rot_val >> 1) | ({31'h0, old_cy} << msb_pos)) & mask;
                        end
                    end
                    result  = rot_val;
                    flag_cy = rot_cy;
                end
            end

            // =================================================================
            // Bit operations (word only)
            // =================================================================
            ALU_SET1: begin
                bit_idx = a[4:0];
                flag_cy = b[bit_idx];
                flag_z  = !flag_cy;
                flag_s  = flags_in[1];
                flag_ov = flags_in[2];
                result  = b | (32'h1 << bit_idx);
            end

            ALU_CLR1: begin
                bit_idx = a[4:0];
                flag_cy = b[bit_idx];
                flag_z  = !flag_cy;
                flag_s  = flags_in[1];
                flag_ov = flags_in[2];
                result  = b & ~(32'h1 << bit_idx);
            end

            ALU_NOT1: begin
                bit_idx = a[4:0];
                flag_cy = b[bit_idx];
                flag_z  = !flag_cy;
                flag_s  = flags_in[1];
                flag_ov = flags_in[2];
                result  = b ^ (32'h1 << bit_idx);
            end

            ALU_TEST1: begin
                bit_idx = a[4:0];
                flag_cy = b[bit_idx];
                flag_z  = !flag_cy;
                flag_s  = flags_in[1];
                flag_ov = flags_in[2];
                result  = b;
            end

            ALU_RVBIT: begin
                result = {24'h0, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]};
            end

            ALU_RVBYT: begin
                result = {a[7:0], a[15:8], a[23:16], a[31:24]};
            end

            ALU_NOP: begin
                result = a;
            end

            default: begin
                result = a;
            end
        endcase

        // Common Z/S flag computation (skip for NOP, bit ops, RVBIT, RVBYT)
        if (op != ALU_NOP &&
            op != ALU_SET1 && op != ALU_CLR1 &&
            op != ALU_NOT1 && op != ALU_TEST1 &&
            op != ALU_RVBIT && op != ALU_RVBYT) begin
            flag_z = (result == 32'h0);
            flag_s = result[msb_pos];
        end
    end

endmodule
