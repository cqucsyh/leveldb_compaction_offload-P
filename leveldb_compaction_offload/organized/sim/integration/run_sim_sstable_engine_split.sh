#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$SCRIPT_DIR/../../rtl_v2"
SIM_DIR="$SCRIPT_DIR"

echo "=== Generating split-mode fixtures ==="
python3 "$SIM_DIR/gen_test_sstable_split.py"

echo ""
echo "=== Compiling split-mode testbench ==="
iverilog -g2012 -Wall -Wno-timescale \
    -I"$RTL_DIR" \
    -o "$SIM_DIR/sim_sstable_engine_split" \
    "$SIM_DIR/tb_sstable_engine_split.v" \
    "$RTL_DIR/cmpct_top.v" \
    "$RTL_DIR/cmpct_engine.v" \
    "$RTL_DIR/cmpct_sstable_parser_v2.v" \
    "$RTL_DIR/cmpct_assembler_v2.v" \
    "$RTL_DIR/cmpct_nblock_engine.v" \
    "$RTL_DIR/cmpct_pair_chain.v" \
    "$RTL_DIR/cmpct_merger.v" \
    "$RTL_DIR/cmpct_block_decoder.v" \
    "$RTL_DIR/cmpct_block_encoder.v" \
    "$RTL_DIR/cmpct_source_pipe.v" \
    "$RTL_DIR/cmpct_desc_matcher.v" \
    "$RTL_DIR/stream_byte_packer_32.v" \
    "$RTL_DIR/stream_byte_packer_64.v" \
    "$RTL_DIR/cmpct_infra.v" \
    "$RTL_DIR/cmpct_sdpram.v" \
    "$SIM_DIR/../common/axi_ram_model.v"

echo ""
echo "=== Running split-mode simulation ==="
cd "$SIM_DIR"
vvp -N sim_sstable_engine_split
