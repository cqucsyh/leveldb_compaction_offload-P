#!/bin/bash
#
# test_cmpct_sstable_engine_bp1_xdma.sh
#
# Board-level regression test for OPT-BP1 (Block Pair Pipeline).
# Verifies that overlapping decode(N+1) with write(N) produces correct
# results across multiple scenarios:
#
#   Phase A: 1-pair  (no pipeline opportunity — backward compat)
#   Phase B: 2-pair  (basic pipeline overlap)
#   Phase C: 4-pair  asymmetric (src0=2blk, src1=4blk, pass-through pairs)
#   Phase D: 4-pair  split mode (max_file_size=300 → ≥2 SSTables)
#   Phase E: 12-pair streaming (heavy pipeline overlap, auto-split)
#   Phase F: back-to-back stability loop (repeat Phase E N times)
#
# Prerequisites:
#   - XDMA driver loaded
#   - FPGA flashed with the OPT-BP1 sstable_engine design

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────
H2C_DEV="/dev/xdma0_h2c_0"
C2H_DEV="/dev/xdma0_c2h_0"
USER_DEV="/dev/xdma0_user"
TOOLS_DIR="/home/yh/pp4/dma_ip_drivers/XDMA/linux-kernel/tools"
FIXTURES="/home/yh/pp4/leveldb_compaction_offload/organized/sim/integration/fixtures"
LARGE_FIXTURES="/home/yh/pp4/generated_real_sstable_pair"

SRC0_DDR="0x00000000"
SRC1_DDR="0x00100000"
DST_BASE="0x00200000"
DST_STRIDE="0x00010000"
MID_ADDR="0x00400000"
MID_SIZE="0x00100000"
AXIL_BASE="0x00000000"

TIMEOUT_MS=30000
POLL_MS=100
STABILITY_LOOPS=5
VERBOSE=0
KEEP=0

# ── Register map (sstable_engine_axil_top) ────────────────────────────────
REG_CTRL="0x0000"
REG_STATUS="0x0004"
REG_SRC0_BASE_LO="0x0008"
REG_SRC0_BASE_HI="0x000C"
REG_SRC0_SIZE="0x0010"
REG_SRC1_BASE_LO="0x0014"
REG_SRC1_BASE_HI="0x0018"
REG_SRC1_SIZE="0x001C"
REG_DST_BASE_LO="0x0020"
REG_DST_BASE_HI="0x0024"
REG_DST_BLOCK_STRIDE="0x0028"
REG_MID_BASE_LO="0x002C"
REG_MID_BASE_HI="0x0030"
REG_BLOCK_PAIR_COUNT="0x0034"
REG_MAX_FILE_SIZE="0x0038"
REG_SSTABLE_COUNT="0x003C"
REG_SRC0_DECODED="0x0040"
REG_SRC1_DECODED="0x0044"
REG_SRC0_BYTES_READ="0x0048"
REG_SRC1_BYTES_READ="0x004C"
REG_MERGE_OUTPUT_BYTES="0x0050"
REG_MERGE_DECODED="0x0054"
REG_MERGE_MERGED="0x0058"
REG_MERGE_DROPPED="0x005C"
REG_STAGE5_INPUT="0x0060"
REG_STAGE5_ENCODED="0x0064"
REG_STAGE5_OUT_BYTES="0x0068"
REG_STAGE5_WRITTEN="0x006C"
REG_PERF_CYCLES="0x0070"
REG_DST_OUTPUT_BASE="0x0100"
REG_SST_SIZES_BASE="0x0180"
MAX_BLOCK_PAIRS=8
MAX_SSTABLES=8

# ── Usage ─────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [options]

OPT-BP1 board-level regression test.

Options:
  -w <h2c_dev>       H2C device       (default: ${H2C_DEV})
  -r <c2h_dev>       C2H device       (default: ${C2H_DEV})
  -u <user_dev>      User BAR         (default: ${USER_DEV})
  -t <tools_dir>     XDMA tools dir   (default: ${TOOLS_DIR})
  -B <axil_base>     AXI-Lite offset  (default: ${AXIL_BASE})
  -n <loops>         Stability loops  (default: ${STABILITY_LOOPS})
  -T <timeout_ms>    Poll timeout     (default: ${TIMEOUT_MS})
  -k                 Keep temp files
  -v                 Verbose
  -h                 Show help
