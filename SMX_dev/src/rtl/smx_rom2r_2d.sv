// Copyright (c) 2026 Luca Donato, Tommaso Spagnolo, Cristina Silvano
// SPDX-License-Identifier: MIT

// smx_rom2r_2d.sv: dual-port flattened 2D ROM, initialized via $readmemh in row-major order
`timescale 1ns/1ps
module smx_rom2r_2d #(
  parameter int    DATA_W   = 8,
  parameter int    COLS     = 11,
  parameter int    ROWS     = 60,
  parameter string INIT_HEX = "smx_lut2d.hex"
)(
  input  logic [$clog2(COLS)-1:0] col_a,
  input  logic [$clog2(ROWS)-1:0] row_a,
  input  logic [$clog2(COLS)-1:0] col_b,
  input  logic [$clog2(ROWS)-1:0] row_b,
  output logic [DATA_W-1:0]       dout_a,
  output logic [DATA_W-1:0]       dout_b
);
  localparam int DEPTH = ROWS*COLS;
  logic [DATA_W-1:0] mem [0:DEPTH-1];
  initial $readmemh(INIT_HEX, mem);

  function automatic int fl_idx(input int r, input int c);
    return r*COLS + c; // row-major
  endfunction

  assign dout_a = mem[ fl_idx(int'(row_a), int'(col_a)) ];
  assign dout_b = mem[ fl_idx(int'(row_b), int'(col_b)) ];
endmodule
