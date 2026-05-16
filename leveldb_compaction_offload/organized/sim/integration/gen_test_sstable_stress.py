#!/usr/bin/env python3
"""
gen_test_sstable_stress.py

Generates large SSTable fixtures (16 data blocks each) for stress testing the
compaction engine with increased parameters (MAX_BLOCK_PAIRS=32).

Layout:
  SRC0: 16 data blocks × 4 records each  @ DDR 0x0000
  SRC1: 16 data blocks × 4 records each  @ DDR 0x4000

Per block-pair overlap:
  SRC0 keys:  k{bi}_00, k{bi}_01, k{bi}_02, k{bi}_03  (seq 100..103)
  SRC1 keys:  k{bi}_01, k{bi}_02, k{bi}_05, k{bi}_06  (seq 50..53)
  → k{bi}_01 and k{bi}_02 are duplicated; SRC1 copies have lower seq → dropped

Expected counters:
  block_pair_count  = 16
  total_src0_decoded = 64  (16 × 4)
  total_src1_decoded = 64  (16 × 4)
  merge_decoded      = 128
  merge_merged       = 96  (128 - 32)
  merge_dropped      = 32  (16 × 2)
  stage5_input       = 96
  stage5_encoded     = 96
"""

import struct
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(SCRIPT_DIR, "fixtures")

LEVELDB_MAGIC = 0x57fb808b24e46a97
NUM_BLOCKS = 16
RECS_PER_BLOCK = 4


# ---------------------------------------------------------------------------
# Varint helpers
# ---------------------------------------------------------------------------

def varint32(v):
    v &= 0xFFFFFFFF
    out = []
    while True:
        b = v & 0x7F
        v >>= 7
        out.append(b | 0x80 if v else b)
        if not v:
            break
    return bytes(out)


def varint64(v):
    v &= 0xFFFFFFFFFFFFFFFF
    out = []
    while True:
        b = v & 0x7F
        v >>= 7
        out.append(b | 0x80 if v else b)
        if not v:
            break
    return bytes(out)


def block_handle_bytes(offset, size):
    return varint64(offset) + varint64(size)


# ---------------------------------------------------------------------------
# Internal key helpers
# ---------------------------------------------------------------------------

def make_ikey(user_key, seq, vtype=1):
    tag = (seq << 8) | vtype
    return user_key + struct.pack('<Q', tag)


# ---------------------------------------------------------------------------
# Block encoder
# ---------------------------------------------------------------------------

def encode_block(records, restart_interval=16):
    if not records:
        return struct.pack('<I', 0)
    entries = bytearray()
    restart_offsets = []
    prev_key = b''
    for idx, (key, value) in enumerate(records):
        if idx % restart_interval == 0:
            restart_offsets.append(len(entries))
            shared = 0
        else:
            shared = 0
            mn = min(len(prev_key), len(key))
            while shared < mn and prev_key[shared] == key[shared]:
                shared += 1
        unshared = len(key) - shared
        entries += varint32(shared)
        entries += varint32(unshared)
        entries += varint32(len(value))
        entries += key[shared:]
        entries += value
        prev_key = key
    for off in restart_offsets:
        entries += struct.pack('<I', off)
    entries += struct.pack('<I', len(restart_offsets))
    return bytes(entries)


def block_with_trailer(data):
    return data + b'\x00' + struct.pack('<I', 0)


# ---------------------------------------------------------------------------
# SSTable builder
# ---------------------------------------------------------------------------

def build_sstable(data_block_records, restart_interval=2):
    file_buf = bytearray()
    data_offsets = []
    for records in data_block_records:
        raw = encode_block(records, restart_interval)
        data_offsets.append((len(file_buf), len(raw)))
        file_buf += block_with_trailer(raw)
    # Index block
    index_entries = []
    for i, records in enumerate(data_block_records):
        largest_key = sorted(r[0] for r in records)[-1]
        off, sz = data_offsets[i]
        index_entries.append((largest_key, block_handle_bytes(off, sz)))
    index_entries.sort(key=lambda e: e[0])
    index_raw = encode_block(index_entries, restart_interval=1)
    index_off = len(file_buf)
    index_sz = len(index_raw)
    file_buf += block_with_trailer(index_raw)
    # Metaindex (empty)
    meta_raw = encode_block([], restart_interval=1)
    meta_off = len(file_buf)
    meta_sz = len(meta_raw)
    file_buf += block_with_trailer(meta_raw)
    # Footer (48 bytes)
    mi_handle = block_handle_bytes(meta_off, meta_sz)
    idx_handle = block_handle_bytes(index_off, index_sz)
    header = mi_handle + idx_handle
    header_padded = header + b'\x00' * (40 - len(header))
    magic = struct.pack('<Q', LEVELDB_MAGIC)
    footer = header_padded + magic
    file_buf += footer
    return {
        'bytes': bytes(file_buf),
        'data_offsets': data_offsets,
        'index_offset': index_off,
        'index_size': index_sz,
    }


