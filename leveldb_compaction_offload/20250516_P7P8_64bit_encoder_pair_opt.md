# P7+P8 优化进度报告：64-bit Encoder 拓宽 + Pair 切换延迟优化

> 日期：2025-05-16  
> 基于 P3+P6（Decoder/Merger 64-bit 拓宽）之上的第二轮优化

---

## 1. 优化背景

P3+P6 将 Decoder 和 Merger 从 32-bit 拓宽到 64-bit (8B/cycle)，仿真 cycle 减少 56%，但**硬件吞吐未提升**（维持 ~191 MiB/s）。根因分析发现：

1. **Encoder 瓶颈**：Encoder 仍为 32-bit (4B/cycle)，中间有 64→32 adapter 砍半带宽
2. **Pair 切换开销**：200 block pair 间的 front_clear + front_start 需 3-4 dead cycles

本轮 P7+P8 分别针对这两个根因进行优化。

---

## 2. P7：Encoder 64-bit 拓宽

### 2.1 修改模块一览

| 文件 | 修改内容 |
|------|---------|
| `cmpct_block_encoder.v` | 输入/输出 64-bit + 8-bit tkeep；8-way 并行 prefix comparison；64-bit varint packing（单周期 emit 完整 varint）；8B key buffer 读写；2 restarts/cycle emit |
| `stream_byte_packer_64.v` | **新建** — 64-bit 变 tkeep → dense 64-bit byte packer，15-byte shift-register accumulator |
| `cmpct_infra.v` | 新增 `crc32c_8byte_streamer`（8 级 byte-CRC 级联，8B/cycle）和 `block_trailer_appender_w64`（64-bit trailer appender） |
| `cmpct_pair_chain.v` | 移除 `stream_width_adapter`(64→32)；Encoder 直连 64-bit merge FIFO；`stream_byte_packer_32` → `stream_byte_packer_64`；`block_trailer_appender_w32` → `block_trailer_appender_w64`；删除 32→8→32 trailer 重打包路径；final pack adapter 从 32→AXI 改为 64→AXI |

### 2.2 关键设计决策

- **8-way prefix comparison**：8 字节并行比较 + priority encoder 找首个 mismatch，组合逻辑深度 ≈ 3 LUT levels
- **64-bit varint packing**：`varint32_pack` function 单周期将 varint 值编码到 64-bit word 低位，tkeep 标记有效字节数（1-5 bytes）
- **CRC 8B/cycle**：8 级 `crc32c_byte_f` 级联，组合逻辑深度 ≈ 40 LUT levels，可在 200-250 MHz 收敛
- **数据通路简化**：端到端全 64-bit 通路，消除了 3 个中间宽度转换模块

### 2.3 数据通路变化

```
修改前 (P6):
  Merger(64) → FIFO(73) → [64→32 adapter] → Encoder(32) → packer_32 → FIFO(37)
  → trailer_w32 → [32→8] → [8→32] → [32→AXI] → write_engine

修改后 (P7):
  Merger(64) → FIFO(73) → Encoder(64) → packer_64 → FIFO(73)
  → trailer_w64 → packer_64 → [64→AXI] → write_engine
```

---

## 3. P8：Pair 切换延迟优化

### 3.1 修改模块

| 文件 | 修改内容 |
|------|---------|
| `cmpct_nblock_engine.v` | 合并 `ST_PIPE_CLEAR` + `ST_PIPE_START` → `ST_PIPE_RESTART`；新增 `front_start_pending` 延迟触发机制；新增 descriptor pre-fetch 逻辑 |

### 3.2 优化策略

**合并 clear/start 状态**：原先 `front_clear` 和 `front_start` 分 2 个 FSM state 依次发送（2 cycles），现合并为 1 个 `ST_PIPE_RESTART` state + deferred 1-cycle `front_start_pending`，**节省 1 dead cycle/transition**。

```
修改前: enc_done → ST_POP → ST_PIPE_CLEAR → ST_PIPE_START → ST_WAIT  (4 cycles)
修改后: enc_done → ST_PIPE_RESTART → ST_WAIT (front_start 自动延迟)  (2 cycles)
```

**Descriptor pre-fetch**：在 `ST_WAIT` 状态空闲期间预取下一个 block pair 的 descriptor，enc_done 时直接使用预取结果，跳过 `ST_POP`，**再省 1 dead cycle/transition**（DESC_STREAM 模式）。

**Bug fix**：修复了 split 路径下 `desc_ready` 在 `ST_POP` + `desc_prefetched` 同时为真时的双重消费问题——`desc_ready` 现在在 `ST_POP` 中检查 `!desc_prefetched`。

---

## 4. 仿真验证

### 4.1 测试通过情况

全部 **5 项**集成仿真测试通过，零错误：

