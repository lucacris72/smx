// Copyright (c) 2026 Luca Donato, Tommaso Spagnolo, Cristina Silvano
// SPDX-License-Identifier: MIT

// smx_fu_lut.sv : FU SoftMax with Adaptive Shift and Custom LUT Sizes
`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */

module smx_fu_lut 
  import cv32e40p_pkg::*;
#(
  parameter bit REGISTER_FINAL_OUTPUT = 1'b1,
  
  // LUT Dimensions
  parameter int unsigned LUT1D_DEPTH = 101,
  parameter int unsigned LUT2D_ROWS  = 11,
  parameter int unsigned LUT2D_COLS  = 60,
  
  // Derived Parameters
  parameter int unsigned LUT1D_IDX_W     = $clog2(LUT1D_DEPTH),
  parameter int unsigned LUT1D_IDX_MAX   = LUT1D_DEPTH - 1,
  parameter int unsigned LUT2D_ROW_IDX_W = $clog2(LUT2D_ROWS),
  parameter int unsigned LUT2D_COL_IDX_W = $clog2(LUT2D_COLS),
  parameter int unsigned LUT2D_ROW_IDX_MAX = LUT2D_ROWS - 1,
  parameter int unsigned LUT2D_COL_IDX_MAX = LUT2D_COLS - 1
)(
  input  logic        clk,
  input  logic        rst_n_i,

  // Operation Selection
  input  logic        smx_en_i,
  input  smx_opcode_e smx_operator_i,

  // Data Inputs
  input  logic [31:0] rs1_value,   // Packed 4x8b or Sum32
  input  logic [31:0] rs2_value,   // Packed 4x8b or {Shift, Xmax} or ExpVec
  input  logic [31:0] rd_value,    // Running Max/Min or Accumulator

  // Outputs
  output logic [31:0] wb_contx_o,  // Result of SMX.CONTX
  output logic [31:0] wb_acc_o,    // Result of SMX.ACC
  output logic [31:0] wb_exp_o,    // Result of SMX.EXP
  output logic [31:0] wb_sigm_o,   // Result of SMX.SIGM
  output logic [31:0] wb_o         // Final Muxed Output
);

  // =====================================================================
  // Unpack Lanes
  // =====================================================================
  logic signed [7:0] rs1_lane0, rs1_lane1, rs1_lane2, rs1_lane3;
  logic signed [7:0] rs2_lane0, rs2_lane1, rs2_lane2, rs2_lane3;

  assign {rs1_lane3, rs1_lane2, rs1_lane1, rs1_lane0} = rs1_value;
  assign {rs2_lane3, rs2_lane2, rs2_lane1, rs2_lane0} = rs2_value;

  // =====================================================================
  // 1) SMX.CONTX: Find Max AND Min (for Adaptive Shift)
  // =====================================================================
  // ISA: SMX.CONTX builds the softmax context from rs1, rs2, rd.
  // We extend it to also find min internally.
  
  function automatic logic signed [7:0] max_s8(input logic signed [7:0] a, input logic signed [7:0] b);
    return (a > b) ? a : b;
  endfunction

  function automatic logic signed [7:0] min_s8(input logic signed [7:0] a, input logic signed [7:0] b);
    return (a < b) ? a : b;
  endfunction

  logic signed [7:0] max_rs1, max_rs2, max_all, max_final;
  logic signed [7:0] min_rs1, min_rs2, min_all, min_final;
  logic signed [7:0] min_running;
  logic signed [7:0] max_running;
  
  assign max_running = rd_value[7:0];
  assign min_running = rd_value[15:8];

  always_comb begin
    // Max Tree
    max_rs1 = max_s8(max_s8(rs1_lane0, rs1_lane1), max_s8(rs1_lane2, rs1_lane3));
    max_rs2 = max_s8(max_s8(rs2_lane0, rs2_lane1), max_s8(rs2_lane2, rs2_lane3));
    max_all = max_s8(max_rs1, max_rs2);
    max_final = max_s8(max_all, max_running);
    
    // Min Tree (New for Adaptive Shift)
    min_rs1 = min_s8(min_s8(rs1_lane0, rs1_lane1), min_s8(rs1_lane2, rs1_lane3));
    min_rs2 = min_s8(min_s8(rs2_lane0, rs2_lane1), min_s8(rs2_lane2, rs2_lane3));
    min_all = min_s8(min_rs1, min_rs2);
    min_final = min_s8(min_all, min_running);    
  end

  // Calculate Range and Shift (Combinational)
  logic [7:0] delta_max;
  logic [3:0] lzc_delta;
  logic       lzc_delta_empty;
  logic signed [4:0] shift_calc; // 5 bits to avoid overflow during calc
  logic [3:0] shift_final;

  assign delta_max = max_final - min_final;

  // LZC for Delta Max
  smx_lzc lzc_d_inst (
    .in_i   (delta_max),
    .cnt_o  (lzc_delta),
    .empty_o(lzc_delta_empty)
  );

  // LZC for LUT Depth (Constant)
  // Calculated at elaboration time
  function automatic logic [3:0] calc_lzc_const(input logic [7:0] val);
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

  localparam logic [3:0] LZC_LUT = calc_lzc_const(LUT1D_DEPTH[7:0]);

  always_comb begin
    // k = lzc(delta) - lzc(lut)
    shift_calc = {1'b0, lzc_delta} - {1'b0, LZC_LUT};
    
    // Clamp to 4-bit signed range (-8 to +7)
    if (shift_calc > 7) shift_final = 4'd7;
    else if (shift_calc < -8) shift_final = 4'd8; // -8 in 2's comp
    else shift_final = shift_calc[3:0];
  end

  // Pack Shift and Min into Output
  // Layout: {12'b0, Shift[3:0], Min[7:0], Max[7:0]}
  // Max: [7:0]
  // Min: [15:8]
  // Shift: [19:16]
  assign wb_contx_o = {12'd0, shift_final, min_final, max_final};

  // =====================================================================
  // 2) SMX.ACC / SMX.EXP: Adaptive Shift + LUT1D
  // =====================================================================
  // Inputs:
  // rs1: vector of 4 int8 values
  // rs2: {12'b0, Shift[3:0], Min[7:0], Xmax[7:0]}
  // Keep the existing layout for consistency; Min is currently unused here.
  
  logic signed [7:0] xmax_in;
  logic [3:0]        shift_in;
  
  assign xmax_in  = rs2_value[7:0];
  assign shift_in = rs2_value[19:16]; // Adaptive Shift Amount

  function automatic logic [LUT1D_IDX_W-1:0] get_lut1_idx(
    input logic signed [7:0] val, 
    input logic signed [7:0] max_val,
    input logic [3:0]        shift
  );
    logic [8:0] delta; // 9 bits for sign
    logic [8:0] delta_shifted;
    logic [LUT1D_IDX_W-1:0] idx;
    begin
      delta = {max_val[7], max_val} - {val[7], val};
      if (delta[8]) delta = 0; // Clamp negative delta (shouldn't happen if max is correct)
      
      // Adaptive Shift
      // shift is 4-bit signed (-8 to +7)
      // Positive -> Left Shift (Multiply)
      // Negative -> Right Shift (Divide)
      
      if (shift[3]) begin // Negative (Right Shift)
        // 2's complement negation: -shift = (~shift + 1)
        logic [3:0] right_shift_amt;
        right_shift_amt = (~shift) + 1;
        delta_shifted = delta >> right_shift_amt;
      end else begin // Positive (Left Shift)
        delta_shifted = delta << shift;
      end
      
      // Clamp to LUT Size
      if (delta_shifted > LUT1D_IDX_MAX) 
        idx = LUT1D_IDX_MAX[LUT1D_IDX_W-1:0];
      else 
        idx = delta_shifted[LUT1D_IDX_W-1:0];
        
      return idx;
    end
  endfunction

  logic [LUT1D_IDX_W-1:0] idx0, idx1, idx2, idx3;
  assign idx0 = get_lut1_idx(rs1_lane0, xmax_in, shift_in);
  assign idx1 = get_lut1_idx(rs1_lane1, xmax_in, shift_in);
  assign idx2 = get_lut1_idx(rs1_lane2, xmax_in, shift_in);
  assign idx3 = get_lut1_idx(rs1_lane3, xmax_in, shift_in);

  // LUT1D Instantiation (4 reads)
  // We need a ROM that supports arbitrary depth.
  // Assuming smx_rom2r_1d handles address width correctly based on parameter.
  
  logic [7:0] exp0, exp1, exp2, exp3;

  smx_rom2r_1d #(.DEPTH(LUT1D_DEPTH), .INIT_HEX("smx_lut1d.hex")) lut1_a (
    .addr_a(idx0), .addr_b(idx1), .dout_a(exp0), .dout_b(exp1)
  );
  smx_rom2r_1d #(.DEPTH(LUT1D_DEPTH), .INIT_HEX("smx_lut1d.hex")) lut1_b (
    .addr_a(idx2), .addr_b(idx3), .dout_a(exp2), .dout_b(exp3)
  );

  // SMX.ACC Output
  assign wb_acc_o = rd_value + {24'd0, exp0} + {24'd0, exp1} + {24'd0, exp2} + {24'd0, exp3};

  // SMX.EXP Output
  assign wb_exp_o = {exp3, exp2, exp1, exp0};

  // =====================================================================
  // 3) SMX.SIGM: LUT2D (11x60)
  // =====================================================================
  // rs1: Sum (32-bit)
  // rs2: Exp Vector (4x8b)
  
  // Row Index (from Sum)
  // We need to map Sum to [0..10].
  // Previous logic: (sum >> 8).
  // With 11 rows, we might need a different mapping or just clamp.
  // Let's stick to (sum >> 8) and clamp to 10.
  
  logic [LUT2D_ROW_IDX_W-1:0] row_idx;
  logic [31:0] sum_shifted;
  
  always_comb begin
    sum_shifted = (rs1_value >> 8); // Simple shift for now
    if (sum_shifted > LUT2D_ROW_IDX_MAX)
      row_idx = LUT2D_ROW_IDX_MAX[LUT2D_ROW_IDX_W-1:0];
    else
      row_idx = sum_shifted[LUT2D_ROW_IDX_W-1:0];
  end

  // Col Index (from Exp)
  function automatic logic [LUT2D_COL_IDX_W-1:0] get_col_idx(input logic [7:0] exp_val);
    logic [LUT2D_COL_IDX_W-1:0] idx;
    begin
      // Use MSB approximation instead of multiplication
      // We want to map 0..255 to 0..59.
      // 60 is approx 64. So take top 6 bits.
      // exp_val[7:2] gives 0..63.
      // Clamp to 59.
      
      logic [5:0] msb_idx;
      msb_idx = exp_val[7:2];
      
      if (msb_idx > LUT2D_COL_IDX_MAX) 
        idx = LUT2D_COL_IDX_MAX[LUT2D_COL_IDX_W-1:0];
      else 
        idx = msb_idx[LUT2D_COL_IDX_W-1:0];
        
      return idx;
    end
  endfunction

  logic [LUT2D_COL_IDX_W-1:0] col0, col1, col2, col3;
  assign col0 = get_col_idx(rs2_lane0); // rs2 holds exp vector here
  assign col1 = get_col_idx(rs2_lane1);
  assign col2 = get_col_idx(rs2_lane2);
  assign col3 = get_col_idx(rs2_lane3);

  logic [7:0] sigm0, sigm1, sigm2, sigm3;

  smx_rom2r_2d #(.ROWS(LUT2D_ROWS), .COLS(LUT2D_COLS), .INIT_HEX("smx_lut2d.hex")) lut2_a (
    .row_a(row_idx), .col_a(col0), .dout_a(sigm0),
    .row_b(row_idx), .col_b(col1), .dout_b(sigm1)
  );
  smx_rom2r_2d #(.ROWS(LUT2D_ROWS), .COLS(LUT2D_COLS), .INIT_HEX("smx_lut2d.hex")) lut2_b (
    .row_a(row_idx), .col_a(col2), .dout_a(sigm2),
    .row_b(row_idx), .col_b(col3), .dout_b(sigm3)
  );

  assign wb_sigm_o = {sigm3, sigm2, sigm1, sigm0};

  // =====================================================================
  // Final Mux
  // =====================================================================
  logic [31:0] result_mux;
  always_comb begin
    unique case (smx_operator_i)
      SMX_CONTX: result_mux = wb_contx_o;
      SMX_ACC:  result_mux = wb_acc_o;
      SMX_EXP:  result_mux = wb_exp_o;
      SMX_SIGM: result_mux = wb_sigm_o;
      default:  result_mux = '0;
    endcase
  end

  generate
    if (REGISTER_FINAL_OUTPUT) begin : gen_reg_output
      always_ff @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i) wb_o <= '0;
        else if (smx_en_i) wb_o <= result_mux;
      end
    end else begin : gen_comb_output
      assign wb_o = result_mux;
    end
  endgenerate

endmodule
