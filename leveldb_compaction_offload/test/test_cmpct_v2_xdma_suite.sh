#!/bin/bash

set -euo pipefail

H2C_DEV_DEFAULT="/dev/xdma0_h2c_0"
C2H_DEV_DEFAULT="/dev/xdma0_c2h_0"
USER_DEV_DEFAULT="/dev/xdma0_user"
TOOLS_DIR_DEFAULT="/home/yh/pp4/dma_ip_drivers/XDMA/linux-kernel/tools"
SRC0_ADDR0_DEFAULT="0x00000000"
SRC1_ADDR0_DEFAULT="0x00001000"
SRC0_ADDR1_DEFAULT="0x00002000"
SRC1_ADDR1_DEFAULT="0x00003000"
SRC0_ADDR2_DEFAULT="0x00004000"
SRC1_ADDR2_DEFAULT="0x00005000"
MID_ADDR_DEFAULT="0x00006000"
DST0_ADDR_DEFAULT="0x00008000"
DST1_ADDR_DEFAULT="0x00009000"
DST2_ADDR_DEFAULT="0x0000A000"
AXIL_BASE_DEFAULT="0x00000000"
SOURCE_RESTART_INTERVAL_DEFAULT="1"
RESTART_INTERVAL_DEFAULT="16"
SCENARIOS_DEFAULT="focused_three_block_smoke,single_pair_only_smoke,two_pair_cross_boundary_smoke,three_block_duplicate_ladder,three_block_many_group_mix,three_block_large_value_mix,three_block_delete_heavy_mix,three_block_zero_keep_middle,three_block_one_sided_empty_mix,three_block_long_shared_prefix,three_block_leading_empty_pairs"
TIMEOUT_MS_DEFAULT="10000"
POLL_INTERVAL_MS_DEFAULT="100"
CFG_SETTLE_MS_DEFAULT="20"
ITERATIONS_DEFAULT="1"

REG_CTRL="0x0000"
REG_STATUS="0x0004"
REG_BLOCK_PAIR_COUNT="0x0008"
REG_MID_BASE_LO="0x000C"
REG_MID_BASE_HI="0x0010"
REG_SRC0_BASE0_LO="0x0014"
REG_SRC0_BASE0_HI="0x0018"
REG_SRC0_SIZE0="0x001C"
REG_SRC1_BASE0_LO="0x0020"
REG_SRC1_BASE0_HI="0x0024"
REG_SRC1_SIZE0="0x0028"
REG_DST_BASE0_LO="0x002C"
REG_DST_BASE0_HI="0x0030"
REG_SRC0_BASE1_LO="0x0034"
REG_SRC0_BASE1_HI="0x0038"
REG_SRC0_SIZE1="0x003C"
REG_SRC1_BASE1_LO="0x0040"
REG_SRC1_BASE1_HI="0x0044"
REG_SRC1_SIZE1="0x0048"
REG_DST_BASE1_LO="0x004C"
REG_DST_BASE1_HI="0x0050"
REG_ACTIVE_BLOCK_INDEX="0x0054"
REG_BLOCKS_COMPLETED="0x0058"
REG_DST0_OUTPUT_BLOCK_BYTES="0x005C"
REG_DST1_OUTPUT_BLOCK_BYTES="0x0060"
REG_TOTAL_SOURCE0_DECODED_ENTRY_COUNT="0x0064"
REG_TOTAL_SOURCE1_DECODED_ENTRY_COUNT="0x0068"
REG_TOTAL_SOURCE0_BYTES_READ="0x006C"
REG_TOTAL_SOURCE1_BYTES_READ="0x0070"
REG_TOTAL_MERGE_OUTPUT_BYTE_COUNT="0x0074"
REG_TOTAL_MERGE_DECODED_RECORD_COUNT="0x0078"
REG_TOTAL_MERGE_MERGED_RECORD_COUNT="0x007C"
REG_TOTAL_MERGE_DROPPED_COUNT="0x0080"
REG_TOTAL_STAGE5_INPUT_RECORD_COUNT="0x0084"
REG_TOTAL_STAGE5_ENCODED_ENTRY_COUNT="0x0088"
REG_TOTAL_STAGE5_OUTPUT_BLOCK_BYTES="0x008C"
REG_TOTAL_STAGE5_BYTES_WRITTEN="0x0090"
REG_PERF_CYCLE_COUNT="0x0094"
REG_DESC_BASE="0x0100"
REG_DESC_STRIDE="0x0020"
REG_DESC_SRC0_BASE_LO_OFF="0x0000"
REG_DESC_SRC0_BASE_HI_OFF="0x0004"
REG_DESC_SRC0_SIZE_OFF="0x0008"
REG_DESC_SRC1_BASE_LO_OFF="0x000C"
REG_DESC_SRC1_BASE_HI_OFF="0x0010"
REG_DESC_SRC1_SIZE_OFF="0x0014"
REG_DESC_DST_BASE_LO_OFF="0x0018"
REG_DESC_DST_BASE_HI_OFF="0x001C"
REG_DESC_DST_OUTPUT_BYTES_BASE="0x0200"

usage() {
  cat <<EOF
Usage: $0 [options]  (v2 mid-DDR-bypass build)

Options:
  -w <h2c_dev>         H2C device node (default: ${H2C_DEV_DEFAULT})
  -r <c2h_dev>         C2H device node (default: ${C2H_DEV_DEFAULT})
  -u <user_dev>        XDMA user BAR device for AXI-Lite regs (default: ${USER_DEV_DEFAULT})
  -t <tools_dir>       Tool dir containing dma_to_device, dma_from_device, reg_rw
                       (default: ${TOOLS_DIR_DEFAULT})
  -0 <src0_addr0>      Block-pair 0 source0 DDR base (default: ${SRC0_ADDR0_DEFAULT})
  -1 <src1_addr0>      Block-pair 0 source1 DDR base (default: ${SRC1_ADDR0_DEFAULT})
  -2 <src0_addr1>      Block-pair 1 source0 DDR base (default: ${SRC0_ADDR1_DEFAULT})
  -3 <src1_addr1>      Block-pair 1 source1 DDR base (default: ${SRC1_ADDR1_DEFAULT})
  -4 <src0_addr2>      Block-pair 2 source0 DDR base (default: ${SRC0_ADDR2_DEFAULT})
  -5 <src1_addr2>      Block-pair 2 source1 DDR base (default: ${SRC1_ADDR2_DEFAULT})
  -m <mid_addr>        Shared intermediate DDR base (default: ${MID_ADDR_DEFAULT})
  -d <dst0_addr>       Block-pair 0 destination DDR base (default: ${DST0_ADDR_DEFAULT})
  -e <dst1_addr>       Block-pair 1 destination DDR base (default: ${DST1_ADDR_DEFAULT})
  -f <dst2_addr>       Block-pair 2 destination DDR base (default: ${DST2_ADDR_DEFAULT})
  -B <axil_base>       AXI-Lite base offset inside XDMA user BAR (default: ${AXIL_BASE_DEFAULT})
  -I <src_restart>     Restart interval used to build source blocks (default: ${SOURCE_RESTART_INTERVAL_DEFAULT})
  -R <dst_restart>     Expected Stage5 restart interval (default: ${RESTART_INTERVAL_DEFAULT})
  -s <scenarios>       Comma-separated scenario list (default: ${SCENARIOS_DEFAULT})
  -T <timeout_ms>      Poll timeout in ms (default: ${TIMEOUT_MS_DEFAULT})
  -P <poll_ms>         Poll interval in ms (default: ${POLL_INTERVAL_MS_DEFAULT})
  -S <settle_ms>       Wait after programming regs before start (default: ${CFG_SETTLE_MS_DEFAULT})
  -n <iterations>      Repeat the full scenario list N times for stability/performance runs
                       (default: ${ITERATIONS_DEFAULT})
  -k                   Keep temporary files
  -v                   Verbose
  -h                   Show help

Scenario names:
  - focused_three_block_smoke
  - single_pair_only_smoke
  - two_pair_cross_boundary_smoke
  - three_block_duplicate_ladder
  - three_block_many_group_mix
  - three_block_large_value_mix
  - three_block_delete_heavy_mix
  - three_block_zero_keep_middle
  - three_block_one_sided_empty_mix
  - three_block_long_shared_prefix
  - three_block_leading_empty_pairs
  - three_block_perf_dense_value_stream
  - three_block_perf_duplicate_churn
  - three_block_perf_long_prefix_stream
EOF
}

H2C_DEV="${H2C_DEV_DEFAULT}"
C2H_DEV="${C2H_DEV_DEFAULT}"
USER_DEV="${USER_DEV_DEFAULT}"
TOOLS_DIR="${TOOLS_DIR_DEFAULT}"
SRC0_ADDR0="${SRC0_ADDR0_DEFAULT}"
SRC1_ADDR0="${SRC1_ADDR0_DEFAULT}"
SRC0_ADDR1="${SRC0_ADDR1_DEFAULT}"
SRC1_ADDR1="${SRC1_ADDR1_DEFAULT}"
SRC0_ADDR2="${SRC0_ADDR2_DEFAULT}"
SRC1_ADDR2="${SRC1_ADDR2_DEFAULT}"
MID_ADDR="${MID_ADDR_DEFAULT}"
DST0_ADDR="${DST0_ADDR_DEFAULT}"
DST1_ADDR="${DST1_ADDR_DEFAULT}"
DST2_ADDR="${DST2_ADDR_DEFAULT}"
AXIL_BASE="${AXIL_BASE_DEFAULT}"
SOURCE_RESTART_INTERVAL="${SOURCE_RESTART_INTERVAL_DEFAULT}"
RESTART_INTERVAL="${RESTART_INTERVAL_DEFAULT}"
SCENARIOS="${SCENARIOS_DEFAULT}"
TIMEOUT_MS="${TIMEOUT_MS_DEFAULT}"
POLL_INTERVAL_MS="${POLL_INTERVAL_MS_DEFAULT}"
CFG_SETTLE_MS="${CFG_SETTLE_MS_DEFAULT}"
ITERATIONS="${ITERATIONS_DEFAULT}"
KEEP=0
VERBOSE=0

