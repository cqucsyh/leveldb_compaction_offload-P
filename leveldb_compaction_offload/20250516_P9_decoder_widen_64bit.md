# P9 优化报告：Decoder 输入 64-bit 拓宽 + AXI Read Engine 竞态修复

> 日期：2025-05-16  
> 基于 P7+P8（Encoder 64-bit + Pair 切换优化）之上的第三轮优化

---

## 1. 优化背景

P7+P8 将 Encoder 从 32-bit 拓宽到 64-bit 并优化了 Pair 切换延迟，硬件吞吐从 191 → 255 MB/s。瓶颈分析表明：

**Decoder 的 capture 阶段是最大瓶颈**：AXI 读接口 512-bit，但数据在进入 Decoder 前被序列化为 1 byte/cycle：

```
AXI Read(512b) → [512→8 adapter] → byte_skip(8-bit) → Decoder(8-bit capture)
```

每个 ~1,263 bytes 的 source block capture 需要 **1,263 cycles**，占 pair 总 1,892 cycles 的 **67%**。

---

## 2. P9：Decoder 输入 64-bit 拓宽

### 2.1 设计目标

将 Decoder capture 从 1 byte/cycle 提升到 8 bytes/cycle：

```
修改前: AXI(512b) → [512→8]  → byte_skip(8b)  → Decoder(8-bit,  1B/cyc capture)
修改后: AXI(512b) → [512→64] → byte_skip(64b) → Decoder(64-bit, 8B/cyc capture)
```

### 2.2 修改模块一览

| 文件 | 修改内容 |
|------|---------|
| `cmpct_block_decoder.v` | 输入端口 8→64 bit；capture FSM 8 bytes/cycle 并行写入 8-bank BRAM；tail_accum 多字节移位；s_axis_tready 适配 partial final beat |
| `byte_skip_adapter_w64.v` | **新建** — 64-bit 宽 byte skip adapter，组合 barrel shifter，支持 0-63 bytes skip 及 partial 首拍输出 |
| `cmpct_source_pipe.v` | `stream_width_adapter` 输出从 8-bit 改为 64-bit；`byte_skip_adapter` 替换为 `byte_skip_adapter_w64` |

### 2.3 cmpct_block_decoder.v 关键变更

#### 端口拓宽

```verilog
// 修改前
input wire [7:0]  s_axis_tdata,
input wire [0:0]  s_axis_tkeep,

// 修改后
input wire [63:0] s_axis_tdata,
input wire [7:0]  s_axis_tkeep,
```

#### 8 bytes/cycle 并行 BRAM 写入

核心思想：以 `cap_wptr[2:0]`（capture 写指针低 3 位）为 offset，将输入的 8 个字节**旋转映射**到 8 个 BRAM bank。每个 bank 独立计算 write enable、address 和 data：

```verilog
wire [2:0] cap_offset = cap_wptr[2:0];

genvar gwi;
generate
    for (gwi = 0; gwi < 8; gwi = gwi + 1) begin : gen_bank_we
        // byte_pos: 输入数据中第几个 byte 映射到 bank gwi
        wire [2:0] byte_pos = (gwi[2:0] - cap_offset) & 3'b111;
        assign bank_we[gwi]    = bram_we_comb && s_axis_tkeep[byte_pos];
        assign bank_wdata[gwi] = s_axis_tdata[byte_pos*8 +: 8];
        assign bank_waddr[gwi] = cap_wptr[BLOCK_AW-1:3] +
                                 ((gwi[2:0] < cap_offset) ? 1 : 0);
    end
endgenerate
```

**特点**：纯组合旋转逻辑，不引入深层 MUX 链，每个 bank 的写路径完全独立，对时序友好。

#### tail_accum 多字节更新

原先每 cycle 移入 1 byte，改为按 `s_axis_byte_count`（1-8）一次性移入多个 byte，用 case 语句选择 shift 量：

```verilog
case (s_axis_byte_count)
    4'd1: tail_accum <= {s_axis_tdata[7:0],   tail_accum[31:8]};
    4'd2: tail_accum <= {s_axis_tdata[15:0],  tail_accum[31:16]};
    ...
    4'd8: tail_accum <= {s_axis_tdata[31:0]};  // 完全覆盖
endcase
```

