// v60_decode.sv — Instruction decoder
// Phase 5A: Decodes Format V (NOP, HALT), Format IV (Bcc),
//           Format I (MOV, ADD, SUB, CMP, AND, OR, XOR, ADDC, SUBC, NOT, NEG),
//           Format III (GETPSW, INC, DEC)
//           Memory addressing modes: [Rn], [Rn]+, -[Rn], Disp8/16/32[Rn],
//           PCDisp8/16/32, DirectAddr
// Combinational decode from fetch buffer window

/* verilator lint_off UNUSEDSIGNAL */
module v60_decode
    import v60_pkg::*;
(
    // Fetch buffer window (12 bytes visible)
    input  logic [7:0]  ibuf_data [FETCH_WINDOW],
    input  logic [4:0]  ibuf_valid_count,

    // Decoded instruction output
    output decoded_inst_t decoded,
    output logic          decode_valid  // Enough bytes available to decode
);

    // =========================================================================
    // Byte extraction from instruction buffer
    // =========================================================================
    logic [7:0] opcode;
    assign opcode = ibuf_data[0];

    // Branch displacement extraction
    logic [7:0]  disp8;
    logic [15:0] disp16;
    assign disp8  = ibuf_data[1];
    assign disp16 = {ibuf_data[2], ibuf_data[1]};  // Little-endian

    // Format I: byte 1 fields
    logic       fmt1_is_fmt2;   // byte1[7] — 0=Format I, 1=Format II
    logic       fmt1_m;         // byte1[6] — addressing mode selector for mod field
    logic       fmt1_d;         // byte1[5] — direction: 0=reg is src, 1=reg is dst
    logic [4:0] fmt1_reg;       // byte1[4:0] — register number
    assign fmt1_is_fmt2 = ibuf_data[1][7];
    assign fmt1_m       = ibuf_data[1][6];
    assign fmt1_d       = ibuf_data[1][5];
    assign fmt1_reg     = ibuf_data[1][4:0];

    // Format I: mod field starts at byte 2
    logic [7:0] fmt1_mod_byte;
    assign fmt1_mod_byte = ibuf_data[2];

    // Format III: m bit is opcode LSB, mod field starts at byte 1
    logic       fmt3_m;
    logic [7:0] fmt3_mod_byte;
    assign fmt3_m        = opcode[0];
    assign fmt3_mod_byte = ibuf_data[1];

    // =========================================================================
    // Format I opcode classification
    // =========================================================================
    logic       is_fmt1_mov;
    logic       is_fmt1_alu;
    alu_op_t    fmt1_alu_op;
    data_size_t fmt1_size;

    always_comb begin
        is_fmt1_mov = 1'b0;
        is_fmt1_alu = 1'b0;
        fmt1_alu_op = ALU_NOP;
        fmt1_size   = SZ_WORD;

        // MOV family
        if (opcode == OP_MOV_B) begin
            is_fmt1_mov = 1'b1; fmt1_alu_op = ALU_MOV; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_MOV_H) begin
            is_fmt1_mov = 1'b1; fmt1_alu_op = ALU_MOV; fmt1_size = SZ_HALF;
        end else if (opcode == OP_MOV_W) begin
            is_fmt1_mov = 1'b1; fmt1_alu_op = ALU_MOV; fmt1_size = SZ_WORD;
        // ALU ops in 0x80-0xBF range
        end else if (opcode == OP_ADD_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_ADD; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_ADD_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_ADD; fmt1_size = SZ_HALF;
        end else if (opcode == OP_ADD_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_ADD; fmt1_size = SZ_WORD;
        end else if (opcode == OP_SUB_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_SUB; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_SUB_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_SUB; fmt1_size = SZ_HALF;
        end else if (opcode == OP_SUB_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_SUB; fmt1_size = SZ_WORD;
        end else if (opcode == OP_CMP_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_CMP; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_CMP_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_CMP; fmt1_size = SZ_HALF;
        end else if (opcode == OP_CMP_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_CMP; fmt1_size = SZ_WORD;
        end else if (opcode == OP_AND_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_AND; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_AND_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_AND; fmt1_size = SZ_HALF;
        end else if (opcode == OP_AND_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_AND; fmt1_size = SZ_WORD;
        end else if (opcode == OP_OR_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_OR;  fmt1_size = SZ_BYTE;
        end else if (opcode == OP_OR_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_OR;  fmt1_size = SZ_HALF;
        end else if (opcode == OP_OR_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_OR;  fmt1_size = SZ_WORD;
        end else if (opcode == OP_XOR_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_XOR; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_XOR_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_XOR; fmt1_size = SZ_HALF;
        end else if (opcode == OP_XOR_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_XOR; fmt1_size = SZ_WORD;
        // ADDC family
        end else if (opcode == OP_ADDC_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_ADDC; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_ADDC_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_ADDC; fmt1_size = SZ_HALF;
        end else if (opcode == OP_ADDC_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_ADDC; fmt1_size = SZ_WORD;
        // SUBC family
        end else if (opcode == OP_SUBC_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_SUBC; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_SUBC_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_SUBC; fmt1_size = SZ_HALF;
        end else if (opcode == OP_SUBC_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_SUBC; fmt1_size = SZ_WORD;
        // NOT family
        end else if (opcode == OP_NOT_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_NOT; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_NOT_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_NOT; fmt1_size = SZ_HALF;
        end else if (opcode == OP_NOT_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_NOT; fmt1_size = SZ_WORD;
        // NEG family
        end else if (opcode == OP_NEG_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_NEG; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_NEG_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_NEG; fmt1_size = SZ_HALF;
        end else if (opcode == OP_NEG_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_NEG; fmt1_size = SZ_WORD;
        end
    end

    logic is_fmt1;
    assign is_fmt1 = is_fmt1_mov || is_fmt1_alu;

    // =========================================================================
    // Immediate value size in bytes (based on data_size)
    // =========================================================================
    logic [2:0] imm_bytes;
    always_comb begin
        case (fmt1_size)
            SZ_BYTE: imm_bytes = 3'd1;
            SZ_HALF: imm_bytes = 3'd2;
            SZ_WORD: imm_bytes = 3'd4;
            default: imm_bytes = 3'd4;
        endcase
    end

    // =========================================================================
    // Immediate value extraction (at byte offset 3 for Format I: opcode+byte1+modbyte+imm)
    // =========================================================================
    logic [31:0] fmt1_imm_val;
    always_comb begin
        case (fmt1_size)
            SZ_BYTE: fmt1_imm_val = {24'h0, ibuf_data[3]};
            SZ_HALF: fmt1_imm_val = {16'h0, ibuf_data[4], ibuf_data[3]};
            SZ_WORD: fmt1_imm_val = {ibuf_data[6], ibuf_data[5], ibuf_data[4], ibuf_data[3]};
            default: fmt1_imm_val = 32'h0;
        endcase
    end

    // =========================================================================
    // Format I mod field decode (mod byte at ibuf_data[2])
    // Dispatch: AMTable[m][mod_byte>>5]
    // =========================================================================
    logic [2:0] f1_mod_hi;
    logic [4:0] f1_mod_lo;
    addr_mode_t f1_mod_am;
    logic [4:0] f1_mod_reg;
    logic [31:0] f1_mod_imm;
    logic [5:0] f1_mod_len;
    logic       f1_mod_is_mem;
    logic       f1_mod_auto_inc;
    logic       f1_mod_auto_dec;

    assign f1_mod_hi = fmt1_mod_byte[7:5];
    assign f1_mod_lo = fmt1_mod_byte[4:0];

    always_comb begin
        f1_mod_am       = AM_ERROR;
        f1_mod_reg      = 5'd0;
        f1_mod_imm      = 32'h0;
        f1_mod_len      = 6'd1;
        f1_mod_is_mem   = 1'b0;
        f1_mod_auto_inc = 1'b0;
        f1_mod_auto_dec = 1'b0;

        if (fmt1_m) begin
            // m=1 dispatch on mod[7:5]
            case (f1_mod_hi)
                3'd3: begin  // Register
                    f1_mod_am  = AM_REGISTER;
                    f1_mod_reg = f1_mod_lo;
                    f1_mod_len = 6'd1;
                end
                3'd4: begin  // Autoincrement [Rn]+
                    f1_mod_am       = AM_REG_INDIRECT_INC;
                    f1_mod_reg      = f1_mod_lo;
                    f1_mod_len      = 6'd1;
                    f1_mod_is_mem   = 1'b1;
                    f1_mod_auto_inc = 1'b1;
                end
                3'd5: begin  // Autodecrement -[Rn]
                    f1_mod_am       = AM_REG_INDIRECT_DEC;
                    f1_mod_reg      = f1_mod_lo;
                    f1_mod_len      = 6'd1;
                    f1_mod_is_mem   = 1'b1;
                    f1_mod_auto_dec = 1'b1;
                end
                default: begin
                    f1_mod_am  = AM_ERROR;
                    f1_mod_len = 6'd1;
                end
            endcase
        end else begin
            // m=0 dispatch on mod[7:5]
            case (f1_mod_hi)
                3'd0: begin  // Displacement 8-bit from register
                    f1_mod_am     = AM_DISP16_REG;
                    f1_mod_reg    = f1_mod_lo;
                    f1_mod_imm    = {{24{ibuf_data[3][7]}}, ibuf_data[3]};
                    f1_mod_len    = 6'd2;
                    f1_mod_is_mem = 1'b1;
                end
                3'd1: begin  // Displacement 16-bit from register
                    f1_mod_am     = AM_DISP16_REG;
                    f1_mod_reg    = f1_mod_lo;
                    f1_mod_imm    = {{16{ibuf_data[4][7]}}, ibuf_data[4], ibuf_data[3]};
                    f1_mod_len    = 6'd3;
                    f1_mod_is_mem = 1'b1;
                end
                3'd2: begin  // Displacement 32-bit from register
                    f1_mod_am     = AM_DISP32_REG;
                    f1_mod_reg    = f1_mod_lo;
                    f1_mod_imm    = {ibuf_data[6], ibuf_data[5], ibuf_data[4], ibuf_data[3]};
                    f1_mod_len    = 6'd5;
                    f1_mod_is_mem = 1'b1;
                end
                3'd3: begin  // Register Indirect [Rn]
                    f1_mod_am     = AM_REG_INDIRECT;
                    f1_mod_reg    = f1_mod_lo;
                    f1_mod_len    = 6'd1;
                    f1_mod_is_mem = 1'b1;
                end
                3'd7: begin  // Group7 — sub-dispatch on mod[4:0]
                    if (f1_mod_lo <= 5'd15) begin
                        // ImmediateQuick: 4-bit value in mod[3:0]
                        f1_mod_am  = AM_IMM_QUICK;
                        f1_mod_imm = {28'h0, fmt1_mod_byte[3:0]};
                        f1_mod_len = 6'd1;
                    end else if (f1_mod_lo == 5'd16) begin
                        // PCDisp8
                        f1_mod_am     = AM_PC_DISP16;
                        f1_mod_imm    = {{24{ibuf_data[3][7]}}, ibuf_data[3]};
                        f1_mod_len    = 6'd2;
                        f1_mod_is_mem = 1'b1;
                    end else if (f1_mod_lo == 5'd17) begin
                        // PCDisp16
                        f1_mod_am     = AM_PC_DISP16;
                        f1_mod_imm    = {{16{ibuf_data[4][7]}}, ibuf_data[4], ibuf_data[3]};
                        f1_mod_len    = 6'd3;
                        f1_mod_is_mem = 1'b1;
                    end else if (f1_mod_lo == 5'd18) begin
                        // PCDisp32
                        f1_mod_am     = AM_PC_DISP32;
                        f1_mod_imm    = {ibuf_data[6], ibuf_data[5], ibuf_data[4], ibuf_data[3]};
                        f1_mod_len    = 6'd5;
                        f1_mod_is_mem = 1'b1;
                    end else if (f1_mod_lo == 5'd19) begin
                        // DirectAddr (absolute 32-bit address)
                        f1_mod_am     = AM_DIRECT_ADDR;
                        f1_mod_imm    = {ibuf_data[6], ibuf_data[5], ibuf_data[4], ibuf_data[3]};
                        f1_mod_len    = 6'd5;
                        f1_mod_is_mem = 1'b1;
                    end else if (f1_mod_lo == 5'd20) begin
                        // Immediate (mod byte 0xF4): value follows mod byte
                        f1_mod_am  = AM_IMMEDIATE;
                        f1_mod_imm = fmt1_imm_val;
                        f1_mod_len = 6'd1 + {3'd0, imm_bytes};
                    end else begin
                        // Other Group7 entries (Phase 5B: indirect modes)
                        f1_mod_am  = AM_ERROR;
                        f1_mod_len = 6'd1;
                    end
                end
                default: begin
                    // hi=4,5,6: Indirect modes (Phase 5B)
                    f1_mod_am  = AM_ERROR;
                    f1_mod_len = 6'd1;
                end
            endcase
        end
    end

    // =========================================================================
    // Format III mod field decode (mod byte at ibuf_data[1])
    // =========================================================================
    logic [2:0] f3_mod_hi;
    logic [4:0] f3_mod_lo;
    addr_mode_t f3_mod_am;
    logic [4:0] f3_mod_reg;
    logic [31:0] f3_mod_imm;
    logic [5:0] f3_mod_len;
    logic       f3_mod_is_mem;
    logic       f3_mod_auto_inc;
    logic       f3_mod_auto_dec;

    assign f3_mod_hi = fmt3_mod_byte[7:5];
    assign f3_mod_lo = fmt3_mod_byte[4:0];

    // Format III immediate value extraction (at byte offset 2: opcode+modbyte+imm)
    logic [31:0] fmt3_imm_val;
    logic [2:0]  fmt3_imm_bytes;
    always_comb begin
        // For Format III, the data size comes from the opcode
        // INC/DEC: ((opcode & 0x06) >> 1) gives 0=B, 1=H, 2=W
        // But we need this for the immediate extraction; for now just
        // use the final decoded data_size. Since Format III imm modes
        // are only ImmQuick (no full imm), this is unused but kept for consistency.
        fmt3_imm_bytes = 3'd4;
        fmt3_imm_val = 32'h0;
    end

    always_comb begin
        f3_mod_am       = AM_ERROR;
        f3_mod_reg      = 5'd0;
        f3_mod_imm      = 32'h0;
        f3_mod_len      = 6'd1;
        f3_mod_is_mem   = 1'b0;
        f3_mod_auto_inc = 1'b0;
        f3_mod_auto_dec = 1'b0;

        if (fmt3_m) begin
            // m=1 dispatch
            case (f3_mod_hi)
                3'd3: begin  // Register
                    f3_mod_am  = AM_REGISTER;
                    f3_mod_reg = f3_mod_lo;
                    f3_mod_len = 6'd1;
                end
                3'd4: begin  // Autoincrement [Rn]+
                    f3_mod_am       = AM_REG_INDIRECT_INC;
                    f3_mod_reg      = f3_mod_lo;
                    f3_mod_len      = 6'd1;
                    f3_mod_is_mem   = 1'b1;
                    f3_mod_auto_inc = 1'b1;
                end
                3'd5: begin  // Autodecrement -[Rn]
                    f3_mod_am       = AM_REG_INDIRECT_DEC;
                    f3_mod_reg      = f3_mod_lo;
                    f3_mod_len      = 6'd1;
                    f3_mod_is_mem   = 1'b1;
                    f3_mod_auto_dec = 1'b1;
                end
                default: begin
                    f3_mod_am  = AM_ERROR;
                    f3_mod_len = 6'd1;
                end
            endcase
        end else begin
            // m=0 dispatch
            case (f3_mod_hi)
                3'd0: begin  // Displacement 8-bit from register
                    f3_mod_am     = AM_DISP16_REG;
                    f3_mod_reg    = f3_mod_lo;
                    f3_mod_imm    = {{24{ibuf_data[2][7]}}, ibuf_data[2]};
                    f3_mod_len    = 6'd2;
                    f3_mod_is_mem = 1'b1;
                end
                3'd1: begin  // Displacement 16-bit from register
                    f3_mod_am     = AM_DISP16_REG;
                    f3_mod_reg    = f3_mod_lo;
                    f3_mod_imm    = {{16{ibuf_data[3][7]}}, ibuf_data[3], ibuf_data[2]};
                    f3_mod_len    = 6'd3;
                    f3_mod_is_mem = 1'b1;
                end
                3'd2: begin  // Displacement 32-bit from register
                    f3_mod_am     = AM_DISP32_REG;
                    f3_mod_reg    = f3_mod_lo;
                    f3_mod_imm    = {ibuf_data[5], ibuf_data[4], ibuf_data[3], ibuf_data[2]};
                    f3_mod_len    = 6'd5;
                    f3_mod_is_mem = 1'b1;
                end
                3'd3: begin  // Register Indirect [Rn]
                    f3_mod_am     = AM_REG_INDIRECT;
                    f3_mod_reg    = f3_mod_lo;
                    f3_mod_len    = 6'd1;
                    f3_mod_is_mem = 1'b1;
                end
                3'd7: begin  // Group7
                    if (f3_mod_lo <= 5'd15) begin
                        f3_mod_am  = AM_IMM_QUICK;
                        f3_mod_len = 6'd1;
                    end else if (f3_mod_lo == 5'd16) begin
                        // PCDisp8
                        f3_mod_am     = AM_PC_DISP16;
                        f3_mod_imm    = {{24{ibuf_data[2][7]}}, ibuf_data[2]};
                        f3_mod_len    = 6'd2;
                        f3_mod_is_mem = 1'b1;
                    end else if (f3_mod_lo == 5'd17) begin
                        // PCDisp16
                        f3_mod_am     = AM_PC_DISP16;
                        f3_mod_imm    = {{16{ibuf_data[3][7]}}, ibuf_data[3], ibuf_data[2]};
                        f3_mod_len    = 6'd3;
                        f3_mod_is_mem = 1'b1;
                    end else if (f3_mod_lo == 5'd18) begin
                        // PCDisp32
                        f3_mod_am     = AM_PC_DISP32;
                        f3_mod_imm    = {ibuf_data[5], ibuf_data[4], ibuf_data[3], ibuf_data[2]};
                        f3_mod_len    = 6'd5;
                        f3_mod_is_mem = 1'b1;
                    end else if (f3_mod_lo == 5'd19) begin
                        // DirectAddr
                        f3_mod_am     = AM_DIRECT_ADDR;
                        f3_mod_imm    = {ibuf_data[5], ibuf_data[4], ibuf_data[3], ibuf_data[2]};
                        f3_mod_len    = 6'd5;
                        f3_mod_is_mem = 1'b1;
                    end else begin
                        f3_mod_am  = AM_ERROR;
                        f3_mod_len = 6'd1;
                    end
                end
                default: begin
                    f3_mod_am  = AM_ERROR;
                    f3_mod_len = 6'd1;
                end
            endcase
        end
    end

    // =========================================================================
    // Main decode logic
    // =========================================================================
    always_comb begin
        // Defaults
        decoded = '0;
        decoded.opcode    = opcode;
        decoded.format    = FMT_V;
        decoded.alu_op    = ALU_NOP;
        decoded.data_size = SZ_WORD;
        decoded.am_src    = AM_ERROR;
        decoded.am_dst    = AM_ERROR;
        decoded.inst_len  = 6'd1;
        decode_valid      = (ibuf_valid_count >= 5'd1);

        // =====================================================================
        // Format V: Zero-operand instructions
        // =====================================================================
        if (opcode == OP_HALT) begin
            decoded.format   = FMT_V;
            decoded.is_halt  = 1'b1;
            decoded.inst_len = 6'd1;

        end else if (opcode == OP_NOP) begin
            decoded.format   = FMT_V;
            decoded.is_nop   = 1'b1;
            decoded.inst_len = 6'd1;

        end else if (opcode == OP_RSR) begin
            decoded.format   = FMT_V;
            decoded.inst_len = 6'd1;

        // =====================================================================
        // Format IV: Branch instructions (0x60-0x6F short, 0x70-0x7F long)
        // Note: 0x6B/0x7B are UNHANDLED in MAME (not BSR — BSR is at 0x48)
        // =====================================================================
        end else if (opcode[7:4] == 4'h6) begin
            decoded.format    = FMT_IV;
            decoded.is_branch = 1'b1;
            decoded.cond      = opcode[3:0];
            decoded.imm_value = {{24{disp8[7]}}, disp8};
            decoded.inst_len  = 6'd2;
            decode_valid      = (ibuf_valid_count >= 5'd2);

        end else if (opcode[7:4] == 4'h7) begin
            decoded.format    = FMT_IV;
            decoded.is_branch = 1'b1;
            decoded.cond      = opcode[3:0];
            decoded.imm_value = {{16{disp16[15]}}, disp16};
            decoded.inst_len  = 6'd3;
            decode_valid      = (ibuf_valid_count >= 5'd3);

        // =====================================================================
        // Format I: Two-operand instructions
        // Byte 0: opcode, Byte 1: [7]=0/[6]=m/[5]=d/[4:0]=reg, Bytes 2+: mod
        // =====================================================================
        end else if (is_fmt1 && ibuf_valid_count >= 5'd2 && !fmt1_is_fmt2) begin
            decoded.format    = FMT_I;
            decoded.alu_op    = fmt1_alu_op;
            decoded.data_size = fmt1_size;
            decoded.dir       = fmt1_d;

            // Direction determines source/destination assignment
            if (fmt1_d == 1'b0) begin
                // d=0: reg field is source, mod field is destination
                decoded.am_src    = AM_REGISTER;
                decoded.reg_src   = fmt1_reg;
                decoded.am_dst    = f1_mod_am;
                decoded.reg_dst   = f1_mod_reg;
                decoded.imm_value = f1_mod_imm;
                decoded.is_mem_dst = f1_mod_is_mem;
                decoded.auto_inc   = f1_mod_auto_inc;
                decoded.auto_dec   = f1_mod_auto_dec;
            end else begin
                // d=1: reg field is destination, mod field is source
                decoded.am_src    = f1_mod_am;
                decoded.reg_src   = f1_mod_reg;
                decoded.am_dst    = AM_REGISTER;
                decoded.reg_dst   = fmt1_reg;
                decoded.imm_value = f1_mod_imm;
                decoded.is_mem_src = f1_mod_is_mem;
                decoded.auto_inc   = f1_mod_auto_inc;
                decoded.auto_dec   = f1_mod_auto_dec;
            end

            // MOV does NOT modify flags; ALU ops (ADD, SUB, etc.) do
            decoded.writes_flags = (fmt1_alu_op != ALU_MOV);

            decoded.inst_len = 6'd2 + f1_mod_len;
            decode_valid     = (ibuf_valid_count >= (5'd2 + f1_mod_len[4:0]));

        // Format I recognized but not enough bytes yet (or Format II — future)
        end else if (is_fmt1) begin
            decode_valid = 1'b0;

        // =====================================================================
        // Format III: Single-operand instructions (opcode LSB = m bit)
        // GETPSW (0xF6/0xF7)
        // =====================================================================
        end else if (opcode == OP_GETPSW_0 || opcode == OP_GETPSW_1) begin
            decoded.format     = FMT_III;
            decoded.is_getpsw  = 1'b1;
            decoded.data_size  = SZ_WORD;
            decoded.am_dst     = f3_mod_am;
            decoded.reg_dst    = f3_mod_reg;
            decoded.imm_value  = f3_mod_imm;
            decoded.is_mem_dst = f3_mod_is_mem;
            decoded.auto_inc   = f3_mod_auto_inc;
            decoded.auto_dec   = f3_mod_auto_dec;
            decoded.inst_len   = 6'd1 + f3_mod_len;
            decode_valid       = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format III: INC/DEC (opcode LSB = m bit)
        // DEC: 0xD0-0xD5, INC: 0xD8-0xDD
        // =====================================================================
        end else if (opcode == OP_INC_B_0 || opcode == OP_INC_B_1) begin
            decoded.format      = FMT_III;
            decoded.alu_op      = ALU_INC;
            decoded.data_size   = SZ_BYTE;
            decoded.writes_flags = 1'b1;
            decoded.am_dst      = f3_mod_am;
            decoded.reg_dst     = f3_mod_reg;
            decoded.imm_value   = f3_mod_imm;
            decoded.is_mem_dst  = f3_mod_is_mem;
            decoded.auto_inc    = f3_mod_auto_inc;
            decoded.auto_dec    = f3_mod_auto_dec;
            decoded.inst_len    = 6'd1 + f3_mod_len;
            decode_valid        = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));
        end else if (opcode == OP_INC_H_0 || opcode == OP_INC_H_1) begin
            decoded.format      = FMT_III;
            decoded.alu_op      = ALU_INC;
            decoded.data_size   = SZ_HALF;
            decoded.writes_flags = 1'b1;
            decoded.am_dst      = f3_mod_am;
            decoded.reg_dst     = f3_mod_reg;
            decoded.imm_value   = f3_mod_imm;
            decoded.is_mem_dst  = f3_mod_is_mem;
            decoded.auto_inc    = f3_mod_auto_inc;
            decoded.auto_dec    = f3_mod_auto_dec;
            decoded.inst_len    = 6'd1 + f3_mod_len;
            decode_valid        = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));
        end else if (opcode == OP_INC_W_0 || opcode == OP_INC_W_1) begin
            decoded.format      = FMT_III;
            decoded.alu_op      = ALU_INC;
            decoded.data_size   = SZ_WORD;
            decoded.writes_flags = 1'b1;
            decoded.am_dst      = f3_mod_am;
            decoded.reg_dst     = f3_mod_reg;
            decoded.imm_value   = f3_mod_imm;
            decoded.is_mem_dst  = f3_mod_is_mem;
            decoded.auto_inc    = f3_mod_auto_inc;
            decoded.auto_dec    = f3_mod_auto_dec;
            decoded.inst_len    = 6'd1 + f3_mod_len;
            decode_valid        = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));
        end else if (opcode == OP_DEC_B_0 || opcode == OP_DEC_B_1) begin
            decoded.format      = FMT_III;
            decoded.alu_op      = ALU_DEC;
            decoded.data_size   = SZ_BYTE;
            decoded.writes_flags = 1'b1;
            decoded.am_dst      = f3_mod_am;
            decoded.reg_dst     = f3_mod_reg;
            decoded.imm_value   = f3_mod_imm;
            decoded.is_mem_dst  = f3_mod_is_mem;
            decoded.auto_inc    = f3_mod_auto_inc;
            decoded.auto_dec    = f3_mod_auto_dec;
            decoded.inst_len    = 6'd1 + f3_mod_len;
            decode_valid        = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));
        end else if (opcode == OP_DEC_H_0 || opcode == OP_DEC_H_1) begin
            decoded.format      = FMT_III;
            decoded.alu_op      = ALU_DEC;
            decoded.data_size   = SZ_HALF;
            decoded.writes_flags = 1'b1;
            decoded.am_dst      = f3_mod_am;
            decoded.reg_dst     = f3_mod_reg;
            decoded.imm_value   = f3_mod_imm;
            decoded.is_mem_dst  = f3_mod_is_mem;
            decoded.auto_inc    = f3_mod_auto_inc;
            decoded.auto_dec    = f3_mod_auto_dec;
            decoded.inst_len    = 6'd1 + f3_mod_len;
            decode_valid        = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));
        end else if (opcode == OP_DEC_W_0 || opcode == OP_DEC_W_1) begin
            decoded.format      = FMT_III;
            decoded.alu_op      = ALU_DEC;
            decoded.data_size   = SZ_WORD;
            decoded.writes_flags = 1'b1;
            decoded.am_dst      = f3_mod_am;
            decoded.reg_dst     = f3_mod_reg;
            decoded.imm_value   = f3_mod_imm;
            decoded.is_mem_dst  = f3_mod_is_mem;
            decoded.auto_inc    = f3_mod_auto_inc;
            decoded.auto_dec    = f3_mod_auto_dec;
            decoded.inst_len    = 6'd1 + f3_mod_len;
            decode_valid        = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format I: Recognize 0x80-0xBF range even for Format II encoding
        // (for forward compatibility; treat as unimplemented for now)
        // =====================================================================
        end else if (opcode[7:4] >= 4'h8 && opcode[7:4] <= 4'hB) begin
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
