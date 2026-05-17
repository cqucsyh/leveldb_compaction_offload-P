#!/bin/bash
#
# test_cmpct_sstable_engine_gb_xdma.sh
#
# GB-level stress test for the streaming sstable_engine pipeline.
# Uploads large SSTables once to DDR, then runs the engine in a tight loop
# hundreds of times to accumulate GB-level throughput.
#
# Default: 200 blocks × 20 records × ~493KB per run × 2048 runs ≈ 1 GB

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────
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
MID_SIZE="0x00100000"
AXIL_BASE="0x00000000"

TARGET_MB=1024          # 1 GB
TIMEOUT_MS=60000        # per-run timeout
VERIFY_INTERVAL=50      # full verify every N runs
QUIET=0

# ── Register map ──────────────────────────────────────────────────────────
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

# ── Usage ─────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [options]

GB-level stress test for the streaming sstable_engine pipeline.

Options:
  -M <target_MB>   Total data to process in MB (default: ${TARGET_MB})
  -w <h2c_dev>     H2C device       (default: ${H2C_DEV})
  -r <c2h_dev>     C2H device       (default: ${C2H_DEV})
  -u <user_dev>    User BAR         (default: ${USER_DEV})
  -t <tools_dir>   XDMA tools dir   (default: ${TOOLS_DIR})
  -q               Quiet mode (less per-run output)
  -h               Show help
EOF
}

while getopts ":M:w:r:u:t:qh" opt; do
  case "$opt" in
    M) TARGET_MB="$OPTARG" ;;
    w) H2C_DEV="$OPTARG" ;;
    r) C2H_DEV="$OPTARG" ;;
    u) USER_DEV="$OPTARG" ;;
    t) TOOLS_DIR="$OPTARG" ;;
    q) QUIET=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

DMA_TO="${TOOLS_DIR}/dma_to_device"
DMA_FROM="${TOOLS_DIR}/dma_from_device"
REG_RW="${TOOLS_DIR}/reg_rw"

# ── Pre-flight ────────────────────────────────────────────────────────────
for bin in "$DMA_TO" "$DMA_FROM" "$REG_RW"; do
  [[ -x "$bin" ]] || { echo "ERROR: $bin not found" >&2; exit 1; }
done
for dev in "$H2C_DEV" "$C2H_DEV" "$USER_DEV"; do
  [[ -e "$dev" ]] || { echo "ERROR: $dev not found" >&2; exit 1; }
done
for f in "$SRC0_FILE" "$SRC1_FILE"; do
  [[ -f "$f" ]] || { echo "ERROR: $f not found. Build gen_real_sstable_gb first." >&2; exit 1; }
done

SRC0_SIZE="$(stat -c%s "$SRC0_FILE")"
SRC1_SIZE="$(stat -c%s "$SRC1_FILE")"
INPUT_PER_RUN=$(( SRC0_SIZE + SRC1_SIZE ))

# Read expected counters from info file
INFO="${FIXTURES}/gb_sstable_info.txt"
EXP_PAIRS="$(grep '^expected_pairs=' "$INFO" | cut -d= -f2)"
EXP_DEC="$(grep '^expected_decoded=' "$INFO" | cut -d= -f2)"
EXP_MRG="$(grep '^expected_merged=' "$INFO" | cut -d= -f2)"
EXP_DRP="$(grep '^expected_dropped=' "$INFO" | cut -d= -f2)"
EXP_S0="$(grep '^src0_records=' "$INFO" | cut -d= -f2)"
EXP_S1="$(grep '^src1_records=' "$INFO" | cut -d= -f2)"

TOTAL_RUNS=$(( (TARGET_MB * 1024 * 1024 + INPUT_PER_RUN - 1) / INPUT_PER_RUN ))

# ── Helper functions ──────────────────────────────────────────────────────
now_ms() { python3 -c "import time; print(int(time.time()*1000))"; }
split_lo() { printf "0x%x" $(( $1 & 0xffffffff )); }
split_hi() { printf "0x%x" $(( ($1 >> 32) & 0xffffffff )); }
addr_add() { printf "0x%x" $(( $1 + $2 )); }

rw() {
  local a=$(( $(printf "%d" "$AXIL_BASE") + $(printf "%d" "$1") ))
  local ah; ah=$(printf "0x%x" "$a")
  "$REG_RW" "$USER_DEV" "$ah" w "$2" >/dev/null
}

rr() {
  local a=$(( $(printf "%d" "$AXIL_BASE") + $(printf "%d" "$1") ))
  local ah; ah=$(printf "0x%x" "$a")
  "$REG_RW" "$USER_DEV" "$ah" w | awk '/Read 32-bit value/ {print $NF}' | tail -n1
}

# ══════════════════════════════════════════════════════════════════════════
echo "================================================================"
echo "  STREAMING SSTABLE ENGINE — GB STRESS TEST"
echo "================================================================"
echo "  SRC0: ${SRC0_FILE}  (${SRC0_SIZE} bytes)"
echo "  SRC1: ${SRC1_FILE}  (${SRC1_SIZE} bytes)"
echo "  Input per run:  ${INPUT_PER_RUN} bytes ($(python3 -c "print(f'{${INPUT_PER_RUN}/1024:.1f}')") KB)"
echo "  Target:         ${TARGET_MB} MB"
echo "  Runs needed:    ${TOTAL_RUNS}"
echo "  Expected/run:   pairs=${EXP_PAIRS} dec=${EXP_DEC} mrg=${EXP_MRG} drp=${EXP_DRP}"
echo "================================================================"
echo ""

