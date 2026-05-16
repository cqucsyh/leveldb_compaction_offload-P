#!/usr/bin/env python3
"""
gen_test_sstable_asymmetric.py

Generates asymmetric SSTable fixtures for testing asymmetric block-pair handling:
  SRC0: 2 data blocks  (the "shorter" side)
  SRC1: 4 data blocks  (the "longer" side)

Block pairing after fix:
  Pair 0: src0.block0 [key_0000..0003] + src1.block0 [key_0004..0006]  → 7 kept, 0 dropped
  Pair 1: src0.block1 [key_0010..0013] + src1.block1 [key_0014..0016]  → 7 kept, 0 dropped
  Pair 2: src0=EMPTY  +                  src1.block2 [key_0020..0022]  → 3 kept, 0 dropped
  Pair 3: src0=EMPTY  +                  src1.block3 [key_0030..0032]  → 3 kept, 0 dropped

No cross-source duplicate keys → all 20 records kept.

Expected totals:
  block_pair_count   = 4
  src0_decoded       = 8   (4+4+0+0)
  src1_decoded       = 12  (3+3+3+3)
  merge_decoded      = 20  (7+7+3+3)
  merge_merged       = 20
  merge_dropped      = 0
  stage5_input       = 20
  stage5_encoded     = 20
  dst_output_bytes[0..3] all > 0

Outputs written to fixtures/:
  src0_asym_real.memh  @0x00000000
  src1_asym_real.memh  @0x00004000
  asym_expected.txt    human-readable summary
"""

import struct, os

SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR  = os.path.join(SCRIPT_DIR, "fixtures")
LEVELDB_MAGIC = 0x57fb808b24e46a97


# ---------------------------------------------------------------------------
# Varint helpers
# ---------------------------------------------------------------------------
def varint(v: int) -> bytes:
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
    return varint(offset) + varint(size)


# ---------------------------------------------------------------------------
# Internal key: user_key + 8-byte tag (seq<<8|type)
# ---------------------------------------------------------------------------
def ikey(user_key: bytes, seq: int, vtype: int = 1) -> bytes:
    return user_key + struct.pack('<Q', (seq << 8) | vtype)


# ---------------------------------------------------------------------------
# Block encoder  (shared/unshared prefix compression, zero CRC trailer)
# ---------------------------------------------------------------------------
def encode_block(records, restart_interval: int = 2) -> bytes:
    if not records:
        return struct.pack('<I', 0)
    buf = bytearray()
    restarts = []
    prev = b''
    for idx, (k, v) in enumerate(records):
        if idx % restart_interval == 0:
            restarts.append(len(buf))
            shared = 0
        else:
            shared = 0
            mn = min(len(prev), len(k))
            while shared < mn and prev[shared] == k[shared]:
                shared += 1
        unshared = len(k) - shared
        buf += varint(shared) + varint(unshared) + varint(len(v))
        buf += k[shared:] + v
        prev = k
    for r in restarts:
        buf += struct.pack('<I', r)
    buf += struct.pack('<I', len(restarts))
    return bytes(buf)


def block_with_trailer(data: bytes) -> bytes:
    return data + b'\x00' + struct.pack('<I', 0)


# ---------------------------------------------------------------------------
# SSTable builder
# ---------------------------------------------------------------------------
def build_sstable(data_block_records, restart_interval: int = 2) -> dict:
    buf = bytearray()
    data_offsets = []
    for recs in data_block_records:
        raw = encode_block(recs, restart_interval)
        data_offsets.append((len(buf), len(raw)))
        buf += block_with_trailer(raw)

    # Index block
    idx_entries = []
    for i, recs in enumerate(data_block_records):
        last_key = sorted(r[0] for r in recs)[-1]
        off, sz  = data_offsets[i]
        idx_entries.append((last_key, block_handle_bytes(off, sz)))
    idx_entries.sort(key=lambda e: e[0])
    idx_raw = encode_block(idx_entries, restart_interval=1)
    idx_off = len(buf); idx_sz = len(idx_raw)
    buf += block_with_trailer(idx_raw)

    # MetaIndex block (empty)
    meta_raw = encode_block([], restart_interval=1)
    meta_off = len(buf); meta_sz = len(meta_raw)
    buf += block_with_trailer(meta_raw)

    # Footer
    header = block_handle_bytes(meta_off, meta_sz) + block_handle_bytes(idx_off, idx_sz)
    assert len(header) <= 40
    footer = header + b'\x00' * (40 - len(header)) + struct.pack('<Q', LEVELDB_MAGIC)
    assert len(footer) == 48
    buf += footer

    return {'bytes': bytes(buf), 'data_offsets': data_offsets,
            'index_offset': idx_off, 'index_size': idx_sz}


