# 2-Block 2-Source Feeder + 2-Way Merge + Stage5 AXI-Lite Register Map

## Overview

`real_internal_key_two_way_merge_stage5_multiblock_top` is a board-facing wrapper for a minimal multi-block continuous compaction path.

One `start` processes up to 2 sequential block-pairs:

- block-pair 0: `src0_base0/src0_size0` + `src1_base0/src1_size0` -> `dst_base0`
- block-pair 1: `src0_base1/src0_size1` + `src1_base1/src1_size1` -> `dst_base1`

Both block-pairs reuse one shared `MID` scratch region.

The key difference versus the old single-block feeder wrapper is that the merge path preserves the previous user key across the boundary between block-pair 0 and block-pair 1. This allows adjacent duplicate-suppression semantics to continue across block boundaries.

The current hardware contract is intentionally minimal:

- maximum block-pairs per run: `2`
- one Stage5 output block is emitted per processed block-pair
- the wrapper reports per-destination output bytes for `dst0` and `dst1`
- aggregate counters sum both processed block-pairs in one run

## AXI interfaces

The wrapper exposes three AXI master interfaces in `ui_aclk` domain:

- **`m_axi_src0`**
  - Read-only
  - Used for both `src0` block-pairs

- **`m_axi_src1`**
  - Read-only
  - Used for both `src1` block-pairs

- **`m_axi_chain`**
  - Read/write
  - Used by merge writeback to `MID` and Stage5 read/write to `DST0/DST1`

## Control semantics

### `REG_CTRL`

- **Bit 0 `start`**
  - Write `1` to launch a new multi-block run
  - Converted into a one-shot `ui_aclk` pulse
  - Cleared by software after issuing the pulse

- **Bit 1 `clear`**
  - Write `1` to clear sticky `done/error` and issue a UI-domain clear pulse
  - Cleared by software after issuing the pulse

### `REG_STATUS`

- **Bit 0 `busy`**
  - Mirrors UI-domain multiblock sequencer busy state

- **Bit 1 `done`**
  - Sticky success indication for the full run
  - Set after the last requested block-pair completes
  - Cleared by `clear` or next `start`

- **Bit 2 `error`**
  - Sticky error indication
  - Set if any inner feeder/merge/Stage5 run errors or if `block_pair_count` is invalid
  - Cleared by `clear` or next `start`