# ── Step 1: Upload SSTables to DDR (once) ─────────────────────────────────
echo "[1/4] Uploading SSTables to DDR..."
"$DMA_TO" -d "$H2C_DEV" -a "$SRC0_DDR" -s "$SRC0_SIZE" -f "$SRC0_FILE" 2>&1 | tail -1
"$DMA_TO" -d "$H2C_DEV" -a "$SRC1_DDR" -s "$SRC1_SIZE" -f "$SRC1_FILE" 2>&1 | tail -1
echo "  Done."

# ── Step 2: Initialize sentinel regions ───────────────────────────────────
echo "[2/4] Initializing DST/MID regions..."
SENTINEL="/tmp/sentinel_gb_$$.bin"
python3 -c "open('${SENTINEL}','wb').write(bytes([0xA5]*$(printf "%d" "$MID_SIZE")))"
"$DMA_TO" -d "$H2C_DEV" -a "$MID_ADDR" -s "$(printf "%d" "$MID_SIZE")" -f "$SENTINEL" 2>&1 | tail -1
rm -f "$SENTINEL"
echo "  Done."

# ── Step 3: Warm-up run with full verification ───────────────────────────
echo "[3/4] Warm-up run with full verification..."

rw "$R_CTRL" 0x2; sleep 0.01; rw "$R_CTRL" 0x0; sleep 0.01

# Program registers (persist across runs)
SRC0_DDR_D=$(printf "%d" "$SRC0_DDR")
SRC1_DDR_D=$(printf "%d" "$SRC1_DDR")
DST_BASE_D=$(printf "%d" "$DST_BASE")
MID_ADDR_D=$(printf "%d" "$MID_ADDR")

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
sleep 0.02

# Start warm-up
rw "$R_CTRL" 0x1; rw "$R_CTRL" 0x0

warmup_ok=0
for ((i=0; i<300; i++)); do
  s="$(rr "$R_STATUS")"; s="${s:-0x0}"
  sv=$(( s ))
  if (( (sv >> 2) & 1 )); then echo "FAIL: warm-up error status=${s}" >&2; exit 1; fi
  if (( (sv >> 1) & 1 )); then warmup_ok=1; break; fi
  sleep 0.2
done
[[ "$warmup_ok" -eq 1 ]] || { echo "FAIL: warm-up timeout" >&2; exit 1; }

# Verify warm-up counters
pairs_hex="$(rr "$R_PAIRS")"
d0_hex="$(rr "$R_D0")"
d1_hex="$(rr "$R_D1")"
md_hex="$(rr "$R_MD")"
mm_hex="$(rr "$R_MM")"
mdp_hex="$(rr "$R_MDP")"
cyc_hex="$(rr "$R_CYC")"
sst_hex="$(rr "$R_SSTC")"

fail=0
chk() { if [[ $(($1)) -ne $(($2)) ]]; then echo "  FAIL: $3: got=$1 exp=$2" >&2; fail=1; else echo "  OK: $3 = $1"; fi; }
chk "$pairs_hex" "$EXP_PAIRS" "block_pairs"
chk "$d0_hex"    "$EXP_S0"    "src0_decoded"
chk "$d1_hex"    "$EXP_S1"    "src1_decoded"
chk "$md_hex"    "$EXP_DEC"   "merge_decoded"
chk "$mm_hex"    "$EXP_MRG"   "merge_merged"
chk "$mdp_hex"   "$EXP_DRP"   "merge_dropped"
echo "  perf_cycles = ${cyc_hex}  sstable_count = ${sst_hex}"

if [[ "$fail" -ne 0 ]]; then echo "FAIL: warm-up verification" >&2; exit 1; fi
echo "  Warm-up PASS."

# ── Step 4: Tight stress loop ─────────────────────────────────────────────
echo ""
echo "[4/4] Starting stress loop: ${TOTAL_RUNS} runs → ${TARGET_MB} MB..."
echo ""

TOTAL_BYTES=0
TOTAL_CYC=0
PASS_COUNT=0
FAIL_COUNT=0

T_ALL_START="$(now_ms)"

