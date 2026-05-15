# FPGA Compaction Engine — 优化进度记录

## 目标

| 阶段 | 目标吞吐 | 状态 |
|------|---------|------|
| 单链优化 | 170 MB/s | ✅ 已达成 190.4 MB/s |
| 最终目标 | 1 GB/s | 🔜 需要多链并行 / 数据通路加宽 |

---

## 基线

- **器件**: Xilinx VU37P (xcvu37p-fsvh2892-2L-e)
- **原始时钟**: DDR4 UI clock 300 MHz
- **原始单链吞吐**: ~125 MB/s
- **数据通路宽度**: 4 bytes/cycle (32-bit)
- **AXI 数据宽度**: 512-bit (DDR4 ↔ SmartConnect)
- **测试 fixture**: 2× 252 KB SSTable, 200 blocks, 4000 records/source, 8000 merged records

---

## 已完成优化

### P4: 比较器单周期有效 (OPT-C1b) — 2024.05.14

**文件**: `organized/rtl_v2/cmpct_merger.v`

**问题**: OPT-C1a 的 `cmp_pipe_valid` 寄存器每 2 cycle toggle 一次，导致 `ST_COMPARE_INPUTS` 和 `ST_CHECK_KEEP` 各多花 1 cycle。

**修改**: 将 `cmp_pipe_valid` 从 toggle 寄存器改为组合逻辑 wire：
```verilog
wire cmp_pipe_valid = (prev_state == state) &&
                      (state == ST_COMPARE_INPUTS || state == ST_CHECK_KEEP);
```
因为 `CMP_CHUNK == MAX_USER_KEY_BYTES`，比较始终在 1 次迭代内完成，只需"状态稳定 1 cycle"即可。

**效果**: 每条 record 节省 2 cycles（compare + check 各 1 cycle）。

**风险**: 低。纯组合逻辑简化，不增加时序路径深度。

---

### P5: MSI-X 中断输出 (OPT-IRQ) — 2024.05.14

**文件**: `organized/rtl_v2/cmpct_top.v`

**修改**: 
- 新增 `usr_irq_req` 输出端口（active-high 1-cycle pulse）
- 在 `done` 或 `error` 上升沿触发脉冲
- Reset 路径中初始化为 `1'b0`
- `cmpct_top_bd` wrapper 中暴露并连接该端口

**用途**: 连接到 XDMA 的 `usr_irq_req[0]`，支持 host 端中断驱动轮询替代忙等待。

---

### 降频 250 MHz — 2024.05.14

**文件**: 
- `organized/rtl_v2/cmpct_top.v` — `ui_aclk` FREQ_HZ 300M → 250M
- `run_downclk_250.tcl` — Block Diagram 时钟重连自动化脚本

**修改**:
- `cmpct_top_bd_0/ui_aclk` 从 `ddr4_0/c0_ddr4_ui_clk` (300 MHz) 切换到 `xdma_0/axi_aclk` (250 MHz)
- `cmpct_top_bd_0/ui_aresetn` 从 DDR4 reset 切换到 `xdma_0/axi_aresetn`
- `ila_0/clk` 同步切换到 250 MHz
- SmartConnect (NUM_CLKS=2) 自动处理 250→300 MHz CDC 到 DDR4

**时序结果**:

| 指标 | 300 MHz（旧） | 250 MHz（新） |
|------|-------------|-------------|
| WNS | -0.614 ns | **-0.010 ns** |
| TNS | -3,408 ns | -0.218 ns |
| WHS | +0.001 ns | 0.000 ns |

**关键发现**: 300 MHz 时 94% 的关键路径延迟来自布线（而非逻辑），降频后获得 0.668 ns 额外余量，时序从严重违规改善到几乎 met。

---

## 吞吐测试结果

### 测试环境
- **脚本**: `test/test_opt_perf_xdma.sh`
- **Fixture**: `fixtures_gb/` (200-block, 4000-record pair)
- **工具**: XDMA linux-kernel driver (`dma_to_device`, `dma_from_device`, `reg_rw`)

### P4 + P5 @ 300 MHz (2024.05.14)

| 指标 | 数值 |
|------|------|
| HW throughput (avg) | 152.8 MB/s |
| Avg HW cycles | 630,825 |
| Correctness | PASS |

### P4 + P5 + 降频 @ 250 MHz (2024.05.14)

| 指标 | 数值 |
|------|------|
| **HW throughput (avg)** | **190.4 MB/s** ✅ |
| HW throughput (best) | 190.6 MB/s |
| HW throughput (worst) | 190.1 MB/s |
| Bytes/cycle (avg) | 0.798 |
| Avg HW cycles | 632,864 |
| Correctness | PASS (1 GB / 2126 runs / 0 fail) |

**分析**: Cycle 数几乎不变 (630K→632K)，但 bytes/cycle 从 ~0.51 提升到 0.798。说明 300 MHz 时存在大量 SmartConnect CDC / AXI 跨时钟域 stall，切到同一 250 MHz 时钟域后 pipeline 效率大幅提升。

---

## 资源利用率 (250 MHz build)

| 资源 | 使用 | 总量 | 利用率 |
|------|------|------|--------|
| CLB LUTs | ~150K | 1,303,680 | ~11.6% |
| Registers | ~154K | 2,607,360 | ~5.9% |
| Block RAM | 115 | 2,016 | 5.7% |
| URAM | 0 | 960 | 0% |

---

## 待实施优化

### P3 + P6: 8-byte 数据通路加宽

**目标**: 将 decoder→merger→encoder 数据通路从 4B/cycle 加宽到 8B/cycle。

**受影响文件**:

| 文件 | 主要改动 |
|------|---------|
| `cmpct_block_decoder.v` | BRAM 4-bank→8-bank, emit 64-bit, tkeep 8-bit |
| `cmpct_merger.v` | 输入/输出 64-bit, emit_b0..b7, capture 8B/cycle |
| `cmpct_block_encoder.v` | 输入 64-bit, prefix compare 8-way, key_buf 8B/cycle |
| `cmpct_pair_chain.v` | FIFO DATA_WIDTH 37→73 |

**预期效果**: 250 MHz × ~1.2 B/cycle ≈ 300 MB/s

**风险**: 中。当前 WNS = -0.010 ns，加宽 MUX 可能增加 ~0.2 ns 逻辑延迟，需要注意 BRAM 地址计算和 encoder prefix compare 路径。

### 多链并行

**目标**: N chains × 190 MB/s → 1 GB/s (需 ~6 chains)

**依赖**: `cmpct_desc_dispatch.v` 调度器，多路 AXI interconnect

---

## 关键文件索引

| 文件 | 说明 |
|------|------|
| `organized/rtl_v2/cmpct_merger.v` | 合并引擎 (P4 已修改) |
| `organized/rtl_v2/cmpct_top.v` | 顶层模块 + BD wrapper (P5 + 降频已修改) |
| `organized/rtl_v2/cmpct_block_decoder.v` | 块解码器 |
| `organized/rtl_v2/cmpct_block_encoder.v` | 块编码器 |
| `organized/rtl_v2/cmpct_pair_chain.v` | 单链 pipeline 连接 |
| `organized/rtl_v2/cmpct_desc_dispatch.v` | 多链调度器 |
| `test/test_opt_perf_xdma.sh` | 板级性能测试脚本 |
| `/home/yh/pp4/run_downclk_250.tcl` | Vivado 降频 + 构建自动化 |
| `/home/yh/pp4/run_build_opt.tcl` | Vivado P4/P5 构建自动化 |

---

*最后更新: 2025.05.15*
