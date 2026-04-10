"""Ancillary data testbench for itu_bt_656_to_axis.

Injects ANC packets carrying a counting pattern in the horizontal ancillary
(HANC) space of blanking lines and verifies that the anc_src AXI-Stream
output faithfully reproduces the payload with correct tlast placement.

ANC packet layout (SMPTE 291M / ITU-R BT.656 Annex B, 8-bit):
  00 FF FF  — preamble
  DID       — primary data identifier   (must match ANC_DID  parameter)
  SDID      — secondary data identifier (must match ANC_SDID parameter)
  DC        — user data word count
  UDW[0..DC-1] — user data words  <- forwarded to anc_src
  CS        — checksum (discarded by receiver)
"""

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

# ── NTSC timing constants ──────────────────────────────────────────────────────
NTSC_TOTAL_LINES  = 525
NTSC_ACTIVE_LINES = 480
NTSC_BLANK_LINES  = NTSC_TOTAL_LINES - NTSC_ACTIVE_LINES  # 45

BYTES_PER_LINE = 1716
ACTIVE_SAMPLES = 1440
TRS_BYTES      = 4
HBLANK_BYTES   = BYTES_PER_LINE - 2 * TRS_BYTES - ACTIVE_SAMPLES  # 268

# ── XY byte values for progressive F=0 ────────────────────────────────────────
XY_EAV_ACTIVE = 0x90
XY_SAV_ACTIVE = 0x80
XY_EAV_BLANK  = 0xB0
XY_SAV_BLANK  = 0xA0

# ── ANC IDs — must match tb_itu_bt_656_to_axis_anc.sv DUT parameters ──────────
ANC_DID  = 0xC0
ANC_SDID = 0x01

# ── Counting-pattern test parameters ──────────────────────────────────────────
PACKET_PAYLOAD_LEN = 16   # user data words per packet
NUM_PACKETS        = 3    # packets to inject (one per blanking line)


def make_counting_payload(packet_index: int) -> list[int]:
    """Return a PACKET_PAYLOAD_LEN-byte counting sequence for packet_index.

    Byte values: [base, base+1, ..., base+PACKET_PAYLOAD_LEN-1] mod 256,
    where base = packet_index * PACKET_PAYLOAD_LEN.
    """
    base = (packet_index * PACKET_PAYLOAD_LEN) & 0xFF
    return [(base + i) & 0xFF for i in range(PACKET_PAYLOAD_LEN)]


async def send_trs(clk, data_sig, xy: int):
    for b in (0xFF, 0x00, 0x00, xy):
        data_sig.value = b
        await RisingEdge(clk)


async def send_anc_packet(clk, data_sig, did: int, sdid: int, payload: list[int]):
    """Emit one complete ANC packet onto the BT.656 stream."""
    dc = len(payload)
    cs = (did + sdid + dc + sum(payload)) & 0xFF
    for b in (0x00, 0xFF, 0xFF, did, sdid, dc, *payload, cs):
        data_sig.value = b
        await RisingEdge(clk)


def anc_packet_len(payload_len: int) -> int:
    """Total byte count of one ANC packet: preamble(3) + DID + SDID + DC + payload + CS."""
    return 3 + 1 + 1 + 1 + payload_len + 1


async def send_line(clk, data_sig, active: bool, line_num: int = 0,
                    anc_payloads: list | None = None):
    """Send one BT.656 line.

    anc_payloads: list of byte-lists, each element is a payload for one ANC
    packet injected consecutively at the start of the HANC interval.
    """
    xy_eav = XY_EAV_ACTIVE if active else XY_EAV_BLANK
    xy_sav = XY_SAV_ACTIVE if active else XY_SAV_BLANK

    await send_trs(clk, data_sig, xy_eav)

    # How many HANC bytes consumed by ANC packets?
    anc_consumed = 0
    if anc_payloads:
        for payload in anc_payloads:
            await send_anc_packet(clk, data_sig, ANC_DID, ANC_SDID, payload)
            anc_consumed += anc_packet_len(len(payload))

    for _ in range(HBLANK_BYTES - anc_consumed):
        data_sig.value = 0x10
        await RisingEdge(clk)

    await send_trs(clk, data_sig, xy_sav)

    if active:
        y_val   = 0x10 + (line_num & 0x6F)
        pattern = [0x80, y_val, 0x80, y_val]
        for i in range(ACTIVE_SAMPLES):
            data_sig.value = pattern[i % 4]
            await RisingEdge(clk)
    else:
        for _ in range(ACTIVE_SAMPLES):
            data_sig.value = 0x10
            await RisingEdge(clk)


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_anc_counting_pattern(dut):
    """Inject NUM_PACKETS ANC packets with counting payloads, verify output.

    Each packet carries PACKET_PAYLOAD_LEN bytes whose values count upward
    mod 256.  The test checks:
      - Received payload bytes match the expected counting sequence exactly.
      - tlast is de-asserted on every beat except the final beat of each packet.
      - No extra beats appear outside the injected packets.
    """
    clk      = dut.clk
    data_sig = dut.bt656_data

    dut.axis_tready.value = 1
    dut.anc_tready.value  = 1

    # Reset
    dut.rst.value = 1
    data_sig.value = 0x00
    await ClockCycles(clk, 4)
    dut.rst.value = 0

    # Build expected payloads
    expected_payloads = [make_counting_payload(i) for i in range(NUM_PACKETS)]

    # Collect all anc_src beats
    received_data  = []
    received_tlast = []

    async def collect_anc():
        while True:
            await RisingEdge(clk)
            if dut.anc_tvalid.value:
                received_data.append(int(dut.anc_tdata.value))
                received_tlast.append(int(dut.anc_tlast.value))

    collector = cocotb.start_soon(collect_anc())

    # Send blanking lines: first NUM_PACKETS carry one ANC packet each
    for line in range(NTSC_BLANK_LINES):
        if line < NUM_PACKETS:
            await send_line(clk, data_sig, active=False,
                            anc_payloads=[expected_payloads[line]])
        else:
            await send_line(clk, data_sig, active=False)

    # Active lines — no ANC
    for line in range(NTSC_ACTIVE_LINES):
        await send_line(clk, data_sig, active=True, line_num=line)

    # Flush combinatorial pipeline (ANC output has no register stage)
    await ClockCycles(clk, 4)
    collector.cancel()

    # ── Assertions ────────────────────────────────────────────────────────────
    flat_expected = [b for p in expected_payloads for b in p]
    total_expected = NUM_PACKETS * PACKET_PAYLOAD_LEN

    assert len(received_data) == total_expected, (
        f"Beat count mismatch: expected {total_expected}, got {len(received_data)}"
    )

    assert received_data == flat_expected, (
        f"Payload mismatch:\n  expected {flat_expected}\n  got      {received_data}"
    )

    # tlast must fire exactly once per packet, on the last byte
    tlast_positions = [i for i, tl in enumerate(received_tlast) if tl]
    expected_tlast  = [(p + 1) * PACKET_PAYLOAD_LEN - 1 for p in range(NUM_PACKETS)]

    assert tlast_positions == expected_tlast, (
        f"tlast positions mismatch: expected {expected_tlast}, got {tlast_positions}"
    )

    dut._log.info(
        f"PASS: {NUM_PACKETS} ANC packets × {PACKET_PAYLOAD_LEN} bytes "
        f"received correctly with correct tlast placement"
    )


