#!/bin/bash
#
# test_opt_perf_xdma.sh
#
# Post-optimization board-level validation & GB throughput benchmark.
#
# Phase 1 — Correctness: single run with full counter + output verification
# Phase 2 — Throughput:  tight loop accumulating ~1 GB of data, measuring
#           pure HW cycles (REG_PERF_CYCLES @300 MHz) and wall-clock time.
#
# Fixtures: /home/yh/pp4/fixtures_gb  (200-block, 4000-record pair)
#
# Optimizations under test:
#   OPT-HF  : record header FIFO (merger→encoder decoupling)
#   OPT-PKR : stream_byte_packer_32 (encoder output 4 B/cycle)
#   P4b     : CMP_CHUNK = MAX_USER_KEY_BYTES
#
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

TARGET_MB=1024          # default 1 GB
CLK_MHZ=300             # hardware clock frequency

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

Optimized bitstream board test + GB throughput benchmark.

Options:
  -M <MB>          Total data to process (default: ${TARGET_MB})
  -f <freq_mhz>    HW clock freq for throughput calc (default: ${CLK_MHZ})
  -h               Show help
EOF
}

while getopts ":M:f:h" opt; do
  case "$opt" in
    M) TARGET_MB="$OPTARG" ;;
    f) CLK_MHZ="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

DMA_TO="${TOOLS_DIR}/dma_to_device"
DMA_FROM="${TOOLS_DIR}/dma_from_device"
REG_RW="${TOOLS_DIR}/reg_rw"

# ── Pre-flight checks ────────────────────────────────────────────────────
echo "================================================================"
echo "  OPT BITSTREAM VALIDATION + GB THROUGHPUT BENCHMARK"
echo "================================================================"
echo ""

preflight_ok=1
for bin in "$DMA_TO" "$DMA_FROM" "$REG_RW"; do
  if [[ ! -x "$bin" ]]; then echo "ERROR: $bin not found" >&2; preflight_ok=0; fi
done
for dev in "$H2C_DEV" "$C2H_DEV" "$USER_DEV"; do
  if [[ ! -e "$dev" ]]; then echo "ERROR: $dev not found" >&2; preflight_ok=0; fi
done
for f in "$SRC0_FILE" "$SRC1_FILE"; do
  if [[ ! -f "$f" ]]; then echo "ERROR: $f not found" >&2; preflight_ok=0; fi
done
[[ "$preflight_ok" -eq 1 ]] || exit 1

# ── Fixture info ──────────────────────────────────────────────────────────
SRC0_SIZE="$(stat -c%s "$SRC0_FILE")"
SRC1_SIZE="$(stat -c%s "$SRC1_FILE")"
INPUT_PER_RUN=$(( SRC0_SIZE + SRC1_SIZE ))

INFO="${FIXTURES}/gb_sstable_info.txt"
EXP_PAIRS="$(grep '^expected_pairs=' "$INFO" | cut -d= -f2)"
EXP_DEC="$(grep '^expected_decoded=' "$INFO" | cut -d= -f2)"
EXP_MRG="$(grep '^expected_merged=' "$INFO" | cut -d= -f2)"
EXP_DRP="$(grep '^expected_dropped=' "$INFO" | cut -d= -f2)"
EXP_S0="$(grep '^src0_records=' "$INFO" | cut -d= -f2)"
EXP_S1="$(grep '^src1_records=' "$INFO" | cut -d= -f2)"

echo "  Fixture:  ${SRC0_SIZE} + ${SRC1_SIZE} = ${INPUT_PER_RUN} bytes/run"
echo "  Records:  ${EXP_S0} + ${EXP_S1} = ${EXP_DEC}"
echo "  Blocks:   ${EXP_PAIRS} pairs"
echo "  Target:   ${TARGET_MB} MB @ ${CLK_MHZ} MHz"
echo ""

# ── Helpers ───────────────────────────────────────────────────────────────
now_ms() { python3 -c "import time; print(int(time.time()*1000))"; }
split_lo() { printf "0x%x" $(( $1 & 0xffffffff )); }
split_hi() { printf "0x%x" $(( ($1 >> 32) & 0xffffffff )); }

