#!/usr/bin/env python3
"""Inspect real LevelDB SSTable files to count data blocks and extract handles."""

import struct, sys, os

LEVELDB_MAGIC = 0xdb4775248b80fb57

def decode_varint(data, offset):
    """Decode a varint from data[offset:]. Returns (value, new_offset)."""
    result = 0
    shift = 0
    while offset < len(data):
        b = data[offset]; offset += 1
        result |= (b & 0x7F) << shift
        shift += 7
        if (b & 0x80) == 0:
            return result, offset
    raise ValueError("varint truncated")

def parse_block_handle(data, offset):
    """Parse a BlockHandle (offset + size as varints)."""
    off, offset = decode_varint(data, offset)
    sz, offset = decode_varint(data, offset)
    return off, sz, offset

def inspect_sstable(path, base_addr=0):
    with open(path, 'rb') as f:
        raw = f.read()
    file_size = len(raw)
    print(f"\n=== {path} ({file_size} bytes) ===")

    # Parse footer (last 48 bytes)
    footer = raw[-48:]
    magic = struct.unpack('<Q', footer[40:48])[0]
    assert magic == LEVELDB_MAGIC, f"Bad magic: {magic:#x}"

    meta_off, meta_sz, pos = parse_block_handle(footer, 0)
    idx_off, idx_sz, pos = parse_block_handle(footer, pos)
    print(f"  MetaIndex: offset={meta_off} size={meta_sz}")
    print(f"  Index:     offset={idx_off} size={idx_sz}")

    # Parse index block to extract data block handles
    idx_data = raw[idx_off : idx_off + idx_sz]
    # Index block format: entries followed by restart array + restart_count
    # restart_count at end (last 4 bytes)
    restart_count = struct.unpack('<I', idx_data[-4:])[0]
    restarts_start = len(idx_data) - 4 - restart_count * 4
    print(f"  Index block: {restart_count} restart points, entries region = {restarts_start} bytes")

    # Parse index entries
    blocks = []
    pos = 0
    while pos < restarts_start:
        shared, pos = decode_varint(idx_data, pos)
        non_shared, pos = decode_varint(idx_data, pos)
        value_len, pos = decode_varint(idx_data, pos)
        # key: shared prefix (which we track) + non_shared bytes
        key_delta = idx_data[pos:pos+non_shared]; pos += non_shared
        value_data = idx_data[pos:pos+value_len]; pos += value_len
        # value_data is a BlockHandle
        bh_off, bh_sz, _ = parse_block_handle(value_data, 0)
        blocks.append((bh_off, bh_sz))

    print(f"  Data blocks: {len(blocks)}")
    total_records = 0
    for i, (boff, bsz) in enumerate(blocks):
        abs_addr = base_addr + boff
        # Count records in this data block
        blk_data = raw[boff : boff + bsz]
        rc = struct.unpack('<I', blk_data[-4:])[0]  # restart_count
        # Count entries by walking the block
        entries_end = len(blk_data) - 4 - rc * 4
        epos = 0; rec_count = 0
        while epos < entries_end:
            sh, epos = decode_varint(blk_data, epos)
            ns, epos = decode_varint(blk_data, epos)
            vl, epos = decode_varint(blk_data, epos)
            epos += ns + vl
            rec_count += 1
        total_records += rec_count
        print(f"    block[{i:2d}]: abs=0x{abs_addr:08x} off={boff:5d} size={bsz:4d} records={rec_count}")

    print(f"  Total records: {total_records}")
    return len(blocks), total_records

if __name__ == '__main__':
    fix = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
    n0, r0 = inspect_sstable(os.path.join(fix, "src0_real.sst"), base_addr=0x0)
    n1, r1 = inspect_sstable(os.path.join(fix, "src1_real.sst"), base_addr=0x10000)

    pairs = max(n0, n1)
    print(f"\n=== Summary ===")
    print(f"  SRC0: {n0} data blocks, {r0} records")
    print(f"  SRC1: {n1} data blocks, {r1} records")
    print(f"  Block pairs = {pairs}")
    print(f"  Expected src0_decoded = {r0}")
    print(f"  Expected src1_decoded = {r1}")