## Register map

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x0000` | `REG_CTRL` | RW | bit0=`start`, bit1=`clear` |
| `0x0004` | `REG_STATUS` | RO | bit0=`busy`, bit1=`done`, bit2=`error` |
| `0x0008` | `REG_BLOCK_PAIR_COUNT` | RW | Number of sequential block-pairs to process, valid values: `1` or `2` |
| `0x000C` | `REG_MID_BASE_LO` | RW | Shared `MID` base address low 32 bits |
| `0x0010` | `REG_MID_BASE_HI` | RW | Shared `MID` base address high 32 bits |
| `0x0014` | `REG_SRC0_BASE0_LO` | RW | Block-pair 0 source0 base low 32 bits |
| `0x0018` | `REG_SRC0_BASE0_HI` | RW | Block-pair 0 source0 base high 32 bits |
| `0x001C` | `REG_SRC0_SIZE0` | RW | Block-pair 0 source0 byte count |
| `0x0020` | `REG_SRC1_BASE0_LO` | RW | Block-pair 0 source1 base low 32 bits |
| `0x0024` | `REG_SRC1_BASE0_HI` | RW | Block-pair 0 source1 base high 32 bits |
| `0x0028` | `REG_SRC1_SIZE0` | RW | Block-pair 0 source1 byte count |
| `0x002C` | `REG_DST_BASE0_LO` | RW | Block-pair 0 destination base low 32 bits |
| `0x0030` | `REG_DST_BASE0_HI` | RW | Block-pair 0 destination base high 32 bits |
| `0x0034` | `REG_SRC0_BASE1_LO` | RW | Block-pair 1 source0 base low 32 bits |
| `0x0038` | `REG_SRC0_BASE1_HI` | RW | Block-pair 1 source0 base high 32 bits |
| `0x003C` | `REG_SRC0_SIZE1` | RW | Block-pair 1 source0 byte count |
| `0x0040` | `REG_SRC1_BASE1_LO` | RW | Block-pair 1 source1 base low 32 bits |
| `0x0044` | `REG_SRC1_BASE1_HI` | RW | Block-pair 1 source1 base high 32 bits |
| `0x0048` | `REG_SRC1_SIZE1` | RW | Block-pair 1 source1 byte count |
| `0x004C` | `REG_DST_BASE1_LO` | RW | Block-pair 1 destination base low 32 bits |
| `0x0050` | `REG_DST_BASE1_HI` | RW | Block-pair 1 destination base high 32 bits |
| `0x0054` | `REG_ACTIVE_BLOCK_INDEX` | RO | Currently active block-pair index |
| `0x0058` | `REG_BLOCKS_COMPLETED` | RO | Number of completed block-pairs in this run |
| `0x005C` | `REG_DST0_OUTPUT_BLOCK_BYTES` | RO | Output bytes written to `DST0` |
| `0x0060` | `REG_DST1_OUTPUT_BLOCK_BYTES` | RO | Output bytes written to `DST1` |
| `0x0064` | `REG_TOTAL_SOURCE0_DECODED_ENTRY_COUNT` | RO | Sum of source0 decoded entries across the run |
| `0x0068` | `REG_TOTAL_SOURCE1_DECODED_ENTRY_COUNT` | RO | Sum of source1 decoded entries across the run |
| `0x006C` | `REG_TOTAL_SOURCE0_BYTES_READ` | RO | Sum of source0 AXI bytes read |
| `0x0070` | `REG_TOTAL_SOURCE1_BYTES_READ` | RO | Sum of source1 AXI bytes read |
| `0x0074` | `REG_TOTAL_MERGE_OUTPUT_BYTE_COUNT` | RO | Sum of merged counted-stream bytes written to `MID` |
| `0x0078` | `REG_TOTAL_MERGE_DECODED_RECORD_COUNT` | RO | Sum of merge input records seen across all processed block-pairs |
| `0x007C` | `REG_TOTAL_MERGE_MERGED_RECORD_COUNT` | RO | Sum of kept records after duplicate suppression |
| `0x0080` | `REG_TOTAL_MERGE_DROPPED_COUNT` | RO | Sum of dropped superseded records |
| `0x0084` | `REG_TOTAL_STAGE5_INPUT_RECORD_COUNT` | RO | Sum of records consumed by Stage5 |
| `0x0088` | `REG_TOTAL_STAGE5_ENCODED_ENTRY_COUNT` | RO | Sum of Stage5 encoded entries |
| `0x008C` | `REG_TOTAL_STAGE5_OUTPUT_BLOCK_BYTES` | RO | Sum of output block bytes across `DST0` and `DST1` |
| `0x0090` | `REG_TOTAL_STAGE5_BYTES_WRITTEN` | RO | Sum of Stage5 AXI bytes written |

## Bring-up sequence

1. Write `REG_CTRL=0x2` then `REG_CTRL=0x0`
2. Program `REG_BLOCK_PAIR_COUNT` to `1` or `2`
3. Program `MID_BASE`
4. Program all source/destination descriptors for block-pair 0
5. If `REG_BLOCK_PAIR_COUNT=2`, also program block-pair 1 descriptors
6. Initialize destination DDR ranges with a known fill pattern such as `0xA5`
7. Write `REG_CTRL=0x1` then `REG_CTRL=0x0`
8. Poll `REG_STATUS`
9. Read `REG_BLOCKS_COMPLETED`, `REG_DST0_OUTPUT_BLOCK_BYTES`, `REG_DST1_OUTPUT_BLOCK_BYTES`, and aggregate counters
10. Read back `DST0` and `DST1` for verification

## Board-level assumptions

- All DDR base addresses should be 64-byte aligned for current XDMA tooling
- `SRC0_0`, `SRC1_0`, `SRC0_1`, `SRC1_1`, `MID`, `DST0`, and `DST1` must not overlap
- Each source block must remain internally sorted by user key ascending and internal tag descending for duplicate versions of one user key
- `MID` must be large enough for the largest intermediate counted-record payload of any processed block-pair
- `bytes_done` mirrors `REG_TOTAL_STAGE5_BYTES_WRITTEN`
- `blocks_done` mirrors `REG_BLOCKS_COMPLETED`
