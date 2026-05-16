# RTL Compaction Pipeline — 最小侵入·高收益优化路线图

## 0. 当前活跃数据通路

```
Source0 DDR ─→ axi_read_engine ─→ stream_width_adapter(512→8) ─→ byte_skip ─→ block_decoder ─┐
                                                                                                 ├─→ merger ─→ block_encoder ─→ trailer_appender ─→ stream_pack(8→512) ─→ axi_write_engine ─→ DST DDR
Source1 DDR ─→ axi_read_engine ─→ stream_width_adapter(512→8) ─→ byte_skip ─→ block_decoder ─┘
```

**已确认**：`real_internal_key_two_way_merge_stage5_chain_top` 采用 Opt-A 直连——
merger 的 record-stream 直接喂入 encoder，**不经过 MID DDR 回程**。
因此瓶颈全部集中在上述单遍流水线内部。

### 每个模块的当前 cycle 成本估算（典型 entry: 16B user_key + 100B value）

| 模块 | 阶段 | 每 entry cycle | 根因 |
|------|------|---------------|------|
| **block_decoder** | varint parse | 6–12 | 每 varint byte 需 2 cycle（FETCH+CONSUME） |
| **block_decoder** | key copy | ~8 | `ST_COPY_KEY` 逐 byte |
| **block_decoder** | value emit | **~200** | `ST_PREP_EMIT_VALUE` + `ST_EMIT_VALUE_BYTES` = 2 cycle/byte |
| **block_decoder** | key emit | 16 | 已 1 cycle/byte，OK |
| **merger** | capture | 124 | 逐 byte 写 record_mem (1 cycle/byte) |
| **merger** | compare | 16 | 逐 byte 比较 (1 cycle/byte) |
| **merger** | dup check | 16 | 逐 byte 比较 prev_key (1 cycle/byte) |
| **merger** | emit | 124 | 逐 byte 读 record_mem (1 cycle/byte) |
| **encoder** | encode pass | ~4000/block | entries → block_mem |
| **encoder** | output pass | ~4000/block | block_mem → m_axis (第二遍扫描) |

**结论**：decoder 的 value 发射（2 cycle/byte）是 **per-byte 最大浪费**。
encoder 的二次扫描是 **per-block 最大浪费**。

---

## Tier-1：最高 ROI、最低风险

### OPT-1A  block_decoder value 发射流水化 (2→1 cycle/byte)

**目标文件**：`cmpct_block_decoder.v`

**问题**：当前 value byte 发射需要两个状态：
```
ST_PREP_EMIT_VALUE:  fetched_byte <= block_mem[value_base_index + emit_index];  // 1 cycle: BRAM 读
                     state <= ST_EMIT_VALUE_BYTES;
ST_EMIT_VALUE_BYTES: if (output_accept) { emit_index++; state <= ST_PREP_EMIT_VALUE; }  // 1 cycle: 输出
```
每个 value byte 至少 2 cycle。对 100B value，浪费 100 cycle/entry。

**修复方案**：添加 1 级预取寄存器，在输出当前 byte 的同时预读下一个 byte。

```verilog
// 新增寄存器
reg        value_prefetched;
reg [7:0]  value_next_byte;

// ST_PREP_EMIT_VALUE: 首次预取，1 cycle 启动开销（仅一次）
ST_PREP_EMIT_VALUE: begin
    value_next_byte  <= block_mem[value_base_index + emit_index];
    value_prefetched <= 1'b1;
    state            <= ST_EMIT_VALUE_BYTES;
end

// ST_EMIT_VALUE_BYTES: 输出 + 同步预取下一 byte
ST_EMIT_VALUE_BYTES: begin
    if (output_accept) begin
        if (emit_index + 32'd1 < value_len) begin
            emit_index       <= emit_index + 32'd1;
            // 关键：本 cycle 同时从 block_mem 预读下一 byte
            value_next_byte  <= block_mem[value_base_index + emit_index + 32'd1];
        end else begin
            state <= ST_FETCH_SHARED;  // done
        end
    end
end

// m_axis_tdata mux 中 value 分支改为读 value_next_byte
assign m_axis_tdata = ... (state == ST_EMIT_VALUE_BYTES) ? value_next_byte : ...;
```

**时序安全**：
- `block_mem` 声明了 `(* ram_style = "block" *)`，综合为 BRAM
- BRAM 读操作本身就是注册输出（1 cycle 延迟），预取方案不增加组合深度
- `value_base_index + emit_index + 1` 是简单加法，不增加关键路径

