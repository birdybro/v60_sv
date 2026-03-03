// v60_harness.cpp — Standalone MAME V60 harness with trace output
// This is a placeholder that will be connected to the actual MAME V60 source
// files once they are copied into mame/src/.
//
// For now, it provides the trace format and harness structure.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include "mame_stubs.h"

// =========================================================================
// V60 CPU state (mirrors MAME's internal state)
// =========================================================================
struct V60State {
    uint32_t reg[32];   // General purpose registers R0-R31
    uint32_t pc;        // Program counter
    uint32_t psw;       // Program status word
    uint32_t isp;       // Interrupt stack pointer
    uint32_t l0sp, l1sp, l2sp, l3sp;  // Level stack pointers
    uint32_t sbr;       // System base register
    uint32_t tr;        // Task register
    uint32_t sycw;      // System control word
    uint32_t tkcw;      // Task control word
    uint32_t pir;       // Processor ID register
    uint32_t psw2;      // Emulation PSW

    address_space* program;
    io_space* io;

    bool halted;
    int icount;         // Instruction counter
};

// =========================================================================
// Trace output
// =========================================================================
static void emit_trace_header(FILE* fp) {
    fprintf(fp, "step,PC,PSW");
    for (int i = 0; i < 32; i++)
        fprintf(fp, ",R%d", i);
    fprintf(fp, "\n");
}

static void emit_trace_line(FILE* fp, uint32_t step, const V60State& s) {
    fprintf(fp, "%u,0x%08X,0x%08X", step, s.pc, s.psw);
    for (int i = 0; i < 32; i++)
        fprintf(fp, ",0x%08X", s.reg[i]);
    fprintf(fp, "\n");
}

// =========================================================================
// Addressing mode decoder for mod field
// Returns: operand value (for register/immediate modes)
//          bytes consumed by the mod field
// =========================================================================
struct ModResult {
    uint32_t value;    // Operand value
    int      reg_idx;  // Register index (-1 if not register destination)
    bool     is_reg;   // True if destination is a register
    int      len;      // Bytes consumed
};

static ModResult decode_mod(const V60State& s, uint32_t addr, bool m_bit, int data_size) {
    ModResult r = {0, -1, false, 1};
    uint8_t mod_byte = s.program->read_byte(addr);
    int hi = (mod_byte >> 5) & 7;
    int lo = mod_byte & 0x1F;

    if (m_bit) {
        // m=1 dispatch
        switch (hi) {
            case 3: // Register
                r.value = s.reg[lo];
                r.reg_idx = lo;
                r.is_reg = true;
                r.len = 1;
                break;
            default:
                fprintf(stderr, "MAME harness: unsupported mod m=1 hi=%d at 0x%08X\n", hi, addr);
                r.len = 1;
                break;
        }
    } else {
        // m=0 dispatch
        switch (hi) {
            case 7: // Group7
                if (lo <= 15) {
                    // ImmediateQuick
                    r.value = mod_byte & 0x0F;
                    r.is_reg = false;
                    r.len = 1;
                } else if (lo == 20) {
                    // Immediate (0xF4)
                    r.len = 1;
                    switch (data_size) {
                        case 0: r.value = s.program->read_byte(addr + 1); r.len += 1; break;
                        case 1: r.value = s.program->read_word(addr + 1); r.len += 2; break;
                        case 2: r.value = s.program->read_dword(addr + 1); r.len += 4; break;
                    }
                    r.is_reg = false;
                } else {
                    fprintf(stderr, "MAME harness: unsupported Group7 lo=%d at 0x%08X\n", lo, addr);
                    r.len = 1;
                }
                break;
            default:
                fprintf(stderr, "MAME harness: unsupported mod m=0 hi=%d at 0x%08X\n", hi, addr);
                r.len = 1;
                break;
        }
    }
    return r;
}

// =========================================================================
// Data size from opcode (for Format I instructions)
// Returns: 0=byte, 1=half, 2=word
// =========================================================================
static int get_data_size(uint8_t opcode) {
    switch (opcode) {
        case 0x09: return 0; // MOV.B
        case 0x1B: return 1; // MOV.H
        case 0x2D: return 2; // MOV.W
        default: return 2;
    }
}