for ((run=1; run<=TOTAL_RUNS; run++)); do
  # Clear
  rw "$R_CTRL" 0x2
  rw "$R_CTRL" 0x0

  # Registers persist — just re-start
  rw "$R_CTRL" 0x1
  rw "$R_CTRL" 0x0

  # Poll for done
  done_ok=0
  for ((p=0; p<500; p++)); do
    s="$(rr "$R_STATUS")"; s="${s:-0x0}"
    sv=$(( s ))
    if (( (sv >> 2) & 1 )); then
      echo "  RUN ${run}: ERROR status=${s}" >&2
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      done_ok=2
      break
    fi
    if (( (sv >> 1) & 1 )); then done_ok=1; break; fi
    sleep 0.01
  done

  if [[ "$done_ok" -eq 0 ]]; then
    echo "  RUN ${run}: TIMEOUT" >&2
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    continue
  fi
  if [[ "$done_ok" -eq 2 ]]; then continue; fi

  TOTAL_BYTES=$(( TOTAL_BYTES + INPUT_PER_RUN ))
  PASS_COUNT=$(( PASS_COUNT + 1 ))

  # Read perf cycles
  cyc="$(rr "$R_CYC")"
  TOTAL_CYC=$(( TOTAL_CYC + $(( cyc )) ))

  # Periodic full verification
  if (( run % VERIFY_INTERVAL == 0 )) || (( run == TOTAL_RUNS )); then
    vp="$(rr "$R_PAIRS")"
    vd0="$(rr "$R_D0")"
    vd1="$(rr "$R_D1")"
    vmd="$(rr "$R_MD")"
    vmm="$(rr "$R_MM")"
    vmdp="$(rr "$R_MDP")"

    vfail=0
    if [[ $(($vp)) -ne $((EXP_PAIRS)) ]]; then vfail=1; fi
    if [[ $(($vd0)) -ne $((EXP_S0)) ]]; then vfail=1; fi
    if [[ $(($vd1)) -ne $((EXP_S1)) ]]; then vfail=1; fi
    if [[ $(($vmd)) -ne $((EXP_DEC)) ]]; then vfail=1; fi
    if [[ $(($vmm)) -ne $((EXP_MRG)) ]]; then vfail=1; fi
    if [[ $(($vmdp)) -ne $((EXP_DRP)) ]]; then vfail=1; fi

    if [[ "$vfail" -ne 0 ]]; then
      echo "  RUN ${run}: VERIFY FAIL p=${vp} d0=${vd0} d1=${vd1} md=${vmd} mm=${vmm} dp=${vmdp}" >&2
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      PASS_COUNT=$(( PASS_COUNT - 1 ))
    fi

    T_NOW="$(now_ms)"
    elapsed_s="$(python3 -c "print(f'{(${T_NOW}-${T_ALL_START})/1000:.1f}')")"
    processed_mb="$(python3 -c "print(f'{${TOTAL_BYTES}/1024/1024:.1f}')")"
    avg_cyc=$(( TOTAL_CYC / (PASS_COUNT > 0 ? PASS_COUNT : 1) ))

    if [[ "$QUIET" -eq 0 ]]; then
      printf "  [%5d/%d]  %s MB  %ss  avg_cyc=%d  pass=%d fail=%d\n" \
             "$run" "$TOTAL_RUNS" "$processed_mb" "$elapsed_s" "$avg_cyc" "$PASS_COUNT" "$FAIL_COUNT"
    fi
  fi
done

T_ALL_END="$(now_ms)"
WALL_MS=$(( T_ALL_END - T_ALL_START ))

# ── Summary ───────────────────────────────────────────────────────────────
PROCESSED_MB="$(python3 -c "print(f'{${TOTAL_BYTES}/1024/1024:.2f}')")"
WALL_S="$(python3 -c "print(f'{${WALL_MS}/1000:.2f}')")"
HOST_THRU="$(python3 -c "print(f'{${TOTAL_BYTES}/1024/1024/(${WALL_MS}/1000):.2f}')" 2>/dev/null || echo "N/A")"
AVG_CYC=$(( TOTAL_CYC / (PASS_COUNT > 0 ? PASS_COUNT : 1) ))
HW_US="$(python3 -c "print(f'{${AVG_CYC}/300:.1f}')")"   # assume 300 MHz
HW_THRU="$(python3 -c "
cyc=${AVG_CYC}; inp=${INPUT_PER_RUN}
if cyc > 0:
    us = cyc / 300.0  # 300 MHz → µs
    print(f'{inp / 1024 / 1024 / (us / 1e6):.1f}')
else:
    print('N/A')
")"

echo ""
echo "================================================================"
echo "  GB STRESS TEST COMPLETE"
echo "================================================================"
echo "  Runs:            ${PASS_COUNT} pass / ${FAIL_COUNT} fail / ${TOTAL_RUNS} total"
echo "  Data processed:  ${PROCESSED_MB} MB"
echo "  Wall time:       ${WALL_S} s"
echo "  Host throughput: ${HOST_THRU} MB/s  (incl. XDMA + reg overhead)"
echo "  Avg HW cycles:   ${AVG_CYC} cycles/run"
echo "  Avg HW time:     ${HW_US} µs/run  (@300MHz)"
echo "  HW throughput:   ${HW_THRU} MB/s  (pure hardware)"
echo "  Input per run:   ${INPUT_PER_RUN} bytes"
echo "  Blocks per run:  ${EXP_PAIRS} pairs"
echo "  Records per run: ${EXP_DEC} decoded"
echo "================================================================"

if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo ""
  echo "ALL PASS — ${PROCESSED_MB} MB processed without error"
  exit 0
else
  echo ""
  echo "FAILED — ${FAIL_COUNT} runs had errors" >&2
  exit 1
fi