rw() {
  local a=$(( $(printf "%d" "$AXIL_BASE") + $(printf "%d" "$1") ))
  "$REG_RW" "$USER_DEV" "$(printf "0x%x" "$a")" w "$2" >/dev/null
}

rr() {
  local a=$(( $(printf "%d" "$AXIL_BASE") + $(printf "%d" "$1") ))
  "$REG_RW" "$USER_DEV" "$(printf "0x%x" "$a")" w | awk '/Read 32-bit value/ {print $NF}' | tail -n1
}

chk() {
  local got="$1" exp="$2" label="$3"
  if [[ $(($got)) -ne $(($exp)) ]]; then
    echo "  FAIL: $label: got=$got exp=$exp" >&2; return 1
  else
    echo "  OK:   $label = $(($got))"
  fi
}

run_engine() {
  # Clear + start
  rw "$R_CTRL" 0x2; rw "$R_CTRL" 0x0
  rw "$R_CTRL" 0x1; rw "$R_CTRL" 0x0

  # Poll for done/error (timeout ~10s)
  for ((p=0; p<500; p++)); do
    local s; s="$(rr "$R_STATUS")"; s="${s:-0x0}"
    local sv=$(( s ))
    if (( (sv >> 2) & 1 )); then echo "ERROR: engine error (status=${s})" >&2; return 2; fi
    if (( (sv >> 1) & 1 )); then return 0; fi
    sleep 0.02
  done
  echo "ERROR: engine timeout" >&2; return 1
}

# ══════════════════════════════════════════════════════════════════════════
#  PHASE 1: CORRECTNESS VERIFICATION
# ══════════════════════════════════════════════════════════════════════════
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Phase 1: Correctness Verification                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Upload fixtures to DDR
echo "[1] Uploading fixtures to DDR..."
"$DMA_TO" -d "$H2C_DEV" -a "$SRC0_DDR" -s "$SRC0_SIZE" -f "$SRC0_FILE" 2>&1 | tail -1
"$DMA_TO" -d "$H2C_DEV" -a "$SRC1_DDR" -s "$SRC1_SIZE" -f "$SRC1_FILE" 2>&1 | tail -1
echo "  Done."

# Program registers
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

# Run engine
echo "[3] Running engine (correctness run)..."
t_start="$(now_ms)"
if ! run_engine; then
  echo "PHASE 1 FAIL: engine did not complete" >&2
  exit 1
fi
t_end="$(now_ms)"
wall_ms=$(( t_end - t_start ))

# Verify counters
echo "[4] Verifying hardware counters..."
fail=0
chk "$(rr "$R_PAIRS")" "$EXP_PAIRS" "block_pairs"      || fail=1
chk "$(rr "$R_D0")"    "$EXP_S0"    "src0_decoded"      || fail=1
chk "$(rr "$R_D1")"    "$EXP_S1"    "src1_decoded"      || fail=1
chk "$(rr "$R_MD")"    "$EXP_DEC"   "merge_decoded"     || fail=1
chk "$(rr "$R_MM")"    "$EXP_MRG"   "merge_merged"      || fail=1
chk "$(rr "$R_MDP")"   "$EXP_DRP"   "merge_dropped"     || fail=1

cyc_hex="$(rr "$R_CYC")"
cyc_val=$(( cyc_hex ))
s5w_hex="$(rr "$R_S5W")"
sst_hex="$(rr "$R_SSTC")"
mob_hex="$(rr "$R_MOB")"

echo ""
echo "  perf_cycles     = ${cyc_val}"
echo "  stage5_written  = $(( s5w_hex )) bytes"
echo "  sstable_count   = $(( sst_hex ))"
echo "  merge_out_bytes = $(( mob_hex ))"
echo "  wall_time       = ${wall_ms} ms"
echo ""

if [[ "$fail" -ne 0 ]]; then
  echo "═══ PHASE 1 FAIL ═══" >&2
  exit 1
fi

# Calculate single-run HW throughput
hw_thru_single="$(python3 -c "
cyc=${cyc_val}; inp=${INPUT_PER_RUN}; freq=${CLK_MHZ}
if cyc > 0:
    us = cyc / freq  # cycles → µs
    mbps = inp / 1024 / 1024 / (us / 1e6)
    print(f'{mbps:.1f}')
