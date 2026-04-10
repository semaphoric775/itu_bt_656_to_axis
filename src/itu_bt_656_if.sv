// SPDX-License-Identifier: MIT
/*

Authors:
- Eamon Murphy

*/

interface itu_bt_656_if #(
    // Width of data bus in bits (8 or 10)
    parameter DATA_W = 8
)
();
    logic              clk;
    logic [DATA_W-1:0] data;

    modport src (
        output clk,
        output data
    );

    modport snk (
        input clk,
        input data
    );

    modport mon (
        input clk,
        input data
    );

endinterface