EOF
}

while getopts ":w:r:u:t:B:n:T:kvh" opt; do
  case "$opt" in
    w) H2C_DEV="$OPTARG" ;;
    r) C2H_DEV="$OPTARG" ;;
    u) USER_DEV="$OPTARG" ;;
    t) TOOLS_DIR="$OPTARG" ;;
    B) AXIL_BASE="$OPTARG" ;;
    n) STABILITY_LOOPS="$OPTARG" ;;
    T) TIMEOUT_MS="$OPTARG" ;;
    k) KEEP=1 ;;
    v) VERBOSE=1 ;;
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

WORKDIR="$(mktemp -d)"
cleanup() {
  if [[ "$KEEP" -eq 0 ]]; then rm -rf "$WORKDIR"
  else echo "Keeping temp files in: $WORKDIR"; fi
}
trap cleanup EXIT

# ── Helpers ───────────────────────────────────────────────────────────────
now_ms() { python3 -c "import time; print(int(time.time()*1000))"; }
split_lo() { python3 -c "print(hex(int('$1',0) & 0xffffffff))"; }
split_hi() { python3 -c "print(hex((int('$1',0) >> 32) & 0xffffffff))"; }
addr_add() { python3 -c "print(hex(int('$1',0)+int('$2',0)))"; }

vlog() { if [[ "$VERBOSE" -eq 1 ]]; then echo "  [v] $*"; fi; }

reg_write() {
  local abs; abs="$(addr_add "$AXIL_BASE" "$1")"
  "$REG_RW" "$USER_DEV" "$abs" w "$2" >/dev/null
}

reg_read() {
  local abs; abs="$(addr_add "$AXIL_BASE" "$1")"
  "$REG_RW" "$USER_DEV" "$abs" w | awk '/Read 32-bit value/ {print $NF}' | tail -n1
}

dump_regs() {
  echo "  === Register snapshot ==="
  for name in \
    REG_STATUS REG_BLOCK_PAIR_COUNT REG_SSTABLE_COUNT \
    REG_SRC0_DECODED REG_SRC1_DECODED \
    REG_MERGE_DECODED REG_MERGE_MERGED REG_MERGE_DROPPED \
    REG_STAGE5_INPUT REG_STAGE5_ENCODED REG_STAGE5_WRITTEN \
    REG_PERF_CYCLES
  do
    printf "    %-35s = %s\n" "${name}" "$(reg_read "${!name}")"
  done
  for ((i=0; i<MAX_BLOCK_PAIRS; i++)); do
    local off; off="$(python3 -c "print(hex(int('${REG_DST_OUTPUT_BASE}',0)+$i*4))")"
    local v; v="$(reg_read "$off")"
    if [[ $((v)) -gt 0 ]]; then printf "    DST_OUTPUT_BYTES[%d]              = %s\n" "$i" "$v"; fi
  done
  for ((i=0; i<MAX_SSTABLES; i++)); do
    local off; off="$(python3 -c "print(hex(int('${REG_SST_SIZES_BASE}',0)+$i*4))")"
    local v; v="$(reg_read "$off")"
    if [[ $((v)) -gt 0 ]]; then printf "    SSTABLE_SIZE[%d]                  = %s\n" "$i" "$v"; fi
  done
}

