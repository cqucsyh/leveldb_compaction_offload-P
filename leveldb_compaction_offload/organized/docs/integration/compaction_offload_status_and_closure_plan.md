# Compaction Offload Status and Closure Plan

## Current completed status

The current hardware and board-validation status is no longer limited to isolated stage bring-up.
The compaction data path from real LevelDB blocks through merge and Stage5 re-encode is already working in board-facing packaged forms.

### Completed RTL/data-path building blocks

- `stage4_real_data_block_record_emit_top`
  - real LevelDB data-block decode and record-stream emit

- `real_internal_key_two_way_merge_stage5_chain_top`
  - 2-way internal-key merge
  - duplicate suppression
  - counted-record writeback to `MID`
  - Stage5 re-encode from `MID` to `DST`

- `stage4_real_internal_key_two_way_merge_stage5_chain_top`
  - integrated feeder + merge + Stage5 chain

- `stage4_real_internal_key_two_way_merge_stage5_nblock_top`
  - sequential multi-block-pair processing
  - carried previous-user-key state across pair boundaries
  - aggregate counters across one run

- `stage4_real_internal_key_two_way_merge_stage5_nblock_axil_top`
  - board-facing AXI-Lite control wrapper for the N-block path
  - descriptor programming for pair0/pair1 compatibility window and generic descriptor window for pair2+

### Completed documentation

- chain AXI-Lite register map
- multiblock AXI-Lite register map
- N-block AXI-Lite register map
- feeder project history / staged milestone document

### Completed board validation

#### Functional regression baseline

The N-block XDMA suite has already passed a full 11-scenario board regression covering:

- focused 3-block smoke
- single-pair execution
- cross-boundary duplicate carry
- duplicate ladders across pair boundaries
- many-group compaction-like mixes
- large-value multibeat cases
- delete-heavy mixes
- zero-kept middle pair
- near-empty one-sided pressure
- long shared-prefix pressure
- leading near-empty pairs with active tail pair

#### Performance-oriented scenario baseline

Three optional larger-load scenarios have also passed board validation:

- `three_block_perf_dense_value_stream`
- `three_block_perf_duplicate_churn`
- `three_block_perf_long_prefix_stream`

These give a first usable throughput/stability baseline beyond pure functional smoke coverage.

### Important hardware contract already identified

For the current positive regression flow, active block-pairs should not use source blocks that encode zero records.
Near-empty but legal minimal-record blocks are supported and are already used in the validated suites.

## What is still missing for a complete compaction-offload closure

The remaining gap is no longer the core hardware data path itself.
The main missing work is the software/system bridge that turns real compaction inputs into N-block runs and reconnects hardware outputs back into the higher-level compaction flow.

### Missing closure pieces

- real compaction input extraction
  - identify the exact LevelDB table/data blocks that should feed one offloaded merge run

- host-side run planning
  - pack real source blocks into N-block descriptors
  - size and assign DDR regions for `SRC0[i]`, `SRC1[i]`, shared `MID`, and `DST[i]`

- golden/reference generation for prepared runs
  - generate expected counters and destination blocks for non-synthetic inputs

- result reintegration
  - map hardware-produced destination blocks back into the software compaction pipeline
  - decide whether the first closure step should replace block building only, or a larger portion of compaction output assembly

- multi-run orchestration
  - queue or iterate multiple N-block runs when the compaction working set spans more than one hardware launch

## Chosen next step

The next step toward closure is to externalize the N-block host driver so it no longer depends on hardcoded synthetic scenario generators.

That bridge is:

- a prepared-case / manifest-driven N-block runner

This allows the hardware path to be driven by externally prepared real inputs, while reusing the already validated board execution, counter checking, and destination readback flow.

## Immediate implementation plan after this document

1. Use the new prepared-case runner to accept externally generated N-block inputs.
2. Add a real-input preparation step that extracts real source blocks and builds the prepared-case directory.
3. Add a software reference path for those real inputs so hardware output can be compared against a golden result.
4. Connect that preparation + run + verification loop to a higher-level compaction driver.

## Practical closure definition

For this project, "complete compaction offload closure" means reaching the point where:

- real compaction inputs are selected by software
- those inputs are converted into one or more valid N-block hardware runs
- hardware produces verified destination LevelDB blocks
- software consumes the produced outputs as part of the compaction pipeline rather than as an isolated board test

At the current state, the project is already very close on the hardware side.
The next critical work is the host/software orchestration layer.
