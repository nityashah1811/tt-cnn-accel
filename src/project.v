/*
 * Copyright (c) 2026 Nitya Shah
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Tapeout wrapper for the CNNAccelTeam9 3x3 convolution accelerator.
 *
 * Pins
 *   ui_in[7:0]   DATA   byte to load (pixel or weight, INT8)
 *   uio_in[0]    WR     rising edge: write DATA at the load pointer, pointer++
 *   uio_in[1]    SEL    0 = load image (64 bytes), 1 = load weights (36 bytes)
 *                       any change of SEL resets the load pointer to 0
 *   uio_in[2]    START  rising edge: start the convolution
 *   uio_in[3]    RD     rising edge: current result byte consumed, show next
 *   uio_out[5]   BUSY   convolution in progress
 *   uio_out[6]   DONE   all 144 results read out (cleared by START)
 *   uio_out[7]   RVALID uo_out holds a valid result byte
 *   uo_out[7:0]  RESULT current result byte (0 when RVALID is low)
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

  wire [3:0] rise = sync2 & ~sync3;
  wire wr_pulse    = rise[0];
  wire sel         = sync2[1];
  wire sel_changed = sync2[1] ^ sync3[1];
  wire start_pulse = rise[2];
  wire rd_pulse    = rise[3];

  // --------------------------------------------------------- load pointer
  reg  [5:0] ld_ptr;
  wire       busy;

  always @(posedge clk) begin
    if (!rst_n || sel_changed || start_pulse) ld_ptr <= 6'd0;
    else if (wr_pulse && !busy) ld_ptr <= ld_ptr + 6'd1;
  end

  // ----------------------------------------------------------------- core
  wire       done, rvalid;
  wire [7:0] rbyte;

  cnn9_core u_core (
      .clk    (clk),
      .rst_n  (rst_n),
      .ld_we  (wr_pulse),
      .ld_sel (sel),
      .ld_addr(ld_ptr),
      .ld_data(ui_in),
      .start  (start_pulse),
      .rd_next(rd_pulse),
      .busy   (busy),
      .done   (done),
      .rvalid (rvalid),
      .rbyte  (rbyte)
  );

  // -------------------------------------------------------------- outputs
  assign uo_out  = rvalid ? rbyte : 8'd0;
  assign uio_out = {rvalid, done, busy, 5'd0};
  assign uio_oe  = 8'b1110_0000;

  wire _unused = &{ena, uio_in[7:4], 1'b0};

endmodule