while getopts ":w:r:u:t:0:1:2:3:4:5:m:d:e:f:B:I:R:s:T:P:S:n:kvh" opt; do
  case "$opt" in
    w) H2C_DEV="$OPTARG" ;;
    r) C2H_DEV="$OPTARG" ;;
    u) USER_DEV="$OPTARG" ;;
    t) TOOLS_DIR="$OPTARG" ;;
    0) SRC0_ADDR0="$OPTARG" ;;
    1) SRC1_ADDR0="$OPTARG" ;;
    2) SRC0_ADDR1="$OPTARG" ;;
    3) SRC1_ADDR1="$OPTARG" ;;
    4) SRC0_ADDR2="$OPTARG" ;;
    5) SRC1_ADDR2="$OPTARG" ;;
    m) MID_ADDR="$OPTARG" ;;
    d) DST0_ADDR="$OPTARG" ;;
    e) DST1_ADDR="$OPTARG" ;;
    f) DST2_ADDR="$OPTARG" ;;
    B) AXIL_BASE="$OPTARG" ;;
    I) SOURCE_RESTART_INTERVAL="$OPTARG" ;;
    R) RESTART_INTERVAL="$OPTARG" ;;
    s) SCENARIOS="$OPTARG" ;;
    T) TIMEOUT_MS="$OPTARG" ;;
    P) POLL_INTERVAL_MS="$OPTARG" ;;
    S) CFG_SETTLE_MS="$OPTARG" ;;
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

for bin in "$DMA_TO" "$DMA_FROM" "$REG_RW"; do
  if [[ ! -x "$bin" ]]; then
    echo "ERROR: executable not found: $bin" >&2
    exit 1
  fi
done

for dev in "$H2C_DEV" "$C2H_DEV" "$USER_DEV"; do
  if [[ ! -e "$dev" ]]; then
    echo "ERROR: device not found: $dev" >&2
    exit 1
  fi
done

if ! python3 - <<PY
addrs = [
    int("$SRC0_ADDR0", 0), int("$SRC1_ADDR0", 0), int("$SRC0_ADDR1", 0), int("$SRC1_ADDR1", 0),
    int("$SRC0_ADDR2", 0), int("$SRC1_ADDR2", 0), int("$MID_ADDR", 0), int("$DST0_ADDR", 0),
    int("$DST1_ADDR", 0), int("$DST2_ADDR", 0)
]
if any(addr % 64 != 0 for addr in addrs):
    raise SystemExit(1)
if int("$SOURCE_RESTART_INTERVAL", 0) <= 0 or int("$RESTART_INTERVAL", 0) <= 0:
    raise SystemExit(1)
if int("$TIMEOUT_MS", 0) <= 0 or int("$POLL_INTERVAL_MS", 0) <= 0 or int("$CFG_SETTLE_MS", 0) < 0:
    raise SystemExit(1)
if int("$ITERATIONS", 0) <= 0:
    raise SystemExit(1)
PY
then
  echo "ERROR: addresses must be 64-byte aligned and numeric options must be valid" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() {
  if [[ "$KEEP" -eq 0 ]]; then
    rm -rf "$WORKDIR"
  else
    echo "Keeping temp files in: $WORKDIR"
  fi
}
trap cleanup EXIT

now_ns() {
  date +%s%N
}

rate_mib_s() {
  python3 - <<PY
bytes_value = int("$1", 0)
elapsed_ms = max(1, int("$2", 0))
print(f"{bytes_value / (1024.0 * 1024.0) / (elapsed_ms / 1000.0):.3f}")
PY
}

addr_add() {
  python3 - <<PY
base = int("$1", 0)
off = int("$2", 0)
print(hex(base + off))
PY
}

split_u64_lo() {
  python3 - <<PY
value = int("$1", 0)
print(hex(value & 0xffffffff))
PY
}

split_u64_hi() {
  python3 - <<PY
value = int("$1", 0)
print(hex((value >> 32) & 0xffffffff))
PY
}

desc_addr() {
  python3 - <<PY
base = int("$REG_DESC_BASE", 0)
stride = int("$REG_DESC_STRIDE", 0)
index = int("$1", 0)
off = int("$2", 0)
print(hex(base + index * stride + off))
PY
}

desc_output_addr() {
  python3 - <<PY
base = int("$REG_DESC_DST_OUTPUT_BYTES_BASE", 0)
index = int("$1", 0)
print(hex(base + index * 4))
PY
}

reg_write() {
  local addr
  addr="$(addr_add "$AXIL_BASE" "$1")"
  "$REG_RW" "$USER_DEV" "$addr" w "$2" >/dev/null
}

reg_read() {
  local addr
  addr="$(addr_add "$AXIL_BASE" "$1")"
  "$REG_RW" "$USER_DEV" "$addr" w | awk '/Read 32-bit value/ {print $NF}' | tail -n 1
}

expect_eq() {
  local name="$1"
  local actual="$2"
  local expected="$3"
  if [[ $((actual)) -ne $((expected)) ]]; then
    echo "FAIL: ${name}=${actual} expected=${expected}" >&2
    exit 1
  fi
}

verify_buffer() {
  local label="$1"
  local expected_file="$2"
  local actual_file="$3"
  local expected_bytes="$4"
  local aligned_bytes="$5"
  if python3 - "$expected_file" "$actual_file" "$expected_bytes" "$aligned_bytes" <<'PY'
import pathlib
import sys
expected_path, actual_path, expected_bytes, aligned_bytes = sys.argv[1:5]
expected = pathlib.Path(expected_path).read_bytes()
actual = pathlib.Path(actual_path).read_bytes()
expected_bytes = int(expected_bytes, 0)
aligned_bytes = int(aligned_bytes, 0)
if len(actual) < aligned_bytes:
    raise SystemExit(3)
if actual[:expected_bytes] != expected:
    raise SystemExit(1)
if any(b != 0xA5 for b in actual[expected_bytes:aligned_bytes]):
    raise SystemExit(2)
PY
  then
    return 0
  fi
  local rc=$?
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "Expected ${label}:"
    hexdump -C "$expected_file" | head -n 80 || true
    echo "Read back ${label}:"
    hexdump -C "$actual_file" | head -n 80 || true
  fi
  if [[ "$rc" -eq 2 ]]; then
    echo "FAIL: bytes beyond valid ${label} length were modified unexpectedly" >&2
  else
    echo "FAIL: ${label} bytes do not match expected output" >&2
  fi
  exit 1
}

verify_prefix() {
  local label="$1"
  local expected_file="$2"
  local actual_file="$3"
  local expected_bytes="$4"
  if python3 - "$expected_file" "$actual_file" "$expected_bytes" <<'PY'
import pathlib
import sys
expected_path, actual_path, expected_bytes = sys.argv[1:4]
expected = pathlib.Path(expected_path).read_bytes()
actual = pathlib.Path(actual_path).read_bytes()
expected_bytes = int(expected_bytes, 0)
if len(actual) < expected_bytes:
    raise SystemExit(2)
if actual[:expected_bytes] != expected[:expected_bytes]:
    raise SystemExit(1)
PY
  then
    return 0
  fi
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "Expected prefix ${label}:"
    hexdump -C "$expected_file" | head -n 80 || true
    echo "Read back ${label}:"
    hexdump -C "$actual_file" | head -n 80 || true
  fi
  echo "FAIL: ${label} prefix does not match expected output" >&2
  exit 1
}

dump_regs() {
  echo "Register snapshot:"
  for name in \
    REG_STATUS \
    REG_BLOCK_PAIR_COUNT \
    REG_ACTIVE_BLOCK_INDEX \
    REG_BLOCKS_COMPLETED \
    REG_DST0_OUTPUT_BLOCK_BYTES \
    REG_DST1_OUTPUT_BLOCK_BYTES \
    REG_TOTAL_SOURCE0_DECODED_ENTRY_COUNT \
    REG_TOTAL_SOURCE1_DECODED_ENTRY_COUNT \
    REG_TOTAL_SOURCE0_BYTES_READ \
    REG_TOTAL_SOURCE1_BYTES_READ \
    REG_TOTAL_MERGE_OUTPUT_BYTE_COUNT \
    REG_TOTAL_MERGE_DECODED_RECORD_COUNT \
    REG_TOTAL_MERGE_MERGED_RECORD_COUNT \
    REG_TOTAL_MERGE_DROPPED_COUNT \
    REG_TOTAL_STAGE5_INPUT_RECORD_COUNT \
    REG_TOTAL_STAGE5_ENCODED_ENTRY_COUNT \
    REG_TOTAL_STAGE5_OUTPUT_BLOCK_BYTES \
    REG_TOTAL_STAGE5_BYTES_WRITTEN \
    REG_PERF_CYCLE_COUNT
  do
    echo "  ${name}=$(reg_read "${!name}")"
  done
  echo "  REG_DESC_DST_OUTPUT_BYTES0=$(reg_read "$(desc_output_addr 0)")"
  echo "  REG_DESC_DST_OUTPUT_BYTES1=$(reg_read "$(desc_output_addr 1)")"
  echo "  REG_DESC_DST_OUTPUT_BYTES2=$(reg_read "$(desc_output_addr 2)")"
}

