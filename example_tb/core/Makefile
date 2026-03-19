MAKE := make

RISCV ?= /opt/riscv
RISCV_EXE_PREFIX := $(RISCV)/bin/riscv32-unknown-elf-
RISCV_INCLUDE_DIR := $(RISCV)/riscv32-unknown-elf/include
RISCV_LIB_DIR := $(RISCV)/riscv32-unknown-elf/lib

VERILATOR ?= verilator

RTLSRC_HOME := ../..
export DESIGN_RTL_DIR := $(RTLSRC_HOME)/rtl
RTLSRC_TB_PKG := include/perturbation_pkg.sv
RTLSRC_TB := $(filter-out cv32e40p_fp_wrapper.sv,$(wildcard *.sv))
VERILATOR_MANIFEST := $(RTLSRC_HOME)/cv32e40p_fpu_manifest.flist
VERILATOR_FLAGS := -Wall --cc --exe --build --timing \
	-I$(RTLSRC_HOME)/rtl \
	-I$(RTLSRC_HOME)/SMX_dev/src/rtl \
	-CFLAGS "-O2 -std=c++20" \
	-f $(VERILATOR_MANIFEST) \
	-Wno-BLKANDNBLK \
	-Wno-fatal

COMMON_BAREMETAL_SRCS := mem_stall/mem_stall.c custom/syscalls.c custom/vectors.S
COMMON_BAREMETAL_INCLUDES := -I $(RISCV_INCLUDE_DIR) -I mem_stall
COMMON_BAREMETAL_LIBS := -L $(RISCV_LIB_DIR) -Wl,--start-group -lm -lc -lgcc -Wl,--end-group

CUSTOM_GCC_FLAGS ?=

HELLO_WORLD_ELF := custom/hello_world.elf
HELLO_WORLD_HEX := custom/hello_world.hex
SOFTMAX_COMPARISON_ELF := custom/softmax_comparison.elf
SOFTMAX_COMPARISON_HEX := custom/softmax_comparison.hex
SIM_EXE := obj_dir/Vtb_top

FIRMWARE ?= $(HELLO_WORLD_HEX)

.DEFAULT_GOAL := help

define build_baremetal_program
	$(RISCV_EXE_PREFIX)gcc $(1) -o $@ -w $(2) -g -nostdlib \
		$(CUSTOM_GCC_FLAGS) \
		-T custom/link.ld \
		-static \
		custom/crt0.S \
		$^ \
		$(COMMON_BAREMETAL_INCLUDES) \
		$(COMMON_BAREMETAL_LIBS)
endef

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  make hello-world-run"
	@echo "  make softmax-comparison-run"
	@echo "  make verilator-build"
	@echo "  make clean"

%.hex: %.elf
	$(RISCV_EXE_PREFIX)objcopy -O verilog $< $@

$(HELLO_WORLD_ELF): custom/hello_world.c $(COMMON_BAREMETAL_SRCS)
	$(call build_baremetal_program,-march=rv32imc_zicsr -mabi=ilp32,-Os)

$(SOFTMAX_COMPARISON_ELF): custom/softmax_comparison.c $(COMMON_BAREMETAL_SRCS)
	$(call build_baremetal_program,-march=rv32imc_zicsr -mabi=ilp32,-O3)

$(SIM_EXE): $(RTLSRC_TB_PKG) $(RTLSRC_TB) sim_main.cpp $(VERILATOR_MANIFEST)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTLSRC_TB_PKG) $(RTLSRC_TB) \
		--top-module tb_top \
		--exe sim_main.cpp

.PHONY: verilator-build
verilator-build: $(SIM_EXE)

.PHONY: verilator-run
verilator-run: $(SIM_EXE) $(FIRMWARE)
	./$(SIM_EXE) +firmware=$(FIRMWARE)

.PHONY: hello-world-run
hello-world-run: $(HELLO_WORLD_HEX)
	$(MAKE) FIRMWARE=$(HELLO_WORLD_HEX) verilator-run

.PHONY: softmax-comparison-run
softmax-comparison-run: $(SOFTMAX_COMPARISON_HEX)
	$(MAKE) FIRMWARE=$(SOFTMAX_COMPARISON_HEX) verilator-run

.PHONY: clean
clean:
	rm -rf obj_dir
	rm -f custom/*.elf custom/*.hex
	rm -f transcript vsim.wlf vsim.dbg trace_core*.log objdump *.vcd
	rm -f sim_ram.bin sim_ram.hex
	rm -f softmax_performance.csv softmax_performance.png