**预期收益**：value byte 占 block 数据量 50–80%，此优化使 decoder 吞吐提升 **~40–50%**。

**改动量**：~20 行

---

### OPT-1B  block_decoder varint 解析流水化 (2→1 cycle/varint byte)

**目标文件**：`cmpct_block_decoder.v`

**问题**：三组 varint 解析（shared/unshared/value_len）各有 FETCH + CONSUME 两状态：
```
ST_FETCH_SHARED:   fetched_byte <= block_mem[parse_index]; parse_index++; → ST_CONSUME_SHARED
ST_CONSUME_SHARED: 处理 varint byte; if (continuation) → ST_FETCH_SHARED
```
每 varint byte 2 cycle。

**修复方案**：合并 FETCH + CONSUME 为单级流水。在 CONSUME 状态中，如果还需要下一 byte，
同时从 block_mem 预读 `parse_index`（已在上一 cycle 自增）。

```verilog
// 在 ST_CONSUME_SHARED 分支中:
if (fetched_byte[7]) begin
    // continuation — 预取下一 byte 与 varint 累加并行
    varint_accum <= varint_accum | ({25'd0, fetched_byte[6:0]} << varint_shift);
    varint_shift <= varint_shift + 6'd7;
    varint_bytes <= varint_bytes + 3'd1;
    fetched_byte <= block_mem[parse_index];   // parse_index 已在 FETCH 中自增
    parse_index  <= parse_index + 32'd1;
    // 不切回 ST_FETCH_SHARED，直接留在 ST_CONSUME_SHARED
    state <= ST_CONSUME_SHARED;
end else begin
    // 终止 byte — 完成 varint
    ...
end
```

同理对 ST_CONSUME_UNSHARED、ST_CONSUME_VALUE_LEN 做相同处理。
FETCH 状态仅用于首次进入时的启动预取（1 cycle 启动开销，之后管道满了就不用了）。

**时序安全**：
- block_mem 是 BRAM，注册读
- varint 累加逻辑 `(accum | (byte[6:0] << shift))` 是最宽 28 位移位+OR，
  综合为 ~3 级 LUT，对 200MHz FPGA 完全可以收敛
- parse_index 自增是简单 +1

**预期收益**：每 entry 3 个 varint，平均各 1–2 byte → 节省 3–6 cycle/entry。

**改动量**：~30 行（三组 CONSUME 状态各改一次）

---

### OPT-1C  block_decoder key 拷贝与发射重叠

**目标文件**：`cmpct_block_decoder.v`

**问题**：`ST_COPY_KEY` 逐 byte 从 block_mem 拷贝 unshared suffix 到 curr_key_mem，
拷贝完成后才进入 `ST_EMIT_ENTRY` 开始发射。拷贝和发射完全串行。

**修复方案**：在 `ST_EMIT_KEY_BYTES` 发射 key 的同时，用 curr_key_mem 的写端口
把正在发射的 byte 同步拷贝到 prev_key_mem。这样可以省掉 `ST_EMIT_ENTRY` 中
对 prev_key_mem 的大规模并行拷贝。

具体做法：
1. `ST_COPY_KEY` 保持不变（功能上仍需要把 unshared key 拷贝到 curr_key_mem，
   因为 emit 从 curr_key_mem 读）
2. 但在 `ST_EMIT_KEY_BYTES` 中，同步做 `prev_key_mem[emit_index] <= curr_key_mem[emit_index]`
3. `ST_EMIT_ENTRY` 中去掉 `for (i=0;i<MAX_KEY_BYTES;i=i+1) prev_key_mem[i] <= curr_key_mem[i]`
   这个大并行拷贝——此拷贝是 Fmax 杀手（MAX_KEY_BYTES=256 个写使能同时 fan-out）

**时序安全**：
- 消除了 ST_EMIT_ENTRY 中 256 路并行写，**改善** Fmax
- 逐 byte 拷贝不增加任何组合深度

**预期收益**：
- 直接 cycle 节省：不大（~1 cycle transition）
- **间接收益**：消除 256 路 prev_key_mem 并行写的 fan-out，**改善 timing closure**
- 这是一个"不提速但防 Fmax 下降"的关键改动

**改动量**：~15 行

---

## Tier-2：高 ROI、中等复杂度

### OPT-2A  merger 多字节 key 比较 (1→4 byte/cycle)

**目标文件**：`cmpct_two_way_merger.v`

