#!/usr/bin/env python3
"""
gen_test_sstable_split.py

Generates LevelDB SSTable fixtures for split-mode simulation.
Creates 4-block SSTables for SRC0 and SRC1 so that with a small
max_file_size threshold, the nblock engine produces multiple output
SSTables.

Layout:
  SRC0 @ 0x0000: 4 data blocks, 4 records each (key_0000..key_0015)
  SRC1 @ 0x4000: 4 data blocks, 2 records each (key_0001 dup, key_0016..key_0022)

Expected with max_file_size ~ 300 bytes:
  - Block pair 0 output ≈ 170 bytes → fits in SST #0
  - Block pair 1 output ≈ 170 bytes → over threshold → split, SST #0 finalized
  - Block pair 2 output ≈ 170 bytes → SST #1
  - Block pair 3 output ≈ 170 bytes → over threshold → split, SST #1 finalized
  - Final: 2 or 3 output SSTables
"""

import struct
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(SCRIPT_DIR, "fixtures")

LEVELDB_MAGIC = 0x57fb808b24e46a97


def varint32(v):
    v &= 0xFFFFFFFF
    out = []
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def varint64(v):
    v &= 0xFFFFFFFFFFFFFFFF
    out = []
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def block_handle_bytes(offset, size):
    return varint64(offset) + varint64(size)


def make_ikey(user_key, seq, vtype=1):
    tag = (seq << 8) | vtype
    return user_key + struct.pack('<Q', tag)


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


def build_sstable(data_block_records, restart_interval=2):
    file_buf = bytearray()
    data_offsets = []
    for records in data_block_records:
        raw = encode_block(records, restart_interval)
        data_offsets.append((len(file_buf), len(raw)))
        file_buf += block_with_trailer(raw)
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
    meta_raw = encode_block([], restart_interval=1)
    meta_off = len(file_buf)
    meta_sz = len(meta_raw)
    file_buf += block_with_trailer(meta_raw)
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
# Test data: 4 blocks per SSTable
# ---------------------------------------------------------------------------
def make_records_src0_split():
    """SRC0: 4 blocks, 4 records each. Keys key_0000..key_0015."""
    val = lambda k: b"val_" + k
    blocks = []
    for blk in range(4):
        recs = []
        for i in range(4):
            idx = blk * 4 + i
            uk = f"key_{idx:04d}".encode()
            recs.append((make_ikey(uk, seq=100 + idx), val(uk)))
        blocks.append(recs)
    return blocks


def make_records_src1_split():
    """SRC1: 4 blocks, 2 records each.
    Block 0: key_0001 (dup, older), key_0016 (unique)
    Block 1: key_0005 (dup, older), key_0017
    Block 2: key_0009 (dup, older), key_0018
    Block 3: key_0013 (dup, older), key_0019
    """
    val = lambda k: b"old_" + k
    dup_keys = [1, 5, 9, 13]
    uniq_start = 16
    blocks = []
    for blk in range(4):
        recs = []
        dk = f"key_{dup_keys[blk]:04d}".encode()
        recs.append((make_ikey(dk, seq=50 + blk), val(dk)))
        uk = f"key_{uniq_start + blk:04d}".encode()
        recs.append((make_ikey(uk, seq=60 + blk), val(uk)))
        blocks.append(recs)
    return blocks


def main():
    os.makedirs(FIXTURE_DIR, exist_ok=True)

    total_src0_recs = 0
    total_src1_recs = 0

    for name, base, block_records_fn in [
        ("src0", 0x0000, make_records_src0_split),
        ("src1", 0x4000, make_records_src1_split),
    ]:
        records = block_records_fn()
        result = build_sstable(records, restart_interval=2)
        raw = result['bytes']
        data_offs = result['data_offsets']

        bin_path = os.path.join(FIXTURE_DIR, f"{name}_split_sstable_real.bin")
        with open(bin_path, 'wb') as f:
            f.write(raw)
        print(f"[{name}] wrote {bin_path}  ({len(raw)} bytes)")

        memh_path = os.path.join(FIXTURE_DIR, f"{name}_split_sstable_real.memh")
        with open(memh_path, 'w') as f:
            f.write(to_memh(raw, base_addr=base))
        print(f"[{name}] wrote {memh_path}")

        nrecs = sum(len(b) for b in records)
        if name == "src0":
            total_src0_recs = nrecs
        else:
            total_src1_recs = nrecs

        print(f"[{name}] SSTable size: {len(raw)}")
        print(f"[{name}] data blocks: {len(data_offs)}")
        print(f"[{name}] total records: {nrecs}")
        for i, (off, sz) in enumerate(data_offs):
            print(f"[{name}]   block[{i}]: off={off} size={sz}")
        print()

    # Expected counters
    print("=== Expected counters ===")
    print(f"block_pair_count = 4")
    print(f"total_src0_decoded = {total_src0_recs}")
    print(f"total_src1_decoded = {total_src1_recs}")
    total_decoded = total_src0_recs + total_src1_recs
    # 4 dups (one per block pair)
    total_merged = total_decoded - 4
    print(f"total_merge_decoded = {total_decoded}")
    print(f"total_merge_merged = {total_merged}")
    print(f"total_merge_dropped = 4")
    print(f"total_stage5_input = {total_merged}")
    print(f"total_stage5_encoded = {total_merged}")

    # Write expected file
    exp_path = os.path.join(FIXTURE_DIR, "split_expected.txt")
    with open(exp_path, 'w') as f:
        f.write(f"block_pair_count=4\n")
        f.write(f"total_src0_decoded={total_src0_recs}\n")
        f.write(f"total_src1_decoded={total_src1_recs}\n")
        f.write(f"total_merge_decoded={total_decoded}\n")
        f.write(f"total_merge_merged={total_merged}\n")
        f.write(f"total_merge_dropped=4\n")
        f.write(f"total_stage5_input={total_merged}\n")
        f.write(f"total_stage5_encoded={total_merged}\n")
    print(f"\nWrote {exp_path}")


if __name__ == '__main__':
    main()
