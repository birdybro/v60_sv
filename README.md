# v60_sv

Synthesizable NEC V60 CPU model in SystemVerilog.

The V60 is a 32-bit CISC processor with variable-length instructions (1-22 bytes), 21 addressing modes, and 119 instructions. This RTL is parameterized to support both V60 (16-bit data bus, 24-bit address bus) and V70 (32-bit data bus, 32-bit address bus).

MAME's V60 emulation serves as the golden reference — every instruction is validated cycle-by-cycle against the real MAME V60 source code compiled into a test harness.

## Building

Requires [Verilator](https://www.veripool.org/verilator/) and a C++17 compiler.

```
make sim           # Build Verilator simulation
make mame_harness  # Build MAME reference harness
make lint          # Verilator lint check
make clean         # Clean all build artifacts
```

## Running

```bash
# Run a test binary through RTL simulation
sim/obj_dir/Vtb_v60_top -bin tests/phase8_test.bin -base 0x1000 -trace rtl.trace -cycles 15000

# Run the same binary through MAME reference
mame/build_out/v60_harness -bin tests/phase8_test.bin -base 0x1000 -trace mame.trace

# Compare traces (exits 0 if identical)
python3 sim/trace_compare.py mame.trace rtl.trace
```

Optional flags: `-vcd out.vcd` for waveform output.

## Repository Structure

| Directory | Contents |
|-----------|----------|
| `rtl/` | SystemVerilog RTL source (v60_cpu.sv top-level, v60_pkg.sv shared types) |
| `tb/` | Verilator testbench (tb_v60_top.sv, tb_memory.sv) |
| `sim/` | C++ simulation driver, trace comparison tool |
| `mame/` | MAME reference harness (compiles real MAME V60 source unmodified) |
| `tests/` | V60 assembler (asm_v60.py) and generated test binaries |
| `docs/` | NEC V60 Programmer's Reference Manual |

## Architecture

```
                    +------------------+
                    |    v60_cpu.sv    |
                    |  (top-level)     |
                    +------------------+
                    |                  |
         +----------+    +------------+----------+
         | v60_fetch |    | v60_control (FSM)     |
         | _unit     |    |   v60_decode          |
         | (prefetch |    |   v60_alu             |
         |  buffer)  |    |   v60_flags           |
         +-----+-----+    +---+--------+----------+
               |               |        |
         +-----+---------------+---+    |
         |     v60_bus_if          |    v60_regfile
         | (16/32-bit external)    |    (32 GPR + preg)
         +-------------------------+
```

**Top-level parameters:**
- `DATA_WIDTH` — 16 for V60, 32 for V70
- `ADDR_WIDTH` — 24 for V60, 32 for V70
- `PIR_VALUE` — Processor ID (0x6000 for V60, 0x7000 for V70)

**FSM flow:**
```
RESET → RESET_VEC → FETCH → DECODE → EXECUTE → WRITEBACK → FETCH
                                    ↓
                              MEM_READ → EXECUTE2 → [MEM_WRITE →] WRITEBACK
```

## Implementation Progress

| Phase | Status | Instructions | Verified |
|-------|--------|-------------|----------|
| 1 - Infrastructure | Done | NOP, HALT, BR; build system; MAME harness | 3/3 steps |
| 2 - Register ops | Done | MOV.B/H/W, GETPSW | 7/7 steps |
| 3 - Core ALU | Done | ADD, SUB, CMP, AND, OR, XOR, NOT, NEG, INC, DEC, ADDC, SUBC | 27/27 steps |
| 4 - Branches | Done | All 14 Bcc conditions (short + long) | 50/50 steps |
| 5A - Memory modes | Done | [Rn], [Rn]+, -[Rn], Disp8/16/32, PCDisp, DirectAddr | 23/23 steps |
| 5B - Indirect modes | Done | DispInd, DblDisp, PCDispInd, DirectAddrDeferred, PCDblDisp | 35/35 steps |
| 6 - Control flow | Done | JMP, JSR, BSR, RET, PREPARE/DISPOSE, PUSH/POP, PUSHM/POPM | 47/47 steps |
| 7 - Multiply/shift/bit | Done | MUL/MULU, DIV/DIVU, REM/REMU, SHL, SHA, ROT, ROTC, SET1/CLR1/NOT1/TEST1 | 73/73 steps |
| 8 - System/utility | Done | Cross-size MOV, MOVEA, RVBIT/RVBYT, SETF, UPDPSW, LDPR/STPR, TASI | 54/54 steps |
| 9 - Interrupts | Planned | Interrupt/exception handling | |
| 10 - Dec-and-branch | Planned | DBGT, DBLE, etc. | |
| 11 - Floating point | Planned | FPU operations | |
| 12 - String ops | Planned | Block move/compare/search | |
| 13 - Bitfield/decimal | Planned | Bitfield extract/insert, BCD | |
| 14 - Full validation | Planned | System-level integration tests | |

**Total verified: 319 instruction steps matching MAME**

## Validation Approach

Each phase produces a test binary via `tests/asm_v60.py`. The binary runs through both the RTL simulation and a MAME reference harness that compiles the real MAME V60 source code (unmodified). A trace comparator checks that PC, PSW, and all 32 GPRs match at every instruction retirement.

## License

See individual source files for licensing information. MAME source files under `mame/src/` retain their original licensing.
