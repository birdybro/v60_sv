// v60_pkg.sv — Shared package for NEC V60 CPU
// Types, constants, enums, register indices, PSW bit positions, reset values

/* verilator lint_off UNUSEDPARAM */
package v60_pkg;

    // =========================================================================
    // Data size encoding (used throughout for B/H/W variants)
    // =========================================================================
    typedef enum logic [1:0] {
        SZ_BYTE = 2'b00,
        SZ_HALF = 2'b01,
        SZ_WORD = 2'b10,
        SZ_RSVD = 2'b11
    } data_size_t;

    // =========================================================================
    // PSW bit positions
    // =========================================================================
    // Integer condition codes (lower halfword)
    localparam int PSW_Z   = 0;   // Zero
    localparam int PSW_S   = 1;   // Sign
    localparam int PSW_OV  = 2;   // Overflow
    localparam int PSW_CY  = 3;   // Carry

    // Floating point condition codes
    localparam int PSW_FD  = 8;   // FP Denormalized
    localparam int PSW_FV  = 9;   // FP Overflow
    localparam int PSW_FU  = 10;  // FP Underflow
    localparam int PSW_FO  = 11;  // FP Operand error
    localparam int PSW_FZ  = 12;  // FP Zero

    // Upper halfword (privileged/status)
    localparam int PSW_NP  = 16;  // Nested exception/trap pending
    localparam int PSW_TE  = 17;  // Trace enable
    localparam int PSW_ID  = 18;  // Interrupt disable
    localparam int PSW_EL0 = 24;  // Execution level bit 0
    localparam int PSW_EL1 = 25;  // Execution level bit 1
    localparam int PSW_IS  = 28;  // Interrupt stack select

    // =========================================================================
    // Execution levels
    // =========================================================================
    typedef enum logic [1:0] {
        EL_0 = 2'b00,  // Most privileged (kernel)
        EL_1 = 2'b01,
        EL_2 = 2'b10,
        EL_3 = 2'b11   // Least privileged (user)
    } exec_level_t;

    // =========================================================================
    // General purpose register aliases
    // =========================================================================
    localparam int REG_AP  = 29;  // Argument Pointer
    localparam int REG_FP  = 30;  // Frame Pointer
    localparam int REG_SP  = 31;  // Stack Pointer (cached)

    // =========================================================================
    // Privileged register indices (for LDPR/STPR)
    // =========================================================================
    localparam int PREG_ISP    = 0;
    localparam int PREG_L0SP   = 1;
    localparam int PREG_L1SP   = 2;
    localparam int PREG_L2SP   = 3;
    localparam int PREG_L3SP   = 4;
    localparam int PREG_SBR    = 5;
    localparam int PREG_TR     = 6;
    localparam int PREG_SYCW   = 7;
    localparam int PREG_TKCW   = 8;
    localparam int PREG_PIR    = 9;
    localparam int PREG_PSW2   = 15;
    localparam int PREG_ATBR0  = 16;
    localparam int PREG_ATLR0  = 17;
    localparam int PREG_ATBR1  = 18;
    localparam int PREG_ATLR1  = 19;
    localparam int PREG_ATBR2  = 20;
    localparam int PREG_ATLR2  = 21;
    localparam int PREG_ATBR3  = 22;
    localparam int PREG_ATLR3  = 23;
    localparam int PREG_TRMOD  = 24;
    localparam int PREG_ADTR0  = 25;
    localparam int PREG_ADTMR0 = 26;
    localparam int PREG_ADTR1  = 27;
    localparam int PREG_ADTMR1 = 28;
    localparam int NUM_PREG    = 32;

    // =========================================================================
    // Instruction formats
    // =========================================================================
    typedef enum logic [2:0] {
        FMT_I    = 3'd0,  // Two-operand: reg + mem/reg
        FMT_II   = 3'd1,  // Two-operand: mem/reg + mem/reg (extended opcode)
        FMT_III  = 3'd2,  // Single operand
        FMT_IV   = 3'd3,  // PC-relative (branches)
        FMT_V    = 3'd4,  // No operand (NOP, HALT, etc.)
        FMT_VI   = 3'd5,  // Loop (decrement-and-branch)
        FMT_VII  = 3'd6   // String/bitfield/decimal
    } inst_format_t;

    // =========================================================================
    // ALU operations
    // =========================================================================
    typedef enum logic [4:0] {
        ALU_ADD   = 5'd0,
        ALU_SUB   = 5'd1,
        ALU_AND   = 5'd2,
        ALU_OR    = 5'd3,
        ALU_XOR   = 5'd4,
        ALU_NOT   = 5'd5,
        ALU_NEG   = 5'd6,
        ALU_MOV   = 5'd7,
        ALU_CMP   = 5'd8,
        ALU_ADDC  = 5'd9,
        ALU_SUBC  = 5'd10,
        ALU_SHL   = 5'd11,
        ALU_SHA   = 5'd12,
        ALU_ROT   = 5'd13,
        ALU_ROTC  = 5'd14,
        ALU_MUL   = 5'd15,
        ALU_MULU  = 5'd16,
        ALU_DIV   = 5'd17,
        ALU_DIVU  = 5'd18,
        ALU_INC   = 5'd19,
        ALU_DEC   = 5'd20,
        ALU_REM   = 5'd21,
        ALU_REMU  = 5'd22,
        ALU_SET1  = 5'd23,
        ALU_CLR1  = 5'd24,
        ALU_NOT1  = 5'd25,
        ALU_TEST1 = 5'd26,
        ALU_NOP   = 5'd31
    } alu_op_t;

    // =========================================================================
    // Addressing modes
    // =========================================================================
    typedef enum logic [4:0] {
        AM_REGISTER          = 5'd0,
        AM_REG_INDIRECT      = 5'd1,
        AM_REG_INDIRECT_INC  = 5'd2,
        AM_REG_INDIRECT_DEC  = 5'd3,
        AM_DISP16_REG        = 5'd4,
        AM_DISP32_REG        = 5'd5,
        AM_INDEXED_DISP16    = 5'd6,
        AM_INDEXED_DISP32    = 5'd7,
        AM_DIRECT_ADDR       = 5'd8,
        AM_DIRECT_ADDR_DEFERRED = 5'd9,
        AM_PC_DISP16         = 5'd10,
        AM_PC_DISP32         = 5'd11,
        AM_PC_INDEXED_DISP16 = 5'd12,
        AM_PC_INDEXED_DISP32 = 5'd13,
        AM_DISP16_INDIRECT   = 5'd14,
        AM_DISP32_INDIRECT   = 5'd15,
        AM_DOUBLE_DISP       = 5'd16,
        AM_IMMEDIATE         = 5'd17,
        AM_IMM_QUICK         = 5'd18,
        AM_ERROR             = 5'd31
    } addr_mode_t;

    // =========================================================================
    // Main FSM states (v60_control)
    // =========================================================================
    typedef enum logic [4:0] {
        ST_RESET         = 5'd0,
        ST_FETCH         = 5'd1,
        ST_DECODE        = 5'd2,
        ST_ADDR_MODE_1   = 5'd3,
        ST_ADDR_MODE_2   = 5'd4,
        ST_EXECUTE       = 5'd5,
        ST_WRITEBACK     = 5'd6,
        ST_MEM_READ      = 5'd7,
        ST_MEM_WRITE     = 5'd8,
        ST_HALT          = 5'd9,
        ST_INT_CHECK     = 5'd10,
        ST_INT_ACK       = 5'd11,
        ST_INT_PUSH_PSW  = 5'd12,
        ST_INT_PUSH_PC   = 5'd13,
        ST_INT_VECTOR    = 5'd14,
        ST_STRING_LOOP   = 5'd15,
        ST_FETCH_WAIT    = 5'd16,
        ST_MEM_READ_WAIT = 5'd17,
        ST_MEM_WRITE_WAIT= 5'd18,
        ST_RESET_VEC     = 5'd19,
        ST_RESET_VEC_WAIT= 5'd20,
        ST_EXECUTE2      = 5'd21
    } fsm_state_t;

    // =========================================================================
    // Bus interface request type
    // =========================================================================
    typedef enum logic [1:0] {
        BUS_IDLE  = 2'b00,
        BUS_READ  = 2'b01,
        BUS_WRITE = 2'b10,
        BUS_IACK  = 2'b11
    } bus_req_t;

    // =========================================================================
    // Branch condition codes (lower nibble of Bcc opcode)
    // =========================================================================
    localparam logic [3:0] CC_BV   = 4'h0;
    localparam logic [3:0] CC_BNV  = 4'h1;
    localparam logic [3:0] CC_BL   = 4'h2;  // aka BC
    localparam logic [3:0] CC_BNL  = 4'h3;  // aka BNC
    localparam logic [3:0] CC_BE   = 4'h4;  // aka BZ
    localparam logic [3:0] CC_BNE  = 4'h5;  // aka BNZ
    localparam logic [3:0] CC_BNH  = 4'h6;
    localparam logic [3:0] CC_BH   = 4'h7;
    localparam logic [3:0] CC_BN   = 4'h8;
    localparam logic [3:0] CC_BP   = 4'h9;
    localparam logic [3:0] CC_BR   = 4'hA;  // Always
    localparam logic [3:0] CC_NOP  = 4'hB;  // Never
    localparam logic [3:0] CC_BLT  = 4'hC;
    localparam logic [3:0] CC_BGE  = 4'hD;
    localparam logic [3:0] CC_BLE  = 4'hE;
    localparam logic [3:0] CC_BGT  = 4'hF;

    // =========================================================================
    // Control flow instruction type
    // =========================================================================
    typedef enum logic [3:0] {
        CF_NONE    = 4'd0,
        CF_JMP     = 4'd1,
        CF_JSR     = 4'd2,
        CF_BSR     = 4'd3,
        CF_RET     = 4'd4,
        CF_PREPARE = 4'd5,
        CF_DISPOSE = 4'd6,
        CF_PUSH    = 4'd7,
        CF_POP     = 4'd8,
        CF_PUSHM   = 4'd9,
        CF_POPM    = 4'd10
    } ctrl_flow_t;

    // =========================================================================
    // Key opcodes (verified against MAME optable.hxx)
    // =========================================================================
    localparam logic [7:0] OP_HALT    = 8'h00;
    localparam logic [7:0] OP_NOP     = 8'hCD;
    localparam logic [7:0] OP_RSR     = 8'hCA;
    localparam logic [7:0] OP_BRK     = 8'hC8;
    localparam logic [7:0] OP_BRKV    = 8'hC9;
    localparam logic [7:0] OP_TRAPFL  = 8'hCB;
    localparam logic [7:0] OP_DISPOSE = 8'hCC;
    localparam logic [7:0] OP_BSR     = 8'h48;
    localparam logic [7:0] OP_CALL    = 8'h49;

    // Format III opcodes (LSB = m bit, pairs of consecutive opcodes)
    localparam logic [7:0] OP_GETPSW_0 = 8'hF6;
    localparam logic [7:0] OP_GETPSW_1 = 8'hF7;
    localparam logic [7:0] OP_RET_0    = 8'hE2;
    localparam logic [7:0] OP_RET_1    = 8'hE3;
    localparam logic [7:0] OP_TRAP_0   = 8'hF8;
    localparam logic [7:0] OP_TRAP_1   = 8'hF9;
    localparam logic [7:0] OP_RETIU_0  = 8'hEA;
    localparam logic [7:0] OP_RETIU_1  = 8'hEB;
    localparam logic [7:0] OP_RETIS_0  = 8'hFA;
    localparam logic [7:0] OP_RETIS_1  = 8'hFB;
    localparam logic [7:0] OP_JMP_0    = 8'hD6;
    localparam logic [7:0] OP_JMP_1    = 8'hD7;
    localparam logic [7:0] OP_JSR_0    = 8'hE8;
    localparam logic [7:0] OP_JSR_1    = 8'hE9;
    localparam logic [7:0] OP_PUSH_0   = 8'hEE;
    localparam logic [7:0] OP_PUSH_1   = 8'hEF;
    localparam logic [7:0] OP_POP_0    = 8'hE6;
    localparam logic [7:0] OP_POP_1    = 8'hE7;
    localparam logic [7:0] OP_PUSHM_0  = 8'hEC;
    localparam logic [7:0] OP_PUSHM_1  = 8'hED;
    localparam logic [7:0] OP_POPM_0   = 8'hE4;
    localparam logic [7:0] OP_POPM_1   = 8'hE5;
    localparam logic [7:0] OP_PREPARE_0 = 8'hDE;
    localparam logic [7:0] OP_PREPARE_1 = 8'hDF;

    // Branch opcode nibble identification
    localparam logic [3:0] OP_BCC_SHORT_HI = 4'h6;
    localparam logic [3:0] OP_BCC_LONG_HI  = 4'h7;

    // Format I opcodes (two-operand, verified against MAME optable.hxx)
    // MOV family (0x09, 0x1B, 0x2D)
    localparam logic [7:0] OP_MOV_B   = 8'h09;
    localparam logic [7:0] OP_MOV_H   = 8'h1B;
    localparam logic [7:0] OP_MOV_W   = 8'h2D;
    // ALU ops: base + 0=byte, +2=half, +4=word
    localparam logic [7:0] OP_ADD_B   = 8'h80;
    localparam logic [7:0] OP_ADD_H   = 8'h82;
    localparam logic [7:0] OP_ADD_W   = 8'h84;
    localparam logic [7:0] OP_MUL_B   = 8'h81;
    localparam logic [7:0] OP_MUL_H   = 8'h83;
    localparam logic [7:0] OP_MUL_W   = 8'h85;
    localparam logic [7:0] OP_OR_B    = 8'h88;
    localparam logic [7:0] OP_OR_H    = 8'h8A;
    localparam logic [7:0] OP_OR_W    = 8'h8C;
    localparam logic [7:0] OP_ADDC_B  = 8'h90;
    localparam logic [7:0] OP_ADDC_H  = 8'h92;
    localparam logic [7:0] OP_ADDC_W  = 8'h94;
    localparam logic [7:0] OP_SUBC_B  = 8'h98;
    localparam logic [7:0] OP_SUBC_H  = 8'h9A;
    localparam logic [7:0] OP_SUBC_W  = 8'h9C;
    localparam logic [7:0] OP_AND_B   = 8'hA0;
    localparam logic [7:0] OP_AND_H   = 8'hA2;
    localparam logic [7:0] OP_AND_W   = 8'hA4;
    localparam logic [7:0] OP_SUB_B   = 8'hA8;
    localparam logic [7:0] OP_SUB_H   = 8'hAA;
    localparam logic [7:0] OP_SUB_W   = 8'hAC;
    localparam logic [7:0] OP_XOR_B   = 8'hB0;
    localparam logic [7:0] OP_XOR_H   = 8'hB2;
    localparam logic [7:0] OP_XOR_W   = 8'hB4;
    localparam logic [7:0] OP_CMP_B   = 8'hB8;
    localparam logic [7:0] OP_CMP_H   = 8'hBA;
    localparam logic [7:0] OP_CMP_W   = 8'hBC;
    // NOT/NEG (Format I, 0x38-0x3D)
    localparam logic [7:0] OP_NOT_B   = 8'h38;
    localparam logic [7:0] OP_NOT_H   = 8'h3A;
    localparam logic [7:0] OP_NOT_W   = 8'h3C;
    localparam logic [7:0] OP_NEG_B   = 8'h39;
    localparam logic [7:0] OP_NEG_H   = 8'h3B;
    localparam logic [7:0] OP_NEG_W   = 8'h3D;
    // Phase 7: Multiply/Divide/Remainder
    localparam logic [7:0] OP_MULU_B = 8'h91;
    localparam logic [7:0] OP_MULU_H = 8'h93;
    localparam logic [7:0] OP_MULU_W = 8'h95;
    localparam logic [7:0] OP_DIV_B  = 8'hA1;
    localparam logic [7:0] OP_DIV_H  = 8'hA3;
    localparam logic [7:0] OP_DIV_W  = 8'hA5;
    localparam logic [7:0] OP_DIVU_B = 8'hB1;
    localparam logic [7:0] OP_DIVU_H = 8'hB3;
    localparam logic [7:0] OP_DIVU_W = 8'hB5;
    localparam logic [7:0] OP_REM_B  = 8'h50;
    localparam logic [7:0] OP_REM_H  = 8'h52;
    localparam logic [7:0] OP_REM_W  = 8'h54;
    localparam logic [7:0] OP_REMU_B = 8'h51;
    localparam logic [7:0] OP_REMU_H = 8'h53;
    localparam logic [7:0] OP_REMU_W = 8'h55;
    // Phase 7: Shift/Rotate
    localparam logic [7:0] OP_SHL_B  = 8'hA9;
    localparam logic [7:0] OP_SHL_H  = 8'hAB;
    localparam logic [7:0] OP_SHL_W  = 8'hAD;
    localparam logic [7:0] OP_SHA_B  = 8'hB9;
    localparam logic [7:0] OP_SHA_H  = 8'hBB;
    localparam logic [7:0] OP_SHA_W  = 8'hBD;
    localparam logic [7:0] OP_ROT_B  = 8'h89;
    localparam logic [7:0] OP_ROT_H  = 8'h8B;
    localparam logic [7:0] OP_ROT_W  = 8'h8D;
    localparam logic [7:0] OP_ROTC_B = 8'h99;
    localparam logic [7:0] OP_ROTC_H = 8'h9B;
    localparam logic [7:0] OP_ROTC_W = 8'h9D;
    // Phase 7: Bit operations
    localparam logic [7:0] OP_TEST1  = 8'h87;
    localparam logic [7:0] OP_SET1   = 8'h97;
    localparam logic [7:0] OP_CLR1   = 8'hA7;
    localparam logic [7:0] OP_NOT1   = 8'hB7;
    // INC/DEC (Format III, opcode LSB = m bit)
    localparam logic [7:0] OP_DEC_B_0 = 8'hD0;
    localparam logic [7:0] OP_DEC_B_1 = 8'hD1;
    localparam logic [7:0] OP_DEC_H_0 = 8'hD2;
    localparam logic [7:0] OP_DEC_H_1 = 8'hD3;
    localparam logic [7:0] OP_DEC_W_0 = 8'hD4;
    localparam logic [7:0] OP_DEC_W_1 = 8'hD5;
    localparam logic [7:0] OP_INC_B_0 = 8'hD8;
    localparam logic [7:0] OP_INC_B_1 = 8'hD9;
    localparam logic [7:0] OP_INC_H_0 = 8'hDA;
    localparam logic [7:0] OP_INC_H_1 = 8'hDB;
    localparam logic [7:0] OP_INC_W_0 = 8'hDC;
    localparam logic [7:0] OP_INC_W_1 = 8'hDD;

    // =========================================================================
    // Reset vector address
    // =========================================================================
    localparam logic [31:0] RESET_VECTOR_ADDR = 32'hFFFFFFF0;

    // =========================================================================
    // Instruction buffer parameters
    // =========================================================================
    localparam int IBUF_SIZE    = 24;
    localparam int MAX_INST_LEN = 22;
    localparam int FETCH_WINDOW = 12;

    // =========================================================================
    // Addressing mode encoding (mod field, byte after opcode in Format I/III)
    // Dispatch: s_AMTable[m][mod_byte>>5]
    // m=0: 0=Disp8, 1=Disp16, 2=Disp32, 3=RegIndirect, 4=DispInd8, 5=DispInd16, 6=DispInd32, 7=Group7
    // m=1: 0=DblDisp8, 1=DblDisp16, 2=DblDisp32, 3=Register, 4=AutoInc, 5=AutoDec, 6=Group6, 7=Error
    // Group7 (m=0, mod>>5=7): mod[4:0]=0-15: ImmQuick, 16:PCDisp8, 17:PCDisp16, 18:PCDisp32,
    //   19:DirectAddr, 20:Immediate, 24:PCDispInd8, ...
    // =========================================================================
    localparam logic [7:0] MOD_IMMEDIATE = 8'hF4;

    // =========================================================================
    // Decoded instruction bundle
    // =========================================================================
    typedef struct packed {
        logic [7:0]     opcode;
        inst_format_t   format;
        alu_op_t        alu_op;
        data_size_t     data_size;
        logic [4:0]     reg_src;      // Source register (for Format I reg field when d=0, or mod field)
        logic [4:0]     reg_dst;      // Dest register (for Format I reg field when d=1, or mod field)
        addr_mode_t     am_src;       // Source addressing mode
        addr_mode_t     am_dst;       // Destination addressing mode
        logic           dir;          // Format I direction: 0=reg is src, 1=reg is dst
        logic [4:0]     subop;
        logic [3:0]     cond;
        logic           is_branch;
        logic           is_halt;
        logic           is_nop;
        logic           is_getpsw;
        logic           writes_flags; // Instruction updates PSW condition codes
        logic           is_privileged;
        logic [31:0]    imm_value;    // Immediate operand or displacement
        logic [5:0]     inst_len;
        logic           is_mem_src;   // Source operand requires memory access
        logic           is_mem_dst;   // Destination operand requires memory access
        logic           auto_inc;     // Post-increment side effect
        logic           auto_dec;     // Pre-decrement side effect
        logic           needs_indirect; // Pointer dereference needed (indirect/dbldisp modes)
        logic [31:0]    imm_value2;   // Second displacement (DblDisp/PCDblDisp modes)
        ctrl_flow_t     ctrl_flow;    // Control flow instruction type
        logic           src_is_byte;  // Source operand always byte (shift/rotate count)
    } decoded_inst_t;

endpackage
