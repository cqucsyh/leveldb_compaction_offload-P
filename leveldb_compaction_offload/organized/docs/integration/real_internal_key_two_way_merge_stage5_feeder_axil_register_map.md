# 2-Source Feeder + 2-Way Merge + Stage5 AXI-Lite Register Map

## Overview

`real_internal_key_two_way_merge_stage5_feeder_top` is the board-facing wrapper for the fully integrated flow:

- source0 DDR read + real data-block decode + record emit
- source1 DDR read + real data-block decode + record emit
- 2-way real internal-key merge to `MID`
- Stage5 real LevelDB block encode from `MID` to `DST`

The AXI-Lite control plane is implemented by `stage4_real_internal_key_two_way_merge_stage5_chain_axil_top`.

Unlike the earlier `real_internal_key_two_way_merge_stage5_chain_board_top`, this integrated feeder wrapper owns the two upstream record-stream producers internally. Software only needs to program:

- source0 DDR base and byte count
- source1 DDR base and byte count
- `MID` DDR base
- `DST` DDR base

## AXI interfaces

The board-facing wrapper exposes three AXI master interfaces in `ui_aclk` domain:

- **`m_axi_src0`**
  - Read-only
  - Used by source0 feeder

- **`m_axi_src1`**
  - Read-only
  - Used by source1 feeder

- **`m_axi_chain`**
  - Read/write
  - Used by the merge writeback to `MID` and Stage5 read/write path

A block design should connect all three masters to DDR through the platform interconnect.

## Control semantics

### `REG_CTRL`

- **Bit 0 `start`**
  - Write `1` to request a new run
  - Converted into a one-shot `ui_aclk` pulse
  - Auto-clears after the edge is consumed

- **Bit 1 `clear`**
  - Write `1` to clear sticky status and issue a UI-domain clear pulse
  - Auto-clears after the edge is consumed

### `REG_STATUS`

- **Bit 0 `busy`**
  - Mirrors integrated-top busy state

- **Bit 1 `done`**
  - Sticky done indication
  - Set when the full feeder + merge + Stage5 run completes successfully
  - Cleared by `clear` or next `start`

- **Bit 2 `error`**
  - Sticky error indication
  - Set when any source feeder or chain stage reports error
  - Cleared by `clear` or next `start`

