# Top-level Makefile for NEC V60 CPU project

.PHONY: all sim mame_harness test lint clean

all: sim

# Build Verilator simulation
sim:
	$(MAKE) -C sim build

# Build MAME reference harness
mame_harness:
	$(MAKE) -C mame build

# Run tests: build both, run comparison
test: sim
	$(MAKE) -C sim run
	@echo "=== RTL simulation complete ==="
	@echo "Run trace_compare.py to diff against MAME traces"

# Lint-only check on all RTL
lint:
	$(MAKE) -C sim lint

# Clean everything
clean:
	$(MAKE) -C sim clean
	$(MAKE) -C mame clean 2>/dev/null || true
	rm -f tests/*.trace
