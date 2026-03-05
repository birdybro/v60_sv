# sim/Makefile — Verilator build for V60 CPU simulation

VERILATOR    ?= verilator
VERILATOR_FLAGS = --cc --exe --build --trace \
                  -Wall -Wno-fatal \
                  --top-module tb_v60_top \
                  -CFLAGS "-std=c++17 -O2"

# Source files
RTL_DIR      = ../rtl
TB_DIR       = ../tb
RTL_SRCS     = $(RTL_DIR)/v60_pkg.sv \
               $(RTL_DIR)/v60_regfile.sv \
               $(RTL_DIR)/v60_bus_if.sv \
               $(RTL_DIR)/v60_fetch_unit.sv \
               $(RTL_DIR)/v60_decode.sv \
               $(RTL_DIR)/v60_alu.sv \
               $(RTL_DIR)/v60_flags.sv \
               $(RTL_DIR)/v60_addr_mode.sv \
               $(RTL_DIR)/v60_interrupt.sv \
               $(RTL_DIR)/v60_control.sv \
               $(RTL_DIR)/v60_fpu.sv \
               $(RTL_DIR)/v60_cpu.sv
TB_SRCS      = $(TB_DIR)/tb_memory.sv \
               $(TB_DIR)/tb_v60_top.sv
CPP_SRCS     = sim_main.cpp v60_fp.cpp

OBJ_DIR      = obj_dir
SIM_BIN      = $(OBJ_DIR)/Vtb_v60_top

.PHONY: all build lint clean run

all: build

build: $(SIM_BIN)

$(SIM_BIN): $(RTL_SRCS) $(TB_SRCS) $(CPP_SRCS)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_SRCS) $(TB_SRCS) $(CPP_SRCS)

lint:
	$(VERILATOR) --lint-only -Wall \
		--top-module tb_v60_top \
		$(RTL_SRCS) $(TB_SRCS)

run: $(SIM_BIN)
	$(SIM_BIN) -trace sim.rtl.trace -vcd sim.vcd

clean:
	rm -rf $(OBJ_DIR) *.vcd *.trace
