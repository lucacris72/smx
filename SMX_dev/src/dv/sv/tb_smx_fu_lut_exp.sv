// Copyright (c) 2026 Luca Donato, Tommaso Spagnolo, Cristina Silvano
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

// Focused testbench for the EXP path only.
// verilator lint_off PINCONNECTEMPTY
// verilator lint_off UNUSED
// verilator lint_off UNUSEDSIGNAL

module tb_smx_fu_lut_exp 
  import cv32e40p_pkg::*;
;

  localparam int unsigned CLK_PERIOD_NS = 10;
  localparam string       LUT1D_FILE    = "smx_lut1d.hex";
  localparam int unsigned LUT1D_DEPTH   = 101;
  localparam int unsigned LUT1D_IDX_W   = $clog2(LUT1D_DEPTH);
  localparam int unsigned LUT1D_IDX_MAX = LUT1D_DEPTH - 1;

  logic clk = 1'b0;
  always #(CLK_PERIOD_NS/2) clk <= ~clk;
  logic rst_n_i;

  logic        smx_en_i;
  smx_opcode_e smx_operator_i;
  logic [31:0] rs1_value;
  logic [31:0] rs2_value;
  logic [31:0] rd_value;

  logic [31:0] wb_exp_o;
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
    .wb_exp_o(wb_exp_o),
    .wb_sigm_o(),
    .wb_o(wb_o)
  );

  logic [7:0] lut1d_mem [0:LUT1D_DEPTH-1];
  initial $readmemh(LUT1D_FILE, lut1d_mem);

  function automatic logic signed [7:0] lane_s8(input logic [31:0] vec, input int lane);
    return $signed(vec[lane*8 +: 8]);
  endfunction

  function automatic logic [LUT1D_IDX_W-1:0]
  lut1d_index_model(input logic signed [7:0] x_int8, input logic signed [7:0] xmax_int8, input logic signed [3:0] shift);
    logic [8:0] positive_delta;
    logic [16:0] shifted_delta;
    logic [LUT1D_IDX_W-1:0] idx_tmp;
    int idx_tmp_int;
    begin
      positive_delta = {xmax_int8[7], xmax_int8} - {x_int8[7], x_int8};
      if (positive_delta[8]) positive_delta = '0;
      
      // Adaptive Shift
      if (shift[3]) begin // Negative -> Right Shift
         logic [3:0] rshift = (~shift) + 1;
         shifted_delta = {8'd0, positive_delta} >> rshift;
      end else begin // Positive -> Left Shift
         shifted_delta = {8'd0, positive_delta} << shift;
      end

      idx_tmp = shifted_delta[LUT1D_IDX_W-1:0];
      idx_tmp_int = int'(shifted_delta);
      
      if (idx_tmp_int > LUT1D_IDX_MAX) idx_tmp = LUT1D_IDX_MAX[LUT1D_IDX_W-1:0];
      return idx_tmp;
    end
  endfunction

  function automatic logic [31:0]
  compute_exp_result(input logic [31:0] rs1,
                     input logic signed [7:0] xmax);
    logic [7:0] exp_lane[0:3];
    begin
      for (int lane = 0; lane < 4; lane++) begin
        exp_lane[lane] = lut1d_mem[lut1d_index_model(lane_s8(rs1, lane), xmax, 4'd0)];
      end
      return {exp_lane[3], exp_lane[2], exp_lane[1], exp_lane[0]};
    end
  endfunction

  int unsigned num_checks;
  int unsigned error_count;

  task automatic run_case(
    input  string   label,
    input  logic [31:0] rs1,
    input  logic signed [7:0] xmax
  );
    logic [31:0] expected;
    begin
      expected = compute_exp_result(rs1, xmax);

      rs1_value    = rs1;
      rs2_value    = {24'd0, xmax};
      rd_value     = 32'd0;
      smx_operator_i = SMX_EXP;

      @(posedge clk);
      #1;

      num_checks++;

      if (wb_o !== expected) begin
        error_count++;
        $error("[%s] wb_o mismatch: 0x%08x != 0x%08x", label, wb_o, expected);
      end else begin
        $display("[%s] wb_o OK -> 0x%08x", label, wb_o);
      end

      if (wb_exp_o !== expected) begin
        error_count++;
        $error("[%s] wb_exp_o mismatch: 0x%08x != 0x%08x", label, wb_exp_o, expected);
      end
    end
  endtask

  initial begin
    $display("--- [TB_EXP] smx_fu_lut EXP tests ---");
    $dumpfile("tb_smx_fu_lut_exp.vcd");
    $dumpvars(0, tb_smx_fu_lut_exp);

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

    // Mixed signed inputs
    run_case("mixed",
             {8'sd20, -8'sd5, 8'sd0, -8'sd30},
             8'sd20);

    // All lanes greater than xmax -> clamp to highest LUT entry
    run_case("delta_negative_clamp",
             {8'sd60, 8'sd55, 8'sd50, 8'sd45},
             8'sd40);

    // All lanes far below xmax -> saturate to LUT index 127
    run_case("delta_high_saturate",
             {-8'sd128, -8'sd120, -8'sd110, -8'sd100},
             8'sd70);
    
    run_case("TEST",
             {8'sd42, 8'sd102, -8'sd153, 8'sd63},
             8'sd102);


    $display("--- [TB_EXP] Completed with %0d checks, %0d errors ---", num_checks, error_count);
    if (error_count == 0) begin
      $display("*** TB_EXP PASS ***");
    end else begin
      $fatal(1, "*** TB_EXP FAIL ***");
    end
    $finish;
  end

endmodule
