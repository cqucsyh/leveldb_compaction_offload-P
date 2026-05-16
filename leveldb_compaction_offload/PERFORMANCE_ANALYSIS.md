# LevelDB Compaction FPGA Offload — GB/s 吞吐优化分析

*2026-05-13*

---

## 一、当前性能基线

| 指标 | 值 |
|------|-----|
| 引擎时钟 | 300 MHz |
| AXI 数据宽度 | 512 bit (64 B/beat) |
| 每轮输入 | 505,278 bytes (200 block pairs, 8000 records) |
| 每轮 HW 周期 | 989,049 cycles |
| **吞吐效率** | **0.51 bytes/cycle** |
| **纯硬件吞吐** | **97.4 MB/s** |
| Host 端吞吐 | 30.2 MB/s (含 XDMA 寄存器轮询开销) |

**目标：1 GB/s = 3.33 bytes/cycle @ 300 MHz → 需要 6.5× 提升**

---

## 二、瓶颈定量分析

### 2.1 每条记录的周期成本

典型记录：user_key=16B + tag=8B = 24B key，value≈39B，总计≈63B

| 阶段 | 模块 | 周期/记录 | 数据通路 | 说明 |
|------|------|-----------|----------|------|
| Varint 解析 | block_decoder | 3 | 1B/cycle | 3 个 varint × ~1 byte |
| Shared key 发射 | block_decoder | 2-3 | 4B/cycle | prev_key_mem 读 |
| Unshared key 发射 | block_decoder | 4-5 | 4B/cycle | BRAM 4-bank 读 |
| Value 发射 | block_decoder | 10-11 | 4B/cycle | BRAM 4-bank 读 |
| **Decoder 总计** | | **~20** | | |
| Key 捕获 | merger | 6 | 4B/cycle | user_key_mem 写 |
| Key 比较 | merger | 6 | 8B/cycle | CMP_CHUNK=8 + C1a pipeline |
| 去重检查 | merger | 6 | 8B/cycle | 同上 |
| Key 发射 | merger | 6 | 4B/cycle | user_key_mem 读 |
| Value 直通 | merger | 10 | 4B/cycle | OPT-A2b cut-through |
| 开销 (header/finalize) | merger | 3 | — | FSM 转换 |
| **Merger 总计** | | **~37** | | **关键瓶颈** |
| Key 接收+比较 | encoder | 6 | 4B/cycle | 双 buffer + inline 比较 |
| Varint 输出 | encoder | 3 | 1 varint/cycle | shared+unshared+value_len |
| Key 输出 | encoder | 4 | 4B/cycle | unshared key 部分 |
| Value 直通 | encoder | 10 | 4B/cycle | stream-through |
| **Encoder 总计** | | **~23** | | |

### 2.2 Pipeline 瓶颈结构

```
Decoder0 ──┐                          
            ├─→ [FIFO] → Merger ──→ [FIFO] → Encoder → Writer
Decoder1 ──┘      ▲                   ▲
                   │                   │
              backpressure        backpressure
```

**关键发现**：

1. **Merger 是单条链的吞吐天花板**：37 cycles/record → 1.70 B/cycle → **512 MB/s 理论极限**
2. **流水线串行化严重**：merger 的 capture → compare → check → emit 全部串行，不能与下一条记录重叠
3. **实测 124 cycles/record vs 理论 37 cycles/record**：3.4× 差距来自 pipeline stall 和 backpressure
4. **AXI 带宽利用率极低**：512-bit 端口 @ 300MHz = 19.2 GB/s，实际仅用 0.5%

### 2.3 实测 vs 理论差距的根因

| 原因 | 估算浪费 | 说明 |
|------|----------|------|
| Merger 串行处理 | ~50% | capture0 → capture1 → compare → emit 不能重叠 |
| C1a pipeline 额外延迟 | ~15% | 每次 compare/check 需要 2 额外周期等待寄存器锁存 |
| Value 直通 backpressure | ~20% | encoder 的 varint 输出阻塞 merger 的 value 直通 |
| Inter-block FSM 开销 | ~5% | clear + start + setup per block pair |
| Decoder 等待 BRAM capture | ~10% | 流式解码等待 capture 追上 parse |

---

## 三、优化方案（按优先级排列）

