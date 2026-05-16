#!/usr/bin/env python3
"""
gen_test_sstable_large.py

Generates large SSTable fixtures with 12 data blocks each to test
the streaming pipeline beyond MAX_BLOCK_PAIRS=8.

SRC0: 12 data blocks × 2 records = 24 records  (keys: a_00_00 .. a_11_01)
SRC1: 12 data blocks × 2 records = 24 records  (keys: b_00_00 .. b_11_01)
No duplicate user keys → all 48 records survive the merge.

Expected (MAX_BLOCK_PAIRS=8):
  block_pair_count = 12
  sstable_count    = 2   (auto-split after block index 7)
  total_src0_decoded = 24
  total_src1_decoded = 24
  total_merge_decoded = 48
  total_merge_merged  = 48
  total_merge_dropped = 0
  total_stage5_input  = 48
  total_stage5_encoded = 48
"""

import struct, os, sys

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(SCRIPT_DIR, "fixtures")
LEVELDB_MAGIC = 0x57fb808b24e46a97


# ── helpers (same as gen_test_sstable.py) ──────────────────────────────────
def varint32(v):
    v &= 0xFFFFFFFF; out = []
    while True:
        b = v & 0x7F; v >>= 7
        if v: out.append(b | 0x80)
        else: out.append(b); break
    return bytes(out)

def varint64(v):
    v &= 0xFFFFFFFFFFFFFFFF; out = []
    while True:
        b = v & 0x7F; v >>= 7
        if v: out.append(b | 0x80)
        else: out.append(b); break
    return bytes(out)

def block_handle_bytes(offset, size):
    return varint64(offset) + varint64(size)

def make_ikey(user_key, seq, vtype=1):
    tag = (seq << 8) | vtype
    return user_key + struct.pack('<Q', tag)

def encode_block(records, restart_interval=16):
    if not records:
        return struct.pack('<I', 0)
    entries = bytearray(); restart_offsets = []; prev_key = b''
    for idx, (key, value) in enumerate(records):
        if idx % restart_interval == 0:
            restart_offsets.append(len(entries)); shared = 0
        else:
            shared = 0; mn = min(len(prev_key), len(key))
            while shared < mn and prev_key[shared] == key[shared]:
                shared += 1
        unshared = len(key) - shared
        entries += varint32(shared) + varint32(unshared) + varint32(len(value))
        entries += key[shared:] + value
        prev_key = key
    for off in restart_offsets:
        entries += struct.pack('<I', off)
    entries += struct.pack('<I', len(restart_offsets))
    return bytes(entries)

def block_with_trailer(data):
    return data + b'\x00' + struct.pack('<I', 0)

def build_sstable(data_block_records, restart_interval=2):
    file_buf = bytearray(); data_offsets = []
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
    index_off = len(file_buf); index_sz = len(index_raw)
    file_buf += block_with_trailer(index_raw)
    meta_raw = encode_block([], restart_interval=1)
    meta_off = len(file_buf); meta_sz = len(meta_raw)
    file_buf += block_with_trailer(meta_raw)
    mi_handle = block_handle_bytes(meta_off, meta_sz)
    idx_handle = block_handle_bytes(index_off, index_sz)
    header = mi_handle + idx_handle
    header_padded = header + b'\x00' * (40 - len(header))
    footer = header_padded + struct.pack('<Q', LEVELDB_MAGIC)
    file_buf += footer
    return {'bytes': bytes(file_buf), 'data_offsets': data_offsets,
            'index_offset': index_off, 'index_size': index_sz}

def to_memh(data, base_addr=0):
    lines = [f"@{base_addr:08x}"]
    for b in data:
        lines.append(f"{b:02x}")
    return "\n".join(lines) + "\n"


# ── large test data ───────────────────────────────────────────────────────
NUM_BLOCKS = 12
RECORDS_PER_BLOCK = 2

def make_large_src0():
    blocks = []
    for b in range(NUM_BLOCKS):
        records = []
        for r in range(RECORDS_PER_BLOCK):
            user_key = f"a_{b:02d}_{r:02d}".encode()
            seq = 1000 - b * 10 - r
            records.append((make_ikey(user_key, seq), f"vs0_{b:02d}_{r}".encode()))
        blocks.append(records)
    return blocks

def make_large_src1():
    blocks = []
    for b in range(NUM_BLOCKS):
        records = []
        for r in range(RECORDS_PER_BLOCK):
            user_key = f"b_{b:02d}_{r:02d}".encode()
            seq = 500 - b * 10 - r
            records.append((make_ikey(user_key, seq), f"vs1_{b:02d}_{r}".encode()))
        blocks.append(records)
    return blocks


# ── main ──────────────────────────────────────────────────────────────────
def main():
    os.makedirs(FIXTURE_DIR, exist_ok=True)
    total_src0 = NUM_BLOCKS * RECORDS_PER_BLOCK
    total_src1 = NUM_BLOCKS * RECORDS_PER_BLOCK

    for name, base, fn in [("src0_large", 0x0000, make_large_src0),
                            ("src1_large", 0x10000, make_large_src1)]:
        records = fn()
        result  = build_sstable(records, restart_interval=2)
        raw = result['bytes']

        bin_path = os.path.join(FIXTURE_DIR, f"{name}.bin")
        with open(bin_path, 'wb') as f:
            f.write(raw)

        memh_path = os.path.join(FIXTURE_DIR, f"{name}.memh")
        with open(memh_path, 'w') as f:
            f.write(to_memh(raw, base_addr=base))

        print(f"[{name}] {len(raw)} bytes, {len(result['data_offsets'])} data blocks, "
              f"base=0x{base:x}")
        for i, (off, sz) in enumerate(result['data_offsets']):
            print(f"  block[{i}]: off={off} size={sz} abs=0x{base+off:x}")

    print(f"\nExpected counters:")
    print(f"  block_pair_count = {NUM_BLOCKS}")
    print(f"  total_src0_decoded = {total_src0}")
    print(f"  total_src1_decoded = {total_src1}")
    print(f"  total_merge_decoded = {total_src0 + total_src1}")
    print(f"  total_merge_merged  = {total_src0 + total_src1}")
    print(f"  total_merge_dropped = 0")
    print(f"  sstable_count >= 2  (auto-split at MAX_BLOCK_PAIRS=8)")

if __name__ == '__main__':
    main()
