/*
 * Copyright (c) 2026 Nitya Shah
 * SPDX-License-Identifier: Apache-2.0
 *
 * Streaming 3x3 convolution core: 8x8 INT8 image, 4 INT8 filters,
 * 6x6x4 INT20 output. Fits 2x2 Tiny Tapeout tiles.
 *
 * Weights (load first, 36 bytes, order wgt[tap*4 + filter], tap = fr*3+fc)
 *   Each filter keeps its 9 weights in a 72-bit circular shift register,
 *   tap 0 bit 0 at the head. A written byte is shifted into its filter's
 *   register one bit per clock (8 clocks, BUSY is high meanwhile).
 *   During compute every register rotates one bit per clock, which is
 *   exactly the order the bit-serial MACs consume them, so no weight lookup
 *   is needed. 72 rotations per output position bring them back to the start.
 *
 * Image (stream 64 bytes, row-major)
 *   A 19-pixel line buffer holds the newest pixel and the 18 before it
 *   (two rows plus three). When the pixel at (row, col) arrives with
 *   row >= 2 and col >= 2, the 3x3 window whose bottom-right corner it is
 *   sits at fixed buffer positions, and output (row-2, col-2) is computed.
 *
 * Compute: 9 taps x (1 fetch + 8 weight bits) = 81 clocks per output
 * position, 4 filters in parallel. The 4 sums then wait in the
 * accumulators (RVALID) until the host has read all 12 bytes.
 *
 * Readout per position: filter 0..3, 3 bytes each, low byte first, the
 * 20-bit sum sign-extended to 24 bits. Positions come out row-major.
 */