**问题**：`ST_COMPARE_INPUTS` 和 `ST_CHECK_KEEP` 都逐 byte 比较 user key。
16B key → 16 cycle 比较 + 16 cycle 去重检查 = 32 cycle/record。

**修复方案**：每 cycle 比较 4 byte，使用寄存器缓冲避免组合深度过大。

**关键设计（时序安全版本）**：
```
                 ┌─────────────────────────────────────────┐
   Cycle N:      │ 从 key_mem 读 4 byte → cmp_reg (注册)  │
                 └─────────────────────────────────────────┘
                 ┌─────────────────────────────────────────┐
   Cycle N+1:    │ 比较 4 byte (纯组合, 浅)  → 判定       │
                 └─────────────────────────────────────────┘
```

两拍流水：读 + 比较。每 2 cycle 处理 4 byte = 2 byte/cycle，相比当前 1 byte/cycle 提升 2x。

如果进一步想要 4 byte/cycle，可以用 True-Dual-Port 寄存器阵列，
但 user_key_mem 是 reg array，4 路并行读在综合时已经是 MUX forest，
对 256B key 来说，4 路 MUX 可能导致 timing 收紧。
因此建议 **保守方案 = 2 byte/cycle (读+比较 2 拍流水)**，
或者把 user_key_mem 换成 BRAM（True-Dual-Port，一个 read port 给 source0，一个给 source1），
但这改动更大。

**保守实现**：
```verilog
// 新增寄存器
reg [31:0] cmp_word0, cmp_word1;  // 4-byte comparison windows
reg        cmp_loaded;

ST_COMPARE_INPUTS: begin
    if (!cmp_loaded) begin
        // Cycle 1: load 4 bytes from each key (combinational MUX from reg array)
        cmp_word0 <= {user_key_mem0[compare_index+3],
                      user_key_mem0[compare_index+2],
                      user_key_mem0[compare_index+1],
                      user_key_mem0[compare_index]};
        cmp_word1 <= {user_key_mem1[compare_index+3],
                      user_key_mem1[compare_index+2],
                      user_key_mem1[compare_index+1],
                      user_key_mem1[compare_index]};
        cmp_loaded <= 1'b1;
    end else begin
        // Cycle 2: compare (registered operands, shallow combinational)
        cmp_loaded <= 1'b0;
        if (cmp_word0 != cmp_word1) begin
            // 找第一个不同 byte (priority logic, 4-entry, 2 LUT levels)
            ...
        end else begin
            compare_index <= compare_index + 16'd4;
        end
    end
end
```

**时序安全**：
- 4 路 MUX 从 reg array 读：综合为 4 个独立 MUX，每个 MAX_USER_KEY_BYTES deep
  - 但这些 MUX 的选择信号 (compare_index) 是寄存器输出
  - 输出注册到 cmp_word0/1
  - 所以 MUX 深度 = 从 compare_index 到 cmp_word0 的组合路径 = ~8 级 LUT（256:1 MUX）
  - 这可能较深！如果 MAX_USER_KEY_BYTES=256，则 MUX 8:1 x 3 级 = 24 级
  - **缓解方案**：如果 MAX_USER_KEY_BYTES <= 64，4 路读完全安全
  - 如果 MAX_USER_KEY_BYTES > 64，建议将 user_key_mem 改为 BRAM (True-DP)，
    每 cycle 读 1 地址（返回 1 byte），但连续读 4 地址需要 4 cycle →
    不如保持 reg array 但只比较 2 byte/cycle 以限制 MUX 深度

**推荐**：
- 如果 MAX_USER_KEY_BYTES ≤ 64 → 直接 4B/cycle
- 如果 MAX_USER_KEY_BYTES > 64 → 先做 2B/cycle，或把 key_mem 分 bank

**预期收益**：compare + dup check 从 ~32 cycle → ~8–16 cycle/record。

**改动量**：~60 行

---

### OPT-2B  merger 发射与预取重叠

**目标文件**：`cmpct_two_way_merger.v`

**问题**：`ST_EMIT_PAYLOAD` 把选中的 record 逐 byte 发射完后，
才清 `buf_validX` 并回 `ST_FETCH`，然后才开始接收该源的下一条 record。

**修复方案**：把 `ST_FETCH` 的调度逻辑合并到 `ST_EMIT_PAYLOAD` 的最后一拍，
利用 `buf_valid` 清除后的下一 cycle 直接进入 `ST_WAIT0_HEADER` / `ST_WAIT1_HEADER`，
节省 1 cycle/record 的 FETCH 跳转开销。