# ── run_phase: core engine run + verify ──────────────────────────────────
#   run_phase <label> <src0_file> <src1_file> <max_file_size>
#             <exp_pairs> <exp_s0_dec> <exp_s1_dec>
#             <exp_m_dec> <exp_m_mrg> <exp_m_drp>
#             <exp_min_sst>
run_phase() {
  local LABEL="$1"
  local SRC0_FILE="$2"
  local SRC1_FILE="$3"
  local MAX_FSIZE="$4"
  local EXP_PAIRS="$5"
  local EXP_S0="$6"
  local EXP_S1="$7"
  local EXP_M_DEC="$8"
  local EXP_M_MRG="$9"
  local EXP_M_DRP="${10}"
  local EXP_MIN_SST="${11}"

  local SRC0_SIZE SRC1_SIZE
  SRC0_SIZE="$(stat -c%s "$SRC0_FILE")"
  SRC1_SIZE="$(stat -c%s "$SRC1_FILE")"

  echo ""
  echo "  ────────────────────────────────────────────────"
  echo "  ${LABEL}"
  echo "  SRC0: $(basename "$SRC0_FILE")  ${SRC0_SIZE}B"
  echo "  SRC1: $(basename "$SRC1_FILE")  ${SRC1_SIZE}B"
  echo "  Expect: pairs=${EXP_PAIRS} s0=${EXP_S0} s1=${EXP_S1}"
  echo "    merge: dec=${EXP_M_DEC} mrg=${EXP_M_MRG} drp=${EXP_M_DRP}"
  echo "  ────────────────────────────────────────────────"

  # Clear
  reg_write "$REG_CTRL" 0x2; sleep 0.01
  reg_write "$REG_CTRL" 0x0; sleep 0.01

  # Init sentinel for DST + MID
  local DST_INIT MID_INIT SENTINEL TOTAL_INIT
  DST_INIT=$(( 0x10000 * MAX_BLOCK_PAIRS ))
  MID_INIT=$(printf "%d" "$MID_SIZE")
  TOTAL_INIT=$(( DST_INIT > MID_INIT ? DST_INIT : MID_INIT ))
  SENTINEL="${WORKDIR}/sentinel.bin"
  python3 -c "open('${SENTINEL}','wb').write(bytes([0xA5]*${TOTAL_INIT}))"
  "$DMA_TO" -d "$H2C_DEV" -a "$DST_BASE" -s "${DST_INIT}" -f "$SENTINEL" 2>/dev/null
  "$DMA_TO" -d "$H2C_DEV" -a "$MID_ADDR" -s "${MID_INIT}" -f "$SENTINEL" 2>/dev/null

  # Upload SSTables
  "$DMA_TO" -d "$H2C_DEV" -a "$SRC0_DDR" -s "$SRC0_SIZE" -f "$SRC0_FILE" 2>/dev/null
  "$DMA_TO" -d "$H2C_DEV" -a "$SRC1_DDR" -s "$SRC1_SIZE" -f "$SRC1_FILE" 2>/dev/null

  # Program registers
  reg_write "$REG_SRC0_BASE_LO" "$(split_lo "$SRC0_DDR")"
  reg_write "$REG_SRC0_BASE_HI" "$(split_hi "$SRC0_DDR")"
  reg_write "$REG_SRC0_SIZE"    "$(printf "0x%x" "$SRC0_SIZE")"
  reg_write "$REG_SRC1_BASE_LO" "$(split_lo "$SRC1_DDR")"
  reg_write "$REG_SRC1_BASE_HI" "$(split_hi "$SRC1_DDR")"
  reg_write "$REG_SRC1_SIZE"    "$(printf "0x%x" "$SRC1_SIZE")"
  reg_write "$REG_DST_BASE_LO"  "$(split_lo "$DST_BASE")"
  reg_write "$REG_DST_BASE_HI"  "$(split_hi "$DST_BASE")"
  reg_write "$REG_DST_BLOCK_STRIDE" "$DST_STRIDE"
  reg_write "$REG_MID_BASE_LO"  "$(split_lo "$MID_ADDR")"
  reg_write "$REG_MID_BASE_HI"  "$(split_hi "$MID_ADDR")"
  reg_write "$REG_MAX_FILE_SIZE" "$MAX_FSIZE"
  sleep 0.02

  # Start
  local T_START T_END ELAPSED_MS
  T_START="$(now_ms)"
  reg_write "$REG_CTRL" 0x1
  reg_write "$REG_CTRL" 0x0

  # Poll
  local POLL_LOOPS POLL_SLEEP
  POLL_LOOPS=$(python3 -c "import math; print(max(1, math.ceil($TIMEOUT_MS/$POLL_MS)))")
  POLL_SLEEP=$(python3 -c "print($POLL_MS/1000.0)")

  local completed=0
  for ((i=0; i<POLL_LOOPS; i++)); do
    local sh sv
    sh="$(reg_read "$REG_STATUS")"; sh="${sh:-0x0}"; sv=$(($sh))
    if (( (sv >> 2) & 1 )); then
      T_END="$(now_ms)"
      dump_regs
      echo "  FAIL [${LABEL}]: error status=${sh} after $((T_END-T_START))ms" >&2
      return 1
    fi
    if (( (sv >> 1) & 1 )); then
      T_END="$(now_ms)"; ELAPSED_MS=$(( T_END - T_START ))
      completed=1; break
    fi
    sleep "$POLL_SLEEP"
  done

  if [[ "$completed" -ne 1 ]]; then
    T_END="$(now_ms)"
    dump_regs
    echo "  FAIL [${LABEL}]: timeout after $((T_END-T_START))ms" >&2
    return 1
  fi

  # Read counters
  local PAIRS S0 S1 MD MM MDP S5I S5E S5W SST CYC
  PAIRS="$(reg_read "$REG_BLOCK_PAIR_COUNT")"
  S0="$(reg_read "$REG_SRC0_DECODED")"
  S1="$(reg_read "$REG_SRC1_DECODED")"
  MD="$(reg_read "$REG_MERGE_DECODED")"
  MM="$(reg_read "$REG_MERGE_MERGED")"
  MDP="$(reg_read "$REG_MERGE_DROPPED")"
  S5I="$(reg_read "$REG_STAGE5_INPUT")"
  S5E="$(reg_read "$REG_STAGE5_ENCODED")"
  S5W="$(reg_read "$REG_STAGE5_WRITTEN")"
  SST="$(reg_read "$REG_SSTABLE_COUNT")"
  CYC="$(reg_read "$REG_PERF_CYCLES")"

  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "    pairs=${PAIRS} s0=${S0} s1=${S1}"
    echo "    merge: dec=${MD} mrg=${MM} drp=${MDP}"
    echo "    stage5: in=${S5I} enc=${S5E} written=${S5W}"
    echo "    sst_count=${SST} cycles=${CYC}"
  fi

  # Verify
  local FAIL=0

  chk_eq() {
    local name="$1" got="$2" exp="$3"
    if [[ $(($got)) -ne $(($exp)) ]]; then
      echo "    FAIL: ${name}=${got} expected=${exp}" >&2; FAIL=1
    else
      vlog "OK: ${name}=${got}"
    fi
  }
  chk_gte() {
    local name="$1" got="$2" min="$3"
    if [[ $(($got)) -lt $(($min)) ]]; then
      echo "    FAIL: ${name}=${got} expected >= ${min}" >&2; FAIL=1
    else
      vlog "OK: ${name}=${got} >= ${min}"
    fi
  }
  chk_gt0() {
    local name="$1" got="$2"
    if [[ $(($got)) -le 0 ]]; then
      echo "    FAIL: ${name}=${got} expected > 0" >&2; FAIL=1
    else
      vlog "OK: ${name}=${got} > 0"
    fi
  }

  chk_eq  "block_pairs"    "$PAIRS" "$EXP_PAIRS"
  chk_eq  "src0_decoded"   "$S0"    "$EXP_S0"
  chk_eq  "src1_decoded"   "$S1"    "$EXP_S1"
  chk_eq  "merge_decoded"  "$MD"    "$EXP_M_DEC"
  chk_eq  "merge_merged"   "$MM"    "$EXP_M_MRG"
  chk_eq  "merge_dropped"  "$MDP"   "$EXP_M_DRP"
  chk_eq  "stage5_input"   "$S5I"   "$EXP_M_MRG"
  chk_eq  "stage5_encoded" "$S5E"   "$EXP_M_MRG"
  chk_gt0 "stage5_written" "$S5W"
  chk_gte "sstable_count"  "$SST"   "$EXP_MIN_SST"

  # Accounting: dec == mrg + drp
  local SUM=$(( $(($MM)) + $(($MDP)) ))
  if [[ $(($MD)) -ne $SUM ]]; then
    echo "    FAIL: accounting dec=${MD} != mrg+drp=${SUM}" >&2; FAIL=1
  fi

  # Verify per-block output bytes: with split, only last SSTable's blocks are visible
  # Check that at least one dst_output_bytes entry is > 0
  local blk_nonzero=0
  for ((bi=0; bi<MAX_BLOCK_PAIRS; bi++)); do
    local off bv
    off="$(python3 -c "print(hex(int('${REG_DST_OUTPUT_BASE}',0)+$bi*4))")"
    bv="$(reg_read "$off")"
    if [[ $(($bv)) -gt 0 ]]; then blk_nonzero=$((blk_nonzero+1)); fi
  done
  if [[ "$blk_nonzero" -eq 0 ]]; then
    echo "    FAIL: all dst_output_bytes entries are 0" >&2; FAIL=1
  else
    vlog "dst_output_bytes: ${blk_nonzero} non-zero entries"
  fi

  # Verify LevelDB footer magic in output
  local N_SST=$(($SST))
  local SST_OFFSET=0
  for ((si=0; si<N_SST && si<MAX_SSTABLES; si++)); do
    local sst_off sst_bytes sst_addr outfile
    sst_off="$(python3 -c "print(hex(int('${REG_SST_SIZES_BASE}',0)+$si*4))")"
    sst_bytes="$(reg_read "$sst_off")"
    if [[ $(($sst_bytes)) -le 0 ]]; then continue; fi
    sst_addr="$(python3 -c "print(hex(int('${DST_BASE}',0)+$SST_OFFSET))")"
    outfile="${WORKDIR}/sst_${si}.bin"
    "$DMA_FROM" -d "$C2H_DEV" -a "$sst_addr" -s "$(($sst_bytes))" -f "$outfile" 2>/dev/null
    python3 - "$outfile" "$sst_bytes" "$si" <<'PYEOF'
import sys, struct, pathlib
path, sz_s, idx_s = sys.argv[1:4]
sz = int(sz_s, 0); idx = int(idx_s)
data = pathlib.Path(path).read_bytes()
if len(data) < sz:
    raise SystemExit(f"FAIL: sst[{idx}] readback short: {len(data)} < {sz}")
sst = data[:sz]
if all(b == 0xA5 for b in sst):
    raise SystemExit(f"FAIL: sst[{idx}] all sentinel")
if sz >= 48:
    magic = struct.unpack_from('<Q', sst, sz - 8)[0]
    if magic != 0xdb4775248b80fb57:
        raise SystemExit(f"FAIL: sst[{idx}] bad footer magic: {magic:#x}")
PYEOF
    if [[ $? -ne 0 ]]; then FAIL=1; fi
    SST_OFFSET=$(( $(python3 -c "print(((${SST_OFFSET}+$(($sst_bytes))+63)//64)*64)") ))
  done

  if [[ "$FAIL" -eq 0 ]]; then
    echo "  PASS [${LABEL}]  ${ELAPSED_MS}ms  cycles=${CYC}  sst=${SST}"
    return 0
  else
    dump_regs
    echo "  FAIL [${LABEL}]" >&2
    return 1
  fi
}

