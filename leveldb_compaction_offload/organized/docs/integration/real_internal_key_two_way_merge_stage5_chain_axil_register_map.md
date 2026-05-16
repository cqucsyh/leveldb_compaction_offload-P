# 2-Way Merge + Stage5 Chain AXI-Lite Register Map

## Overview

`real_internal_key_two_way_merge_stage5_chain_axil_top` exposes an AXI-Lite control plane for the 2-way compaction chain:

- 2-way record-stream merge frontend
- merged counted-record writeback to `MID`
- Stage5 LevelDB block encode from `MID` to `DST`

The AXI-Lite wrapper does **not** generate the two input streams itself.
Your board design must already provide two UI-clock-domain record-stream producers to:

- `source0_done`, `s0_record_*`, `s0_axis_*`
- `source1_done`, `s1_record_*`, `s1_axis_*`

## Control semantics

### `REG_CTRL` bit definitions

- **Bit 0 `start`**
  - Write `1` to request a new run
  - The wrapper converts this into a one-shot pulse in `ui_aclk`
  - The bit auto-clears in the AXI-Lite domain after the edge is consumed

- **Bit 1 `clear`**
  - Write `1` to clear status and issue a UI-domain clear pulse
  - The bit auto-clears after the edge is consumed

### `REG_STATUS` bit definitions

- **Bit 0 `busy`**
  - Mirrors current chain busy state

- **Bit 1 `done`**
  - Sticky done indication
  - Set when the chain finishes successfully
  - Cleared by `clear` or next `start`

- **Bit 2 `error`**
  - Sticky error indication
  - Set when the chain reports an error
  - Cleared by `clear` or next `start`

## Register map

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x0000` | `REG_CTRL` | RW | Control register: bit0=`start`, bit1=`clear` |
| `0x0004` | `REG_STATUS` | RO | Status register: bit0=`busy`, bit1=`done`, bit2=`error` |
| `0x0008` | `REG_MID_BASE_LO` | RW | Intermediate DDR base address low 32 bits |
| `0x000C` | `REG_MID_BASE_HI` | RW | Intermediate DDR base address high 32 bits |
| `0x0010` | `REG_DST_BASE_LO` | RW | Destination DDR base address low 32 bits |
| `0x0014` | `REG_DST_BASE_HI` | RW | Destination DDR base address high 32 bits |
| `0x0018` | `REG_MERGE_OUTPUT_BYTE_COUNT` | RO | Total counted-record bytes written to `MID` |
| `0x001C` | `REG_MERGE_BYTES_WRITTEN` | RO | AXI write bytes written by merge writeback |
| `0x0020` | `REG_MERGE_BEATS_WRITTEN` | RO | AXI write beats written by merge writeback |
| `0x0024` | `REG_MERGE_DECODED_RECORD_COUNT` | RO | Total decoded input records seen across both sources |
| `0x0028` | `REG_MERGE_MERGED_RECORD_COUNT` | RO | Kept records after duplicate suppression |
| `0x002C` | `REG_MERGE_DROPPED_SUPERSEDED_COUNT` | RO | Dropped superseded records |
| `0x0030` | `REG_MERGE_VALUE_RECORD_COUNT` | RO | Input value-record count |
| `0x0034` | `REG_MERGE_DELETE_RECORD_COUNT` | RO | Input delete-record count |
| `0x0038` | `REG_MERGE_USER_KEY_BYTES_TOTAL` | RO | Total user-key bytes observed |
| `0x003C` | `REG_MERGE_VALUE_BYTES_TOTAL` | RO | Total value bytes observed |
| `0x0040` | `REG_MERGE_LAST_USER_KEY_LEN` | RO | Last processed user-key length |
| `0x0044` | `REG_MERGE_LAST_SEQUENCE_LO` | RO | Low 32 bits of last processed sequence |
| `0x0048` | `REG_MERGE_LAST_SEQUENCE_HI` | RO | High 24 bits of last processed sequence in bits `[23:0]` |
| `0x004C` | `REG_MERGE_LAST_VALUE_TYPE` | RO | Last processed value type |
| `0x0050` | `REG_MERGE_LAST_RECORD_KEEP` | RO | Whether the last processed record was kept |
| `0x0054` | `REG_STAGE5_INPUT_RECORD_COUNT` | RO | Counted records consumed by Stage5 |
| `0x0058` | `REG_STAGE5_ENCODED_ENTRY_COUNT` | RO | Records encoded into final LevelDB block |
| `0x005C` | `REG_STAGE5_RESTART_COUNT` | RO | Restart count in final block |
| `0x0060` | `REG_STAGE5_SHARED_KEY_BYTES_TOTAL` | RO | Stage5 shared-key bytes total |
| `0x0064` | `REG_STAGE5_UNSHARED_KEY_BYTES_TOTAL` | RO | Stage5 unshared-key bytes total |
| `0x0068` | `REG_STAGE5_VALUE_BYTES_TOTAL` | RO | Stage5 value bytes total |
| `0x006C` | `REG_STAGE5_LAST_KEY_LEN` | RO | Last encoded key length |
| `0x0070` | `REG_STAGE5_LAST_VALUE_LEN` | RO | Last encoded value length |
| `0x0074` | `REG_STAGE5_LAST_SHARED_BYTES` | RO | Last encoded shared-byte count |
| `0x0078` | `REG_STAGE5_LAST_NON_SHARED_BYTES` | RO | Last encoded non-shared-byte count |
| `0x007C` | `REG_STAGE5_OUTPUT_BLOCK_BYTES` | RO | Final LevelDB block byte count |
| `0x0080` | `REG_STAGE5_BYTES_READ` | RO | AXI read bytes consumed by Stage5 from `MID` |
| `0x0084` | `REG_STAGE5_BEATS_READ` | RO | AXI read beats consumed by Stage5 from `MID` |
| `0x0088` | `REG_STAGE5_BYTES_WRITTEN` | RO | AXI write bytes written by Stage5 to `DST` |
| `0x008C` | `REG_STAGE5_BEATS_WRITTEN` | RO | AXI write beats written by Stage5 to `DST` |

## Bring-up sequence

1. Ensure both source producers are reset, configured, and able to emit valid record streams in `ui_aclk`
2. Program `MID_BASE` and `DST_BASE`
3. Optionally initialize `MID` and `DST` DDR ranges with a sentinel pattern like `0xA5`
4. Write `REG_CTRL = 0x2` then `REG_CTRL = 0x0` to clear sticky status
5. Wait a short settle interval if your design crosses multiple control domains
6. Write `REG_CTRL = 0x1` to start the chain
7. Poll `REG_STATUS`
   - if bit2=`1`, the chain failed
   - if bit1=`1`, the chain completed
8. Read merge and Stage5 counters
9. Optionally DMA-read back `MID` and `DST` for verification

## Expected board-level assumptions

- `MID` and `DST` should be 64-byte aligned for the current XDMA/AXI usage
- The two upstream sources must already obey the decoder contract:
  - sorted by user key ascending
  - duplicate versions for the same user key in descending internal-key order
  - one-shot `source*_done` pulse after the final record
- The wrapper only controls the chain itself; if the two producers have their own control plane, software must arm them separately before issuing chain `start`
