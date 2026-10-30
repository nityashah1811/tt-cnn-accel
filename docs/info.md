## How it works

This chip runs one layer of a convolutional neural network: a 3x3 convolution
of an 8x8 image with 4 filters at once.

- **Image:** 8x8 pixels, signed 8-bit (INT8), stored row-major.
- **Weights:** 4 filters of 3x3, signed 8-bit, stored as `wgt[tap*4 + filter]`
  with `tap = row*3 + col`.
- **Output:** 6x6 positions x 4 filters = 144 signed results, 20 bits each
  (no padding, stride 1).

Four multiply-accumulate (MAC) units share one image pixel per clock and each
uses its own filter's weight, so all 4 filters for one output position are
done in 9 clocks. Each MAC has a 2-stage pipeline (multiply, then accumulate).

To save area there is no output memory. After each output position, the chip
holds the 4 sums and waits for the host to read them (12 bytes) before it
computes the next position.

All control inputs pass through 2-flop synchronisers, so the host can be a
slow microcontroller (such as the demo board's RP2040) on its own clock.

Designed by CNNAccelTeam9.

## How to test

Pins:

| Pin         | Name   | Dir | Meaning |
|-------------|--------|-----|---------|
| ui[7:0]     | DATA   | in  | byte to load (pixel or weight) |
| uio[0]      | WR     | in  | rising edge: write DATA at the load pointer, then pointer + 1 |
| uio[1]      | SEL    | in  | 0 = image, 1 = weights. Any change resets the load pointer to 0 |
| uio[2]      | START  | in  | rising edge: start the convolution |
| uio[3]      | RD     | in  | rising edge: current result byte read, show the next one |
| uio[5]      | BUSY   | out | convolution in progress |
| uio[6]      | DONE   | out | all 144 results read (cleared by the next START) |
| uio[7]      | RVALID | out | RESULT holds a valid byte |
| uo[7:0]     | RESULT | out | current result byte (0 when RVALID is low) |

Hold every strobe high and low for at least 3 clocks each, and keep DATA
steady while WR is high.

1. Reset the chip (`rst_n` low, then high) with all inputs at 0.
2. **Load the image:** with SEL = 0, for each of the 64 pixels (row by row)
   put the byte on DATA and pulse WR.
3. **Load the weights:** set SEL = 1 (this resets the pointer), then write the
   36 weight bytes in the order `tap0 f0, tap0 f1, tap0 f2, tap0 f3, tap1 f0, ...`.
4. Set SEL back to 0, then pulse START. BUSY goes high.
5. **Read the results:** 144 results, each sent as 3 bytes, low byte first. The
   20-bit value is sign-extended to 24 bits. For each byte: wait for RVALID = 1,
   read RESULT, pulse RD. Results come out in order output row, output column,
   then filter 0..3.
6. After the last byte DONE goes high and BUSY goes low.

To run again with new weights and the same image, set SEL to 1 (from 0), write
36 new weights, set SEL to 0, and pulse START. Writes are ignored while BUSY.

The cocotb testbench in `test/` checks every result against a Python model
(`test/cnn_model.py`).

## External hardware

None. Everything can be driven from the Tiny Tapeout demo board's
microcontroller.
