#!/usr/bin/env python3

from math import exp

LUT1D_DEPTH = 101
LUT2D_ROWS = 11
LUT2D_COLS = 60
MAX_VAL = 255


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


def emit_lut1d(lut):
    print("static const uint8_t lut1d[101] = {")
    for start in range(0, len(lut), 16):
        chunk = lut[start:start + 16]
        print("    " + ", ".join(f"0x{value:02x}" for value in chunk) + ",")
    print("};")


def emit_lut2d(lut):
    print("static const uint8_t lut2d[11][60] = {")
    for row in lut:
        print("    {")
        for start in range(0, len(row), 15):
            chunk = row[start:start + 15]
            print("        " + ", ".join(f"0x{value:02x}" for value in chunk) + ",")
        print("    },")
    print("};")


def main():
    emit_lut1d(generate_lut1d_exp())
    print()
    emit_lut2d(generate_lut2d_sigm())


if __name__ == "__main__":
    main()