更激进的方案：在 emit 尾部的几个 cycle，提前 assert 对应 sourceX 的 ready，
让上游 decoder 在 emit 最后一拍就可以推送 next record header。
但这需要仔细处理 ready 信号的 validity window。

**保守推荐**：仅省 `ST_FETCH` 的 1 cycle 跳转。安全、改动小。

**时序安全**：不增加任何组合路径。

**预期收益**：~1 cycle/record，在 record 数量多时累积可观。

**改动量**：~10 行

---

### OPT-2C  block_encoder 流式输出（消除二次扫描）

**目标文件**：`cmpct_block_encoder.v`

**问题**：encoder 先把所有 entry 写入 block_mem，再从 block_mem 整块读出。
对 4KB block 浪费 ~4000 cycle（第二遍扫描）。

**修复方案（分两步实施）**：

**Phase 1（低风险）**：让 encoder 边编码边输出 entry data，仅缓冲 restart offsets。
- varint header bytes → 直接推到输出
- unshared key bytes → 直接从 key buffer 推到输出
- value bytes → 直接从输入 s_axis 透传到输出（不经过 block_mem）
- restart_offset_mem → 照旧记录
- 所有 entry 完成后，从 restart_offset_mem 输出 restart array + count

**关键难点**：`axi_write_engine` 需要 `byte_count` 在 start 时已知，
但流式输出时 block 总大小直到 restart array append 完才确定。

**解决**：
- 方案 A：让 write engine 支持 `tlast` 终止（需改 write engine，见 OPT-3A）
- 方案 B：在 encoder 和 write engine 之间插一个小 FIFO，让 write engine 等到
  encoder done 后再 start（此时 output_block_bytes 已确定）。
  FIFO 深度只需 ≥ AXI burst 深度 × 64B = 1KB 级别。

**推荐方案 B**：
```
encoder → [小 FIFO, 1–2KB] → trail_appender → pack → write_engine
                                                           ↑
                                              encoder.done 时 start，byte_count 已知
```

这样 encoder 输出到 FIFO 的速度不受 write_engine start 延迟影响。

**时序安全**：
- 流式输出不增加任何组合深度
- 小 FIFO 是标准 BRAM FIFO，时序优秀
- 去掉 block_mem 二次读扫描，**减少** BRAM 端口压力

**预期收益**：消除 ~4000 cycle/block 的二次扫描 → encoder 部分吞吐 **提升 ~2x**。

**改动量**：~100 行（encoder 核心重构 + FIFO 插入）

**风险**：中等。需要修改 encoder 核心状态机，建议用新模块文件，保留旧 encoder 可回退。

---

## Tier-3：显著收益、较高复杂度

### OPT-3A  axi_write_engine burst pipeline

**目标文件**：`cmpct_infra.v :: axi_write_engine`

**问题**：当前 AW → W → B 严格串行，每个 burst 都等 B response。

**修复方案**：允许 AW/W 与 B 重叠。

```
当前: AW₁ → W₁ → B₁ → AW₂ → W₂ → B₂ → ...
优化: AW₁ → W₁ → AW₂ → W₂ → B₁ → AW₃ → W₃ → B₂ → ...
```

实现要点：
- 维护 `b_pending_count` 计数器（最多 2–4 个 outstanding B）
- `ST_W` 完成后，如果 `b_pending_count < MAX_OUTSTANDING`，直接去 `ST_AW` 发下一个 burst
- 在所有状态中持续 accept `bvalid`（不只在 ST_B）
- 全部 beats 写完且所有 B 都收回后，才 assert `done`

```verilog
// 新增
reg [2:0] b_pending_count;
localparam MAX_OUTSTANDING_B = 3'd4;

// 持续处理 B response（不限于 ST_B）
always @(posedge clk) begin
    ...
    if (m_axi_bvalid && m_axi_bready) begin
        b_pending_count <= b_pending_count - 3'd1;
        if (m_axi_bresp != 2'b00) error <= 1'b1;
    end
    ...
end

assign m_axi_bready = busy && (b_pending_count != 3'd0);

// ST_W 完成后的跳转
if (m_axi_wlast && w_handshake) begin
    b_pending_count <= b_pending_count + 3'd1;
    if (beats_remaining == 32'd0) begin
        // 等所有 B 回来
        state <= ST_DRAIN_B;
    end else if (b_pending_count + 3'd1 < MAX_OUTSTANDING_B) begin
        state <= ST_AW;  // 马上发下一个 burst
    end else begin
        state <= ST_WAIT_B;  // 等一个 B 再继续
    end
end
```

