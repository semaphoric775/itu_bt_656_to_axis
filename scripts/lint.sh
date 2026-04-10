#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

verilator --lint-only --sv \
    -Wall \
    "$SRC_DIR/itu_bt_656_if.sv" \
    "$SRC_DIR/taxi_axis_if.sv" \
    "$SRC_DIR/itu_bt_656_to_axis.sv" \
    --top-module itu_bt_656_to_axis
