// Copyright (c) 2026 Luca Donato, Tommaso Spagnolo, Cristina Silvano
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

// Silence some Verilator warnings that are benign for this TB
// verilator lint_off PINCONNECTEMPTY
// verilator lint_off UNUSED
// verilator lint_off UNUSEDSIGNAL

module tb_smx_fu_lut_contx 
  import cv32e40p_pkg::*;
;

  // Test parameters
  localparam CLK_PERIOD = 10; // 10ns = 100MHz

  // Testbench signals
  logic        clk;
  logic        rst_n_i;

  // DUT inputs
  logic        smx_en_i;
  smx_opcode_e smx_operator_i;
  localparam smx_opcode_e SMX_CONTX = smx_opcode_e'(3'b000);
  logic [31:0] rs1_value;
  logic [31:0] rs2_value;
  logic [31:0] rd_value;

  // DUT output under test
  logic [31:0] wb_o;

  // Clock generation
  initial begin
    clk = 0;
    forever #((CLK_PERIOD / 2)) clk = ~clk;
  end

  // DUT instance
  smx_fu_lut #(
    // Enable the registered final output path.
    .REGISTER_FINAL_OUTPUT(1'b1) 
  ) DUT (
    .clk(clk),
    .rst_n_i(rst_n_i),
    .smx_en_i(smx_en_i),
    .smx_operator_i(smx_operator_i),
    .rs1_value(rs1_value),
    .rs2_value(rs2_value),
    .rd_value(rd_value),
    .wb_o(wb_o),
    .wb_contx_o(), 
    .wb_acc_o(),
    .wb_exp_o(),
    .wb_sigm_o()
  );

  // Result-check helper
  task automatic check_result(logic signed [7:0] expected_val);
    @(posedge clk);
    $display("[TIME: %0t] Checking output...", $time);
    
    // With REGISTER_FINAL_OUTPUT=1, the result is valid one cycle after the input is applied.
    if ($signed(wb_o[7:0]) != expected_val) begin
      $error("  -> ERROR: Got %d, expected %d", $signed(wb_o[7:0]), expected_val);
    end else begin
      $display("  -> OK: Got %d, expected %d", $signed(wb_o[7:0]), expected_val);
    end
  endtask

  // Test stimulus
  initial begin
    $display("--- [TB_CONTX] Starting testbench ---");
    $dumpfile("tb_contx.vcd");
    $dumpvars(0, tb_smx_fu_lut_contx);

    // 1. Initialization and reset
    rst_n_i      = 1'b0; // Active-low reset assertion
    smx_en_i     = 1'b0;
    smx_operator_i = SMX_NONE;
    rs1_value    = '0;
    rs2_value    = '0;
    rd_value     = '0;

    repeat(2) @(posedge clk);
    rst_n_i = 1'b1; // Release reset
    @(posedge clk);
    
    // Keep the operation mode fixed throughout the test.
    smx_en_i     = 1'b1;
    smx_operator_i = SMX_CONTX;

    // Test 1: all positive values
    $display("[Test 1] Positive values (expected: 80)");
    // rs1 = {40, 30, 20, 10}
    rs1_value = {8'd40, 8'd30, 8'd20, 8'd10};
    // rs2 = {80, 70, 60, 50}
    rs2_value = {8'd80, 8'd70, 8'd60, 8'd50};
    // rd = {9}
    rd_value  = 32'd9;
    check_result(80);

    // Test 2: all negative values
    $display("[Test 2] Negative values (expected: -1)");
    // rs1 = {-10, -20, -30, -40}
    rs1_value = {-8'sd10, -8'sd20, -8'sd30, -8'sd40};
    // rs2 = {-5, -6, -7, -8}
    rs2_value = {-8'sd5, -8'sd6, -8'sd7, -8'sd8};
    // rd = {-1}
    rd_value  = -32'sd1;
    check_result(-1);

    // Test 3: mixed values
    $display("[Test 3] Mixed values (expected: 5)");
    // rs1 = {-10, 5, -30, -40}
    rs1_value = {-8'sd10, 8'sd5, -8'sd30, -8'sd40};
    // rs2 = {-5, -6, 0, -8}
    rs2_value = {-8'sd5, -8'sd6, 8'sd0, -8'sd8};
    // rd = {-1}
    rd_value  = -32'sd1;
    check_result(5);
    
    // Test 4: boundary values (127 and -128)
    $display("[Test 4] Boundary values (expected: 127)");
    // rs1 = {127, -2, -3, -4}
    rs1_value = {8'sd127, -8'sd2, -8'sd3, -8'sd4};
    // rs2 = {-128, -128, -128, -128}
    rs2_value = {-8'sd128, -8'sd128, -8'sd128, -8'sd128};
    // rd = {126}
    rd_value  = 32'd126;
    check_result(127);

    // Test 5: lower boundary value
    $display("[Test 5] Lower boundary value (expected: -128)");
    // rs1 = {-128, -128, -128, -128}
    rs1_value = {-8'sd128, -8'sd128, -8'sd128, -8'sd128};
    // rs2 = {-128, -128, -128, -128}
    rs2_value = {-8'sd128, -8'sd128, -8'sd128, -8'sd128};
    // rd = {-128}
    rd_value  = -32'sd128;
    check_result(-128);

    @(posedge clk);
    smx_en_i = 1'b0;
    $display("--- [TB_CONTX] Testbench completed ---");
    $finish;
  end

endmodule