### 2.4 byte_skip_adapter_w64 设计

新模块，核心功能：丢弃 AXI beat 内的前 N 个字节（align offset），输出剩余有效字节。

- **状态机**：`skipping` / passthrough 两态
- **Skip 逻辑**：每拍可 skip 0-8 bytes，多拍累积完成 0-63 bytes skip
- **Barrel shifter**：组合逻辑 byte-level 右移 + 截断 tkeep
- **AXI-Stream 合规**：skip 整拍时 `s_axis_tready=1`（直接消费），partial 拍时依赖 `m_axis_tready`

#### 修复的关键 bug

初版中 `bytes_to_skip` 的比较：

```verilog
// BUG: in_byte_count[2:0] 将 8 (4'b1000) 截断为 0，导致 skip_remain>=0 恒真
wire [3:0] bytes_to_skip = (skip_remain >= {1'b0, in_byte_count[2:0]}) ? ...

// 修复后: 使用完整 4-bit in_byte_count
wire [3:0] bytes_to_skip = (skip_remain >= {{(SKIP_WIDTH-4){1'b0}}, in_byte_count}) ? ...
```

此 bug 导致当 `in_byte_count=8`（全 8 字节有效）时，skip adapter 错误地跳过整个 beat，使后续 block 数据偏移 1 字节。仅在 `align_offset > 0` 的 block 上触发。

### 2.5 cmpct_source_pipe.v 变更

```verilog
// 修改前: 512→8 宽度转换 + 8-bit skip
stream_width_adapter #(.OUT_DATA_WIDTH(8),  .OUT_KEEP_WIDTH(1))
byte_skip_adapter    #(.SKIP_WIDTH(6))

// 修改后: 512→64 宽度转换 + 64-bit skip
stream_width_adapter #(.OUT_DATA_WIDTH(64), .OUT_KEEP_WIDTH(8))
byte_skip_adapter_w64 #(.SKIP_WIDTH(6))
```

---

## 3. AXI Read Engine 竞态条件修复

### 3.1 问题发现

P9 实现后，GB 级压力测试中出现 **~0.5% 偶发错误**（5000 次中约 25 次失败）。

诊断数据一致指向：
- 错误始终在 **decoder/source_pipe** 中触发
- **两个 source (src0, src1) 总是在同一 pair 上同时失败**
- 失败发生在**不同的 pair 编号**（113, 177 等），非数据依赖

### 3.2 根因分析

**`axi_read_engine`（`cmpct_infra.v`）在 `clear` + `start` 后未正确隔离残余 AXI R-data。**

时序场景：

```
Cycle N:   front_clear → busy=0, waiting_for_r=0, out_valid=0
Cycle N+1: front_start → busy=1, 开始新 AXI 读地址阶段
Cycle N+2~N+k: DDR refresh 延迟，旧 burst 残余 R-data 到达
```

在 cycle N+2 时：
- `busy = 1`（新 block 已 start）
- `waiting_for_r = 0`（新 AR 还没发出/接受）
- **但** `m_axi_rvalid = 1`（旧 burst 的残余数据）

原代码中 R-data 接受条件仅检查 `busy`：

```verilog
// BUG: 没有 waiting_for_r 门控，旧数据被当作新 block 数据处理
if (m_axi_rvalid && can_take_r) begin
    out_data  <= m_axi_rdata;   // 写入旧数据！
    out_valid <= 1'b1;          // 下游看到错误数据
```

旧数据流入 width adapter → skip adapter → decoder → **decoder 解析出错误的 varint → error**。

### 3.3 修复

一行修复——增加 `waiting_for_r` 门控：

```verilog
// 修复后: 仅在确认发出 AR 并收到 arready 后才处理 R-data
if (waiting_for_r && m_axi_rvalid && can_take_r) begin
```

**安全性分析**：
- `m_axi_rready` 仍为 `(!out_valid) || m_axis_tready`，始终保持 ready
- 残余 R-data 被 AXI 接口正常消费（rready=1），但不写入 `out_data`/`out_valid`
- `waiting_for_r` 在正常操作中始终在 AR 被接受后置 1，数据到达前已就绪，不影响正常流程