// =========================================================================
// ALU data size from opcode (base + 0=byte, +2=half, +4=word)
// =========================================================================
static int alu_data_size(uint8_t opcode) {
    uint8_t low = opcode & 0x07;
    // Even base: B=+0, H=+2, W=+4
    // Odd base (NOT/NEG): B=+0, H=+2, W=+4 but base is odd
    switch (low) {
        case 0: case 1: return 0; // byte
        case 2: case 3: return 1; // half
        case 4: case 5: return 2; // word
        default: return 2;
    }
}

// =========================================================================
// Size mask for ALU operations
// =========================================================================
static uint32_t size_mask(int dsize) {
    switch (dsize) {
        case 0: return 0xFF;
        case 1: return 0xFFFF;
        default: return 0xFFFFFFFF;
    }
}

// =========================================================================
// MSB position for a data size
// =========================================================================
static int msb_pos(int dsize) {
    switch (dsize) {
        case 0: return 7;
        case 1: return 15;
        default: return 31;
    }
}

// =========================================================================
// Compute PSW flags from ALU result
// =========================================================================
static void set_flags_arith(V60State& s, uint64_t sum, uint32_t result, uint32_t a, uint32_t b, int dsize, bool is_sub) {
    uint32_t m = size_mask(dsize);
    int mb = msb_pos(dsize);
    result &= m;
    a &= m;
    b &= m;

    // Clear Z, S, OV, CY
    s.psw &= ~0xFu;

    // Z flag
    if (result == 0) s.psw |= (1 << 0);
    // S flag
    if ((result >> mb) & 1) s.psw |= (1 << 1);
    // CY flag — carry/borrow out of MSB+1
    if ((sum >> (mb + 1)) & 1) s.psw |= (1 << 3);
    // OV flag
    if (is_sub) {
        // Overflow on subtraction: signs of operands differ AND result sign != dest sign
        if (((a >> mb) & 1) != ((b >> mb) & 1) &&
            ((result >> mb) & 1) != ((b >> mb) & 1))
            s.psw |= (1 << 2);
    } else {
        // Overflow on addition: signs of operands same AND result sign differs
        if (((a >> mb) & 1) == ((b >> mb) & 1) &&
            ((result >> mb) & 1) != ((a >> mb) & 1))
            s.psw |= (1 << 2);
    }
}

static void set_flags_logic(V60State& s, uint32_t result, int dsize) {
    uint32_t m = size_mask(dsize);
    int mb = msb_pos(dsize);
    result &= m;

    // Clear Z, S, OV, CY — logic ops clear OV and CY
    s.psw &= ~0xFu;
    if (result == 0) s.psw |= (1 << 0);
    if ((result >> mb) & 1) s.psw |= (1 << 1);
}

// =========================================================================
// Execute Format I ALU operation
// Returns instruction length, or 0 on error
// =========================================================================
enum AluType { ALU_T_ADD, ALU_T_SUB, ALU_T_CMP, ALU_T_AND, ALU_T_OR, ALU_T_XOR,
               ALU_T_ADDC, ALU_T_SUBC, ALU_T_NOT, ALU_T_NEG, ALU_T_MOV };

