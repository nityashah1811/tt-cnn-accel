![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# CNN Conv Accelerator

A 3x3 convolution accelerator for [Tiny Tapeout](https://tinytapeout.com)
(sky130): 8x8 INT8 image, 4 filters in parallel, 6x6x4 INT20 output.

**Team:** Nitya Shah, Kush Shah, Kiran Karthik, Toprak Celikel

Built in the Basics of ASICs course at the
[MIT Beaver Works Summer Institute](https://bwsi.mit.edu/bwsi-programs-2/basics-of-asics/).

![Layout](gds/layout.png)

| | |
|---|---|
| Size | 2x2 tiles |
| Clock | 40 MHz |
| Checks | precheck, DRC, LVS, timing and gate-level tests all pass |

How it works and how to use it: [docs/info.md](docs/info.md)
