![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# CNN Conv Accelerator (Tiny Tapeout, sky130)

A 3x3 convolution accelerator from CNNAccelTeam9, packaged for
[Tiny Tapeout](https://tinytapeout.com): an 8x8 INT8 image, 4 filters, 4
parallel MACs, and 6x6x4 INT20 output read out one byte at a time.

- How it works, pinout and how to drive it: [docs/info.md](docs/info.md)
- Top module: `tt_um_nityashah1811_cnn_accel` ([src/project.v](src/project.v))
- Size: 3x2 tiles, 50 MHz

## Source

| File | What it is |
|------|------------|
| `src/project.v`   | Tiny Tapeout wrapper: synchronisers, load pointer, pin mapping |
| `src/cnn9_core.v` | image/weight memories, address generation, FSM, result readout |
| `src/cnn9_mac.v`  | 2-stage signed multiply-accumulate |
| `test/test.py`    | cocotb tests (RTL and gate-level) |
| `test/cnn_model.py` | golden model of the convolution |

All module names start with `cnn9_` because module names must be unique
across the whole Tiny Tapeout chip.

### Changes from the original CNNAccelTeam9 RTL

- The 144 x 20-bit output memory (memC) is gone. The core computes one output
  position, then waits for the host to read its 4 results before going on.
  This cut the flip-flop count from about 3,900 to about 990.
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