### ★★★ 优先级 1：多链并行 (Multiple Parallel Pair Chains)

**影响：N× 吞吐（N = 并行链数）| 难度：中高 | 风险：中**

这是达到 GB/s 的**唯一可行主路径**。单条链理论极限 ~512 MB/s，即使完美优化也不够。

#### 方案

```
                    ┌─ pair_chain_0 (blocks 0,4,8,...)  ─→ writer_0
Parser0 ──┐         │
           ├─ Desc ─┼─ pair_chain_1 (blocks 1,5,9,...)  ─→ writer_1
Parser1 ──┘  Match  │
                    ├─ pair_chain_2 (blocks 2,6,10,...) ─→ writer_2
                    │
                    └─ pair_chain_3 (blocks 3,7,11,...) ─→ writer_3
                                                            │
                                    Assembler ◄─────────────┘
```

- `desc_matcher` 输出的 block pair descriptor 通过 round-robin 或 load-balance 分配给 N 条 `pair_chain`
- 每条 chain 独立拥有：2× source_pipe + 2× decoder + merger + encoder + writer
- 所有 chain 共享 AXI interconnect 访问 DDR
- Assembler 接收所有 chain 的 block metadata，按序组装 SSTable

#### 资源评估 (VU37P: 1.18M LUTs, 2160 BRAM36)

| 并行度 | LUTs (估算) | BRAM | 吞吐 | 达标？ |
|--------|-------------|------|------|--------|
| 1 (当前) | 26K (2.2%) | 24 (1.1%) | 97 MB/s | ❌ |
| 4 | 104K (8.8%) | 96 (4.4%) | 390 MB/s | ❌ |
| 8 | 208K (17.6%) | 192 (8.9%) | 779 MB/s | 接近 |
| **12** | **312K (26.4%)** | **288 (13.3%)** | **1.17 GB/s** | **✅** |
| 16 | 416K (35.2%) | 384 (17.8%) | 1.56 GB/s | ✅ |

#### 关键挑战

1. **AXI 互联**：N 条 chain × 3 AXI 端口 = 3N 个 AXI master，需要高效的 AXI crossbar/arbiter
2. **DDR 带宽**：DDR4-3200 实际 ~17.5 GB/s，每链 ~300 MB/s (2 read + 1 write)，DDR 支撑 ~50+ 链
3. **跨链 dedup 一致性**：需要将上一链的 `final_prev_user_key` 传递给下一链作为 `seed_prev_user_key`
4. **组装器协调**：Assembler 需要按 block 顺序接收所有链的 metadata

#### 实现步骤

1. 参数化 `cmpct_engine.v`，添加 `N_CHAINS` 参数
2. 在 `desc_matcher` 后加 round-robin dispatcher
3. 实例化 N 个 `cmpct_pair_chain`
4. 添加 AXI read/write arbiter (或使用 Vivado AXI SmartConnect)
5. 修改 `nblock_engine` 支持多链跨 block dedup 链 (`prev_user_key` chain forwarding)
6. Assembler 从 N 个 chain 收集 block metadata

#### 预估工期：2-3 周

---

### ★★★ 优先级 2：Merger 流水线化 (Pipelined Merger)

**影响：单链 1.5-2× | 难度：高 | 风险：中高**

结合多链并行，可以将所需链数从 12 降到 6-8。

#### 当前问题

```
Time:  |--cap0--|--cap1--|--compare--|--check--|--final--|--emit_key--|--stream_val--|
                                                                                     |--cap0 (next)--|...
```

每条记录全部串行处理，下一条记录必须等当前完成。

#### 优化方案：双缓冲 + 状态重叠

```
Time:  |--cap0--|--cap1--|--compare--|--check--|--final--|--emit_key--|--stream_val--|
                                                          |--cap0'---|--cap1'-------|--compare'--|...
```

- **双缓冲 user_key_mem**：`user_key_mem0_a/b`, `user_key_mem1_a/b`，一组用于当前比较/发射，另一组同时捕获下一对 key
- **重叠 capture 与 emit**：当前记录进入 EMIT_PAYLOAD / STREAM_VALUE 时，同时开始捕获下一对 key
- **预计节省**：每记录节省 ~13 cycles (capture0 + capture1 时间)，约 35% 提升

#### 关键约束

