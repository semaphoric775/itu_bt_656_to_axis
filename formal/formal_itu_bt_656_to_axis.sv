// SPDX-License-Identifier: MIT
/*

Authors:
- Eamon Murphy

*/

// SymbiYosys formal wrapper for itu_bt_656_to_axis.
// Interfaces are instantiated internally (not as ports) for Yosys compatibility.

module formal_itu_bt_656_to_axis;

logic       clk;
logic       rst;
logic [7:0] bt656_data;
logic       axis_tready;
logic       err;

// Interface instances
itu_bt_656_if #(.DATA_W(8)) bt656_if ();
taxi_axis_if  #(.DATA_W(8)) axis_if  ();

assign bt656_if.clk   = clk;
assign bt656_if.data  = bt656_data;
assign axis_if.tready = axis_tready;

itu_bt_656_to_axis #(.DATA_W(8)) dut (
    .rst      (rst),
    .bt656_snk(bt656_if.snk),
    .axis_src (axis_if.src),
    .err      (err)
);

// ── Clocking and reset ────────────────────────────────────────────────────────
default clocking @(posedge clk); endclocking
default disable iff (rst);

// ── Assumptions ───────────────────────────────────────────────────────────────
// tready is held high; the BT.656 stream is free-running with no backpressure
am_tready: assume property (axis_tready);

// ── Safety assertions ─────────────────────────────────────────────────────────

// AXIS: tlast is only ever asserted alongside tvalid
ap_tlast_needs_tvalid: assert property (
    axis_if.tlast |-> axis_if.tvalid
);

// AXIS: tuser (SOF) is only ever asserted alongside tvalid
ap_tuser_needs_tvalid: assert property (
    axis_if.tuser |-> axis_if.tvalid
);

// is_sav and is_eav are mutually exclusive — H bit (bit 4) can only be 0 or 1
ap_sav_eav_mutex: assert property (
    !(dut.is_sav && dut.is_eav)
);

// err output is the direct reflection of the ERR state
ap_err_reflects_state: assert property (
    err == (dut.curr_state == dut.ERR)
);

// tvalid is registered from ACT_VID: if tvalid is high, last cycle was ACT_VID
ap_tvalid_from_act_vid: assert property (
    axis_if.tvalid |-> $past(dut.curr_state == dut.ACT_VID)
);

// 0xFF is illegal in active video; the suppress logic must block it from output
ap_no_ff_in_output: assert property (
    axis_if.tvalid |-> axis_if.tdata != 8'hFF
);

// 0x00 is the blanking level and also illegal as active video data after a 0xFF.
// The two-zero bytes of the preamble must also be suppressed.
ap_no_preamble_00_in_output: assert property (
    axis_if.tvalid |-> !($past(dut.shift_reg[7:0] == 8'hFF))
);

// ── Cover goals ───────────────────────────────────────────────────────────────
cp_act_vid: cover property (dut.curr_state == dut.ACT_VID);
cp_eav:     cover property (dut.curr_state == dut.EAV);
cp_err:     cover property (dut.curr_state == dut.ERR);
cp_tvalid:  cover property (axis_if.tvalid);
cp_tlast:   cover property (axis_if.tlast);
cp_tuser:   cover property (axis_if.tuser);

// Cover the ERR→WAIT_SAV recovery path
cp_err_recovery: cover property (
    dut.curr_state == dut.ERR
    ##[1:$] dut.curr_state == dut.WAIT_SAV
);

// Cover two consecutive active lines (EAV → WAIT_SAV → ACT_VID)
cp_two_lines: cover property (
    dut.curr_state == dut.EAV
    ##[1:$] dut.curr_state == dut.ACT_VID
);

endmodule
