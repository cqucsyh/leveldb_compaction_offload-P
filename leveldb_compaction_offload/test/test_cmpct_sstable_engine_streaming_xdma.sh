#!/bin/bash
#
# test_cmpct_sstable_engine_streaming_xdma.sh
#
# Board-level test for the streaming sstable_engine pipeline.
# Tests continuous processing of data blocks beyond the legacy
# MAX_BLOCK_PAIRS=8 limit using real LevelDB SSTables.
#
# Test phases:
#   Phase A: 12 block pairs, 48+48 records, 8 duplicates, auto-split
#   Phase B: Immediate back-to-back re-run (stability)
#   Phase C: 2-block minimal SSTable (basic sanity after large run)
#
# Each phase loads SSTables into DDR, programs the AXI-Lite registers,
# starts the engine, polls for completion, and verifies all counters.
#
# Prerequisites:
#   - XDMA driver loaded, devices present
#   - FPGA flashed with the streaming sstable_engine design
#   - gen_real_sstable built (or fixtures already generated)

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────
H2C_DEV_DEFAULT="/dev/xdma0_h2c_0"
C2H_DEV_DEFAULT="/dev/xdma0_c2h_0"
USER_DEV_DEFAULT="/dev/xdma0_user"
TOOLS_DIR_DEFAULT="/home/yh/pp4/dma_ip_drivers/XDMA/linux-kernel/tools"
SIM_FIXTURES="/home/yh/pp4/leveldb_compaction_offload/organized/sim/integration/fixtures"
GEN_TOOL="/home/yh/pp4/leveldb_compaction_offload/organized/sim/integration/gen_real_sstable"
# Pre-existing small SSTable pair (2 blocks each)
SMALL_SRC0_DEFAULT="/home/yh/pp4/generated_real_sstable_pair/src0_db/000005.ldb"
SMALL_SRC1_DEFAULT="/home/yh/pp4/generated_real_sstable_pair/src1_db/000005.ldb"

SRC0_DDR_ADDR_DEFAULT="0x00000000"
SRC1_DDR_ADDR_DEFAULT="0x00100000"
DST_BASE_ADDR_DEFAULT="0x00200000"
DST_BLOCK_STRIDE_DEFAULT="0x00010000"
MID_ADDR_DEFAULT="0x00300000"
MID_SIZE_DEFAULT="0x00080000"
AXIL_BASE_DEFAULT="0x00000000"
TIMEOUT_MS_DEFAULT="30000"
POLL_INTERVAL_MS_DEFAULT="200"
CFG_SETTLE_MS_DEFAULT="20"
ITERATIONS_DEFAULT="1"

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
REG_BLOCK_PAIR_COUNT_OUT="0x0034"
REG_MAX_FILE_SIZE="0x0038"
REG_SSTABLE_COUNT="0x003C"
REG_TOTAL_SRC0_DECODED="0x0040"
REG_TOTAL_SRC1_DECODED="0x0044"
REG_TOTAL_SRC0_BYTES_READ="0x0048"
REG_TOTAL_SRC1_BYTES_READ="0x004C"
REG_TOTAL_MERGE_OUTPUT_BYTES="0x0050"
REG_TOTAL_MERGE_DECODED="0x0054"
REG_TOTAL_MERGE_MERGED="0x0058"
REG_TOTAL_MERGE_DROPPED="0x005C"
REG_TOTAL_STAGE5_INPUT="0x0060"
REG_TOTAL_STAGE5_ENCODED="0x0064"
REG_TOTAL_STAGE5_OUTPUT_BYTES="0x0068"
REG_TOTAL_STAGE5_BYTES_WRITTEN="0x006C"
REG_PERF_CYCLE_COUNT="0x0070"
REG_DST_OUTPUT_BYTES_BASE="0x0100"
REG_SSTABLE_SIZES_BASE="0x0180"
MAX_BLOCK_PAIRS=8
MAX_SSTABLES=8

# ── Usage ─────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [options]

Streaming pipeline continuous-processing board test.

Tests the engine's ability to process >8 block pairs in a single run,
verifying auto-split and counter correctness, then re-runs for stability.

Options:
  -w <h2c_dev>       H2C device       (default: ${H2C_DEV_DEFAULT})
  -r <c2h_dev>       C2H device       (default: ${C2H_DEV_DEFAULT})
  -u <user_dev>      User BAR         (default: ${USER_DEV_DEFAULT})
  -t <tools_dir>     XDMA tools dir   (default: ${TOOLS_DIR_DEFAULT})
  -B <axil_base>     AXI-Lite offset  (default: ${AXIL_BASE_DEFAULT})
  -T <timeout_ms>    Poll timeout     (default: ${TIMEOUT_MS_DEFAULT})
  -P <poll_ms>       Poll interval    (default: ${POLL_INTERVAL_MS_DEFAULT})
  -n <iterations>    Repeat count     (default: ${ITERATIONS_DEFAULT})
  -k                 Keep temp files
  -v                 Verbose
  -h                 Show help
