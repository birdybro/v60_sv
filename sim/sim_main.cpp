// sim_main.cpp — Verilator C++ driver with trace capture
// Loads a binary test program, runs the V60 CPU simulation,
// and outputs a trace CSV for comparison with MAME.

#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vtb_v60_top.h"
#include "Vtb_v60_top___024root.h"
#include "svdpi.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

// DPI-C function declarations (exported from SystemVerilog)
extern "C" {
    extern int get_pc();
    extern int get_psw();
    extern int get_gpr(int idx);
    extern int get_cpu_state();
    extern int is_halted();
    extern void mem_write_byte(int addr, int data);
    extern int mem_read_byte(int addr);
    extern void v60_string_init();
    extern void v60_string_sync_mem();
    extern int  v60_string_get_num_mem_writes();
    extern void v60_string_get_mem_write(int idx, int* addr, int* data);
    extern void v60_string_clear_mem_writes();
}

// V60 FSM state enum (matches v60_pkg::fsm_state_t)
enum FsmState {
    ST_RESET = 0, ST_FETCH = 1, ST_DECODE = 2,
    ST_ADDR_MODE_1 = 3, ST_ADDR_MODE_2 = 4,
    ST_EXECUTE = 5, ST_WRITEBACK = 6,
    ST_HALT = 9,
    ST_MEM_READ_WAIT = 17
};

// Scope pointers for DPI calls
static svScope scope_top = nullptr;
static svScope scope_mem = nullptr;

static void set_top_scope() { svSetScope(scope_top); }
static void set_mem_scope() { svSetScope(scope_mem); }

static void load_binary(const char* filename, uint32_t base_addr) {
    FILE* f = fopen(filename, "rb");
    if (!f) {
        fprintf(stderr, "ERROR: Cannot open binary file: %s\n", filename);
        exit(1);
    }
    set_mem_scope();
    int addr = base_addr;
    int c;
    while ((c = fgetc(f)) != EOF) {
        mem_write_byte(addr++, c);
    }
    fclose(f);
    printf("Loaded %d bytes from %s at 0x%06X\n", addr - (int)base_addr, filename, base_addr);
}

