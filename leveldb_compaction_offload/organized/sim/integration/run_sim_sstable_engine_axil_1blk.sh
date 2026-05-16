#!/usr/bin/env bash
# Run simulation for tb_sstable_engine_axil_1blk (single block pair)
set -euo pipefail
cd "$(dirname "$0")"

# Generate fixtures if needed
python3 gen_test_sstable_single_block.py

RTL=../../rtl_v2
SIM_COMMON=../common

iverilog -g2012 -Wall -Wno-timescale \
    -I "${RTL}" \
    -o tb_sstable_engine_axil_1blk.vvp \
    tb_sstable_engine_axil_1blk.v \
    "${SIM_COMMON}/axi_ram_model.v" \
    "${RTL}/cmpct_sdpram.v" \
    "${RTL}/cmpct_infra.v" \
    "${RTL}/cmpct_top.v" \
    "${RTL}/cmpct_engine.v" \
    "${RTL}/cmpct_sstable_parser_v2.v" \
    "${RTL}/cmpct_assembler_v2.v" \
    "${RTL}/cmpct_nblock_engine.v" \
    "${RTL}/cmpct_pair_chain.v" \
    "${RTL}/cmpct_merger.v" \
    "${RTL}/cmpct_block_decoder.v" \
    "${RTL}/cmpct_block_encoder.v" \
    "${RTL}/cmpct_source_pipe.v" \
    "${RTL}/cmpct_desc_matcher.v" \
    "${RTL}/stream_byte_packer_32.v" \
    "${RTL}/stream_byte_packer_64.v" \
    "${RTL}/byte_skip_adapter_w64.v" \
    2>&1

echo "Compile OK – running simulation..."
vvp tb_sstable_engine_axil_1blk.vvp