def to_memh(data, base_addr=0):
    lines = [f"@{base_addr:08x}"]
    for b in data:
        lines.append(f"{b:02x}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Test data: 16 blocks per SSTable
# ---------------------------------------------------------------------------

def make_src0_blocks():
    blocks = []
    for bi in range(NUM_BLOCKS):
        records = []
        for ri in range(RECS_PER_BLOCK):
            uk = f"k{bi:03d}_{ri:02d}".encode()
            val = f"v0_{bi:03d}_{ri:02d}".encode()
            records.append((make_ikey(uk, seq=100 + ri), val))
        blocks.append(records)
    return blocks


def make_src1_blocks():
    blocks = []
    for bi in range(NUM_BLOCKS):
        records = [
            (make_ikey(f"k{bi:03d}_01".encode(), seq=50),
             f"v1_{bi:03d}_01".encode()),
            (make_ikey(f"k{bi:03d}_02".encode(), seq=51),
             f"v1_{bi:03d}_02".encode()),
            (make_ikey(f"k{bi:03d}_05".encode(), seq=52),
             f"v1_{bi:03d}_05".encode()),
            (make_ikey(f"k{bi:03d}_06".encode(), seq=53),
             f"v1_{bi:03d}_06".encode()),
        ]
        blocks.append(records)
    return blocks


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    os.makedirs(FIXTURE_DIR, exist_ok=True)

    specs = [
        ("src0_stress", 0x0000, make_src0_blocks),
        ("src1_stress", 0x4000, make_src1_blocks),
    ]

    total_src0_decoded = 0
    total_src1_decoded = 0

    for name, base, fn in specs:
        blocks = fn()
        result = build_sstable(blocks, restart_interval=2)
        raw = result['bytes']
        total_records = sum(len(b) for b in blocks)
        if "src0" in name:
            total_src0_decoded = total_records
        else:
            total_src1_decoded = total_records

        bin_path = os.path.join(FIXTURE_DIR, f"{name}_sstable_real.bin")
        with open(bin_path, 'wb') as f:
            f.write(raw)

        memh_path = os.path.join(FIXTURE_DIR, f"{name}_sstable_real.memh")
        with open(memh_path, 'w') as f:
            f.write(to_memh(raw, base_addr=base))

        print(f"[{name}] {len(raw)} bytes, {len(blocks)} blocks, "
              f"{total_records} records, index_size={result['index_size']}")

    # Expected counters
    num_pairs = NUM_BLOCKS
    total_decoded = total_src0_decoded + total_src1_decoded
    total_dropped = num_pairs * 2
    total_merged = total_decoded - total_dropped

    src0_result = build_sstable(make_src0_blocks(), restart_interval=2)
    src1_result = build_sstable(make_src1_blocks(), restart_interval=2)

    exp_path = os.path.join(FIXTURE_DIR, "stress_expected.txt")
    with open(exp_path, 'w') as f:
        f.write(f"SRC0_SIZE={len(src0_result['bytes'])}\n")
        f.write(f"SRC1_SIZE={len(src1_result['bytes'])}\n")
        f.write(f"NUM_BLOCK_PAIRS={num_pairs}\n")
        f.write(f"TOTAL_SRC0_DECODED={total_src0_decoded}\n")
        f.write(f"TOTAL_SRC1_DECODED={total_src1_decoded}\n")
        f.write(f"TOTAL_MERGE_DECODED={total_decoded}\n")
        f.write(f"TOTAL_MERGE_MERGED={total_merged}\n")
        f.write(f"TOTAL_MERGE_DROPPED={total_dropped}\n")
        f.write(f"TOTAL_STAGE5_INPUT={total_merged}\n")
        f.write(f"TOTAL_STAGE5_ENCODED={total_merged}\n")

    print(f"\nExpected counters:")
    print(f"  SRC0_SIZE        = {len(src0_result['bytes'])}")
    print(f"  SRC1_SIZE        = {len(src1_result['bytes'])}")
    print(f"  block_pairs      = {num_pairs}")
    print(f"  src0_decoded     = {total_src0_decoded}")
    print(f"  src1_decoded     = {total_src1_decoded}")
    print(f"  merge_decoded    = {total_decoded}")
    print(f"  merge_merged     = {total_merged}")
    print(f"  merge_dropped    = {total_dropped}")
    print(f"  stage5_input     = {total_merged}")
    print(f"  stage5_encoded   = {total_merged}")
    print(f"\nWrote {exp_path}")


if __name__ == '__main__':
    main()
