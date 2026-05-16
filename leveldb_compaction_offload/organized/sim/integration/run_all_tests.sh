#!/usr/bin/env bash
# Comprehensive simulation suite for refactored cmpct_* RTL
# Tests real LevelDB SSTables with various scenarios
set -euo pipefail
cd "$(dirname "$0")"

RTL=../../rtl_v2
SIM_COMMON=../common

RTL_FILES=(
    "${RTL}/cmpct_sdpram.v"
    "${RTL}/cmpct_infra.v"
    "${RTL}/cmpct_top.v"
    "${RTL}/cmpct_engine.v"
    "${RTL}/cmpct_sstable_parser_v2.v"
    "${RTL}/cmpct_assembler_v2.v"
    "${RTL}/cmpct_nblock_engine.v"
    "${RTL}/cmpct_pair_chain.v"
    "${RTL}/cmpct_merger.v"
    "${RTL}/cmpct_block_decoder.v"
    "${RTL}/cmpct_block_encoder.v"
    "${RTL}/cmpct_source_pipe.v"
    "${RTL}/cmpct_desc_matcher.v"
)

PASS=0
FAIL=0
SKIP=0
RESULTS=()

compile_and_run() {
    local NAME="$1"
    local TB_V="$2"
    local VVP="$3"
    shift 3
    # Extra fixture generation commands (optional)
    local FIXTURE_CMD="${1:-}"

    echo ""
    echo "================================================================"
    echo "  TEST: ${NAME}"
    echo "================================================================"

    # Generate fixtures if needed
    if [ -n "${FIXTURE_CMD}" ]; then
        echo "  Generating fixtures..."
        eval "${FIXTURE_CMD}" || { echo "  SKIP: fixture generation failed"; SKIP=$((SKIP+1)); RESULTS+=("SKIP  ${NAME} (fixture gen failed)"); return; }
    fi

    # Compile
    echo "  Compiling..."
    if ! iverilog -g2012 -Wno-timescale -I "${RTL}" \
        -o "${VVP}" "${TB_V}" "${SIM_COMMON}/axi_ram_model.v" \
        "${RTL_FILES[@]}" 2>&1 | tail -5; then
        echo "  FAIL: compilation error"
        FAIL=$((FAIL+1))
        RESULTS+=("FAIL  ${NAME} (compile error)")
        return
    fi

    # Run simulation with timeout
    echo "  Running simulation..."
    local OUTPUT
    OUTPUT=$(timeout 300 vvp "${VVP}" 2>&1) || true
    local LAST_LINES
    LAST_LINES=$(echo "$OUTPUT" | tail -20)
    echo "$LAST_LINES"

    if echo "$OUTPUT" | grep -q "PASS:"; then
        PASS=$((PASS+1))
        local PASS_LINE
        PASS_LINE=$(echo "$OUTPUT" | grep "PASS:" | tail -1)
        RESULTS+=("PASS  ${NAME}: ${PASS_LINE}")
    elif echo "$OUTPUT" | grep -q "FAIL"; then
        FAIL=$((FAIL+1))
        local FAIL_LINE
        FAIL_LINE=$(echo "$OUTPUT" | grep "FAIL" | head -1)
        RESULTS+=("FAIL  ${NAME}: ${FAIL_LINE}")
    elif echo "$OUTPUT" | grep -q "TIMEOUT\|WATCHDOG"; then
        FAIL=$((FAIL+1))
        RESULTS+=("FAIL  ${NAME} (timeout)")
    else
        FAIL=$((FAIL+1))
        RESULTS+=("FAIL  ${NAME} (unknown exit)")
    fi
}

echo "============================================================"
echo "  Comprehensive RTL Simulation Suite (refactored cmpct_*)"
echo "  $(date)"
echo "============================================================"

# ──────────────────────────────────────────────────────────────
# Test 1: Standard 2-pair AXI-Lite test (synthetic fixtures)
# ──────────────────────────────────────────────────────────────
compile_and_run \
    "axil_2pair (synthetic, 2 block-pairs)" \
    "tb_sstable_engine_axil_top.v" \
    "tb_all_axil.vvp" \
    "python3 gen_test_sstable.py"

# ──────────────────────────────────────────────────────────────
# Test 2: Single block-pair (synthetic)
# ──────────────────────────────────────────────────────────────
compile_and_run \
    "axil_1blk (synthetic, 1 block-pair)" \
    "tb_sstable_engine_axil_1blk.v" \
    "tb_all_1blk.vvp" \
    "python3 gen_test_sstable_single_block.py"

# ──────────────────────────────────────────────────────────────
# Test 3: Asymmetric (src0=2 blocks, src1=4 blocks)
# ──────────────────────────────────────────────────────────────
compile_and_run \
    "asym_4pair (synthetic, src0=2blk src1=4blk)" \
    "tb_sstable_asym.v" \
    "tb_all_asym.vvp" \
    "python3 gen_test_sstable_asymmetric.py"

# ──────────────────────────────────────────────────────────────
# Test 4: Split mode (auto-split SSTable)
# ──────────────────────────────────────────────────────────────
compile_and_run \
    "split_mode (synthetic, auto-split)" \
    "tb_sstable_engine_split.v" \
    "tb_all_split.vvp" \
    "python3 gen_test_sstable_split.py"

# ──────────────────────────────────────────────────────────────
# Test 5: Heavy duplicates (synthetic, stress dedup)
# ──────────────────────────────────────────────────────────────
compile_and_run \
    "heavy_dup (synthetic, 50% duplicate keys)" \
    "tb_sstable_engine_heavy_dup.v" \
    "tb_all_heavy_dup.vvp" \
    ""

# ──────────────────────────────────────────────────────────────
# Test 6: Large batch (synthetic, 12 blocks, >MAX_BLOCK_PAIRS)
# ──────────────────────────────────────────────────────────────
compile_and_run \
    "large_12blk (synthetic, 12 block-pairs, auto-split)" \
    "tb_sstable_engine_large.v" \
    "tb_all_large.vvp" \
    "python3 gen_test_sstable_large.py"

# ──────────────────────────────────────────────────────────────
# Test 7: Real LevelDB SSTables (12 blocks, 8 dups, auto-split)
# ──────────────────────────────────────────────────────────────
compile_and_run \
    "real_sst (real LevelDB, 12 blocks, 8 dups, auto-split)" \
    "tb_sstable_engine_real.v" \
    "tb_all_real.vvp" \
    ""

# ──────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  SUMMARY"
echo "============================================================"
for R in "${RESULTS[@]}"; do
    echo "  ${R}"
done
echo ""
echo "  PASS: ${PASS}  FAIL: ${FAIL}  SKIP: ${SKIP}  TOTAL: $((PASS+FAIL+SKIP))"
echo "============================================================"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
