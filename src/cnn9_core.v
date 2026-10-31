/*
 * Copyright (c) 2026 Nitya Shah
 * SPDX-License-Identifier: Apache-2.0
 *
 * Streaming 3x3 convolution core: 8x8 INT8 image, 2 INT8 filters,
 * 6x6x2 INT20 output. Fits a 1x2 Tiny Tapeout tile.
 *
 * Phase counter
 *   phase runs 0..71 forever. During compute, phase = tap*8 + bit:
 *   tap = phase[6:3] (0..8), bit = phase[2:0] (weight bit, LSB first).
 *
 * Weights (load first, 18 bytes, order wgt[tap*2 + filter], tap = fr*3+fc)
 *   Each filter keeps its 9 weights in a 72-bit loop that shifts EVERY
 *   clock (no hold logic). The bit at the head is always weight bit
 *   "phase": tap phase[6:3], bit phase[2:0]. A written byte for tap t is
 *   injected into the loop during phases t*8 .. t*8+7, replacing the old
 *   bits in exactly those slots (BUSY until done, at most 80 clocks).
 *
 * Image (stream 64 bytes, row-major)
 *   A 19-pixel line buffer holds the newest pixel and the 18 before it.
 *   When the pixel at (row, col) arrives with row >= 2 and col >= 2, the
 *   3x3 window whose bottom-right corner it is sits at fixed buffer
 *   positions, and output (row-2, col-2) is computed.
 *
 * Compute: wait for phase 0, then 72 clocks (9 taps x 8 weight bits), both
 * filters in parallel with bit-serial MACs. The 2 sums wait in the
 * accumulators (RVALID) until the host has read all 6 bytes.
 *
 * Readout per position: filter 0 then 1, 3 bytes each, low byte first, the
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
  localparam S_WAIT = 2'd1;  // window ready, waiting for phase 0
  localparam S_RUN  = 2'd2;  // computing one output position (72 clocks)
  localparam S_OUT  = 2'd3;  // host is reading the 6 result bytes

  reg [1:0] state;

  // ----------------------------------------------------------- phase 0..71
  reg [6:0] phase;
  wire      phase_end = (phase == 7'd71);
  always @(posedge clk) begin
    if (!rst_n || phase_end) phase <= 7'd0;
    else phase <= phase + 7'd1;
  end
  wire [3:0] tap = phase[6:3];
  wire [2:0] bitn = phase[2:0];

  // ------------------------------------------------------------ load control
  reg  [6:0] ptr;     // bytes written since the last clear (saturates)
  reg  [7:0] wbyte;   // weight byte waiting to be injected
  reg  [3:0] wtap;    // its tap
  reg        wfilt;   // its filter
  reg        wpend;   // waiting for / doing the injection
  reg        winj;    // injecting bits 1..7

  wire full       = ld_sel ? (ptr >= 7'd18) : ptr[6];
  wire accept     = ld_we && (state == S_IDLE) && !wpend && !full;
  wire pix_accept = accept && !ld_sel;
  wire wgt_accept = accept && ld_sel;

  wire inject  = winj || (wpend && (phase == {wtap, 3'b000}));
  wire inj_bit = wbyte[bitn];

  // the pixel being accepted is number ptr: row ptr[5:3], col ptr[2:0]
  wire win_valid = (ptr[5:3] >= 3'd2) && (ptr[2:0] >= 3'd2);
  wire pix_last  = (ptr[5:0] == 6'd63);

  always @(posedge clk) begin
    if (!rst_n) begin
      ptr   <= 7'd0;
      wbyte <= 8'd0;
      wtap  <= 4'd0;
      wfilt <= 1'b0;
      wpend <= 1'b0;
      winj  <= 1'b0;
    end else begin
      if (ld_ptr_clr) ptr <= 7'd0;
      else if (accept) ptr <= ptr + 7'd1;

      if (wgt_accept) begin
        wbyte <= ld_data;
        wtap  <= ptr[4:1];
        wfilt <= ptr[0];
        wpend <= 1'b1;
      end else if (inject && bitn == 3'd7) begin
        wpend <= 1'b0;
      end
      winj <= inject && (bitn != 3'd7);
    end
  end

  // ------------------------------------------------------------ line buffer
  // lb[8*i +: 8] = the pixel written i writes ago (i = 0 is the newest)
  reg [19*8-1:0] lb;
  always @(posedge clk) begin
    if (pix_accept) lb <= {lb[18*8-1:0], ld_data};
  end

  // tap (fr, fc) of the window is (2-fr)*8 + (2-fc) pixels before the newest
  reg [7:0] a_fetch;
  always @(*) begin
    case (tap)
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

  // a << bit: on bit 0 take the fresh pixel, then keep shifting a copy
  wire        computing = (state == S_RUN);
  wire [15:0] a_fresh   = {{8{a_fetch[7]}}, a_fetch};
  reg  [15:0] a_sh;
  wire [15:0] a_term    = (bitn == 3'd0) ? a_fresh : a_sh;
  always @(posedge clk) begin
    a_sh <= {a_term[14:0], 1'b0};
  end

  wire start_pos = pix_accept && win_valid;
  wire sub       = (bitn == 3'd7);

  wire [19:0] acc[0:1];

  genvar g;
  generate
    for (g = 0; g < 2; g = g + 1) begin : g_filt
      reg [71:0] wsr;  // this filter's 9 weights; wsr[0] = weight bit "phase"
      wire       ld_here = inject && (wfilt == g);

      always @(posedge clk) begin
        wsr <= {(ld_here ? inj_bit : wsr[0]), wsr[71:1]};
      end

      cnn9_mac u_mac (
          .clk   (clk),
          .rst_n (rst_n),
          .clr   (start_pos),
          .add   (computing),
          .sub   (sub),
          .bbit  (wsr[0]),
          .a_term(a_term),
          .acc   (acc[g])
      );
    end
  endgenerate

  // ------------------------------------------------------------ readout
  reg        fsel;  // which filter is being read out
  reg  [1:0] bsel;  // which byte of that filter's sum
  wire [19:0] sel_acc = fsel ? acc[1] : acc[0];
  always @(*) begin
    case (bsel)
      2'd0:    rbyte = sel_acc[7:0];
      2'd1:    rbyte = sel_acc[15:8];
      default: rbyte = {{4{sel_acc[19]}}, sel_acc[19:16]};
    endcase
  end

  assign busy   = (state != S_IDLE) || wpend;
  assign rvalid = (state == S_OUT);

  wire last_byte = fsel && (bsel == 2'd2);
  reg  pos_last;  // this output position is the last one (5,5)

  // ---------------------------------------------------------------- FSM
  always @(posedge clk) begin
    if (!rst_n) begin
      state    <= S_IDLE;
      done     <= 1'b0;
      pos_last <= 1'b0;
      fsel     <= 1'b0;
      bsel     <= 2'd0;
    end else begin
      if (ld_ptr_clr) done <= 1'b0;

      case (state)
        S_IDLE: begin
          if (start_pos) begin
            state    <= S_WAIT;
            pos_last <= pix_last;
          end
        end

        S_WAIT: begin
          if (phase_end) state <= S_RUN;  // RUN starts at phase 0
        end

        S_RUN: begin
          if (phase_end) begin
            // the last add lands at this edge: sums are final in S_OUT
            fsel  <= 1'b0;
            bsel  <= 2'd0;
            state <= S_OUT;
          end
        end

        S_OUT: begin
          if (rd_next) begin
            if (last_byte) begin
              fsel  <= 1'b0;
              bsel  <= 2'd0;
              state <= S_IDLE;
              if (pos_last) done <= 1'b1;
            end else if (bsel == 2'd2) begin
              bsel <= 2'd0;
              fsel <= 1'b1;
            end else begin
              bsel <= bsel + 2'd1;
            end
          end
        end
      endcase
    end
  end

endmodule
