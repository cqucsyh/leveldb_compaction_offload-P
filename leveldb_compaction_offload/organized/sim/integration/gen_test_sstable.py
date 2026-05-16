#!/usr/bin/env python3
"""
gen_test_sstable.py

Generates real LevelDB SSTable binary files for simulation of
cmpct_sstable_parser (sstable_data_block_handle_emitter).

Outputs:
  fixtures/src0_sstable_real.bin   - SRC0 SSTable binary
  fixtures/src1_sstable_real.bin   - SRC1 SSTable binary
  fixtures/src0_sstable_real.memh  - hex dump for $readmemh
  fixtures/src1_sstable_real.memh  - hex dump for $readmemh
  fixtures/sstable_expected.txt    - expected block handles for verification

LevelDB SSTable format used here:
  [Data Block 0] [5-byte trailer]
  ...
  [Data Block N] [5-byte trailer]
  [Index Block]  [5-byte trailer]
  [MetaIndex Block] [5-byte trailer]
  [Footer 48 bytes]

All blocks use compression_type=0 (uncompressed).  CRC is zeroed
(simulation only; RTL parser does not verify CRC).
"""

import struct
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(SCRIPT_DIR, "fixtures")

LEVELDB_MAGIC = 0x57fb808b24e46a97


# ---------------------------------------------------------------------------
# Varint helpers
# ---------------------------------------------------------------------------

def varint32(v: int) -> bytes:
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


def varint64(v: int) -> bytes:
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


def block_handle_bytes(offset: int, size: int) -> bytes:
    return varint64(offset) + varint64(size)


# ---------------------------------------------------------------------------
# Internal key helpers
# ---------------------------------------------------------------------------
# LevelDB internal key = user_key + tag(8 bytes LE)
# tag = (sequence_number << 8) | value_type
# value_type: 1 = kTypeValue, 0 = kTypeDeletion

def make_ikey(user_key: bytes, seq: int, vtype: int = 1) -> bytes:
    tag = (seq << 8) | vtype
    return user_key + struct.pack('<Q', tag)


# ---------------------------------------------------------------------------
# Block encoder
# ---------------------------------------------------------------------------

def encode_block(records: list, restart_interval: int = 16) -> bytes:
    """
    Encode sorted (key_bytes, value_bytes) pairs into a LevelDB block body.
    No trailer.  restart_interval controls how often a restart point is inserted.
    """
    if not records:
        # Empty block: just restart_count=0
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


def block_with_trailer(data: bytes) -> bytes:
    """Append 5-byte block trailer (no-compression, CRC=0)."""
    return data + b'\x00' + struct.pack('<I', 0)


# ---------------------------------------------------------------------------
# SSTable builder
# ---------------------------------------------------------------------------

def build_sstable(data_block_records: list, restart_interval: int = 2) -> dict:
    """
    Build a complete LevelDB SSTable.

    data_block_records: list[list[(key_bytes, value_bytes)]]
                        Each sub-list becomes one data block.
                        Records must be sorted by key within each block,
                        and the last key of block[i] < first key of block[i+1].

    Returns a dict with:
      'bytes'         : complete SSTable bytes
      'data_offsets'  : list of (abs_offset, data_size) for each data block
      'index_offset'  : abs offset of index block
      'index_size'    : size of index block data (no trailer)
    """
    file_buf = bytearray()
    data_offsets = []    # (abs_offset_in_file, size_without_trailer)

    # --- Write data blocks ---
    for records in data_block_records:
        raw = encode_block(records, restart_interval)
        data_offsets.append((len(file_buf), len(raw)))
        file_buf += block_with_trailer(raw)

    # --- Build index block ---
    # Each entry: key = separator key for data block (= last key in block)
    #             value = BlockHandle(offset, size) of that data block
    index_entries = []
    for i, records in enumerate(data_block_records):
        largest_key = sorted(r[0] for r in records)[-1]
        off, sz = data_offsets[i]
        index_entries.append((largest_key, block_handle_bytes(off, sz)))
    # Sort by key (should already be sorted if data blocks are sorted)
    index_entries.sort(key=lambda e: e[0])
    index_raw = encode_block(index_entries, restart_interval=1)
    index_off = len(file_buf)
    index_sz  = len(index_raw)
    file_buf  += block_with_trailer(index_raw)

    # --- Build metaindex block (empty) ---
    meta_raw = encode_block([], restart_interval=1)
    meta_off = len(file_buf)
    meta_sz  = len(meta_raw)
    file_buf += block_with_trailer(meta_raw)

    # --- Build footer (48 bytes) ---
    mi_handle = block_handle_bytes(meta_off, meta_sz)
    idx_handle = block_handle_bytes(index_off, index_sz)
    header = mi_handle + idx_handle
    assert len(header) <= 40, f"Handle encoding too large: {len(header)}"
    header_padded = header + b'\x00' * (40 - len(header))
    magic = struct.pack('<Q', LEVELDB_MAGIC)
    footer = header_padded + magic
    assert len(footer) == 48
    file_buf += footer

    return {
        'bytes':        bytes(file_buf),
        'data_offsets': data_offsets,
        'index_offset': index_off,
        'index_size':   index_sz,
    }


# ---------------------------------------------------------------------------
# Binary → .memh  (4-byte words, little-endian, $readmemh compatible)
# ---------------------------------------------------------------------------

