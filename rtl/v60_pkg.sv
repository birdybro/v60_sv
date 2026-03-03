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
    localparam int PSW_IS  = 19;  // Interrupt stack select
    localparam int PSW_EL0 = 24;  // Execution level bit 0
    localparam int PSW_EL1 = 25;  // Execution level bit 1
    localparam int PSW_DB  = 28;  // Debug mode

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
        ST_RESET_VEC_WAIT= 5'd20
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
    // Key opcodes
    // =========================================================================
    localparam logic [7:0] OP_HALT    = 8'h00;
    localparam logic [7:0] OP_NOP     = 8'hCD;
    localparam logic [7:0] OP_RET     = 8'hBF;
    localparam logic [7:0] OP_RSR     = 8'h9F;
    localparam logic [7:0] OP_GETPSW  = 8'hCC;
    localparam logic [7:0] OP_TRAP    = 8'hE1;
    localparam logic [7:0] OP_RETIU   = 8'hE7;
    localparam logic [7:0] OP_RETIS   = 8'hE6;

    // Branch opcode nibble identification
    localparam logic [3:0] OP_BCC_SHORT_HI = 4'h6;
    localparam logic [3:0] OP_BCC_LONG_HI  = 4'h7;

    // Format I opcodes
    localparam logic [7:0] OP_MOV_B   = 8'h88;
    localparam logic [7:0] OP_MOV_H   = 8'h89;
    localparam logic [7:0] OP_MOV_W   = 8'h8B;
    localparam logic [7:0] OP_ADD_B   = 8'h80;
    localparam logic [7:0] OP_ADD_H   = 8'h81;
    localparam logic [7:0] OP_ADD_W   = 8'h83;
    localparam logic [7:0] OP_SUB_B   = 8'h98;
    localparam logic [7:0] OP_SUB_H   = 8'h99;
    localparam logic [7:0] OP_SUB_W   = 8'h9B;
    localparam logic [7:0] OP_CMP_B   = 8'hA0;
    localparam logic [7:0] OP_CMP_H   = 8'hA1;
    localparam logic [7:0] OP_CMP_W   = 8'hA3;
    localparam logic [7:0] OP_AND_B   = 8'h90;
    localparam logic [7:0] OP_AND_H   = 8'h91;
    localparam logic [7:0] OP_AND_W   = 8'h93;
    localparam logic [7:0] OP_OR_B    = 8'h94;
    localparam logic [7:0] OP_OR_H    = 8'h95;
    localparam logic [7:0] OP_OR_W    = 8'h97;
    localparam logic [7:0] OP_XOR_B   = 8'h84;
    localparam logic [7:0] OP_XOR_H   = 8'h85;
    localparam logic [7:0] OP_XOR_W   = 8'h87;

    // =========================================================================
    // Reset vector address
    // =========================================================================
    localparam logic [31:0] RESET_VECTOR_ADDR = 32'hFFFFFFF0;

    // =========================================================================
    // Instruction buffer parameters
    // =========================================================================
    localparam int IBUF_SIZE    = 24;
    localparam int MAX_INST_LEN = 22;
    localparam int FETCH_WINDOW = 8;

    // =========================================================================
    // Decoded instruction bundle
    // =========================================================================
    typedef struct packed {
        logic [7:0]     opcode;
        inst_format_t   format;
        alu_op_t        alu_op;
        data_size_t     data_size;
        logic [4:0]     reg_src;
        logic [4:0]     reg_dst;
        addr_mode_t     am_src;
        addr_mode_t     am_dst;
        logic           dir;
        logic [4:0]     subop;
        logic [3:0]     cond;
        logic           is_branch;
        logic           is_bsr;
        logic           is_halt;
        logic           is_nop;
        logic           is_privileged;
        logic [31:0]    imm_value;
        logic [5:0]     inst_len;
    } decoded_inst_t;

endpackage
