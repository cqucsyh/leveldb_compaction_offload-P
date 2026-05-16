#!/bin/bash
#
# test_p9_diag.sh — P9 sporadic error diagnostic
#
# Runs the engine in a tight loop and dumps full register state on error.
# Goal: identify which sub-module (parser/decoder/nblock/encoder) triggers
# the rare failure.
#
set -euo pipefail

H2C_DEV="/dev/xdma0_h2c_0"
C2H_DEV="/dev/xdma0_c2h_0"
USER_DEV="/dev/xdma0_user"
TOOLS_DIR="/home/yh/pp4/dma_ip_drivers/XDMA/linux-kernel/tools"
FIXTURES="/home/yh/pp4/fixtures_gb"
SRC0_FILE="${FIXTURES}/src0_gb.sst"
SRC1_FILE="${FIXTURES}/src1_gb.sst"

SRC0_DDR="0x00000000"
SRC1_DDR="0x00100000"
DST_BASE="0x00200000"
DST_STRIDE="0x00010000"
MID_ADDR="0x00400000"
AXIL_BASE="0x00000000"

NUM_RUNS=5000

DMA_TO="${TOOLS_DIR}/dma_to_device"
REG_RW="${TOOLS_DIR}/reg_rw"

# Register map
R_CTRL="0x0000";     R_STATUS="0x0004"
R_S0BL="0x0008";     R_S0BH="0x000C";     R_S0SZ="0x0010"
R_S1BL="0x0014";     R_S1BH="0x0018";     R_S1SZ="0x001C"
R_DBL="0x0020";      R_DBH="0x0024";      R_DST="0x0028"
R_MBL="0x002C";      R_MBH="0x0030"
R_PAIRS="0x0034";    R_MAXF="0x0038";     R_SSTC="0x003C"
R_D0="0x0040";  R_D1="0x0044"
R_BR0="0x0048"; R_BR1="0x004C"
R_MOB="0x0050"; R_MD="0x0054";  R_MM="0x0058";  R_MDP="0x005C"
R_S5I="0x0060"; R_S5E="0x0064"; R_S5O="0x0068"; R_S5W="0x006C"
R_CYC="0x0070"

rw() {
  local a=$(( $(printf "%d" "$AXIL_BASE") + $(printf "%d" "$1") ))
  "$REG_RW" "$USER_DEV" "$(printf "0x%x" "$a")" w "$2" >/dev/null
}
rr() {
  local a=$(( $(printf "%d" "$AXIL_BASE") + $(printf "%d" "$1") ))
  "$REG_RW" "$USER_DEV" "$(printf "0x%x" "$a")" w | awk '/Read 32-bit value/ {print $NF}' | tail -n1
}
split_lo() { printf "0x%x" $(( $1 & 0xffffffff )); }
split_hi() { printf "0x%x" $(( ($1 >> 32) & 0xffffffff )); }

dump_regs() {
  echo "  ── Full Register Dump ──"
  echo "  STATUS      = $(rr "$R_STATUS")"
  echo "  PAIRS       = $(rr "$R_PAIRS")"
  echo "  D0 (src0)   = $(rr "$R_D0")"
  echo "  D1 (src1)   = $(rr "$R_D1")"
  echo "  BR0 (bytes) = $(rr "$R_BR0")"
  echo "  BR1 (bytes) = $(rr "$R_BR1")"
  echo "  MOB (merge) = $(rr "$R_MOB")"
  echo "  MD  (m_dec) = $(rr "$R_MD")"
  echo "  MM  (m_mrg) = $(rr "$R_MM")"
  echo "  MDP (m_drp) = $(rr "$R_MDP")"
  echo "  S5I (s5 in) = $(rr "$R_S5I")"
  echo "  S5E (s5enc) = $(rr "$R_S5E")"
  echo "  S5O (s5out) = $(rr "$R_S5O")"
  echo "  S5W (s5wr)  = $(rr "$R_S5W")"
  echo "  CYC (perf)  = $(rr "$R_CYC")"
  echo "  SSTC        = $(rr "$R_SSTC")"
  echo "  ────────────────────────"
}

# Pre-flight
for f in "$SRC0_FILE" "$SRC1_FILE"; do
  [[ -f "$f" ]] || { echo "ERROR: $f not found" >&2; exit 1; }
done
SRC0_SIZE="$(stat -c%s "$SRC0_FILE")"
SRC1_SIZE="$(stat -c%s "$SRC1_FILE")"

echo "═══════════════════════════════════════════════════"
echo "  P9 ERROR DIAGNOSTIC — ${NUM_RUNS} iterations"
echo "═══════════════════════════════════════════════════"

# Upload fixtures
echo "[1] Uploading SSTables to DDR..."
"$DMA_TO" -d "$H2C_DEV" -a "$SRC0_DDR" -s "$SRC0_SIZE" -f "$SRC0_FILE" 2>&1 | tail -1
"$DMA_TO" -d "$H2C_DEV" -a "$SRC1_DDR" -s "$SRC1_SIZE" -f "$SRC1_FILE" 2>&1 | tail -1
echo "  Done."

# Program registers (persist)
echo "[2] Programming registers..."
SRC0_DDR_D=$(printf "%d" "$SRC0_DDR")
SRC1_DDR_D=$(printf "%d" "$SRC1_DDR")
DST_BASE_D=$(printf "%d" "$DST_BASE")
MID_ADDR_D=$(printf "%d" "$MID_ADDR")

