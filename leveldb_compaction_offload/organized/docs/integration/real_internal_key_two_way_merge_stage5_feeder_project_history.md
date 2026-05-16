# Real Internal-Key Two-Way Merge + Stage5 + 2-Source Feeder Project History

## Document Purpose

This document is a detailed summary of the project history leading to the current board-validated implementation of:

- real LevelDB data-block decode feeders for two sources
- real internal-key two-way merge with duplicate suppression
- merged counted-record DDR writeback to `MID`
- Stage5 real LevelDB block re-encode from `MID` to `DST`
- integrated AXI-Lite-controlled board wrapper with internal dual feeders
- single-case and multi-scenario XDMA-based board validation

The goal of this document is to preserve:

- the original project objective
- the architectural decisions made along the way
- the staged implementation milestones
- the roles of the important RTL and host-side files
- the major debug findings and fixes
- the current functional status
- the immediate next-step options

---

# 1. Original Objective

## High-level project direction

The long-term objective was to extend the compaction RTL flow toward **multi-input k-way merge**. The immediate practical milestone was to build a **minimal 2-input real internal-key merge path**, verify it thoroughly, and then integrate it into the existing DDR-based compaction engine.

The project intentionally progressed in small validated layers:

- build reusable stage infrastructure first
- prove each stage in simulation
- wrap each stage in board-friendly AXI-Lite control
- validate on hardware with XDMA scripts
- only then combine stages into larger integrated pipelines

## Immediate objective that drove the final phase

After the real two-way merge + Stage5 chain and its AXI-Lite / board wrappers were built, the next major request was to create a **2-source feeder top** so that the board-facing design no longer depended on externally provided record-stream producers.

That final step required:

- instantiating two real DDR-fed stage4 record emit feeders
- connecting those two feeders directly into the existing two-way merge + Stage5 chain
- unifying all control/status under one AXI-Lite wrapper
- exposing separate AXI masters for each feeder and for the chain write/read path
- validating the integrated design first with static compilation and then on board

---

# 2. Design Principles and Constraints

## Core design principles used throughout

- **Stage-by-stage validation first**
  - each stage was made correct and testable before integration

- **Prefer reuse of verified infrastructure**
  - stage1/2/3 transport and wrapper patterns were reused whenever possible

- **Board-first packaging discipline**
  - every meaningful stage eventually got an AXI-Lite wrapper and a BD-friendly top

- **Simulation before hardware**
  - new blocks were verified with focused testbenches before being exercised on board

- **Host scripts are part of the deliverable**
  - each board-facing IP gained a bring-up script or suite, not just RTL

## Important explicit user constraint

For the stage4 work, implementation was to be derived from **previously verified stage1-3 content and reference LevelDB format behavior**, and **not from residual or partially implemented old stage4 code**.

That constraint shaped the stage4 decoder and related record-emit path implementation.

---

# 3. Architectural Overview of the Current End State

At the end of the current work, the integrated pipeline is:

```text
SRC0 DDR block
  -> stage4_real_data_block_record_emit_top
  -> source0 record stream

SRC1 DDR block
  -> stage4_real_data_block_record_emit_top
  -> source1 record stream

source0 + source1 record streams
  -> real_internal_key_two_way_merge_decoder
  -> counted-record stream
  -> DDR writeback to MID

MID counted-record DDR region
  -> stage5_real_data_block_encode_top
  -> final real LevelDB data block at DST
```

The board-facing control path is:

```text
AXI-Lite
  -> stage4_real_internal_key_two_way_merge_stage5_chain_axil_top
  -> integrated 2-source feeder + merge + Stage5 core
```

The board-facing memory interfaces are:

- `m_axi_src0`
  - source0 feeder DDR read path
- `m_axi_src1`
  - source1 feeder DDR read path
- `m_axi_chain`
  - merge writeback + Stage5 read/write DDR path

