# SPDX-FileCopyrightText: © 2026 Nitya Shah, Kush Shah, Kiran Karthik, Toprak Celikel
# SPDX-License-Identifier: Apache-2.0
"""Golden model for the convolution: same math as CNNAccelTeam9's cnn_sw_timed.py.

  image   img[r*8 + c]          INT8, 8x8
  weights wgt[tap*2 + filter]   INT8, tap = fr*3 + fc
  output  out[patch*2 + filter] INT20, patch = orow*6 + ocol

Written as plain nested loops (no numpy) so it is easy to check by eye and
does not share any indexing tricks with the RTL.
"""

IFM = 8
KS = 3
P = 2
OFM = IFM - KS + 1  # 6
N_IMG = IFM * IFM  # 64
N_WGT = KS * KS * P  # 18
N_OUT = OFM * OFM * P  # 72


def conv(img, wgt):
    """img: 64 signed ints, wgt: 18 signed ints -> 72 signed ints."""
    assert len(img) == N_IMG and len(wgt) == N_WGT
    out = []
    for orow in range(OFM):
        for ocol in range(OFM):
            for f in range(P):
                s = 0
                for fr in range(KS):
                    for fc in range(KS):
                        s += img[(orow + fr) * IFM + (ocol + fc)] * wgt[(fr * KS + fc) * P + f]
                out.append(s)
    return out


def to_u8(v):
    return v & 0xFF


def to_s8(u):
    u &= 0xFF
    return u - 256 if u >= 128 else u


def bytes_to_result(b0, b1, b2):
    """3 readout bytes (low first, 24-bit sign-extended) -> signed int."""
    v = b0 | (b1 << 8) | (b2 << 16)
    return v - (1 << 24) if v & (1 << 23) else v
