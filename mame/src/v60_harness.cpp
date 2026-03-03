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
// Minimal V60 executor (placeholder until real MAME source is integrated)
// Handles NOP, HALT, and BR only — matches Phase 1 RTL scope
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