# ── Quick run (no DMA upload, reuse already-loaded SSTables) ─────────────
#   quick_run <label> <exp_pairs> <exp_s0_dec> <exp_s1_dec>
#             <exp_m_dec> <exp_m_mrg> <exp_m_drp>
quick_run() {
  local LABEL="$1"
  local EXP_PAIRS="$2"
  local EXP_S0="$3"
  local EXP_S1="$4"
  local EXP_M_DEC="$5"
  local EXP_M_MRG="$6"
  local EXP_M_DRP="$7"

  # Clear + restart (registers persist)
  reg_write "$REG_CTRL" 0x2
  reg_write "$REG_CTRL" 0x0
  sleep 0.01

  local T_START T_END
  T_START="$(now_ms)"
  reg_write "$REG_CTRL" 0x1
  reg_write "$REG_CTRL" 0x0

  local completed=0
  for ((p=0; p<300; p++)); do
    local sh sv
    sh="$(reg_read "$REG_STATUS")"; sh="${sh:-0x0}"; sv=$(($sh))
    if (( (sv >> 2) & 1 )); then
      echo "    FAIL [${LABEL}]: error status=${sh}" >&2; return 1
    fi
    if (( (sv >> 1) & 1 )); then completed=1; break; fi
    sleep 0.05
  done
  T_END="$(now_ms)"

  if [[ "$completed" -ne 1 ]]; then
    echo "    FAIL [${LABEL}]: timeout after $((T_END-T_START))ms" >&2; return 1
  fi

  local PAIRS MD MM MDP CYC
  PAIRS="$(reg_read "$REG_BLOCK_PAIR_COUNT")"
  MD="$(reg_read "$REG_MERGE_DECODED")"
  MM="$(reg_read "$REG_MERGE_MERGED")"
  MDP="$(reg_read "$REG_MERGE_DROPPED")"
  CYC="$(reg_read "$REG_PERF_CYCLES")"

  local FAIL=0
  if [[ $(($PAIRS)) -ne $(($EXP_PAIRS)) ]]; then FAIL=1; fi
  if [[ $(($MD))    -ne $(($EXP_M_DEC)) ]]; then FAIL=1; fi
  if [[ $(($MM))    -ne $(($EXP_M_MRG)) ]]; then FAIL=1; fi
  if [[ $(($MDP))   -ne $(($EXP_M_DRP)) ]]; then FAIL=1; fi

  if [[ "$FAIL" -eq 0 ]]; then
    echo "    PASS [${LABEL}]  $((T_END-T_START))ms  cycles=${CYC}"
    return 0
  else
    echo "    FAIL [${LABEL}]: pairs=${PAIRS}/${EXP_PAIRS} dec=${MD}/${EXP_M_DEC} mrg=${MM}/${EXP_M_MRG} drp=${MDP}/${EXP_M_DRP}" >&2
    return 1
  fi
}