- 需要双端口 BRAM 或双份 user_key_mem 寄存器
- FSM 复杂度显著增加（两组状态交替）
- 跨记录去重仍然串行（必须等 compare 结果确定 keep/drop 后才能更新 prev_user_key）

#### 预估工期：1-2 周

---

### ★★☆ 优先级 3：加宽 Merger 数据通路 (8B/cycle)

**影响：单链 1.3-1.5× | 难度：中 | 风险：低**

#### 当前瓶颈

- Key 捕获：4B/cycle → 24B key 需 6 cycles
- Key 发射：4B/cycle → 24B key 需 6 cycles
- Value 直通：4B/cycle → 39B value 需 10 cycles

#### 优化方案

将 merger 的 AXI-Stream 数据通路从 32-bit 加宽到 64-bit：

- `s0_axis_tdata/tkeep/tready`: 32-bit → 64-bit
- `m_axis_tdata/tkeep`: 32-bit → 64-bit
- Key capture: 8B/cycle → 24B key 只需 3 cycles
- Key emit: 8B/cycle → 24B key 只需 3 cycles
- Value pass-through: 8B/cycle → 39B value 只需 5 cycles

同步修改上下游接口：
- `block_decoder` 输出加宽到 64-bit (已有 4-bank BRAM，可扩展到 8-bank)
- `block_encoder` 输入加宽到 64-bit

#### 影响分析

| 组件 | 当前 cycles/record | 加宽后 | 节省 |
|------|-------------------|--------|------|
| Key capture | 6 | 3 | 3 |
| Key emit | 6 | 3 | 3 |
| Value stream | 10 | 5 | 5 |
| **Merger 总计** | **37** | **~26** | **~30%** |

#### 预估工期：1 周

---

### ★★☆ 优先级 4：消除 C1a Pipeline 额外延迟

**影响：单链 1.1-1.2× | 难度：低 | 风险：低**

#### 当前问题

OPT-C1a 注册式比较器要求 `cmp_pipe_valid` 每 2 cycle 才有效一次：
```verilog
// 需要 prev_state == ST_COMPARE_INPUTS 才 toggle valid → 额外 1 cycle 延迟
if ((state == ST_COMPARE_INPUTS && prev_state == ST_COMPARE_INPUTS) ...)
    cmp_pipe_valid <= !cmp_pipe_valid;
```

对于 16B user_key, CMP_CHUNK=8：理论 2 chunks = 2 cycles，实际 2 chunks × 3 cycles = 6 cycles。

#### 优化方案

方案 A：**单周期 compare 结果**
- 将 CMP_CHUNK 从 8 扩大到 32（或 64），一次性比较所有 user_key 字节
- 用一个 32-byte 宽比较器在 1-2 cycle 内完成整个 key 比较
- 资源开销：~256 个 LUT6 (可接受)
- 收益：compare 从 6 cycles → 2 cycles，check_keep 从 6 → 2 cycles
- 每记录节省 ~8 cycles

方案 B：**流水线优化**
- 去掉 `prev_state` 检查，改用发射-等待-读取的显式 3 状态编码
- 减少每 chunk 从 3 → 2 cycles

#### 预估工期：2-3 天

---

### ★★☆ 优先级 5：Host 端中断驱动

**影响：Host 吞吐 3× (30 → 90+ MB/s) | 难度：低 | 风险：低**

#### 当前问题

每轮 FPGA 处理 ~3.3 ms，但 host 端寄存器轮询 + DMA 编程 + 状态检查增加 ~12 ms，导致 host 吞吐仅 30 MB/s。

#### 优化方案

1. **MSI-X 中断**：XDMA IP 已支持 MSI-X，配置 `usr_irq_req` 在 `done` 信号上触发中断
2. **RTL 修改**：在 `cmpct_top.v` 添加 `irq_request` 输出，连接 XDMA 的 `usr_irq_req[0]`
3. **驱动修改**：使用 `/dev/xdma0_events_0` 的 `read()` 阻塞等待替代 register polling
4. **批量寄存器写**：将多个 reg write 合并为单次 AXI burst（利用 XDMA bypass 模式）

#### 预估工期：2-3 天

---

### ★☆☆ 优先级 6：Decoder 8-bank BRAM (8B/cycle emit)

**影响：单链 1.1-1.2× | 难度：中 | 风险：低**