| 测试 | 说明 | 结果 |
|------|------|------|
| `run_sim_sstable_engine_axil.sh` | 2-pair 全引擎 AXI-Lite | ✅ PASS |
| `run_sim_sstable_engine_axil_1blk.sh` | 单 block pair | ✅ PASS |
| `run_sim_sstable_engine_split.sh` | SSTable 分割 (2 phase) | ✅ PASS |
| `run_sim_sstable_asym.sh` | 非对称 4-pair | ✅ PASS |
| `run_sim_sstable_engine_stress.sh` | 16-pair 三轮压力测试 | ✅ PASS |

### 4.2 仿真 Cycle 对比

| 测试场景 | P6 基线 | P7+P8 | 节省 cycles | 改善比 |
|----------|---------|-------|-------------|--------|
| 2-pair (axil) | 1,057 | 938 | 119 | **11.3%** |
| 16-pair stress R1 | 5,901 | 4,997 | 904 | **15.3%** |
| 16-pair stress R3 (split) | 5,901 | 5,386 | 515 | **8.7%** |

---

## 5. 硬件测试结果

### 5.1 测试环境

- **FPGA 时钟**：200 MHz
- **测试工具**：`test_opt_perf_xdma.sh -M 1024 -f 200`
- **测试数据**：200 block pairs, 505,278 bytes/run (2 × ~252 KB SSTable)
- **总处理量**：1,024 MB (2,126 次运行)，**零错误**

### 5.2 结果对比

| 指标 | P3+P6 基线 | **P7+P8** | 变化 |
|------|-----------|-----------|------|
| HW throughput (avg) | 191 MiB/s | **254.7 MB/s** | **+33%** |
| HW throughput (best) | 191 MiB/s | **255.4 MB/s** | **+34%** |
| Bytes/cycle (avg) | 0.80 | **1.335** | **+67%** |
| Avg cycles/run | 630,851 | **378,427** | **-40%** |
| Min cycles/run | — | **377,337** | — |
| Max cycles/run | — | **380,199** | — |
| Cycle 标准差 | < 500 | < 800 | 极稳定 |

### 5.3 关键发现

P7+P8 硬件实测 **远超之前的预估**（预估 200-210 MiB/s，实测 255 MB/s），说明 Encoder 确实是之前最大的瓶颈，而非之前怀疑的 DDR 延迟。Cycles/run 从 630k 降到 378k（-40%），表明 Encoder 处理速度从 4B/cycle 到 8B/cycle 的加速效果在硬件上被充分体现。

---

## 6. 当前流水线瓶颈分析

### 6.1 Per-pair Cycle 预算

```
输入数据:   505,278 bytes / 200 pairs = 2,526 bytes/pair
实测 cycles: 378,427 / 200 = 1,892 cycles/pair
理论极限 (8B/cycle): 2,526 / 8 = 316 cycles/pair
效率: 316 / 1,892 = 16.7%
```

**83% 的 cycle 消耗在哪里？** 以下按影响大小排序：

### 6.2 瓶颈 #1：Decoder 输入仍为 byte-serial（最大瓶颈）

**这是当前最严重的性能限制。** 虽然 AXI 读接口是 512-bit (64 bytes/beat)，数据在进入 Decoder 之前被序列化为 **1 byte/cycle**：

```
AXI Read(512-bit) → stream_width_adapter(512→8) → byte_skip → Decoder(8-bit input)
```

`cmpct_source_pipe.v` 中的 `stream_width_adapter` 将每个 64-byte AXI beat 拆成 64 个独立 byte 传输。Decoder 的 capture 阶段必须逐字节接收并写入 BRAM。

**影响估算**：每个 source block ~1,263 bytes，capture 阶段至少需要 **1,263 cycles**。两个 source 并行 capture → 1,263 cycles 占总 1,892 cycles/pair 的 **67%**。

### 6.3 瓶颈 #2：AXI 读引擎无 Outstanding Reads

`axi_read_engine` 采用严格串行 burst 模式：

```verilog
// cmpct_infra.v line 419:
if (!m_axi_arvalid && !waiting_for_r && (beats_remaining != 32'd0)) begin
    // issue next burst
end
```

`waiting_for_r` 标志在整个 burst 数据返回前阻止下一个 AR 请求。对于需要 2+ burst 的 block，DDR 延迟 (~100ns = 20 cycles @200MHz) 被完全串行化。

### 6.4 瓶颈 #3：Decoder 内部 FSM 开销

每条 record 的解码过程涉及多个 FSM 状态跳转：
- Varint 解码 (shared_len, unshared_len, value_len)：每个 varint 1-5 cycles
- Key 重建（从共享前缀）：多 cycle BRAM 读操作
- Emit 阶段（key + value）：虽已 8B/cycle，但启动开销每 record 有 ~5-10 cycles

### 6.5 瓶颈 #4：Pair 切换与 Pipeline Drain