# ══════════════════════════════════════════════════════════════════════════
echo "================================================================"
echo "  OPT-BP1 BOARD REGRESSION TEST"
echo "================================================================"
echo ""

TOTAL_PASS=0
TOTAL_FAIL=0

# ── Phase A: 1-pair (no pipeline opportunity) ────────────────────────────
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Phase A: Single block pair (baseline, no pipelining)      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
if run_phase \
    "A: 1-pair" \
    "${FIXTURES}/src0_sstable_1blk.bin" \
    "${FIXTURES}/src1_sstable_1blk.bin" \
    "0x0" \
    1 5 5 10 8 2 1; then
  TOTAL_PASS=$((TOTAL_PASS+1))
else
  TOTAL_FAIL=$((TOTAL_FAIL+1))
fi

# ── Phase B: 2-pair (basic pipeline) ─────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Phase B: 2 block pairs (basic OPT-BP1 pipeline)          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
if run_phase \
    "B: 2-pair" \
    "${FIXTURES}/src0_sstable_real.bin" \
    "${FIXTURES}/src1_sstable_real.bin" \
    "0x0" \
    2 8 6 14 12 2 1; then
  TOTAL_PASS=$((TOTAL_PASS+1))
else
  TOTAL_FAIL=$((TOTAL_FAIL+1))
