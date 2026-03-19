// Copyright (c) 2026 Luca Donato, Tommaso Spagnolo, Cristina Silvano
// SPDX-License-Identifier: MIT

#ifndef VERILATOR_TOP_H
#define VERILATOR_TOP_H "Vtb_smx_fu_lut.h"
#endif

#ifndef VERILATOR_TOP_CLASS
#define VERILATOR_TOP_CLASS Vtb_smx_fu_lut
#endif

#include "verilated.h"
#include VERILATOR_TOP_H

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    VERILATOR_TOP_CLASS *top = new VERILATOR_TOP_CLASS;

    // Advance simulated time in 1-unit steps so `#` delays and event scheduling
    // in the SystemVerilog testbench progress as expected.
    Verilated::traceEverOn(true);
    vluint64_t main_time = 0;
    const vluint64_t TIME_LIMIT = 1000000ULL; // safety limit

    while (!Verilated::gotFinish() && main_time < TIME_LIMIT) {
        top->eval();
        main_time++;
        Verilated::timeInc(1);
    }

    delete top;
    return 0;
}
