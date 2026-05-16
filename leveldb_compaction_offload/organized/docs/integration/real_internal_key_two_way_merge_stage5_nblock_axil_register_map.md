# N-Block 2-Source Feeder + 2-Way Merge + Stage5 AXI-Lite Register Map

## Overview

`stage4_real_internal_key_two_way_merge_stage5_nblock_axil_top` is the board-facing AXI-Lite wrapper for the N-block continuous compaction path.

One `start` processes `1..MAX_BLOCK_PAIRS` sequential block-pairs:

- block-pair `i`: `src0_base[i]/src0_size[i]` + `src1_base[i]/src1_size[i]` -> `dst_base[i]`

All processed block-pairs reuse one shared `MID` scratch region.

The wrapper preserves the previous user key across every processed block-pair boundary in one run. This means adjacent duplicate-suppression semantics continue from block-pair `i` into block-pair `i+1`, rather than resetting at each block boundary.

The current hardware contract is intentionally minimal:

- maximum block-pairs per run: `MAX_BLOCK_PAIRS`
- one Stage5 output block is emitted per processed block-pair
- aggregate counters sum all processed block-pairs in one run
- per-destination output-byte readback is available for every descriptor index

## AXI interfaces

The wrapper exposes three AXI master interfaces in `ui_aclk` domain:

- **`m_axi_src0`**
  - Read-only
  - Used for every configured `src0` block descriptor

- **`m_axi_src1`**
  - Read-only
  - Used for every configured `src1` block descriptor

- **`m_axi_chain`**
  - Read/write
  - Used by merge writeback to `MID` and Stage5 read/write to every `DST` block

## Control semantics

### `REG_CTRL`

- **Bit 0 `start`**
  - Write `1` to launch a new N-block run
  - Converted into a one-shot `ui_aclk` pulse
  - Cleared by software after issuing the pulse

- **Bit 1 `clear`**
  - Write `1` to clear sticky `done/error` and issue a UI-domain clear pulse
  - Cleared by software after issuing the pulse

### `REG_STATUS`

- **Bit 0 `busy`**
  - Mirrors UI-domain N-block sequencer busy state

- **Bit 1 `done`**
  - Sticky success indication for the full run
  - Set after the last requested block-pair completes
  - Cleared by `clear` or next `start`

- **Bit 2 `error`**
  - Sticky error indication
  - Set if any inner feeder/merge/Stage5 run errors or if `block_pair_count` is invalid
  - Cleared by `clear` or next `start`

## Addressing model

The AXI-Lite map has three regions:

- **Compatibility window**
  - Fixed offsets for block-pair `0` and block-pair `1`
  - Preserves compatibility with the validated 2-block multiblock scripts

- **Generic descriptor window**
  - `REG_DESC_BASE + REG_DESC_STRIDE * i`
  - Available for every descriptor index `i` in `0..MAX_BLOCK_PAIRS-1`
  - Software may use this window for all descriptors, but current bring-up scripts usually keep pair `0/1` on the compatibility window and use the generic window for pair `2+`

- **Generic output-byte window**
  - `REG_DESC_DST_OUTPUT_BYTES_BASE + 4 * i`
  - Returns the Stage5 output byte count for descriptor index `i`
  - Pair `0` and pair `1` also remain available through `REG_DST0_OUTPUT_BLOCK_BYTES` and `REG_DST1_OUTPUT_BLOCK_BYTES`

## Register map