fi

# ── Phase C: 4-pair asymmetric ───────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Phase C: 4-pair asymmetric (src0=2blk, src1=4blk)        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
if run_phase \
    "C: 4-pair asym" \
    "${FIXTURES}/src0_asym_real.bin" \
    "${FIXTURES}/src1_asym_real.bin" \
    "0x0" \
    4 8 12 20 20 0 1; then
  TOTAL_PASS=$((TOTAL_PASS+1))
else
  TOTAL_FAIL=$((TOTAL_FAIL+1))
fi

# ── Phase D: 12-pair split (SPLIT_TAIL_MARGIN=4096 on board) ─────────────
# Need max_file_size > 4096 to enable split. Use 12-pair streaming data.
# Total output ~2826B for 12 pairs. Set max_file_size=0x1800 (6144) so
# split_threshold = 6144-4096 = 2048 → triggers split mid-way.
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Phase D: 12-pair split mode (max_file_size=6144)          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
if run_phase \
    "D: 12-pair split" \
    "${FIXTURES}/src0_real.sst" \
    "${FIXTURES}/src1_real.sst" \
    "0x1800" \
    12 48 48 96 88 8 2; then
  TOTAL_PASS=$((TOTAL_PASS+1))
else
  TOTAL_FAIL=$((TOTAL_FAIL+1))
