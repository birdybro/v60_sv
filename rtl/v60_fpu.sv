// v60_fpu.sv — Synthesizable IEEE 754 single-precision FPU for V60
// Matches MAME op2.hxx float arithmetic behavior.
// All operations are combinational (single-cycle).

/* verilator lint_off UNUSEDSIGNAL */
module v60_fpu
    import v60_pkg::*;
(
    input  fp_op_t      op,
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [2:0]  rounding,
    output logic [31:0] result,
    output logic        flag_z,
    output logic        flag_s,
    output logic        flag_ov,
    output logic        flag_cy
);

    // =========================================================================
    // IEEE 754 single-precision field extraction
    // =========================================================================
    logic        a_sign, b_sign;
    logic [7:0]  a_exp,  b_exp;
    logic [22:0] a_man,  b_man;

    assign a_sign = a[31];
    assign a_exp  = a[30:23];
    assign a_man  = a[22:0];
    assign b_sign = b[31];
    assign b_exp  = b[30:23];
    assign b_man  = b[22:0];

    // =========================================================================
    // Float-to-integer conversion (for CVTSW)
    // Converts IEEE 754 single to signed 32-bit integer with rounding
    // =========================================================================
    logic [31:0] cvtsw_result;
    logic        cvtsw_sign;
    logic [7:0]  cvtsw_exp;
    logic [22:0] cvtsw_frac;
    logic [31:0] cvtsw_abs;
    logic [7:0]  cvtsw_shift;
    logic [31:0] cvtsw_int_trunc;
    logic        cvtsw_round_bit;
    logic        cvtsw_sticky;
    logic [31:0] cvtsw_rounded;
    logic        cvtsw_is_zero;

    always_comb begin
        cvtsw_sign = a[31];
        cvtsw_exp  = a[30:23];
        cvtsw_frac = a[22:0];
        cvtsw_is_zero = (cvtsw_exp == 8'd0) && (cvtsw_frac == 23'd0);
        cvtsw_abs = 32'd0;
        cvtsw_int_trunc = 32'd0;
        cvtsw_round_bit = 1'b0;
        cvtsw_sticky = 1'b0;
        cvtsw_rounded = 32'd0;

        if (cvtsw_is_zero || cvtsw_exp < 8'd127) begin
            // |value| < 1.0 or zero
            if (!cvtsw_is_zero && cvtsw_exp == 8'd126) begin
                // 0.5 <= |val| < 1.0
                cvtsw_round_bit = 1'b1;
                cvtsw_sticky = (cvtsw_frac != 23'd0);
            end else if (!cvtsw_is_zero && cvtsw_exp > 8'd0) begin
                cvtsw_sticky = 1'b1;
            end
            cvtsw_int_trunc = 32'd0;
        end else begin
            cvtsw_shift = cvtsw_exp - 8'd127; // unbiased exponent (0-30 useful range)
            // Build mantissa with implicit 1: 1.fraction * 2^shift
            // = {1, frac} >> (23 - shift)
            if (cvtsw_shift >= 8'd31) begin
                // Overflow — clamp
                cvtsw_int_trunc = 32'h7FFFFFFF;
            end else if (cvtsw_shift >= 8'd23) begin
                // Shift left: no fractional bits lost
                cvtsw_int_trunc = {9'd0, 1'b1, cvtsw_frac} << (cvtsw_shift - 8'd23);
            end else begin
                // Shift right: some fractional bits
                logic [23:0] full_man;
                logic [7:0]  right_shift;
                full_man = {1'b1, cvtsw_frac};
                right_shift = 8'd23 - cvtsw_shift;
                cvtsw_int_trunc = {8'd0, full_man} >> right_shift;
                // Round bit is the bit just below the integer part
                if (right_shift > 8'd0)
                    cvtsw_round_bit = full_man[right_shift - 1];
                // Sticky is OR of all bits below round bit
                if (right_shift > 8'd1) begin
                    logic [22:0] sticky_mask;
                    sticky_mask = (23'd1 << (right_shift - 8'd1)) - 23'd1;
                    cvtsw_sticky = |(full_man[22:0] & sticky_mask);
                end
            end
        end

        // Apply rounding
        case (rounding)
            3'd0: begin // Round to nearest (ties to even)
                if (cvtsw_round_bit && (cvtsw_sticky || cvtsw_int_trunc[0]))
                    cvtsw_rounded = cvtsw_int_trunc + 32'd1;
                else
                    cvtsw_rounded = cvtsw_int_trunc;
            end
            3'd1: begin // Round toward negative infinity (floor)
                if (cvtsw_sign && (cvtsw_round_bit || cvtsw_sticky))
                    cvtsw_rounded = cvtsw_int_trunc + 32'd1;
                else
                    cvtsw_rounded = cvtsw_int_trunc;
            end
            3'd2: begin // Round toward positive infinity (ceil)
                if (!cvtsw_sign && (cvtsw_round_bit || cvtsw_sticky))
                    cvtsw_rounded = cvtsw_int_trunc + 32'd1;
                else
                    cvtsw_rounded = cvtsw_int_trunc;
            end
            default: begin // Truncate (round toward zero)
                cvtsw_rounded = cvtsw_int_trunc;
            end
        endcase

        // Apply sign
        if (cvtsw_sign)
            cvtsw_result = (~cvtsw_rounded) + 32'd1; // negate
        else
            cvtsw_result = cvtsw_rounded;
    end

    // =========================================================================
    // Integer-to-float conversion (for CVTWS)
    // Converts signed 32-bit integer to IEEE 754 single
    // =========================================================================
    logic [31:0] cvtws_result;
    logic        cvtws_sign;
    logic [31:0] cvtws_abs;
    logic [4:0]  cvtws_lz;    // leading zero count
    logic [31:0] cvtws_norm;
    logic [7:0]  cvtws_exp;
    logic [22:0] cvtws_frac;
    logic        cvtws_round_bit;
    logic        cvtws_sticky_bit;

    // Leading zero counter for 32-bit value
    function automatic logic [4:0] clz32(input logic [31:0] val);
        logic [4:0] cnt;
        cnt = 5'd0;
        for (int i = 31; i >= 0; i--) begin
            if (val[i]) return 5'd31 - 5'(i);
        end
        return 5'd32;
    endfunction

    always_comb begin
        cvtws_sign = a[31];
        cvtws_abs = cvtws_sign ? ((~a) + 32'd1) : a;
        cvtws_lz = clz32(cvtws_abs);
        cvtws_norm = cvtws_abs << cvtws_lz;
        // Exponent: 127 + 31 - lz = 158 - lz
        cvtws_exp = 8'd158 - {3'd0, cvtws_lz};
        // Mantissa: bits [30:8] of normalized value (bit 31 is implicit 1)
        cvtws_frac = cvtws_norm[30:8];
        // Round bit and sticky for round-to-nearest-even
        cvtws_round_bit = cvtws_norm[7];
        cvtws_sticky_bit = |cvtws_norm[6:0];

        if (a == 32'd0) begin
            cvtws_result = 32'd0;
        end else begin
            // Round to nearest even
            if (cvtws_round_bit && (cvtws_sticky_bit || cvtws_frac[0])) begin
                if (cvtws_frac == 23'h7FFFFF) begin
                    // Mantissa overflow: increment exponent
                    cvtws_result = {cvtws_sign, cvtws_exp + 8'd1, 23'd0};
                end else begin
                    cvtws_result = {cvtws_sign, cvtws_exp, cvtws_frac + 23'd1};
                end
            end else begin
                cvtws_result = {cvtws_sign, cvtws_exp, cvtws_frac};
            end
        end
    end

    // =========================================================================
    // Float add/sub core
    // Computes a_val + b_val or a_val - b_val in IEEE 754 single
    // =========================================================================
    logic [31:0] addsub_a, addsub_b;
    logic [31:0] addsub_result;
    logic        addsub_sub; // 1 = subtract

    // Internal signals for add/sub
    // Mantissa format: {implicit_1, frac[22:0]} = 24 bits
    // Sum is 25 bits to capture carry
    logic        as_a_sign, as_b_sign;
    logic [7:0]  as_a_exp, as_b_exp;
    logic [23:0] as_a_man, as_b_man;
    logic        as_swap;
    logic [7:0]  as_exp_diff;
    logic [7:0]  as_big_exp;
    logic [23:0] as_big_man, as_small_man;
    logic        as_big_sign, as_small_sign;
    logic        as_eff_sub;
    logic [24:0] as_sum;
    logic        as_res_sign;
    logic [7:0]  as_res_exp;
    logic [22:0] as_res_frac;
    logic [4:0]  as_norm_shift;

    function automatic logic [4:0] clz25(input logic [24:0] val);
        for (int i = 24; i >= 0; i--) begin
            if (val[i]) return 5'd24 - 5'(i);
        end
        return 5'd25;
    endfunction

    always_comb begin
        as_a_sign = addsub_a[31] ^ addsub_sub; // flip a's sign for b - a
        as_b_sign = addsub_b[31];
        as_a_exp = addsub_a[30:23];
        as_b_exp = addsub_b[30:23];
        // 24-bit mantissa: {implicit_1, frac[22:0]}
        as_a_man = (as_a_exp != 8'd0) ? {1'b1, addsub_a[22:0]} : {1'b0, addsub_a[22:0]};
        as_b_man = (as_b_exp != 8'd0) ? {1'b1, addsub_b[22:0]} : {1'b0, addsub_b[22:0]};

        // Ensure big has larger exponent (or larger mantissa if equal exp)
        as_swap = (as_b_exp > as_a_exp) || (as_b_exp == as_a_exp && as_b_man > as_a_man);
        if (as_swap) begin
            as_big_exp = as_b_exp;
            as_big_man = as_b_man;  as_small_man = as_a_man;
            as_big_sign = as_b_sign; as_small_sign = as_a_sign;
        end else begin
            as_big_exp = as_a_exp;
            as_big_man = as_a_man;  as_small_man = as_b_man;
            as_big_sign = as_a_sign; as_small_sign = as_b_sign;
        end

        as_exp_diff = as_big_exp - (as_swap ? as_a_exp : as_b_exp);
        if (as_exp_diff > 8'd24)
            as_small_man = 24'd0;
        else
            as_small_man = as_small_man >> as_exp_diff;

        as_eff_sub = as_big_sign ^ as_small_sign;

        if (as_eff_sub)
            as_sum = {1'b0, as_big_man} - {1'b0, as_small_man};
        else
            as_sum = {1'b0, as_big_man} + {1'b0, as_small_man};

        as_res_sign = as_big_sign;
        as_res_exp = as_big_exp;
        as_res_frac = 23'd0;
        as_norm_shift = 5'd0;

        if (as_sum == 25'd0) begin
            addsub_result = 32'd0;
        end else begin
            if (as_sum[24]) begin
                // Carry out: shift right 1, increment exponent
                // sum = {1, bit23..bit0} → frac = sum[23:1], round with sum[0]
                as_res_frac = as_sum[23:1];
                if (as_sum[0] && as_sum[1]) // round to nearest even (simplified)
                    as_res_frac = as_res_frac + 23'd1;
                as_res_exp = as_big_exp + 8'd1;
            end else if (as_sum[23]) begin
                // Normalized: implicit 1 at bit 23
                as_res_frac = as_sum[22:0];
                // No rounding needed (no bits lost)
            end else begin
                // Sub-normal result from subtraction: normalize left
                as_norm_shift = clz25(as_sum);
                // as_norm_shift >= 2 means the leading 1 is at position 23-as_norm_shift+1
                // We need to shift left by (as_norm_shift - 1) to put bit at position 23
                if (as_norm_shift <= 5'd1) begin
                    as_res_frac = as_sum[22:0];
                    as_res_exp = as_big_exp;
                end else begin
                    logic [24:0] shifted;
                    shifted = as_sum << (as_norm_shift - 5'd1);
                    as_res_frac = shifted[22:0];
                    if ({3'd0, as_norm_shift} > {1'b0, as_big_exp})
                        as_res_exp = 8'd0;
                    else
                        as_res_exp = as_big_exp - {3'd0, as_norm_shift} + 8'd1;
                end
            end

            if (as_res_exp == 8'd0)
                addsub_result = 32'd0;
            else
                addsub_result = {as_res_sign, as_res_exp, as_res_frac};
        end

        if (addsub_a[30:0] == 31'd0 && addsub_b[30:0] == 31'd0)
            addsub_result = 32'd0;
    end

    // =========================================================================
    // Float multiply
    // =========================================================================
    logic [31:0] mul_result;
    logic        mul_a_sign, mul_b_sign, mul_res_sign;
    logic [7:0]  mul_a_exp, mul_b_exp;
    logic [23:0] mul_a_man, mul_b_man;
    logic [47:0] mul_product;
    logic [8:0]  mul_exp_sum;
    logic [7:0]  mul_res_exp;
    logic [22:0] mul_res_frac;

    always_comb begin
        mul_a_sign = a[31];
        mul_b_sign = b[31];
        mul_res_sign = mul_a_sign ^ mul_b_sign;
        mul_a_exp = a[30:23];
        mul_b_exp = b[30:23];
        mul_a_man = {1'b1, a[22:0]};
        mul_b_man = {1'b1, b[22:0]};

        mul_product = {24'd0, mul_a_man} * {24'd0, mul_b_man}; // 48-bit product
        mul_exp_sum = {1'b0, mul_a_exp} + {1'b0, mul_b_exp} - 9'd127;

        mul_res_exp = 8'd0;
        mul_res_frac = 23'd0;

        if (a[30:0] == 31'd0 || b[30:0] == 31'd0) begin
            mul_result = 32'd0;
        end else begin
            if (mul_product[47]) begin
                // Normalize: shift right 1
                mul_res_frac = mul_product[46:24];
                // Round
                if (mul_product[23] && (mul_product[22:0] != 23'd0 || mul_product[24]))
                    mul_res_frac = mul_res_frac + 23'd1;
                mul_exp_sum = mul_exp_sum + 9'd1;
            end else begin
                mul_res_frac = mul_product[45:23];
                if (mul_product[22] && (mul_product[21:0] != 22'd0 || mul_product[23]))
                    mul_res_frac = mul_res_frac + 23'd1;
            end

            if (mul_exp_sum[8] || mul_exp_sum == 9'd0)
                mul_result = 32'd0; // underflow
            else if (mul_exp_sum >= 9'd255)
                mul_result = {mul_res_sign, 8'hFF, 23'd0}; // overflow → infinity
            else begin
                mul_res_exp = mul_exp_sum[7:0];
                mul_result = {mul_res_sign, mul_res_exp, mul_res_frac};
            end
        end
    end

    // =========================================================================
    // Float divide
    // =========================================================================
    logic [31:0] div_result;
    logic        div_res_sign;
    logic [7:0]  div_a_exp, div_b_exp;
    logic [23:0] div_a_man, div_b_man;
    logic [49:0] div_dividend;
    logic [49:0] div_quotient_full;
    logic [8:0]  div_exp;
    logic [22:0] div_res_frac;

    always_comb begin
        // DIVF computes b / a (matches MAME: u2f(ub) / u2f(ua))
        div_res_sign = a[31] ^ b[31];
        div_a_exp = a[30:23]; // divisor
        div_b_exp = b[30:23]; // dividend
        div_a_man = {1'b1, a[22:0]}; // divisor mantissa
        div_b_man = {1'b1, b[22:0]}; // dividend mantissa

        // Shift dividend (b) left for precision, divide by divisor (a)
        div_dividend = {2'b0, div_b_man, 24'd0};
        if (div_a_man != 24'd0)
            div_quotient_full = div_dividend / {26'd0, div_a_man};
        else
            div_quotient_full = 50'd0;

        div_exp = {1'b0, div_b_exp} - {1'b0, div_a_exp} + 9'd127;
        div_res_frac = 23'd0;

        if (b[30:0] == 31'd0) begin
            div_result = 32'd0; // 0 / x = 0
        end else if (a[30:0] == 31'd0) begin
            div_result = {div_res_sign, 8'hFF, 23'd0}; // x / 0 = inf
        end else begin
            // Quotient is in ~[24:1] range, normalize
            if (div_quotient_full[25]) begin
                div_res_frac = div_quotient_full[24:2];
                if (div_quotient_full[1] && (div_quotient_full[0] || div_quotient_full[2]))
                    div_res_frac = div_res_frac + 23'd1;
                div_exp = div_exp + 9'd1;
            end else if (div_quotient_full[24]) begin
                div_res_frac = div_quotient_full[23:1];
                if (div_quotient_full[0] && div_quotient_full[1])
                    div_res_frac = div_res_frac + 23'd1;
            end else begin
                // Shift up to normalize
                div_res_frac = div_quotient_full[22:0];
                if (div_exp > 9'd0)
                    div_exp = div_exp - 9'd1;
            end

            if (div_exp[8] || div_exp == 9'd0)
                div_result = 32'd0;
            else if (div_exp >= 9'd255)
                div_result = {div_res_sign, 8'hFF, 23'd0};
            else
                div_result = {div_res_sign, div_exp[7:0], div_res_frac};
        end
    end

    // =========================================================================
    // SCLF: scale float by integer power of 2
    // =========================================================================
    logic [31:0] sclf_result;
    logic signed [15:0] sclf_count;
    logic [7:0]  sclf_exp;
    logic signed [16:0] sclf_new_exp;

    always_comb begin
        sclf_count = $signed(a[15:0]);
        sclf_exp = b[30:23];
        sclf_new_exp = {1'b0, 8'(sclf_exp)} + {{1{sclf_count[15]}}, sclf_count};

        if (b[30:0] == 31'd0) begin
            sclf_result = 32'd0;
        end else if (sclf_new_exp <= 17'sd0) begin
            sclf_result = 32'd0; // underflow
        end else if (sclf_new_exp >= 17'sd255) begin
            sclf_result = {b[31], 8'hFF, 23'd0}; // overflow → infinity
        end else begin
            sclf_result = {b[31], sclf_new_exp[7:0], b[22:0]};
        end
    end

    // =========================================================================
    // Main output mux
    // =========================================================================
    always_comb begin
        result  = 32'd0;
        flag_z  = 1'b0;
        flag_s  = 1'b0;
        flag_ov = 1'b0;
        flag_cy = 1'b0;

        addsub_a = a;
        addsub_b = b;
        addsub_sub = 1'b0;

        case (op)
            FP_CMPF: begin
                // Compare: b - a, set flags only
                addsub_a = a;
                addsub_b = b;
                addsub_sub = 1'b1;
                result = 32'd0;
                flag_z = (addsub_result == 32'd0);
                flag_s = addsub_result[31];
            end

            FP_MOVF: begin
                result = a;
            end

            FP_NEGF: begin
                result = {~a[31], a[30:0]};
                flag_z = (a[30:0] == 31'd0);
                flag_s = result[31];
                flag_cy = result[31];
            end

            FP_ABSF: begin
                result = {1'b0, a[30:0]};
                flag_z = (a[30:0] == 31'd0);
                flag_s = 1'b0;
            end

            FP_SCLF: begin
                result = sclf_result;
                flag_z = (sclf_result == 32'd0);
                flag_s = sclf_result[31];
            end

            FP_ADDF: begin
                addsub_a = a;
                addsub_b = b;
                addsub_sub = 1'b0;
                result = addsub_result;
                flag_z = (addsub_result == 32'd0);
                flag_s = addsub_result[31];
            end

            FP_SUBF: begin
                // b - a
                addsub_a = a;
                addsub_b = b;
                addsub_sub = 1'b1;
                result = addsub_result;
                flag_z = (addsub_result == 32'd0);
                flag_s = addsub_result[31];
            end

            FP_MULF: begin
                result = mul_result;
                flag_z = (mul_result == 32'd0);
                flag_s = mul_result[31];
            end

            FP_DIVF: begin
                result = div_result;
                flag_z = (div_result == 32'd0);
                flag_s = div_result[31];
            end

            FP_CVTWS: begin
                result = cvtws_result;
                flag_z = (cvtws_result == 32'd0);
                flag_s = cvtws_result[31];
                flag_cy = cvtws_result[31]; // negative
            end

            FP_CVTSW: begin
                result = cvtsw_result;
                flag_z = (cvtsw_result == 32'd0);
                flag_s = cvtsw_result[31];
                flag_ov = (cvtsw_result[31] && !cvtsw_sign) ||
                          (!cvtsw_result[31] && cvtsw_sign && cvtsw_result != 32'd0);
            end

            default: begin
                result = 32'd0;
            end
        endcase
    end

endmodule