static int exec_fmt1_alu(V60State& s, uint8_t opcode, AluType atype, int dsize) {
    uint8_t byte1 = s.program->read_byte(s.pc + 1);
    bool m_bit = (byte1 >> 6) & 1;
    bool d_bit = (byte1 >> 5) & 1;
    int reg_field = byte1 & 0x1F;

    ModResult mod = decode_mod(s, s.pc + 2, m_bit, dsize);
    int inst_len = 2 + mod.len;

    uint32_t src_val, dst_val;
    int dst_reg;

    if (d_bit == 0) {
        // reg=source, mod=destination
        src_val = s.reg[reg_field];
        dst_val = mod.is_reg ? s.reg[mod.reg_idx] : 0;
        dst_reg = mod.reg_idx;
    } else {
        // reg=destination, mod=source
        src_val = mod.value;
        dst_val = s.reg[reg_field];
        dst_reg = reg_field;
    }

    uint32_t m = size_mask(dsize);
    src_val &= m;
    dst_val &= m;

    uint32_t result = 0;
    uint64_t sum = 0;

    switch (atype) {
        case ALU_T_ADD:
            sum = (uint64_t)dst_val + (uint64_t)src_val;
            result = (uint32_t)(sum & m);
            set_flags_arith(s, sum, result, src_val, dst_val, dsize, false);
            if (dst_reg >= 0) s.reg[dst_reg] = result;
            break;
        case ALU_T_ADDC: {
            uint32_t cin = (s.psw >> 3) & 1;
            sum = (uint64_t)dst_val + (uint64_t)src_val + cin;
            result = (uint32_t)(sum & m);
            set_flags_arith(s, sum, result, src_val, dst_val, dsize, false);
            if (dst_reg >= 0) s.reg[dst_reg] = result;
            break;
        }
        case ALU_T_SUB:
            sum = (uint64_t)dst_val - (uint64_t)src_val;
            result = (uint32_t)(sum & m);
            set_flags_arith(s, sum, result, src_val, dst_val, dsize, true);
            if (dst_reg >= 0) s.reg[dst_reg] = result;
            break;
        case ALU_T_SUBC: {
            uint32_t cin = (s.psw >> 3) & 1;
            sum = (uint64_t)dst_val - (uint64_t)src_val - cin;
            result = (uint32_t)(sum & m);
            set_flags_arith(s, sum, result, src_val, dst_val, dsize, true);
            if (dst_reg >= 0) s.reg[dst_reg] = result;
            break;
        }
        case ALU_T_CMP:
            sum = (uint64_t)dst_val - (uint64_t)src_val;
            result = (uint32_t)(sum & m);
            set_flags_arith(s, sum, result, src_val, dst_val, dsize, true);
            // CMP: flags only, no writeback
            break;
        case ALU_T_AND:
            result = dst_val & src_val;
            set_flags_logic(s, result, dsize);
            if (dst_reg >= 0) s.reg[dst_reg] = result;
            break;
        case ALU_T_OR:
            result = dst_val | src_val;
            set_flags_logic(s, result, dsize);
            if (dst_reg >= 0) s.reg[dst_reg] = result;
            break;
        case ALU_T_XOR:
            result = dst_val ^ src_val;
            set_flags_logic(s, result, dsize);
            if (dst_reg >= 0) s.reg[dst_reg] = result;
            break;
        case ALU_T_NOT:
            result = (~src_val) & m;
            set_flags_logic(s, result, dsize);
            if (dst_reg >= 0) s.reg[dst_reg] = result;
            break;
        case ALU_T_NEG: {
            sum = (uint64_t)0 - (uint64_t)src_val;
            result = (uint32_t)(sum & m);
            // NEG flags: Z, S as normal, CY = (src != 0), OV = (src_msb && result_msb)
            int mb = msb_pos(dsize);
            s.psw &= ~0xFu;
            if (result == 0) s.psw |= (1 << 0);
            if ((result >> mb) & 1) s.psw |= (1 << 1);
            if (src_val != 0) s.psw |= (1 << 3);
            if (((src_val >> mb) & 1) && ((result >> mb) & 1)) s.psw |= (1 << 2);
            if (dst_reg >= 0) s.reg[dst_reg] = result;
            break;
        }
        default:
            break;
    }

    s.pc += inst_len;
    return inst_len;
}

