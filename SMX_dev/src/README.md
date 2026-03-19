<!--
Copyright (c) 2026 Luca Donato, Tommaso Spagnolo, Cristina Silvano
SPDX-License-Identifier: MIT
-->

# Verilator simulation helpers for SMX_dev/src

Overview
- This folder contains a small Makefile to build and run Verilator-based simulations.
- RTL sources: `rtl/`
- SystemVerilog testbenches: `dv/sv/`
- Verilator C++ harnesses/helpers: `dv/verilator/`

Quick start
1. Install Verilator and a C++ compiler (`g++` or `clang++`) and ensure they are in your PATH.
2. From this directory:
   ```bash
   make          # builds the default testbench (auto-detected)
   make sim      # runs the generated simulation binary
   ```

Running the available testbenches
- End-to-end datapath (CONTX→ACC→EXP→SIGM):
  ```bash
  make TOP=tb_smx_fu_lut
  make TOP=tb_smx_fu_lut sim
  ```
- CONTX-only sanity checks (8-byte reductions with edge cases):
  ```bash
  make TOP=tb_smx_fu_lut_contx
  make TOP=tb_smx_fu_lut_contx sim
  ```
- ACC, EXP, and SIGM focused benches (each instantiates the full DUT but only asserts one op-select). These mirror the LUT contents locally and run self-checking edge cases:
  ```bash
  make TOP=tb_smx_fu_lut_acc   # exercises accumulation path + rd feedback
  make TOP=tb_smx_fu_lut_exp   # stresses LUT1D packing/clamping
  make TOP=tb_smx_fu_lut_sigm  # targets LUT2D row/column selection
  ```
  Append `sim` (or run `./obj_dir/<top>/V<top>`) to execute after the build. Each test writes a `.vcd` waveform (`tb_smx_fu_lut_<mode>.vcd`) if you need to inspect signals.

Selecting a different testbench
- The Makefile auto-detects the first `*.sv` file in `dv/sv/` and uses its basename as the
  Verilator top module name. To build/run a specific testbench, override `TOP`:
  ```bash
  make TOP=tb_my_test
  make TOP=tb_my_test sim
  ```

Adding new simulations / benchtests
- SystemVerilog testbench: add your `tb_<name>.sv` file to `dv/sv/`. The testbench must
  instantiate your DUT module and use the name `tb_<name>` (or you can specify `TOP` manually).
- C++ harness: if your testbench requires custom C++ helpers (for file I/O, stimuli, etc.),
  add them under `dv/verilator/` (they will be compiled into the Verilator executable).
- ROM/hex data: place any `.hex` files referenced by RTL into `rtl/` (or use absolute paths).
