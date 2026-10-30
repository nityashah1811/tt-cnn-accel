/*
 * Copyright (c) 2026 Nitya Shah
 * SPDX-License-Identifier: Apache-2.0
 *
 * Bit-serial signed multiply-accumulate: acc += a * b over 8 clocks.
 *
 * Each clock the core supplies one weight bit (LSB first) and a_term =
 * a << j for that bit j. Two's complement: bits 0..6 add a << j, bit 7
 * subtracts a << 7 (sub = 1). One adder instead of an 8x8 multiplier.
 */

`default_nettype none

module cnn9_mac (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clr,     // acc <= 0
    input  wire        add,     // this clock carries a weight bit
    input  wire        sub,     // the weight bit is the sign bit: subtract
    input  wire        bbit,    // current weight bit
    input  wire [15:0] a_term,  // sign-extended a << j
    output reg  [19:0] acc
);

  wire [19:0] term   = {{4{a_term[15]}}, a_term};
  wire [19:0] addend = sub ? ~term : term;  // -x = ~x + 1, the +1 is the carry-in

  always @(posedge clk) begin
    if (!rst_n || clr) acc <= 20'd0;
    else if (add && bbit) acc <= acc + addend + {19'd0, sub};
  end

endmodule
