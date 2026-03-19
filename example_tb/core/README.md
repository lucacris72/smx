# `example_tb/core`

This directory contains the **active full-core simulation flow** used to benchmark the SMX-enabled `cv32e40p` with Verilator.

The current workflow is intentionally small:

- build bare-metal firmware,
- run it on `tb_top`,
- collect benchmark output from the simulator log.

## Prerequisites

- `verilator`
- `make`
- a RISC-V toolchain reachable through `RISCV` (default: `/opt/riscv`)

## Main targets

```bash
make hello-world-run
make softmax-comparison-run
python3 run_performance_sweep.py
```

## Performance sweep

`run_performance_sweep.py` recompiles `custom/softmax_comparison.c` for different `N`, runs the RTL simulation, parses:

- `FP32 Cycles`
- `SMX  Cycles`
- `SW Model Cycles`

and emits:

- `softmax_performance.csv`
- `softmax_performance.png`