// =========================================================================
// Minimal V60 executor (placeholder until real MAME source is integrated)
// Phase 3: Handles NOP, HALT, BR, MOV, ADD, SUB, CMP, AND, OR, XOR,
//          ADDC, SUBC, NOT, NEG, GETPSW, INC, DEC
// =========================================================================
static bool execute_one(V60State& s) {
    uint8_t opcode = s.program->read_byte(s.pc);

    switch (opcode) {
        case 0xCD: // NOP
            s.pc += 1;
            return true;

        case 0x00: // HALT
            s.halted = true;
            s.pc += 1;
            return true;

        case 0x6A: { // BR (unconditional, 8-bit displacement)
            int8_t disp = (int8_t)s.program->read_byte(s.pc + 1);
            s.pc = s.pc + (int32_t)disp;
            return true;
        }

        case 0x7A: { // BR (unconditional, 16-bit displacement)
            int16_t disp = (int16_t)s.program->read_word(s.pc + 1);
            s.pc = s.pc + (int32_t)disp;
            return true;
        }

        case 0x09:   // MOV.B
        case 0x1B:   // MOV.H
        case 0x2D: { // MOV.W — Format I two-operand
            uint8_t byte1 = s.program->read_byte(s.pc + 1);
            bool m_bit = (byte1 >> 6) & 1;
            bool d_bit = (byte1 >> 5) & 1;
            int reg_field = byte1 & 0x1F;
            int dsize = get_data_size(opcode);

            // Decode the mod field (second operand) at pc+2
            ModResult mod = decode_mod(s, s.pc + 2, m_bit, dsize);
            int inst_len = 2 + mod.len;

            uint32_t src_val;
            int dst_reg;

            if (d_bit == 0) {
                // reg=source, mod=destination
                src_val = s.reg[reg_field];
                dst_reg = mod.reg_idx;
            } else {
                // reg=destination, mod=source
                src_val = mod.value;
                dst_reg = reg_field;
            }

            // Apply size mask
            switch (dsize) {
                case 0: src_val &= 0xFF; break;
                case 1: src_val &= 0xFFFF; break;
                case 2: break; // full word
            }

            if (dst_reg >= 0)
                s.reg[dst_reg] = src_val;

            s.pc += inst_len;
            return true;
        }

        // Format I ALU instructions
        case 0x80: case 0x82: case 0x84: // ADD.B/H/W
            exec_fmt1_alu(s, opcode, ALU_T_ADD, alu_data_size(opcode));
            return true;
        case 0x88: case 0x8A: case 0x8C: // OR.B/H/W
            exec_fmt1_alu(s, opcode, ALU_T_OR, alu_data_size(opcode));
            return true;
        case 0x90: case 0x92: case 0x94: // ADDC.B/H/W
            exec_fmt1_alu(s, opcode, ALU_T_ADDC, alu_data_size(opcode));
            return true;
        case 0x98: case 0x9A: case 0x9C: // SUBC.B/H/W
            exec_fmt1_alu(s, opcode, ALU_T_SUBC, alu_data_size(opcode));
            return true;
        case 0xA0: case 0xA2: case 0xA4: // AND.B/H/W
            exec_fmt1_alu(s, opcode, ALU_T_AND, alu_data_size(opcode));
            return true;
        case 0xA8: case 0xAA: case 0xAC: // SUB.B/H/W
            exec_fmt1_alu(s, opcode, ALU_T_SUB, alu_data_size(opcode));
            return true;
        case 0xB0: case 0xB2: case 0xB4: // XOR.B/H/W
            exec_fmt1_alu(s, opcode, ALU_T_XOR, alu_data_size(opcode));
            return true;
        case 0xB8: case 0xBA: case 0xBC: // CMP.B/H/W
            exec_fmt1_alu(s, opcode, ALU_T_CMP, alu_data_size(opcode));
            return true;
        case 0x38: case 0x3A: case 0x3C: // NOT.B/H/W
            exec_fmt1_alu(s, opcode, ALU_T_NOT, alu_data_size(opcode));
            return true;
        case 0x39: case 0x3B: case 0x3D: // NEG.B/H/W
            exec_fmt1_alu(s, opcode, ALU_T_NEG, alu_data_size(opcode));
            return true;

        // Format III: INC/DEC
        case 0xD8: case 0xD9:   // INC.B
        case 0xDA: case 0xDB:   // INC.H
        case 0xDC: case 0xDD: { // INC.W
            bool m_bit = opcode & 1;
            int dsize = ((opcode & 0x06) >> 1);  // 0=B, 1=H, 2=W
            ModResult mod = decode_mod(s, s.pc + 1, m_bit, dsize);
            int inst_len = 1 + mod.len;
            uint32_t m = size_mask(dsize);
            int mb = msb_pos(dsize);

            uint32_t val = mod.is_reg ? s.reg[mod.reg_idx] : 0;
            val &= m;
            uint64_t sum = (uint64_t)val + 1;
            uint32_t result = (uint32_t)(sum & m);

            s.psw &= ~0xFu;
            if (result == 0) s.psw |= (1 << 0);
            if ((result >> mb) & 1) s.psw |= (1 << 1);
            if ((sum >> (mb + 1)) & 1) s.psw |= (1 << 3);
            // OV: was max positive, now negative
            if (!((val >> mb) & 1) && ((result >> mb) & 1) && val == (m >> 1))
                s.psw |= (1 << 2);

            if (mod.is_reg && mod.reg_idx >= 0)
                s.reg[mod.reg_idx] = result;

            s.pc += inst_len;
            return true;
        }

        case 0xD0: case 0xD1:   // DEC.B
        case 0xD2: case 0xD3:   // DEC.H
        case 0xD4: case 0xD5: { // DEC.W
            bool m_bit = opcode & 1;
            int dsize = ((opcode & 0x06) >> 1);
            ModResult mod = decode_mod(s, s.pc + 1, m_bit, dsize);
            int inst_len = 1 + mod.len;
            uint32_t m = size_mask(dsize);
            int mb = msb_pos(dsize);

            uint32_t val = mod.is_reg ? s.reg[mod.reg_idx] : 0;
            val &= m;
            uint64_t sum = (uint64_t)val - 1;
            uint32_t result = (uint32_t)(sum & m);

            s.psw &= ~0xFu;
            if (result == 0) s.psw |= (1 << 0);
            if ((result >> mb) & 1) s.psw |= (1 << 1);
            if ((sum >> (mb + 1)) & 1) s.psw |= (1 << 3);
            // OV: was min negative, now positive
            if (((val >> mb) & 1) && !((result >> mb) & 1))
                s.psw |= (1 << 2);

            if (mod.is_reg && mod.reg_idx >= 0)
                s.reg[mod.reg_idx] = result;

            s.pc += inst_len;
            return true;
        }

        case 0xF6:   // GETPSW (m=0)
        case 0xF7: { // GETPSW (m=1)
            bool m_bit = opcode & 1;
            ModResult mod = decode_mod(s, s.pc + 1, m_bit, 2 /*word*/);
            int inst_len = 1 + mod.len;

            if (mod.is_reg && mod.reg_idx >= 0)
                s.reg[mod.reg_idx] = s.psw;

            s.pc += inst_len;
            return true;
        }

        default:
            fprintf(stderr, "MAME harness: unimplemented opcode 0x%02X at PC=0x%08X\n",
                    opcode, s.pc);
            s.pc += 1;  // Skip unknown byte
            return true;
    }
}

