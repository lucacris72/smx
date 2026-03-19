// Copyright (c) 2026 Luca Donato, Tommaso Spagnolo, Cristina Silvano
// SPDX-License-Identifier: MIT

// smx_rom2r_1d.sv: 1D dual-port ROM (read-only, async), initialized via $readmemh
`timescale 1ns/1ps
module smx_rom2r_1d #(
  parameter int    DATA_W   = 8,
  parameter int    DEPTH    = 101,                // Default: 101 entries (x in [-6.4, 0] with step 0.05)
  parameter string INIT_HEX = "smx_lut1d.hex"
)(
  input  logic [$clog2(DEPTH)-1:0] addr_a,
  input  logic [$clog2(DEPTH)-1:0] addr_b,
  output logic [DATA_W-1:0]        dout_a,
  output logic [DATA_W-1:0]        dout_b
);
  logic [DATA_W-1:0] mem [0:DEPTH-1];
  initial $readmemh(INIT_HEX, mem);
  assign dout_a = mem[addr_a];
  assign dout_b = mem[addr_b];
endmodule