else:
    print('N/A')
")"
echo "  Single-run HW throughput: ${hw_thru_single} MB/s (@${CLK_MHZ} MHz)"
echo ""
echo "═══ PHASE 1 PASS ═══"
echo ""

# ══════════════════════════════════════════════════════════════════════════
#  PHASE 2: GB THROUGHPUT BENCHMARK
# ══════════════════════════════════════════════════════════════════════════
TOTAL_RUNS=$(( (TARGET_MB * 1024 * 1024 + INPUT_PER_RUN - 1) / INPUT_PER_RUN ))

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Phase 2: GB Throughput Benchmark                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Runs needed:  ${TOTAL_RUNS}"
echo "  Data target:  ${TARGET_MB} MB"
echo ""

TOTAL_BYTES=0
TOTAL_CYC=0
PASS_COUNT=0
FAIL_COUNT=0
MIN_CYC=999999999
MAX_CYC=0
VERIFY_INTERVAL=100

T_ALL_START="$(now_ms)"

for ((run=1; run<=TOTAL_RUNS; run++)); do
  # Clear + start (registers persist)
  rw "$R_CTRL" 0x2
  rw "$R_CTRL" 0x0
  rw "$R_CTRL" 0x1
  rw "$R_CTRL" 0x0

  # Poll for done
  done_ok=0
  for ((p=0; p<500; p++)); do
    s="$(rr "$R_STATUS")"; s="${s:-0x0}"
    sv=$(( s ))
    if (( (sv >> 2) & 1 )); then
      echo "  RUN ${run}: ERROR status=${s}" >&2
      FAIL_COUNT=$(( FAIL_COUNT + 1 )); done_ok=2; break
    fi
    if (( (sv >> 1) & 1 )); then done_ok=1; break; fi
    sleep 0.005
  done

  if [[ "$done_ok" -eq 0 ]]; then
    echo "  RUN ${run}: TIMEOUT" >&2
    FAIL_COUNT=$(( FAIL_COUNT + 1 )); continue
  fi
  if [[ "$done_ok" -eq 2 ]]; then continue; fi

  # Accumulate
  cyc="$(rr "$R_CYC")"
  cyc_v=$(( cyc ))
  TOTAL_BYTES=$(( TOTAL_BYTES + INPUT_PER_RUN ))
  TOTAL_CYC=$(( TOTAL_CYC + cyc_v ))
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  if (( cyc_v < MIN_CYC )); then MIN_CYC=$cyc_v; fi
  if (( cyc_v > MAX_CYC )); then MAX_CYC=$cyc_v; fi

  # Periodic verification + progress
  if (( run % VERIFY_INTERVAL == 0 )) || (( run == TOTAL_RUNS )); then
    # Quick sanity check
    vp="$(rr "$R_PAIRS")"
    vmm="$(rr "$R_MM")"
    vfail=0
    if [[ $(($vp)) -ne $((EXP_PAIRS)) ]]; then vfail=1; fi
    if [[ $(($vmm)) -ne $((EXP_MRG)) ]]; then vfail=1; fi

    if [[ "$vfail" -ne 0 ]]; then
      echo "  RUN ${run}: VERIFY FAIL pairs=${vp} merged=${vmm}" >&2
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      PASS_COUNT=$(( PASS_COUNT - 1 ))
    fi

    T_NOW="$(now_ms)"
    elapsed_s="$(python3 -c "print(f'{(${T_NOW}-${T_ALL_START})/1000:.1f}')")"
    processed_mb="$(python3 -c "print(f'{${TOTAL_BYTES}/1024/1024:.1f}')")"
    avg_cyc=$(( TOTAL_CYC / (PASS_COUNT > 0 ? PASS_COUNT : 1) ))

    printf "  [%5d/%d]  %7s MB  %6ss  avg_cyc=%d  min=%d  max=%d\n" \
           "$run" "$TOTAL_RUNS" "$processed_mb" "$elapsed_s" "$avg_cyc" "$MIN_CYC" "$MAX_CYC"
  fi
