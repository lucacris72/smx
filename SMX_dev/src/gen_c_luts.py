#!/usr/bin/env python3
# Copyright (c) 2026 Luca Donato, Tommaso Spagnolo, Cristina Silvano
# SPDX-License-Identifier: MIT

from math import exp
from pathlib import Path

LUT1D_DEPTH = 101
LUT2D_ROWS = 11
LUT2D_COLS = 60
MAX_VAL = 255
SCRIPT_DIR = Path(__file__).resolve().parent
LUT1D_PATH = SCRIPT_DIR / "smx_lut1d.hex"
LUT2D_PATH = SCRIPT_DIR / "smx_lut2d.hex"


def quantize_unit_interval(value):
    value = round(value * MAX_VAL)
    return max(0, min(MAX_VAL, int(value)))


def generate_lut1d_exp():
    step = 6.4 / (LUT1D_DEPTH - 1)
    return [quantize_unit_interval(exp(-i * step)) for i in range(LUT1D_DEPTH)]


def generate_lut2d_sigm():
    scale_num = 1.0 / (LUT2D_COLS - 1)
    lut = []
    for row in range(LUT2D_ROWS):
        row_values = []
        denom = max(float(row), 1.0)
        for col in range(LUT2D_COLS):
            num = col * scale_num
            row_values.append(quantize_unit_interval(num / denom))
        lut.append(row_values)
    return lut


def write_hex(path, values):
    with path.open("w", encoding="ascii") as handle:
        for value in values:
            handle.write(f"{value:02x}\n")


def flatten(rows):
    return [value for row in rows for value in row]


def main():
    write_hex(LUT1D_PATH, generate_lut1d_exp())
    write_hex(LUT2D_PATH, flatten(generate_lut2d_sigm()))
    print(f"Wrote {LUT1D_PATH.name} and {LUT2D_PATH.name}")


if __name__ == "__main__":
    main()
