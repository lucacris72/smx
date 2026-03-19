// Copyright (c) 2026 Luca Donato, Tommaso Spagnolo, Cristina Silvano
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

// Focused testbench for the SIGM path only.
// verilator lint_off PINCONNECTEMPTY
// verilator lint_off UNUSED
// verilator lint_off UNUSEDSIGNAL

module tb_smx_fu_lut_sigm 
  import cv32e40p_pkg::*;
;

  localparam int unsigned CLK_PERIOD_NS        = 10;
  localparam string       LUT2D_FILE           = "smx_lut2d.hex";
  localparam int unsigned LUT2D_COLS           = 60;
  localparam int unsigned LUT2D_ROWS           = 11;
  localparam int unsigned LUT2D_COL_IDX_W      = $clog2(LUT2D_COLS);
  localparam int unsigned LUT2D_ROW_IDX_W      = $clog2(LUT2D_ROWS);
  localparam int unsigned LUT2D_ROW_IDX_MAX    = LUT2D_ROWS - 1;
  localparam int unsigned LUT2D_COL_IDX_MAX    = LUT2D_COLS - 1;
  localparam int unsigned LUT2D_SUM_SHIFT_BITS = 8;

  logic clk = 1'b0;
  always #(CLK_PERIOD_NS/2) clk <= ~clk;
  logic rst_n_i;

  logic        smx_en_i;
  smx_opcode_e smx_operator_i;
  logic [31:0] rs1_value;
  logic [31:0] rs2_value;
  logic [31:0] rd_value;

  logic [31:0] wb_sigm_o;
  logic [31:0] wb_o;

  smx_fu_lut #(
    .REGISTER_FINAL_OUTPUT(1'b1)
  ) dut (
    .clk(clk),
    .rst_n_i(rst_n_i),
    .smx_en_i(smx_en_i),
    .smx_operator_i(smx_operator_i),
    .rs1_value(rs1_value),
    .rs2_value(rs2_value),
    .rd_value(rd_value),
    .wb_contx_o(),
    .wb_acc_o(),
    .wb_exp_o(),
    .wb_sigm_o(wb_sigm_o),
    .wb_o(wb_o)
  );

  logic [7:0] lut2d_mem [0:LUT2D_ROWS*LUT2D_COLS-1];
  initial $readmemh(LUT2D_FILE, lut2d_mem);

  function automatic logic [LUT2D_ROW_IDX_W-1:0]
  lut2d_row_index_model(input logic [31:0] sum_q08_u32);
    logic [31:0] shifted_sum;
    begin
      shifted_sum = sum_q08_u32 >> LUT2D_SUM_SHIFT_BITS;
      if (shifted_sum >= LUT2D_ROW_IDX_MAX) begin
        return LUT2D_ROW_IDX_MAX[LUT2D_ROW_IDX_W-1:0];
      end else begin
        return shifted_sum[LUT2D_ROW_IDX_W-1:0];
      end
    end
  endfunction

  function automatic logic [5:0] lane_col_idx(input logic [31:0] vec, input int lane);
    return vec[lane*8 + 7 -: 6];
  endfunction

  function automatic int lut2d_flat_index(input int row, input int col);
    return row*LUT2D_COLS + col;
  endfunction

  function automatic logic [7:0]
  lut2d_lookup(input logic [LUT2D_ROW_IDX_W-1:0] row,
               input logic [LUT2D_COL_IDX_W-1:0] col);
    return lut2d_mem[lut2d_flat_index(int'(row), int'(col))];
  endfunction

  function automatic logic [31:0]
  compute_sigm_result(input logic [31:0] sum_q08,
                      input logic [31:0] exp_vec);
    logic [LUT2D_ROW_IDX_W-1:0] row_idx;
    logic [7:0] sigm_lane[0:3];
    logic [LUT2D_COL_IDX_W-1:0] col_idx;
    begin
      row_idx = lut2d_row_index_model(sum_q08);
      for (int lane = 0; lane < 4; lane++) begin
        col_idx = lane_col_idx(exp_vec, lane);
        if (col_idx > LUT2D_COL_IDX_W'(LUT2D_COL_IDX_MAX)) col_idx = LUT2D_COL_IDX_W'(LUT2D_COL_IDX_MAX);
        sigm_lane[lane] = lut2d_lookup(row_idx, col_idx);
      end
      return {sigm_lane[3], sigm_lane[2], sigm_lane[1], sigm_lane[0]};
    end
  endfunction

  int unsigned num_checks;
  int unsigned error_count;

  task automatic run_case(
    input string label,
    input logic [31:0] sum_q08,
    input logic [31:0] exp_vec
  );
    logic [31:0] expected;
    begin
      expected = compute_sigm_result(sum_q08, exp_vec);

      rs1_value     = sum_q08;
      rs2_value     = exp_vec;
      rd_value      = 32'd0;
      smx_operator_i = SMX_SIGM;

      @(posedge clk);
      #1;

      num_checks++;

      if (wb_o !== expected) begin
        error_count++;
        $error("[%s] wb_o mismatch: 0x%08x != 0x%08x", label, wb_o, expected);
      end else begin
        $display("[%s] wb_o OK -> 0x%08x", label, wb_o);
      end

      if (wb_sigm_o !== expected) begin
        error_count++;
        $error("[%s] wb_sigm_o mismatch: 0x%08x != 0x%08x", label, wb_sigm_o, expected);
      end
    end
  endtask

  initial begin
    $display("--- [TB_SIGM] smx_fu_lut SIGM tests ---");
    $dumpfile("tb_smx_fu_lut_sigm.vcd");
    $dumpvars(0, tb_smx_fu_lut_sigm);

    smx_en_i      = 1'b0;
    smx_operator_i = SMX_NONE;
    rs1_value     = '0;
    rs2_value     = '0;
    rd_value      = '0;
    rst_n_i       = 1'b0;

    repeat (4) @(posedge clk);
    rst_n_i  = 1'b1;
    @(posedge clk);

    smx_en_i = 1'b1;

    // Small sum -> row 0
    run_case("row0_basic",
             32'd12,
             {8'h10, 8'h32, 8'h54, 8'h76});

    // Moderate sum -> mid row
    run_case("row_mid",
             32'd2048,
             {8'hf1, 8'he2, 8'hd3, 8'hc4});

    // Very large sum -> clamp to last row
    run_case("row_clamp",
             32'h00FF_FFFF,
             {8'hff, 8'hef, 8'hde, 8'hcd});

    run_case("TEST",
             32'h0000_0298,
             {8'h62, 8'hff, 8'hff, 8'h38});

    $display("--- [TB_SIGM] Completed with %0d checks, %0d errors ---", num_checks, error_count);
    if (error_count == 0) begin
      $display("*** TB_SIGM PASS ***");
    end else begin
      $fatal(1, "*** TB_SIGM FAIL ***");
    end
    $finish;
  end

endmodule