### Base window

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x0000` | `REG_CTRL` | RW | bit0=`start`, bit1=`clear` |
| `0x0004` | `REG_STATUS` | RO | bit0=`busy`, bit1=`done`, bit2=`error` |
| `0x0008` | `REG_BLOCK_PAIR_COUNT` | RW | Number of sequential block-pairs to process, valid range: `1..MAX_BLOCK_PAIRS` |
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
| `0x008C` | `REG_TOTAL_STAGE5_OUTPUT_BLOCK_BYTES` | RO | Sum of output block bytes across all processed destinations |
| `0x0090` | `REG_TOTAL_STAGE5_BYTES_WRITTEN` | RO | Sum of Stage5 AXI bytes written |

### Generic descriptor window

Let:

- `REG_DESC_BASE = 0x0100`
- `REG_DESC_STRIDE = 0x0020`
- `DESC(i) = REG_DESC_BASE + REG_DESC_STRIDE * i`

Then for each descriptor index `i`:

| Offset | Name | Access | Description |
|---|---|---|---|
| `DESC(i) + 0x00` | `REG_DESC_SRC0_BASE_LO(i)` | RW | Source0 base low 32 bits for descriptor `i` |
| `DESC(i) + 0x04` | `REG_DESC_SRC0_BASE_HI(i)` | RW | Source0 base high 32 bits for descriptor `i` |
| `DESC(i) + 0x08` | `REG_DESC_SRC0_SIZE(i)` | RW | Source0 byte count for descriptor `i` |
| `DESC(i) + 0x0C` | `REG_DESC_SRC1_BASE_LO(i)` | RW | Source1 base low 32 bits for descriptor `i` |
| `DESC(i) + 0x10` | `REG_DESC_SRC1_BASE_HI(i)` | RW | Source1 base high 32 bits for descriptor `i` |
| `DESC(i) + 0x14` | `REG_DESC_SRC1_SIZE(i)` | RW | Source1 byte count for descriptor `i` |
| `DESC(i) + 0x18` | `REG_DESC_DST_BASE_LO(i)` | RW | Destination base low 32 bits for descriptor `i` |
| `DESC(i) + 0x1C` | `REG_DESC_DST_BASE_HI(i)` | RW | Destination base high 32 bits for descriptor `i` |

### Generic per-descriptor output-byte window

Let:

- `REG_DESC_DST_OUTPUT_BYTES_BASE = 0x0200`

Then for each descriptor index `i`:

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x0200 + 4*i` | `REG_DESC_DST_OUTPUT_BYTES(i)` | RO | Output bytes written to destination block `i` |

## Bring-up sequence

1. Write `REG_CTRL=0x2` then `REG_CTRL=0x0`
2. Program `REG_BLOCK_PAIR_COUNT` to the number of block-pairs to process
3. Program shared `MID_BASE`
4. Program block-pair `0` descriptors
5. If `block_pair_count >= 2`, program block-pair `1` descriptors
6. If `block_pair_count >= 3`, program block-pair `2+` descriptors through the generic descriptor window
7. Initialize destination DDR ranges with a known fill pattern such as `0xA5`
8. Write `REG_CTRL=0x1` then `REG_CTRL=0x0`
9. Poll `REG_STATUS`
10. Read `REG_BLOCKS_COMPLETED`, per-destination output bytes, and aggregate counters
11. Read back the processed destination blocks for verification

## Software notes

- Pair `0` and pair `1` are readable and writable through both the compatibility window and the generic descriptor window
- Current bring-up scripts use the compatibility window for pair `0/1` and the generic window for pair `2+`
- Current board validation has already passed a focused 3-block scenario that programs descriptor index `2` through the generic window and reads back `REG_DESC_DST_OUTPUT_BYTES(2)` from `0x0208`

## Board-level assumptions

- All DDR base addresses should be 64-byte aligned for current XDMA tooling
- `SRC0[i]`, `SRC1[i]`, `MID`, and `DST[i]` must not overlap for any programmed descriptor
- Each source block must remain internally sorted by user key ascending and internal tag descending for duplicate versions of one user key
- `MID` must be large enough for the largest intermediate counted-record payload of any processed block-pair
- `bytes_done` mirrors `REG_TOTAL_STAGE5_BYTES_WRITTEN`
- `blocks_done` mirrors `REG_BLOCKS_COMPLETED`
