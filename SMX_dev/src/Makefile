# Copyright (c) 2026 Luca Donato, Tommaso Spagnolo, Cristina Silvano
# SPDX-License-Identifier: MIT

# Makefile: build and run Verilator simulation for RTL in `rtl`,
# testbench SV files in `dv/sv` and C++ helpers in `dv/verilator`.

VERILATOR ?= verilator
CXX ?= g++
RM := rm -rf

# Default top module points to the end-to-end smx_fu_lut testbench.
# Override on the command line with `make TOP=tb_my_test`.
TOP ?= tb_smx_fu_lut

RTL_DIR := rtl
TB_SV_DIR := dv/sv
VER_DIR := dv/verilator
BUILD_ROOT := obj_dir
BUILD_DIR  := $(BUILD_ROOT)/$(TOP)
BUILD_DIR_ABS := $(abspath $(BUILD_DIR))

# Collect sources (recursive)
# Collect sources (recursive)
PKG_SRCS := ../../rtl/include/cv32e40p_pkg.sv
RTL_SRCS := $(PKG_SRCS) $(shell find $(RTL_DIR) -name '*.sv' -print)
TB_SRCS := $(shell find $(TB_SV_DIR) -name '*.sv' -print)
VER_CPP  := $(shell find $(VER_DIR) -name '*.cpp' -print)
HEX_SRCS := $(shell find . -maxdepth 1 -name '*.hex' -print)

RTL_SRCS_ABS := $(foreach f,$(RTL_SRCS),$(abspath $(f)))
TB_SRCS_ABS  := $(foreach f,$(TB_SRCS),$(abspath $(f)))
VER_CPP_ABS  := $(foreach f,$(VER_CPP),$(abspath $(f)))
HEX_SRCS_ABS := $(foreach f,$(HEX_SRCS),$(abspath $(f)))
VER_CPP_BASENAMES := $(notdir $(VER_CPP_ABS))

# Verilator flags
# Place the top module name immediately after `--top-module`.
VERILATOR_FLAGS = -Wall --cc --trace --top-module $(TOP) --timing \
                  +incdir+../../rtl/include \
                  -Wno-UNUSEDPARAM \
                  -Wno-TIMESCALEMOD \
                  -CFLAGS "-DVERILATOR_TOP_H=\\\"V$(TOP).h\\\"" \
                  -CFLAGS "-DVERILATOR_TOP_CLASS=V$(TOP)"

CXXFLAGS ?= -O2 -std=c++11

all: build sim

build: $(BUILD_DIR)/V$(TOP).mk

$(BUILD_DIR)/V$(TOP).mk: $(RTL_SRCS) $(TB_SRCS) $(VER_CPP) $(HEX_SRCS)
	@echo "Running Verilator for top module: $(TOP)"
	@mkdir -p $(BUILD_DIR)
	@if [ -n "$(VER_CPP_ABS)" ]; then \
		for src in $(VER_CPP_ABS); do \
			cp $$src $(BUILD_DIR_ABS)/$$(basename $$src); \
		done; \
	fi
	@if [ -n "$(HEX_SRCS_ABS)" ]; then \
		for src in $(HEX_SRCS_ABS); do \
			cp $$src $(BUILD_DIR_ABS)/$$(basename $$src); \
		done; \
	fi
	$(VERILATOR) $(VERILATOR_FLAGS) -Mdir $(BUILD_DIR) --exe $(addprefix $(BUILD_DIR_ABS)/,$(VER_CPP_BASENAMES)) $(RTL_SRCS_ABS) $(TB_SRCS_ABS)
	$(MAKE) -C $(BUILD_DIR) -f V$(TOP).mk

sim: build
	@echo "Running simulation binary (from $(BUILD_DIR))"
	./$(BUILD_DIR)/V$(TOP)

clean:
	$(RM) $(BUILD_ROOT) *.o a.out

.PHONY: all build sim clean list

# Pattern target: run a single testbench by name, e.g. `make tb_smx_fu_lut_contx`.
# This will set `TOP` to the full target name and run build + sim for it.
tb_%:
	@echo "Building & running testbench: $@"
	$(MAKE) TOP=$@ build
	$(MAKE) TOP=$@ sim

# Usage notes:
# - Run `make` to build the Verilator simulation (requires `verilator` in PATH).
# - Run `make sim` or `make` to execute the generated executable.
# - You can override `VERILATOR` or `CXX` on the command line, e.g.
#     make VERILATOR=/usr/bin/verilator-4.208

# Helper: list detected testbenches and RTL sources
list:
	@echo "Detected SystemVerilog testbenches (dv/sv):"
	@for f in $(TB_SRCS); do echo "  $$f"; done
	@echo "\nDetected RTL sources (rtl):"
	@for f in $(RTL_SRCS); do echo "  $$f"; done
	@echo "\nBuild a specific testbench with: make TOP=<tb_basename>"

# How to add more simulations / benchtests
# - Create a SystemVerilog testbench file under `dv/sv/`, for example `tb_my_test.sv`.
# - If your test requires C++ helpers for the Verilator harness, add them under `dv/verilator/`.
# - If your DUT requires pre-initialized ROMs, place `.hex` files under `rtl/` (or give an
#   absolute path in the module instantiation) and reference them via the `INIT_HEX` parameter.
# - To run the new testbench, either ensure it is the only/first `dv/sv/*.sv` file or invoke:
#     make TOP=tb_my_test
# - To run multiple different simulations from CI, invoke `make` repeatedly with different
#   `TOP` values, or add custom Make targets that set `TOP` and call `make build`/`make sim`.
#
