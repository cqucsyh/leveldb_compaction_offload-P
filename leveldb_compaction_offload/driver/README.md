# FPGA Compaction Offload Driver

Minimal C++ driver that hooks LevelDB's `DoCompactionWork` to accelerate
two-way SSTable merges on the FPGA via XDMA.

## Files

| File | Purpose |
|------|---------|
| `xdma_access.h/.cc` | Low-level XDMA wrapper (register R/W + DMA) |
| `compaction_offload.h/.cc` | Offload pipeline: DMA → hardware → DMA back → write file |
| `CMakeLists.txt` | Build integration |

LevelDB patches (minimal):
- `db/db_impl.h` – `TryHardwareCompaction()` declaration
- `db/db_impl.cc` – implementation + hook in `DoCompactionWork`

## Hardware Interface

DDR layout (fixed):
```
0x00000000  SRC0 SSTable   (≤ 1 MB)
0x00100000  SRC1 SSTable   (≤ 1 MB)
0x00200000  Output SSTable (≤ 256 KB, read-back buffer)
0x00300000  MID scratch    (1 MB)
```

AXI-Lite register map: see `cmpct_sstable_engine_axil_top.v` lines 8–38.

## Build

```bash
# In /home/yh/pp4/leveldb/build:
cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMPCT_OFFLOAD_ENABLED=ON \
  -DCMAKE_CXX_FLAGS="-DCMPCT_OFFLOAD_ENABLED"
make -j$(nproc)
```

Or add the driver manually to the existing LevelDB CMakeLists:

```cmake
option(CMPCT_OFFLOAD_ENABLED "Enable FPGA compaction offload" OFF)
if(CMPCT_OFFLOAD_ENABLED)
  target_compile_definitions(leveldb PUBLIC CMPCT_OFFLOAD_ENABLED)
  add_subdirectory(
      ${CMAKE_SOURCE_DIR}/../../leveldb_compaction_offload/driver
      ${CMAKE_BINARY_DIR}/compaction_offload_driver)
  target_link_libraries(leveldb compaction_offload_driver)
endif()
```

## Eligibility Conditions

The driver skips to software compaction if any condition fails:
- `num_input_files(0) == 1 && num_input_files(1) == 1`
- Both SSTable files ≤ 1 MB (hardware DDR limit)
- XDMA devices exist and can be opened

## Limitations (MVP)

1. **Assumes `kNoCompression`** – Snappy-compressed SSTables will be
   corrupted by the hardware decoder; add a compression check before use
   in production.
2. **Key range bounds are conservative** – `smallest`/`largest` in the
   output `FileMetaData` are the union of the two input ranges. This is
   correct but may trigger slightly more future compactions than necessary.
3. **Single output file** – The output SSTable must fit in hardware limits
   (8 block pairs × 4 KB = 32 KB data max). Larger compactions fall back
   to software automatically.
4. **Root privileges** – `/dev/xdma0_*` typically require root or a udev
   rule granting access to the LevelDB process.

## Quick Verification

After enabling the driver, look for these log lines:

```
[HW] Compaction offload: 362@0 + 568@1 => #7 (880 bytes)
compacted to: files[ 0 1 0 0 0 0 0 ]
```

And the absent `[HW] Offload failed` message.