EOF
}

# ── Parse options ─────────────────────────────────────────────────────────
H2C_DEV="${H2C_DEV_DEFAULT}"
C2H_DEV="${C2H_DEV_DEFAULT}"
USER_DEV="${USER_DEV_DEFAULT}"
TOOLS_DIR="${TOOLS_DIR_DEFAULT}"
AXIL_BASE="${AXIL_BASE_DEFAULT}"
TIMEOUT_MS="${TIMEOUT_MS_DEFAULT}"
POLL_INTERVAL_MS="${POLL_INTERVAL_MS_DEFAULT}"
CFG_SETTLE_MS="${CFG_SETTLE_MS_DEFAULT}"
ITERATIONS="${ITERATIONS_DEFAULT}"
KEEP=0
VERBOSE=0

while getopts ":w:r:u:t:B:T:P:n:kvh" opt; do
  case "$opt" in
    w) H2C_DEV="$OPTARG" ;;
    r) C2H_DEV="$OPTARG" ;;
    u) USER_DEV="$OPTARG" ;;
    t) TOOLS_DIR="$OPTARG" ;;
    B) AXIL_BASE="$OPTARG" ;;
    T) TIMEOUT_MS="$OPTARG" ;;
    P) POLL_INTERVAL_MS="$OPTARG" ;;
    n) ITERATIONS="$OPTARG" ;;
    k) KEEP=1 ;;
    v) VERBOSE=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

DMA_TO="${TOOLS_DIR}/dma_to_device"
DMA_FROM="${TOOLS_DIR}/dma_from_device"
REG_RW="${TOOLS_DIR}/reg_rw"

# ── Pre-flight checks ────────────────────────────────────────────────────
for bin in "$DMA_TO" "$DMA_FROM" "$REG_RW"; do
  if [[ ! -x "$bin" ]]; then
    echo "ERROR: executable not found: $bin" >&2; exit 1
  fi
done
for dev in "$H2C_DEV" "$C2H_DEV" "$USER_DEV"; do
  if [[ ! -e "$dev" ]]; then
    echo "ERROR: device not found: $dev" >&2; exit 1
  fi
done

# ── Work directory ────────────────────────────────────────────────────────
WORKDIR="$(mktemp -d)"
cleanup() {
  if [[ "$KEEP" -eq 0 ]]; then
    rm -rf "$WORKDIR"
  else
    echo "Keeping temp files in: $WORKDIR"
  fi
}
trap cleanup EXIT

# ── Helper functions ──────────────────────────────────────────────────────
now_ms() { python3 -c "import time; print(int(time.time()*1000))"; }
split_lo() { python3 -c "print(hex(int('$1',0) & 0xffffffff))"; }
split_hi() { python3 -c "print(hex((int('$1',0) >> 32) & 0xffffffff))"; }
addr_add() { python3 -c "print(hex(int('$1',0)+int('$2',0)))"; }
align64() { python3 -c "v=int('$1',0); print(hex(((v+63)//64)*64))"; }

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
  echo "=== Register snapshot ==="
  for name in \
    REG_STATUS REG_BLOCK_PAIR_COUNT_OUT REG_MAX_FILE_SIZE REG_SSTABLE_COUNT \
    REG_TOTAL_SRC0_DECODED REG_TOTAL_SRC1_DECODED \
    REG_TOTAL_SRC0_BYTES_READ REG_TOTAL_SRC1_BYTES_READ \
    REG_TOTAL_MERGE_OUTPUT_BYTES \
    REG_TOTAL_MERGE_DECODED REG_TOTAL_MERGE_MERGED REG_TOTAL_MERGE_DROPPED \
    REG_TOTAL_STAGE5_INPUT REG_TOTAL_STAGE5_ENCODED \
    REG_TOTAL_STAGE5_OUTPUT_BYTES REG_TOTAL_STAGE5_BYTES_WRITTEN \
    REG_PERF_CYCLE_COUNT
  do
    printf "  %-40s = %s\n" "${name}" "$(reg_read "${!name}")"
  done
  for ((i=0; i<MAX_BLOCK_PAIRS; i++)); do
    local off; off="$(python3 -c "print(hex(int('${REG_DST_OUTPUT_BYTES_BASE}',0)+$i*4))")"
    local v; v="$(reg_read "$off")"
    if [[ $((v)) -gt 0 ]]; then printf "  DST_OUTPUT_BYTES[%d]                    = %s\n" "$i" "$v"; fi
  done
  for ((i=0; i<MAX_SSTABLES; i++)); do
    local off; off="$(python3 -c "print(hex(int('${REG_SSTABLE_SIZES_BASE}',0)+$i*4))")"
    local v; v="$(reg_read "$off")"
    if [[ $((v)) -gt 0 ]]; then printf "  SSTABLE_SIZE[%d]                        = %s\n" "$i" "$v"; fi
  done
}