poll_until_done() {
  local poll_loops poll_sleep
  mapfile -t _POLL_PLAN < <(python3 - <<PY
import math
interval_ms = int("$POLL_INTERVAL_MS", 0)
timeout_ms = int("$TIMEOUT_MS", 0)
loops = max(1, math.ceil(timeout_ms / interval_ms))
print(loops)
print(interval_ms / 1000.0)
PY
)
  poll_loops="${_POLL_PLAN[0]}"
  poll_sleep="${_POLL_PLAN[1]}"

  for ((i=0; i<poll_loops; i++)); do
    local status_hex status_val busy_bit done_bit err_bit
    status_hex="$(reg_read "$REG_STATUS")"
    status_hex=${status_hex:-0x0}
    status_val=$((status_hex))
    busy_bit=$(( status_val & 0x1 ))
    done_bit=$(( (status_val >> 1) & 0x1 ))
    err_bit=$(( (status_val >> 2) & 0x1 ))
    if [[ "$VERBOSE" -eq 1 ]]; then
      echo "  status=${status_hex} busy=${busy_bit} done=${done_bit} err=${err_bit}"
    fi
    if (( err_bit == 1 )); then
      dump_regs
      echo "FAIL: nblock IP reported error, status=${status_hex}" >&2
      exit 1
    fi
    if (( done_bit == 1 )); then
      return 0
    fi
    if (( i == poll_loops - 1 )); then
      dump_regs
      echo "FAIL: timed out waiting for nblock completion" >&2
      exit 1
    fi
    sleep "$poll_sleep"
  done
}

