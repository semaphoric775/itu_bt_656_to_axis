"""Basic cocotb testbench for itu_bt_656_to_axis.
Tests NTSC 480p progressive format: 525 total lines, 480 active.
"""

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

# ── NTSC timing constants ──────────────────────────────────────────────────────
NTSC_TOTAL_LINES  = 525
NTSC_ACTIVE_LINES = 480
NTSC_BLANK_LINES  = NTSC_TOTAL_LINES - NTSC_ACTIVE_LINES   # 45

BYTES_PER_LINE    = 1716   # 27 MHz byte clock, 858 pixels × 2 bytes
ACTIVE_SAMPLES    = 1440   # 720 pixels × 2 bytes (Cb Y Cr Y …)
TRS_BYTES         = 4      # FF 00 00 XY
HBLANK_BYTES      = BYTES_PER_LINE - 2 * TRS_BYTES - ACTIVE_SAMPLES  # 268

# ── BT.656 XY byte values for progressive (F=0) ───────────────────────────────
# Bit layout: 1 F V H p3 p2 p1 p0  (protection bits zeroed for simplicity)
XY_EAV_ACTIVE = 0x90   # F=0 V=0 H=1
XY_SAV_ACTIVE = 0x80   # F=0 V=0 H=0
XY_EAV_BLANK  = 0xB0   # F=0 V=1 H=1
XY_SAV_BLANK  = 0xA0   # F=0 V=1 H=0


async def send_trs(clk, data_sig, xy=0x00):
    """Send a 4-byte TRS sequence: FF 00 00 XY."""
    for b in (0xFF, 0x00, 0x00, xy):
        data_sig.value = b
        await RisingEdge(clk)


async def send_line(clk, data_sig, active, line_num=0):
    """
    Send one BT.656 line.
    Line structure: EAV | h-blank | SAV | video/blank data
    """
    xy_eav = XY_EAV_ACTIVE if active else XY_EAV_BLANK
    xy_sav = XY_SAV_ACTIVE if active else XY_SAV_BLANK

    # EAV
    await send_trs(clk, data_sig, xy_eav)

    # Horizontal blanking
    for _ in range(HBLANK_BYTES):
        data_sig.value = 0x10
        await RisingEdge(clk)

    # SAV
    await send_trs(clk, data_sig, xy_sav)

    # Payload
    if active:
        # Cb Y Cr Y pattern; Y encodes line number for easy debugging
        y_val = 0x10 + (line_num & 0x6F)
        pattern = [0x80, y_val, 0x80, y_val]
        for i in range(ACTIVE_SAMPLES):
            data_sig.value = pattern[i % 4]
            await RisingEdge(clk)
    else:
        for _ in range(ACTIVE_SAMPLES):
            data_sig.value = 0x10
            await RisingEdge(clk)


async def send_frame(clk, data_sig):
    """Send one complete NTSC progressive frame."""
    for _ in range(NTSC_BLANK_LINES):
        await send_line(clk, data_sig, active=False)
    for line in range(NTSC_ACTIVE_LINES):
        await send_line(clk, data_sig, active=True, line_num=line)


@cocotb.test()
async def test_basic_frame(dut):
    # Clock is generated in the HDL wrapper; cocotb observes it
    clk      = dut.clk
    data_sig = dut.bt656_data

    # BT.656 is free-running; downstream is always ready
    dut.axis_tready.value = 1
    dut.anc_tready.value  = 1

    # Reset
    dut.rst.value = 1
    data_sig.value = 0x00
    await ClockCycles(clk, 4)
    dut.rst.value = 0

    tuser_seen  = False
    running     = True

    await send_frame(clk, data_sig)

    # Flush the 1-cycle output pipeline
    await ClockCycles(clk, 16)
    running = False
    await RisingEdge(clk)

    dut._log.info(f"PASS: test compiled and ran")
