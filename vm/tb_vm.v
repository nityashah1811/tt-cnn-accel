// Self-checking testbench for bASICs VM (iverilog only, no Python needed).
//
//   iverilog -g2012 -o tb_vm ../src/project.v ../src/cnn9_core.v ../src/cnn9_mac.v tb_vm.v
//   vvp tb_vm
//
// Drives the chip pins the same way the cocotb test does, computes the
// expected convolution with plain loops, and compares all 144 results for
// each test. Ends with "ALL TESTS PASSED" or an error count.

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
  integer exp_out [0:143];  // out[(orow*6 + ocol)*4 + filter]
  integer errors = 0;
  integer seed = 12345;
  integer i, n;

  task wait_clks(input integer cycles);
    integer c;
    begin
      for (c = 0; c < cycles; c = c + 1) @(posedge clk);
    end
  endtask

  // hold each level 4 clocks: the input synchronisers need at least 3
  task strobe(input integer bit_num);
    begin
      uio_in[bit_num] = 1'b1;
      wait_clks(4);
      uio_in[bit_num] = 1'b0;
      wait_clks(4);
    end
  endtask

  // SEL changing resets the load pointer. SEL is parked at 0 between
  // loads, and START also resets the pointer, so the image load starts at 0.
  task load_all;
    integer k;
    begin
      uio_in[SEL] = 1'b0;
      wait_clks(4);
      for (k = 0; k < 64; k = k + 1) begin
        ui_in = img[k];  // keeps the low 8 bits (two's complement)
        strobe(WR);
      end
      uio_in[SEL] = 1'b1;
      wait_clks(4);
      for (k = 0; k < 36; k = k + 1) begin
        ui_in = wgt[k];
        strobe(WR);
      end
      uio_in[SEL] = 1'b0;
      wait_clks(4);
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

  task run_and_check(input integer test_id);
    integer r, b, t, got, bad;
    reg [23:0] v;
    begin
      bad = 0;
      ui_in = 8'd0;
      strobe(START);
      if (!uio_out[BUSY]) begin
        $display("  test %0d: BUSY not set after START", test_id);
        bad = bad + 1;
      end
      for (r = 0; r < 144; r = r + 1) begin
        v = 24'd0;
        for (b = 0; b < 3; b = b + 1) begin
          t = 0;
          while (!uio_out[RVALID] && t < 200) begin
            @(posedge clk);
            t = t + 1;
          end
          if (t >= 200) begin
            $display("  test %0d: timeout waiting for result %0d byte %0d", test_id, r, b);
            $display("FAILED");
            $finish;
          end
          v = v | ({16'd0, uo_out} << (8 * b));
          strobe(RD);
        end
        got = {{8{v[23]}}, v};  // 24-bit sign-extended -> integer
        if (got !== exp_out[r]) begin
          if (bad < 5)
            $display("  test %0d: out[%0d] (patch %0d, filter %0d) got %0d, expected %0d",
                     test_id, r, r / 4, r % 4, got, exp_out[r]);
          bad = bad + 1;
        end
      end
      wait_clks(4);
      if (!uio_out[DONE] || uio_out[BUSY] || uio_out[RVALID] || uo_out != 8'd0) begin
        $display("  test %0d: status wrong at end (uio_out=%b uo_out=%h)", test_id, uio_out, uo_out);
        bad = bad + 1;
      end
      if (bad == 0) $display("test %0d: PASS (144/144 results match)", test_id);
      else $display("test %0d: FAIL (%0d mismatches)", test_id, bad);
      errors = errors + bad;
    end
  endtask

  task random_data;
    integer k, rv;
    begin
      for (k = 0; k < 64; k = k + 1) begin
        rv = $random(seed);
        img[k] = (rv & 255) - 128;
      end
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
    if (uio_oe !== 8'b1110_0000) begin
      $display("uio_oe wrong: %b", uio_oe);
      errors = errors + 1;
    end

    // test 1: identity (centre tap of filter 0 = 1)
    for (i = 0; i < 64; i = i + 1) img[i] = i;
    for (i = 0; i < 36; i = i + 1) wgt[i] = (i == 16) ? 1 : 0;  // tap 4, filter 0
    load_all;
    compute_expected;
    run_and_check(1);

    // test 2: largest positive sum (-128 * -128 * 9)
    for (i = 0; i < 64; i = i + 1) img[i] = -128;
    for (i = 0; i < 36; i = i + 1) wgt[i] = -128;
    load_all;
    compute_expected;
    run_and_check(2);

    // test 3: largest negative sum (127 * -128 * 9)
    for (i = 0; i < 64; i = i + 1) img[i] = 127;
    load_all;
    compute_expected;
    run_and_check(3);

    // tests 4-8: random image and weights
    for (n = 4; n <= 8; n = n + 1) begin
      random_data;
      load_all;
      compute_expected;
      run_and_check(n);
    end

    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("FAILED: %0d errors", errors);
    $finish;
  end

endmodule