fi

# ── Phase E: 12-pair streaming (heavy pipeline overlap) ──────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Phase E: 12-pair streaming (heavy OPT-BP1 pipelining)    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
if run_phase \
    "E: 12-pair streaming" \
    "${FIXTURES}/src0_real.sst" \
    "${FIXTURES}/src1_real.sst" \
    "0x0" \
    12 48 48 96 88 8 2; then
  TOTAL_PASS=$((TOTAL_PASS+1))
else
  TOTAL_FAIL=$((TOTAL_FAIL+1))
fi

# ── Phase F: Stability loop (back-to-back re-runs) ──────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Phase F: Back-to-back stability (${STABILITY_LOOPS} loops)                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Phase F reuses the 12-pair SSTable data already in DDR
F_FAIL=0
for ((loop=1; loop<=STABILITY_LOOPS; loop++)); do
  if ! quick_run "F-${loop}/${STABILITY_LOOPS}" 12 48 48 96 88 8; then
    F_FAIL=$((F_FAIL+1))
  fi
done

if [[ "$F_FAIL" -eq 0 ]]; then
  echo "  PASS [Phase F]: ${STABILITY_LOOPS} back-to-back runs OK"
  TOTAL_PASS=$((TOTAL_PASS+1))
else
  echo "  FAIL [Phase F]: ${F_FAIL}/${STABILITY_LOOPS} runs failed" >&2
  TOTAL_FAIL=$((TOTAL_FAIL+1))
fi