def to_memh(data: bytes, base_addr: int = 0) -> str:
    lines = [f"@{base_addr:08x}"]
    for b in data:
        lines.append(f"{b:02x}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Fixture data
# ---------------------------------------------------------------------------
def make_src0():
    """2 data blocks; keys do not appear in src1 (no cross-source duplicates)."""
    val = lambda k: b"v0_" + k
    b0 = [(ikey(f"key_{i:04d}".encode(), 20 + i), val(f"key_{i:04d}".encode()))
          for i in [0, 1, 2, 3]]
    b1 = [(ikey(f"key_{i:04d}".encode(), 24 + i - 10), val(f"key_{i:04d}".encode()))
          for i in [10, 11, 12, 13]]
    return [b0, b1]


def make_src1():
    """4 data blocks; keys interleave with src0 per pair but never overlap."""
    val = lambda k: b"v1_" + k
    b0 = [(ikey(f"key_{i:04d}".encode(), i), val(f"key_{i:04d}".encode()))
          for i in [4, 5, 6]]
    b1 = [(ikey(f"key_{i:04d}".encode(), i - 7), val(f"key_{i:04d}".encode()))
          for i in [14, 15, 16]]
    b2 = [(ikey(f"key_{i:04d}".encode(), i - 10), val(f"key_{i:04d}".encode()))
          for i in [20, 21, 22]]
    b3 = [(ikey(f"key_{i:04d}".encode(), i - 17), val(f"key_{i:04d}".encode()))
          for i in [30, 31, 32]]
    return [b0, b1, b2, b3]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    os.makedirs(FIXTURE_DIR, exist_ok=True)

    fixtures = [("src0_asym", 0x00000000, make_src0),
                ("src1_asym", 0x00004000, make_src1)]

    sizes = {}
    for name, base, fn in fixtures:
        recs   = fn()
        result = build_sstable(recs, restart_interval=2)
        raw    = result['bytes']
        sizes[name] = len(raw)

        bin_path  = os.path.join(FIXTURE_DIR, f"{name}_real.bin")
        memh_path = os.path.join(FIXTURE_DIR, f"{name}_real.memh")
        with open(bin_path, 'wb') as f:
            f.write(raw)
        with open(memh_path, 'w') as f:
            f.write(to_memh(raw, base_addr=base))

        print(f"[{name}] {len(raw)} bytes, {len(recs)} blocks")
        for i, (off, sz) in enumerate(result['data_offsets']):
            print(f"  block[{i}]: abs=0x{base+off:08x} size={sz}")

    # Write summary for TB comment
    exp_path = os.path.join(FIXTURE_DIR, "asym_expected.txt")
    with open(exp_path, 'w') as f:
        f.write("# Asymmetric SSTable fixture summary\n")
        f.write(f"# SRC0: {sizes['src0_asym']} bytes  2 blocks\n")
        f.write(f"# SRC1: {sizes['src1_asym']} bytes  4 blocks\n")
        f.write("#\n")
        f.write("# Expected counters:\n")
        f.write("#   block_pair_count = 4  (max of 2,4)\n")
        f.write("#   src0_decoded     = 8  (4+4+0+0)\n")
        f.write("#   src1_decoded     = 12 (3+3+3+3)\n")
        f.write("#   merge_decoded    = 20\n")
        f.write("#   merge_merged     = 20  (all kept, no cross-source dups)\n")
        f.write("#   merge_dropped    = 0\n")
        f.write("#   stage5_input     = 20\n")
        f.write("#   stage5_encoded   = 20\n")
        f.write(f"src0_size={sizes['src0_asym']}\n")
        f.write(f"src1_size={sizes['src1_asym']}\n")
    print(f"\nWrote {exp_path}")
    print(f"\nsrc0_size={sizes['src0_asym']}")
    print(f"src1_size={sizes['src1_asym']}")


if __name__ == '__main__':
    main()
