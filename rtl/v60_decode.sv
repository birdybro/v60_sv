// v60_decode.sv — Instruction decoder
// Phase 11: Adds Format II FP (0x5C, 0x5F) with dual-AM decode
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
    logic       is_fmt1_sys;
    alu_op_t    fmt1_alu_op;
    data_size_t fmt1_size;
    sys_op_t    fmt1_sys_op;
    data_size_t fmt1_src_size;
    data_size_t fmt1_dst_size;

    always_comb begin
        is_fmt1_mov = 1'b0;
        is_fmt1_alu = 1'b0;
        is_fmt1_sys = 1'b0;
        fmt1_alu_op = ALU_NOP;
        fmt1_size   = SZ_WORD;
        fmt1_sys_op  = SYS_NONE;
        fmt1_src_size = SZ_WORD;
        fmt1_dst_size = SZ_WORD;

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
        // Phase 7: MUL family
        end else if (opcode == OP_MUL_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_MUL; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_MUL_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_MUL; fmt1_size = SZ_HALF;
        end else if (opcode == OP_MUL_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_MUL; fmt1_size = SZ_WORD;
        // Phase 7: MULU family
        end else if (opcode == OP_MULU_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_MULU; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_MULU_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_MULU; fmt1_size = SZ_HALF;
        end else if (opcode == OP_MULU_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_MULU; fmt1_size = SZ_WORD;
        // DIV family
        end else if (opcode == OP_DIV_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_DIV; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_DIV_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_DIV; fmt1_size = SZ_HALF;
        end else if (opcode == OP_DIV_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_DIV; fmt1_size = SZ_WORD;
        // DIVU family
        end else if (opcode == OP_DIVU_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_DIVU; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_DIVU_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_DIVU; fmt1_size = SZ_HALF;
        end else if (opcode == OP_DIVU_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_DIVU; fmt1_size = SZ_WORD;
        // REM family
        end else if (opcode == OP_REM_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_REM; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_REM_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_REM; fmt1_size = SZ_HALF;
        end else if (opcode == OP_REM_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_REM; fmt1_size = SZ_WORD;
        // REMU family
        end else if (opcode == OP_REMU_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_REMU; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_REMU_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_REMU; fmt1_size = SZ_HALF;
        end else if (opcode == OP_REMU_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_REMU; fmt1_size = SZ_WORD;
        // SHL family
        end else if (opcode == OP_SHL_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_SHL; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_SHL_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_SHL; fmt1_size = SZ_HALF;
        end else if (opcode == OP_SHL_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_SHL; fmt1_size = SZ_WORD;
        // SHA family
        end else if (opcode == OP_SHA_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_SHA; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_SHA_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_SHA; fmt1_size = SZ_HALF;
        end else if (opcode == OP_SHA_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_SHA; fmt1_size = SZ_WORD;
        // ROT family
        end else if (opcode == OP_ROT_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_ROT; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_ROT_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_ROT; fmt1_size = SZ_HALF;
        end else if (opcode == OP_ROT_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_ROT; fmt1_size = SZ_WORD;
        // ROTC family
        end else if (opcode == OP_ROTC_B) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_ROTC; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_ROTC_H) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_ROTC; fmt1_size = SZ_HALF;
        end else if (opcode == OP_ROTC_W) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_ROTC; fmt1_size = SZ_WORD;
        // Bit operations (word only)
        end else if (opcode == OP_TEST1) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_TEST1; fmt1_size = SZ_WORD;
        end else if (opcode == OP_SET1) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_SET1; fmt1_size = SZ_WORD;
        end else if (opcode == OP_CLR1) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_CLR1; fmt1_size = SZ_WORD;
        end else if (opcode == OP_NOT1) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_NOT1; fmt1_size = SZ_WORD;
        // Phase 8: RVBIT/RVBYT (ALU path, no flags)
        end else if (opcode == OP_RVBIT) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_RVBIT; fmt1_size = SZ_BYTE;
        end else if (opcode == OP_RVBYT) begin
            is_fmt1_alu = 1'b1; fmt1_alu_op = ALU_RVBYT; fmt1_size = SZ_WORD;
        // Phase 8: Cross-size MOV (sign extend)
        end else if (opcode == OP_MOVSBH) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_MOVSB; fmt1_src_size = SZ_BYTE; fmt1_dst_size = SZ_HALF;
        end else if (opcode == OP_MOVSBW) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_MOVSB; fmt1_src_size = SZ_BYTE; fmt1_dst_size = SZ_WORD;
        end else if (opcode == OP_MOVSHW) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_MOVSH; fmt1_src_size = SZ_HALF; fmt1_dst_size = SZ_WORD;
        // Phase 8: Cross-size MOV (zero extend)
        end else if (opcode == OP_MOVZBH) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_MOVZB; fmt1_src_size = SZ_BYTE; fmt1_dst_size = SZ_HALF;
        end else if (opcode == OP_MOVZBW) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_MOVZB; fmt1_src_size = SZ_BYTE; fmt1_dst_size = SZ_WORD;
        end else if (opcode == OP_MOVZHW) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_MOVZH; fmt1_src_size = SZ_HALF; fmt1_dst_size = SZ_WORD;
        // Phase 8: Cross-size MOV (truncate)
        end else if (opcode == OP_MOVTHB) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_MOVT; fmt1_src_size = SZ_HALF; fmt1_dst_size = SZ_BYTE;
        end else if (opcode == OP_MOVTWB) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_MOVT; fmt1_src_size = SZ_WORD; fmt1_dst_size = SZ_BYTE;
        end else if (opcode == OP_MOVTWH) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_MOVT; fmt1_src_size = SZ_WORD; fmt1_dst_size = SZ_HALF;
        // Phase 8: MOVEA (address, not data)
        end else if (opcode == OP_MOVEAB) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_MOVEA; fmt1_src_size = SZ_BYTE; fmt1_dst_size = SZ_WORD;
        end else if (opcode == OP_MOVEAH) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_MOVEA; fmt1_src_size = SZ_HALF; fmt1_dst_size = SZ_WORD;
        end else if (opcode == OP_MOVEAW) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_MOVEA; fmt1_src_size = SZ_WORD; fmt1_dst_size = SZ_WORD;
        // Phase 8: SETF
        end else if (opcode == OP_SETF) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_SETF; fmt1_src_size = SZ_BYTE; fmt1_dst_size = SZ_BYTE;
        // Phase 8: UPDPSW
        end else if (opcode == OP_UPDPSWW) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_UPDPSW; fmt1_src_size = SZ_WORD; fmt1_dst_size = SZ_WORD;
        end else if (opcode == OP_UPDPSWH) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_UPDPSW; fmt1_src_size = SZ_WORD; fmt1_dst_size = SZ_HALF;
        // Phase 8: LDPR/STPR
        end else if (opcode == OP_LDPR) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_LDPR; fmt1_src_size = SZ_WORD; fmt1_dst_size = SZ_WORD;
        end else if (opcode == OP_STPR) begin
            is_fmt1_sys = 1'b1; fmt1_sys_op = SYS_STPR; fmt1_src_size = SZ_WORD; fmt1_dst_size = SZ_WORD;
        end
    end

    logic is_fmt1;
    assign is_fmt1 = is_fmt1_mov || is_fmt1_alu || is_fmt1_sys;

    // =========================================================================
    // Format II FP detection and subop dispatch
    // =========================================================================
    logic       is_fmt2_fp;
    assign is_fmt2_fp = (opcode == OP_FP_5C || opcode == OP_FP_5F);

    logic [4:0] fmt2_subop;
    assign fmt2_subop = ibuf_data[1][4:0];

    fp_op_t     fmt2_fp_op;
    logic       fmt2_is_cmpf;    // CMP-like: read AM1, read AM2, flags only
    logic       fmt2_is_mov_like; // MOV-like: read AM1, write AM2 (no AM2 read)
    logic       fmt2_is_rmw;     // R-M-W: read AM1, read AM2 addr, compute, write AM2
    data_size_t fmt2_am1_dim;    // AM1 dimension (SZ_HALF for SCLF, else SZ_WORD)

    always_comb begin
        fmt2_fp_op     = FP_NONE;
        fmt2_is_cmpf   = 1'b0;
        fmt2_is_mov_like = 1'b0;
        fmt2_is_rmw    = 1'b0;
        fmt2_am1_dim   = SZ_WORD;

        if (opcode == OP_FP_5C) begin
            case (fmt2_subop)
                5'h00: begin fmt2_fp_op = FP_CMPF; fmt2_is_cmpf = 1'b1; end
                5'h08: begin fmt2_fp_op = FP_MOVF; fmt2_is_mov_like = 1'b1; end
                5'h09: begin fmt2_fp_op = FP_NEGF; fmt2_is_rmw = 1'b1; end
                5'h0A: begin fmt2_fp_op = FP_ABSF; fmt2_is_rmw = 1'b1; end
                5'h10: begin fmt2_fp_op = FP_SCLF; fmt2_is_rmw = 1'b1; fmt2_am1_dim = SZ_HALF; end
                5'h18: begin fmt2_fp_op = FP_ADDF; fmt2_is_rmw = 1'b1; end
                5'h19: begin fmt2_fp_op = FP_SUBF; fmt2_is_rmw = 1'b1; end
                5'h1A: begin fmt2_fp_op = FP_MULF; fmt2_is_rmw = 1'b1; end
                5'h1B: begin fmt2_fp_op = FP_DIVF; fmt2_is_rmw = 1'b1; end
                default: ;
            endcase
        end else if (opcode == OP_FP_5F) begin
            case (fmt2_subop)
                5'h00: begin fmt2_fp_op = FP_CVTWS; fmt2_is_mov_like = 1'b1; end
                5'h01: begin fmt2_fp_op = FP_CVTSW; fmt2_is_mov_like = 1'b1; end
                default: ;
            endcase
        end
    end

    // =========================================================================
    // Source dimension override for shift/rotate
    // When d=1 (mod=source/count), shift/rotate source is always byte
    // =========================================================================
    logic fmt1_src_is_byte;
    assign fmt1_src_is_byte = (fmt1_alu_op == ALU_SHL || fmt1_alu_op == ALU_SHA ||
                               fmt1_alu_op == ALU_ROT || fmt1_alu_op == ALU_ROTC);

    data_size_t fmt1_mod_dim;
    always_comb begin
        if (is_fmt2_fp)
            fmt1_mod_dim = fmt2_am1_dim;
        else if (is_fmt1_sys)
            fmt1_mod_dim = fmt1_d ? fmt1_src_size : fmt1_dst_size;
        else if (fmt1_src_is_byte && fmt1_d)
            fmt1_mod_dim = SZ_BYTE;
        else
            fmt1_mod_dim = fmt1_size;
    end

    // =========================================================================
    // Immediate value size in bytes (based on mod dimension)
    // =========================================================================
    logic [2:0] imm_bytes;
    always_comb begin
        case (fmt1_mod_dim)
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
        case (fmt1_mod_dim)
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
    logic       f1_mod_needs_indirect;
    logic [31:0] f1_mod_imm2;

    assign f1_mod_hi = fmt1_mod_byte[7:5];
    assign f1_mod_lo = fmt1_mod_byte[4:0];

    always_comb begin
        f1_mod_am              = AM_ERROR;
        f1_mod_reg             = 5'd0;
        f1_mod_imm             = 32'h0;
        f1_mod_len             = 6'd1;
        f1_mod_is_mem          = 1'b0;
        f1_mod_auto_inc        = 1'b0;
        f1_mod_auto_dec        = 1'b0;
        f1_mod_needs_indirect  = 1'b0;
        f1_mod_imm2            = 32'h0;

        if (fmt1_m) begin
            // m=1 dispatch on mod[7:5]
            case (f1_mod_hi)
                3'd0: begin  // DblDisp8[Rn] — pointer at Rn+d1, data at [ptr+d2]
                    f1_mod_am             = AM_DISP16_REG;
                    f1_mod_reg            = f1_mod_lo;
                    f1_mod_imm            = {{24{ibuf_data[3][7]}}, ibuf_data[3]};
                    f1_mod_imm2           = {{24{ibuf_data[4][7]}}, ibuf_data[4]};
                    f1_mod_len            = 6'd3;
                    f1_mod_is_mem         = 1'b1;
                    f1_mod_needs_indirect = 1'b1;
                end
                3'd1: begin  // DblDisp16[Rn]
                    f1_mod_am             = AM_DISP16_REG;
                    f1_mod_reg            = f1_mod_lo;
                    f1_mod_imm            = {{16{ibuf_data[4][7]}}, ibuf_data[4], ibuf_data[3]};
                    f1_mod_imm2           = {{16{ibuf_data[6][7]}}, ibuf_data[6], ibuf_data[5]};
                    f1_mod_len            = 6'd5;
                    f1_mod_is_mem         = 1'b1;
                    f1_mod_needs_indirect = 1'b1;
                end
                3'd2: begin  // DblDisp32[Rn]
                    f1_mod_am             = AM_DISP32_REG;
                    f1_mod_reg            = f1_mod_lo;
                    f1_mod_imm            = {ibuf_data[6], ibuf_data[5], ibuf_data[4], ibuf_data[3]};
                    f1_mod_imm2           = {ibuf_data[10], ibuf_data[9], ibuf_data[8], ibuf_data[7]};
                    f1_mod_len            = 6'd9;
                    f1_mod_is_mem         = 1'b1;
                    f1_mod_needs_indirect = 1'b1;
                end
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
                3'd4: begin  // DispInd8[Rn] — pointer at Rn+d, data at [ptr]
                    f1_mod_am             = AM_DISP16_REG;
                    f1_mod_reg            = f1_mod_lo;
                    f1_mod_imm            = {{24{ibuf_data[3][7]}}, ibuf_data[3]};
                    f1_mod_len            = 6'd2;
                    f1_mod_is_mem         = 1'b1;
                    f1_mod_needs_indirect = 1'b1;
                end
                3'd5: begin  // DispInd16[Rn]
                    f1_mod_am             = AM_DISP16_REG;
                    f1_mod_reg            = f1_mod_lo;
                    f1_mod_imm            = {{16{ibuf_data[4][7]}}, ibuf_data[4], ibuf_data[3]};
                    f1_mod_len            = 6'd3;
                    f1_mod_is_mem         = 1'b1;
                    f1_mod_needs_indirect = 1'b1;
                end
                3'd6: begin  // DispInd32[Rn]
                    f1_mod_am             = AM_DISP32_REG;
                    f1_mod_reg            = f1_mod_lo;
                    f1_mod_imm            = {ibuf_data[6], ibuf_data[5], ibuf_data[4], ibuf_data[3]};
                    f1_mod_len            = 6'd5;
                    f1_mod_is_mem         = 1'b1;
                    f1_mod_needs_indirect = 1'b1;
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
                    end else if (f1_mod_lo == 5'd24) begin
                        // PCDispInd8
                        f1_mod_am             = AM_PC_DISP16;
                        f1_mod_imm            = {{24{ibuf_data[3][7]}}, ibuf_data[3]};
                        f1_mod_len            = 6'd2;
                        f1_mod_is_mem         = 1'b1;
                        f1_mod_needs_indirect = 1'b1;
                    end else if (f1_mod_lo == 5'd25) begin
                        // PCDispInd16
                        f1_mod_am             = AM_PC_DISP16;
                        f1_mod_imm            = {{16{ibuf_data[4][7]}}, ibuf_data[4], ibuf_data[3]};
                        f1_mod_len            = 6'd3;
                        f1_mod_is_mem         = 1'b1;
                        f1_mod_needs_indirect = 1'b1;
                    end else if (f1_mod_lo == 5'd26) begin
                        // PCDispInd32
                        f1_mod_am             = AM_PC_DISP32;
                        f1_mod_imm            = {ibuf_data[6], ibuf_data[5], ibuf_data[4], ibuf_data[3]};
                        f1_mod_len            = 6'd5;
                        f1_mod_is_mem         = 1'b1;
                        f1_mod_needs_indirect = 1'b1;
                    end else if (f1_mod_lo == 5'd27) begin
                        // DirectAddrDeferred — pointer at absolute address
                        f1_mod_am             = AM_DIRECT_ADDR;
                        f1_mod_imm            = {ibuf_data[6], ibuf_data[5], ibuf_data[4], ibuf_data[3]};
                        f1_mod_len            = 6'd5;
                        f1_mod_is_mem         = 1'b1;
                        f1_mod_needs_indirect = 1'b1;
                    end else if (f1_mod_lo == 5'd28) begin
                        // PCDblDisp8
                        f1_mod_am             = AM_PC_DISP16;
                        f1_mod_imm            = {{24{ibuf_data[3][7]}}, ibuf_data[3]};
                        f1_mod_imm2           = {{24{ibuf_data[4][7]}}, ibuf_data[4]};
                        f1_mod_len            = 6'd3;
                        f1_mod_is_mem         = 1'b1;
                        f1_mod_needs_indirect = 1'b1;
                    end else if (f1_mod_lo == 5'd29) begin
                        // PCDblDisp16
                        f1_mod_am             = AM_PC_DISP16;
                        f1_mod_imm            = {{16{ibuf_data[4][7]}}, ibuf_data[4], ibuf_data[3]};
                        f1_mod_imm2           = {{16{ibuf_data[6][7]}}, ibuf_data[6], ibuf_data[5]};
                        f1_mod_len            = 6'd5;
                        f1_mod_is_mem         = 1'b1;
                        f1_mod_needs_indirect = 1'b1;
                    end else if (f1_mod_lo == 5'd30) begin
                        // PCDblDisp32
                        f1_mod_am             = AM_PC_DISP32;
                        f1_mod_imm            = {ibuf_data[6], ibuf_data[5], ibuf_data[4], ibuf_data[3]};
                        f1_mod_imm2           = {ibuf_data[10], ibuf_data[9], ibuf_data[8], ibuf_data[7]};
                        f1_mod_len            = 6'd9;
                        f1_mod_is_mem         = 1'b1;
                        f1_mod_needs_indirect = 1'b1;
                    end else begin
                        f1_mod_am  = AM_ERROR;
                        f1_mod_len = 6'd1;
                    end
                end
                default: begin
                    f1_mod_am  = AM_ERROR;
                    f1_mod_len = 6'd1;
                end
            endcase
        end
    end

    // =========================================================================
    // Format II AM2 decode (for FP dual-AM instructions)
    // AM2 starts at byte offset (2 + f1_mod_len), uses m2 = ibuf_data[1][5]
    // =========================================================================
    logic       f2_am2_m;
    assign f2_am2_m = ibuf_data[1][5]; // m2 bit

    // Compute AM2 base offset
    logic [4:0] f2_am2_base;
    assign f2_am2_base = 5'd2 + f1_mod_len[4:0];

    // AM2 mod byte and fields
    logic [7:0] f2_am2_mod_byte;
    assign f2_am2_mod_byte = ibuf_data[f2_am2_base];
    logic [2:0] f2_am2_hi;
    logic [4:0] f2_am2_lo;
    assign f2_am2_hi = f2_am2_mod_byte[7:5];
    assign f2_am2_lo = f2_am2_mod_byte[4:0];

    // AM2 immediate extraction helpers (relative to AM2 base + 1)
    logic [7:0] f2_am2_b1, f2_am2_b2, f2_am2_b3, f2_am2_b4;
    logic [7:0] f2_am2_b5, f2_am2_b6, f2_am2_b7, f2_am2_b8;
    assign f2_am2_b1 = ibuf_data[f2_am2_base + 5'd1];
    assign f2_am2_b2 = ibuf_data[f2_am2_base + 5'd2];
    assign f2_am2_b3 = ibuf_data[f2_am2_base + 5'd3];
    assign f2_am2_b4 = ibuf_data[f2_am2_base + 5'd4];
    assign f2_am2_b5 = ibuf_data[f2_am2_base + 5'd5];
    assign f2_am2_b6 = ibuf_data[f2_am2_base + 5'd6];
    assign f2_am2_b7 = ibuf_data[f2_am2_base + 5'd7];
    assign f2_am2_b8 = ibuf_data[f2_am2_base + 5'd8];

    // AM2 immediate value for word-sized (always SZ_WORD for AM2)
    logic [31:0] f2_am2_imm_val;
    assign f2_am2_imm_val = {f2_am2_b4, f2_am2_b3, f2_am2_b2, f2_am2_b1};

    addr_mode_t f2_am2_am;
    logic [4:0] f2_am2_reg;
    logic [31:0] f2_am2_imm;
    logic [5:0] f2_am2_len;
    logic       f2_am2_is_mem;
    logic       f2_am2_auto_inc;
    logic       f2_am2_auto_dec;
    logic       f2_am2_needs_indirect;
    logic [31:0] f2_am2_imm2;

    always_comb begin
        f2_am2_am              = AM_ERROR;
        f2_am2_reg             = 5'd0;
        f2_am2_imm             = 32'h0;
        f2_am2_len             = 6'd1;
        f2_am2_is_mem          = 1'b0;
        f2_am2_auto_inc        = 1'b0;
        f2_am2_auto_dec        = 1'b0;
        f2_am2_needs_indirect  = 1'b0;
        f2_am2_imm2            = 32'h0;

        if (f2_am2_m) begin
            // m=1 dispatch
            case (f2_am2_hi)
                3'd0: begin  // DblDisp8[Rn]
                    f2_am2_am             = AM_DISP16_REG;
                    f2_am2_reg            = f2_am2_lo;
                    f2_am2_imm            = {{24{f2_am2_b1[7]}}, f2_am2_b1};
                    f2_am2_imm2           = {{24{f2_am2_b2[7]}}, f2_am2_b2};
                    f2_am2_len            = 6'd3;
                    f2_am2_is_mem         = 1'b1;
                    f2_am2_needs_indirect = 1'b1;
                end
                3'd1: begin  // DblDisp16[Rn]
                    f2_am2_am             = AM_DISP16_REG;
                    f2_am2_reg            = f2_am2_lo;
                    f2_am2_imm            = {{16{f2_am2_b2[7]}}, f2_am2_b2, f2_am2_b1};
                    f2_am2_imm2           = {{16{f2_am2_b4[7]}}, f2_am2_b4, f2_am2_b3};
                    f2_am2_len            = 6'd5;
                    f2_am2_is_mem         = 1'b1;
                    f2_am2_needs_indirect = 1'b1;
                end
                3'd2: begin  // DblDisp32[Rn]
                    f2_am2_am             = AM_DISP32_REG;
                    f2_am2_reg            = f2_am2_lo;
                    f2_am2_imm            = {f2_am2_b4, f2_am2_b3, f2_am2_b2, f2_am2_b1};
                    f2_am2_imm2           = {f2_am2_b8, f2_am2_b7, f2_am2_b6, f2_am2_b5};
                    f2_am2_len            = 6'd9;
                    f2_am2_is_mem         = 1'b1;
                    f2_am2_needs_indirect = 1'b1;
                end
                3'd3: begin  // Register
                    f2_am2_am  = AM_REGISTER;
                    f2_am2_reg = f2_am2_lo;
                    f2_am2_len = 6'd1;
                end
                3'd4: begin  // AutoInc [Rn]+
                    f2_am2_am       = AM_REG_INDIRECT_INC;
                    f2_am2_reg      = f2_am2_lo;
                    f2_am2_len      = 6'd1;
                    f2_am2_is_mem   = 1'b1;
                    f2_am2_auto_inc = 1'b1;
                end
                3'd5: begin  // AutoDec -[Rn]
                    f2_am2_am       = AM_REG_INDIRECT_DEC;
                    f2_am2_reg      = f2_am2_lo;
                    f2_am2_len      = 6'd1;
                    f2_am2_is_mem   = 1'b1;
                    f2_am2_auto_dec = 1'b1;
                end
                default: begin
                    f2_am2_am  = AM_ERROR;
                    f2_am2_len = 6'd1;
                end
            endcase
        end else begin
            // m=0 dispatch
            case (f2_am2_hi)
                3'd0: begin  // Disp8[Rn]
                    f2_am2_am     = AM_DISP16_REG;
                    f2_am2_reg    = f2_am2_lo;
                    f2_am2_imm    = {{24{f2_am2_b1[7]}}, f2_am2_b1};
                    f2_am2_len    = 6'd2;
                    f2_am2_is_mem = 1'b1;
                end
                3'd1: begin  // Disp16[Rn]
                    f2_am2_am     = AM_DISP16_REG;
                    f2_am2_reg    = f2_am2_lo;
                    f2_am2_imm    = {{16{f2_am2_b2[7]}}, f2_am2_b2, f2_am2_b1};
                    f2_am2_len    = 6'd3;
                    f2_am2_is_mem = 1'b1;
                end
                3'd2: begin  // Disp32[Rn]
                    f2_am2_am     = AM_DISP32_REG;
                    f2_am2_reg    = f2_am2_lo;
                    f2_am2_imm    = {f2_am2_b4, f2_am2_b3, f2_am2_b2, f2_am2_b1};
                    f2_am2_len    = 6'd5;
                    f2_am2_is_mem = 1'b1;
                end
                3'd3: begin  // Register Indirect [Rn]
                    f2_am2_am     = AM_REG_INDIRECT;
                    f2_am2_reg    = f2_am2_lo;
                    f2_am2_len    = 6'd1;
                    f2_am2_is_mem = 1'b1;
                end
                3'd4: begin  // DispInd8[Rn]
                    f2_am2_am             = AM_DISP16_REG;
                    f2_am2_reg            = f2_am2_lo;
                    f2_am2_imm            = {{24{f2_am2_b1[7]}}, f2_am2_b1};
                    f2_am2_len            = 6'd2;
                    f2_am2_is_mem         = 1'b1;
                    f2_am2_needs_indirect = 1'b1;
                end
                3'd5: begin  // DispInd16[Rn]
                    f2_am2_am             = AM_DISP16_REG;
                    f2_am2_reg            = f2_am2_lo;
                    f2_am2_imm            = {{16{f2_am2_b2[7]}}, f2_am2_b2, f2_am2_b1};
                    f2_am2_len            = 6'd3;
                    f2_am2_is_mem         = 1'b1;
                    f2_am2_needs_indirect = 1'b1;
                end
                3'd6: begin  // DispInd32[Rn]
                    f2_am2_am             = AM_DISP32_REG;
                    f2_am2_reg            = f2_am2_lo;
                    f2_am2_imm            = {f2_am2_b4, f2_am2_b3, f2_am2_b2, f2_am2_b1};
                    f2_am2_len            = 6'd5;
                    f2_am2_is_mem         = 1'b1;
                    f2_am2_needs_indirect = 1'b1;
                end
                3'd7: begin  // Group7
                    if (f2_am2_lo <= 5'd15) begin
                        f2_am2_am  = AM_IMM_QUICK;
                        f2_am2_imm = {27'd0, f2_am2_lo};
                        f2_am2_len = 6'd1;
                    end else if (f2_am2_lo == 5'd16) begin
                        f2_am2_am     = AM_PC_DISP16;
                        f2_am2_imm    = {{24{f2_am2_b1[7]}}, f2_am2_b1};
                        f2_am2_len    = 6'd2;
                        f2_am2_is_mem = 1'b1;
                    end else if (f2_am2_lo == 5'd17) begin
                        f2_am2_am     = AM_PC_DISP16;
                        f2_am2_imm    = {{16{f2_am2_b2[7]}}, f2_am2_b2, f2_am2_b1};
                        f2_am2_len    = 6'd3;
                        f2_am2_is_mem = 1'b1;
                    end else if (f2_am2_lo == 5'd18) begin
                        f2_am2_am     = AM_PC_DISP32;
                        f2_am2_imm    = {f2_am2_b4, f2_am2_b3, f2_am2_b2, f2_am2_b1};
                        f2_am2_len    = 6'd5;
                        f2_am2_is_mem = 1'b1;
                    end else if (f2_am2_lo == 5'd19) begin
                        f2_am2_am     = AM_DIRECT_ADDR;
                        f2_am2_imm    = {f2_am2_b4, f2_am2_b3, f2_am2_b2, f2_am2_b1};
                        f2_am2_len    = 6'd5;
                        f2_am2_is_mem = 1'b1;
                    end else if (f2_am2_lo == 5'd20) begin
                        // Immediate: for AM2 always word (4 bytes)
                        f2_am2_am  = AM_IMMEDIATE;
                        f2_am2_imm = f2_am2_imm_val;
                        f2_am2_len = 6'd5; // 1 mod byte + 4 imm bytes
                    end else if (f2_am2_lo == 5'd24) begin
                        f2_am2_am             = AM_PC_DISP16;
                        f2_am2_imm            = {{24{f2_am2_b1[7]}}, f2_am2_b1};
                        f2_am2_len            = 6'd2;
                        f2_am2_is_mem         = 1'b1;
                        f2_am2_needs_indirect = 1'b1;
                    end else if (f2_am2_lo == 5'd25) begin
                        f2_am2_am             = AM_PC_DISP16;
                        f2_am2_imm            = {{16{f2_am2_b2[7]}}, f2_am2_b2, f2_am2_b1};
                        f2_am2_len            = 6'd3;
                        f2_am2_is_mem         = 1'b1;
                        f2_am2_needs_indirect = 1'b1;
                    end else if (f2_am2_lo == 5'd26) begin
                        f2_am2_am             = AM_PC_DISP32;
                        f2_am2_imm            = {f2_am2_b4, f2_am2_b3, f2_am2_b2, f2_am2_b1};
                        f2_am2_len            = 6'd5;
                        f2_am2_is_mem         = 1'b1;
                        f2_am2_needs_indirect = 1'b1;
                    end else if (f2_am2_lo == 5'd27) begin
                        f2_am2_am             = AM_DIRECT_ADDR;
                        f2_am2_imm            = {f2_am2_b4, f2_am2_b3, f2_am2_b2, f2_am2_b1};
                        f2_am2_len            = 6'd5;
                        f2_am2_is_mem         = 1'b1;
                        f2_am2_needs_indirect = 1'b1;
                    end else if (f2_am2_lo == 5'd28) begin
                        f2_am2_am             = AM_PC_DISP16;
                        f2_am2_imm            = {{24{f2_am2_b1[7]}}, f2_am2_b1};
                        f2_am2_imm2           = {{24{f2_am2_b2[7]}}, f2_am2_b2};
                        f2_am2_len            = 6'd3;
                        f2_am2_is_mem         = 1'b1;
                        f2_am2_needs_indirect = 1'b1;
                    end else if (f2_am2_lo == 5'd29) begin
                        f2_am2_am             = AM_PC_DISP16;
                        f2_am2_imm            = {{16{f2_am2_b2[7]}}, f2_am2_b2, f2_am2_b1};
                        f2_am2_imm2           = {{16{f2_am2_b4[7]}}, f2_am2_b4, f2_am2_b3};
                        f2_am2_len            = 6'd5;
                        f2_am2_is_mem         = 1'b1;
                        f2_am2_needs_indirect = 1'b1;
                    end else if (f2_am2_lo == 5'd30) begin
                        f2_am2_am             = AM_PC_DISP32;
                        f2_am2_imm            = {f2_am2_b4, f2_am2_b3, f2_am2_b2, f2_am2_b1};
                        f2_am2_imm2           = {f2_am2_b8, f2_am2_b7, f2_am2_b6, f2_am2_b5};
                        f2_am2_len            = 6'd9;
                        f2_am2_is_mem         = 1'b1;
                        f2_am2_needs_indirect = 1'b1;
                    end else begin
                        f2_am2_am  = AM_ERROR;
                        f2_am2_len = 6'd1;
                    end
                end
                default: begin
                    f2_am2_am  = AM_ERROR;
                    f2_am2_len = 6'd1;
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
    logic       f3_mod_needs_indirect;
    logic [31:0] f3_mod_imm2;

    assign f3_mod_hi = fmt3_mod_byte[7:5];
    assign f3_mod_lo = fmt3_mod_byte[4:0];

    // Format III immediate value extraction (at byte offset 2: opcode+modbyte+imm)
    // For Phase 6 control flow ops, data_size is always SZ_WORD (4 bytes)
    logic [31:0] fmt3_imm_val;
    logic [2:0]  fmt3_imm_bytes;
    always_comb begin
        // Derive immediate size from opcode for Format III instructions.
        // TRAP (0xF8/F9) uses SZ_BYTE (1 byte), RETIU/RETIS (0xEA/EB/FA/FB) use SZ_HALF (2 bytes).
        // All other Format III ops use SZ_WORD or ImmQuick (never full immediate).
        case (opcode)
            OP_TRAP_0, OP_TRAP_1: begin
                fmt3_imm_bytes = 3'd1;
                fmt3_imm_val = {24'h0, ibuf_data[2]};
            end
            OP_RETIU_0, OP_RETIU_1, OP_RETIS_0, OP_RETIS_1: begin
                fmt3_imm_bytes = 3'd2;
                fmt3_imm_val = {16'h0, ibuf_data[3], ibuf_data[2]};
            end
            default: begin
                fmt3_imm_bytes = 3'd4;
                fmt3_imm_val = {ibuf_data[5], ibuf_data[4], ibuf_data[3], ibuf_data[2]};
            end
        endcase
    end

    always_comb begin
        f3_mod_am              = AM_ERROR;
        f3_mod_reg             = 5'd0;
        f3_mod_imm             = 32'h0;
        f3_mod_len             = 6'd1;
        f3_mod_is_mem          = 1'b0;
        f3_mod_auto_inc        = 1'b0;
        f3_mod_auto_dec        = 1'b0;
        f3_mod_needs_indirect  = 1'b0;
        f3_mod_imm2            = 32'h0;

        if (fmt3_m) begin
            // m=1 dispatch
            case (f3_mod_hi)
                3'd0: begin  // DblDisp8[Rn]
                    f3_mod_am             = AM_DISP16_REG;
                    f3_mod_reg            = f3_mod_lo;
                    f3_mod_imm            = {{24{ibuf_data[2][7]}}, ibuf_data[2]};
                    f3_mod_imm2           = {{24{ibuf_data[3][7]}}, ibuf_data[3]};
                    f3_mod_len            = 6'd3;
                    f3_mod_is_mem         = 1'b1;
                    f3_mod_needs_indirect = 1'b1;
                end
                3'd1: begin  // DblDisp16[Rn]
                    f3_mod_am             = AM_DISP16_REG;
                    f3_mod_reg            = f3_mod_lo;
                    f3_mod_imm            = {{16{ibuf_data[3][7]}}, ibuf_data[3], ibuf_data[2]};
                    f3_mod_imm2           = {{16{ibuf_data[5][7]}}, ibuf_data[5], ibuf_data[4]};
                    f3_mod_len            = 6'd5;
                    f3_mod_is_mem         = 1'b1;
                    f3_mod_needs_indirect = 1'b1;
                end
                3'd2: begin  // DblDisp32[Rn]
                    f3_mod_am             = AM_DISP32_REG;
                    f3_mod_reg            = f3_mod_lo;
                    f3_mod_imm            = {ibuf_data[5], ibuf_data[4], ibuf_data[3], ibuf_data[2]};
                    f3_mod_imm2           = {ibuf_data[9], ibuf_data[8], ibuf_data[7], ibuf_data[6]};
                    f3_mod_len            = 6'd9;
                    f3_mod_is_mem         = 1'b1;
                    f3_mod_needs_indirect = 1'b1;
                end
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
                3'd4: begin  // DispInd8[Rn]
                    f3_mod_am             = AM_DISP16_REG;
                    f3_mod_reg            = f3_mod_lo;
                    f3_mod_imm            = {{24{ibuf_data[2][7]}}, ibuf_data[2]};
                    f3_mod_len            = 6'd2;
                    f3_mod_is_mem         = 1'b1;
                    f3_mod_needs_indirect = 1'b1;
                end
                3'd5: begin  // DispInd16[Rn]
                    f3_mod_am             = AM_DISP16_REG;
                    f3_mod_reg            = f3_mod_lo;
                    f3_mod_imm            = {{16{ibuf_data[3][7]}}, ibuf_data[3], ibuf_data[2]};
                    f3_mod_len            = 6'd3;
                    f3_mod_is_mem         = 1'b1;
                    f3_mod_needs_indirect = 1'b1;
                end
                3'd6: begin  // DispInd32[Rn]
                    f3_mod_am             = AM_DISP32_REG;
                    f3_mod_reg            = f3_mod_lo;
                    f3_mod_imm            = {ibuf_data[5], ibuf_data[4], ibuf_data[3], ibuf_data[2]};
                    f3_mod_len            = 6'd5;
                    f3_mod_is_mem         = 1'b1;
                    f3_mod_needs_indirect = 1'b1;
                end
                3'd7: begin  // Group7
                    if (f3_mod_lo <= 5'd15) begin
                        f3_mod_am  = AM_IMM_QUICK;
                        f3_mod_imm = {27'd0, f3_mod_lo};
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
                    end else if (f3_mod_lo == 5'd20) begin
                        // Immediate (mod byte 0xF4): value follows mod byte
                        f3_mod_am  = AM_IMMEDIATE;
                        f3_mod_imm = fmt3_imm_val;
                        f3_mod_len = 6'd1 + {3'd0, fmt3_imm_bytes};
                    end else if (f3_mod_lo == 5'd24) begin
                        // PCDispInd8
                        f3_mod_am             = AM_PC_DISP16;
                        f3_mod_imm            = {{24{ibuf_data[2][7]}}, ibuf_data[2]};
                        f3_mod_len            = 6'd2;
                        f3_mod_is_mem         = 1'b1;
                        f3_mod_needs_indirect = 1'b1;
                    end else if (f3_mod_lo == 5'd25) begin
                        // PCDispInd16
                        f3_mod_am             = AM_PC_DISP16;
                        f3_mod_imm            = {{16{ibuf_data[3][7]}}, ibuf_data[3], ibuf_data[2]};
                        f3_mod_len            = 6'd3;
                        f3_mod_is_mem         = 1'b1;
                        f3_mod_needs_indirect = 1'b1;
                    end else if (f3_mod_lo == 5'd26) begin
                        // PCDispInd32
                        f3_mod_am             = AM_PC_DISP32;
                        f3_mod_imm            = {ibuf_data[5], ibuf_data[4], ibuf_data[3], ibuf_data[2]};
                        f3_mod_len            = 6'd5;
                        f3_mod_is_mem         = 1'b1;
                        f3_mod_needs_indirect = 1'b1;
                    end else if (f3_mod_lo == 5'd27) begin
                        // DirectAddrDeferred
                        f3_mod_am             = AM_DIRECT_ADDR;
                        f3_mod_imm            = {ibuf_data[5], ibuf_data[4], ibuf_data[3], ibuf_data[2]};
                        f3_mod_len            = 6'd5;
                        f3_mod_is_mem         = 1'b1;
                        f3_mod_needs_indirect = 1'b1;
                    end else if (f3_mod_lo == 5'd28) begin
                        // PCDblDisp8
                        f3_mod_am             = AM_PC_DISP16;
                        f3_mod_imm            = {{24{ibuf_data[2][7]}}, ibuf_data[2]};
                        f3_mod_imm2           = {{24{ibuf_data[3][7]}}, ibuf_data[3]};
                        f3_mod_len            = 6'd3;
                        f3_mod_is_mem         = 1'b1;
                        f3_mod_needs_indirect = 1'b1;
                    end else if (f3_mod_lo == 5'd29) begin
                        // PCDblDisp16
                        f3_mod_am             = AM_PC_DISP16;
                        f3_mod_imm            = {{16{ibuf_data[3][7]}}, ibuf_data[3], ibuf_data[2]};
                        f3_mod_imm2           = {{16{ibuf_data[5][7]}}, ibuf_data[5], ibuf_data[4]};
                        f3_mod_len            = 6'd5;
                        f3_mod_is_mem         = 1'b1;
                        f3_mod_needs_indirect = 1'b1;
                    end else if (f3_mod_lo == 5'd30) begin
                        // PCDblDisp32
                        f3_mod_am             = AM_PC_DISP32;
                        f3_mod_imm            = {ibuf_data[5], ibuf_data[4], ibuf_data[3], ibuf_data[2]};
                        f3_mod_imm2           = {ibuf_data[9], ibuf_data[8], ibuf_data[7], ibuf_data[6]};
                        f3_mod_len            = 6'd9;
                        f3_mod_is_mem         = 1'b1;
                        f3_mod_needs_indirect = 1'b1;
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

        // =====================================================================
        // Phase 10: DBCC / TB (opcodes 0xC6, 0xC7)
        // =====================================================================
        end else if (opcode == 8'hC6 || opcode == 8'hC7) begin
            decoded.format    = FMT_VI;
            decoded.ctrl_flow = CF_DBCC;
            decoded.is_branch = 1'b1;
            decoded.cond      = {ibuf_data[1][7:5], opcode[0]};
            decoded.reg_dst   = ibuf_data[1][4:0];
            decoded.imm_value = {{16{ibuf_data[3][7]}}, ibuf_data[3], ibuf_data[2]};
            decoded.inst_len  = 6'd4;
            decode_valid      = (ibuf_valid_count >= 5'd4);

        end else if (opcode == OP_BRK) begin
            decoded.format   = FMT_V;
            decoded.is_nop   = 1'b1;
            decoded.inst_len = 6'd1;

        end else if (opcode == OP_BRKV) begin
            decoded.format    = FMT_V;
            decoded.ctrl_flow = CF_BRKV;
            decoded.inst_len  = 6'd1;

        end else if (opcode == OP_RSR) begin
            decoded.format    = FMT_V;
            decoded.ctrl_flow = CF_RSR;
            decoded.inst_len  = 6'd1;

        end else if (opcode == OP_DISPOSE) begin
            decoded.format    = FMT_V;
            decoded.ctrl_flow = CF_DISPOSE;
            decoded.inst_len  = 6'd1;

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
        // BSR: 3-byte fixed format (opcode + 16-bit signed displacement)
        // =====================================================================
        end else if (opcode == OP_BSR) begin
            decoded.format    = FMT_IV;
            decoded.ctrl_flow = CF_BSR;
            decoded.is_branch = 1'b1;
            decoded.imm_value = {{16{disp16[15]}}, disp16};
            decoded.inst_len  = 6'd3;
            decode_valid      = (ibuf_valid_count >= 5'd3);

        // =====================================================================
        // Format II: Floating point dual-AM (0x5C, 0x5F)
        // Byte 0: opcode, Byte 1: [6]=m1/[5]=m2/[4:0]=subop
        // Bytes 2+: AM1 field, then AM2 field
        // =====================================================================
        end else if (is_fmt2_fp && fmt2_fp_op != FP_NONE && ibuf_valid_count >= 5'd2) begin
            decoded.format    = FMT_II;
            decoded.data_size = SZ_WORD;
            decoded.fp_op     = fmt2_fp_op;

            // AM1 → source fields (reuse f1_mod decode, which uses ibuf_data[1][6] as m-bit)
            decoded.am_src         = f1_mod_am;
            decoded.reg_src        = f1_mod_reg;
            decoded.imm_value      = f1_mod_imm;
            decoded.is_mem_src     = f1_mod_is_mem;
            decoded.auto_inc       = f1_mod_auto_inc;
            decoded.auto_dec       = f1_mod_auto_dec;
            decoded.needs_indirect = f1_mod_needs_indirect;
            decoded.imm_value2     = f1_mod_imm2;

            // AM2 → destination fields
            decoded.am_dst          = f2_am2_am;
            decoded.reg_dst         = f2_am2_reg;
            decoded.imm_value_dst   = f2_am2_imm;
            decoded.imm_value2_dst  = f2_am2_imm2;
            decoded.is_mem_dst      = f2_am2_is_mem;
            decoded.auto_inc2       = f2_am2_auto_inc;
            decoded.auto_dec2       = f2_am2_auto_dec;
            decoded.needs_indirect2 = f2_am2_needs_indirect;

            // For CMPF, AM2 reads data (ReadAM), not address
            // For R-M-W ops, AM2 reads address (ReadAMAddress) — same AM decode

            // No flags from MOV; all others write flags
            decoded.writes_flags = (fmt2_fp_op != FP_MOVF);

            decoded.inst_len = 6'd2 + f1_mod_len + f2_am2_len;
            decode_valid     = (ibuf_valid_count >= (5'd2 + f1_mod_len[4:0] + f2_am2_len[4:0]));

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
            decoded.needs_indirect = f1_mod_needs_indirect;
            decoded.imm_value2     = f1_mod_imm2;

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
            // RVBIT/RVBYT do not modify flags
            decoded.writes_flags = (fmt1_alu_op != ALU_MOV &&
                                    fmt1_alu_op != ALU_RVBIT && fmt1_alu_op != ALU_RVBYT);
            decoded.src_is_byte  = fmt1_src_is_byte;

            // Phase 8: sys op overrides
            if (is_fmt1_sys) begin
                decoded.data_size    = fmt1_src_size;
                decoded.dst_size     = fmt1_dst_size;
                decoded.sys_op       = fmt1_sys_op;
                decoded.writes_flags = (fmt1_sys_op == SYS_MOVT);
            end else begin
                decoded.dst_size = fmt1_size;
            end

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
            decoded.format         = FMT_III;
            decoded.is_getpsw      = 1'b1;
            decoded.data_size      = SZ_WORD;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.auto_inc       = f3_mod_auto_inc;
            decoded.auto_dec       = f3_mod_auto_dec;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format III: INC/DEC (opcode LSB = m bit)
        // DEC: 0xD0-0xD5, INC: 0xD8-0xDD
        // =====================================================================
        end else if (opcode == OP_INC_B_0 || opcode == OP_INC_B_1) begin
            decoded.format         = FMT_III;
            decoded.alu_op         = ALU_INC;
            decoded.data_size      = SZ_BYTE;
            decoded.writes_flags   = 1'b1;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.auto_inc       = f3_mod_auto_inc;
            decoded.auto_dec       = f3_mod_auto_dec;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));
        end else if (opcode == OP_INC_H_0 || opcode == OP_INC_H_1) begin
            decoded.format         = FMT_III;
            decoded.alu_op         = ALU_INC;
            decoded.data_size      = SZ_HALF;
            decoded.writes_flags   = 1'b1;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.auto_inc       = f3_mod_auto_inc;
            decoded.auto_dec       = f3_mod_auto_dec;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));
        end else if (opcode == OP_INC_W_0 || opcode == OP_INC_W_1) begin
            decoded.format         = FMT_III;
            decoded.alu_op         = ALU_INC;
            decoded.data_size      = SZ_WORD;
            decoded.writes_flags   = 1'b1;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.auto_inc       = f3_mod_auto_inc;
            decoded.auto_dec       = f3_mod_auto_dec;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));
        end else if (opcode == OP_DEC_B_0 || opcode == OP_DEC_B_1) begin
            decoded.format         = FMT_III;
            decoded.alu_op         = ALU_DEC;
            decoded.data_size      = SZ_BYTE;
            decoded.writes_flags   = 1'b1;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.auto_inc       = f3_mod_auto_inc;
            decoded.auto_dec       = f3_mod_auto_dec;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));
        end else if (opcode == OP_DEC_H_0 || opcode == OP_DEC_H_1) begin
            decoded.format         = FMT_III;
            decoded.alu_op         = ALU_DEC;
            decoded.data_size      = SZ_HALF;
            decoded.writes_flags   = 1'b1;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.auto_inc       = f3_mod_auto_inc;
            decoded.auto_dec       = f3_mod_auto_dec;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));
        end else if (opcode == OP_DEC_W_0 || opcode == OP_DEC_W_1) begin
            decoded.format         = FMT_III;
            decoded.alu_op         = ALU_DEC;
            decoded.data_size      = SZ_WORD;
            decoded.writes_flags   = 1'b1;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.auto_inc       = f3_mod_auto_inc;
            decoded.auto_dec       = f3_mod_auto_dec;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format III: JMP (0xD6/0xD7) — address operand (jump to effective addr)
        // Uses ReadAMAddress: the effective address IS the target, not a value.
        // =====================================================================
        end else if (opcode == OP_JMP_0 || opcode == OP_JMP_1) begin
            decoded.format         = FMT_III;
            decoded.ctrl_flow      = CF_JMP;
            decoded.is_branch      = 1'b1;
            decoded.data_size      = SZ_WORD;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format III: JSR (0xE8/0xE9) — address operand (push ret addr, jump)
        // =====================================================================
        end else if (opcode == OP_JSR_0 || opcode == OP_JSR_1) begin
            decoded.format         = FMT_III;
            decoded.ctrl_flow      = CF_JSR;
            decoded.is_branch      = 1'b1;
            decoded.data_size      = SZ_WORD;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format III: RET (0xE2/0xE3) — value operand (cleanup size)
        // =====================================================================
        end else if (opcode == OP_RET_0 || opcode == OP_RET_1) begin
            decoded.format         = FMT_III;
            decoded.ctrl_flow      = CF_RET;
            decoded.is_branch      = 1'b1;
            decoded.data_size      = SZ_WORD;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format III: PREPARE (0xDE/0xDF) — value operand (local frame size)
        // =====================================================================
        end else if (opcode == OP_PREPARE_0 || opcode == OP_PREPARE_1) begin
            decoded.format         = FMT_III;
            decoded.ctrl_flow      = CF_PREPARE;
            decoded.data_size      = SZ_WORD;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format III: PUSH (0xEE/0xEF) — value operand (always 32-bit)
        // =====================================================================
        end else if (opcode == OP_PUSH_0 || opcode == OP_PUSH_1) begin
            decoded.format         = FMT_III;
            decoded.ctrl_flow      = CF_PUSH;
            decoded.data_size      = SZ_WORD;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format III: POP (0xE6/0xE7) — destination operand (always 32-bit)
        // =====================================================================
        end else if (opcode == OP_POP_0 || opcode == OP_POP_1) begin
            decoded.format         = FMT_III;
            decoded.ctrl_flow      = CF_POP;
            decoded.data_size      = SZ_WORD;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format III: PUSHM (0xEC/0xED) — value operand (32-bit bitmap)
        // =====================================================================
        end else if (opcode == OP_PUSHM_0 || opcode == OP_PUSHM_1) begin
            decoded.format         = FMT_III;
            decoded.ctrl_flow      = CF_PUSHM;
            decoded.data_size      = SZ_WORD;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format III: POPM (0xE4/0xE5) — value operand (32-bit bitmap)
        // =====================================================================
        end else if (opcode == OP_POPM_0 || opcode == OP_POPM_1) begin
            decoded.format         = FMT_III;
            decoded.ctrl_flow      = CF_POPM;
            decoded.data_size      = SZ_WORD;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format III: TASI (0xE0/0xE1) — test-and-set byte
        // =====================================================================
        end else if (opcode == OP_TASI_0 || opcode == OP_TASI_1) begin
            decoded.format         = FMT_III;
            decoded.data_size      = SZ_BYTE;
            decoded.writes_flags   = 1'b1;
            decoded.sys_op         = SYS_TASI;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.auto_inc       = f3_mod_auto_inc;
            decoded.auto_dec       = f3_mod_auto_dec;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format III: TRAP (0xF8/0xF9) — conditional software trap
        // =====================================================================
        end else if (opcode == OP_TRAP_0 || opcode == OP_TRAP_1) begin
            decoded.format         = FMT_III;
            decoded.ctrl_flow      = CF_TRAP;
            decoded.data_size      = SZ_BYTE;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format III: RETIU (0xEA/0xEB) — return from interrupt (user)
        // =====================================================================
        end else if (opcode == OP_RETIU_0 || opcode == OP_RETIU_1) begin
            decoded.format         = FMT_III;
            decoded.ctrl_flow      = CF_RETIU;
            decoded.data_size      = SZ_HALF;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format III: RETIS (0xFA/0xFB) — return from interrupt (supervisor)
        // =====================================================================
        end else if (opcode == OP_RETIS_0 || opcode == OP_RETIS_1) begin
            decoded.format         = FMT_III;
            decoded.ctrl_flow      = CF_RETIU;  // Same behavior as RETIU
            decoded.data_size      = SZ_HALF;
            decoded.am_dst         = f3_mod_am;
            decoded.reg_dst        = f3_mod_reg;
            decoded.imm_value      = f3_mod_imm;
            decoded.is_mem_dst     = f3_mod_is_mem;
            decoded.needs_indirect = f3_mod_needs_indirect;
            decoded.imm_value2     = f3_mod_imm2;
            decoded.inst_len       = 6'd1 + f3_mod_len;
            decode_valid           = (ibuf_valid_count >= (5'd1 + f3_mod_len[4:0]));

        // =====================================================================
        // Format I: Recognize 0x80-0xBF range even for Format II encoding
        // (for forward compatibility; treat as unimplemented for now)
        // =====================================================================
        end else if (opcode[7:4] >= 4'h8 && opcode[7:4] <= 4'hB) begin
            decoded.format   = FMT_I;
            decoded.inst_len = 6'd3;
            decode_valid     = (ibuf_valid_count >= 5'd3);

        // Format VII: String/bitfield/decimal (0x58, 0x59, 0x5A, 0x5B, 0x5D)
        // These are fully handled by DPI-C; RTL just needs to identify them
        end else if (opcode == OP_STR_58 || opcode == OP_STR_59 ||
                     opcode == OP_STR_5A || opcode == OP_STR_5B ||
                     opcode == OP_STR_5D) begin
            if (ibuf_valid_count >= 5'd2) begin
                decoded.format   = FMT_VII;
                decoded.inst_len = 6'd2; // placeholder; real length from DPI
            end else begin
                decode_valid = 1'b0; // stall until we have opcode + subop
            end

        // Format II FP recognized but not enough bytes yet — stall
        end else if (is_fmt2_fp) begin
            decode_valid = 1'b0;

        end else begin
            // Unknown opcode — treat as 1-byte NOP for now
            decoded.format   = FMT_V;
            decoded.inst_len = 6'd1;
        end
    end

endmodule
