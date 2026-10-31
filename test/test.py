# SPDX-FileCopyrightText: © 2026 Nitya Shah
# SPDX-License-Identifier: Apache-2.0
"""cocotb tests for tt_um_nityashah1811_cnn_accel (streaming, 2 filters).

Drives the pins the way the demo-board microcontroller would: write 18
weights (SEL=1), then stream 64 pixels (SEL=0). After every write, wait for
BUSY to drop, reading 6 result bytes whenever RVALID is high. Every result
is checked against the golden model in cnn_model.py. The same tests run on
the RTL and on the gate-level netlist.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from cnn_model import N_OUT, N_WGT, P, bytes_to_result, conv, to_u8

WR, SEL, START, RD = 0, 1, 2, 3
BUSY, DONE, RVALID = 5, 6, 7


class Host:
    def __init__(self, dut, hold=4):
        self.dut = dut
        self.hold = hold  # clocks each strobe level is held (>= 2)
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
        await ClockCycles(self.dut.clk, self.hold)
        self.set_pin(bit, 0)
        await ClockCycles(self.dut.clk, self.hold)

    async def set_sel(self, v):
        self.set_pin(SEL, v)
        await ClockCycles(self.dut.clk, self.hold)

    async def read_position(self):
        """3*P bytes -> P results (filter 0, 1, ...)."""
        raw = []
        for i in range(3 * P):
            assert self.status(RVALID), f"RVALID dropped at byte {i} of a position"
            raw.append(int(self.dut.uo_out.value))
            await self.strobe(RD)
        return [bytes_to_result(*raw[3 * f : 3 * f + 3]) for f in range(P)]

    async def service(self, results, limit=3000):
        """Wait until BUSY is low, collecting any results on the way."""
        for _ in range(limit):
            if self.status(RVALID):
                results.extend(await self.read_position())
                continue
            if not self.status(BUSY):
                return
            await ClockCycles(self.dut.clk, 1)
        raise AssertionError("timed out: BUSY stuck high")

    async def write(self, value, results):
        self.dut.ui_in.value = to_u8(value)
        await self.strobe(WR)
        await self.service(results)

    async def load_weights(self, wgt, results):
        await self.set_sel(1)
        for v in wgt:
            await self.write(v, results)
        await self.set_sel(0)  # also restarts the pixel count

    async def stream_image(self, img, results):
        for v in img:
            await self.write(v, results)

    async def run(self, img, wgt):
        results = []
        await self.load_weights(wgt, results)
        assert results == [], "results appeared before any pixel was sent"
        await self.stream_image(img, results)
        return results


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
    assert int(dut.uio_out.value) == 0, "all status low after reset"
    assert int(dut.uo_out.value) == 0
    return host


def compare(dut, got, img, wgt, name):
    exp = conv(img, wgt)
    assert len(got) == N_OUT, f"{name}: got {len(got)} results, expected {N_OUT}"
    for i, (g, e) in enumerate(zip(got, exp)):
        assert g == e, f"{name}: out[{i}] (position {i // P}, filter {i % P}) got {g}, expected {e}"
    dut._log.info(f"{name}: all {N_OUT} results match")


def check_done(host, name):
    assert host.status(DONE), f"{name}: DONE not set after the last result"
    assert not host.status(BUSY), f"{name}: BUSY still set"
    assert not host.status(RVALID), f"{name}: RVALID still set"
    assert int(host.dut.uo_out.value) == 0, f"{name}: uo_out should be 0 when idle"


def rand_bytes(rng, n):
    return [rng.randint(-128, 127) for _ in range(n)]


@cocotb.test()
async def test_identity(dut):
    """Centre-tap identity on filter 0: output = the inner 6x6 of the image."""
    host = await setup(dut)
    img = list(range(64))
    wgt = [1 if (t == 4 and f == 0) else 0 for t in range(9) for f in range(P)]
    got = await host.run(img, wgt)
    compare(dut, got, img, wgt, "identity")
    check_done(host, "identity")


@cocotb.test()
async def test_extremes(dut):
    """Largest positive and negative sums, sign-bit-only and all -1 weights."""
    host = await setup(dut)
    cases = [
        ("max positive", [-128] * 64, [-128] * N_WGT),
        ("max negative", [127] * 64, [-128] * N_WGT),
        ("-128 x 127", [-128] * 64, [127] * N_WGT),
        ("all -1", [-1] * 64, [-1] * N_WGT),
        ("alternating", [127 if i % 2 else -128 for i in range(64)],
         [-128 if i % 2 else 127 for i in range(N_WGT)]),
    ]
    for name, img, wgt in cases:
        got = await host.run(img, wgt)
        compare(dut, got, img, wgt, name)
        check_done(host, name)


@cocotb.test()
async def test_random(dut):
    """Random images and weights, new weights every time."""
    host = await setup(dut)
    rng = random.Random(0xC0FFEE)
    for n in range(4):
        img, wgt = rand_bytes(rng, 64), rand_bytes(rng, N_WGT)
        got = await host.run(img, wgt)
        compare(dut, got, img, wgt, f"random {n}")
        check_done(host, f"random {n}")


@cocotb.test()
async def test_start_reuses_weights(dut):
    """START begins a new image; weights stay loaded. Also restarts mid-image."""
    host = await setup(dut)
    rng = random.Random(11)
    wgt = rand_bytes(rng, N_WGT)
    img1, img2 = rand_bytes(rng, 64), rand_bytes(rng, 64)
    compare(dut, await host.run(img1, wgt), img1, wgt, "first image")

    await host.strobe(START)
    assert not host.status(DONE), "START should clear DONE"
    got = []
    await host.stream_image(img2[:37], got)  # partial image, thrown away
    await host.strobe(START)
    got = []
    await host.stream_image(img2, got)
    compare(dut, got, img2, wgt, "second image after restart")
    check_done(host, "second image")


@cocotb.test()
async def test_protocol_abuse(dut):
    """Extra bytes, writes/reads while busy, RD with nothing pending."""
    host = await setup(dut)
    rng = random.Random(23)
    wgt, img = rand_bytes(rng, N_WGT), rand_bytes(rng, 64)

    for _ in range(3):
        await host.strobe(RD)  # nothing pending
    assert not host.status(RVALID)

    got = []
    await host.load_weights(wgt + [99, -99, 55, -55], got)  # 4 extra weights ignored
    for v in img:
        dut.ui_in.value = to_u8(v)
        await host.strobe(WR)
        if host.status(BUSY) and not host.status(RVALID):
            dut.ui_in.value = 0x55  # junk write and a stray RD mid-compute
            await host.strobe(WR)
            await host.strobe(RD)
        await host.service(got)
    for _ in range(5):
        await host.write(0x7F, got)  # pixels after the 64th are ignored
    compare(dut, got, img, wgt, "abuse")
    check_done(host, "abuse")


@cocotb.test()
async def test_reset_mid_image(dut):
    """Reset halfway through an image, reload everything, get correct results."""
    host = await setup(dut)
    rng = random.Random(31)
    wgt, img = rand_bytes(rng, N_WGT), rand_bytes(rng, 64)
    got = []
    await host.load_weights(wgt, got)
    await host.stream_image(img[:30], got)
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    assert int(dut.uio_out.value) == 0, "status should be clear after reset"
    wgt2 = rand_bytes(rng, N_WGT)
    got = await host.run(img, wgt2)
    compare(dut, got, img, wgt2, "after reset")


@cocotb.test()
async def test_fast_strobes(dut):
    """Fastest legal host: every strobe level held for only 2 clocks."""
    host = await setup(dut)
    host.hold = 2
    rng = random.Random(47)
    wgt, img = rand_bytes(rng, N_WGT), rand_bytes(rng, 64)
    got = await host.run(img, wgt)
    compare(dut, got, img, wgt, "fast strobes")
    check_done(host, "fast strobes")
