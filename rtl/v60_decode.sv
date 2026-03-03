// v60_decode.sv — Instruction decoder
// Phase 1: Decodes NOP (0xCD), HALT (0x00), Bcc/BR (0x60-0x7F)
// Combinational decode from fetch buffer window

module v60_decode
    import v60_pkg::*;
(
    // Fetch buffer window (8 bytes visible)
    input  logic [7:0]  ibuf_data [FETCH_WINDOW],
    input  logic [4:0]  ibuf_valid_count,

    // Decoded instruction output
    output decoded_inst_t decoded,
    output logic          decode_valid  // Enough bytes available to decode
);

    // First byte is always the opcode
    logic [7:0] opcode;
    assign opcode = ibuf_data[0];

    // Branch displacement extraction
    logic [7:0]  disp8;
    logic [15:0] disp16;
    assign disp8  = ibuf_data[1];
    assign disp16 = {ibuf_data[2], ibuf_data[1]};  // Little-endian

    // Decode logic
    always_comb begin
        // Default: unknown instruction
        decoded = '0;
        decoded.opcode    = opcode;
        decoded.format    = FMT_V;
        decoded.alu_op    = ALU_NOP;
        decoded.data_size = SZ_WORD;
        decoded.am_src    = AM_ERROR;
        decoded.am_dst    = AM_ERROR;
        decoded.inst_len  = 6'd1;
        decode_valid      = (ibuf_valid_count >= 5'd1);

        // Priority decode: specific opcodes first, then wildcard ranges
        // Using if/else chain instead of casez to avoid overlap issues
        if (opcode == OP_HALT) begin
            // HALT (0x00) — Format V
            decoded.format   = FMT_V;
            decoded.is_halt  = 1'b1;
            decoded.inst_len = 6'd1;

        end else if (opcode == OP_NOP) begin
            // NOP (0xCD) — Format V
            decoded.format   = FMT_V;
            decoded.is_nop   = 1'b1;
            decoded.inst_len = 6'd1;

        end else if (opcode == OP_GETPSW) begin
            // GETPSW (0xCC) — Format V
            decoded.format   = FMT_V;
            decoded.inst_len = 6'd1;

        end else if (opcode == OP_RET) begin
            // RET (0xBF) — Format V
            decoded.format   = FMT_V;
            decoded.inst_len = 6'd1;

        end else if (opcode == OP_RSR) begin
            // RSR (0x9F) — Format V
            decoded.format   = FMT_V;
            decoded.inst_len = 6'd1;

        end else if (opcode[7:4] == 4'h6) begin
            // Bcc short (0x60-0x6F) — Format IV, 8-bit displacement
            decoded.format    = FMT_IV;
            decoded.is_branch = 1'b1;
            decoded.cond      = opcode[3:0];
            decoded.is_bsr    = (opcode[3:0] == 4'hB);  // 0x6B = BSR short
            decoded.imm_value = {{24{disp8[7]}}, disp8};
            decoded.inst_len  = 6'd2;
            decode_valid      = (ibuf_valid_count >= 5'd2);

        end else if (opcode[7:4] == 4'h7) begin
            // Bcc long (0x70-0x7F) — Format IV, 16-bit displacement
            decoded.format    = FMT_IV;
            decoded.is_branch = 1'b1;
            decoded.cond      = opcode[3:0];
            decoded.is_bsr    = (opcode[3:0] == 4'hB);  // 0x7B = BSR long
            decoded.imm_value = {{16{disp16[15]}}, disp16};
            decoded.inst_len  = 6'd3;
            decode_valid      = (ibuf_valid_count >= 5'd3);

        end else if (opcode[7:4] == 4'h8 || opcode[7:4] == 4'h9 ||
                     opcode[7:4] == 4'hA || opcode[7:4] == 4'hB) begin
            // Format I: Two-operand instructions (Phase 2+)
            decoded.format   = FMT_I;
            decoded.inst_len = 6'd3;
            decode_valid     = (ibuf_valid_count >= 5'd3);

        end else begin
            // Unknown opcode — treat as 1-byte NOP for now
            decoded.format   = FMT_V;
            decoded.inst_len = 6'd1;
        end
    end

endmodule