rw "$R_CTRL" 0x2; sleep 0.01; rw "$R_CTRL" 0x0; sleep 0.01
rw "$R_S0BL" "$(split_lo $SRC0_DDR_D)"
rw "$R_S0BH" "$(split_hi $SRC0_DDR_D)"
rw "$R_S0SZ" "$(printf "0x%x" $SRC0_SIZE)"
rw "$R_S1BL" "$(split_lo $SRC1_DDR_D)"
rw "$R_S1BH" "$(split_hi $SRC1_DDR_D)"
rw "$R_S1SZ" "$(printf "0x%x" $SRC1_SIZE)"
rw "$R_DBL"  "$(split_lo $DST_BASE_D)"
rw "$R_DBH"  "$(split_hi $DST_BASE_D)"
rw "$R_DST"  "$DST_STRIDE"
rw "$R_MBL"  "$(split_lo $MID_ADDR_D)"
rw "$R_MBH"  "$(split_hi $MID_ADDR_D)"
rw "$R_MAXF" "0x0"
echo "  Done."

# Warm-up
echo "[3] Warm-up run..."
rw "$R_CTRL" 0x2; rw "$R_CTRL" 0x0
rw "$R_CTRL" 0x1; rw "$R_CTRL" 0x0
warmup_ok=0
for ((i=0; i<300; i++)); do
  s="$(rr "$R_STATUS")"; s="${s:-0x0}"; sv=$(( s ))
  if (( (sv >> 2) & 1 )); then echo "FAIL: warm-up error"; dump_regs; exit 1; fi
  if (( (sv >> 1) & 1 )); then warmup_ok=1; break; fi
  sleep 0.2
done
[[ "$warmup_ok" -eq 1 ]] || { echo "FAIL: warm-up timeout"; exit 1; }
echo "  Warm-up PASS. cycles=$(rr "$R_CYC")"

# Tight loop
echo ""
echo "[4] Stress loop: ${NUM_RUNS} runs (stopping on first error with full diag)..."
echo ""

PASS=0
FAIL=0
ERR_RUNS=""

for ((run=1; run<=NUM_RUNS; run++)); do
  rw "$R_CTRL" 0x2
  rw "$R_CTRL" 0x0
  rw "$R_CTRL" 0x1
  rw "$R_CTRL" 0x0

  done_ok=0
  for ((p=0; p<500; p++)); do
    s="$(rr "$R_STATUS")"; s="${s:-0x0}"; sv=$(( s ))
    if (( (sv >> 2) & 1 )); then done_ok=2; break; fi
    if (( (sv >> 1) & 1 )); then done_ok=1; break; fi
    sleep 0.01
  done

  if [[ "$done_ok" -eq 2 ]]; then
    FAIL=$(( FAIL + 1 ))
    ERR_RUNS="${ERR_RUNS} ${run}"
    echo "══════════════════════════════════════════════════"
    echo "  ERROR at run ${run} (after ${PASS} consecutive passes)"
    echo "══════════════════════════════════════════════════"
    dump_regs

    # Additional: compare partial progress vs expected
    pairs_v=$(( $(rr "$R_PAIRS") ))
    d0_v=$(( $(rr "$R_D0") ))
    d1_v=$(( $(rr "$R_D1") ))
    md_v=$(( $(rr "$R_MD") ))
    mm_v=$(( $(rr "$R_MM") ))
    s5i_v=$(( $(rr "$R_S5I") ))
    s5e_v=$(( $(rr "$R_S5E") ))
    cyc_v=$(( $(rr "$R_CYC") ))

    echo ""
    echo "  Analysis:"
    echo "    Completed pairs: ${pairs_v}/200"
    echo "    src0_decoded: ${d0_v}/4000  src1_decoded: ${d1_v}/4000"
    echo "    merge_decoded: ${md_v}/8000  merge_merged: ${mm_v}/8000"
    echo "    stage5_input: ${s5i_v}  stage5_encoded: ${s5e_v}"
    echo "    HW cycles at error: ${cyc_v}"

    if (( pairs_v == 200 && d0_v == 4000 && d1_v == 4000 )); then
      echo "    → Decoders completed OK; error likely in encoder/assembler/write path"
    elif (( d0_v < 4000 || d1_v < 4000 )); then
      echo "    → Decoder incomplete: src0=${d0_v} src1=${d1_v} — error in decoder/source_pipe"
      echo "    → Failed around block pair ~$((pairs_v+1))"
    fi
    echo ""

    # Don't stop — accumulate multiple errors for pattern analysis
    if (( FAIL >= 5 )); then
      echo "  Stopping after 5 errors."
      break
    fi
    continue
  fi

  if [[ "$done_ok" -eq 0 ]]; then
    FAIL=$(( FAIL + 1 ))
    echo "  RUN ${run}: TIMEOUT"
    if (( FAIL >= 5 )); then break; fi
    continue
  fi

  PASS=$(( PASS + 1 ))

  if (( run % 500 == 0 )); then
    printf "  [%d/%d] pass=%d fail=%d\n" "$run" "$NUM_RUNS" "$PASS" "$FAIL"
  fi
done

echo ""
echo "═══════════════════════════════════════════════════"
echo "  DIAGNOSTIC SUMMARY"
echo "═══════════════════════════════════════════════════"
echo "  Total runs:  $((PASS + FAIL))"
echo "  Pass:        ${PASS}"
echo "  Fail:        ${FAIL}"
echo "  Error runs:  ${ERR_RUNS:-none}"
echo "  Error rate:  $(python3 -c "p=${PASS};f=${FAIL};print(f'{f/(p+f)*100:.3f}%' if (p+f)>0 else 'N/A')")"
echo "═══════════════════════════════════════════════════"
