// v60_harness.cpp — Standalone harness wrapping real MAME v60_device
// Compiles against the unmodified MAME V60 source files with emu.h stubs.

#include "emu.h"
#include "v60.h"
#include "v60d.h"

// =========================================================================
// Disassembler stubs (v60d.cpp not compiled)
// =========================================================================
u32 v60_disassembler::opcode_alignment() const { return 1; }
offs_t v60_disassembler::disassemble(std::ostream&, offs_t,
                                     const data_buffer&, const data_buffer&) { return 0; }

// =========================================================================
// Trace output
// =========================================================================
static void emit_trace_header(FILE* fp) {
    fprintf(fp, "step,PC,PSW");
    for (int i = 0; i < 32; i++)
        fprintf(fp, ",R%d", i);
    fprintf(fp, "\n");
}

static void emit_trace_line(FILE* fp, uint32_t step, v60_device& cpu) {
    uint32_t pc  = cpu.state_value(V60_PC);
    uint32_t psw = cpu.state_value(V60_PSW);
    fprintf(fp, "%u,0x%08X,0x%08X", step, pc, psw);
    for (int i = 0; i < 32; i++)
        fprintf(fp, ",0x%08X", cpu.state_value(V60_R0 + i));
    fprintf(fp, "\n");
}

// =========================================================================
// Load binary file into address space
// =========================================================================
static int load_binary(address_space& prog, const char* filename, uint32_t base_addr) {
    FILE* f = fopen(filename, "rb");
    if (!f) return -1;
    int count = 0;
    int c;
    while ((c = fgetc(f)) != EOF) {
        prog.write_byte(base_addr + count, (u8)c);
        count++;
    }
    fclose(f);
    return count;
}

// =========================================================================
// Main
// =========================================================================
int main(int argc, char* argv[]) {
    const char* bin_file   = nullptr;
    const char* trace_file = nullptr;
    uint32_t    base_addr  = 0x1000;
    uint32_t    max_steps  = 10000;

    // Parse arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-bin") == 0 && i + 1 < argc)
            bin_file = argv[++i];
        else if (strcmp(argv[i], "-base") == 0 && i + 1 < argc)
            base_addr = (uint32_t)strtoul(argv[++i], nullptr, 0);
        else if (strcmp(argv[i], "-trace") == 0 && i + 1 < argc)
            trace_file = argv[++i];
        else if (strcmp(argv[i], "-steps") == 0 && i + 1 < argc)
            max_steps = (uint32_t)strtoul(argv[++i], nullptr, 0);
        else {
            fprintf(stderr, "Usage: %s [-bin file] [-base addr] [-trace file] [-steps N]\n", argv[0]);
            return 1;
        }
    }

    // Create V60 device
    machine_config mconfig;
    v60_device cpu(mconfig, "v60", nullptr, 0);

    // Initialize address spaces (must happen before device_start)
    cpu.resolve_spaces();
    address_space& prog = cpu.space(AS_PROGRAM);

    // Load binary or default test
    if (bin_file) {
        int nbytes = load_binary(prog, bin_file, base_addr);
        if (nbytes < 0) {
            fprintf(stderr, "ERROR: Cannot open binary file: %s\n", bin_file);
            return 1;
        }
        printf("Loaded %d bytes from %s at 0x%08X\n", nbytes, bin_file, base_addr);
    } else {
        // Default NOP loop test
        prog.write_byte(0x1000, 0xCD);  // NOP
        prog.write_byte(0x1001, 0xCD);  // NOP
        prog.write_byte(0x1002, 0xCD);  // NOP
        prog.write_byte(0x1003, 0x00);  // HALT
    }

    // Initialize CPU
    cpu.do_start();
    cpu.do_reset();

    // Override PC to entry point (device_reset sets PC = 0xFFFFFFF0)
    cpu.set_state_value(V60_PC, base_addr);

    // Open trace file
    FILE* trace_fp = stdout;
    if (trace_file) {
        trace_fp = fopen(trace_file, "w");
        if (!trace_fp) {
            fprintf(stderr, "ERROR: Cannot open trace file: %s\n", trace_file);
            return 1;
        }
    }
    emit_trace_header(trace_fp);

    // Single-step execution loop
    printf("Starting MAME harness execution at PC=0x%08X\n", base_addr);
    uint32_t step = 0;

    while (step < max_steps) {
        // Check if current instruction is HALT (opcode 0x00)
        uint32_t pc = cpu.state_value(V60_PC);
        u8 opcode = prog.read_byte(pc);
        if (opcode == 0x00) {
            printf("CPU halted at PC=0x%08X\n", pc);
            break;
        }

        // Execute one instruction (m_icount=8, decremented by 8 = 0, loop exits)
        *cpu.icountptr() = 8;
        cpu.do_run();

        // Emit trace after instruction completes
        emit_trace_line(trace_fp, step, cpu);
        step++;
    }

    printf("Execution finished: %u steps\n", step);

    if (trace_file && trace_fp != stdout)
        fclose(trace_fp);

    return 0;
}