### 3.4 为什么之前没触发？

此 bug 自 axi_read_engine 创建以来就存在，但之前 **1 byte/cycle 的 decoder 很慢**：
- 1B/cycle capture 保证 decoder 完成时，DDR 早已无残余 burst 在途
- P9 的 8B/cycle capture 使 decoder **提前完成**，`clear` 在 DDR 仍有 in-flight 数据时就发出
- DDR refresh（~300ns = 60 cycles）的时序抖动使残余数据偶尔在新 start 之后到达

---

## 4. 仿真验证

全部 **5 项**集成仿真测试通过：

| 测试 | 结果 |
|------|------|
| `run_sim_sstable_engine_axil.sh` | ✅ PASS |
| `run_sim_sstable_engine_axil_1blk.sh` | ✅ PASS |
| `run_sim_sstable_engine_stress.sh` | ✅ PASS (3 rounds) |
| `run_sim_sstable_engine_split.sh` | ✅ PASS (2 phases) |
| `run_sim_sstable_asym.sh` | ✅ PASS |

仿真 cycle 对比（stress test, 16 pairs）：

| 版本 | perf_cycle_count | 变化 |
|------|:---:|:---:|
| P7+P8 基线 | 4,997 | — |
| P9 | 3,055 | **-38.9%** |

---

## 5. 硬件测试结果

### 5.1 测试环境

- **FPGA 时钟**：200 MHz
- **测试数据**：200 block pairs, 505,278 bytes/run (2 × ~252 KB SSTable)
- **诊断测试**：5,000 次连续运行
- **吞吐测试**：2,126 次运行 (1,024 MB)

### 5.2 修复前（有竞态 bug）

| 指标 | 结果 |
|------|------|
| 5,000 次诊断 | 5 fail (0.5%) |
| 失败模式 | decoder error, 总是在 pair 边界 |
| 1,063 次吞吐测试 | 1 fail |

### 5.3 修复后（最终版本）

| 指标 | P7+P8 基线 | **P9 最终** | 变化 |
|------|:---:|:---:|:---:|
| HW throughput (avg) | 254.7 MB/s | **507.4 MB/s** | **+99%** |
| HW throughput (best) | 255.4 MB/s | **510.9 MB/s** | **+100%** |
| HW throughput (worst) | — | **504.6 MB/s** | — |
| Bytes/cycle (avg) | 1.335 | **2.660** | **+99%** |
| Bytes/cycle (best) | — | **2.679** | — |
| Avg cycles/run | 378,427 | **189,945** | **-50%** |
| Min cycles/run | 377,337 | **188,638** | — |
| Max cycles/run | 380,199 | **190,987** | — |
| 错误率 (5K diag) | 0% | **0%** | ✅ |
| 错误率 (1 GB bench) | 0% | **0%** | ✅ |

**总计 7,126 次连续运行零错误。**

---

## 6. 完整优化历程

```
版本          时钟     吞吐 (avg)    Bytes/cycle    Cycles/run
──────────    ──────   ──────────    ───────────    ──────────
原始基线      300 MHz   125 MB/s       0.51          —
P4+P5         300 MHz   153 MB/s       0.51         630,825
P4+P5 降频    250 MHz   190 MB/s       0.80         632,864
P3+P6         200 MHz   191 MB/s       0.80         630,851
P7+P8         200 MHz   255 MB/s       1.34         378,427
P9 ★         200 MHz   507 MB/s       2.66         189,945
```

从最初的 125 MB/s 到现在的 **507 MB/s**，**4.06× 提升**。

---

## 7. 当前流水线瓶颈分析

### 7.1 Per-pair Cycle 预算

```
输入数据:     505,278 bytes / 200 pairs = 2,526 bytes/pair
实测 cycles:  189,945 / 200 = 950 cycles/pair
理论极限 (8B/cycle 全通路): 2,526 / 8 = 316 cycles/pair
效率: 316 / 950 = 33.3%
```

P9 将效率从 16.7% 提升到 33.3%，但距理论极限仍有 **3× 差距**。剩余开销来自：

