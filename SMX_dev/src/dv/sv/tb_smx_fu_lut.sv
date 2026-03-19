// Copyright (c) 2026 Luca Donato, Tommaso Spagnolo, Cristina Silvano
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

// Benign warnings triggered by intentional unused signals/ports in the TB
// verilator lint_off PINCONNECTEMPTY
// verilator lint_off UNUSED
// verilator lint_off UNUSEDSIGNAL

module tb_smx_fu_lut 
  import cv32e40p_pkg::*;
;

  localparam int unsigned CLK_PERIOD_NS = 10;

  localparam string       LUT1D_FILE              = "smx_lut1d.hex";
  localparam string       LUT2D_FILE              = "smx_lut2d.hex";
  localparam int unsigned LUT1D_DEPTH             = 101;
  localparam int unsigned LUT1D_IDX_W             = $clog2(LUT1D_DEPTH);
  localparam int unsigned LUT1D_IDX_MAX           = LUT1D_DEPTH - 1;
  localparam int unsigned LUT2D_COLS              = 60;
  localparam int unsigned LUT2D_ROWS              = 11;
  localparam int unsigned LUT2D_COL_IDX_W         = $clog2(LUT2D_COLS);
  localparam int unsigned LUT2D_ROW_IDX_W         = $clog2(LUT2D_ROWS);
  localparam int unsigned LUT2D_ROW_IDX_MAX       = LUT2D_ROWS - 1;
  localparam int unsigned LUT2D_COL_IDX_MAX       = LUT2D_COLS - 1;
  localparam int unsigned LUT2D_SUM_SHIFT_BITS    = 8;

  typedef enum int unsigned {
    OP_CONTX,
    OP_ACC,
    OP_EXP,
    OP_SIGM
  } smx_op_e;

  // ---------------------------------------------------------------------------
  // Clock/reset
  // ---------------------------------------------------------------------------
  logic clk = 1'b0;
  always #(CLK_PERIOD_NS/2) clk <= ~clk;

  logic rst_n_i;

  // ---------------------------------------------------------------------------
  // DUT signals
  // ---------------------------------------------------------------------------
  logic        smx_en_i;
  smx_opcode_e smx_operator_i;
  logic [31:0] rs1_value;
  logic [31:0] rs2_value;
  logic [31:0] rd_value;

  logic [31:0] wb_contx_o;
  logic [31:0] wb_acc_o;
  logic [31:0] wb_exp_o;
  logic [31:0] wb_sigm_o;
  logic [31:0] wb_o;

  smx_fu_lut #(
    .REGISTER_FINAL_OUTPUT(1'b1),
    .LUT1D_DEPTH(LUT1D_DEPTH),
    .LUT2D_ROWS(LUT2D_ROWS),
    .LUT2D_COLS(LUT2D_COLS)
  ) DUT (
    .clk(clk),
    .rst_n_i(rst_n_i),
    .smx_en_i(smx_en_i),
    .smx_operator_i(smx_operator_i),
    .rs1_value(rs1_value),
    .rs2_value(rs2_value),
    .rd_value(rd_value),
    .wb_contx_o(wb_contx_o),
    .wb_acc_o(wb_acc_o),
    .wb_exp_o(wb_exp_o),
    .wb_sigm_o(wb_sigm_o),
    .wb_o(wb_o)
  );

  // ---------------------------------------------------------------------------
  // Local golden LUT copies
  // ---------------------------------------------------------------------------
  logic [7:0] lut1d_mem [0:LUT1D_DEPTH-1];
  logic [7:0] lut2d_mem [0:LUT2D_ROWS*LUT2D_COLS-1];

  initial begin
    $readmemh(LUT1D_FILE, lut1d_mem);
    $readmemh(LUT2D_FILE, lut2d_mem);
  end

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  function automatic logic signed [7:0] lane_s8(input logic [31:0] vec, input int lane);
    return $signed(vec[lane*8 +: 8]);
  endfunction

  function automatic logic [3:0] nibble(input logic [31:0] vec, input int lane);
    return vec[(lane*8)+4 +: 4];
  endfunction

  function automatic logic signed [7:0] max2(input logic signed [7:0] a, input logic signed [7:0] b);
    return (a > b) ? a : b;
  endfunction

  function automatic int clz(input logic [7:0] val);
    if (val[7]) return 0;
    if (val[6]) return 1;
    if (val[5]) return 2;
    if (val[4]) return 3;
    if (val[3]) return 4;
    if (val[2]) return 5;
    if (val[1]) return 6;
    if (val[0]) return 7;
    return 8;
  endfunction

  function automatic logic [LUT1D_IDX_W-1:0]
  lut1d_index_model(input logic signed [7:0] x_int8, input logic signed [7:0] xmax_int8, input logic signed [3:0] shift);
    logic [8:0] positive_delta;
    logic [16:0] shifted_delta; // Wider to handle left shift
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
      idx_tmp_int = int'(shifted_delta); // Check full value for clamping
      
      if (idx_tmp_int > LUT1D_IDX_MAX) idx_tmp = LUT1D_IDX_MAX[LUT1D_IDX_W-1:0];
      return idx_tmp;
    end
  endfunction

  function automatic logic [LUT2D_ROW_IDX_W-1:0]
  lut2d_row_index_model(input logic [31:0] sum_q08_u32);
    logic [31:0] shifted_sum;
    begin
      shifted_sum = (sum_q08_u32) >> LUT2D_SUM_SHIFT_BITS; 
      if (shifted_sum >= LUT2D_ROW_IDX_MAX) begin
        return LUT2D_ROW_IDX_MAX[LUT2D_ROW_IDX_W-1:0];
      end else begin
        return shifted_sum[LUT2D_ROW_IDX_W-1:0];
      end
    end
  endfunction

  function automatic int lut2d_flat_index(input int row, input int col);
    return row*LUT2D_COLS + col;
  endfunction

  function automatic logic [7:0]
  lut2d_lookup(input logic [LUT2D_ROW_IDX_W-1:0] row,
               input logic [LUT2D_COL_IDX_W-1:0] col);
    int idx;
    begin
      idx = lut2d_flat_index(int'(row), int'(col));
      return lut2d_mem[idx];
    end
  endfunction

  function automatic logic signed [7:0] min2(input logic signed [7:0] a, input logic signed [7:0] b);
    return (a < b) ? a : b;
  endfunction

  function automatic logic [31:0]
  compute_contx_result(input logic [31:0] rs1, input logic [31:0] rs2, input logic [31:0] rd);
    logic signed [7:0] lanes [0:7];
    logic signed [7:0] rd_scalar;
    logic signed [7:0] best_max;
    logic signed [7:0] best_min;
    logic [7:0] delta_max;
    int lzc_delta, lzc_lut;
    int shift_calc;
    logic [3:0] shift_final;
    begin
      for (int i = 0; i < 4; i++) begin
        lanes[i]     = lane_s8(rs1, i);
        lanes[i + 4] = lane_s8(rs2, i);
      end
      rd_scalar = $signed(rd[7:0]);
      
      // Find Max
      best_max = lanes[0];
      for (int k = 1; k < 8; k++) best_max = max2(best_max, lanes[k]);
      best_max = max2(best_max, rd_scalar);
      
      // Find Min (Global)
      // rd layout: {12'd0, min_running, shift, max_running}
      best_min = lanes[0];
      for (int k = 1; k < 8; k++) best_min = min2(best_min, lanes[k]);
      
      // Extract running min from rd[19:12]
      // Note: If this is the first iteration, rd should be initialized.
      // In the testbench, we control rd.
      best_min = min2(best_min, $signed(rd[15:8]));
      
      // Calculate Shift
      delta_max = best_max - best_min;
      lzc_delta = clz(delta_max);
      lzc_lut   = clz(LUT1D_DEPTH[7:0]);
      shift_calc = lzc_delta - lzc_lut;
      
      if (shift_calc > 7) shift_final = 4'd7;
      else if (shift_calc < -8) shift_final = 4'd8;
      else shift_final = shift_calc[3:0];
      
      // Pack: {12'd0, Shift, Min, Max}
      return {12'd0, shift_final, best_min, best_max};
    end
  endfunction

  function automatic logic [31:0]
  compute_acc_result(input logic [31:0] rs1, input logic [31:0] rs2, input logic [31:0] rd);
    logic signed [7:0] xmax_int8;
    logic signed [3:0] shift;
    logic [LUT1D_IDX_W-1:0] idx[0:3];
    logic [7:0] exp_lane[0:3];
    logic [31:0] sum;
    begin
      xmax_int8 = $signed(rs2[7:0]);
      shift     = $signed(rs2[19:16]);
      for (int lane = 0; lane < 4; lane++) begin
        idx[lane]      = lut1d_index_model(lane_s8(rs1, lane), xmax_int8, shift);
        exp_lane[lane] = lut1d_mem[idx[lane]];
      end
      sum = rd;
      for (int lane = 0; lane < 4; lane++) begin
        sum = sum + {24'd0, exp_lane[lane]};
      end
      return sum;
    end
  endfunction

  function automatic logic [31:0]
  compute_exp_result(input logic [31:0] rs1, input logic [31:0] rs2);
    logic signed [7:0] xmax_int8;
    logic signed [3:0] shift;
    logic [7:0] exp_lane[0:3];
    begin
      xmax_int8 = $signed(rs2[7:0]);
      shift     = $signed(rs2[19:16]);
      for (int lane = 0; lane < 4; lane++) begin
        exp_lane[lane] = lut1d_mem[lut1d_index_model(lane_s8(rs1, lane), xmax_int8, shift)];
      end
      return {exp_lane[3], exp_lane[2], exp_lane[1], exp_lane[0]};
    end
  endfunction

  function automatic logic [31:0]
  compute_sigm_result(input logic [31:0] sum_q08, input logic [31:0] exp_vec);
    logic [LUT2D_ROW_IDX_W-1:0] row_idx;
    logic [LUT2D_COL_IDX_W-1:0] col_idx;
    logic [7:0] exp_val;
    logic [7:0] sigm_lane[0:3];
    begin
      row_idx = lut2d_row_index_model(sum_q08);
      for (int lane = 0; lane < 4; lane++) begin
        exp_val = lane_s8(exp_vec, lane); // Extract 8-bit Exp
        
        // MSB Approximation for Column Index (matches HW)
        // Map 0..255 to 0..59 using top 6 bits
        if (32'(exp_val[7:2]) > LUT2D_COL_IDX_MAX) 
          col_idx = LUT2D_COL_IDX_MAX[LUT2D_COL_IDX_W-1:0];
        else 
          col_idx = exp_val[7:2];
          
        sigm_lane[lane] = lut2d_lookup(row_idx, col_idx);
      end
      return {sigm_lane[3], sigm_lane[2], sigm_lane[1], sigm_lane[0]};
    end
  endfunction

  function automatic logic [31:0]
  compute_expected(input smx_op_e op,
                   input logic [31:0] rs1,
                   input logic [31:0] rs2,
                   input logic [31:0] rd);
    case (op)
      OP_CONTX: return compute_contx_result(rs1, rs2, rd);
      OP_ACC : return compute_acc_result(rs1, rs2, rd);
      OP_EXP : return compute_exp_result(rs1, rs2);
      OP_SIGM: return compute_sigm_result(rs1, rs2);
      default: return '0;
    endcase
  endfunction

  function automatic string op_name(input smx_op_e op);
    case (op)
      OP_CONTX: return "CONTX";
      OP_ACC : return "ACC";
      OP_EXP : return "EXP";
      OP_SIGM: return "SIGM";
      default: return "???";
    endcase
  endfunction

  int unsigned num_checks;
  int unsigned error_count;
  logic [31:0] result;
  logic [31:0] acc_sum_stage0;
  logic [31:0] acc_sum_stage1;
  logic [31:0] exp_vec0;
  logic [31:0] exp_vec1;

  task automatic run_case(
    input  string   label,
    input  smx_op_e op,
    input  logic [31:0] rs1,
    input  logic [31:0] rs2,
    input  logic [31:0] rd,
    output logic [31:0] observed
  );
    logic [31:0] expected;
    logic [31:0] branch_value;
    begin
      expected = compute_expected(op, rs1, rs2, rd);

      case (op)
        OP_CONTX: smx_operator_i = SMX_CONTX;
        OP_ACC : smx_operator_i = SMX_ACC;
        OP_EXP : smx_operator_i = SMX_EXP;
        OP_SIGM: smx_operator_i = SMX_SIGM;
        default: smx_operator_i = SMX_NONE;
      endcase
      rs1_value     = rs1;
      rs2_value     = rs2;
      rd_value      = rd;

      @(posedge clk);
      #1;

      observed = wb_o;
      num_checks++;

      if (observed !== expected) begin
        error_count++;
        $error("[%s] %s mismatch: got 0x%08x expected 0x%08x",
               label, op_name(op), observed, expected);
      end else begin
        $display("[%s] %s OK -> 0x%08x", label, op_name(op), observed);
      end

      case (op)
        OP_CONTX: branch_value = wb_contx_o;
        OP_ACC : branch_value = wb_acc_o;
        OP_EXP : branch_value = wb_exp_o;
        default: branch_value = wb_sigm_o;
      endcase

      if (branch_value !== expected) begin
        error_count++;
        $error("[%s] branch result mismatch: got 0x%08x expected 0x%08x",
               label, branch_value, expected);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------------
  initial begin
    $display("--- [TB] smx_fu_lut smoke test ---");
    $dumpfile("tb_smx_fu_lut.vcd");
    $dumpvars(0, tb_smx_fu_lut);

    smx_en_i     = 1'b0;
    smx_operator_i = SMX_NONE;
    rs1_value    = '0;
    rs2_value    = '0;
    rd_value     = '0;
    rst_n_i      = 1'b0;
    repeat (4) @(posedge clk);
    rst_n_i      = 1'b1;

    @(posedge clk);
    smx_en_i = 1'b1;

    // CONTX path checks
    run_case("contx_posmix",
             OP_CONTX,
             {8'sd40, 8'sd15, -8'sd3, 8'sd12},
             {8'sd5, 8'sd63, -8'sd10, 8'sd9},
             32'sd0,
             result);

    run_case("contx_with_rd",
             OP_CONTX,
             {-8'sd1, -8'sd2, -8'sd3, -8'sd4},
             {-8'sd10, -8'sd11, -8'sd12, -8'sd13},
             32'sd50,
             result);

    // Check Global Min Tracking
    // rd has min=10 (at [19:12])
    // inputs have min=5. Result min should be 5.
    // inputs have max=20. rd has max=50. Result max should be 50.
    run_case("contx_min_global",
             OP_CONTX,
             {8'sd5, 8'sd6, 8'sd7, 8'sd8},
             {8'sd15, 8'sd16, 8'sd17, 8'sd20},
             {12'd0, 4'd0, 8'sd10, 8'sd50}, // rd: min=10, max=50
             result);

    // ACC covering multi-cycle accumulation (rd feedback)
    run_case("acc_vec0",
             OP_ACC,
             {8'sd20, -8'sd1, 8'sd9, -8'sd30},
             {24'd0, 8'sd25},
             32'd0,
             acc_sum_stage0);

    run_case("acc_vec1",
             OP_ACC,
             {8'sd7, -8'sd12, 8'sd4, 8'sd25},
             {24'd0, 8'sd25},
             acc_sum_stage0,
             acc_sum_stage1);

    // EXP paths driven with the same xmax used by the accumulator
    run_case("exp_vec0",
             OP_EXP,
             {8'sd20, -8'sd1, 8'sd9, -8'sd30},
             {24'd0, 8'sd25},
             32'd0,
             exp_vec0);

    run_case("exp_vec1",
             OP_EXP,
             {8'sd7, -8'sd12, 8'sd4, 8'sd25},
             {24'd0, 8'sd25},
             32'd0,
             exp_vec1);

    // SIGM uses the accumulated sum + EXP output as inputs
    run_case("sigm_vec0",
             OP_SIGM,
             acc_sum_stage1,
             exp_vec0,
             32'd0,
             result);

    run_case("sigm_vec1",
             OP_SIGM,
             acc_sum_stage1,
             exp_vec1,
             32'd0,
             result);

    // Output register hold check when smx_en_i is low
    smx_en_i = 1'b0;
    smx_operator_i = SMX_CONTX;
    rs1_value = {8'sd100, 8'sd0, 8'sd0, 8'sd0};
    rs2_value = {-8'sd100, 8'sd0, 8'sd0, 8'sd0};
    rd_value  = 32'd0;

    @(posedge clk);
    #1;
    num_checks++;
    if (wb_o !== result) begin
      error_count++;
      $error("[hold_check] wb_o changed while smx_en_i=0 (got 0x%08x, expected 0x%08x)", wb_o, result);
    end else begin
      $display("[hold_check] wb_o correctly held 0x%08x when smx_en_i=0", wb_o);
    end

    $display("--- [TB] Completed with %0d checks, %0d errors ---", num_checks, error_count);
    if (error_count == 0) begin
      $display("*** TB PASS ***");
    end else begin
      $fatal(1, "*** TB FAIL ***");
    end
  end

endmodule
