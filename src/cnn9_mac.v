/*
 * Copyright (c) 2026 Nitya Shah
 * SPDX-License-Identifier: Apache-2.0
 *
 * Two-stage signed multiply-accumulate.
 *   stage 1: register a*b (and the valid / clear flags)
 *   stage 2: acc <= clear ? prod : acc + prod
 * acc_out holds its value while valid_in is low, so the top level can read
 * the finished sums straight out of the accumulators.
 */

`default_nettype none

module cnn9_mac #(
    parameter DW    = 8,
    parameter ACC_W = 20
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire signed [DW-1:0]    a,
    input  wire signed [DW-1:0]    b,
    input  wire                    valid_in,
    input  wire                    clear_acc,
    output reg  signed [ACC_W-1:0] acc_out
);

  reg signed [2*DW-1:0] prod;
  reg                   s1_valid;
  reg                   s1_clear;

  always @(posedge clk) begin
    if (!rst_n) begin
      prod     <= {2 * DW{1'b0}};
      s1_valid <= 1'b0;
      s1_clear <= 1'b0;
    end else begin
      prod     <= a * b;
      s1_valid <= valid_in;
      s1_clear <= clear_acc;
    end
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      acc_out <= {ACC_W{1'b0}};
    end else if (s1_valid) begin
      if (s1_clear) acc_out <= {{(ACC_W - 2 * DW) {prod[2*DW-1]}}, prod};
      else acc_out <= acc_out + {{(ACC_W - 2 * DW) {prod[2*DW-1]}}, prod};
    end
  end

endmodule