虽然 P8 已优化到 2 dead cycles/transition，200 pairs 仍有 ~400 dead cycles（总 cycle 的 ~0.1%，影响已很小）。

---

## 7. 后续优化方向——显著提升硬件吞吐的路线图

按**预期收益/实现难度**排序：

### 7.1 🔴 P9：Decoder 宽输入（预期 +50~100%，最高优先级）

**目标**：将 Decoder 输入从 1 byte/cycle 拓宽到 8 bytes/cycle (64-bit) 或更宽。

**当前路径**：
```
AXI(512b) → [512→8] → byte_skip → Decoder(8-bit capture, 1 byte/cycle)
```

**优化后**：
```
AXI(512b) → [512→64] → 64-bit skip → Decoder(64-bit capture, 8 bytes/cycle)
```

**关键挑战**：
- Decoder capture FSM 需要重写：当前逐字节写入 BRAM bank，需改为 8 字节并行写入
- Varint 解码需要适应多字节输入：varint 的变长编码在多字节并行时需要 lookahead 逻辑
- Block 尾部的 restart index 解析逻辑需适配
- BRAM bank 写冲突处理（8 bytes 可能跨 bank boundary）

**预期收益**：capture 阶段从 1,263 cycles → ~158 cycles，pair 总时间可能降至 ~800 cycles，**吞吐翻倍至 ~500 MB/s**。

### 7.2 🟠 P10：AXI Outstanding Reads（预期 +10~20%）

**目标**：支持 2-4 个 outstanding read burst，隐藏 DDR 延迟。

**修改点**：
- `axi_read_engine` 中移除 `waiting_for_r` 对 AR 发送的阻塞
- 增加 burst tracking 计数器（跟踪 in-flight burst 数量）
- 增加 FIFO 缓冲 AXI 读返回数据，防止背压停顿 DDR 控制器

**实现难度**：中等。需确保 burst 顺序和 RLAST 处理正确。

### 7.3 🟡 P11：时钟频率提升（预期 +25%）

**目标**：从 200 MHz 提升到 250 MHz。

**关注的关键路径**：
- `crc32c_8byte_streamer`：8 级 byte-CRC 级联（~40 LUT levels），可能需要插入流水线寄存器
- Encoder 的 8-way prefix comparison 链
- Decoder varint 解码的组合逻辑

**方法**：Vivado timing 分析 → 在关键路径插入 pipeline register → retiming。

### 7.4 🟢 P12：Record-level 流水线重叠

**目标**：Decoder 边 capture 边 emit，不等待整个 block capture 完成。

**当前行为**：Decoder 先 capture 整个 block 到 BRAM，然后再逐 record emit。两阶段串行。

**优化**：当第一个 record 的数据完全到达 BRAM 后，立即开始 emit，同时继续 capture 后续数据。需要管理 read/write pointer 和 hazard 检测。

### 7.5 🔵 长期方向：多 Pair Chain 并行

如果单链已接近 DDR 带宽上限（DDR4 理论 ~12.8 GB/s @ 3200 MT/s），可实例化 2-4 个独立的 `cmpct_pair_chain`，每个处理不同的 block pair，共享 DDR 带宽。

需要 AXI interconnect 仲裁和足够的 DDR bandwidth margin。

---

## 8. 优化路线图总结

```
                    当前                 P9 后                P9+P10+P11 后
                    ─────                ──────               ──────────────
HW Throughput:     255 MB/s    →    ~450-500 MB/s     →     ~600-800 MB/s
Bytes/cycle:        1.34       →     ~2.5-2.7         →      ~2.5-3.2
主要瓶颈:       Decoder 1B/cyc    AXI latency+Fmax     DDR bandwidth
```

**最大的单项优化**是 P9（Decoder 宽输入），预期可将吞吐**翻倍**。其余 P10-P12 是递减收益的叠加优化。

---

## 9. 完整文件变更清单

```
rtl_v2/cmpct_block_encoder.v       — P7: 64-bit I/O, 8-way prefix cmp, 64-bit varint
rtl_v2/stream_byte_packer_64.v     — P7: 新建，64-bit variable-tkeep byte packer
rtl_v2/cmpct_infra.v               — P7: +crc32c_8byte_streamer, +block_trailer_appender_w64
rtl_v2/cmpct_pair_chain.v          — P7: 全 64-bit encoder path, 移除 64→32 adapter
rtl_v2/cmpct_nblock_engine.v       — P8: ST_PIPE_RESTART + desc pre-fetch + bugfix

sim/integration/run_sim_sstable_engine_axil.sh      — 添加 stream_byte_packer_64.v
sim/integration/run_sim_sstable_engine_axil_1blk.sh — 同上
sim/integration/run_sim_sstable_engine_stress.sh    — 同上
sim/integration/run_sim_sstable_engine_split.sh     — 同上
sim/integration/run_sim_sstable_asym.sh             — 同上
```