// =========================================================================
// Main
// =========================================================================
int main(int argc, char** argv) {
    const char* binary_file = nullptr;
    uint32_t base_addr = 0x1000;
    uint32_t max_steps = 10000;
    const char* trace_file = nullptr;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-bin") == 0 && i+1 < argc)
            binary_file = argv[++i];
        else if (strcmp(argv[i], "-base") == 0 && i+1 < argc)
            base_addr = strtoul(argv[++i], nullptr, 0);
        else if (strcmp(argv[i], "-steps") == 0 && i+1 < argc)
            max_steps = strtoul(argv[++i], nullptr, 0);
        else if (strcmp(argv[i], "-trace") == 0 && i+1 < argc)
            trace_file = argv[++i];
    }

    // Initialize CPU state
    V60State state = {};
    address_space prog_mem;
    io_space io_mem;
    state.program = &prog_mem;
    state.io = &io_mem;
    state.pir = 0x00006000;  // V60

    // Load binary
    if (binary_file) {
        int loaded = prog_mem.load_binary(binary_file, base_addr);
        if (loaded < 0) {
            fprintf(stderr, "ERROR: Cannot open binary file: %s\n", binary_file);
            return 1;
        }
        printf("Loaded %d bytes from %s at 0x%06X\n", loaded, binary_file, base_addr);
    } else {
        // Default NOP loop test
        prog_mem.write_byte(0x1000, 0xCD);  // NOP
        prog_mem.write_byte(0x1001, 0xCD);  // NOP
        prog_mem.write_byte(0x1002, 0xCD);  // NOP
        prog_mem.write_byte(0x1003, 0x00);  // HALT
    }

    // Set entry point
    state.pc = base_addr;
    state.psw = (1 << 18) | (1 << 19);  // ID=1, IS=1

    // Trace output
    FILE* trace_fp = stdout;
    if (trace_file) {
        trace_fp = fopen(trace_file, "w");
        if (!trace_fp) {
            fprintf(stderr, "ERROR: Cannot open trace file: %s\n", trace_file);
            return 1;
        }
    }
    emit_trace_header(trace_fp);

    // Execute
    printf("Starting MAME harness execution at PC=0x%08X\n", state.pc);
    uint32_t step = 0;
    while (step < max_steps && !state.halted) {
        if (!execute_one(state))
            break;
        // Don't trace HALT — it doesn't "retire" like other instructions
        if (!state.halted) {
            emit_trace_line(trace_fp, step, state);
            step++;
        }
    }

    if (state.halted)
        printf("CPU halted at PC=0x%08X\n", state.pc);
    printf("Execution finished: %u steps\n", step);

    if (trace_file && trace_fp != stdout)
        fclose(trace_fp);

    return 0;
}