This separation avoids internal arbitration complexity between concurrent feeders and the downstream chain.

---

# 4. Chronological Project History

## 4.1 Stage1 reusable DDR/stream infrastructure

The foundation of the project was a reusable stage1 transport layer that already supported:

- burst-based DDR reads
- burst-based DDR writes
- byte-stream width adaptation
- FIFO-style stream plumbing
- simple AXI-Lite-controlled board integration

### Important stage1 files

- `stream_fifo.v`
- `stream_width_adapter.v`
- `axi_read_engine.v`
- `axi_write_engine.v`
- `stage1_ddr_copy_top.v`
- `stage1_ddr_copy_axil_top.v`
- `sstable_compaction_top.v`
- `axi_ram_model.v`
- `tb_stage1_ddr_copy_top.v`
- `tb_stream_width_adapter.v`
- `tb_stage1_ddr_copy_axil_top.v`

### What stage1 established

- proven AXI read/write transport blocks
- proven simulation infrastructure with `axi_ram_model`
- proven AXI-Lite register/control style reused by later stages
- a known-good baseline for XDMA hardware interaction patterns

---

## 4.2 Stage2 pseudo SSTable decode path

The next milestone added a simplified pseudo-SSTable decode path. This stage was not yet real LevelDB data-block handling, but it established the decoding pipeline pattern and board-facing wrapper structure.

### Important stage2 files

- `pseudo_sstable_decoder.v`
- `stage2_pseudo_sstable_decode_top.v`
- `tb_stage2_pseudo_sstable_decode_top.v`
- `stage2_pseudo_sstable_decode_axil_top.v`
- `sstable_decode_top.v`
- `tb_stage2_pseudo_sstable_decode_axil_top.v`

### What stage2 established

- DDR-read-to-byte-stream decode structure
- AXI-Lite register-map style for decoder IPs
- first full decode-oriented board wrapper pattern

---

## 4.3 Stage3 pseudo internal-key merge path

Stage3 introduced the internal-key merge semantics in a simpler pseudo-SSTable domain before the project moved into the real LevelDB block path.

### Important stage3 files

- `pseudo_internal_key_merge_decoder.v`
- `stage3_internal_key_merge_top.v`
- `tb_stage3_internal_key_merge_top.v`
- `stage3_internal_key_merge_axil_top.v`
- `internal_key_merge_top.v`
- `test_stage3_internal_key_merge_xdma.sh`
- `test_stage3_internal_key_merge_xdma_suite.sh`

### Stage3 semantics

- internal key modeled as `user_key || fixed64(tag)`
- tag format: `(sequence << 8) | value_type`
- record ordering assumption:
  - user key ascending
  - sequence descending within same user key
- merge policy:
  - keep first record of each adjacent user-key run
  - drop later superseded versions

### Important bug fixed during this era

A bug in `stream_width_adapter.v` affecting multi-beat streams was fixed by correctly distinguishing:

- end of buffered beat
- end of entire stream

That fix later benefitted the real stage4/stage5 paths as well.

### Board validation outcome

Stage3 ultimately passed on hardware, including richer scenarios such as:

- long duplicate chains
- many-group compaction-like mixes
- large-value mixes

This established confidence in the merge policy before moving to real LevelDB block handling.

---

## 4.4 Real Stage4 data-block decode

After the stage1-3 infrastructure was established, a new **real LevelDB data-block decoder** was implemented from scratch within the verified project framework.

### Important real stage4 files

- `real_data_block_decoder.v`
- `stage4_real_data_block_decode_top.v`
- `stage4_real_data_block_decode_axil_top.v`
- `real_data_block_decode_top.v`
- `tb_stage4_real_data_block_decode_top.v`
- `test_stage4_real_data_block_decode_xdma.sh`

### What the decoder does

- captures the full block byte stream
- parses LevelDB varint fields:
  - shared bytes
  - non-shared bytes
  - value length