## Register map

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x0000` | `REG_CTRL` | RW | Control register: bit0=`start`, bit1=`clear` |
| `0x0004` | `REG_STATUS` | RO | Status register: bit0=`busy`, bit1=`done`, bit2=`error` |
| `0x0008` | `REG_SRC0_BASE_LO` | RW | Source0 DDR base address low 32 bits |
| `0x000C` | `REG_SRC0_BASE_HI` | RW | Source0 DDR base address high 32 bits |
| `0x0010` | `REG_SRC0_SIZE` | RW | Source0 byte count |
| `0x0014` | `REG_SRC1_BASE_LO` | RW | Source1 DDR base address low 32 bits |
| `0x0018` | `REG_SRC1_BASE_HI` | RW | Source1 DDR base address high 32 bits |
| `0x001C` | `REG_SRC1_SIZE` | RW | Source1 byte count |
| `0x0020` | `REG_MID_BASE_LO` | RW | Intermediate counted-record DDR base low 32 bits |
| `0x0024` | `REG_MID_BASE_HI` | RW | Intermediate counted-record DDR base high 32 bits |
| `0x0028` | `REG_DST_BASE_LO` | RW | Final LevelDB block DDR base low 32 bits |
| `0x002C` | `REG_DST_BASE_HI` | RW | Final LevelDB block DDR base high 32 bits |
| `0x0030` | `REG_SOURCE0_DECODED_ENTRY_COUNT` | RO | Source0 decoded entry count |
| `0x0034` | `REG_SOURCE0_RESTART_COUNT` | RO | Source0 restart count |
| `0x0038` | `REG_SOURCE0_RESTART_ENTRY_COUNT` | RO | Source0 restart-entry count |
| `0x003C` | `REG_SOURCE0_SHARED_KEY_BYTES_TOTAL` | RO | Source0 total shared-key bytes |
| `0x0040` | `REG_SOURCE0_UNSHARED_KEY_BYTES_TOTAL` | RO | Source0 total unshared-key bytes |
| `0x0044` | `REG_SOURCE0_VALUE_BYTES_TOTAL` | RO | Source0 total value bytes |
| `0x0048` | `REG_SOURCE0_LAST_KEY_LEN` | RO | Source0 last decoded key length |
| `0x004C` | `REG_SOURCE0_LAST_VALUE_LEN` | RO | Source0 last decoded value length |
| `0x0050` | `REG_SOURCE0_LAST_SHARED_BYTES` | RO | Source0 last shared-byte count |
| `0x0054` | `REG_SOURCE0_LAST_NON_SHARED_BYTES` | RO | Source0 last non-shared-byte count |
| `0x0058` | `REG_SOURCE0_RESTART_ARRAY_OFFSET` | RO | Source0 restart array offset inside decoded block |
| `0x005C` | `REG_SOURCE0_BYTES_READ` | RO | Source0 AXI read byte count |
| `0x0060` | `REG_SOURCE0_BEATS_READ` | RO | Source0 AXI read beat count |
| `0x0064` | `REG_SOURCE1_DECODED_ENTRY_COUNT` | RO | Source1 decoded entry count |
| `0x0068` | `REG_SOURCE1_RESTART_COUNT` | RO | Source1 restart count |
| `0x006C` | `REG_SOURCE1_RESTART_ENTRY_COUNT` | RO | Source1 restart-entry count |
| `0x0070` | `REG_SOURCE1_SHARED_KEY_BYTES_TOTAL` | RO | Source1 total shared-key bytes |
| `0x0074` | `REG_SOURCE1_UNSHARED_KEY_BYTES_TOTAL` | RO | Source1 total unshared-key bytes |
| `0x0078` | `REG_SOURCE1_VALUE_BYTES_TOTAL` | RO | Source1 total value bytes |
| `0x007C` | `REG_SOURCE1_LAST_KEY_LEN` | RO | Source1 last decoded key length |
| `0x0080` | `REG_SOURCE1_LAST_VALUE_LEN` | RO | Source1 last decoded value length |
| `0x0084` | `REG_SOURCE1_LAST_SHARED_BYTES` | RO | Source1 last shared-byte count |
| `0x0088` | `REG_SOURCE1_LAST_NON_SHARED_BYTES` | RO | Source1 last non-shared-byte count |
| `0x008C` | `REG_SOURCE1_RESTART_ARRAY_OFFSET` | RO | Source1 restart array offset inside decoded block |
| `0x0090` | `REG_SOURCE1_BYTES_READ` | RO | Source1 AXI read byte count |
| `0x0094` | `REG_SOURCE1_BEATS_READ` | RO | Source1 AXI read beat count |
| `0x0098` | `REG_MERGE_OUTPUT_BYTE_COUNT` | RO | Counted-record bytes written to `MID` |
| `0x009C` | `REG_MERGE_BYTES_WRITTEN` | RO | Merge writeback AXI byte count |
| `0x00A0` | `REG_MERGE_BEATS_WRITTEN` | RO | Merge writeback AXI beat count |
| `0x00A4` | `REG_MERGE_DECODED_RECORD_COUNT` | RO | Total decoded records seen across both sources |
| `0x00A8` | `REG_MERGE_MERGED_RECORD_COUNT` | RO | Kept records after duplicate suppression |
| `0x00AC` | `REG_MERGE_DROPPED_SUPERSEDED_COUNT` | RO | Dropped superseded records |
| `0x00B0` | `REG_MERGE_VALUE_RECORD_COUNT` | RO | Input value-record count |
| `0x00B4` | `REG_MERGE_DELETE_RECORD_COUNT` | RO | Input delete-record count |
| `0x00B8` | `REG_MERGE_USER_KEY_BYTES_TOTAL` | RO | Total user-key bytes observed |
| `0x00BC` | `REG_MERGE_VALUE_BYTES_TOTAL` | RO | Total value bytes observed |
| `0x00C0` | `REG_MERGE_LAST_USER_KEY_LEN` | RO | Last processed user-key length |
| `0x00C4` | `REG_MERGE_LAST_SEQUENCE_LO` | RO | Low 32 bits of last processed sequence |
| `0x00C8` | `REG_MERGE_LAST_SEQUENCE_HI` | RO | High 24 bits of last processed sequence in bits `[23:0]` |
| `0x00CC` | `REG_MERGE_LAST_VALUE_TYPE` | RO | Last processed value type |
| `0x00D0` | `REG_MERGE_LAST_RECORD_KEEP` | RO | Whether the last processed record was kept |
| `0x00D4` | `REG_STAGE5_INPUT_RECORD_COUNT` | RO | Counted records consumed by Stage5 |
| `0x00D8` | `REG_STAGE5_ENCODED_ENTRY_COUNT` | RO | Records encoded into final LevelDB block |
| `0x00DC` | `REG_STAGE5_RESTART_COUNT` | RO | Restart count in final output block |
| `0x00E0` | `REG_STAGE5_SHARED_KEY_BYTES_TOTAL` | RO | Stage5 shared-key bytes total |
| `0x00E4` | `REG_STAGE5_UNSHARED_KEY_BYTES_TOTAL` | RO | Stage5 unshared-key bytes total |
| `0x00E8` | `REG_STAGE5_VALUE_BYTES_TOTAL` | RO | Stage5 value bytes total |
| `0x00EC` | `REG_STAGE5_LAST_KEY_LEN` | RO | Last encoded key length |
| `0x00F0` | `REG_STAGE5_LAST_VALUE_LEN` | RO | Last encoded value length |
| `0x00F4` | `REG_STAGE5_LAST_SHARED_BYTES` | RO | Last encoded shared-byte count |
| `0x00F8` | `REG_STAGE5_LAST_NON_SHARED_BYTES` | RO | Last encoded non-shared-byte count |
| `0x00FC` | `REG_STAGE5_OUTPUT_BLOCK_BYTES` | RO | Final LevelDB block byte count |
| `0x0100` | `REG_STAGE5_BYTES_READ` | RO | Stage5 AXI read byte count from `MID` |
| `0x0104` | `REG_STAGE5_BEATS_READ` | RO | Stage5 AXI read beat count from `MID` |
| `0x0108` | `REG_STAGE5_BYTES_WRITTEN` | RO | Stage5 AXI write byte count to `DST` |
| `0x010C` | `REG_STAGE5_BEATS_WRITTEN` | RO | Stage5 AXI write beat count to `DST` |

## Bring-up sequence

1. Program source DDR regions with two valid real LevelDB data blocks
2. Choose non-overlapping 64-byte-aligned `MID` and `DST` DDR ranges
3. Write `REG_CTRL = 0x2` then `REG_CTRL = 0x0` to clear sticky status
4. Program `SRC0_BASE`, `SRC0_SIZE`, `SRC1_BASE`, `SRC1_SIZE`, `MID_BASE`, and `DST_BASE`
5. Optionally wait a short settle interval after programming registers
6. Write `REG_CTRL = 0x1` to start the integrated run
7. Poll `REG_STATUS`
   - if bit2=`1`, the run failed
   - if bit1=`1`, the run completed
8. Read source0/source1 counters to confirm feeder progress
9. Read merge and Stage5 counters
10. Optionally DMA-read back `MID` and `DST` for verification

## Board-level assumptions

- `SRC0`, `SRC1`, `MID`, and `DST` should be 64-byte aligned for current XDMA usage
- `SRC0`, `SRC1`, `MID`, and `DST` DDR ranges must not overlap
- The two source blocks must each contain records sorted by user key ascending and internal tag descending for duplicate versions of the same user key
- `bytes_done` on the top-level output mirrors `REG_STAGE5_BYTES_WRITTEN`
- `blocks_done` on the top-level output mirrors `REG_STAGE5_ENCODED_ENTRY_COUNT`
