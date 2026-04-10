// SPDX-License-Identifier: MIT
/*

Authors:
- Eamon Murphy

*/

// Dedicated wrapper for ancillary data testing.
// Exposes flat ports so cocotb can drive/observe without interface syntax.
// Clock is generated in HDL; cocotb only observes it.

module tb_itu_bt_656_to_axis_anc;

// ── Clock and reset ────────────────────────────────────────────────────────────
logic clk;
logic rst;

// 27 MHz: period = 37.037 ns, half-period ≈ 18 ns
initial clk = 1'b0;
always #18 clk = ~clk;

// ── Flat BT.656 input ─────────────────────────────────────────────────────────
logic [7:0] bt656_data;

// ── Flat AXI-Stream video output (observed but not the focus of this bench) ───
logic [7:0] axis_tdata;
logic       axis_tvalid;
logic       axis_tready;
logic       axis_tlast;
logic       axis_tuser;

// ── Flat AXI-Stream ancillary output ──────────────────────────────────────────
logic [7:0] anc_tdata;
logic       anc_tvalid;
logic       anc_tready;
logic       anc_tlast;

// ── Error flag ────────────────────────────────────────────────────────────────
logic err;

// ── Interface instances ───────────────────────────────────────────────────────
itu_bt_656_if #(.DATA_W(8)) bt656_if ();
taxi_axis_if  #(.DATA_W(8)) axis_if  ();
taxi_axis_if  #(.DATA_W(8)) anc_if   ();

assign bt656_if.clk  = clk;
assign bt656_if.data = bt656_data;

assign axis_tdata     = axis_if.tdata;
assign axis_tvalid    = axis_if.tvalid;
assign axis_tlast     = axis_if.tlast;
assign axis_tuser     = axis_if.tuser;
assign axis_if.tready = axis_tready;

assign anc_tdata      = anc_if.tdata;
assign anc_tvalid     = anc_if.tvalid;
assign anc_tlast      = anc_if.tlast;
assign anc_if.tready  = anc_tready;

// ── DUT ───────────────────────────────────────────────────────────────────────
itu_bt_656_to_axis #(
    .DATA_W  (8),
    .ANC_DID (8'hC0),
    .ANC_SDID(8'h01)
) dut (
    .rst      (rst),
    .bt656_snk(bt656_if.snk),
    .axis_src (axis_if.src),
    .anc_src  (anc_if.src),
    .err      (err)
);

endmodule
