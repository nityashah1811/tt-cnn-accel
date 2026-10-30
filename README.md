![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# CNN Conv Accelerator (Tiny Tapeout, sky130)

A 3x3 convolution accelerator from CNNAccelTeam9, packaged for
[Tiny Tapeout](https://tinytapeout.com): an 8x8 INT8 image, 4 filters, 4
parallel MACs, and 6x6x4 INT20 output read out one byte at a time.

- How it works, pinout and how to drive it: [docs/info.md](docs/info.md)
- Top module: `tt_um_nityashah1811_cnn_accel` ([src/project.v](src/project.v))
- Size: 3x2 tiles, 40 MHz
- Layout and signoff results: [gds/](gds/) (see [Results](#results))

![Layout](gds/layout.png)

## Results

From the Tiny Tapeout GDS action for commit `53a8bab`
([run 40990714001](https://github.com/nityashah1811/tt-cnn-accel/actions/runs/40990714001)),
LibreLane on sky130A, `sky130_fd_sc_hd` cells. Files in [gds/](gds/):
`tt_um_nityashah1811_cnn_accel.gds` (final layout), `.lef`, `metrics.csv`,
`synthesis-stats.txt`, `precheck_results.md`.

**Size**

| | |
|---|---|
| Tiles | 3x2 |
| Die | 508.76 x 225.76 µm (114,858 µm²) |
| Cells after synthesis | 5,122 (62,431 µm²), including 1,029 flip-flops |
| Standard cells after place and route | 8,343 (80,878 µm², incl. buffers and taps) |
| Utilisation | 72.9% |
| Wire length | 192,962 µm |
| Power (typical) | 18.0 mW |

**Timing at 40 MHz (25 ns clock)**, worst over min/nom/max parasitics:

| Corner | Setup slack | Hold slack |
|---|---|---|
| Typical (tt, 25 °C, 1.80 V) | +15.51 ns | +0.34 ns |
| Slow (ss, 100 °C, 1.60 V) | +10.09 ns | +0.93 ns |
| Fast (ff, −40 °C, 1.95 V) | +17.00 ns | +0.12 ns |

0 setup and 0 hold violations. The slow-corner path is about 15 ns, so the
design has room to run faster than 40 MHz.

**Signoff**

| Check | Result |
|---|---|
| Tiny Tapeout precheck | 15/15 pass |
| Routing DRC errors | 0 |
| LVS errors | 0 |
| Antenna violations | 0 |
| RTL tests (cocotb) | 4/4 pass |
| Gate-level test (cocotb on the routed netlist) | pass |
| Max slew / fanout / cap warnings | 2,338 / 78 / 11 (warnings only, not checked by precheck) |

**How timing got here**

| Run | Change | Worst slow-corner setup slack |
|---|---|---|
| 1 | first version, 50 MHz | −2.21 ns |
| 2 | clock lowered to 40 MHz | −2.89 ns |
| 3 | pixel and weights registered before the multipliers, 40 MHz | **+10.09 ns** |

In runs 1 and 2 one path went from the tap counter through the 64:1 image
memory mux straight into the multiplier (about 28 ns in the slow corner), so
slowing the clock did not help. Run 3 splits it with a register.

## Source

| File | What it is |
|------|------------|
| `src/project.v`   | Tiny Tapeout wrapper: synchronisers, load pointer, pin mapping |
| `src/cnn9_core.v` | image/weight memories, address generation, FSM, result readout |
| `src/cnn9_mac.v`  | 2-stage signed multiply-accumulate (after a fetch register stage in the core) |
| `test/test.py`    | cocotb tests (RTL and gate-level) |
| `test/cnn_model.py` | golden model of the convolution |

All module names start with `cnn9_` because module names must be unique
across the whole Tiny Tapeout chip.

### Changes from the original CNNAccelTeam9 RTL

- The 144 x 20-bit output memory (memC) is gone. The core computes one output
  position, then waits for the host to read its 4 results before going on.
  This cut the flip-flop count from about 3,900 to 1,029.
- The wide load/read ports became a byte-wide bus with an auto-incrementing
  load pointer, to fit Tiny Tapeout's 8 in / 8 out / 8 bidirectional pins.
- Patch and tap indices are now separate row/column counters, so there is no
  divide-by-6 or divide-by-3 in hardware.

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

## Hardening locally (LibreLane / OpenLane)

The GitHub Actions in this repo harden the design on every push, so a local
run is optional. To run it locally, follow
<https://tinytapeout.com/guides/local-hardening/>. In short:

```sh
git clone -b ttsky26d https://github.com/TinyTapeout/tt-support-tools tt
pip install -r tt/requirements.txt librelane==3.0.14
export PDK_ROOT=~/ttsetup/pdk PDK=sky130A
./tt/tt_tool.py --create-user-config
./tt/tt_tool.py --harden
./tt/tt_tool.py --print-stats
./tt/tt_tool.py --print-warnings
```

If placement fails or utilisation is very low, change `tiles` in
[info.yaml](info.yaml) (try `2x2` to save cost, `4x2` if 3x2 does not fit).