### 7.2 瓶颈 #1：Decoder 内部 FSM 串行解析（最大瓶颈）

Capture 阶段已被 P9 加速到 8B/cycle，但 **parse 阶段仍为 byte-serial**：

```
每条 record 解码流程:
  ST_CONSUME_SHARED     → varint decode (1-5 cycles)
  ST_CONSUME_UNSHARED   → varint decode (1-5 cycles)
  ST_CONSUME_VALUE_LEN  → varint decode (1-5 cycles)
  ST_EMIT_SHARED        → 从 prev_key BRAM 读 (N/8 cycles)
  ST_EMIT_UNSHARED      → 从 capture BRAM 读 (N/8 cycles)
  ST_EMIT_VALUE         → 从 capture BRAM 读 (N/8 cycles)
  各状态间的 FSM 跳转开销  → ~2-4 cycles/record
```

每条 record 约 20 个 key bytes + 8 byte sequence number + value → ~10 cycles emit + ~8 cycles varint + ~4 cycles FSM = **~22 cycles/record**。

200 blocks × 20 records/block = 4,000 records/source × 22 cycles ≈ **88,000 cycles/source**。这是当前最大 cycle 消费者。

### 7.3 瓶颈 #2：AXI 读引擎无 Outstanding Reads

`axi_read_engine` 采用严格串行 burst：每个 burst 完成后才发下一个 AR。DDR 延迟 ~100ns (20 cycles @200MHz) 在多 burst block 上完全串行化。

### 7.4 瓶颈 #3：Capture 与 Parse 不重叠

当前 Decoder 必须 capture 完整个 block 到 BRAM 后才开始 parse/emit。这两个阶段完全串行。

### 7.5 瓶颈 #4：Encoder 8-way prefix compare 依赖前一条 record

Encoder 在 emit 完一条 record 后才能开始下一条的 prefix comparison，record 间有 ~3-5 cycles 启动延迟。

---

## 8. 后续优化路线图

### 8.1 🔴 P10：AXI Outstanding Reads（预期 +10~15%）

**目标**：支持 2-4 outstanding read bursts，隐藏 DDR 延迟。

**修改点**：
- `axi_read_engine` 中解除 `waiting_for_r` 对 AR 发送的阻塞
- 新增 outstanding burst 计数器（max_outstanding 参数化）
- 输出端增加浅 FIFO 缓冲（防止背压 stall DDR controller）
- 需保证 burst 顺序和 RLAST 对齐

**实现难度**：中。核心改动在 read engine 内部，接口不变。

**预期收益**：每个 block ~4 bursts，当前每 burst 有 ~20 cycles DDR 延迟 gap，overlap 后节省 ~60 cycles/block × 200 blocks × 2 sources = ~24,000 cycles → **~12% 改善**。

---

### 8.2 🔴 P11：Decoder Capture/Parse 重叠（预期 +15~25%）

**目标**：Decoder 边 capture 边 parse/emit，不等待整个 block 到达。

**当前行为**：
```
时间线: [--- capture 全 block ---][--- parse+emit 全 block ---]
```

**优化后**：
```
时间线: [--- capture ---]
              [--- parse+emit (当足够数据到达时开始) ---]
```

**关键挑战**：
- 需要 read pointer / write pointer 的 hazard 检测（parse 不能超过 capture 进度）
- Capture 完成前无法计算 restart array 位置（需要 tail_accum），但 record parse 可以提前开始（从 block 头部顺序解析）
- 第一条 record 的 varint 数据一般在 capture 开始 1-2 cycles 内就到达 BRAM

**实现方案**：
- Capture 写指针 `cap_wptr` 已存在，parse 读指针 `parse_index` 也已存在
- 新增 "safe_to_parse" 信号：`parse_index + guard_margin < cap_wptr`
- Parse FSM 在 safe_to_parse 为假时 stall（等待更多数据到达）
- Restart count 在 cap_done 后才计算（不影响 record 解析，因为 restart array 在 block 末尾）

