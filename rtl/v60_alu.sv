// v60_alu.sv — Combinational ALU
// Performs arithmetic, logic, shift, and rotate operations.
// Phase 1 skeleton: ADD, SUB, AND, OR, XOR, NOT, NEG, MOV, CMP, INC, DEC, NOP

module v60_alu
    import v60_pkg::*;
(
    input  alu_op_t     op,
    input  data_size_t  size,
    input  logic [31:0] a,          // Source operand
    input  logic [31:0] b,          // Destination operand (also receives result for 2-op)
    input  logic        carry_in,   // PSW.CY for ADDC/SUBC/ROTC

    output logic [31:0] result,
    output logic        flag_z,     // Zero
    output logic        flag_s,     // Sign
    output logic        flag_ov,    // Overflow
    output logic        flag_cy     // Carry
);

    // Sized operand masks
    logic [31:0] mask;
    logic [4:0]  msb_pos;
    logic [32:0] sum;  // 33-bit for carry detection

    always_comb begin
        case (size)
            SZ_BYTE: begin mask = 32'h000000FF; msb_pos = 5'd7;  end
            SZ_HALF: begin mask = 32'h0000FFFF; msb_pos = 5'd15; end
            SZ_WORD: begin mask = 32'hFFFFFFFF; msb_pos = 5'd31; end
            default: begin mask = 32'hFFFFFFFF; msb_pos = 5'd31; end
        endcase
    end

    logic [31:0] a_sized, b_sized;
    assign a_sized = a & mask;
    assign b_sized = b & mask;

    // ALU core
    always_comb begin
        result  = 32'h0;
        flag_z  = 1'b0;
        flag_s  = 1'b0;
        flag_ov = 1'b0;
        flag_cy = 1'b0;
        sum     = 33'h0;

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
                flag_cy = sum[msb_pos + 1];  // Borrow
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

            ALU_NOP: begin
                result = a;
            end

            default: begin
                result = a;
            end
        endcase

        // Common flag computation for all ops (except NOP)
        if (op != ALU_NOP) begin
            flag_z = (result == 32'h0);
            flag_s = result[msb_pos];
        end
    end

endmodule
