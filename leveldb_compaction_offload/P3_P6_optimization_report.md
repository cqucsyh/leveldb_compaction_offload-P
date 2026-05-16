# P3+P6 数据通路拓宽优化报告

## 1. 优化概述

**P3 (Decoder 8B emit)** 和 **P6 (Merger 8B)** 将解码器和合并器的数据通路从 4 字节/周期 (32-bit) 拓宽到 8 字节/周期 (64-bit)，目标是将流水线吞吐量翻倍。

### 修改的模块

| 模块 | 修改内容 |
|------|---------|
| `cmpct_block_decoder.v` | 8 个 BRAM bank、64-bit 输出、8-bit tkeep、流水线桶形移位器 |
| `cmpct_source_pipe.v` | 输出端口从 32-bit 拓宽到 64-bit |
| `cmpct_merger.v` | 输入/输出 64-bit、8B capture/emit、8-bit tkeep popcount |
| `cmpct_pair_chain.v` | FIFO 从 37-bit 拓宽到 73-bit、流水线寄存器拓宽、添加 64→32 adapter |
| `cmpct_infra.v` | 修复 `stream_width_adapter` 支持任意宽度比（如 64→32） |

## 2. 关键设计决策

### 2.1 Decoder (P3)
- BRAM 从 4 bank 扩展到 8 bank，每周期可并行读出 8 字节
- Emit FSM 的 `ST_EMIT_UNSHARED_KEY`、`ST_EMIT_KEY_BYTES`、`ST_EMIT_VALUE_BYTES` 状态改为 8 字节递增
- `emit_tkeep_from_cnt` 扩展为 8-bit
- `m_axis_tdata` 扩展为 64-bit
- `tlast` 在最后一个 beat 的 `emit_remain <= 8` 时置位

### 2.2 Merger (P6)
- 输入端口 `s0_axis_tdata/tkeep` 从 32/4 拓宽到 64/8
- `ST_CAPTURE0` 状态每周期捕获最多 8 字节到 `user_key_mem` 或 `tag`
- `ST_EMIT_PAYLOAD` 每周期组装并发射 8 字节 key 数据
- `ST_STREAM_VALUE`/`ST_DRAIN_VALUE` 支持 64-bit value 直通
- `output_byte_count` 的 popcount 从 4-bit 扩展到 8-bit

### 2.3 Pair Chain 连线
- 源端 byte FIFO 从 37-bit (32+4+1) 拓宽到 73-bit (64+8+1)
- 流水线寄存器同步拓宽
- Merger 到 encoder 之间的 FIFO 拓宽到 73-bit
- 由于 encoder 仍为 32-bit，添加 `stream_width_adapter` (64→32)

### 2.4 stream_width_adapter 修复
原始实现仅支持 IN→8-bit 转换，索引计算 `hold_index*OUT_DATA_WIDTH` 对 64→32 不正确。修复为字节索引：
```verilog
assign cur_data = hold_data[hold_index*8 +: OUT_DATA_WIDTH];
assign cur_keep = hold_keep[hold_index +: OUT_KEEP_WIDTH];
```

## 3. 仿真结果

### 3.1 功能验证
4 项集成测试全部通过：
- `run_sim_sstable_engine_axil.sh` — 全引擎 AXI-Lite 测试
- `run_sim_sstable_engine_split.sh` — SSTable 分割测试
- `run_sim_sstable_asym.sh` — 非对称 block pair 测试
- `run_sim_sstable_engine_stress.sh` — 多轮压力测试

### 3.2 仿真周期数对比
| 测试场景 | 修改前 (cycles) | 修改后 (cycles) | 减少比例 |
|----------|----------------|----------------|---------|
| 3-pair AXI-Lite 引擎测试 | 2417 | 1057 | **56%** |

仿真估算内部流水线吞吐：~430 MB/s @ 250 MHz

## 4. 硬件测试结果

### 4.1 小数据测试 (bench_p3p6_throughput.sh)
- **测试数据**: 2 个 4.3 KB SSTable，4 block pairs
- **FPGA 周期数**: ~8,163 cycles/run
- **计算吞吐**: ~263 MB/s (source read, decimal)

### 4.2 大规模基准测试 (test_opt_perf_xdma.sh)
- **测试数据**: 2 × 252 KB SSTable，200 block pairs
- **总处理量**: 1024 MB (2126 次运行)
- **FPGA 周期数**: ~630,851 cycles/run (极稳定，σ < 500)
- **硬件吞吐**: **191 MiB/s** (≈ 200 MB/s)

### 4.3 结果分析

| 指标 | P3+P6 前 (baseline) | P3+P6 后 | 变化 |
|------|---------------------|----------|------|
| 仿真 cycles (3-pair) | 2417 | 1057 | -56% |
| 硬件吞吐 (200-pair) | ~191 MiB/s | ~191 MiB/s | **无提升** |
| Bytes/cycle (200-pair) | ~0.80 | ~0.80 | 无变化 |

**硬件吞吐未提升的原因：**

