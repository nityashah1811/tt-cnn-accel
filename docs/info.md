## How it works

This chip runs one layer of a convolutional neural network: a 3x3
convolution of an 8x8 image with 4 filters at once, streaming the image in
one pixel at a time.

- **Weights:** 4 filters of 3x3, signed 8-bit (INT8), sent as
  `wgt[tap*4 + filter]` with `tap = row*3 + col`.
- **Image:** 8x8 pixels, signed 8-bit, sent row by row.
- **Output:** 6x6 positions x 4 filters = 144 signed results, 20 bits each
  (no padding, stride 1).

Inside:

- **Line buffer.** The chip keeps only the newest 19 pixels (two rows plus
  three). When a pixel arrives that completes a 3x3 window (row and column
  both at least 2), the window is at fixed places in the buffer and the
  chip computes that output position for all 4 filters.
- **Rotating weights.** Each filter's 9 weights sit in a 72-bit loop that
  rotates one bit per clock, in exactly the order the MACs use them.
- **Bit-serial MACs.** Four multiply-accumulate units, one per filter,
  share the pixel. Each multiplies by adding the pixel shifted by one weight
  bit per clock (8 clocks per tap, the sign bit subtracts), so there are 4
  adders instead of 4 multipliers. One output position takes 81 clocks.
- **No output memory.** The 4 sums wait in the accumulators until the host
  reads them, then the chip accepts the next pixel.

All control inputs pass through 2-flop synchronisers, so the host can be a
slow microcontroller (such as the demo board's RP2040) on its own clock.

Designed by CNNAccelTeam9.

## How to test

| Pin         | Name   | Dir | Meaning |
|-------------|--------|-----|---------|
| ui[7:0]     | DATA   | in  | byte to write (weight or pixel) |
| uio[0]      | WR     | in  | rising edge: write DATA |
| uio[1]      | SEL    | in  | 1 = weights, 0 = image. Any change restarts the byte count |
| uio[2]      | START  | in  | rising edge: start a new image (keeps the weights, clears DONE) |
| uio[3]      | RD     | in  | rising edge: current result byte read, show the next one |
| uio[5]      | BUSY   | out | wait: not ready for the next write |
| uio[6]      | DONE   | out | the last result of the image has been read |
| uio[7]      | RVALID | out | RESULT holds a valid byte |
| uo[7:0]     | RESULT | out | current result byte (0 when RVALID is low) |

Hold every strobe high and low for at least 2 clocks each, and keep DATA
steady while WR is high.

1. Reset the chip (`rst_n` low, then high) with all inputs at 0.
2. **Weights:** set SEL = 1, then write the 36 weight bytes in the order
   `tap0 f0, tap0 f1, tap0 f2, tap0 f3, tap1 f0, ...`. For each byte: put it
   on DATA, pulse WR, wait until BUSY = 0.
3. **Image:** set SEL = 0, then write the 64 pixels row by row the same way.
   After each pixel, while BUSY = 1: if RVALID = 1, read 12 result bytes
   (read RESULT, pulse RD, 12 times).
4. Results arrive in order output row, output column, then filter 0..3,
   each as 3 bytes, low byte first. The 20-bit value is sign-extended to 24
   bits. The first result appears after pixel 18, the last after pixel 63.
5. After the last result DONE goes high.

For another image with the same weights, pulse START and go to step 3.
After a reset, load the weights again. Extra bytes (more than 36 weights or
64 pixels) and writes while BUSY are ignored.

In Python-like pseudocode:

```python
def write(b):
    DATA = b; pulse(WR)
    while BUSY:
        if RVALID:
            for i in range(12):
                results.append(RESULT); pulse(RD)

SEL = 1; [write(w) for w in weights]
SEL = 0; [write(p) for p in pixels]
```

The cocotb testbench in `test/` checks every result against a Python model
(`test/cnn_model.py`), on the RTL and on the gate-level netlist.

## External hardware

None. Everything can be driven from the Tiny Tapeout demo board's
microcontroller.