**时序安全**：
- `b_pending_count` 加减是 3-bit 计数器
- `m_axi_bready` 只取决于寄存器值，无组合链
- 不影响 W 数据路径

**预期收益**：
- 在 8-bit 主链路下，DDR 写不太容易成为瓶颈
- 但如果后续加宽内部通路或配合 OPT-2C（流式 encoder），burst pipeline 会显著减少写等待
- 单独收益：~10–20% write throughput 提升

**改动量**：~40 行

---

### OPT-3B  axi_read_engine 多 outstanding read

**目标文件**：`cmpct_infra.v :: axi_read_engine`

**问题**：每次只发一个 AR，等当前 burst 全回完才发下一个。

**修复方案**：允许 2–4 个 outstanding AR。

实现要点：
- 维护 `ar_issued_count` 和 `r_complete_count`
- 只要 `ar_issued - r_complete < MAX_OUTSTANDING`，持续发 AR
- R 数据通过 AXI-Stream skid buffer 推到下游（确保 rready 可以 assert）

```verilog
// ST_BUSY 状态中:
// AR 发射（持续发，不等 R）
if (!m_axi_arvalid && (beats_to_issue > 0) &&
    (ar_outstanding < MAX_OUTSTANDING_AR)) begin
    m_axi_araddr  <= next_ar_addr;
    m_axi_arlen   <= next_burst_len - 8'd1;
    m_axi_arvalid <= 1'b1;
end
if (m_axi_arvalid && m_axi_arready) begin
    m_axi_arvalid  <= 1'b0;
    ar_outstanding  <= ar_outstanding + 1;
    beats_to_issue  <= beats_to_issue - next_burst_len;
    next_ar_addr    <= next_ar_addr + (next_burst_len << AXI_BEAT_SHIFT);
end

// R 接收（持续收）
if (m_axi_rvalid && can_take_r) begin
    ...
    if (m_axi_rlast) ar_outstanding <= ar_outstanding - 1;
end
```

**时序安全**：
- `ar_outstanding` 是 2-3 bit 计数器
- AR 和 R 通路完全解耦，不增加数据路径组合深度

**预期收益**：减少 burst 间空闲周期，DDR 带宽利用率提升 ~30–50%。
在当前 512→8 解串后被 8-bit 限速的场景下，收益不会立即体现，
但一旦下游消费速度加快（得益于 Tier-1/2 优化），读带宽会成为下一瓶颈。

**改动量**：~30 行

---

### OPT-3C  nblock 级 block-pair 预取

**目标文件**：`cmpct_nblock_engine.v` + `cmpct_source_pipe.v`

**问题**：nblock engine 严格串行处理 block pair：
`ST_START → ST_WAIT(done) → 更新统计 → ST_CLEAR → ST_START → ...`
每对 block pair 之间有 2–3 cycle 间隔 + inner chain clear/start 延迟。

**修复方案（保守版）**：
在 `ST_WAIT` 检测到 inner_done 后，**立即** 启动下一对 source 的 AXI 读预取，
不等 clear/start 完成。

需要把 source_emit 从 inner chain 中拆出来，变成独立的前端：
```
source_emit_0 ─┐                      ┌─ encoder → trailer → pack → write
                ├─ [FIFO] ─→ merger ─→ ┤
source_emit_1 ─┘                      └─ ...
```

其中 source_emit 可以用 ping-pong 双缓冲：
- 当前 pair 在解码/合并时，下一 pair 的 source read 已经在进行
- 解码结果进入 record FIFO
- merger 从 FIFO 消费

**但这是较大的架构改动**，不适合"最小侵入"。

**更保守的方案**：
仅优化 `ST_CLEAR → ST_START` 之间的 gap：
当前是 clear 1 cycle → start 1 cycle → inner chain 响应。
可以把 clear 和 start 合并为同一 cycle（clear=1 的下一 cycle 自动 start=1），
减少 1 cycle 间隔。这改动极小但收益也小。

**推荐**：此项延后到 Tier-1/2 完成后再评估是否值得。

---

## 性能计数器（推荐立即添加）

在做任何优化前，**先加 cycle counter**，用于量化每个瓶颈的实际占比。

### block_decoder 中添加：

