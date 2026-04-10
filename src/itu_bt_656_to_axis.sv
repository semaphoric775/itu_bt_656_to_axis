// SPDX-License-Identifier: MIT
/*

Authors:
- Eamon Murphy

*/

module itu_bt_656_to_axis #(
    // Width of BT.656 data bus in bits (8 or 10)
    parameter DATA_W      = 8,
    // Ancillary data primary data identifier (DID) to capture
    parameter logic [7:0] ANC_DID  = 8'h00,
    // Ancillary data secondary data identifier (SDID) to capture
    parameter logic [7:0] ANC_SDID = 8'h00
)
(
    input wire rst,

    itu_bt_656_if.snk  bt656_snk,
    taxi_axis_if.src   axis_src,
    // AXI-Stream output for matched ancillary data user words.
    // BT.656 cannot be back-pressured; tready is ignored.
    // tlast asserts on the last user data word of each ANC packet.
    taxi_axis_if.src   anc_src,
    output wire        err
);

wire clk;

assign clk = bt656_snk.clk;

// TRS preamble shift register — holds the three most recently *registered* bytes.
// Shift direction: new byte enters at [7:0], oldest byte sits at [23:16].
// When byte D is on the input bus, shift_reg = {A, B, C} for stream A B C D.
logic [23:0] shift_reg;

always_ff @(posedge clk) begin
    if (rst) begin
        shift_reg <= '0;
    end else begin
        shift_reg <= {shift_reg[15:0], bt656_snk.data[7:0]};
    end
end