static void setup_reset_vector(uint32_t entry_point) {
    // Write entry point at reset vector address (0xFFFFF0, masked to 1MB)
    uint32_t vec_addr = 0x0FFFF0;
    set_mem_scope();
    mem_write_byte(vec_addr + 0, (entry_point >>  0) & 0xFF);
    mem_write_byte(vec_addr + 1, (entry_point >>  8) & 0xFF);
    mem_write_byte(vec_addr + 2, (entry_point >> 16) & 0xFF);
    mem_write_byte(vec_addr + 3, (entry_point >> 24) & 0xFF);
    printf("Reset vector at 0x%06X -> 0x%08X\n", vec_addr, entry_point);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // Parse arguments
    const char* binary_file = nullptr;
    uint32_t base_addr = 0x1000;
    uint32_t max_cycles = 10000;
    const char* trace_file = nullptr;
    const char* vcd_file = nullptr;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-bin") == 0 && i+1 < argc)
            binary_file = argv[++i];
        else if (strcmp(argv[i], "-base") == 0 && i+1 < argc)
            base_addr = strtoul(argv[++i], nullptr, 0);
        else if (strcmp(argv[i], "-cycles") == 0 && i+1 < argc)
            max_cycles = strtoul(argv[++i], nullptr, 0);
        else if (strcmp(argv[i], "-trace") == 0 && i+1 < argc)
            trace_file = argv[++i];
        else if (strcmp(argv[i], "-vcd") == 0 && i+1 < argc)
            vcd_file = argv[++i];
    }

    // Create model
    Vtb_v60_top* top = new Vtb_v60_top;

    // VCD trace setup
    VerilatedVcdC* tfp = nullptr;
    if (vcd_file) {
        Verilated::traceEverOn(true);
        tfp = new VerilatedVcdC;
        top->trace(tfp, 99);
        tfp->open(vcd_file);
        printf("VCD trace: %s\n", vcd_file);
    }

    // Do one eval to register scopes
    top->clk = 0;
    top->rst_n = 0;
    top->eval();

    // Get DPI scopes
    scope_top = svGetScopeFromName("TOP.tb_v60_top");
    scope_mem = svGetScopeFromName("TOP.tb_v60_top.u_mem");
    if (!scope_top || !scope_mem) {
        fprintf(stderr, "ERROR: Could not find DPI scopes\n");
        // Try alternate naming
        scope_top = svGetScopeFromName("TOP");
        scope_mem = svGetScopeFromName("TOP.u_mem");
        if (!scope_top) {
            fprintf(stderr, "ERROR: Could not find any DPI scope\n");
            exit(1);
        }
    }

    // Initialize string/bitfield/decimal DPI-C module
    v60_string_init();

    // Trace CSV output
    FILE* trace_fp = nullptr;
    if (trace_file) {
        trace_fp = fopen(trace_file, "w");
        if (!trace_fp) {
            fprintf(stderr, "ERROR: Cannot open trace file: %s\n", trace_file);
            exit(1);
        }
        fprintf(trace_fp, "step,PC,PSW");
        for (int i = 0; i < 32; i++)
            fprintf(trace_fp, ",R%d", i);
        fprintf(trace_fp, "\n");
    }

    // Load program
    if (binary_file) {
        load_binary(binary_file, base_addr);
    } else {
        // Default: NOP loop test
        set_mem_scope();
        mem_write_byte(0x1000, 0xCD);  // NOP
        mem_write_byte(0x1001, 0xCD);  // NOP
        mem_write_byte(0x1002, 0xCD);  // NOP
        mem_write_byte(0x1003, 0x00);  // HALT
    }
    setup_reset_vector(base_addr);

    // Sync shadow memory for string operations
    v60_string_sync_mem();

    // Reset sequence
    top->rst_n = 0;
    for (int i = 0; i < 4; i++) {
        top->clk = 0; top->eval();
        if (tfp) tfp->dump(i*2);
        top->clk = 1; top->eval();
        if (tfp) tfp->dump(i*2 + 1);
    }
    top->rst_n = 1;

    // Main simulation loop
    uint64_t cycle = 0;
    uint32_t step = 0;
    int prev_state = -1;

    printf("Starting simulation...\n");

    while (cycle < max_cycles && !Verilated::gotFinish()) {
        // Clock low
        top->clk = 0;
        top->eval();
        if (tfp) tfp->dump(cycle * 2 + 8);

        // Debug: removed

        // Clock high
        top->clk = 1;
        top->eval();
        if (tfp) tfp->dump(cycle * 2 + 9);

        // Apply deferred memory writes from string DPI directly to model array
        {
            int nwr = v60_string_get_num_mem_writes();
            if (nwr > 0) {
                for (int i = 0; i < nwr; i++) {
                    int addr, data;
                    v60_string_get_mem_write(i, &addr, &data);
                    if (addr >= 0 && addr < (1 << 20))
                        top->rootp->tb_v60_top__DOT__u_mem__DOT__mem[addr] = (uint8_t)data;
                }
                v60_string_clear_mem_writes();
            }
        }

        set_top_scope();
        int cur_state = get_cpu_state();

        // Emit trace line on instruction retirement:
        // WRITEBACK → FETCH (normal) or MEM_READ_WAIT → FETCH (exception/interrupt)
        if ((prev_state == ST_WRITEBACK || prev_state == ST_MEM_READ_WAIT) && cur_state == ST_FETCH) {
            if (trace_fp) {
                set_top_scope();
                fprintf(trace_fp, "%u,0x%08X,0x%08X",
                        step, (uint32_t)get_pc(), (uint32_t)get_psw());
                for (int i = 0; i < 32; i++)
                    fprintf(trace_fp, ",0x%08X", (uint32_t)get_gpr(i));
                fprintf(trace_fp, "\n");
            }
            step++;
        }

        // Check for halt
        set_top_scope();
        if (is_halted()) {
            printf("CPU halted at cycle %lu, PC=0x%08X\n",
                   (unsigned long)cycle, (uint32_t)get_pc());
            break;
        }

        prev_state = cur_state;
        cycle++;
    }

    printf("Simulation finished: %lu cycles, %u instructions retired\n",
           (unsigned long)cycle, step);

    // Cleanup
    if (trace_fp) fclose(trace_fp);
    if (tfp) { tfp->close(); delete tfp; }
    delete top;

    return 0;
}