1. **Encoder 瓶颈**: Encoder 仍为 32-bit (4B/cycle)，64→32 adapter 将前级 8B/cycle 带宽砍半。Encoder 成为整条流水线的限速环节。
2. **DDR 延迟**: 真实 DDR 每次 AXI burst 有 ~100ns 延迟，Decoder 频繁等待数据，无法维持满吞吐。
3. **Pair 切换开销**: 200 block pair 间的切换（解码器复位、AXI 读重启、pipeline drain）产生大量死周期。

## 5. 后续优化方向

| 优化 | 目标 | 预期效果 |
|------|------|---------|
| **P7: Encoder 64-bit** | Encoder emit 从 4B/cycle → 8B/cycle | 消除 encoder 瓶颈 |
| **P8: Pair 切换优化** | 减少 pair 间 pipeline drain 死周期 | 提升多 pair 场景效率 |

---

# P7+P8 Encoder 拓宽 + Pair 切换延迟优化

## P7: Encoder 64-bit 拓宽

### 修改内容

| 模块 | 修改内容 |
|------|---------|
| `cmpct_block_encoder.v` | 输入/输出 64-bit + 8-bit tkeep、8-way prefix comparison、64-bit varint packing、8B key emit、2 restarts/cycle |
| `stream_byte_packer_64.v` | **新增** — 64-bit 变 tkeep 到 dense 64-bit 的 byte packer，15-byte shift-register accumulator |
| `cmpct_infra.v` | 新增 `crc32c_8byte_streamer`（8B CRC）和 `block_trailer_appender_w64`（64-bit trailer） |
| `cmpct_pair_chain.v` | 移除 64→32 adapter，encoder 直连 64-bit FIFO；替换 packer_32 → packer_64；替换 trailer_w32 → trailer_w64；final pack 32→AXI 改为 64→AXI |

### 关键设计决策

- **8-way prefix comparison**: 8 字节并行比较 + priority encoder 找首个 mismatch，组合逻辑深度 ≈ 3 LUT levels
- **64-bit varint packing**: 单周期 emit 完整 varint（1-4 bytes）到 64-bit word 的低位
- **CRC 8B/cycle**: 8 级 byte-CRC 级联，组合逻辑深度 ≈ 40 LUT levels，可在 200-250 MHz 收敛
- **数据通路简化**: 移除了 64→32 adapter、32→8→32 trailer 重打包路径，端到端全 64-bit

## P8: Pair 切换延迟优化

### 修改内容

| 模块 | 修改内容 |
|------|---------|
| `cmpct_nblock_engine.v` | 合并 ST_PIPE_CLEAR + ST_PIPE_START → ST_PIPE_RESTART（deferred front_start）；descriptor pre-fetch during ST_WAIT |

### 优化策略

1. **合并 clear/start**: 原先 `front_clear` 和 `front_start` 分 2 个 state 发送（2 cycle），现合并为 1 个 state + deferred 1-cycle `front_start_pending`，节省 **1 dead cycle/transition**
2. **Descriptor pre-fetch**: 在 ST_WAIT 状态预取下一个 descriptor，enc_done 时直接使用，跳过 ST_POP，节省 **1 dead cycle/transition**（DESC_STREAM 模式）

### 仿真性能对比

| 测试场景 | P6 基线 (cycles) | P7+P8 (cycles) | 节省 | 改善比 |
|----------|-----------------|----------------|------|--------|
| 2-pair (axil) | 1057 | 938 | 119 | **11.3%** |
| 1-pair (1blk) | — | 756 | — | 基准 |
| 4-pair asymmetric | — | 1457 | — | — |
| 16-pair stress R1 | 5901 | 4997 | 904 | **15.3%** |
| 16-pair stress R3 (split) | 5901 | 5386 | 515 | **8.7%** |
| 4-pair split | — | 1740 | — | — |

### 改善分析

- **单对处理加速**: 64-bit encoder 将 key 接收、比较、emit 吞吐翻倍，varint/restart 写入效率提升 2×
- **多对切换加速**: Pair 切换从 3-4 dead cycles 减少到 1-2 cycles，对小 block（< 1KB）场景影响显著
- **16-pair 综合效果**: 4997 vs 5901 = **15.3% 总体提升**，来自 encoder 吞吐提升 + 切换延迟缩减

## 6. 文件清单

```
rtl_v2/cmpct_block_decoder.v     — P3: 8-bank BRAM, 64-bit emit
rtl_v2/cmpct_source_pipe.v       — P3: 64-bit output ports
rtl_v2/cmpct_merger.v            — P6: 64-bit I/O, 8B capture/emit
rtl_v2/cmpct_block_encoder.v     — P7: 64-bit encoder, 8B key recv/emit
rtl_v2/stream_byte_packer_64.v   — P7: 64-bit variable-tkeep byte packer
rtl_v2/cmpct_infra.v             — P7: crc32c_8byte_streamer + block_trailer_appender_w64
rtl_v2/cmpct_pair_chain.v        — P7: 64-bit encoder path (no 64→32 adapter)
rtl_v2/cmpct_nblock_engine.v     — P8: merged pipe restart + descriptor pre-fetch
bench_p3p6_throughput.sh         — 硬件吞吐测试脚本 (cmpct_top)
```