// Combinational TRS detection: preamble in shift reg, XY byte on current input
wire is_preamble = (shift_reg == 24'hFF_00_00);
wire is_sav      = is_preamble && bt656_snk.data[7] && !bt656_snk.data[4];
wire is_eav      = is_preamble && bt656_snk.data[7] &&  bt656_snk.data[4];

// ANC preamble (SMPTE 291M / ITU-R BT.656): 00 FF FF, next byte is DID.
// Gated to non-active-video periods; 0x00/0xFF are illegal in active samples.
wire is_anc_preamble = (shift_reg == 24'h00_FF_FF);

// ---------------------------------------------------------------------------
// Video FSM
// ---------------------------------------------------------------------------

typedef enum logic [1:0] {
    WAIT_SAV,
    ACT_VID,
    EAV,
    ERR
} state_t;

state_t curr_state, next_state;

// State register
always_ff @(posedge clk) begin
    if (rst) begin
        curr_state <= WAIT_SAV;
    end else begin
        curr_state <= next_state;
    end
end

// Next-state logic
always_comb begin
    next_state = curr_state;

    case (curr_state)
        WAIT_SAV: begin
            if (is_sav) next_state = ACT_VID;
            else if (is_eav) next_state = ERR;
        end
        ACT_VID: begin
            if (is_sav) next_state = ERR;
            else if (is_eav) next_state = EAV;
        end
        EAV: begin
            // One-cycle state for the XY byte; return to WAIT_SAV for next line
            next_state = WAIT_SAV;
        end
        ERR: begin
            // Recover to WAIT_SAV on next valid SAV
            if (is_sav) next_state = WAIT_SAV;
        end
        default: next_state = ERR;
    endcase
end

assign err = (curr_state == ERR);

// SOF (tuser) detection for progressive video.
// V bit (bit 5) of the SAV XY byte is 1 during vertical blanking, 0 during
// active video. A new frame starts on the first active SAV after blanking.
logic v_prev_r;
logic sof_r;

always_ff @(posedge clk) begin
    if (rst) begin
        v_prev_r <= 1'b1;
        sof_r    <= 1'b0;
    end else begin
        sof_r <= 1'b0;
        if (is_sav) begin
            v_prev_r <= bt656_snk.data[5];
            if (!bt656_snk.data[5] && v_prev_r)
                sof_r <= 1'b1;
        end
    end
end

// 1-cycle data delay for TRS preamble suppression.
// 0xFF is illegal in active video, so it unambiguously marks preamble start.
// suppress gates valid_d on the cycle the preamble byte was captured.
// The incoming byte acts as a 1-cycle lookahead: tlast fires on the last
// valid beat (data_d) when the next byte (bt656_snk.data) is 0xFF.
// sof_d is delayed by one extra cycle to stay aligned with data_d.
wire suppress = (bt656_snk.data[7:0] == 8'hFF)                              // 0xFF
             || (shift_reg[7:0]  == 8'hFF)                                  // 0x00 after FF
             || (shift_reg[15:8] == 8'hFF && shift_reg[7:0] == 8'h00)      // 0x00 0x00 after FF
             || is_preamble;                                                 // XY byte

logic [DATA_W-1:0] data_d;
logic valid_d;
logic sof_d;

always_ff @(posedge clk) begin
    if (rst) begin
        data_d  <= '0;
        valid_d <= 1'b0;
        sof_d   <= 1'b0;
    end else begin
        data_d  <= bt656_snk.data;
        valid_d <= (curr_state == ACT_VID) && !suppress;
        sof_d   <= sof_r;
    end
end

// AXI-Stream video output
assign axis_src.tdata  = data_d;
assign axis_src.tvalid = valid_d;
assign axis_src.tlast  = valid_d && (bt656_snk.data[7:0] == 8'hFF);
assign axis_src.tuser  = sof_d;
assign axis_src.tkeep  = '1;
assign axis_src.tstrb  = '1;
assign axis_src.tid    = '0;
assign axis_src.tdest  = '0;

// ---------------------------------------------------------------------------
// Ancillary data FSM  (SMPTE 291M / ITU-R BT.656 Annex B)
//
// Packet layout (8-bit):
//   00 FF FF   — ANC preamble
//   DID        — primary data identifier
//   SDID       — secondary data identifier
//   DC         — user data word count (0–255)
//   UDW[0..DC-1] — user data words   ← output on anc_src
//   CS         — checksum (discarded)
//
// The FSM matches only packets where DID == ANC_DID and SDID == ANC_SDID.
// All other packets are silently skipped.
// ---------------------------------------------------------------------------

typedef enum logic [2:0] {
    ANC_IDLE,
    ANC_SDID_ST,   // preamble + DID matched; waiting for SDID byte
    ANC_DC_ST,     // SDID matched; waiting for DC byte
    ANC_DATA_ST,   // streaming DC user data words to anc_src
    ANC_CS_ST      // checksum byte; discarded, then return to IDLE
} anc_state_t;

anc_state_t anc_curr, anc_next;

// Remaining user-data-word counter.
// Loaded from the DC byte on entry to ANC_DATA_ST; decremented each cycle
// while in ANC_DATA_ST; tlast fires when it reaches 1.
logic [7:0] anc_dc_r;

always_ff @(posedge clk) begin
    if (rst) begin
        anc_curr <= ANC_IDLE;
        anc_dc_r <= '0;
    end else begin
        anc_curr <= anc_next;
        if (anc_curr == ANC_DC_ST)
            anc_dc_r <= bt656_snk.data[7:0];       // capture data count
        else if (anc_curr == ANC_DATA_ST)
            anc_dc_r <= anc_dc_r - 1'b1;           // count down
    end
end

always_comb begin
    anc_next = anc_curr;
    case (anc_curr)
        ANC_IDLE: begin
            // is_anc_preamble is high when shift_reg = 00 FF FF, so the
            // current input byte is already the DID.
            if (is_anc_preamble && bt656_snk.data[7:0] == ANC_DID)
                anc_next = ANC_SDID_ST;
        end
        ANC_SDID_ST: begin
            anc_next = (bt656_snk.data[7:0] == ANC_SDID) ? ANC_DC_ST : ANC_IDLE;
        end
        ANC_DC_ST: begin
            // DC == 0 means no user data words; skip straight to IDLE
            // (no checksum expected for empty packets per SMPTE 291M).
            anc_next = (bt656_snk.data[7:0] == 8'h00) ? ANC_IDLE : ANC_DATA_ST;
        end
        ANC_DATA_ST: begin
            if (anc_dc_r == 8'd1) anc_next = ANC_CS_ST;
        end
        ANC_CS_ST: begin
            anc_next = ANC_IDLE;
        end
        default: anc_next = ANC_IDLE;
    endcase
end

// AXI-Stream ancillary output — registered to avoid combinational glitches at
// state-transition boundaries.  The register captures bt656_snk.data and the
// ANC_DATA_ST predicate at the same clock edge, so tdata/tvalid/tlast always
// reflect a coherent (state, data) pair.
// tready is an input but BT.656 cannot be back-pressured; data will be lost
// if the downstream is not always ready.
logic [DATA_W-1:0] anc_data_r;
logic              anc_valid_r;
logic              anc_last_r;

always_ff @(posedge clk) begin
    if (rst) begin
        anc_data_r  <= '0;
        anc_valid_r <= 1'b0;
        anc_last_r  <= 1'b0;
    end else begin
        anc_data_r  <= bt656_snk.data;
        anc_valid_r <= (anc_curr == ANC_DATA_ST);
        anc_last_r  <= (anc_curr == ANC_DATA_ST) && (anc_dc_r == 8'd1);
    end
end

assign anc_src.tdata  = anc_data_r;
assign anc_src.tvalid = anc_valid_r;
assign anc_src.tlast  = anc_last_r;
assign anc_src.tuser  = '0;
assign anc_src.tkeep  = '1;
assign anc_src.tstrb  = '1;
assign anc_src.tid    = '0;
assign anc_src.tdest  = '0;

endmodule