- reconstructs keys using prefix sharing
- validates restart trailer structure
- reports statistics such as:
  - decoded entry count
  - restart count
  - restart-entry count
  - shared/unshared/value totals
  - last key/value lengths
  - restart array offset

### First hardware issue

The initial board run timed out with:

- `busy=1`
- no bytes read
- no decode counters incrementing

### Root cause

The AXI-Lite-to-UI configuration mirrors were only updated on the same cycle as the `start` toggle. This allowed the UI domain to see `start` before the synchronized size/base fields were stable.

### Fix

Configuration registers were changed to **continuously mirror** the AXI-Lite config values into the UI-facing synchronization path before any `start` pulse.

### Second hardware issue

After the first fix, the DDR read path moved, but the decoder errored after one beat.

### Root cause

`real_data_block_decoder.v` had severe timing pressure in the parser path at the 300 MHz UI clock. Critical paths ran through block buffer reads and parser logic in a single cycle.

### Fix

The decoder was refactored into a more timing-friendly multi-cycle parser with:

- registered single-byte fetch/consume states
- multi-cycle fixed32 restart reads
- separated validation phases
- block-memory style storage for the captured block

### Result

Stage4 real decode passed both simulation and hardware validation on representative payloads.

---

## 4.5 Real Stage5 LevelDB block encode

The next major milestone was Stage5: converting counted-record streams back into real LevelDB data blocks.

### Important stage5 files

- `real_data_block_encoder.v`
- `tb_real_data_block_encoder.v`
- `stream_pack_adapter.v`
- `stage5_real_data_block_encode_top.v`
- `tb_stage5_real_data_block_encode_top.v`
- `stage5_real_data_block_encode_axil_top.v`
- `real_data_block_encode_top.v`
- `test_stage5_real_data_block_encode_xdma.sh`
- `test_stage5_real_data_block_encode_xdma_suite.sh`

### What Stage5 does

- reads counted-record stream from DDR
- decodes per-record fields from the counted format
- builds a real LevelDB data block with prefix compression and restart array
- emits the block as byte stream
- repacks and writes the final block back to DDR

### Important discovered issue

A suspected multi-beat bug in Stage5 turned out to be **not RTL**, but **test-region overlap**:

- source DDR and destination DDR overlapped in the board tests
- initialization of destination with `0xA5` partially overwrote source payloads

### Fix

Host scripts were corrected to:

- move destination farther away by default
- add explicit source/destination non-overlap checks

### Result

Stage5 ultimately passed a broader hardware suite including:

- prefix-heavy cases
- multibeat large-value traffic
- many-record multi-restart cases

---

## 4.6 Stage4 record emit path

Once real stage4 decode was proven, the project expanded stage4 to emit full record streams suitable for downstream merge logic.

### Important files

- `real_data_block_record_decoder.v`
- `stage4_real_data_block_record_emit_top.v`
- `tb_stage4_real_data_block_record_emit_top.v`

### What this layer added

- per-record header handshake:
  - `record_valid`
  - `record_ready`
  - key/value length metadata
- per-record payload byte stream:
  - reconstructed full key bytes
  - followed by value bytes
- `record_tlast` at record boundary

This established the exact frontend contract later used by the real merge layers and by the new two-source feeder integration.

---

## 4.7 Counted-record buffering and writeback

To chain record emission toward downstream consumers, a counted-record buffer and writeback layer were added.

### Important files

- `record_emit_counted_buffer.v`
- `stage4_real_data_block_record_emit_writeback_top.v`
- `tb_stage4_real_data_block_record_emit_writeback_top.v`

### What this layer does

- collects emitted records from stage4 record emit
- writes them into the counted-record format expected by Stage5:
  - `u32 record_count`
  - repeated `u16 key_len, u16 value_len, key bytes, value bytes`
- packs the stream and writes it to DDR

This layer was an important bridge between stage4 real decode/emit and the later chain compositions.

