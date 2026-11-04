![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# CNN Conv Accelerator (Tiny Tapeout, sky130)

A streaming 3x3 convolution accelerator from CNNAccelTeam9, packaged for
[Tiny Tapeout](https://tinytapeout.com): one CNN layer on an 8x8 INT8
image with 4 filters computed in parallel, 6x6x4 INT20 output.

**Team:** Nitya Shah, Kush Shah, Kiran Karthik, Toprak Celikel

Built in the **Basics of ASICs (bASICs)** course at the
[MIT Beaver Works Summer Institute (BWSI)](https://bwsi.mit.edu/bwsi-programs-2/basics-of-asics/).
Thank you to the BWSI instructors and staff, and to the Tiny Tapeout team.

- How it works, pinout and how to drive it: [docs/info.md](docs/info.md)
- Top module: `tt_um_nityashah1811_cnn_accel` ([src/project.v](src/project.v))
- **2x2 tiles, 40 MHz, 52% utilisation, timing met in every corner**
- Final layout and signoff reports: [gds/](gds/)
- A smaller 2-filter 1x2 variant is tag
  [`v1.1-1x2`](https://github.com/nityashah1811/tt-cnn-accel/tree/v1.1-1x2)

![Layout](gds/layout.png)

## Architecture

```
 weights (36 B) ──► 4 x 72-bit rotating weight loops ──► 1 bit/clk ─┐
                                                                    ▼
 pixels (64 B) ──► 19-pixel line buffer ──► 9 fixed window taps ──► 4 bit-serial MACs ──► 12 result bytes
                                                                    (one per filter)
```

- **Line buffer.** The host streams pixels in. The chip keeps the newest
  19 (two rows plus three); when a pixel completes a 3x3 window, the window
  is at fixed buffer taps. No 64-way memory lookup.
- **Rotating weights.** Each filter's 9 weights sit in a 72-bit loop that
  rotates one bit per clock, the exact order the MACs consume them. No
  weight lookup either.
- **Bit-serial MACs.** Each MAC adds the pixel shifted by one weight bit per
  clock (sign bit subtracts): an adder instead of an 8x8 multiplier. 81
  clocks per output position (2 µs at 40 MHz), 4 filters at once.
- **No output memory.** The 4 sums wait in the accumulators until the host
  reads them.
- Only flip-flops: no latches, no memories, no clock gating.
- **Exact:** integer math with 20-bit accumulators that cannot overflow
  (largest sum 9 x 128 x 128 = 147,456), so every result matches the
  software model bit for bit.

## Results

From the Tiny Tapeout GDS action for commit `9072bba`
([run 41757229919](https://github.com/nityashah1811/tt-cnn-accel/actions/runs/41757229919)),
LibreLane on sky130A with `sky130_fd_sc_hd` cells. Files in [gds/](gds/):
`tt_um_nityashah1811_cnn_accel.gds` (final layout), `.lef`, `metrics.csv`,
`synthesis-stats.txt`, `precheck_results.md`, `layout.png`.

**Size and power**

| | |
|---|---|
| Tiles | 2x2 |
| Die | 334.88 x 225.76 µm (75,603 µm²) |
| Cells after synthesis | 2,001 (26,159 µm²), including 585 flip-flops |
| Standard cells after place and route | 4,028 (37,637 µm²) |
| Utilisation | 51.9% |
| Wire length | 64,395 µm |
| Power (typical corner) | 2.6 mW |

**Timing at 40 MHz (25 ns clock)**, worst over min/nom/max parasitics:

| Corner | Setup slack | Hold slack |
|---|---|---|
| Typical (tt, 25 °C, 1.80 V) | +15.12 ns | +0.35 ns |
| Slow (ss, 100 °C, 1.60 V) | +11.02 ns | +0.92 ns |
| Fast (ff, −40 °C, 1.95 V) | +16.82 ns | +0.11 ns |

0 setup and 0 hold violations.

**Signoff**

| Check | Result |
|---|---|
| Tiny Tapeout precheck | 15/15 pass |
| Routing DRC errors | 0 |
| LVS errors | 0 |
| Antenna violations | 0 |
| cocotb tests on RTL | 7/7 pass |
| cocotb tests on the routed gate-level netlist | 7/7 pass |
| FPGA build (ICE40UP5K) | passes, 794/5,280 logic cells (15%) |
| Max slew / fanout / cap warnings | 468 / 39 / 1 (warnings only, not checked by precheck) |

## Verification

| What | Result |
|---|---|
| cocotb (`test/test.py`), RTL and gate-level in CI | 7 tests: identity, extremes (largest +/− sums, all −1, alternating), 4 random images, START with kept weights and mid-image restart, protocol abuse (extra bytes, writes and reads while busy, stray RD), reset mid-image, fastest legal strobes |
| Gate-level stress (synthesized netlist, 64 parallel lanes, random power-up state) | 14 test groups incl. weights written with random gaps, 896 full convolutions, every one of the 144 results checked |
| Mutation testing | 15 deliberately planted bugs (wrong tap, sign step, rotation direction, weights sent to the wrong filter, missing +1, short readout, level vs edge strobe, ...): 15/15 caught |
| VM testbench (`vm/tb_vm.v`, plain iverilog) | 8 tests, self-checking |

## How it got here

| Version | Filters | Synthesized area | Tiles | Slow-corner setup slack |
|---|---|---|---|---|
| Original RTL with byte-wide wrapper, 4 array multipliers, 50 MHz | 4 | 60,771 µm² | 3x2 | −2.21 ns |
| Pixel and weights registered before the multipliers, 40 MHz | 4 | 62,431 µm² | 3x2 | +10.09 ns |
| **Streaming: line buffer, rotating weights, bit-serial MACs** | **4** | **26,159 µm²** | **2x2** | **+11.02 ns** |
| 2 filters, free-running weight loops (tag `v1.1-1x2`) | 2 | 15,716 µm² | 1x2 | +11.15 ns |

The random-access image and weight memories (and the logic to read them)
were 70% of the original design. Streaming removed them.

## Source

| File | What it is |
|------|------------|
| `src/project.v`   | Tiny Tapeout wrapper: input synchronisers, strobe edge detection, pin mapping |
| `src/cnn9_core.v` | weight loops, line buffer, window taps, FSM, result readout |
| `src/cnn9_mac.v`  | bit-serial signed multiply-accumulate |
| `test/test.py`    | cocotb tests (RTL and gate-level) |
| `test/cnn_model.py` | golden model of the convolution |
| `vm/`             | OpenLane config and iverilog testbench for bASICs VM |
| `gds/`            | final layout and signoff reports |

All module names start with `cnn9_` because module names must be unique
across the whole Tiny Tapeout chip.

## Running the tests

On Linux with `iverilog` installed:

```sh
pip install -r test/requirements.txt
cd test
make -B
```

Gate-level test (after hardening, copy the netlist to
`test/gate_level_netlist.v` first):

```sh
make -B GATES=yes
```

Without pip (for example on bASICs VM), see [vm/README.md](vm/README.md).

## Hardening

The GitHub Actions in this repo harden the design on every push. To run
OpenLane locally, see [vm/README.md](vm/README.md) or
<https://tinytapeout.com/guides/local-hardening/>.