```verilog
reg [31:0] perf_capture_cycles;     // ST_CAPTURE 总 cycle
reg [31:0] perf_parse_cycles;       // FETCH_SHARED ~ VALIDATE_ENTRY 总 cycle
reg [31:0] perf_copy_key_cycles;    // ST_COPY_KEY 总 cycle
reg [31:0] perf_emit_key_cycles;    // ST_EMIT_KEY_BYTES 总 cycle
reg [31:0] perf_emit_value_cycles;  // ST_PREP_EMIT_VALUE + ST_EMIT_VALUE_BYTES 总 cycle
reg [31:0] perf_total_cycles;       // busy 期间总 cycle
```

### merger 中添加：

```verilog
reg [31:0] perf_capture_cycles;     // ST_CAPTURE0/1 总 cycle
reg [31:0] perf_compare_cycles;     // ST_COMPARE_INPUTS 总 cycle
reg [31:0] perf_check_cycles;       // ST_CHECK_KEEP 总 cycle
reg [31:0] perf_emit_cycles;        // ST_EMIT_HEADER + ST_EMIT_PAYLOAD 总 cycle
reg [31:0] perf_total_cycles;
```

### encoder 中添加：

```verilog
reg [31:0] perf_encode_cycles;      // ST_WAIT_RECORD ~ ST_STREAM_VALUE 总 cycle
reg [31:0] perf_restart_cycles;     // ST_APPEND_RESTARTS + ST_APPEND_RST_CNT 总 cycle
reg [31:0] perf_output_cycles;      // ST_OUTPUT 总 cycle
reg [31:0] perf_total_cycles;
```

这些计数器通过 AXI-Lite 暴露（与现有 total_xxx 计数器相同路径），
可以在 board test 中直接读取，用来精确定位优化前后的瓶颈占比。

---

## 实施顺序推荐

```
Phase 0 (准备):  添加性能计数器 → 板上量化基线
                  ↓
Phase 1 (最快见效):  OPT-1A (decoder value 预取)
                     OPT-1B (decoder varint 流水)
                     OPT-1C (decoder key copy 去并行写)
                     ↓ 量化 → 确认收益
Phase 2 (高收益):    OPT-2A (merger 多字节比较)
                     OPT-2C (encoder 流式输出)
                     ↓ 量化 → 确认收益
Phase 3 (补短板):    OPT-3A (write engine pipeline)
                     OPT-3B (read engine multi-outstanding)
```

每个 Phase 完成后，重新读取性能计数器，确认瓶颈是否转移，再决定下一步优先级。

---

## Fmax 风险清单

| 改动 | Fmax 影响 | 说明 |
|------|----------|------|
| OPT-1A decoder value 预取 | ✅ 无负面 | BRAM 注册读，不增加组合深度 |
| OPT-1B decoder varint 流水 | ✅ 无负面 | 移位/OR 已注册 |
| OPT-1C decoder key copy | ✅ **改善** | 消除 256 路并行写 fan-out |
| OPT-2A merger 多字节比较 | ⚠️ 需注意 | 4 路 MUX from key_mem，MAX_KEY>64 时需分拍 |
| OPT-2B merger 预取 | ✅ 无负面 | 仅状态跳转优化 |
| OPT-2C encoder 流式 | ✅ 改善 | 去掉 block_mem 二次扫描，减少 BRAM port 竞争 |
| OPT-3A write pipeline | ✅ 无负面 | 只加小计数器 |
| OPT-3B read pipeline | ✅ 无负面 | 只加小计数器 |

**原则**：每个优化的新增逻辑都只用注册输出 / 浅组合 (≤3 LUT levels)，
不引入跨模块组合路径。所有大扇出操作（key copy、key compare）要么拆成多拍，
要么用注册中间结果。

---

## 未来考虑（不在本路线图范围内）

- **内部通路从 8-bit 提宽到 64-bit**：收益最大但改动最重，属于架构重构
- **多 block-pair 并行**：受 cross-block duplicate suppression 约束，
  只能并行化 source decode，merge 仍需顺序
- **CRC32c 并行化**：当前逐 byte CRC 不在关键路径上（trailer 只有 5 byte），优先级低
- **SSTable assembler 加速**：仅在 block 数很多/split 频繁时才显著

---

## 总结

本路线图 6 项核心优化的 **总改动量约 200–300 行 RTL**，不涉及模块接口变更（OPT-2C 除外），
不引入深组合逻辑，所有新增路径都通过注册中间值确保时序安全。

预期整体吞吐提升：**2–3x**（主要来自 decoder value 发射 + encoder 二次扫描消除）。