---

## 4.8 Single-source real merge chain

Before the project moved to two-way merge, a real single-source internal-key merge path was built and validated end-to-end.

### Important files

- `real_internal_key_merge_decoder.v`
- `tb_real_internal_key_merge_decoder.v`
- `stage4_real_internal_key_merge_top.v`
- `tb_stage4_real_internal_key_merge_top.v`
- `stage4_real_internal_key_merge_writeback_top.v`
- `tb_stage4_real_internal_key_merge_writeback_top.v`
- `stage4_real_internal_key_merge_stage5_chain_top.v`
- `tb_stage4_real_internal_key_merge_stage5_chain_top.v`
- `stage4_real_internal_key_merge_stage5_chain_axil_top.v`
- `real_internal_key_merge_stage5_chain_top.v`
- `test_stage4_real_internal_key_merge_stage5_chain_xdma.sh`
- `test_stage4_real_internal_key_merge_stage5_chain_xdma_suite.sh`

### What this milestone established

- real internal-key merge semantics on top of real stage4 record emit
- merged counted-record DDR writeback to `MID`
- Stage5 re-encoding to `DST`
- end-to-end board validation on multiple scenarios

This became the direct structural template for later two-way merge work.

---

## 4.9 Two-way real internal-key merge core

The project then moved from single-source merge to **two-way real merge**.

### Important files

- `real_internal_key_two_way_merge_decoder.v`
- `tb_real_internal_key_two_way_merge_decoder.v`
- `real_internal_key_two_way_merge_top.v`
- `tb_real_internal_key_two_way_merge_top.v`
- `real_internal_key_two_way_merge_writeback_top.v`
- `tb_real_internal_key_two_way_merge_writeback_top.v`

### What the decoder does

- accepts two independent stage4-style record streams
- buffers one whole record from each source as needed
- compares records by:
  - user key ascending
  - full internal tag descending
- produces globally merged order
- applies duplicate suppression across both sources
- exposes counters for:
  - decoded records
  - merged records
  - dropped superseded records
  - value/delete counts
  - user-key / value totals
  - last-record metadata

### Output contract

The top-level two-way merge wrapper emits a Stage5-compatible counted-record byte stream, making it easy to reuse the proven Stage5 path.

### Result

The focused regressions passed and verified the expected kept/drop behavior for interleaved two-source inputs.

---

## 4.10 Two-way merge + Stage5 chain

After the two-way merge frontend was verified, the project integrated it with DDR writeback and Stage5 encoding.

### Important files

- `real_internal_key_two_way_merge_stage5_chain_top.v`
- `tb_real_internal_key_two_way_merge_stage5_chain_top.v`
- `real_internal_key_two_way_merge_stage5_chain_axil_top.v`
- `real_internal_key_two_way_merge_stage5_chain_board_top.v`
- `real_internal_key_two_way_merge_stage5_chain_axil_register_map.md`
- `test_real_internal_key_two_way_merge_stage5_chain_xdma_minimal.sh`

### What this chain does

- merge two record streams
- write merged counted-record stream to `MID`
- read `MID`
- Stage5 re-encode to final LevelDB block at `DST`

### Validation status achieved before feeder integration

- focused simulation passed
- static compilation of board wrapper stack passed
- minimal XDMA bring-up script passed syntax checking

At this point the chain wrapper still depended on **external record-stream producers**, which is what motivated the next major request.

---

## 4.11 Integrated 2-source feeder wrapper

This was the final major implementation phase of the current project.

### User-facing goal of this phase

Build a board-facing top that **internally owns both upstream sources**, so software only has to program:

- source0 DDR base and size
- source1 DDR base and size
- intermediate `MID` DDR base
- destination `DST` DDR base

### Important files created

- `stage4_real_internal_key_two_way_merge_stage5_chain_top.v`
- `stage4_real_internal_key_two_way_merge_stage5_chain_axil_top.v`
- `real_internal_key_two_way_merge_stage5_feeder_top.v`