# ── Ensure large SSTable fixtures exist ───────────────────────────────────
LARGE_SRC0="${SIM_FIXTURES}/src0_real.sst"
LARGE_SRC1="${SIM_FIXTURES}/src1_real.sst"

if [[ ! -f "$LARGE_SRC0" || ! -f "$LARGE_SRC1" ]]; then
  echo "Generating large SSTable fixtures..."
  if [[ ! -x "$GEN_TOOL" ]]; then
    echo "ERROR: generator not found: $GEN_TOOL" >&2
    echo "Build with: cd $(dirname $GEN_TOOL) && g++ -std=c++17 -I.../leveldb/include -I.../leveldb -o gen_real_sstable gen_real_sstable.cc .../libleveldb.a -lsnappy -lpthread" >&2
    exit 1
  fi
  (cd "$(dirname "$GEN_TOOL")" && "$GEN_TOOL")
fi

# ── Core: run one compaction and verify ───────────────────────────────────
#   run_phase <label> <src0_file> <src1_file> <max_file_size>
#             <exp_pairs> <exp_src0_dec> <exp_src1_dec>
#             <exp_merge_dec> <exp_merge_mrg> <exp_merge_drp>
#             <exp_min_sst_count>
run_phase() {
  local LABEL="$1"
  local SRC0_FILE="$2"
  local SRC1_FILE="$3"
  local MAX_FSIZE="$4"
  local EXP_PAIRS="$5"
  local EXP_S0_DEC="$6"
  local EXP_S1_DEC="$7"
  local EXP_M_DEC="$8"
  local EXP_M_MRG="$9"
  local EXP_M_DRP="${10}"
  local EXP_MIN_SST="${11}"

  local SRC0_SIZE SRC1_SIZE

  SRC0_SIZE="$(stat -c%s "$SRC0_FILE")"
  SRC1_SIZE="$(stat -c%s "$SRC1_FILE")"

  echo ""
  echo "============================================================"
  echo "  ${LABEL}"
  echo "  SRC0: $(basename "$SRC0_FILE")  ${SRC0_SIZE} bytes"
  echo "  SRC1: $(basename "$SRC1_FILE")  ${SRC1_SIZE} bytes"
  echo "  Expected: ${EXP_PAIRS} pairs, ${EXP_S0_DEC}+${EXP_S1_DEC} records"
  echo "    merge: dec=${EXP_M_DEC} mrg=${EXP_M_MRG} drp=${EXP_M_DRP}"
  echo "    min sstable_count=${EXP_MIN_SST}"
  echo "============================================================"

  # Step 1: Clear IP
  echo "  [1] Clearing IP state"
  reg_write "$REG_CTRL" 0x2
  sleep 0.010
  reg_write "$REG_CTRL" 0x0
  sleep 0.010

  # Step 2: Sentinel fill DST + MID
  local DST_INIT_BYTES MID_INIT_BYTES SENTINEL
  DST_INIT_BYTES="$(python3 -c "print(int('${DST_BLOCK_STRIDE_DEFAULT}',0)*$MAX_BLOCK_PAIRS)")"
  MID_INIT_BYTES="$(python3 -c "print(int('${MID_SIZE_DEFAULT}',0))")"
  SENTINEL="${WORKDIR}/sentinel.bin"

  local TOTAL_SENTINEL=$(( DST_INIT_BYTES > MID_INIT_BYTES ? DST_INIT_BYTES : MID_INIT_BYTES ))
  python3 -c "open('${SENTINEL}','wb').write(bytes([0xA5]*${TOTAL_SENTINEL}))"

  echo "  [2] Initializing DST (${DST_INIT_BYTES} B) and MID (${MID_INIT_BYTES} B)"
  "$DMA_TO" -d "$H2C_DEV" -a "${DST_BASE_ADDR_DEFAULT}" -s "${DST_INIT_BYTES}" -f "$SENTINEL"
  "$DMA_TO" -d "$H2C_DEV" -a "${MID_ADDR_DEFAULT}"      -s "${MID_INIT_BYTES}"  -f "$SENTINEL"

  # Step 3: Load SSTables into DDR
  echo "  [3] Loading SSTables into DDR"
  "$DMA_TO" -d "$H2C_DEV" -a "${SRC0_DDR_ADDR_DEFAULT}" -s "$SRC0_SIZE" -f "$SRC0_FILE"
  "$DMA_TO" -d "$H2C_DEV" -a "${SRC1_DDR_ADDR_DEFAULT}" -s "$SRC1_SIZE" -f "$SRC1_FILE"

  # Step 4: Program registers
  echo "  [4] Programming AXI-Lite registers"
  reg_write "$REG_SRC0_BASE_LO"    "$(split_lo "$SRC0_DDR_ADDR_DEFAULT")"
  reg_write "$REG_SRC0_BASE_HI"    "$(split_hi "$SRC0_DDR_ADDR_DEFAULT")"
  reg_write "$REG_SRC0_SIZE"       "$(python3 -c "print(hex($SRC0_SIZE))")"
  reg_write "$REG_SRC1_BASE_LO"    "$(split_lo "$SRC1_DDR_ADDR_DEFAULT")"
  reg_write "$REG_SRC1_BASE_HI"    "$(split_hi "$SRC1_DDR_ADDR_DEFAULT")"
  reg_write "$REG_SRC1_SIZE"       "$(python3 -c "print(hex($SRC1_SIZE))")"
  reg_write "$REG_DST_BASE_LO"     "$(split_lo "$DST_BASE_ADDR_DEFAULT")"
  reg_write "$REG_DST_BASE_HI"     "$(split_hi "$DST_BASE_ADDR_DEFAULT")"
  reg_write "$REG_DST_BLOCK_STRIDE" "${DST_BLOCK_STRIDE_DEFAULT}"
  reg_write "$REG_MID_BASE_LO"     "$(split_lo "$MID_ADDR_DEFAULT")"
  reg_write "$REG_MID_BASE_HI"     "$(split_hi "$MID_ADDR_DEFAULT")"
  reg_write "$REG_MAX_FILE_SIZE"    "${MAX_FSIZE}"

  if [[ "$CFG_SETTLE_MS" -gt 0 ]]; then
    sleep "$(python3 -c "print($CFG_SETTLE_MS/1000.0)")"
  fi

  # Step 5: Start and poll
  echo "  [5] Starting engine"
  local T_START T_END ELAPSED_MS
  T_START="$(now_ms)"
  reg_write "$REG_CTRL" 0x1
  reg_write "$REG_CTRL" 0x0

  local POLL_LOOPS POLL_SLEEP
  mapfile -t _PP < <(python3 -c "
import math
loops = max(1, math.ceil(int('$TIMEOUT_MS',0)/int('$POLL_INTERVAL_MS',0)))
print(loops)
print(int('$POLL_INTERVAL_MS',0)/1000.0)
")
  POLL_LOOPS="${_PP[0]}"
  POLL_SLEEP="${_PP[1]}"

  local completed=0
  for ((i=0; i<POLL_LOOPS; i++)); do
    local status_hex status_val busy_bit done_bit err_bit
    status_hex="$(reg_read "$REG_STATUS")"
    status_hex="${status_hex:-0x0}"
    status_val="$((status_hex))"
    busy_bit=$(( status_val & 0x1 ))
    done_bit=$(( (status_val >> 1) & 0x1 ))
    err_bit=$(( (status_val >> 2) & 0x1 ))
    vlog "poll[$i] status=${status_hex} busy=${busy_bit} done=${done_bit} err=${err_bit}"

    if (( err_bit == 1 )); then
      T_END="$(now_ms)"
      dump_regs
      echo "  FAIL [${LABEL}]: engine error  status=${status_hex}  elapsed=$((T_END-T_START))ms" >&2
      return 1
    fi
    if (( done_bit == 1 )); then
      T_END="$(now_ms)"
      ELAPSED_MS=$(( T_END - T_START ))
      completed=1
      break
    fi
    sleep "$POLL_SLEEP"
  done

  if [[ "$completed" -ne 1 ]]; then
    T_END="$(now_ms)"
    dump_regs
    echo "  FAIL [${LABEL}]: timeout after $((T_END-T_START))ms" >&2
    return 1
  fi

  echo "  [6] Done in ${ELAPSED_MS} ms — reading counters"

  # Step 6: Read and verify counters
  local PAIR_COUNT S0_DEC S1_DEC M_DEC M_MRG M_DRP S5_IN S5_ENC S5_WR
  local SST_COUNT PERF_CYCLES
  PAIR_COUNT="$(reg_read "$REG_BLOCK_PAIR_COUNT_OUT")"
  S0_DEC="$(reg_read "$REG_TOTAL_SRC0_DECODED")"
  S1_DEC="$(reg_read "$REG_TOTAL_SRC1_DECODED")"
  M_DEC="$(reg_read "$REG_TOTAL_MERGE_DECODED")"
  M_MRG="$(reg_read "$REG_TOTAL_MERGE_MERGED")"
  M_DRP="$(reg_read "$REG_TOTAL_MERGE_DROPPED")"
  S5_IN="$(reg_read "$REG_TOTAL_STAGE5_INPUT")"
  S5_ENC="$(reg_read "$REG_TOTAL_STAGE5_ENCODED")"
  S5_WR="$(reg_read "$REG_TOTAL_STAGE5_BYTES_WRITTEN")"
  SST_COUNT="$(reg_read "$REG_SSTABLE_COUNT")"
  PERF_CYCLES="$(reg_read "$REG_PERF_CYCLE_COUNT")"

  echo "    block_pair_count   = ${PAIR_COUNT}"
  echo "    src0_decoded       = ${S0_DEC}"
  echo "    src1_decoded       = ${S1_DEC}"
  echo "    merge_decoded      = ${M_DEC}"
  echo "    merge_merged       = ${M_MRG}"
  echo "    merge_dropped      = ${M_DRP}"
  echo "    stage5_input       = ${S5_IN}"
  echo "    stage5_encoded     = ${S5_ENC}"
  echo "    stage5_written     = ${S5_WR}"
  echo "    sstable_count      = ${SST_COUNT}"
  echo "    perf_cycles        = ${PERF_CYCLES}"

  # Print SSTable sizes
  for ((j=0; j<MAX_SSTABLES; j++)); do
    local off v
    off="$(python3 -c "print(hex(int('${REG_SSTABLE_SIZES_BASE}',0)+$j*4))")"
    v="$(reg_read "$off")"
    if [[ $((v)) -gt 0 ]]; then
      echo "    sstable_size[$j]    = ${v}"
    fi
  done

  # Verify
  local FAIL=0

  check_eq() {
    local name="$1" got="$2" exp="$3"
    if [[ $(($got)) -ne $(($exp)) ]]; then
      echo "  FAIL: ${name}=${got} expected=${exp}" >&2
      FAIL=1
    else
      echo "    CHECK ${name} = ${got}  OK"
    fi
  }

  check_gte() {
    local name="$1" got="$2" min="$3"
    if [[ $(($got)) -lt $(($min)) ]]; then
      echo "  FAIL: ${name}=${got} expected >= ${min}" >&2
      FAIL=1
    else
      echo "    CHECK ${name} = ${got} >= ${min}  OK"
    fi
  }

  check_gt0() {
    local name="$1" got="$2"
    if [[ $(($got)) -le 0 ]]; then
      echo "  FAIL: ${name}=${got} expected > 0" >&2
      FAIL=1
    else
      echo "    CHECK ${name} = ${got} > 0  OK"
    fi
  }

  check_eq  "block_pair_count" "$PAIR_COUNT" "$EXP_PAIRS"
  check_eq  "src0_decoded"     "$S0_DEC"     "$EXP_S0_DEC"
  check_eq  "src1_decoded"     "$S1_DEC"     "$EXP_S1_DEC"
  check_eq  "merge_decoded"    "$M_DEC"      "$EXP_M_DEC"
  check_eq  "merge_merged"     "$M_MRG"      "$EXP_M_MRG"
  check_eq  "merge_dropped"    "$M_DRP"      "$EXP_M_DRP"
  check_eq  "stage5_input"     "$S5_IN"      "$EXP_M_MRG"
  check_eq  "stage5_encoded"   "$S5_ENC"     "$EXP_M_MRG"
  check_gt0 "stage5_written"   "$S5_WR"
  check_gte "sstable_count"    "$SST_COUNT"  "$EXP_MIN_SST"

  # Accounting identity: merge_decoded = merge_merged + merge_dropped
  local M_SUM=$(( $(($M_MRG)) + $(($M_DRP)) ))
  if [[ $(($M_DEC)) -ne ${M_SUM} ]]; then
    echo "  FAIL: merge accounting: dec=${M_DEC} != mrg+drp=${M_SUM}" >&2
    FAIL=1
  else
    echo "    CHECK merge_dec == mrg+drp  OK"
  fi

  # Step 7: Read back output SSTables from DDR
  # The streaming engine writes blocks contiguously within each SSTable.
  # After auto-split, SSTable[i] starts at DST_BASE + cumulative aligned offsets.
  echo "  [7] Reading back output SSTables"
  local N_SST=$(($SST_COUNT))
  local TOTAL_DST_BYTES=0
  local SST_OFFSET=0

  for ((j=0; j<N_SST && j<MAX_SSTABLES; j++)); do
    local sst_size_off sst_bytes
    sst_size_off="$(python3 -c "print(hex(int('${REG_SSTABLE_SIZES_BASE}',0)+$j*4))")"
    sst_bytes="$(reg_read "$sst_size_off")"
    if [[ $(($sst_bytes)) -le 0 ]]; then
      echo "  FAIL: sstable_size[$j]=${sst_bytes} expected > 0" >&2
      FAIL=1
      continue
    fi
    local sst_addr aligned outfile
    sst_addr="$(python3 -c "print(hex(int('${DST_BASE_ADDR_DEFAULT}',0)+$SST_OFFSET))")"
    aligned="$(align64 "$sst_bytes")"
    outfile="${WORKDIR}/dst_${LABEL// /_}_sst_${j}.bin"
    vlog "sst[$j] addr=${sst_addr} size=${sst_bytes} (aligned=${aligned})"
    "$DMA_FROM" -d "$C2H_DEV" -a "$sst_addr" -s "$((aligned))" -f "$outfile"

    # Verify output is not all sentinel (0xA5)
    python3 - "$outfile" "$sst_bytes" "$j" <<'PY'
import sys, struct, pathlib
path, size_s, idx_s = sys.argv[1:4]
sz = int(size_s, 0); idx = int(idx_s)
data = pathlib.Path(path).read_bytes()
if len(data) < sz:
    raise SystemExit(f"FAIL: sst[{idx}] readback too short: {len(data)} < {sz}")
sst = data[:sz]
if all(b == 0xA5 for b in sst):
    raise SystemExit(f"FAIL: sst[{idx}] all sentinel — data not written")
# Check LevelDB footer magic at end of SSTable
if sz >= 48:
    magic = struct.unpack_from('<Q', sst, sz - 8)[0]
    if magic == 0xdb4775248b80fb57:
        print(f"    sst[{idx}]: {sz} bytes  footer magic OK")
    else:
        print(f"    sst[{idx}]: {sz} bytes  (no footer magic — data blocks only)")
else:
    print(f"    sst[{idx}]: {sz} bytes  (too small for footer check)")
PY
    if [[ $? -ne 0 ]]; then
      FAIL=1
    fi
    TOTAL_DST_BYTES=$(( TOTAL_DST_BYTES + $(($sst_bytes)) ))
    # Next SSTable starts after this one, 64-byte aligned
    SST_OFFSET=$(( $(python3 -c "print(((${SST_OFFSET}+$(($sst_bytes))+63)//64)*64)") ))
  done

  # Summary
  local SRC_BYTES=$(( SRC0_SIZE + SRC1_SIZE ))
  if [[ "$FAIL" -eq 0 ]]; then
    local DST_RATE SRC_RATE
    DST_RATE="$(python3 -c "print(f'{$TOTAL_DST_BYTES/1024/1024/max(1,$ELAPSED_MS/1000):.3f}')")"
    SRC_RATE="$(python3 -c "print(f'{$SRC_BYTES/1024/1024/max(1,$ELAPSED_MS/1000):.3f}')")"
    echo ""
    echo "  PASS [${LABEL}]"
    echo "    elapsed            = ${ELAPSED_MS} ms"
    echo "    perf_cycles        = ${PERF_CYCLES}"
    echo "    block_pairs        = ${PAIR_COUNT}"
    echo "    src_bytes          = ${SRC_BYTES}  (${SRC_RATE} MiB/s)"
    echo "    dst_bytes          = ${TOTAL_DST_BYTES}  (${DST_RATE} MiB/s)"
    echo "    merge keep/drop    = ${M_MRG}/${M_DRP}"
    echo "    sstable_count      = ${SST_COUNT}"
    return 0
  else
    echo ""
    echo "  FAIL [${LABEL}]: some checks failed" >&2
    dump_regs
    return 1
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# Main test loop
# ══════════════════════════════════════════════════════════════════════════
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_PHASES=0

for ((iter=1; iter<=ITERATIONS; iter++)); do

  echo ""
  echo "################################################################"
  echo "#  Iteration ${iter}/${ITERATIONS}"
  echo "################################################################"

  # ── Phase A: Large SSTable (12 blocks, auto-split) ──────────────────
  # SRC0: 12 blocks × 4 records = 48 records
  # SRC1: 12 blocks × 4 records = 48 records  (8 duplicate keys → dropped)
  # Expected: 12 pairs, 96 decoded, 88 merged, 8 dropped, ≥2 output SSTables
  if run_phase \
      "Phase A: 12-pair streaming (iter ${iter})" \
      "$LARGE_SRC0" "$LARGE_SRC1" \
      "0x0" \
      12 48 48 96 88 8 2; then
    TOTAL_PASS=$(( TOTAL_PASS + 1 ))
  else
    TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
  fi
  TOTAL_PHASES=$(( TOTAL_PHASES + 1 ))

  # ── Phase B: Immediate back-to-back re-run (same data) ─────────────
  # Tests that the engine can be restarted immediately without issues
  if run_phase \
      "Phase B: back-to-back re-run (iter ${iter})" \
      "$LARGE_SRC0" "$LARGE_SRC1" \
      "0x0" \
      12 48 48 96 88 8 2; then
    TOTAL_PASS=$(( TOTAL_PASS + 1 ))
  else
    TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
  fi
  TOTAL_PHASES=$(( TOTAL_PHASES + 1 ))

  # ── Phase C: Small SSTable (sanity after large run) ───────────────
  # Uses the pre-existing generated SSTable pair (4 blocks each).
  # Key overlap is unknown → only check sanity, not exact merge counts.
  if [[ -f "$SMALL_SRC0_DEFAULT" && -f "$SMALL_SRC1_DEFAULT" ]]; then
    echo ""
    echo "============================================================"
    echo "  Phase C: small SSTable sanity (iter ${iter})"
    echo "  SRC0: $(basename "$SMALL_SRC0_DEFAULT")  $(stat -c%s "$SMALL_SRC0_DEFAULT") bytes"
    echo "  SRC1: $(basename "$SMALL_SRC1_DEFAULT")  $(stat -c%s "$SMALL_SRC1_DEFAULT") bytes"
    echo "============================================================"

    reg_write "$REG_CTRL" 0x2; sleep 0.010; reg_write "$REG_CTRL" 0x0; sleep 0.010

    C_SRC0_SIZE="$(stat -c%s "$SMALL_SRC0_DEFAULT")"
    C_SRC1_SIZE="$(stat -c%s "$SMALL_SRC1_DEFAULT")"

    C_DST_INIT="$(python3 -c "print(int('${DST_BLOCK_STRIDE_DEFAULT}',0)*$MAX_BLOCK_PAIRS)")"
    C_MID_INIT="$(python3 -c "print(int('${MID_SIZE_DEFAULT}',0))")"
    C_SEN="${WORKDIR}/csen.bin"
    C_MAX=$(( C_DST_INIT > C_MID_INIT ? C_DST_INIT : C_MID_INIT ))
    python3 -c "open('${C_SEN}','wb').write(bytes([0xA5]*${C_MAX}))"
    "$DMA_TO" -d "$H2C_DEV" -a "${DST_BASE_ADDR_DEFAULT}" -s "${C_DST_INIT}" -f "$C_SEN"
    "$DMA_TO" -d "$H2C_DEV" -a "${MID_ADDR_DEFAULT}"      -s "${C_MID_INIT}" -f "$C_SEN"

    "$DMA_TO" -d "$H2C_DEV" -a "${SRC0_DDR_ADDR_DEFAULT}" -s "$C_SRC0_SIZE" -f "$SMALL_SRC0_DEFAULT"
    "$DMA_TO" -d "$H2C_DEV" -a "${SRC1_DDR_ADDR_DEFAULT}" -s "$C_SRC1_SIZE" -f "$SMALL_SRC1_DEFAULT"

    reg_write "$REG_SRC0_BASE_LO" "$(split_lo "$SRC0_DDR_ADDR_DEFAULT")"
    reg_write "$REG_SRC0_BASE_HI" "$(split_hi "$SRC0_DDR_ADDR_DEFAULT")"
    reg_write "$REG_SRC0_SIZE"    "$(python3 -c "print(hex($C_SRC0_SIZE))")"
    reg_write "$REG_SRC1_BASE_LO" "$(split_lo "$SRC1_DDR_ADDR_DEFAULT")"
    reg_write "$REG_SRC1_BASE_HI" "$(split_hi "$SRC1_DDR_ADDR_DEFAULT")"
    reg_write "$REG_SRC1_SIZE"    "$(python3 -c "print(hex($C_SRC1_SIZE))")"
    reg_write "$REG_DST_BASE_LO"  "$(split_lo "$DST_BASE_ADDR_DEFAULT")"
    reg_write "$REG_DST_BASE_HI"  "$(split_hi "$DST_BASE_ADDR_DEFAULT")"
    reg_write "$REG_DST_BLOCK_STRIDE" "${DST_BLOCK_STRIDE_DEFAULT}"
    reg_write "$REG_MID_BASE_LO"  "$(split_lo "$MID_ADDR_DEFAULT")"
    reg_write "$REG_MID_BASE_HI"  "$(split_hi "$MID_ADDR_DEFAULT")"
    reg_write "$REG_MAX_FILE_SIZE" "0x0"

    C_T0="$(now_ms)"
    reg_write "$REG_CTRL" 0x1; reg_write "$REG_CTRL" 0x0

    c_done=0
    for ((ci=0; ci<150; ci++)); do
      cs="$(reg_read "$REG_STATUS")"; cs="${cs:-0x0}"
      if (( ($(($cs)) >> 2) & 1 )); then
        dump_regs
        echo "  FAIL [Phase C]: engine error status=${cs}" >&2
        TOTAL_FAIL=$(( TOTAL_FAIL + 1 )); TOTAL_PHASES=$(( TOTAL_PHASES + 1 ))
        continue 2  # next iteration
      fi
      if (( ($(($cs)) >> 1) & 1 )); then c_done=1; break; fi
      sleep 0.2
    done
    C_T1="$(now_ms)"
    C_ELAPSED=$(( C_T1 - C_T0 ))

    if [[ "$c_done" -ne 1 ]]; then
      dump_regs
      echo "  FAIL [Phase C]: timeout after ${C_ELAPSED}ms" >&2
      TOTAL_FAIL=$(( TOTAL_FAIL + 1 )); TOTAL_PHASES=$(( TOTAL_PHASES + 1 ))
      continue
    fi

    # Relaxed sanity checks
    C_FAIL=0
    C_PC="$(reg_read "$REG_BLOCK_PAIR_COUNT_OUT")"
    C_S0="$(reg_read "$REG_TOTAL_SRC0_DECODED")"
    C_S1="$(reg_read "$REG_TOTAL_SRC1_DECODED")"
    C_MD="$(reg_read "$REG_TOTAL_MERGE_DECODED")"
    C_MM="$(reg_read "$REG_TOTAL_MERGE_MERGED")"
    C_MDP="$(reg_read "$REG_TOTAL_MERGE_DROPPED")"
    C_S5W="$(reg_read "$REG_TOTAL_STAGE5_BYTES_WRITTEN")"

    echo "    block_pair_count = ${C_PC}"
    echo "    src0_decoded     = ${C_S0}"
    echo "    src1_decoded     = ${C_S1}"
    echo "    merge_decoded    = ${C_MD}  merged=${C_MM}  dropped=${C_MDP}"
    echo "    stage5_written   = ${C_S5W}"
    echo "    elapsed          = ${C_ELAPSED} ms"

    if [[ $(($C_PC)) -le 0 ]]; then echo "  FAIL: pair_count=0" >&2; C_FAIL=1; fi
    if [[ $(($C_S0)) -le 0 ]]; then echo "  FAIL: src0_decoded=0" >&2; C_FAIL=1; fi
    if [[ $(($C_S1)) -le 0 ]]; then echo "  FAIL: src1_decoded=0" >&2; C_FAIL=1; fi
    if [[ $(($C_S5W)) -le 0 ]]; then echo "  FAIL: stage5_written=0" >&2; C_FAIL=1; fi
    C_SUM=$(( $(($C_MM)) + $(($C_MDP)) ))
    if [[ $(($C_MD)) -ne ${C_SUM} ]]; then
      echo "  FAIL: accounting dec=${C_MD} != mrg+drp=${C_SUM}" >&2; C_FAIL=1
    fi

    if [[ "$C_FAIL" -eq 0 ]]; then
      echo "  PASS [Phase C]"
      TOTAL_PASS=$(( TOTAL_PASS + 1 ))
    else
      echo "  FAIL [Phase C]: sanity checks failed" >&2
      TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
    fi
    TOTAL_PHASES=$(( TOTAL_PHASES + 1 ))
  else
    echo ""
    echo "  SKIP Phase C: small SSTable files not found"
  fi

done

# ── Final summary ─────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  STREAMING PIPELINE BOARD TEST SUMMARY"
echo "================================================================"
echo "  Iterations:  ${ITERATIONS}"
echo "  Phases:      ${TOTAL_PHASES}"
echo "  Passed:      ${TOTAL_PASS}"
echo "  Failed:      ${TOTAL_FAIL}"
echo ""

if [[ "$TOTAL_FAIL" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  echo "SOME TESTS FAILED" >&2
  exit 1
fi