done

T_ALL_END="$(now_ms)"
WALL_MS=$(( T_ALL_END - T_ALL_START ))

# ══════════════════════════════════════════════════════════════════════════
#  FINAL REPORT
# ══════════════════════════════════════════════════════════════════════════
AVG_CYC=$(( TOTAL_CYC / (PASS_COUNT > 0 ? PASS_COUNT : 1) ))

python3 -c "
import sys

total_bytes  = ${TOTAL_BYTES}
total_cyc    = ${TOTAL_CYC}
pass_count   = ${PASS_COUNT}
fail_count   = ${FAIL_COUNT}
total_runs   = ${TOTAL_RUNS}
wall_ms      = ${WALL_MS}
avg_cyc      = ${AVG_CYC}
min_cyc      = ${MIN_CYC}
max_cyc      = ${MAX_CYC}
inp_per_run  = ${INPUT_PER_RUN}
freq_mhz     = ${CLK_MHZ}
exp_pairs    = ${EXP_PAIRS}
exp_dec      = ${EXP_DEC}

processed_mb = total_bytes / 1024 / 1024
wall_s       = wall_ms / 1000.0
host_mbps    = processed_mb / wall_s if wall_s > 0 else 0

hw_us_avg    = avg_cyc / freq_mhz            # µs per run
hw_us_min    = min_cyc / freq_mhz
hw_us_max    = max_cyc / freq_mhz
hw_mbps_avg  = (inp_per_run / 1024 / 1024) / (hw_us_avg / 1e6) if hw_us_avg > 0 else 0
hw_mbps_best = (inp_per_run / 1024 / 1024) / (hw_us_min / 1e6) if hw_us_min > 0 else 0
hw_mbps_worst= (inp_per_run / 1024 / 1024) / (hw_us_max / 1e6) if hw_us_max > 0 else 0

# Bytes per cycle
bpc_avg  = inp_per_run / avg_cyc if avg_cyc > 0 else 0
bpc_best = inp_per_run / min_cyc if min_cyc > 0 else 0

print()
print('================================================================')
print('  OPT BITSTREAM — GB THROUGHPUT BENCHMARK RESULTS')
print('================================================================')
print(f'  Optimizations:   P4b + OPT-HF + OPT-PKR + P10 + P11 + P12')
print(f'  Clock:           {freq_mhz} MHz')
print()
print(f'  Runs:            {pass_count} pass / {fail_count} fail / {total_runs} total')
print(f'  Data processed:  {processed_mb:.2f} MB')
print(f'  Wall time:       {wall_s:.2f} s')
print()
print(f'  ── Host Throughput (incl. DMA + register I/O) ──')
print(f'  Host throughput: {host_mbps:.2f} MB/s')
print()
print(f'  ── Pure HW Throughput (from perf_cycles register) ──')
print(f'  Avg HW cycles:   {avg_cyc:,}  ({hw_us_avg:.1f} µs)')
print(f'  Min HW cycles:   {min_cyc:,}  ({hw_us_min:.1f} µs)')
print(f'  Max HW cycles:   {max_cyc:,}  ({hw_us_max:.1f} µs)')
print()
print(f'  HW throughput (avg):   {hw_mbps_avg:.1f} MB/s')
print(f'  HW throughput (best):  {hw_mbps_best:.1f} MB/s')
print(f'  HW throughput (worst): {hw_mbps_worst:.1f} MB/s')
print()
print(f'  Bytes/cycle (avg):  {bpc_avg:.3f}')
print(f'  Bytes/cycle (best): {bpc_best:.3f}')
print()
print(f'  ── Workload ──')
print(f'  Input/run:   {inp_per_run:,} bytes  ({inp_per_run/1024:.1f} KB)')
print(f'  Blocks/run:  {exp_pairs} pairs')
print(f'  Records/run: {exp_dec} decoded')
print('================================================================')

if fail_count == 0:
    print()
    print(f'ALL PASS — {processed_mb:.0f} MB processed without error')
    sys.exit(0)
else:
    print()
    print(f'FAILED — {fail_count} runs had errors', file=sys.stderr)
    sys.exit(1)
"