### Architectural decision

Instead of multiplexing a single AXI master across two concurrent source feeders and the downstream chain, the wrapper exposes **three AXI masters**:

- `m_axi_src0`
- `m_axi_src1`
- `m_axi_chain`

This keeps the RTL simpler and leaves arbitration to board interconnect infrastructure.

### Register-map additions

The integrated AXI-Lite wrapper exposes:

- `SRC0_BASE_LO/HI`
- `SRC0_SIZE`
- `SRC1_BASE_LO/HI`
- `SRC1_SIZE`
- `MID_BASE_LO/HI`
- `DST_BASE_LO/HI`
- source0 stage4 counters
- source1 stage4 counters
- merge counters
- Stage5 counters

### Static validation

A static `iverilog -t null` compile of the integrated wrapper stack and dependencies passed.

---

## 4.12 Integrated feeder register map and minimal board script

Once the integrated feeder wrapper compiled, host-side support was added.

### Important files

- `real_internal_key_two_way_merge_stage5_feeder_axil_register_map.md`
- `test_real_internal_key_two_way_merge_stage5_feeder_xdma_minimal.sh`

### What the minimal script does

- generates two smoke-case real LevelDB source blocks
- writes them to source DDR regions
- initializes `MID` and `DST` with `0xA5`
- clears sticky status
- programs source and output addresses
- starts the integrated feeder+merge+Stage5 IP
- polls status
- reads back `MID` and `DST`
- verifies data and counters

### Board result

This minimal integrated feeder board test passed.

That established that the new board-facing top worked end-to-end on hardware.

---

## 4.13 Integrated feeder suite and final multi-scenario board regression

The last major step of the current work was to create a full **multi-scenario hardware regression suite** for the integrated feeder wrapper.

### Important file

- `test_real_internal_key_two_way_merge_stage5_feeder_xdma_suite.sh`

### Default scenarios included

- `basic_interleaved_smoke`
- `long_duplicate_chain`
- `many_group_compaction_mix`
- `large_value_multibeat`

### First issue found in the suite

The initial `large_value_multibeat` scenario failed on hardware with:

- `error=1`
- source0 bytes read already large
- no merge progress
- no Stage5 progress

### Root cause

The scenario exceeded the current compiled capacity limits:

- source block size exceeded stage4 feeder block budget
- merged mid payload also exceeded Stage5 input payload budget

### Fix applied to the suite

- reduced the generated value sizes for `large_value_multibeat`
- added generation-time limit checks so oversized scenarios are rejected before hardware execution

### Final result

After that fix, the integrated feeder hardware suite passed all four scenarios on board:

- `basic_interleaved_smoke`
- `long_duplicate_chain`
- `many_group_compaction_mix`
- `large_value_multibeat`

This is the current end-state of the project.

---

# 5. Current Important Files and Their Roles

## 5.1 Current integrated top-level RTL

### `stage4_real_internal_key_two_way_merge_stage5_chain_top.v`

This is the integrated UI-clock-domain core for the board-facing feeder path.

It:

- instantiates two `stage4_real_data_block_record_emit_top` feeders
- wires their record-stream outputs into `real_internal_key_two_way_merge_stage5_chain_top`
- exposes separate AXI masters for source0, source1, and chain DDR traffic
- aggregates busy/done/error behavior and counter outputs

### `stage4_real_internal_key_two_way_merge_stage5_chain_axil_top.v`

This is the AXI-Lite wrapper around the integrated core.

It:

- implements the AXI-Lite register map
- performs control-plane clock-domain crossing
- mirrors configuration values into UI domain
- mirrors status and counters back into AXI-Lite domain
- owns the unified programming model for both feeders and the downstream chain

### `real_internal_key_two_way_merge_stage5_feeder_top.v`

This is the board-friendly top wrapper.

It:

