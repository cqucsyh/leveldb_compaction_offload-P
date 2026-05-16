#!/usr/bin/env python3
"""Generate a realistic LevelDB data block fixture for performance benchmarking.

Outputs a .hex file (one byte per line) loadable via $readmemh in Verilog.
Also prints Verilog localparam values for the testbench.
"""
import struct, sys, os

NUM_ENTRIES = 20
USER_KEY_PREFIX = b"user_key_"     # 9 bytes
VALUE_SIZE = 64                     # bytes per value
RESTART_INTERVAL = 16
SEQ_START = 100

def encode_varint(val):
    out = bytearray()
    while val >= 0x80:
        out.append((val & 0x7F) | 0x80)
        val >>= 7
    out.append(val & 0x7F)
    return bytes(out)

def main():
    entries = []
    prev_key = b""
    restart_offsets = []
    offset = 0

    for i in range(NUM_ENTRIES):
        suffix = f"{i:03d}".encode()          # 3 bytes
        tag = struct.pack("<Q", ((SEQ_START - i) << 8) | 1)  # 8 bytes, type=value
        full_key = USER_KEY_PREFIX + suffix + tag  # 9+3+8 = 20 bytes
        value = bytes([(i * 7 + j) & 0xFF for j in range(VALUE_SIZE)])

        if i % RESTART_INTERVAL == 0:
            shared = 0
            restart_offsets.append(offset)
        else:
            shared = 0
            for k in range(min(len(prev_key), len(full_key))):
                if prev_key[k] == full_key[k]:
                    shared += 1
                else:
                    break

        unshared = len(full_key) - shared
        unshared_key = full_key[shared:]

        entry = encode_varint(shared) + encode_varint(unshared) + encode_varint(VALUE_SIZE)
        entry += unshared_key + value
        entries.append(entry)
        offset += len(entry)
        prev_key = full_key

    # Restart array
    restart_data = b""
    for ro in restart_offsets:
        restart_data += struct.pack("<I", ro)
    restart_data += struct.pack("<I", len(restart_offsets))

    block = b"".join(entries) + restart_data
    total_bytes = len(block)

    # Write hex file
    out_dir = os.path.dirname(os.path.abspath(__file__))
    hex_path = os.path.join(out_dir, "perf_block.hex")
    with open(hex_path, "w") as f:
        for b in block:
            f.write(f"{b:02x}\n")

    print(f"// Generated block: {total_bytes} bytes, {NUM_ENTRIES} entries, "
          f"{len(restart_offsets)} restarts, value_size={VALUE_SIZE}")
    print(f"localparam integer BLOCK_BYTES     = {total_bytes};")
    print(f"localparam integer EXPECTED_ENTRIES = {NUM_ENTRIES};")
    print(f"localparam integer EXPECTED_RESTARTS = {len(restart_offsets)};")
    print(f"localparam integer VALUE_SIZE       = {VALUE_SIZE};")

    # Also compute expected counters
    total_shared = 0
    total_unshared = 0
    total_value = 0
    for i in range(NUM_ENTRIES):
        suffix = f"{i:03d}".encode()
        tag = struct.pack("<Q", ((SEQ_START - i) << 8) | 1)
        full_key = USER_KEY_PREFIX + suffix + tag
        prev_suffix = f"{i-1:03d}".encode() if i > 0 else b""
        prev_tag = struct.pack("<Q", ((SEQ_START - i + 1) << 8) | 1) if i > 0 else b""
        prev_full = (USER_KEY_PREFIX + prev_suffix + prev_tag) if i > 0 else b""

        if i % RESTART_INTERVAL == 0:
            s = 0
        else:
            s = 0
            for k in range(min(len(prev_full), len(full_key))):
                if prev_full[k] == full_key[k]:
                    s += 1
                else:
                    break
        total_shared += s
        total_unshared += len(full_key) - s
        total_value += VALUE_SIZE

    print(f"localparam integer EXPECTED_SHARED_TOTAL   = {total_shared};")
    print(f"localparam integer EXPECTED_UNSHARED_TOTAL = {total_unshared};")
    print(f"localparam integer EXPECTED_VALUE_TOTAL    = {total_value};")
    print(f"// Hex file: {hex_path}")

    # Second block for source1 (different keys, interleaved)
    entries2 = []
    prev_key2 = b""
    restart_offsets2 = []
    offset2 = 0
    for i in range(NUM_ENTRIES):
        suffix = f"{i:03d}".encode()
        tag = struct.pack("<Q", ((SEQ_START - i) << 8) | 1)
        full_key = USER_KEY_PREFIX + suffix + b"B" + tag  # extra "B" to make different keys
        # Actually let's interleave: use "user_key_XXX" + "1" vs "user_key_XXX" + "0"
        # Better: source0 keys are user_key_000 to user_key_019
        # source1 keys use different user keys that interleave
        pass  # We'll use separate key spaces for now

    # Write source1 block with different user keys
    entries2 = []
    prev_key2 = b""
    restart_offsets2 = []
    offset2 = 0
    prefix2 = b"user_keyz_"  # 10 bytes - sorts after "user_key_"
    for i in range(NUM_ENTRIES):
        suffix = f"{i:03d}".encode()
        tag = struct.pack("<Q", ((SEQ_START - i) << 8) | 1)
        full_key = prefix2 + suffix + tag  # 10+3+8 = 21 bytes
        value = bytes([(i * 13 + j) & 0xFF for j in range(VALUE_SIZE)])

        if i % RESTART_INTERVAL == 0:
            shared2 = 0
            restart_offsets2.append(offset2)
        else:
            shared2 = 0
            for k in range(min(len(prev_key2), len(full_key))):
                if prev_key2[k] == full_key[k]:
                    shared2 += 1
                else:
                    break

        unshared2 = len(full_key) - shared2
        unshared_key2 = full_key[shared2:]

        entry2 = encode_varint(shared2) + encode_varint(unshared2) + encode_varint(VALUE_SIZE)
        entry2 += unshared_key2 + value
        entries2.append(entry2)
        offset2 += len(entry2)
        prev_key2 = full_key

    restart_data2 = b""
    for ro in restart_offsets2:
        restart_data2 += struct.pack("<I", ro)
    restart_data2 += struct.pack("<I", len(restart_offsets2))

    block2 = b"".join(entries2) + restart_data2
    hex_path2 = os.path.join(out_dir, "perf_block_src1.hex")
    with open(hex_path2, "w") as f:
        for b in block2:
            f.write(f"{b:02x}\n")

    print(f"// Source1 block: {len(block2)} bytes, {NUM_ENTRIES} entries")
    print(f"localparam integer BLOCK1_BYTES    = {len(block2)};")

if __name__ == "__main__":
    main()
