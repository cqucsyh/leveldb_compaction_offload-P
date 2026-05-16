# real_internal_key_two_way_merge_stage5_multiblock validation baseline

## Scope

This baseline freezes the currently passing 2-block multiblock compaction path before extending the design toward N-block descriptors.

Validated RTL path:

- `leveldb_compaction_offload/organized/src/integration/stage4_real_internal_key_two_way_merge_stage5_multiblock_top.v`
- `leveldb_compaction_offload/organized/src/integration/stage4_real_internal_key_two_way_merge_stage5_multiblock_axil_top.v`
- `leveldb_compaction_offload/organized/src/integration/real_internal_key_two_way_merge_stage5_multiblock_top.v`

Validated board-side test entry points:

- `/home/yh/pp4/test_real_internal_key_two_way_merge_stage5_multiblock_xdma_suite.sh`
- `/home/yh/pp4/test_real_internal_key_two_way_merge_stage5_multiblock_xdma_suite_sudo.sh`
- `/home/yh/pp4/test_real_internal_key_two_way_merge_stage5_multiblock_xdma_minimal.sh`
- `/home/yh/pp4/test_real_internal_key_two_way_merge_stage5_multiblock_xdma_sudo.sh`

## Validation command

```bash
bash /home/yh/pp4/test_real_internal_key_two_way_merge_stage5_multiblock_xdma_suite_sudo.sh -v
```

## Result

Full multiscenario hardware suite passed on board.

Observed final suite result:

```text
PASS: multiblock hardware suite completed for scenarios: two_block_cross_boundary_smoke,single_pair_only_smoke,cross_block_duplicate_chain,many_group_cross_block_mix,large_value_cross_block_mix
```

For every scenario, completion status reached:

```text
status=0x00000002 busy=0 done=1 err=0
```

## Covered scenarios

### `two_block_cross_boundary_smoke`

- `block_pairs=2`
- `dst0=53`
- `dst1=38`
- `merge_keep=5`
- `merge_drop=3`

### `single_pair_only_smoke`

- `block_pairs=1`
- `dst0=68`
- `dst1=0`
- `merge_keep=4`
- `merge_drop=1`

### `cross_block_duplicate_chain`

- `block_pairs=2`
- `dst0=64`
- `dst1=45`
- `merge_keep=5`
- `merge_drop=7`

### `many_group_cross_block_mix`

- `block_pairs=2`
- `dst0=295`
- `dst1=318`
- `merge_keep=24`
- `merge_drop=32`

### `large_value_cross_block_mix`

- `block_pairs=2`
- `dst0=1016`
- `dst1=1327`
- `merge_keep=8`
- `merge_drop=8`

## Frozen baseline assumptions

- Current hardware control plane exposes exactly two descriptor slots.
- Duplicate suppression state is preserved from block pair 0 into block pair 1.
- `block_pair_count=1` correctly ignores pair 1 descriptors.
- Shared `mid_base` scratch usage is valid for sequential processing.
- Aggregate counters in the AXI-Lite wrapper match software-generated expectations for all validated scenarios.

## Next step

Extend the 2-slot register model and sequencer into an N-block descriptor model while preserving the above behavior as the compatibility baseline.