- exposes Xilinx interface metadata for clocks/resets and buses
- passes through AXI-Lite and the three AXI master interfaces
- packages the integrated feeder solution as a single module_ref-friendly IP

---

## 5.2 Core merge and chain RTL beneath the wrapper

### `real_internal_key_two_way_merge_decoder.v`

Two-source record-stream merge core with adjacent-user-key suppression across both sources.

### `real_internal_key_two_way_merge_top.v`

Wraps the decoder and counted-record buffering to produce a Stage5-compatible byte stream.

### `real_internal_key_two_way_merge_writeback_top.v`

Packs the counted-record stream and writes it to DDR.

### `real_internal_key_two_way_merge_stage5_chain_top.v`

Runs:

- merge writeback to `MID`
- then Stage5 read/encode/write to `DST`

This was validated first before the internal feeders were added.

---

## 5.3 Feeder-side stage4 real source path

### `stage4_real_data_block_record_emit_top.v`

This is the current real source feeder used by the integrated wrapper.

It:

- reads a real LevelDB block from DDR
- decodes block entries
- reconstructs full keys
- emits per-record headers and payload byte stream
- reports stage4-style decode/read counters

### `real_data_block_record_decoder.v`

The record emission decoder used by the feeder top.

### `real_data_block_decoder.v`

The earlier real block decoder path that established the parsing logic and later timing fixes.

---

## 5.4 Stage5 encode path

### `real_data_block_encoder.v`

Core real LevelDB data-block encoder.

### `stage5_real_data_block_encode_top.v`

Reads counted-record stream from DDR and writes final block to DDR.

### `stream_pack_adapter.v`

Packs byte streams into AXI beats for DDR writeback.

---

## 5.5 Host-side documentation and test scripts

### Register-map documents

- `real_internal_key_two_way_merge_stage5_chain_axil_register_map.md`
  - older two-way chain wrapper with external record-stream producers
- `real_internal_key_two_way_merge_stage5_feeder_axil_register_map.md`
  - current integrated feeder wrapper register map

### Board test scripts

- `test_real_internal_key_two_way_merge_stage5_chain_xdma_minimal.sh`
  - older chain-only bring-up with externally armed sources
- `test_real_internal_key_two_way_merge_stage5_feeder_xdma_minimal.sh`
  - current integrated feeder smoke-case board test
- `test_real_internal_key_two_way_merge_stage5_feeder_xdma_suite.sh`
  - current integrated feeder multi-scenario board regression suite

---

# 6. Current Board-Tested Functional Status

## What is now board-validated

The following is currently validated on real hardware:

- two real DDR-fed stage4 source feeders
- real two-way internal-key merge logic
- cross-source duplicate suppression
- merged counted-record writeback to `MID`
- Stage5 read from `MID`
- final real LevelDB block write to `DST`
- AXI-Lite control/status plane
- board-facing module_ref-style top integration
- host-driven bring-up and regression through XDMA scripts

## Current suite coverage

The integrated feeder suite currently covers:

- **basic_interleaved_smoke**
  - basic known-good interleaved two-source behavior
- **long_duplicate_chain**
  - long superseded chains spanning both sources
- **many_group_compaction_mix**
  - many groups and high drop counts across many bursts
- **large_value_multibeat**
  - multibeat large values within current hardware size limits

## Implicitly validated properties

By passing the suite, the current implementation has demonstrated:

- correct AXI-Lite control sequencing
- correct AXI read behavior on both source masters
- correct AXI read/write behavior on chain master
- correct DDR-region isolation between source, mid, and destination
- correct valid-length handling with preserved tail bytes
- correct Stage5 restart-array generation on final blocks

---

# 7. Key Debug Discoveries and Lessons Learned

## 7.1 AXI-Lite config CDC must not race `start`

Configuration must be mirrored continuously before issuing the UI-domain start pulse. Updating config only on the same cycle as a start toggle can easily cause the UI domain to observe stale values.

