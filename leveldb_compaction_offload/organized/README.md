# Organized RTL Layout

## Purpose

This directory is the **authoritative staged layout** for the RTL/docs that previously lived in the original flat layout under:

- `/home/yh/pp4/leveldb_compaction_offload`

The original flat top-level `.v` and `.md` files have now been moved here, and project/script references should use this staged structure.

## New directory structure

```text
organized/
  src/
    common/
    stage1/
    stage2/
    stage3/
    stage4/
    stage5/
    integration/
  sim/
    common/
    stage1/
    stage2/
    stage3/
    stage4/
    stage5/
    integration/
  docs/
    integration/
  reorg_manifest.txt
```

## Classification rules

### `src/`

Contains synthesizable or board-facing source RTL, grouped by project stage or integration layer.

- **`src/common`**
  - reusable infrastructure shared across stages
  - examples: AXI engines, stream adapters, FIFOs, counted-buffer utility

- **`src/stage1` ~ `src/stage5`**
  - stage-oriented source RTL
  - includes core logic, AXI-Lite wrappers, and BD-friendly tops associated with that stage

- **`src/integration`**
  - multi-stage chains and final composed pipelines
  - includes single-source chain compositions and the final two-way feeder integration

### `sim/`

Contains simulation-only or testbench-oriented RTL.

- **`sim/common`**
  - shared simulation helpers such as `axi_ram_model.v`

- **`sim/stage1` ~ `sim/stage5`**
  - testbenches focused on one stage

- **`sim/integration`**
  - multi-stage and final-pipeline testbenches

### `docs/`

Contains markdown documentation associated with the integrated designs.

## Important note

This reorganization is now a **full move-based layout**.

That means:

- the staged structure under `organized/` is now the authoritative location for the moved RTL and markdown files
- the previous flat top-level `.v` and `.md` files no longer exist at the old paths

## Manifest

See:

- `organized/reorg_manifest.txt`

This file records every copied file and confirms whether any top-level `.v` or `.md` file was left unmapped.

## If a full physical migration is needed later

A true move-based migration would also need follow-up work on:

- Vivado `.xpr` / generated Tcl references
- any simulation scripts that point to old file paths
- shell scripts that read or compile specific RTL paths
- documentation links that mention original locations

At the time this layout was updated:

- all top-level `.v` and `.md` files in `leveldb_compaction_offload` were physically moved into the staged layout
- project references were updated to point at the new paths
