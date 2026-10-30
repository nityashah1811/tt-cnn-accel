# Running the flow on bASICs VM

These are the same steps as the VM's "Adder From Scratch" guide, set up for
this project. `config.yaml` copies Tiny Tapeout's settings (3x2 tile size, pin
positions, density) so the result should match the GitHub GDS action.

Run everything from the repo's `vm/` folder.

## 1. Lint

```sh
verilator --lint-only -Wall ../src/project.v ../src/cnn9_core.v ../src/cnn9_mac.v --top-module tt_um_nityashah1811_cnn_accel
```

## 2. Simulate (RTL)

The tests use cocotb, which needs Python packages:

```sh
cd ../test
pip install -r requirements.txt
make -B
cd ../vm
```

A passing run ends with `TESTS=4 PASS=4 FAIL=0`.

## 3. Synthesize (optional quick look)

```sh
mkdir -p runs
yosys -p "read_verilog ../src/project.v ../src/cnn9_core.v ../src/cnn9_mac.v; synth -top tt_um_nityashah1811_cnn_accel; stat"
```

## 4. Run OpenLane

```sh
openlane --manual-pdk --pdk sky130A --pdk-root "$PDK_ROOT" config.yaml
```

A passing run prints `Flow complete`. Then check:

```sh
cd runs/RUN_*/
cat final/metrics.csv | grep -E "utilization|timing__setup__ws|timing__hold__ws|route__drc_errors|antenna__violating|lvs__error"
klayout final/gds/tt_um_nityashah1811_cnn_accel.gds
```

What to look for:

| Metric | Good |
|--------|------|
| `design__instance__utilization` | below about 0.6 (if below about 0.35, try 2x2) |
| `timing__setup__ws` (worst setup slack) | 0 or more |
| `timing__hold__ws` (worst hold slack) | 0 or more |
| `route__drc_errors` | 0 |
| `antenna__violating__nets` | 0 (a few can be OK, TT precheck decides) |
| LVS errors | 0 |

## 5. Gate-level test

```sh
cp runs/RUN_*/final/pnl/tt_um_nityashah1811_cnn_accel.pnl.v ../test/gate_level_netlist.v
cd ../test
make -B GATES=yes
```

## Trying 2x2 tiles

In `config.yaml` set `DIE_AREA: [0, 0, 334.88, 225.76]` and
`FP_DEF_TEMPLATE: dir::tt_block_2x2_pg.def`. If that passes, also change
`tiles: "2x2"` in `../info.yaml` so the GitHub flow uses the same size.