## 7.2 Block parser timing matters at UI clock rates

LevelDB block parsing contains nontrivial control and indexing logic. The parser had to be structured as a multi-cycle state machine rather than a deep combinational datapath.

## 7.3 Test-region overlap can masquerade as RTL bugs

A previously suspected Stage5 bug turned out to be source/destination DDR overlap in board tests. The scripts now guard against that class of mistake.

## 7.4 Stress scenarios must reflect current synthesis-time limits

The integrated feeder suite initially generated one scenario that exceeded current compile-time buffer limits. The right fix was not to accept false failures, but to:

- align the scenario with current hardware capacity
- add generator-side checks that fail fast before touching hardware

---

# 8. Current Capacity Assumptions and Limits

Based on the currently used wrapper parameterization, the suite is aligned to the following working limits:

- **stage4 source block size budget**
  - `STAGE4_MAX_BLOCK_BYTES = 4096`

- **Stage5 counted-record payload budget**
  - `STAGE5_MAX_PAYLOAD_BYTES = 4096`

- **Stage5 final block size budget**
  - `STAGE5_MAX_BLOCK_BYTES = 4096`

The current default suite has been tuned so that generated scenarios stay below these limits.

---

# 9. Current Register Model Summary

The current integrated feeder wrapper exposes:

## Control

- `REG_CTRL`
  - bit0 = `start`
  - bit1 = `clear`

- `REG_STATUS`
  - bit0 = `busy`
  - bit1 = `done`
  - bit2 = `error`

## Source configuration

- `REG_SRC0_BASE_LO/HI`
- `REG_SRC0_SIZE`
- `REG_SRC1_BASE_LO/HI`
- `REG_SRC1_SIZE`

## Output configuration

- `REG_MID_BASE_LO/HI`
- `REG_DST_BASE_LO/HI`

## Source counters

Per source:

- decoded entry count
- restart count
- restart-entry count
- shared/unshared/value totals
- last key/value/shared/non-shared fields
- restart array offset
- bytes read
- beats read

## Merge counters

- output byte count
- bytes written
- beats written
- decoded record count
- merged record count
- dropped superseded count
- value record count
- delete record count
- user-key bytes total
- value bytes total
- last user-key length
- last sequence low/high
- last value type
- last record keep flag

## Stage5 counters

- input record count
- encoded entry count
- restart count
- shared/unshared/value totals
- last key/value/shared/non-shared fields
- output block bytes
- bytes read
- beats read
- bytes written
- beats written

For the exact offsets, see:

- `real_internal_key_two_way_merge_stage5_feeder_axil_register_map.md`

---

# 10. Current Host-Side Validation Flow

## Minimal bring-up flow

The minimal script performs a smoke-case board test by:

1. generating two known-good source blocks
2. writing `SRC0` and `SRC1`
3. initializing `MID` and `DST` with `0xA5`
4. clearing status
5. programming source and output addresses
6. starting the integrated IP
7. polling for `done` / `error`
8. reading back `MID` and `DST`
9. verifying data and counters

## Suite flow

The suite extends that flow by:

- generating multiple scenario-specific source block pairs
- verifying per-scenario expected outputs and counters
- failing fast if generated blocks exceed current size budgets
- ensuring no source/mid/dst DDR overlap before running hardware

---

# 11. Completion Status by Major Phase

## Completed and board-validated

- stage1 DDR/stream infrastructure
- stage2 pseudo decode path
- stage3 pseudo merge path
- real stage4 decode
- real stage4 record emit
- counted-record buffering/writeback
- single-source real merge chain
- two-way real merge frontend
- two-way merge + Stage5 chain
- integrated two-source feeder wrapper
- minimal integrated feeder board test
- integrated feeder multi-scenario board suite

## Completed and simulation-validated

