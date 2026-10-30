/*
 * Copyright (c) 2026 Nitya Shah
 * SPDX-License-Identifier: Apache-2.0
 *
 * 3x3 convolution core: 8x8 INT8 image, 4 INT8 filters, 6x6x4 INT20 output.
 *
 *   img[r*8 + c]          image, row-major            (64 x 8 bit)
 *   wgt[tap*4 + filter]   weights, tap = fr*3 + fc    (36 x 8 bit)
 *
 * The four MACs share one image pixel per cycle and each gets its own
 * weight, so one output patch (all 4 filters) takes 9 cycles.
 *
 * Results are NOT stored in an output memory (that would be 144 x 20 bit,
 * most of the area). Instead the core computes one patch, holds the 4 sums
 * in the MAC accumulators, and waits until the host has read all 12 result
 * bytes before it moves on to the next patch.
 *
 * Readout order per patch: filter 0..3, each as 3 bytes, low byte first.
 * The 20-bit sum is sign-extended to 24 bits.
 */

`default_nettype none

module cnn9_core (
    input  wire       clk,
    input  wire       rst_n,
    // load port (only acts while idle)
    input  wire       ld_we,
    input  wire       ld_sel,    // 0 = image, 1 = weights
    input  wire [5:0] ld_addr,
    input  wire [7:0] ld_data,
    // control
    input  wire       start,     // 1-cycle pulse
    input  wire       rd_next,   // 1-cycle pulse: current result byte consumed
    // status / result
    output wire       busy,
    output reg        done,      // stays high until the next start
    output wire       rvalid,    // rbyte holds a valid result byte
    output reg  [7:0] rbyte
);

  localparam ACC_W = 20;

  localparam S_IDLE = 2'd0;  // waiting for start, loads allowed
  localparam S_RUN  = 2'd1;  // feeding 9 taps into the MACs
  localparam S_WAIT = 2'd2;  // letting the MAC pipeline drain
  localparam S_OUT  = 2'd3;  // host is reading the 12 result bytes

  reg [1:0] state;

  // ---------------------------------------------------------------- memories
  reg [7:0] img[0:63];
  reg [7:0] wgt[0:35];

  always @(posedge clk) begin
    if (state == S_IDLE && ld_we) begin
      if (!ld_sel) img[ld_addr] <= ld_data;
      else if (ld_addr < 6'd36) wgt[ld_addr] <= ld_data;
    end
  end

  // ---------------------------------------------------------------- counters
  reg [2:0] orow, ocol;  // output position 0..5
  reg [1:0] tr, tc;      // tap row / col 0..2
  reg [3:0] k;           // tap index 0..8 (= tr*3 + tc)
  reg [1:0] wait_cnt;
  reg [1:0] fsel;        // which filter is being read out
  reg [1:0] bsel;        // which byte of that filter's sum

  // ------------------------------------------------------------- datapath
  wire [2:0] prow = orow + {1'b0, tr};
  wire [2:0] pcol = ocol + {1'b0, tc};
  wire [7:0] a_fetch = img[{prow, pcol}];

  wire issue       = (state == S_RUN);
  wire issue_clear = issue && (k == 4'd0);

  // Fetch stage: register the pixel and the 4 weights before they reach the
  // multipliers. Without it, address add -> 64:1 memory mux -> multiplier is
  // one ~28 ns path in the slow (ss, 100C) corner.
  reg signed [7:0] a_q;
  reg              valid_q, clear_q;

  always @(posedge clk) begin
    a_q <= a_fetch;
    if (!rst_n) begin
      valid_q <= 1'b0;
      clear_q <= 1'b0;
    end else begin
      valid_q <= issue;
      clear_q <= issue_clear;
    end
  end

  wire signed [ACC_W-1:0] acc[0:3];

  genvar g;
  generate
    for (g = 0; g < 4; g = g + 1) begin : g_mac
      localparam [5:0] FILT = g;
      wire [5:0] widx = {k, 2'b00} + FILT;  // tap*4 + filter
      reg signed [7:0] b_q;

      always @(posedge clk) b_q <= wgt[widx];

      cnn9_mac #(
          .DW   (8),
          .ACC_W(ACC_W)
      ) u_mac (
          .clk      (clk),
          .rst_n    (rst_n),
          .a        (a_q),
          .b        (b_q),
          .valid_in (valid_q),
          .clear_acc(clear_q),
          .acc_out  (acc[g])
      );
    end
  endgenerate

  // ------------------------------------------------------------ readout
  wire [ACC_W-1:0] sel_acc = acc[fsel];
  always @(*) begin
    case (bsel)
      2'd0:    rbyte = sel_acc[7:0];
      2'd1:    rbyte = sel_acc[15:8];
      default: rbyte = {{4{sel_acc[19]}}, sel_acc[19:16]};
    endcase
  end

  assign busy   = (state != S_IDLE);
  assign rvalid = (state == S_OUT);

  wire last_tap  = (k == 4'd8);
  wire last_byte = (fsel == 2'd3) && (bsel == 2'd2);
  wire last_patch = (orow == 3'd5) && (ocol == 3'd5);

  // ---------------------------------------------------------------- FSM
  always @(posedge clk) begin
    if (!rst_n) begin
      state    <= S_IDLE;
      done     <= 1'b0;
      orow     <= 3'd0;
      ocol     <= 3'd0;
      tr       <= 2'd0;
      tc       <= 2'd0;
      k        <= 4'd0;
      wait_cnt <= 2'd0;
      fsel     <= 2'd0;
      bsel     <= 2'd0;
    end else begin
      case (state)
        S_IDLE: begin
          if (start) begin
            state <= S_RUN;
            done  <= 1'b0;
            orow  <= 3'd0;
            ocol  <= 3'd0;
            tr    <= 2'd0;
            tc    <= 2'd0;
            k     <= 4'd0;
          end
        end

        S_RUN: begin
          if (last_tap) begin
            k        <= 4'd0;
            tr       <= 2'd0;
            tc       <= 2'd0;
            wait_cnt <= 2'd0;
            state    <= S_WAIT;
          end else begin
            k <= k + 4'd1;
            if (tc == 2'd2) begin
              tc <= 2'd0;
              tr <= tr + 2'd1;
            end else begin
              tc <= tc + 2'd1;
            end
          end
        end

        S_WAIT: begin
          // fetch -> multiply -> accumulate: the last tap's sum is in the
          // accumulators two cycles after S_RUN ends; waiting three cycles
          // leaves one cycle of margin.
          wait_cnt <= wait_cnt + 2'd1;
          if (wait_cnt == 2'd2) begin
            fsel  <= 2'd0;
            bsel  <= 2'd0;
            state <= S_OUT;
          end
        end

        S_OUT: begin
          if (rd_next) begin
            if (last_byte) begin
              fsel <= 2'd0;
              bsel <= 2'd0;
              if (last_patch) begin
                state <= S_IDLE;
                done  <= 1'b1;
              end else begin
                state <= S_RUN;
                if (ocol == 3'd5) begin
                  ocol <= 3'd0;
                  orow <= orow + 3'd1;
                end else begin
                  ocol <= ocol + 3'd1;
                end
              end
            end else if (bsel == 2'd2) begin
              bsel <= 2'd0;
              fsel <= fsel + 2'd1;
            end else begin
              bsel <= bsel + 2'd1;
            end
          end
        end
      endcase
    end
  end

endmodule