generate_case() {
  local scenario="$1"
  local outdir="$2"
  python3 - "$scenario" "$outdir" "$SOURCE_RESTART_INTERVAL" "$RESTART_INTERVAL" <<'PY'
import os
import shlex
import struct
import sys

scenario = sys.argv[1]
outdir = sys.argv[2]
source_restart_interval = int(sys.argv[3], 0)
dst_restart_interval = int(sys.argv[4], 0)
beat_bytes = 64
stage4_max_block_bytes = 4096
stage5_max_payload_bytes = 4096
stage5_max_block_bytes = 4096
pair_count_capacity = 3


def tag_value(seq: int, value_type: int) -> int:
    return (seq << 8) | value_type


def tag_bytes(seq: int, value_type: int) -> bytes:
    if seq < 0 or seq >= (1 << 56):
        raise SystemExit('sequence out of range')
    if value_type not in (0, 1):
        raise SystemExit('value_type must be 0 or 1')
    return struct.pack('<Q', tag_value(seq, value_type))


def full_key(user_key: bytes, seq: int, value_type: int) -> bytes:
    return user_key + tag_bytes(seq, value_type)


def encode_varint32(value: int) -> bytes:
    if value < 0 or value > 0xFFFFFFFF:
        raise SystemExit('varint32 value out of range')
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def align_up(value: int, align: int) -> int:
    return ((value + align - 1) // align) * align


def validate_source_records(records, source_name):
    prev_user_key = None
    prev_tag = None
    for idx, (user_key, seq, value_type, value) in enumerate(records):
        if len(user_key) > 256:
            raise SystemExit(f'{source_name}: user key too long at index {idx}')
        if value_type == 0 and len(value) != 0:
            raise SystemExit(f'{source_name}: delete record carries value at index {idx}')
        fk = full_key(user_key, seq, value_type)
        if len(fk) > 264:
            raise SystemExit(f'{source_name}: full key too long at index {idx}')
        current_tag = tag_value(seq, value_type)
        if prev_user_key is not None:
            if user_key < prev_user_key:
                raise SystemExit(f'{source_name}: records not sorted by user key ascending')
            if user_key == prev_user_key and current_tag >= prev_tag:
                raise SystemExit(f'{source_name}: duplicate-key records must be sorted by internal tag descending')
        prev_user_key = user_key
        prev_tag = current_tag


def build_counted_stream(full_records):
    out = bytearray(struct.pack('<I', len(full_records)))
    for key, value in full_records:
        if len(key) > 0xFFFF or len(value) > 0xFFFF:
            raise SystemExit('key/value too long for counted-record stream')
        out += struct.pack('<H', len(key))
        out += struct.pack('<H', len(value))
        out += key
        out += value
    return bytes(out)


def encode_leveldb(full_records, restart_interval):
    out = bytearray()
    restarts = [0]
    restart_entry_count = 0
    entries_since_restart = 0
    prev_key = b''
    shared_total = 0
    unshared_total = 0
    value_total = 0
    last_key_len = 0
    last_value_len = 0
    last_shared = 0
    last_non_shared = 0
    for idx, (key, value) in enumerate(full_records):
        if idx == 0 or entries_since_restart == restart_interval:
            shared = 0
            if idx != 0:
                restarts.append(len(out))
            entries_since_restart = 0
        else:
            shared = 0
            limit = min(len(prev_key), len(key))
            while shared < limit and prev_key[shared] == key[shared]:
                shared += 1
        non_shared = len(key) - shared
        value_len = len(value)
        out += encode_varint32(shared)
        out += encode_varint32(non_shared)
        out += encode_varint32(value_len)
        out += key[shared:]
        out += value
        entries_since_restart += 1
        if shared == 0:
            restart_entry_count += 1
        shared_total += shared
        unshared_total += non_shared
        value_total += value_len
        last_key_len = len(key)
        last_value_len = value_len
        last_shared = shared
        last_non_shared = non_shared
        prev_key = key
    restart_array_offset = len(out)
    for off in restarts:
        out += struct.pack('<I', off)
    out += struct.pack('<I', len(restarts))
    return bytes(out), {
        'decoded_entry_count': len(full_records),
        'restart_count': len(restarts),
        'restart_entry_count': restart_entry_count,
        'shared_key_bytes_total': shared_total,
        'unshared_key_bytes_total': unshared_total,
        'value_bytes_total': value_total,
        'last_key_len': last_key_len,
        'last_value_len': last_value_len,
        'last_shared_bytes': last_shared,
        'last_non_shared_bytes': last_non_shared,
        'restart_array_offset': restart_array_offset,
    }


def merge_records(src0_records, src1_records, prev_user_key=None):
    all_records = []
    for user_key, seq, value_type, value in src0_records:
        all_records.append((user_key, seq, value_type, full_key(user_key, seq, value_type), value))
    for user_key, seq, value_type, value in src1_records:
        all_records.append((user_key, seq, value_type, full_key(user_key, seq, value_type), value))
    all_records.sort(key=lambda item: (item[0], -tag_value(item[1], item[2])))

    kept = []
    last_user_key = prev_user_key
    decoded_record_count = 0
    dropped_superseded_count = 0
    value_record_count = 0
    delete_record_count = 0
    user_key_bytes_total = 0
    value_bytes_total = 0
    last_user_key_len = 0
    last_sequence = 0
    last_value_type = 0
    last_record_keep = 0

    for user_key, seq, value_type, key, value in all_records:
        decoded_record_count += 1
        user_key_bytes_total += len(user_key)
        value_bytes_total += len(value)
        if value_type == 0:
            delete_record_count += 1
        else:
            value_record_count += 1
        keep = 1 if user_key != last_user_key else 0
        if keep:
            kept.append((key, value))
        else:
            dropped_superseded_count += 1
        last_user_key = user_key
        last_user_key_len = len(user_key)
        last_sequence = seq
        last_value_type = value_type
        last_record_keep = keep

    return kept, {
        'decoded_record_count': decoded_record_count,
        'merged_record_count': len(kept),
        'dropped_superseded_count': dropped_superseded_count,
        'value_record_count': value_record_count,
        'delete_record_count': delete_record_count,
        'user_key_bytes_total': user_key_bytes_total,
        'value_bytes_total': value_bytes_total,
        'last_user_key_len': last_user_key_len,
        'last_sequence': last_sequence,
        'last_value_type': last_value_type,
        'last_record_keep': last_record_keep,
        'final_prev_user_key': last_user_key,
    }


def build_focused_three_block_smoke():
    return {
        'description': 'Focused 3-block scenario validated in simulation and board bring-up, including descriptor index 2',
        'block_pair_count': 3,
        'pairs': [
            (
                [
                    (b'ant', 100, 1, b'A'),
                    (b'cat', 95, 1, b'a'),
                ],
                [
                    (b'bee', 110, 1, b'B'),
                    (b'cat', 97, 1, b'X'),
                ],
            ),
            (
                [
                    (b'cat', 94, 1, b'old'),
                    (b'dog', 90, 1, b'D'),
                ],
                [
                    (b'cat', 93, 1, b'older'),
                    (b'eel', 80, 1, b'E'),
                ],
            ),
            (
                [
                    (b'eel', 79, 1, b'p'),
                ],
                [
                    (b'fox', 70, 1, b'F'),
                ],
            ),
        ],
    }


def build_single_pair_only_smoke():
    return {
        'description': 'Single block-pair execution; pair1 and pair2 descriptors remain unused',
        'block_pair_count': 1,
        'pairs': [
            (
                [
                    (b'ant', 50, 1, b'A'),
                    (b'cat', 40, 1, b'C'),
                ],
                [
                    (b'bee', 60, 1, b'B'),
                    (b'cat', 39, 0, b''),
                    (b'dog', 30, 1, b'D'),
                ],
            ),
            ([], []),
            ([], []),
        ],
    }


def build_two_pair_cross_boundary_smoke():
    return {
        'description': 'Two-block smoke where duplicate suppression carries from pair0 into pair1; pair2 unused',
        'block_pair_count': 2,
        'pairs': [
            (
                [
                    (b'ant', 100, 1, b'A'),
                    (b'cat', 95, 1, b'a'),
                ],
                [
                    (b'bee', 110, 1, b'B'),
                    (b'cat', 97, 1, b'X'),
                ],
            ),
            (
                [
                    (b'cat', 94, 1, b'old'),
                    (b'dog', 90, 1, b'D'),
                ],
                [
                    (b'cat', 93, 1, b'older'),
                    (b'eel', 80, 1, b'E'),
                ],
            ),
            ([], []),
        ],
    }


def build_three_block_duplicate_ladder():
    return {
        'description': 'Boundary duplicate chains continue from pair0 into pair1 and from pair1 into pair2',
        'block_pair_count': 3,
        'pairs': [
            (
                [
                    (b'ant', 300, 1, b'A300'),
                    (b'mango', 290, 1, b'M290'),
                    (b'mango', 288, 1, b'M288'),
                ],
                [
                    (b'bee', 310, 1, b'B310'),
                    (b'mango', 291, 1, b'M291'),
                    (b'mango', 289, 0, b''),
                ],
            ),
            (
                [
                    (b'mango', 287, 1, b'M287'),
                    (b'pear', 270, 1, b'P270'),
                    (b'pear', 269, 1, b'P269'),
                ],
                [
                    (b'mango', 286, 0, b''),
                    (b'plum', 260, 1, b'U260'),
                    (b'plum', 259, 1, b'U259'),
                ],
            ),
            (
                [
                    (b'plum', 258, 1, b'U258'),
                    (b'quince', 250, 1, b'Q250'),
                    (b'quince', 249, 0, b''),
                ],
                [
                    (b'plum', 257, 0, b''),
                    (b'raisin', 240, 1, b'R240'),
                    (b'raisin', 239, 1, b'R239'),
                ],
            ),
        ],
    }


def build_three_block_many_group_mix():
    seq = 5000
    pairs = [([], []), ([], []), ([], [])]

    for group_idx in range(10):
        user_key = f'group_{group_idx:02d}_key'.encode()
        depth = 1 + (group_idx % 3)
        for version_idx in range(depth):
            value_type = 0 if (version_idx == 0 and group_idx % 4 == 0) else 1
            value = b'' if value_type == 0 else (f'A{group_idx:02d}V{version_idx}'.encode() + bytes([(0x41 + group_idx + version_idx) & 0x7F]) * (3 + (group_idx % 5)))
            record = (user_key, seq, value_type, value)
            if (group_idx + version_idx) % 2 == 0:
                pairs[0][0].append(record)
            else:
                pairs[0][1].append(record)
            seq -= 1

    boundary0 = b'group_09_key'
    pairs[1][0].append((boundary0, seq, 1, b'older_boundary_09_s0'))
    seq -= 1
    pairs[1][1].append((boundary0, seq, 0, b''))
    seq -= 1

    for group_idx in range(10, 20):
        user_key = f'group_{group_idx:02d}_key'.encode()
        depth = 1 + (group_idx % 4)
        for version_idx in range(depth):
            value_type = 0 if (version_idx == 0 and group_idx % 5 == 0) else 1
            value = b'' if value_type == 0 else (f'B{group_idx:02d}V{version_idx}'.encode() + bytes([(0x51 + group_idx + version_idx) & 0x7F]) * (4 + (group_idx % 4)))
            record = (user_key, seq, value_type, value)
            if (group_idx + version_idx) % 2 == 0:
                pairs[1][0].append(record)
            else:
                pairs[1][1].append(record)
            seq -= 1

    boundary1 = b'group_19_key'
    pairs[2][0].append((boundary1, seq, 1, b'older_boundary_19_s0'))
    seq -= 1
    pairs[2][1].append((boundary1, seq, 1, b'older_boundary_19_s1'))
    seq -= 1

    for group_idx in range(20, 30):
        user_key = f'group_{group_idx:02d}_key'.encode()
        depth = 1 + (group_idx % 3)
        for version_idx in range(depth):
            value_type = 0 if (version_idx == 0 and group_idx % 6 == 0) else 1
            value = b'' if value_type == 0 else (f'C{group_idx:02d}V{version_idx}'.encode() + bytes([(0x61 + group_idx + version_idx) & 0x7F]) * (5 + (group_idx % 3)))
            record = (user_key, seq, value_type, value)
            if (group_idx + version_idx) % 2 == 0:
                pairs[2][0].append(record)
            else:
                pairs[2][1].append(record)
            seq -= 1

    return {
        'description': 'Three-block mix of many sorted groups with duplicate carry across both block boundaries',
        'block_pair_count': 3,
        'pairs': pairs,
    }


def build_three_block_large_value_mix():
    seq = 2400
    pairs = [([], []), ([], []), ([], [])]

    for idx in range(3):
        user_key = f'blob0_{idx:02d}'.encode()
        latest = bytes([(0x41 + idx) & 0xFF]) * (180 + idx * 47)
        older = bytes([(0x61 + idx) & 0xFF]) * (96 + idx * 29)
        pairs[0][0].append((user_key, seq, 1, latest))
        seq -= 1
        pairs[0][1].append((user_key, seq, 1, older))
        seq -= 1

    boundary0 = b'blob_boundary_0'
    pairs[0][0].append((boundary0, seq, 1, b'B' * 256))
    seq -= 1
    pairs[0][1].append((boundary0, seq, 1, b'b' * 208))
    seq -= 1

    pairs[1][0].append((boundary0, seq, 1, b'C' * 192))
    seq -= 1
    pairs[1][1].append((boundary0, seq, 0, b''))
    seq -= 1

    for idx in range(3, 6):
        user_key = f'blob1_{idx:02d}'.encode()
        latest = bytes([(0x31 + idx) & 0xFF]) * (220 + idx * 33)
        pairs[1][0].append((user_key, seq, 1, latest))
        seq -= 1
        if idx % 2 == 0:
            pairs[1][1].append((user_key, seq, 0, b''))
        else:
            pairs[1][1].append((user_key, seq, 1, bytes([(0x51 + idx) & 0xFF]) * (128 + idx * 21)))
        seq -= 1

    boundary1 = b'blob_boundary_1'
    pairs[1][0].append((boundary1, seq, 1, b'D' * 300))
    seq -= 1
    pairs[1][1].append((boundary1, seq, 1, b'd' * 244))
    seq -= 1
    pairs[2][0].append((boundary1, seq, 1, b'E' * 196))
    seq -= 1
    pairs[2][1].append((boundary1, seq, 0, b''))
    seq -= 1

    for idx in range(6, 8):
        user_key = f'blob2_{idx:02d}'.encode()
        latest = bytes([(0x21 + idx) & 0xFF]) * (190 + idx * 37)
        older = bytes([(0x71 + idx) & 0xFF]) * (110 + idx * 19)
        pairs[2][0].append((user_key, seq, 1, latest))
        seq -= 1
        pairs[2][1].append((user_key, seq, 1, older))
        seq -= 1

    return {
        'description': 'Large multibeat values over three block-pairs with duplicate carry across both boundaries',
        'block_pair_count': 3,
        'pairs': pairs,
    }


def build_three_block_delete_heavy_mix():
    return {
        'description': 'Delete-heavy mix over three block-pairs with carried duplicate suppression and surviving tombstones',
        'block_pair_count': 3,
        'pairs': [
            (
                [
                    (b'ant', 900, 1, b'A900'),
                    (b'cat', 880, 0, b''),
                    (b'cat', 879, 1, b'older_cat_value'),
                ],
                [
                    (b'bee', 890, 1, b'B890'),
                    (b'cat', 881, 1, b'newer_cat_value'),
                    (b'dog', 870, 0, b''),
                ],
            ),
            (
                [
                    (b'dog', 869, 1, b'dog_old_value'),
                    (b'eel', 860, 0, b''),
                    (b'fox', 850, 1, b'F850'),
                ],
                [
                    (b'dog', 868, 0, b''),
                    (b'eel', 859, 1, b'eel_old_value'),
                    (b'gnu', 840, 1, b'G840'),
                ],
            ),
            (
                [
                    (b'gnu', 839, 1, b'gnu_old_value'),
                    (b'hare', 830, 0, b''),
                    (b'ibis', 820, 1, b'I820'),
                ],
                [
                    (b'gnu', 838, 0, b''),
                    (b'hare', 829, 1, b'hare_old_value'),
                    (b'jay', 810, 1, b'J810'),
                ],
            ),
        ],
    }


def build_three_block_zero_keep_middle():
    return {
        'description': 'Middle block-pair produces zero kept records because every record duplicates the carried boundary key',
        'block_pair_count': 3,
        'pairs': [
            (
                [
                    (b'ant', 200, 1, b'A200'),
                    (b'shared_edge', 190, 1, b'S190'),
                ],
                [
                    (b'bee', 210, 1, b'B210'),
                    (b'shared_edge', 189, 1, b'S189'),
                ],
            ),
            (
                [
                    (b'shared_edge', 188, 1, b'S188'),
                    (b'shared_edge', 186, 0, b''),
                ],
                [
                    (b'shared_edge', 187, 1, b'S187'),
                    (b'shared_edge', 185, 1, b'S185'),
                ],
            ),
            (
                [
                    (b'tiger', 180, 1, b'T180'),
                ],
                [
                    (b'whale', 170, 1, b'W170'),
                ],
            ),
        ],
    }


def build_three_block_one_sided_empty_mix():
    return {
        'description': 'Exercises near-empty one-sided pressure with one minimal legal record on the sparse side while keeping cross-block duplicate suppression active',
        'block_pair_count': 3,
        'pairs': [
            (
                [
                    (b'ant', 301, 1, b'A301_shadow'),
                ],
                [
                    (b'ant', 300, 1, b'A300'),
                    (b'cat', 290, 1, b'C290'),
                ],
            ),
            (
                [
                    (b'cat', 289, 1, b'C289'),
                    (b'dog', 280, 1, b'D280'),
                ],
                [
                    (b'dog', 281, 1, b'D281_shadow'),
                ],
            ),
            (
                [
                    (b'eel', 271, 1, b'E271_shadow'),
                ],
                [
                    (b'dog', 279, 0, b''),
                    (b'eel', 270, 1, b'E270'),
                ],
            ),
        ],
    }


def build_three_block_long_shared_prefix():
    prefix = b'prefix_' + (b'k' * 120)

    def key(suffix: bytes) -> bytes:
        return prefix + suffix

    return {
        'description': 'Long shared user-key prefixes stress counted-stream and Stage5 prefix-compression paths across block boundaries',
        'block_pair_count': 3,
        'pairs': [
            (
                [
                    (key(b'_ant'), 700, 1, b'A' * 32),
                    (key(b'_cat'), 690, 1, b'C' * 40),
                ],
                [
                    (key(b'_bee'), 710, 1, b'B' * 36),
                    (key(b'_cat'), 691, 1, b'NEWCAT' * 6),
                ],
            ),
            (
                [
                    (key(b'_cat'), 689, 1, b'oldcat' * 5),
                    (key(b'_yak'), 680, 1, b'Y' * 48),
                ],
                [
                    (key(b'_dog'), 685, 1, b'D' * 44),
                    (key(b'_yak'), 679, 0, b''),
                ],
            ),
            (
                [
                    (key(b'_yak'), 678, 1, b'older_yak' * 4),
                    (key(b'_zebra'), 670, 1, b'Z' * 52),
                ],
                [
                    (key(b'_yak'), 677, 1, b'oldest_yak' * 3),
                    (key(b'_zz_top'), 660, 1, b'TOP' * 18),
                ],
            ),
        ],
    }


def build_three_block_leading_empty_pairs():
    return {
        'description': 'First two block-pairs are reduced to minimal legal traffic and only the last block-pair emits substantial payload',
        'block_pair_count': 3,
        'pairs': [
            (
                [
                    (b'prefill0', 120, 1, b'P0'),
                ],
                [
                    (b'prefill0', 119, 1, b'P0_old'),
                ],
            ),
            (
                [
                    (b'prefill1', 110, 1, b'P1'),
                ],
                [
                    (b'prefill1', 109, 0, b''),
                ],
            ),
            (
                [
                    (b'ant', 50, 1, b'A50'),
                    (b'dog', 40, 1, b'D40'),
                ],
                [
                    (b'bee', 45, 1, b'B45'),
                    (b'cat', 42, 0, b''),
                ],
            ),
        ],
    }


def build_three_block_perf_dense_value_stream():
    seq = 5200
    pairs = [([], []), ([], []), ([], [])]

    for pair_index in range(3):
        for idx in range(6):
            key0 = f'dense_p{pair_index}_src0_{idx:02d}'.encode()
            value0 = bytes([(0x21 + pair_index + idx) & 0xFF]) * (186 + pair_index * 19 + idx * 14)
            pairs[pair_index][0].append((key0, seq, 1, value0))
            seq -= 1

            key1 = f'dense_p{pair_index}_src1_{idx:02d}'.encode()
            value1 = bytes([(0x61 + pair_index + idx) & 0xFF]) * (180 + pair_index * 17 + idx * 12)
            pairs[pair_index][1].append((key1, seq, 1, value1))
            seq -= 1

        shared_key = f'dense_shared_{pair_index:02d}'.encode()
        pairs[pair_index][0].append((shared_key, seq, 1, bytes([(0x31 + pair_index) & 0xFF]) * (204 + pair_index * 15)))
        seq -= 1
        pairs[pair_index][1].append((shared_key, seq, 1, bytes([(0x71 + pair_index) & 0xFF]) * (132 + pair_index * 9)))
        seq -= 1

        if pair_index < 2:
            carry_key = f'dense_carry_{pair_index:02d}'.encode()
            pairs[pair_index][1].append((carry_key, seq, 1, bytes([(0x41 + pair_index) & 0xFF]) * (188 + pair_index * 17)))
            seq -= 1
            pairs[pair_index + 1][0].append((carry_key, seq, 0, b''))
            seq -= 1

    return {
        'description': 'Performance-oriented high-byte stream with mostly kept medium and large values across all three block-pairs',
        'block_pair_count': 3,
        'pairs': pairs,
    }


def build_three_block_perf_duplicate_churn():
    seq = 4300
    pairs = [([], []), ([], []), ([], [])]

    for pair_index in range(3):
        for idx in range(7):
            user_key = f'churn_p{pair_index}_key_{idx:02d}'.encode()
            latest = bytes([(0x11 + pair_index + idx) & 0xFF]) * (154 + pair_index * 15 + idx * 11)
            pairs[pair_index][0].append((user_key, seq, 1, latest))
            seq -= 1

            if idx % 3 == 0:
                pairs[pair_index][1].append((user_key, seq, 0, b''))
            else:
                stale = bytes([(0x81 + pair_index + idx) & 0xFF]) * (92 + pair_index * 9 + idx * 7)
                pairs[pair_index][1].append((user_key, seq, 1, stale))
            seq -= 1

        if pair_index < 2:
            carry_key = f'churn_edge_{pair_index:02d}'.encode()
            pairs[pair_index][0].append((carry_key, seq, 1, bytes([(0x51 + pair_index) & 0xFF]) * (164 + pair_index * 15)))
            seq -= 1
            pairs[pair_index][1].append((carry_key, seq, 1, bytes([(0x91 + pair_index) & 0xFF]) * (84 + pair_index * 11)))
            seq -= 1
            pairs[pair_index + 1][1].append((carry_key, seq, 0, b''))
            seq -= 1

    return {
        'description': 'Performance-oriented duplicate churn with many superseded records, deletes, and carried boundary drops',
        'block_pair_count': 3,
        'pairs': pairs,
    }


def build_three_block_perf_long_prefix_stream():
    prefix = b'perf_prefix_' + (b'x' * 72)

    def key(pair_index: int, bucket: str, idx: int) -> bytes:
        return prefix + f'_p{pair_index}_{bucket}_{idx:02d}'.encode()

    seq = 3400
    pairs = [([], []), ([], []), ([], [])]

    for pair_index in range(3):
        for idx in range(4):
            pairs[pair_index][0].append((key(pair_index, 'a', idx), seq, 1, bytes([(0x21 + pair_index + idx) & 0xFF]) * (132 + pair_index * 12 + idx * 10)))
            seq -= 1
            pairs[pair_index][1].append((key(pair_index, 'b', idx), seq, 1, bytes([(0x61 + pair_index + idx) & 0xFF]) * (136 + pair_index * 13 + idx * 9)))
            seq -= 1

        shared_key = prefix + f'_shared_{pair_index:02d}'.encode()
        pairs[pair_index][0].append((shared_key, seq, 1, bytes([(0x31 + pair_index) & 0xFF]) * (180 + pair_index * 14)))
        seq -= 1
        pairs[pair_index][1].append((shared_key, seq, 1, bytes([(0x71 + pair_index) & 0xFF]) * (124 + pair_index * 8)))
        seq -= 1

        if pair_index < 2:
            carry_key = prefix + f'_carry_{pair_index:02d}'.encode()
            pairs[pair_index][1].append((carry_key, seq, 1, bytes([(0x41 + pair_index) & 0xFF]) * (156 + pair_index * 12)))
            seq -= 1
            pairs[pair_index + 1][0].append((carry_key, seq, 0, b''))
            seq -= 1

    return {
        'description': 'Performance-oriented long-prefix stream with larger counted-stream payloads and Stage5 prefix-compression pressure',
        'block_pair_count': 3,
        'pairs': pairs,
    }


cases = {
    'focused_three_block_smoke': build_focused_three_block_smoke,
    'single_pair_only_smoke': build_single_pair_only_smoke,
    'two_pair_cross_boundary_smoke': build_two_pair_cross_boundary_smoke,
    'three_block_duplicate_ladder': build_three_block_duplicate_ladder,
    'three_block_many_group_mix': build_three_block_many_group_mix,
    'three_block_large_value_mix': build_three_block_large_value_mix,
    'three_block_delete_heavy_mix': build_three_block_delete_heavy_mix,
    'three_block_zero_keep_middle': build_three_block_zero_keep_middle,
    'three_block_one_sided_empty_mix': build_three_block_one_sided_empty_mix,
    'three_block_long_shared_prefix': build_three_block_long_shared_prefix,
    'three_block_leading_empty_pairs': build_three_block_leading_empty_pairs,
    'three_block_perf_dense_value_stream': build_three_block_perf_dense_value_stream,
    'three_block_perf_duplicate_churn': build_three_block_perf_duplicate_churn,
    'three_block_perf_long_prefix_stream': build_three_block_perf_long_prefix_stream,
}

if scenario not in cases:
    raise SystemExit(f'unknown scenario: {scenario}')

case = cases[scenario]()
block_pair_count = case['block_pair_count']
pairs = case['pairs']
if block_pair_count < 1 or block_pair_count > pair_count_capacity:
    raise SystemExit('block_pair_count out of range for host suite')
if len(pairs) != pair_count_capacity:
    raise SystemExit('cases must provide exactly 3 pairs for this host suite')

normalized_pairs = []
for pair_index, (src0_records, src1_records) in enumerate(pairs):
    src0_records = sorted(src0_records, key=lambda item: (item[0], -tag_value(item[1], item[2])))
    src1_records = sorted(src1_records, key=lambda item: (item[0], -tag_value(item[1], item[2])))
    if pair_index < block_pair_count:
        validate_source_records(src0_records, f'pair{pair_index}_src0')
        validate_source_records(src1_records, f'pair{pair_index}_src1')
    elif src0_records or src1_records:
        raise SystemExit(f'unused pair{pair_index} must be empty for scenario {scenario}')
    normalized_pairs.append((src0_records, src1_records))

src_blocks = []
expected_dsts = []
expected_mids = []
merge_metrics_list = []
prev_user_key = None
aggregate = {
    'source0_decoded_entry_count': 0,
    'source1_decoded_entry_count': 0,
    'source0_bytes_read': 0,
    'source1_bytes_read': 0,
    'merge_output_byte_count': 0,
    'merge_decoded_record_count': 0,
    'merge_merged_record_count': 0,
    'merge_dropped_count': 0,
    'stage5_input_record_count': 0,
    'stage5_encoded_entry_count': 0,
    'stage5_output_block_bytes': 0,
    'stage5_bytes_written': 0,
}

for pair_index, (src0_records, src1_records) in enumerate(normalized_pairs):
    if pair_index < block_pair_count:
        src0_full = [(full_key(user_key, seq, value_type), value) for user_key, seq, value_type, value in src0_records]
        src1_full = [(full_key(user_key, seq, value_type), value) for user_key, seq, value_type, value in src1_records]
        src0_block, src0_metric = encode_leveldb(src0_full, source_restart_interval)
        src1_block, src1_metric = encode_leveldb(src1_full, source_restart_interval)
        if len(src0_block) > stage4_max_block_bytes:
            raise SystemExit(f'scenario {scenario}: pair{pair_index} src0 block {len(src0_block)} exceeds STAGE4_MAX_BLOCK_BYTES')
        if len(src1_block) > stage4_max_block_bytes:
            raise SystemExit(f'scenario {scenario}: pair{pair_index} src1 block {len(src1_block)} exceeds STAGE4_MAX_BLOCK_BYTES')
        kept_records, merge_metrics = merge_records(src0_records, src1_records, prev_user_key)
        mid = build_counted_stream(kept_records)
        dst, _ = encode_leveldb(kept_records, dst_restart_interval)
        prev_user_key = merge_metrics['final_prev_user_key']
        if len(mid) > stage5_max_payload_bytes:
            raise SystemExit(f'scenario {scenario}: pair{pair_index} mid payload {len(mid)} exceeds STAGE5_MAX_PAYLOAD_BYTES')
        if len(dst) > stage5_max_block_bytes:
            raise SystemExit(f'scenario {scenario}: pair{pair_index} dst block {len(dst)} exceeds STAGE5_MAX_BLOCK_BYTES')
        src_blocks.append((src0_block, src1_block))
        expected_mids.append(mid)
        expected_dsts.append(dst)
        merge_metrics_list.append(merge_metrics)
        aggregate['source0_decoded_entry_count'] += src0_metric['decoded_entry_count']
        aggregate['source1_decoded_entry_count'] += src1_metric['decoded_entry_count']
        aggregate['source0_bytes_read'] += len(src0_block)
        aggregate['source1_bytes_read'] += len(src1_block)
        aggregate['merge_output_byte_count'] += sum(len(k) + len(v) for k, v in kept_records)
        aggregate['merge_decoded_record_count'] += merge_metrics['decoded_record_count']
        aggregate['merge_merged_record_count'] += merge_metrics['merged_record_count']
        aggregate['merge_dropped_count'] += merge_metrics['dropped_superseded_count']
        aggregate['stage5_input_record_count'] += len(kept_records)
        aggregate['stage5_encoded_entry_count'] += len(kept_records)
        aggregate['stage5_output_block_bytes'] += len(dst)
        aggregate['stage5_bytes_written'] += len(dst)
    else:
        src_blocks.append((b'', b''))
        expected_mids.append(b'')
        expected_dsts.append(b'')
        merge_metrics_list.append({
            'decoded_record_count': 0,
            'merged_record_count': 0,
            'dropped_superseded_count': 0,
            'final_prev_user_key': prev_user_key,
        })

os.makedirs(outdir, exist_ok=True)
for pair_index, ((src0_block, src1_block), dst_block, mid_block) in enumerate(zip(src_blocks, expected_dsts, expected_mids)):
    with open(os.path.join(outdir, f'src0_block{pair_index}.bin'), 'wb') as f:
        f.write(src0_block)
    with open(os.path.join(outdir, f'src1_block{pair_index}.bin'), 'wb') as f:
        f.write(src1_block)
    with open(os.path.join(outdir, f'expected_dst{pair_index}.bin'), 'wb') as f:
        f.write(dst_block)
    with open(os.path.join(outdir, f'expected_mid{pair_index}.bin'), 'wb') as f:
        f.write(mid_block)

final_mid = expected_mids[block_pair_count - 1]
mid_read_bytes = max(beat_bytes, align_up(len(final_mid), beat_bytes))
dst_read_bytes = [max(beat_bytes, align_up(len(block), beat_bytes)) for block in expected_dsts]

with open(os.path.join(outdir, 'mid_init.bin'), 'wb') as f:
    f.write(bytes([0xA5]) * mid_read_bytes)
for pair_index, read_bytes in enumerate(dst_read_bytes):
    with open(os.path.join(outdir, f'dst{pair_index}_init.bin'), 'wb') as f:
        f.write(bytes([0xA5]) * read_bytes)

with open(os.path.join(outdir, 'meta.env'), 'w', encoding='utf-8') as f:
    f.write(f'SCENARIO={shlex.quote(scenario)}\n')
    f.write(f'DESCRIPTION={shlex.quote(case["description"])}\n')
    f.write(f'BLOCK_PAIR_COUNT={block_pair_count}\n')
    for pair_index in range(pair_count_capacity):
        f.write(f'SRC0_BYTE_COUNT{pair_index}={len(src_blocks[pair_index][0])}\n')
        f.write(f'SRC1_BYTE_COUNT{pair_index}={len(src_blocks[pair_index][1])}\n')
        f.write(f'EXPECTED_DST{pair_index}_BYTES={len(expected_dsts[pair_index])}\n')
        f.write(f'DST{pair_index}_READ_BYTES={dst_read_bytes[pair_index]}\n')
        f.write(f'PAIR{pair_index}_KEEP={merge_metrics_list[pair_index]["merged_record_count"]}\n')
        f.write(f'PAIR{pair_index}_DROP={merge_metrics_list[pair_index]["dropped_superseded_count"]}\n')
    f.write(f'EXPECTED_FINAL_MID_BYTES={len(final_mid)}\n')
    f.write(f'MID_READ_BYTES={mid_read_bytes}\n')
    f.write(f'TOTAL_SOURCE0_DECODED_ENTRY_COUNT={aggregate["source0_decoded_entry_count"]}\n')
    f.write(f'TOTAL_SOURCE1_DECODED_ENTRY_COUNT={aggregate["source1_decoded_entry_count"]}\n')
    f.write(f'TOTAL_SOURCE0_BYTES_READ={aggregate["source0_bytes_read"]}\n')
    f.write(f'TOTAL_SOURCE1_BYTES_READ={aggregate["source1_bytes_read"]}\n')
    f.write(f'TOTAL_MERGE_OUTPUT_BYTE_COUNT={aggregate["merge_output_byte_count"]}\n')
    f.write(f'TOTAL_MERGE_DECODED_RECORD_COUNT={aggregate["merge_decoded_record_count"]}\n')
    f.write(f'TOTAL_MERGE_MERGED_RECORD_COUNT={aggregate["merge_merged_record_count"]}\n')
    f.write(f'TOTAL_MERGE_DROPPED_COUNT={aggregate["merge_dropped_count"]}\n')
    f.write(f'TOTAL_STAGE5_INPUT_RECORD_COUNT={aggregate["stage5_input_record_count"]}\n')
    f.write(f'TOTAL_STAGE5_ENCODED_ENTRY_COUNT={aggregate["stage5_encoded_entry_count"]}\n')
    f.write(f'TOTAL_STAGE5_OUTPUT_BLOCK_BYTES={aggregate["stage5_output_block_bytes"]}\n')
    f.write(f'TOTAL_STAGE5_BYTES_WRITTEN={aggregate["stage5_bytes_written"]}\n')

print(
    f'scenario={scenario} block_pairs={block_pair_count} '
    f'src0_bytes=({len(src_blocks[0][0])},{len(src_blocks[1][0])},{len(src_blocks[2][0])}) '
    f'src1_bytes=({len(src_blocks[0][1])},{len(src_blocks[1][1])},{len(src_blocks[2][1])}) '
    f'dst_bytes=({len(expected_dsts[0])},{len(expected_dsts[1])},{len(expected_dsts[2])}) '
    f'agg_keep_drop={aggregate["merge_merged_record_count"]}/{aggregate["merge_dropped_count"]}'
)
PY
}

run_case() {
  local scenario="$1"
  local case_dir="${WORKDIR}/${scenario}"
  local src0_file0 src1_file0 src0_file1 src1_file1 src0_file2 src1_file2
  local dst0_expected_file dst1_expected_file dst2_expected_file final_mid_expected_file
  local mid_init_file dst0_init_file dst1_init_file dst2_init_file
  local dst0_file dst1_file dst2_file mid_file meta_file
  local status_hex status_val done_bit err_bit
  local desc0_output desc1_output desc2_output
  local perf_cycle_count
  local case_start_ns case_end_ns elapsed_ms total_src_bytes total_dst_bytes

  case_start_ns="$(now_ns)"
  mkdir -p "$case_dir"
  generate_case "$scenario" "$case_dir"

  src0_file0="${case_dir}/src0_block0.bin"
  src1_file0="${case_dir}/src1_block0.bin"
  src0_file1="${case_dir}/src0_block1.bin"
  src1_file1="${case_dir}/src1_block1.bin"
  src0_file2="${case_dir}/src0_block2.bin"
  src1_file2="${case_dir}/src1_block2.bin"
  dst0_expected_file="${case_dir}/expected_dst0.bin"
  dst1_expected_file="${case_dir}/expected_dst1.bin"
  dst2_expected_file="${case_dir}/expected_dst2.bin"
  mid_init_file="${case_dir}/mid_init.bin"
  dst0_init_file="${case_dir}/dst0_init.bin"
  dst1_init_file="${case_dir}/dst1_init.bin"
  dst2_init_file="${case_dir}/dst2_init.bin"
  dst0_file="${case_dir}/dst0_readback.bin"
  dst1_file="${case_dir}/dst1_readback.bin"
  dst2_file="${case_dir}/dst2_readback.bin"
  mid_file="${case_dir}/mid_readback.bin"
  meta_file="${case_dir}/meta.env"

  source "$meta_file"
  final_mid_expected_file="${case_dir}/expected_mid$((BLOCK_PAIR_COUNT - 1)).bin"

  if ! python3 - <<PY
ranges = []
def add_range(base_s, size_s, name):
    size = int(size_s, 0)
    if size <= 0:
        return
    base = int(base_s, 0)
    ranges.append((base, base + size, name))
add_range("$SRC0_ADDR0", "$SRC0_BYTE_COUNT0", 'src0_pair0')
add_range("$SRC1_ADDR0", "$SRC1_BYTE_COUNT0", 'src1_pair0')
add_range("$SRC0_ADDR1", "$SRC0_BYTE_COUNT1", 'src0_pair1')
add_range("$SRC1_ADDR1", "$SRC1_BYTE_COUNT1", 'src1_pair1')
add_range("$SRC0_ADDR2", "$SRC0_BYTE_COUNT2", 'src0_pair2')
add_range("$SRC1_ADDR2", "$SRC1_BYTE_COUNT2", 'src1_pair2')
add_range("$MID_ADDR", "$MID_READ_BYTES", 'mid')
add_range("$DST0_ADDR", "$DST0_READ_BYTES", 'dst0')
add_range("$DST1_ADDR", "$DST1_READ_BYTES", 'dst1')
add_range("$DST2_ADDR", "$DST2_READ_BYTES", 'dst2')
for i in range(len(ranges)):
    for j in range(i + 1, len(ranges)):
        a0, a1, an = ranges[i]
        b0, b1, bn = ranges[j]
        if not (a1 <= b0 or b1 <= a0):
            raise SystemExit(f'overlap:{an}:{bn}')
PY
  then
    echo "ERROR: source/intermediate/destination DDR ranges overlap for scenario ${scenario}" >&2
    exit 1
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "Scenario                 : ${SCENARIO}"
    echo "Description              : ${DESCRIPTION}"
    echo "Block pair count         : ${BLOCK_PAIR_COUNT}"
    echo "Source0 bytes            : ${SRC0_BYTE_COUNT0}, ${SRC0_BYTE_COUNT1}, ${SRC0_BYTE_COUNT2}"
    echo "Source1 bytes            : ${SRC1_BYTE_COUNT0}, ${SRC1_BYTE_COUNT1}, ${SRC1_BYTE_COUNT2}"
    echo "Expected dst bytes       : ${EXPECTED_DST0_BYTES}, ${EXPECTED_DST1_BYTES}, ${EXPECTED_DST2_BYTES}"
    echo "Expected final mid bytes : ${EXPECTED_FINAL_MID_BYTES}"
    echo "Expected keep/drop       : ${TOTAL_MERGE_MERGED_RECORD_COUNT}/${TOTAL_MERGE_DROPPED_COUNT}"
  fi

  if (( SRC0_BYTE_COUNT0 > 0 )); then
    "$DMA_TO" "$H2C_DEV" -f "$src0_file0" -a "$SRC0_ADDR0" -s "$SRC0_BYTE_COUNT0" >/dev/null
  fi
  if (( SRC1_BYTE_COUNT0 > 0 )); then
    "$DMA_TO" "$H2C_DEV" -f "$src1_file0" -a "$SRC1_ADDR0" -s "$SRC1_BYTE_COUNT0" >/dev/null
  fi
  if (( SRC0_BYTE_COUNT1 > 0 )); then
    "$DMA_TO" "$H2C_DEV" -f "$src0_file1" -a "$SRC0_ADDR1" -s "$SRC0_BYTE_COUNT1" >/dev/null
  fi
  if (( SRC1_BYTE_COUNT1 > 0 )); then
    "$DMA_TO" "$H2C_DEV" -f "$src1_file1" -a "$SRC1_ADDR1" -s "$SRC1_BYTE_COUNT1" >/dev/null
  fi
  if (( SRC0_BYTE_COUNT2 > 0 )); then
    "$DMA_TO" "$H2C_DEV" -f "$src0_file2" -a "$SRC0_ADDR2" -s "$SRC0_BYTE_COUNT2" >/dev/null
  fi
  if (( SRC1_BYTE_COUNT2 > 0 )); then
    "$DMA_TO" "$H2C_DEV" -f "$src1_file2" -a "$SRC1_ADDR2" -s "$SRC1_BYTE_COUNT2" >/dev/null
  fi
  "$DMA_TO" "$H2C_DEV" -f "$mid_init_file" -a "$MID_ADDR" -s "$MID_READ_BYTES" >/dev/null
  "$DMA_TO" "$H2C_DEV" -f "$dst0_init_file" -a "$DST0_ADDR" -s "$DST0_READ_BYTES" >/dev/null
  "$DMA_TO" "$H2C_DEV" -f "$dst1_init_file" -a "$DST1_ADDR" -s "$DST1_READ_BYTES" >/dev/null
  "$DMA_TO" "$H2C_DEV" -f "$dst2_init_file" -a "$DST2_ADDR" -s "$DST2_READ_BYTES" >/dev/null

  reg_write "$REG_CTRL" 0x2
  reg_write "$REG_CTRL" 0x0
  reg_write "$REG_BLOCK_PAIR_COUNT" "$BLOCK_PAIR_COUNT"
  reg_write "$REG_MID_BASE_LO" "$(split_u64_lo "$MID_ADDR")"
  reg_write "$REG_MID_BASE_HI" "$(split_u64_hi "$MID_ADDR")"
  reg_write "$REG_SRC0_BASE0_LO" "$(split_u64_lo "$SRC0_ADDR0")"
  reg_write "$REG_SRC0_BASE0_HI" "$(split_u64_hi "$SRC0_ADDR0")"
  reg_write "$REG_SRC0_SIZE0" "$SRC0_BYTE_COUNT0"
  reg_write "$REG_SRC1_BASE0_LO" "$(split_u64_lo "$SRC1_ADDR0")"
  reg_write "$REG_SRC1_BASE0_HI" "$(split_u64_hi "$SRC1_ADDR0")"
  reg_write "$REG_SRC1_SIZE0" "$SRC1_BYTE_COUNT0"
  reg_write "$REG_DST_BASE0_LO" "$(split_u64_lo "$DST0_ADDR")"
  reg_write "$REG_DST_BASE0_HI" "$(split_u64_hi "$DST0_ADDR")"
  reg_write "$REG_SRC0_BASE1_LO" "$(split_u64_lo "$SRC0_ADDR1")"
  reg_write "$REG_SRC0_BASE1_HI" "$(split_u64_hi "$SRC0_ADDR1")"
  reg_write "$REG_SRC0_SIZE1" "$SRC0_BYTE_COUNT1"
  reg_write "$REG_SRC1_BASE1_LO" "$(split_u64_lo "$SRC1_ADDR1")"
  reg_write "$REG_SRC1_BASE1_HI" "$(split_u64_hi "$SRC1_ADDR1")"
  reg_write "$REG_SRC1_SIZE1" "$SRC1_BYTE_COUNT1"
  reg_write "$REG_DST_BASE1_LO" "$(split_u64_lo "$DST1_ADDR")"
  reg_write "$REG_DST_BASE1_HI" "$(split_u64_hi "$DST1_ADDR")"
  reg_write "$(desc_addr 2 "$REG_DESC_SRC0_BASE_LO_OFF")" "$(split_u64_lo "$SRC0_ADDR2")"
  reg_write "$(desc_addr 2 "$REG_DESC_SRC0_BASE_HI_OFF")" "$(split_u64_hi "$SRC0_ADDR2")"
  reg_write "$(desc_addr 2 "$REG_DESC_SRC0_SIZE_OFF")" "$SRC0_BYTE_COUNT2"
  reg_write "$(desc_addr 2 "$REG_DESC_SRC1_BASE_LO_OFF")" "$(split_u64_lo "$SRC1_ADDR2")"
  reg_write "$(desc_addr 2 "$REG_DESC_SRC1_BASE_HI_OFF")" "$(split_u64_hi "$SRC1_ADDR2")"
  reg_write "$(desc_addr 2 "$REG_DESC_SRC1_SIZE_OFF")" "$SRC1_BYTE_COUNT2"
  reg_write "$(desc_addr 2 "$REG_DESC_DST_BASE_LO_OFF")" "$(split_u64_lo "$DST2_ADDR")"
  reg_write "$(desc_addr 2 "$REG_DESC_DST_BASE_HI_OFF")" "$(split_u64_hi "$DST2_ADDR")"

  if (( CFG_SETTLE_MS > 0 )); then
    sleep "$(python3 - <<PY
print(int("$CFG_SETTLE_MS", 0) / 1000.0)
PY
)"
  fi

  reg_write "$REG_CTRL" 0x1
  reg_write "$REG_CTRL" 0x0

  poll_until_done

  status_hex="$(reg_read "$REG_STATUS")"
  status_hex=${status_hex:-0x0}
  status_val=$((status_hex))
  done_bit=$(((status_val >> 1) & 0x1))
  err_bit=$(((status_val >> 2) & 0x1))
  if (( done_bit != 1 || err_bit != 0 )); then
    dump_regs
    echo "FAIL: unexpected final status=${status_hex}" >&2
    exit 1
  fi

  desc0_output="$(reg_read "$(desc_output_addr 0)")"
  desc1_output="$(reg_read "$(desc_output_addr 1)")"
  desc2_output="$(reg_read "$(desc_output_addr 2)")"

  expect_eq "blocks_completed" "$(reg_read "$REG_BLOCKS_COMPLETED")" "$BLOCK_PAIR_COUNT"
  expect_eq "dst0_output_block_bytes_fixed" "$(reg_read "$REG_DST0_OUTPUT_BLOCK_BYTES")" "$EXPECTED_DST0_BYTES"
  expect_eq "dst1_output_block_bytes_fixed" "$(reg_read "$REG_DST1_OUTPUT_BLOCK_BYTES")" "$EXPECTED_DST1_BYTES"
  expect_eq "dst0_output_block_bytes_desc" "$desc0_output" "$EXPECTED_DST0_BYTES"
  expect_eq "dst1_output_block_bytes_desc" "$desc1_output" "$EXPECTED_DST1_BYTES"
  expect_eq "dst2_output_block_bytes_desc" "$desc2_output" "$EXPECTED_DST2_BYTES"
  expect_eq "total_source0_decoded_entry_count" "$(reg_read "$REG_TOTAL_SOURCE0_DECODED_ENTRY_COUNT")" "$TOTAL_SOURCE0_DECODED_ENTRY_COUNT"
  expect_eq "total_source1_decoded_entry_count" "$(reg_read "$REG_TOTAL_SOURCE1_DECODED_ENTRY_COUNT")" "$TOTAL_SOURCE1_DECODED_ENTRY_COUNT"
  expect_eq "total_source0_bytes_read" "$(reg_read "$REG_TOTAL_SOURCE0_BYTES_READ")" "$TOTAL_SOURCE0_BYTES_READ"
  expect_eq "total_source1_bytes_read" "$(reg_read "$REG_TOTAL_SOURCE1_BYTES_READ")" "$TOTAL_SOURCE1_BYTES_READ"
  expect_eq "total_merge_output_byte_count" "$(reg_read "$REG_TOTAL_MERGE_OUTPUT_BYTE_COUNT")" "$TOTAL_MERGE_OUTPUT_BYTE_COUNT"
  expect_eq "total_merge_decoded_record_count" "$(reg_read "$REG_TOTAL_MERGE_DECODED_RECORD_COUNT")" "$TOTAL_MERGE_DECODED_RECORD_COUNT"
  expect_eq "total_merge_merged_record_count" "$(reg_read "$REG_TOTAL_MERGE_MERGED_RECORD_COUNT")" "$TOTAL_MERGE_MERGED_RECORD_COUNT"
  expect_eq "total_merge_dropped_count" "$(reg_read "$REG_TOTAL_MERGE_DROPPED_COUNT")" "$TOTAL_MERGE_DROPPED_COUNT"
  expect_eq "total_stage5_input_record_count" "$(reg_read "$REG_TOTAL_STAGE5_INPUT_RECORD_COUNT")" "$TOTAL_STAGE5_INPUT_RECORD_COUNT"
  expect_eq "total_stage5_encoded_entry_count" "$(reg_read "$REG_TOTAL_STAGE5_ENCODED_ENTRY_COUNT")" "$TOTAL_STAGE5_ENCODED_ENTRY_COUNT"
  expect_eq "total_stage5_output_block_bytes" "$(reg_read "$REG_TOTAL_STAGE5_OUTPUT_BLOCK_BYTES")" "$TOTAL_STAGE5_OUTPUT_BLOCK_BYTES"
  expect_eq "total_stage5_bytes_written" "$(reg_read "$REG_TOTAL_STAGE5_BYTES_WRITTEN")" "$TOTAL_STAGE5_BYTES_WRITTEN"
  perf_cycle_count="$(reg_read "$REG_PERF_CYCLE_COUNT")"
  perf_cycle_count=${perf_cycle_count:-0x0}

  "$DMA_FROM" "$C2H_DEV" -f "$dst0_file" -a "$DST0_ADDR" -s "$DST0_READ_BYTES" >/dev/null
  "$DMA_FROM" "$C2H_DEV" -f "$dst1_file" -a "$DST1_ADDR" -s "$DST1_READ_BYTES" >/dev/null
  "$DMA_FROM" "$C2H_DEV" -f "$dst2_file" -a "$DST2_ADDR" -s "$DST2_READ_BYTES" >/dev/null
  "$DMA_FROM" "$C2H_DEV" -f "$mid_file" -a "$MID_ADDR" -s "$MID_READ_BYTES" >/dev/null

  verify_buffer "dst0" "$dst0_expected_file" "$dst0_file" "$EXPECTED_DST0_BYTES" "$DST0_READ_BYTES"
  verify_buffer "dst1" "$dst1_expected_file" "$dst1_file" "$EXPECTED_DST1_BYTES" "$DST1_READ_BYTES"
  verify_buffer "dst2" "$dst2_expected_file" "$dst2_file" "$EXPECTED_DST2_BYTES" "$DST2_READ_BYTES"
  if ! python3 - "$mid_file" "$MID_READ_BYTES" <<'PY'
import pathlib, sys
mid_file, mid_read_bytes = sys.argv[1], int(sys.argv[2], 0)
data = pathlib.Path(mid_file).read_bytes()
if len(data) < mid_read_bytes:
    raise SystemExit(f'mid readback too short: {len(data)} < {mid_read_bytes}')
for i, b in enumerate(data[:mid_read_bytes]):
    if b != 0xA5:
        raise SystemExit(f'[v2-bypass] mid DDR byte {i} was written (got 0x{b:02x}), expected 0xA5 untouched')
PY
  then
    echo "FAIL: [v2-bypass] mid DDR was modified unexpectedly" >&2
    exit 1
  fi

  case_end_ns="$(now_ns)"
  elapsed_ms=$(( (case_end_ns - case_start_ns) / 1000000 ))
  if (( elapsed_ms <= 0 )); then
    elapsed_ms=1
  fi
  total_src_bytes=$((TOTAL_SOURCE0_BYTES_READ + TOTAL_SOURCE1_BYTES_READ))
  total_dst_bytes=$((TOTAL_STAGE5_BYTES_WRITTEN))
  LAST_CASE_ELAPSED_MS="$elapsed_ms"
  LAST_CASE_SRC_BYTES="$total_src_bytes"
  LAST_CASE_DST_BYTES="$total_dst_bytes"
  LAST_CASE_MID_BYTES="$TOTAL_MERGE_OUTPUT_BYTE_COUNT"

  echo "PERF [$scenario]: elapsed_ms=${elapsed_ms} src_bytes=${total_src_bytes} mid_bytes=${TOTAL_MERGE_OUTPUT_BYTE_COUNT} dst_bytes=${total_dst_bytes} src_mib_s=$(rate_mib_s "$total_src_bytes" "$elapsed_ms") dst_mib_s=$(rate_mib_s "$total_dst_bytes" "$elapsed_ms") perf_cycles=$((perf_cycle_count))"
  echo "PASS [$scenario]: block_pairs=${BLOCK_PAIR_COUNT} dst=(${EXPECTED_DST0_BYTES},${EXPECTED_DST1_BYTES},${EXPECTED_DST2_BYTES}) merge_keep=${TOTAL_MERGE_MERGED_RECORD_COUNT} merge_drop=${TOTAL_MERGE_DROPPED_COUNT} mid_ddr=untouched"
}