def to_memh(data: bytes, base_addr: int = 0) -> str:
    """
    Convert raw bytes to a Verilog $readmemh compatible hex file.
    Each line is one byte as 2 hex digits.
    An @address comment marks the start.
    """
    lines = [f"@{base_addr:08x}"]
    for b in data:
        lines.append(f"{b:02x}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Test data
# ---------------------------------------------------------------------------
# LevelDB internal key = user_key + 8-byte tag (seq<<8|type)
# We arrange:
#   SRC0: sequence numbers 10..19  (newer for overlapping keys)
#   SRC1: sequence numbers 1..9   (older for overlapping keys)
#
# Block layout:
#   src0_block0: key_a0, key_a1, key_a2  (user keys aaa_0, aaa_1, aaa_2)
#   src0_block1: key_b0, key_b1, key_b2
#
#   src1_block0: key_a1 (older dup), key_a3, key_a4
#   src1_block1: key_b2 (older dup), key_b3

def make_records_src0():
    uk = [f"key_{i:04d}".encode() for i in [0, 1, 2, 10, 11, 20, 21, 22]]
    val = lambda k: b"val_" + k
    # Two blocks: block0 = uk[0..3], block1 = uk[4..7]
    block0 = [(make_ikey(uk[i], seq=10+i), val(uk[i])) for i in range(4)]
    block1 = [(make_ikey(uk[i], seq=10+i), val(uk[i])) for i in range(4, 8)]
    return [block0, block1]


def make_records_src1():
    # Overlapping keys: key_0001, key_0002 (older seqs), plus unique keys
    uk_dup  = [f"key_{i:04d}".encode() for i in [1, 2]]   # duplicated in src0
    uk_uniq = [f"key_{i:04d}".encode() for i in [5, 6, 30, 31]]
    val = lambda k: b"old_" + k

    block0 = ([(make_ikey(uk_dup[0], seq=3),  val(uk_dup[0])),
               (make_ikey(uk_dup[1], seq=4),  val(uk_dup[1])),
               (make_ikey(uk_uniq[0], seq=5), val(uk_uniq[0])),
               (make_ikey(uk_uniq[1], seq=6), val(uk_uniq[1]))])
    block1 = ([(make_ikey(uk_uniq[2], seq=7), val(uk_uniq[2])),
               (make_ikey(uk_uniq[3], seq=8), val(uk_uniq[3]))])
    return [block0, block1]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    os.makedirs(FIXTURE_DIR, exist_ok=True)

    for name, block_records_fn in [("src0", make_records_src0),
                                   ("src1", make_records_src1)]:
        records = block_records_fn()
        result  = build_sstable(records, restart_interval=2)

        raw       = result['bytes']
        data_offs = result['data_offsets']
        idx_off   = result['index_offset']
        idx_sz    = result['index_size']

        # Write binary
        bin_path = os.path.join(FIXTURE_DIR, f"{name}_sstable_real.bin")
        with open(bin_path, 'wb') as f:
            f.write(raw)
        print(f"[{name}] wrote {bin_path}  ({len(raw)} bytes)")

        # Write .memh  (base_addr 0 for SRC0, 0x4000 for SRC1)
        base = 0x0000 if name == "src0" else 0x4000
        memh_path = os.path.join(FIXTURE_DIR, f"{name}_sstable_real.memh")
        with open(memh_path, 'w') as f:
            f.write(to_memh(raw, base_addr=base))
        print(f"[{name}] wrote {memh_path}")

        # Print handle summary
        print(f"[{name}] SSTable size        : {len(raw)}")
        print(f"[{name}] number of data blocks: {len(data_offs)}")
        for i, (off, sz) in enumerate(data_offs):
            abs_addr = base + off
            print(f"[{name}]   block[{i}]: abs_addr=0x{abs_addr:08x}  "
                  f"size={sz}  (file_off={off})")
        print(f"[{name}] index block: file_off={idx_off}  size={idx_sz}")
        print()

    # Write expected handles file
    exp_path = os.path.join(FIXTURE_DIR, "sstable_expected.txt")
    with open(exp_path, 'w') as f:
        for name, base, block_records_fn in [
                ("src0", 0x0000, make_records_src0),
                ("src1", 0x4000, make_records_src1)]:
            records = block_records_fn()
            result  = build_sstable(records, restart_interval=2)
            f.write(f"# {name}  base=0x{base:08x}  total_size={len(result['bytes'])}\n")
            f.write(f"sstable_size={len(result['bytes'])}\n")
            f.write(f"block_count={len(result['data_offsets'])}\n")
            for i, (off, sz) in enumerate(result['data_offsets']):
                f.write(f"block[{i}]: abs_addr=0x{base+off:016x} size={sz}\n")
            f.write("\n")
    print(f"Wrote expected handles to {exp_path}")

    # Also dump footer bytes for manual inspection
    print("\n--- Footer bytes (last 48) ---")
    for name, base, block_records_fn in [("src0", 0x0000, make_records_src0),
                                         ("src1", 0x4000, make_records_src1)]:
        records = block_records_fn()
        result  = build_sstable(records, restart_interval=2)
        raw = result['bytes']
        footer = raw[-48:]
        print(f"[{name}] footer hex: {footer.hex(' ')}")


if __name__ == '__main__':
    main()
