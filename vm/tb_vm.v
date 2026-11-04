// Self-checking testbench for bASICs VM (iverilog only, no Python needed).
//
//   iverilog -g2012 -o tb_vm ../src/project.v ../src/cnn9_core.v ../src/cnn9_mac.v tb_vm.v
//   vvp tb_vm
//
// Drives the pins like the cocotb test: 36 weights (SEL=1), then 64 pixels
// (SEL=0). After each write it waits for BUSY to drop, reading 12 result
// bytes whenever RVALID is high. Expected results are computed with plain
// loops and all 144 are compared for each test. Ends with
// "ALL TESTS PASSED" or an error count.

`timescale 1ns / 1ps
`default_nettype none

module tb_vm;

  localparam WR = 0, SEL = 1, START = 2, RD = 3;
  localparam BUSY = 5, DONE = 6, RVALID = 7;

  reg clk = 1'b0;
  always #12.5 clk = ~clk;  // 40 MHz

  reg        rst_n = 1'b0;
  reg        ena = 1'b1;
  reg  [7:0] ui_in = 8'd0;
  reg  [7:0] uio_in = 8'd0;
  wire [7:0] uo_out, uio_out, uio_oe;

  tt_um_nityashah1811_cnn_accel dut (
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

  integer img    [0:63];   // img[row*8 + col]
  integer wgt    [0:35];   // wgt[tap*4 + filter], tap = fr*3 + fc
  integer exp_out[0:143];  // out[(orow*6 + ocol)*4 + filter]
  integer got    [0:143];
  integer ngot;
  integer errors = 0;
  integer seed = 12345;
  integer i, n;

  task wait_clks(input integer cycles);
    integer c;
    begin
      for (c = 0; c < cycles; c = c + 1) @(posedge clk);
    end
  endtask

  // hold each level 4 clocks (the chip needs at least 2)
  task strobe(input integer bit_num);
    begin
      uio_in[bit_num] = 1'b1;
      wait_clks(4);
      uio_in[bit_num] = 1'b0;
      wait_clks(4);
    end
  endtask

  // read the 12 bytes of one output position into got[]
  task read_position;
    integer f, b;
    reg [23:0] v;
    begin
      for (f = 0; f < 4; f = f + 1) begin
        v = 24'd0;
        for (b = 0; b < 3; b = b + 1) begin
          if (!uio_out[RVALID]) begin
            $display("  RVALID dropped in the middle of a position");
            errors = errors + 1;
          end
          v = v | ({16'd0, uo_out} << (8 * b));
          strobe(RD);
        end
        if (ngot < 144) got[ngot] = {{8{v[23]}}, v};
        ngot = ngot + 1;
      end
    end
  endtask

  // wait until BUSY is low, reading any results that become ready
  task service;
    integer t;
    begin
      t = 0;
      while ((uio_out[BUSY] || uio_out[RVALID]) && t < 3000) begin
        if (uio_out[RVALID]) read_position;
        else begin
          @(posedge clk);
          t = t + 1;
        end
      end
      if (t >= 3000) begin
        $display("  timeout: BUSY stuck high");
        $display("FAILED");
        $finish;
      end
    end
  endtask

  task write_byte(input integer v);
    begin
      ui_in = v;  // keeps the low 8 bits (two's complement)
      strobe(WR);
      service;
    end
  endtask

  task load_weights;
    integer k;
    begin
      uio_in[SEL] = 1'b1;
      wait_clks(4);
      for (k = 0; k < 36; k = k + 1) write_byte(wgt[k]);
      uio_in[SEL] = 1'b0;  // also restarts the pixel count
      wait_clks(4);
    end
  endtask

  task stream_image;
    integer k;
    begin
      for (k = 0; k < 64; k = k + 1) write_byte(img[k]);
    end
  endtask

  task compute_expected;
    integer orow, ocol, f, fr, fc, s;
    begin
      for (orow = 0; orow < 6; orow = orow + 1)
        for (ocol = 0; ocol < 6; ocol = ocol + 1)
          for (f = 0; f < 4; f = f + 1) begin
            s = 0;
            for (fr = 0; fr < 3; fr = fr + 1)
              for (fc = 0; fc < 3; fc = fc + 1)
                s = s + img[(orow + fr) * 8 + (ocol + fc)] * wgt[(fr * 3 + fc) * 4 + f];
            exp_out[(orow * 6 + ocol) * 4 + f] = s;
          end
    end
  endtask

  // load weights + stream image, then compare all 144 results
  task run_and_check(input integer test_id, input integer reload_weights);
    integer r, bad;
    begin
      bad  = 0;
      ngot = 0;
      compute_expected;
      if (reload_weights) load_weights;
      else strobe(START);  // new image, same weights
      stream_image;
      if (ngot != 144) begin
        $display("  test %0d: got %0d results, expected 144", test_id, ngot);
        bad = bad + 1;
      end
      for (r = 0; r < 144 && r < ngot; r = r + 1) begin
        if (got[r] !== exp_out[r]) begin
          if (bad < 5)
            $display("  test %0d: out[%0d] (position %0d, filter %0d) got %0d, expected %0d",
                     test_id, r, r / 4, r % 4, got[r], exp_out[r]);
          bad = bad + 1;
        end
      end
      if (!uio_out[DONE] || uio_out[BUSY] || uio_out[RVALID] || uo_out != 8'd0) begin
        $display("  test %0d: status wrong at end (uio_out=%b uo_out=%h)", test_id, uio_out, uo_out);
        bad = bad + 1;
      end
      if (bad == 0) $display("test %0d: PASS (144/144 results match)", test_id);
      else $display("test %0d: FAIL (%0d problems)", test_id, bad);
      errors = errors + bad;
    end
  endtask

  task random_image;
    integer k, rv;
    begin
      for (k = 0; k < 64; k = k + 1) begin
        rv = $random(seed);
        img[k] = (rv & 255) - 128;
      end
    end
  endtask

  task random_weights;
    integer k, rv;
    begin
      for (k = 0; k < 36; k = k + 1) begin
        rv = $random(seed);
        wgt[k] = (rv & 255) - 128;
      end
    end
  endtask

  initial begin
    $dumpfile("tb_vm.vcd");
    $dumpvars(0, tb_vm);

    wait_clks(10);
    rst_n = 1'b1;
    wait_clks(2);
    if (uio_oe !== 8'b1110_0000 || uio_out !== 8'd0) begin
      $display("bad state after reset: uio_oe=%b uio_out=%b", uio_oe, uio_out);
      errors = errors + 1;
    end

    // test 1: identity (centre tap of filter 0 = 1)
    for (i = 0; i < 64; i = i + 1) img[i] = i;
    for (i = 0; i < 36; i = i + 1) wgt[i] = (i == 16) ? 1 : 0;  // tap 4, filter 0
    run_and_check(1, 1);

    // test 2: largest positive sum (-128 * -128 * 9)
    for (i = 0; i < 64; i = i + 1) img[i] = -128;
    for (i = 0; i < 36; i = i + 1) wgt[i] = -128;
    run_and_check(2, 1);

    // test 3: largest negative sum (127 * -128 * 9), same weights via START
    for (i = 0; i < 64; i = i + 1) img[i] = 127;
    run_and_check(3, 0);

    // tests 4-7: random image and weights
    for (n = 4; n <= 7; n = n + 1) begin
      random_image;
      random_weights;
      run_and_check(n, 1);
    end

    // test 8: new random image, keep test 7's weights
    random_image;
    run_and_check(8, 0);

    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("FAILED: %0d errors", errors);
    $finish;
  end

endmodule