IFS=',' read -r -a RAW_SCENARIO_LIST <<< "$SCENARIOS"
SELECTED_SCENARIOS=()
for scenario in "${RAW_SCENARIO_LIST[@]}"; do
  scenario="${scenario//[[:space:]]/}"
  if [[ -n "$scenario" ]]; then
    SELECTED_SCENARIOS+=("$scenario")
  fi
done

if [[ ${#SELECTED_SCENARIOS[@]} -eq 0 ]]; then
  echo "ERROR: no scenarios selected" >&2
  exit 1
fi

LAST_CASE_ELAPSED_MS=0
LAST_CASE_SRC_BYTES=0
LAST_CASE_DST_BYTES=0
LAST_CASE_MID_BYTES=0
PASS_COUNT=0
TOTAL_ELAPSED_MS=0
TOTAL_SRC_BYTES=0
TOTAL_DST_BYTES=0
TOTAL_MID_BYTES=0
SUITE_START_NS="$(now_ns)"

for ((iteration=1; iteration<=ITERATIONS; iteration++)); do
  if (( ITERATIONS > 1 )); then
    echo "=== Iteration ${iteration}/${ITERATIONS} ==="
  fi
  ITERATION_PASS_COUNT=0
  for scenario in "${SELECTED_SCENARIOS[@]}"; do
    echo "Running scenario: $scenario (iteration ${iteration}/${ITERATIONS})"
    run_case "$scenario"
    PASS_COUNT=$((PASS_COUNT + 1))
    ITERATION_PASS_COUNT=$((ITERATION_PASS_COUNT + 1))
    TOTAL_ELAPSED_MS=$((TOTAL_ELAPSED_MS + LAST_CASE_ELAPSED_MS))
    TOTAL_SRC_BYTES=$((TOTAL_SRC_BYTES + LAST_CASE_SRC_BYTES))
    TOTAL_DST_BYTES=$((TOTAL_DST_BYTES + LAST_CASE_DST_BYTES))
    TOTAL_MID_BYTES=$((TOTAL_MID_BYTES + LAST_CASE_MID_BYTES))
  done
  if (( ITERATIONS > 1 )); then
    echo "PASS: iteration ${iteration}/${ITERATIONS} completed ${ITERATION_PASS_COUNT} scenario(s)"
  fi
done

SUITE_END_NS="$(now_ns)"
SUITE_ELAPSED_MS=$(( (SUITE_END_NS - SUITE_START_NS) / 1000000 ))
if (( SUITE_ELAPSED_MS <= 0 )); then
  SUITE_ELAPSED_MS=1
fi
AVG_CASE_MS=$(( (TOTAL_ELAPSED_MS + PASS_COUNT - 1) / PASS_COUNT ))

echo "PERF SUMMARY: runs=${PASS_COUNT} iterations=${ITERATIONS} suite_elapsed_ms=${SUITE_ELAPSED_MS} avg_case_ms=${AVG_CASE_MS} total_src_bytes=${TOTAL_SRC_BYTES} total_mid_bytes=${TOTAL_MID_BYTES} total_dst_bytes=${TOTAL_DST_BYTES} suite_src_mib_s=$(rate_mib_s "$TOTAL_SRC_BYTES" "$SUITE_ELAPSED_MS") suite_dst_mib_s=$(rate_mib_s "$TOTAL_DST_BYTES" "$SUITE_ELAPSED_MS")"
echo "PASS: completed ${PASS_COUNT} v2-bypass board regression run(s) across ${ITERATIONS} iteration(s)"

