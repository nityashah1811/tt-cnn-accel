# Running the flow on bASICs VM

These are the same steps as the VM's "Adder From Scratch" guide, set up for
this project. `config.yaml` copies Tiny Tapeout's settings (2x2 tile size, pin
positions, density) so the result should match the GitHub GDS action.

Copy the project out of the shared folder first (shared folders are slow and
can have permission problems with OpenLane's run folders), then run
everything from its `vm/` folder:

```sh
cp -r /media/sf_VM_Shared_Folder/tt-cnn-accel ~/bASICs/work/
cd ~/bASICs/work/tt-cnn-accel/vm
```

## 1. Lint

```sh
verilator --lint-only -Wall -Wno-DECLFILENAME ../src/project.v ../src/cnn9_core.v ../src/cnn9_mac.v --top-module tt_um_nityashah1811_cnn_accel
```

No output means it passed. (`DECLFILENAME` only complains that `project.v`
doesn't match the module name; Tiny Tapeout's template names it that way.)

## 2. Simulate (RTL)

The VM has no `pip`, so use the plain Verilog testbench `tb_vm.v`:

```sh
iverilog -g2012 -o tb_vm ../src/project.v ../src/cnn9_core.v ../src/cnn9_mac.v tb_vm.v
vvp tb_vm
```

It runs 8 tests (identity, both extremes, random images, new images with
the same weights) and ends with
`ALL TESTS PASSED`. Waves go to `tb_vm.vcd` (`gtkwave tb_vm.vcd`).

The cocotb tests in `../test` (run by GitHub Actions) need
`pip install -r requirements.txt` and then `make -B`.

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
| `design__instance__utilization` | must fit the 2x2 tile; see the GitHub number in ../README.md |
| `timing__setup__ws` (worst setup slack) | 0 or more, in every corner (see below) |
| `timing__hold__ws` (worst hold slack) | 0 or more |
| `route__drc_errors` | 0 |
| `antenna__violating__nets` | 0 (a few can be OK, TT precheck decides) |
| LVS errors | 0 |

Check every corner, not just typical (every line should be positive):

```sh
grep -E "timing__(setup|hold)__ws__corner" runs/RUN_*/final/metrics.csv
```

## 5. Gate-level test

Runs `tb_vm.v` against the placed-and-routed netlist instead of the RTL
(replace `RUN_*` with your run folder if you have more than one):

```sh
iverilog -g2012 -DFUNCTIONAL -DUNIT_DELAY=#1 -o tb_vm_gl \
  "$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v" \
  "$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v" \
  runs/RUN_*/final/nl/tt_um_nityashah1811_cnn_accel.nl.v tb_vm.v
vvp tb_vm_gl
```

With pip available, the cocotb version is: copy
`final/pnl/tt_um_nityashah1811_cnn_accel.pnl.v` to `../test/gate_level_netlist.v`,
then `cd ../test && make -B GATES=yes`.

## Other tile sizes

The project targets 2x2. For 3x2, set `DIE_AREA: [0, 0, 508.76, 225.76]` and
`FP_DEF_TEMPLATE: dir::tt_block_3x2_pg.def` in `config.yaml`, and
`tiles: "3x2"` in `../info.yaml`.