All major intermediate cores and top wrappers in the progression above received focused simulation support, including the two-way merge frontend and the chain layers beneath the final integrated feeder wrapper.

## Current project status in one line

**The real two-source feeder -> two-way merge -> Stage5 pipeline is implemented, board-friendly, and validated on hardware across multiple scenarios within current configured size limits.**

---

# 12. Recommended Next Steps

## Option A: Treat current implementation as a stable milestone

If the immediate goal is to lock in the current success, the next step should be to treat this state as a validated milestone and preserve:

- exact tested bitstream assumptions
- passing suite scenarios
- default address map assumptions
- Stage5 restart interval assumptions

## Option B: Increase supported size limits

If the project now needs larger source blocks or larger merged payloads, the next logical step is to:

- increase stage4 source block budget
- increase Stage5 counted-payload budget
- potentially increase Stage5 output block budget
- rebuild, reflash, and rerun the feeder suite with enlarged scenarios

## Option C: Move upward in system integration

If this block is to be used as a subsystem in a larger compaction engine, the next work could focus on:

- upstream source orchestration
- multi-run scheduling / descriptor queues
- software integration layer above the AXI-Lite/XDMA scripts
- eventual movement from two-way to generalized k-way structures

## Option D: Add even broader regression coverage

Possible future suite additions:

- boundary-near capacity cases
- intentionally malformed source blocks for error-path validation
- randomized but deterministic scenario generation
- longer runtime soak/regression loops

---

# 13. Practical Current-State Summary

If someone new reads only this section, the important facts are:

- the project started from reusable stage1-3 transport and wrapper infrastructure
- real stage4 decode was implemented carefully and debugged on hardware
- Stage5 real encode was implemented and hardware-validated
- a single-source real merge chain was built first and validated
- a real two-way merge frontend was then implemented and validated
- the two-way merge was connected to Stage5 and wrapped for the board
- the final request was to build a **2-source feeder top** that internally owns both DDR-fed source feeders
- that integrated feeder wrapper now exists, compiles, has a documented AXI-Lite register map, and is board-validated
- the current hardware suite passes multiple scenarios, including multibeat large-value traffic within current size limits

---

# 14. File Index of the Most Relevant Current Deliverables

## Primary RTL deliverables

- `stage4_real_internal_key_two_way_merge_stage5_chain_top.v`
- `stage4_real_internal_key_two_way_merge_stage5_chain_axil_top.v`
- `real_internal_key_two_way_merge_stage5_feeder_top.v`
- `real_internal_key_two_way_merge_stage5_chain_top.v`
- `real_internal_key_two_way_merge_top.v`
- `real_internal_key_two_way_merge_decoder.v`
- `stage4_real_data_block_record_emit_top.v`
- `stage5_real_data_block_encode_top.v`
- `real_data_block_encoder.v`
- `record_emit_counted_buffer.v`
- `stream_pack_adapter.v`

## Primary documentation deliverables

- `real_internal_key_two_way_merge_stage5_feeder_axil_register_map.md`
- `real_internal_key_two_way_merge_stage5_chain_axil_register_map.md`
- `real_internal_key_two_way_merge_stage5_feeder_project_history.md`

## Primary host-side validation deliverables

- `test_real_internal_key_two_way_merge_stage5_feeder_xdma_minimal.sh`
- `test_real_internal_key_two_way_merge_stage5_feeder_xdma_suite.sh`
- `test_real_internal_key_two_way_merge_stage5_chain_xdma_minimal.sh`

---

# 15. Final Status

The project has reached a strong milestone:

- **implementation complete** for the intended two-source feeder + two-way merge + Stage5 path
- **board integration complete** for the current wrapper style
- **documentation present** for register map and usage
- **minimal bring-up passing**
- **multi-scenario hardware regression passing**

At the time of writing, the implementation should be regarded as **board-validated within current configured size limits**, and ready either for:

- parameter expansion
- higher-level system integration
- or milestone sign-off/document preservation
