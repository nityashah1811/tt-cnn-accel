# SPDX-FileCopyrightText: © 2026 Nitya Shah
# SPDX-License-Identifier: Apache-2.0
"""cocotb tests for tt_um_nityashah1811_cnn_accel.

Drives the chip exactly like the demo-board microcontroller would: byte-wide
loads with a WR strobe, a START strobe, then 144 x 3 result bytes read with
an RD strobe. Every result is checked against the golden model in
cnn_model.py. The same tests run on the RTL and on the gate-level netlist.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from cnn_model import N_OUT, bytes_to_result, conv, to_u8

WR, SEL, START, RD = 0, 1, 2, 3
BUSY, DONE, RVALID = 5, 6, 7
HOLD = 4  # cycles each strobe level is held (synchronisers need >= 3)


class Host:
    def __init__(self, dut):
        self.dut = dut
        self.uio = 0

    def set_pin(self, bit, val):
        if val:
            self.uio |= 1 << bit
        else:
            self.uio &= ~(1 << bit)
        self.dut.uio_in.value = self.uio

    def status(self, bit):
        return (int(self.dut.uio_out.value) >> bit) & 1

    async def strobe(self, bit):
        self.set_pin(bit, 1)
        await ClockCycles(self.dut.clk, HOLD)
        self.set_pin(bit, 0)
        await ClockCycles(self.dut.clk, HOLD)

    async def load(self, sel, data):
        """Changing SEL resets the load pointer, so SEL must actually change."""
        self.set_pin(SEL, sel)
        await ClockCycles(self.dut.clk, HOLD)
        for v in data:
            self.dut.ui_in.value = to_u8(v)
            await self.strobe(WR)

    async def park_sel(self):
        """Return SEL to 0 (also resets the pointer, ready for an image load)."""
        self.set_pin(SEL, 0)
        await ClockCycles(self.dut.clk, HOLD)

    async def load_all(self, img, wgt):
        await self.load(0, img)  # pointer is 0 after reset, START or park_sel
        await self.load(1, wgt)
        await self.park_sel()

    async def wait_rvalid(self, timeout=100):
        for _ in range(timeout):
            if self.status(RVALID):
                return
            assert not self.status(DONE), "DONE went high before all results were read"
            await ClockCycles(self.dut.clk, 1)
        raise AssertionError("timed out waiting for RVALID")

    async def run(self):
        self.dut.ui_in.value = 0
        await self.strobe(START)
        assert self.status(BUSY), "BUSY not set after START"
        out = []
        for _ in range(N_OUT):
            raw = []
            for _ in range(3):
                await self.wait_rvalid()
                raw.append(int(self.dut.uo_out.value))
                await self.strobe(RD)
            out.append(bytes_to_result(*raw))
        await ClockCycles(self.dut.clk, HOLD)
        assert self.status(DONE), "DONE not set after the last result"
        assert not self.status(BUSY), "BUSY still set after the last result"
        assert not self.status(RVALID), "RVALID still set after the last result"
        assert int(self.dut.uo_out.value) == 0, "uo_out should be 0 when idle"
        return out


async def setup(dut):
    clock = Clock(dut.clk, 25, unit="ns")  # 40 MHz
    cocotb.start_soon(clock.start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    host = Host(dut)
    assert int(dut.uio_oe.value) == 0b1110_0000, "uio_oe should drive only uio[7:5]"
    assert not host.status(BUSY) and not host.status(DONE)
    return host


def compare(dut, got, img, wgt, name):
    exp = conv(img, wgt)
    for i, (g, e) in enumerate(zip(got, exp)):
        assert g == e, f"{name}: out[{i}] (patch {i // 4}, filter {i % 4}) got {g}, expected {e}"
    dut._log.info(f"{name}: all {N_OUT} results match")


async def check_case(host, img, wgt, name):
    await host.load_all(img, wgt)
    compare(host.dut, await host.run(), img, wgt, name)


@cocotb.test()
async def test_identity(dut):
    """Centre-tap identity on filter 0 (the repo's sample inputs)."""
    host = await setup(dut)
    img = list(range(64))
    wgt = [1 if (t == 4 and f == 0) else 0 for t in range(9) for f in range(4)]
    await check_case(host, img, wgt, "identity")


@cocotb.test()
async def test_extremes(dut):
    """Largest positive and negative sums the 20-bit accumulator must hold."""
    host = await setup(dut)
    await check_case(host, [-128] * 64, [-128] * 36, "max positive")
    await check_case(host, [127] * 64, [-128] * 36, "max negative")


@cocotb.test()
async def test_random(dut):
    """Back-to-back random inferences, then a weights-only reload."""
    host = await setup(dut)
    rng = random.Random(0xC0FFEE)
    img = None
    for n in range(3):
        img = [rng.randint(-128, 127) for _ in range(64)]
        wgt = [rng.randint(-128, 127) for _ in range(36)]
        await check_case(host, img, wgt, f"random run {n}")

    # keep the last image, load new weights only
    wgt = [rng.randint(-128, 127) for _ in range(36)]
    await host.load(1, wgt)
    await host.park_sel()
    compare(dut, await host.run(), img, wgt, "weights-only reload")


@cocotb.test()
async def test_writes_ignored_while_busy(dut):
    """WR strobes during a run must not change the loaded image or weights."""
    host = await setup(dut)
    rng = random.Random(7)
    img = [rng.randint(-128, 127) for _ in range(64)]
    wgt = [rng.randint(-128, 127) for _ in range(36)]
    await host.load_all(img, wgt)
    dut.ui_in.value = 0
    await host.strobe(START)
    for _ in range(5):
        dut.ui_in.value = 0x55
        await host.strobe(WR)
    # the START strobe inside run() is ignored while busy, so it just reads out
    compare(dut, await host.run(), img, wgt, "writes while busy")