@cocotb.test()
async def test_anc_did_sdid_filter(dut):
    """Non-matching DID/SDID packets must produce no output on anc_src.

    Sends one packet with a wrong DID and one with the right DID but wrong
    SDID, interleaved with a correct packet.  Only the correct packet should
    appear on anc_src.
    """
    clk      = dut.clk
    data_sig = dut.bt656_data

    dut.axis_tready.value = 1
    dut.anc_tready.value  = 1

    dut.rst.value = 1
    data_sig.value = 0x00
    await ClockCycles(clk, 4)
    dut.rst.value = 0

    wrong_did  = (ANC_DID  ^ 0xFF) & 0xFF
    wrong_sdid = (ANC_SDID ^ 0xFF) & 0xFF
    correct_payload = list(range(8))          # 0x00..0x07

    received_data  = []
    received_tlast = []

    async def collect_anc():
        while True:
            await RisingEdge(clk)
            if dut.anc_tvalid.value:
                received_data.append(int(dut.anc_tdata.value))
                received_tlast.append(int(dut.anc_tlast.value))

    collector = cocotb.start_soon(collect_anc())

    async def send_raw_anc(did, sdid, payload):
        """Helper: send one raw ANC packet with arbitrary DID/SDID."""
        dc = len(payload)
        cs = (did + sdid + dc + sum(payload)) & 0xFF
        for b in (0x00, 0xFF, 0xFF, did, sdid, dc, *payload, cs):
            data_sig.value = b
            await RisingEdge(clk)

    # Line 0: wrong DID → should be filtered
    await send_trs(clk, data_sig, XY_EAV_BLANK)
    await send_raw_anc(wrong_did, ANC_SDID, [0xAA] * 4)
    for _ in range(HBLANK_BYTES - anc_packet_len(4)):
        data_sig.value = 0x10
        await RisingEdge(clk)
    await send_trs(clk, data_sig, XY_SAV_BLANK)
    for _ in range(ACTIVE_SAMPLES):
        data_sig.value = 0x10
        await RisingEdge(clk)

    # Line 1: wrong SDID → should be filtered
    await send_trs(clk, data_sig, XY_EAV_BLANK)
    await send_raw_anc(ANC_DID, wrong_sdid, [0xBB] * 4)
    for _ in range(HBLANK_BYTES - anc_packet_len(4)):
        data_sig.value = 0x10
        await RisingEdge(clk)
    await send_trs(clk, data_sig, XY_SAV_BLANK)
    for _ in range(ACTIVE_SAMPLES):
        data_sig.value = 0x10
        await RisingEdge(clk)

    # Line 2: correct DID + SDID → should pass through
    await send_trs(clk, data_sig, XY_EAV_BLANK)
    await send_anc_packet(clk, data_sig, ANC_DID, ANC_SDID, correct_payload)
    for _ in range(HBLANK_BYTES - anc_packet_len(len(correct_payload))):
        data_sig.value = 0x10
        await RisingEdge(clk)
    await send_trs(clk, data_sig, XY_SAV_BLANK)
    for _ in range(ACTIVE_SAMPLES):
        data_sig.value = 0x10
        await RisingEdge(clk)

    await ClockCycles(clk, 4)
    collector.cancel()

    assert received_data == correct_payload, (
        f"Filter test failed: expected {correct_payload}, got {received_data}"
    )
    assert received_tlast[-1] == 1, "tlast not asserted on final beat"
    assert all(tl == 0 for tl in received_tlast[:-1]), \
        "Spurious tlast in middle of packet"

    dut._log.info(
        f"PASS: non-matching DID/SDID packets filtered; correct packet "
        f"({len(correct_payload)} bytes) forwarded"
    )