当前 `block_decoder` 使用 4-bank interleaved BRAM，4B/cycle emit。扩展到 8-bank：

- Value emit: 10 cycles → 5 cycles (39B)
- Unshared key emit: 4 cycles → 2 cycles (14B)
- 每记录节省 ~7 cycles
- BRAM 用量翻倍 (4→8 per decoder, total 8→16 per chain)

当 merger 数据通路同步加宽后（优先级 3），decoder 必须匹配 8B/cycle 输出。

#### 预估工期：3-5 天

---

### ★☆☆ 优先级 7：双 SSTable Pair 批处理

**影响：Host 吞吐 2× | 难度：低 | 风险：低**

当前每次 FPGA 调用处理 1 对 SSTable。修改为接受 2-4 对 SSTable 的批处理队列：
- 上传所有 SSTable 到 DDR
- 写入任务描述符数组
- 单次启动 → FPGA 顺序处理所有 pair → 单次中断通知完成
- 消除 per-pair 的 DMA 编程和 reg 配置开销

#### 预估工期：3-5 天

---

### ☆☆☆ 优先级 8：全 64-bit 数据通路重设计

**影响：理论 2× | 难度：极高 | 风险：高**

将整条 pipeline 从 32-bit (4B/cycle) 全面升级到 64-bit (8B/cycle)。包括：
- Decoder: 8-bank BRAM + 8B emit
- Merger: 8B capture/emit + 更宽 MUX
- Encoder: 8B varint pack + 8B key/value stream
- 所有 FIFO 和 stream adapter 加宽

工程量大但对单链吞吐有 ~2× 提升。建议在多链并行稳定后再考虑。

---

## 四、推荐实施路线

```
Phase 1 (1 周)  ─── 单链快速优化 ───
  ├─ [P4] 消除 C1a pipeline 额外延迟    (+10-20%)
  ├─ [P5] Host 端 MSI-X 中断驱动         (Host 30→90 MB/s)
  └─ 目标: 单链 ~120 MB/s, Host ~90 MB/s

Phase 2 (2 周)  ─── 数据通路加宽 ───
  ├─ [P3] Merger 加宽到 8B/cycle          (+30%)
  ├─ [P6] Decoder 8-bank BRAM             (+15%)
  └─ 目标: 单链 ~170 MB/s

Phase 3 (3 周)  ─── 多链并行 ───
  ├─ [P1] 实现 4-chain 并行架构           (×4)
  ├─ AXI arbiter/crossbar 集成
  └─ 目标: 4 链 × 170 = ~680 MB/s

Phase 4 (2 周)  ─── 扩展与调优 ───
  ├─ [P1] 扩展到 8 链                     (×2)
  ├─ [P2] Merger 流水线化 (如有需要)
  ├─ [P7] 批量 SSTable 处理
  └─ 目标: 8 链 × 170 = ~1.36 GB/s ✅
```

### 总计预估：8 周达到 1+ GB/s

---

## 五、总结

| 排名 | 优化项 | 单项提升 | 开发周期 | ROI |
|------|--------|----------|----------|-----|
| **1** | **多链并行 (N chains)** | **N×** | **2-3 周** | **★★★★★** |
| **2** | **Merger 流水线化** | **1.5-2×** | **1-2 周** | **★★★★** |
| **3** | **Merger 8B/cycle 通路** | **1.3×** | **1 周** | **★★★★** |
| 4 | 消除 C1a pipeline 延迟 | 1.1-1.2× | 2-3 天 | ★★★ |
| 5 | Host MSI-X 中断 | Host 3× | 2-3 天 | ★★★ |
| 6 | Decoder 8-bank BRAM | 1.1-1.2× | 3-5 天 | ★★☆ |
| 7 | 批量 SSTable 处理 | Host 2× | 3-5 天 | ★★☆ |
| 8 | 全 64-bit 数据通路 | 2× | 4+ 周 | ★☆☆ |

**核心结论**：单链优化最多到 ~250 MB/s（理论极限 512 MB/s 但受 pipeline stall 限制）。**达到 GB/s 必须走多链并行路线**。VU37P 资源充裕（8-16 链仅占 18-35% LUT），DDR 带宽也不是瓶颈。关键工程挑战在 AXI 互联和跨链 dedup 一致性。
