#!/usr/bin/env python3
"""Generate single-data-block SSTable fixtures for 1-block-pair testing."""

import struct, os, sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(SCRIPT_DIR, "fixtures")
LEVELDB_MAGIC = 0x57fb808b24e46a97

def varint32(v):
    v &= 0xFFFFFFFF
    out = []
    while True:
        b = v & 0x7F; v >>= 7
        if v: out.append(b | 0x80)
        else: out.append(b); break
    return bytes(out)

def varint64(v):
    v &= 0xFFFFFFFFFFFFFFFF
    out = []
    while True:
        b = v & 0x7F; v >>= 7
        if v: out.append(b | 0x80)
        else: out.append(b); break
    return bytes(out)

def block_handle_bytes(off, sz):
    return varint64(off) + varint64(sz)

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
    # Metaindex
    meta_raw = encode_block([], restart_interval=1)
    meta_off = len(file_buf)
    meta_sz = len(meta_raw)
    file_buf += block_with_trailer(meta_raw)
    # Footer
    mi_handle = block_handle_bytes(meta_off, meta_sz)
    idx_handle = block_handle_bytes(index_off, index_sz)
    header = mi_handle + idx_handle
    header_padded = header + b'\x00' * (40 - len(header))
    magic = struct.pack('<Q', LEVELDB_MAGIC)
    footer = header_padded + magic
    file_buf += footer
    return {'bytes': bytes(file_buf), 'data_offsets': data_offsets,
            'index_offset': index_off, 'index_size': index_sz}

def to_memh(data, base_addr=0):
    lines = [f"@{base_addr:08x}"]
    for b in data:
        lines.append(f"{b:02x}")
    return "\n".join(lines) + "\n"

# Single data block per SSTable:
# SRC0: 5 records (keys 0,1,2,3,4) seq 10..14
# SRC1: 5 records (keys 1,2,5,6,7) seq 1..5  (keys 1,2 overlap with SRC0)
def make_records_src0():
    uk = [f"key_{i:04d}".encode() for i in range(5)]
    val = lambda k: b"val_" + k
    block0 = [(make_ikey(uk[i], seq=10+i), val(uk[i])) for i in range(5)]
    return [block0]

def make_records_src1():
    uk_dup = [f"key_{i:04d}".encode() for i in [1, 2]]
    uk_uniq = [f"key_{i:04d}".encode() for i in [5, 6, 7]]
    val = lambda k: b"old_" + k
    block0 = [(make_ikey(uk_dup[0], seq=1), val(uk_dup[0])),
              (make_ikey(uk_dup[1], seq=2), val(uk_dup[1])),
              (make_ikey(uk_uniq[0], seq=3), val(uk_uniq[0])),
              (make_ikey(uk_uniq[1], seq=4), val(uk_uniq[1])),
              (make_ikey(uk_uniq[2], seq=5), val(uk_uniq[2]))]
    return [block0]

def main():
    os.makedirs(FIXTURE_DIR, exist_ok=True)
    for name, fn in [("src0", make_records_src0), ("src1", make_records_src1)]:
        records = fn()
        result = build_sstable(records, restart_interval=2)
        raw = result['bytes']
        bin_path = os.path.join(FIXTURE_DIR, f"{name}_sstable_1blk.bin")
        with open(bin_path, 'wb') as f:
            f.write(raw)
        base = 0x0000 if name == "src0" else 0x4000
        memh_path = os.path.join(FIXTURE_DIR, f"{name}_sstable_1blk.memh")
        with open(memh_path, 'w') as f:
            f.write(to_memh(raw, base_addr=base))
        print(f"[{name}] {len(raw)} bytes, {len(result['data_offsets'])} data block(s)")
        for i, (off, sz) in enumerate(result['data_offsets']):
            print(f"  block[{i}]: off={off} size={sz}")

if __name__ == '__main__':
    main()