# ── Phase G: Large SSTable (real sstable pair, 4 blocks) ─────────────────
if [[ -f "${LARGE_FIXTURES}/src0_db/000005.ldb" && -f "${LARGE_FIXTURES}/src1_db/000005.ldb" ]]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  Phase G: Real LevelDB SSTable pair (4+ blocks)           ║"
  echo "╚══════════════════════════════════════════════════════════════╝"

  # For this fixture we only have relaxed expectations (key overlap unknown)
  G_SRC0="${LARGE_FIXTURES}/src0_db/000005.ldb"
  G_SRC1="${LARGE_FIXTURES}/src1_db/000005.ldb"
  G_SRC0_SIZE="$(stat -c%s "$G_SRC0")"
  G_SRC1_SIZE="$(stat -c%s "$G_SRC1")"

  # Clear
  reg_write "$REG_CTRL" 0x2; sleep 0.01; reg_write "$REG_CTRL" 0x0; sleep 0.01

  # Init + upload
  G_SENTINEL="${WORKDIR}/g_sentinel.bin"
  python3 -c "open('${G_SENTINEL}','wb').write(bytes([0xA5]*$(printf "%d" "$MID_SIZE")))"
  "$DMA_TO" -d "$H2C_DEV" -a "$DST_BASE" -s "$(( 0x10000 * MAX_BLOCK_PAIRS ))" -f "$G_SENTINEL" 2>/dev/null
  "$DMA_TO" -d "$H2C_DEV" -a "$MID_ADDR" -s "$(printf "%d" "$MID_SIZE")" -f "$G_SENTINEL" 2>/dev/null
  "$DMA_TO" -d "$H2C_DEV" -a "$SRC0_DDR" -s "$G_SRC0_SIZE" -f "$G_SRC0" 2>/dev/null
  "$DMA_TO" -d "$H2C_DEV" -a "$SRC1_DDR" -s "$G_SRC1_SIZE" -f "$G_SRC1" 2>/dev/null

  # Program
  reg_write "$REG_SRC0_BASE_LO" "$(split_lo "$SRC0_DDR")"
  reg_write "$REG_SRC0_BASE_HI" "$(split_hi "$SRC0_DDR")"
  reg_write "$REG_SRC0_SIZE"    "$(printf "0x%x" "$G_SRC0_SIZE")"
  reg_write "$REG_SRC1_BASE_LO" "$(split_lo "$SRC1_DDR")"
  reg_write "$REG_SRC1_BASE_HI" "$(split_hi "$SRC1_DDR")"
  reg_write "$REG_SRC1_SIZE"    "$(printf "0x%x" "$G_SRC1_SIZE")"
  reg_write "$REG_DST_BASE_LO"  "$(split_lo "$DST_BASE")"
  reg_write "$REG_DST_BASE_HI"  "$(split_hi "$DST_BASE")"
  reg_write "$REG_DST_BLOCK_STRIDE" "$DST_STRIDE"
  reg_write "$REG_MID_BASE_LO"  "$(split_lo "$MID_ADDR")"
  reg_write "$REG_MID_BASE_HI"  "$(split_hi "$MID_ADDR")"
  reg_write "$REG_MAX_FILE_SIZE" "0x0"
  sleep 0.02

  reg_write "$REG_CTRL" 0x1; reg_write "$REG_CTRL" 0x0

  g_done=0
  for ((gi=0; gi<300; gi++)); do
    gs="$(reg_read "$REG_STATUS")"; gs="${gs:-0x0}"
    if (( ($(($gs)) >> 2) & 1 )); then
      dump_regs
      echo "  FAIL [Phase G]: error status=${gs}" >&2
      TOTAL_FAIL=$((TOTAL_FAIL+1))
      g_done=2; break
    fi
    if (( ($(($gs)) >> 1) & 1 )); then g_done=1; break; fi
    sleep 0.2
  done

  if [[ "$g_done" -eq 1 ]]; then
    G_FAIL=0
    G_PAIRS="$(reg_read "$REG_BLOCK_PAIR_COUNT")"
    G_S0="$(reg_read "$REG_SRC0_DECODED")"
    G_S1="$(reg_read "$REG_SRC1_DECODED")"
    G_MD="$(reg_read "$REG_MERGE_DECODED")"
    G_MM="$(reg_read "$REG_MERGE_MERGED")"
    G_MDP="$(reg_read "$REG_MERGE_DROPPED")"
    G_S5W="$(reg_read "$REG_STAGE5_WRITTEN")"
    G_CYC="$(reg_read "$REG_PERF_CYCLES")"

    echo "    pairs=${G_PAIRS} s0=${G_S0} s1=${G_S1} dec=${G_MD} mrg=${G_MM} drp=${G_MDP} wr=${G_S5W} cyc=${G_CYC}"

    if [[ $(($G_PAIRS)) -le 0 ]]; then echo "    FAIL: pairs=0" >&2; G_FAIL=1; fi
    if [[ $(($G_S0))    -le 0 ]]; then echo "    FAIL: s0_dec=0" >&2; G_FAIL=1; fi
    if [[ $(($G_S1))    -le 0 ]]; then echo "    FAIL: s1_dec=0" >&2; G_FAIL=1; fi
    if [[ $(($G_S5W))   -le 0 ]]; then echo "    FAIL: s5_written=0" >&2; G_FAIL=1; fi
    G_SUM=$(( $(($G_MM)) + $(($G_MDP)) ))
    if [[ $(($G_MD)) -ne $G_SUM ]]; then
      echo "    FAIL: accounting dec=${G_MD} != mrg+drp=${G_SUM}" >&2; G_FAIL=1
    fi

    if [[ "$G_FAIL" -eq 0 ]]; then
      echo "  PASS [Phase G]"
      TOTAL_PASS=$((TOTAL_PASS+1))
    else
      echo "  FAIL [Phase G]" >&2
      TOTAL_FAIL=$((TOTAL_FAIL+1))
    fi
  elif [[ "$g_done" -eq 0 ]]; then
    dump_regs
    echo "  FAIL [Phase G]: timeout" >&2
    TOTAL_FAIL=$((TOTAL_FAIL+1))
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────
TOTAL=$((TOTAL_PASS + TOTAL_FAIL))
echo ""
echo "================================================================"
echo "  OPT-BP1 BOARD TEST SUMMARY"
echo "================================================================"
echo "  Phases:   ${TOTAL}"
echo "  Passed:   ${TOTAL_PASS}"
echo "  Failed:   ${TOTAL_FAIL}"
echo "================================================================"
echo ""

if [[ "$TOTAL_FAIL" -eq 0 ]]; then
  echo "ALL PASS — OPT-BP1 block pair pipelining verified on board"
  exit 0
else
  echo "SOME TESTS FAILED" >&2
  exit 1
fi