**预期收益**：capture 和 parse/emit 的较长者决定总时间，而非两者之和。对于典型 block (~1,263 bytes, ~20 records)：capture ~160 cycles, parse ~440 cycles → 总 cycle 从 ~600 降到 ~440，**~27% 改善**。

---

### 8.3 🟠 P12：Multi-byte Varint 解码（预期 +5~10%）

**目标**：单周期解码完整 varint（最多 5 bytes），消除 varint 解码的逐字节循环。

**当前行为**：每个 varint 需要 1-5 cycles（每 cycle 读 1 byte，检查 MSB continuation bit）。

**优化方案**：
- 从 BRAM 一次读出 5 bytes（跨 bank 读取）
- 组合逻辑 priority encoder 找到第一个 MSB=0 的字节
- 单周期计算 varint value 和长度
- parse_index 一次前进 1-5 positions

**实现难度**：中。需要 5-byte 跨 bank BRAM 读取逻辑（5 个并行 bank 读端口，barrel rotate）。

---

### 8.4 🟠 P13：时钟频率 200 → 250 MHz（预期 +25%）

**目标**：提升时钟频率获得线性吞吐提升。

**关键路径分析**：
- `crc32c_8byte_streamer`：8 级 CRC 级联 (~40 LUT levels)，可能需要 2-stage pipeline
- Encoder 8-way prefix compare：~3 LUT levels，应该无问题
- Decoder bank_we 旋转逻辑：纯组合，浅
- SmartConnect CDC：250→300 MHz 仍需 CDC，但比 200→300 更接近

**方法**：Vivado timing 分析 → 在 CRC 路径插入 pipeline → retiming。如果 CRC 需要 2 cycles，可能需要在 trailer appender 中增加 pipeline stage。

---

### 8.5 🟡 P14：Record Emit 阶段加速

**目标**：减少 emit 阶段的 per-record FSM 启动开销。

**当前问题**：每条 record 在 `ST_EMIT_SHARED` → `ST_EMIT_UNSHARED` → `ST_EMIT_VALUE` 之间各有 1 cycle 空转（状态转换）。

**优化**：合并 emit 状态，用 counter 统一管理 shared/unshared/value 三段 emit，消除状态间的空 cycle。

---

### 8.6 综合路线图

```
                P9 (当前)        +P10+P11         +P12+P13          +P14
                ──────────       ─────────        ─────────         ─────
HW Throughput:  507 MB/s    →   ~650 MB/s    →   ~850 MB/s    →   ~900+ MB/s
Bytes/cycle:    2.66        →    ~3.4        →    ~3.4        →    ~3.6
Clock:          200 MHz          200 MHz          250 MHz           250 MHz
主要瓶颈:     Parse串行     Capture-Parse串行   Fmax+varint     Per-record FSM
```

**最大收益的两项**：
1. **P11 (Capture/Parse 重叠)** — 预期 +15~25%，从根本上改变 Decoder 的串行两阶段模型
2. **P13 (250 MHz)** — 预期 +25%，线性提升，但需解决 CRC 时序

两者叠加可望达到 **~850 MB/s**，接近 DDR4 单通道有效带宽的上限。

---

## 9. 完整文件变更清单

```
新建:
  rtl_v2/byte_skip_adapter_w64.v          — P9: 64-bit 宽 byte skip adapter

修改:
  rtl_v2/cmpct_block_decoder.v            — P9: 64-bit 输入, 8B/cycle capture, 多字节 tail_accum
  rtl_v2/cmpct_source_pipe.v              — P9: 512→64 width adapter + w64 skip adapter
  rtl_v2/cmpct_infra.v                    — P9: axi_read_engine waiting_for_r 竞态修复

仿真脚本 (添加 byte_skip_adapter_w64.v):
  sim/integration/run_sim_sstable_engine_axil.sh
  sim/integration/run_sim_sstable_engine_axil_1blk.sh
  sim/integration/run_sim_sstable_engine_stress.sh
  sim/integration/run_sim_sstable_engine_split.sh
  sim/integration/run_sim_sstable_asym.sh

测试脚本:
  test/test_p9_diag.sh                    — P9 偶发错误诊断脚本 (5000 次连续运行)
```

---

*最后更新: 2025-05-16*