`default_nettype none

module cnn9_core (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ld_we,      // 1-cycle pulse: write ld_data
    input  wire       ld_sel,     // 0 = image pixel, 1 = weight
    input  wire       ld_ptr_clr, // 1-cycle pulse: restart the byte count, clear DONE
    input  wire [7:0] ld_data,
    input  wire       rd_next,    // 1-cycle pulse: current result byte consumed
    output wire       busy,       // not ready for the next write
    output reg        done,       // last result read; cleared by ld_ptr_clr
    output wire       rvalid,     // rbyte holds a valid result byte
    output reg  [7:0] rbyte
);

  localparam S_IDLE = 2'd0;  // ready for a write
  localparam S_RUN  = 2'd1;  // computing one output position
  localparam S_OUT  = 2'd2;  // host is reading the 12 result bytes

  reg [1:0] state;

  // ------------------------------------------------------------ load control
  reg  [6:0] ptr;       // bytes written since the last clear (saturates)
  reg  [3:0] ser_cnt;   // weight bits still to shift in
  reg  [7:0] ser_byte;  // weight byte being shifted in, LSB first
  reg  [1:0] ser_f;     // which filter it belongs to

  wire ser_busy   = (ser_cnt != 4'd0);
  wire full       = ld_sel ? (ptr >= 7'd36) : ptr[6];
  wire accept     = ld_we && (state == S_IDLE) && !ser_busy && !full;
  wire pix_accept = accept && !ld_sel;
  wire wgt_accept = accept && ld_sel;

  // the pixel being accepted is number ptr: row ptr[5:3], col ptr[2:0]
  wire win_valid  = (ptr[5:3] >= 3'd2) && (ptr[2:0] >= 3'd2);
  wire pix_last   = (ptr[5:0] == 6'd63);

  always @(posedge clk) begin
    if (!rst_n) begin
      ptr      <= 7'd0;
      ser_cnt  <= 4'd0;
      ser_byte <= 8'd0;
      ser_f    <= 2'd0;
    end else begin
      if (ld_ptr_clr) ptr <= 7'd0;
      else if (accept) ptr <= ptr + 7'd1;

      if (wgt_accept) begin
        ser_byte <= ld_data;
        ser_f    <= ptr[1:0];
        ser_cnt  <= 4'd8;
      end else if (ser_busy) begin
        ser_byte <= {1'b0, ser_byte[7:1]};
        ser_cnt  <= ser_cnt - 4'd1;
      end
    end
  end

  // ------------------------------------------------------------ line buffer
  // lb[8*i +: 8] = the pixel written i writes ago (i = 0 is the newest)
  reg [19*8-1:0] lb;
  always @(posedge clk) begin
    if (pix_accept) lb <= {lb[18*8-1:0], ld_data};
  end

  // ---------------------------------------------------------------- counters
  reg [3:0] k;       // tap 0..8 (= fr*3 + fc)
  reg [3:0] step;    // 0 = fetch, 1..8 = weight bit 0..7
  reg       pos_last;  // this output position is the last one (5,5)
  reg [1:0] fsel;    // which filter is being read out
  reg [1:0] bsel;    // which byte of that filter's sum

  wire fetch = (state == S_RUN) && (step == 4'd0);
  wire add   = (state == S_RUN) && (step != 4'd0);
  wire sub   = (step == 4'd8);

  // tap (fr, fc) of the window is (2-fr)*8 + (2-fc) pixels before the newest
  reg [7:0] a_fetch;
  always @(*) begin
    case (k)
      4'd0:    a_fetch = lb[18*8+:8];
      4'd1:    a_fetch = lb[17*8+:8];
      4'd2:    a_fetch = lb[16*8+:8];
      4'd3:    a_fetch = lb[10*8+:8];
      4'd4:    a_fetch = lb[9*8+:8];
      4'd5:    a_fetch = lb[8*8+:8];
      4'd6:    a_fetch = lb[2*8+:8];
      4'd7:    a_fetch = lb[1*8+:8];
      default: a_fetch = lb[0*8+:8];
    endcase
  end

  // pixel shifted left once per weight bit, shared by all 4 MACs
  reg [15:0] a_sh;
  always @(posedge clk) begin
    if (fetch) a_sh <= {{8{a_fetch[7]}}, a_fetch};
    else if (add) a_sh <= {a_sh[14:0], 1'b0};
  end

  wire start_pos = pix_accept && win_valid;

  wire [19:0] acc[0:3];

  genvar g;
  generate
    for (g = 0; g < 4; g = g + 1) begin : g_filt
      localparam [1:0] F = g;
      reg  [71:0] wsr;  // this filter's 9 weights, rotating
      wire        ser_in = ser_busy && (ser_f == F);

      always @(posedge clk) begin
        if (add) wsr <= {wsr[0], wsr[71:1]};
        else if (ser_in) wsr <= {ser_byte[0], wsr[71:1]};
      end

      cnn9_mac u_mac (
          .clk   (clk),
          .rst_n (rst_n),
          .clr   (start_pos),
          .add   (add),
          .sub   (sub),
          .bbit  (wsr[0]),
          .a_term(a_sh),
          .acc   (acc[g])
      );
    end
  endgenerate

  // ------------------------------------------------------------ readout
  wire [19:0] sel_acc = acc[fsel];
  always @(*) begin
    case (bsel)
      2'd0:    rbyte = sel_acc[7:0];
      2'd1:    rbyte = sel_acc[15:8];
      default: rbyte = {{4{sel_acc[19]}}, sel_acc[19:16]};
    endcase
  end

  assign busy   = (state != S_IDLE) || ser_busy;
  assign rvalid = (state == S_OUT);

  wire last_byte = (fsel == 2'd3) && (bsel == 2'd2);

  // ---------------------------------------------------------------- FSM
  always @(posedge clk) begin
    if (!rst_n) begin
      state    <= S_IDLE;
      done     <= 1'b0;
      k        <= 4'd0;
      step     <= 4'd0;
      pos_last <= 1'b0;
      fsel     <= 2'd0;
      bsel     <= 2'd0;
    end else begin
      if (ld_ptr_clr) done <= 1'b0;

      case (state)
        S_IDLE: begin
          if (start_pos) begin
            state    <= S_RUN;
            k        <= 4'd0;
            step     <= 4'd0;
            pos_last <= pix_last;
          end
        end

        S_RUN: begin
          if (step == 4'd8) begin
            step <= 4'd0;
            if (k == 4'd8) begin
              // the last add lands at this edge: sums are final in S_OUT
              k     <= 4'd0;
              fsel  <= 2'd0;
              bsel  <= 2'd0;
              state <= S_OUT;
            end else begin
              k <= k + 4'd1;
            end
          end else begin
            step <= step + 4'd1;
          end
        end

        S_OUT: begin
          if (rd_next) begin
            if (last_byte) begin
              fsel  <= 2'd0;
              bsel  <= 2'd0;
              state <= S_IDLE;
              if (pos_last) done <= 1'b1;
            end else if (bsel == 2'd2) begin
              bsel <= 2'd0;
              fsel <= fsel + 2'd1;
            end else begin
              bsel <= bsel + 2'd1;
            end
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
