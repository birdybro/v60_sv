# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a synthesizable NEC V60 CPU model in SystemVerilog. The V60 is a 32-bit CISC processor with variable-length instructions (1-22 bytes), 21 addressing modes, and 119 instructions. The RTL is parameterized to support both V60 (16-bit data bus, 24-bit address bus) and V70 (32-bit data bus, 32-bit address bus). MAME's V60 emulation serves as the golden reference for validation.

Reference documentation: `docs/NEC_V60_Programmers_Reference_Manual.pdf`

## Repository Structure

- **rtl/** — SystemVerilog RTL source files for the V60 CPU model
  - `v60_pkg.sv` — Shared package (types, enums, constants, opcodes)
  - `v60_cpu.sv` — Top-level parameterized module
  - `v60_regfile.sv` — 32 GPRs + privileged registers, SP caching
  - `v60_bus_if.sv` — Parameterized bus interface (16/32-bit external)
  - `v60_fetch_unit.sv` — 24-byte instruction buffer, sequential prefetch
  - `v60_decode.sv` — Opcode decoder, instruction format classification
  - `v60_addr_mode.sv` — Addressing mode resolver (21 modes)
  - `v60_alu.sv` — Combinational ALU
  - `v60_flags.sv` — Branch condition evaluator
  - `v60_control.sv` — Main FSM controller
  - `v60_interrupt.sv` — Interrupt/exception handler
- **tb/** — Testbench files
  - `tb_v60_top.sv` — Top-level Verilator testbench with DPI exports
  - `tb_memory.sv` — Simple byte-addressable RAM model
- **sim/** — Simulation drivers and tools
  - `sim_main.cpp` — Verilator C++ driver with CSV trace and VCD output
  - `trace_compare.py` — Python script to diff MAME vs RTL traces
  - `Makefile` — Verilator build
- **mame/** — MAME reference harness (compiles real MAME V60 source unmodified)
  - `src/emu.h` — MAME framework stubs (address_space, cpu_device, device types, etc.)
  - `src/v60_harness.cpp` — Thin wrapper around real v60_device
  - `src/v60.cpp`, `src/v60.h` — Real MAME V60 CPU source (unmodified)
  - `src/am*.hxx`, `src/op*.hxx`, `src/optable.hxx` — MAME addressing modes & opcodes (unmodified)
  - `src/v60d.cpp`, `src/v60d.h` — MAME disassembler (not compiled, stubs in harness)
  - `Makefile` — Harness build
- **tests/** — Binary test programs and assembler
  - `asm_v60.py` — V60 assembler/test generator
  - `phase*_test.bin` — Phase-specific test binaries
- **docs/** — Reference documentation (NEC V60 Programmer's Reference Manual)

## Build Commands

```
make sim           # Build Verilator simulation (output: sim/obj_dir/Vtb_v60_top)
make mame_harness  # Build MAME reference harness (output: mame/build_out/v60_harness)
make lint          # Verilator lint-only check on all RTL
make test          # Build + run RTL simulation
make clean         # Clean all build artifacts
```

### Running the simulation

```bash
# Default NOP+HALT test
sim/obj_dir/Vtb_v60_top -trace out.trace -cycles 5000

# With binary test program
sim/obj_dir/Vtb_v60_top -bin tests/test.bin -base 0x1000 -trace out.trace -vcd out.vcd

# MAME harness
mame/build_out/v60_harness -bin tests/test.bin -base 0x1000 -trace mame.trace

# Compare traces
python3 sim/trace_compare.py mame.trace rtl.trace
```

## Language & Conventions

- Primary language: SystemVerilog (.sv files)
- Follow standard SystemVerilog coding conventions (lowercase with underscores for signals/modules)
- All RTL imports `v60_pkg` for shared types and constants
- Verilator lint pragmas (`lint_off UNUSEDSIGNAL`, `lint_off UNUSEDPARAM`) are used at module level for signals/params needed in future phases

## Architecture Notes

### Top-Level Parameters
```systemverilog
module v60_cpu #(
    parameter int DATA_WIDTH = 16,            // 16 for V60, 32 for V70
    parameter int ADDR_WIDTH = 24,            // 24 for V60, 32 for V70
    parameter int PIR_VALUE  = 32'h00006000   // 0x6000 for V60, 0x7000 for V70
)
```

### Main FSM Flow
```
RESET → RESET_VEC (read reset vector) → FETCH → DECODE → EXECUTE → WRITEBACK → FETCH
DECODE → HALT (if HALT opcode)
EXECUTE → MEM_READ → MEM_READ_WAIT → EXECUTE2 → [MEM_WRITE → MEM_WRITE_WAIT →] WRITEBACK
EXECUTE → MEM_WRITE → MEM_WRITE_WAIT → WRITEBACK (MOV to memory, write-only)
Indirect modes: EXECUTE2(indirect_active) → MEM_READ/MEM_WRITE (loop back for data access)
```

### Key V60 ISA Facts
- NOP = 0xCD, HALT = 0x00 (Format V, 1 byte)
- Bcc short = 0x60-0x6F (8-bit signed displacement), long = 0x70-0x7F (16-bit)
- BR = cond 0xA (always); cond 0xB (opcode 0x6B/0x7B) is unhandled in MAME
- PSW: bit0=Z, bit1=S, bit2=OV, bit3=CY, bit18=ID, bits24-25=EL, bit28=IS
- Reset vector at physical address 0xFFFFFFF0
- R31=SP (cached: L0SP-L3SP + ISP selected by EL/IS), R30=FP, R29=AP
- Little-endian byte ordering

### Bus Arbitration
Data bus requests from the control FSM have priority over instruction fetch. A registered `response_to_data` flag latches ownership at request submission time and routes bus responses correctly even when a data request arrives while a fetch is in-flight.

### DPI Interface
DPI-exported functions (`get_pc`, `get_psw`, `get_gpr`, `mem_write_byte`, etc.) require `svSetScope()` before calling from C++. Scopes are obtained via `svGetScopeFromName("TOP.tb_v60_top")` and `svGetScopeFromName("TOP.tb_v60_top.u_mem")`.

## Implementation Phases

- **Phase 1** ✅ — Infrastructure: NOP, HALT, BR execution; build system; MAME harness
- **Phase 2** ✅ — Register ops & immediate MOV (MOVB/H/W, GETPSW)
- **Phase 3** ✅ — Core ALU (ADD, SUB, CMP, AND, OR, XOR, NOT, NEG, INC, DEC, ADDC, SUBC)
- **Phase 4** ✅ — Conditional branches (all 14 Bcc conditions)
- **Phase 5A** ✅ — Simple memory addressing modes ([Rn], [Rn]+, -[Rn], Disp8/16/32[Rn], PCDisp, DirectAddr)
- **Phase 5B** ✅ — Indirect + double displacement addressing modes (DispInd, DblDisp, PCDispInd, DirectAddrDeferred, PCDblDisp)
- **Phase 6** ✅ — Control flow (JMP, JSR, BSR, RET, PREPARE/DISPOSE, PUSH/POP, PUSHM/POPM)
- **Phase 7** ✅ — Multiply, divide, shifts, rotates, bit ops (MUL/MULU, DIV/DIVU, REM/REMU, SHL, SHA, ROT, ROTC, SET1/CLR1/NOT1/TEST1)
- **Phase 8** — System instructions & I/O
- **Phase 9** — Interrupts & exceptions
- **Phase 10** — Decrement-and-branch
- **Phase 11** — Floating point
- **Phase 12** — String operations
- **Phase 13** — Bitfield & decimal
- **Phase 14** — Full system validation
