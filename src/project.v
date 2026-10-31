/*
 * Copyright (c) 2026 Nitya Shah, Kush Shah, Kiran Karthik, Toprak Celikel
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Tapeout wrapper for the CNNAccelTeam9 streaming 3x3 convolution
 * accelerator (8x8 INT8 image, 2 filters, 6x6x2 INT20 output).
 *
 * Pins
 *   ui_in[7:0]   DATA   byte to write (weight or pixel, INT8)
 *   uio_in[0]    WR     rising edge: write DATA
 *   uio_in[1]    SEL    1 = weights (18 bytes), 0 = image pixels (64 bytes)
 *                       any change of SEL restarts the byte count
 *   uio_in[2]    START  rising edge: start a new image (restart the pixel
 *                       count, clear DONE). Weights are kept.
 *   uio_in[3]    RD     rising edge: current result byte read, show the next
 *   uio_out[5]   BUSY   wait: the chip is not ready for the next write
 *   uio_out[6]   DONE   the last of the 72 results has been read
 *   uio_out[7]   RVALID uo_out holds a valid result byte
 *   uo_out[7:0]  RESULT current result byte (0 when RVALID is low)
 *
 * Host loop: write the 18 weights (SEL=1), then the 64 pixels (SEL=0).
 * After every write wait until BUSY is low; whenever RVALID is high, read
 * 6 result bytes (pulse RD after each) first.
 *
 * All strobes go through 2-flop synchronisers, so the host can be a slow
 * microcontroller on its own clock. Hold DATA steady while WR is high.
 */

`default_nettype none

module tt_um_nityashah1811_cnn_accel (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // ------------------------------------------------- input synchronisers
  // bit 0 WR, 1 SEL, 2 START, 3 RD
  reg [3:0] sync1, sync2, sync3;

  always @(posedge clk) begin
    if (!rst_n) begin
      sync1 <= 4'd0;
      sync2 <= 4'd0;
      sync3 <= 4'd0;
    end else begin
      sync1 <= uio_in[3:0];
      sync2 <= sync1;
      sync3 <= sync2;
    end
  end

  wire wr_pulse    = sync2[0] & ~sync3[0];
  wire sel         = sync2[1];
  wire sel_changed = sync2[1] ^ sync3[1];
  wire start_pulse = sync2[2] & ~sync3[2];
  wire rd_pulse    = sync2[3] & ~sync3[3];

  // ----------------------------------------------------------------- core
  wire       busy, done, rvalid;
  wire [7:0] rbyte;

  cnn9_core u_core (
      .clk       (clk),
      .rst_n     (rst_n),
      .ld_we     (wr_pulse),
      .ld_sel    (sel),
      .ld_ptr_clr(sel_changed | start_pulse),
      .ld_data   (ui_in),
      .rd_next   (rd_pulse),
      .busy      (busy),
      .done      (done),
      .rvalid    (rvalid),
      .rbyte     (rbyte)
  );

  // -------------------------------------------------------------- outputs
  assign uo_out  = rvalid ? rbyte : 8'd0;
  assign uio_out = {rvalid, done, busy, 5'd0};
  assign uio_oe  = 8'b1110_0000;

  wire _unused = &{ena, uio_in[7:4], 1'b0};

endmodule
