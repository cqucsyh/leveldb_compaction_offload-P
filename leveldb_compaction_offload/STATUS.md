# LevelDB Compaction FPGA Offload — 项目状态

*最后更新：2026-05-13*

---

## 一、整体目标

将 LevelDB 的 SSTable Compaction 核心计算流程卸载到 FPGA：读取两个 SSTable → 解析 footer/index → 逐对 block 解码 → 两路归并去重 → 重编码输出 data block → 组装完整 SSTable（含 index block、trailer、footer）→ 写回 DDR。主机通过 PCIe XDMA 上传源 SSTable、启动引擎、读回输出 SSTable。

---

## 二、硬件平台

| 项目 | 规格 |
|------|------|
| FPGA | Xilinx Virtex UltraScale+ **xcvu37p-fsvh2892-2L-e** |
| 开发板 | Inspur F37X |
| 引擎时钟 | **300 MHz** (mmcm_clkout0, period = 3.332 ns) |
| AXI 数据宽度 | 512 bit (64 bytes/beat) |
| DDR4 | 板载 DDR4，用于源/目标数据暂存 |
| 主机接口 | PCIe Gen3/4 x16 + Xilinx XDMA IP |
| EDA 工具 | Vivado 2025.1 |

---

## 三、RTL 架构

### 3.1 顶层流水线

```
  Host (PCIe XDMA)
       │ AXI-Lite regs + DMA H2C/C2H
       ▼
  ┌─ cmpct_top.v ─────────────────────────────────────────────────────┐
  │  AXI-Lite 寄存器译码 + CDC (axil_aclk ↔ ui_clk)                    │
  │       ▼                                                            │
  │  ┌─ cmpct_engine.v ──────────────────────────────────────────────┐ │
  │  │                                                                │ │
  │  │  SRC0 SSTable (DDR)             SRC1 SSTable (DDR)             │ │
  │  │       │                              │                         │ │
  │  │  [Parser p0]                    [Parser p1]                    │ │
  │  │  cmpct_sstable_parser_v2.v      cmpct_sstable_parser_v2.v     │ │
  │  │  解析 footer → index block       解析 footer → index block      │ │
  │  │  输出 block handle 流             输出 block handle 流           │ │
  │  │       │                              │                         │ │
  │  │       └──────────┬───────────────────┘                         │ │
  │  │                  ▼                                             │ │
  │  │         [Desc Matcher]                                         │ │
  │  │         cmpct_desc_matcher.v                                   │ │
  │  │         将两侧 handle 流 zip 成 descriptor 流                    │ │
  │  │                  ▼                                             │ │
  │  │         [N-Block Engine]                                       │ │
  │  │         cmpct_nblock_engine.v                                  │ │
  │  │         顺序调度每对 block pair                                  │ │
  │  │                  ▼                                             │ │
  │  │  ┌─ cmpct_pair_chain.v (单对 block 处理链) ─────────────────┐  │ │
  │  │  │                                                           │  │ │
  │  │  │  [Source Pipe 0]           [Source Pipe 1]                │  │ │
  │  │  │  AXI读 → align → skip     AXI读 → align → skip          │  │ │
  │  │  │  → block_decoder          → block_decoder                │  │ │
  │  │  │  → hdr FIFO + byte FIFO   → hdr FIFO + byte FIFO        │  │ │
  │  │  │       │    ┌──OPT-T4──┐        │                         │  │ │
  │  │  │       ▼    │ pipe reg │        ▼                         │  │ │
  │  │  │       └────┤          ├────────┘                         │  │ │
  │  │  │            └──────────┘                                  │  │ │
  │  │  │                  ▼                                        │  │ │
  │  │  │         [Two-Way Merger]                                 │  │ │
  │  │  │         cmpct_merger.v                                   │  │ │
  │  │  │         user_key ASC + seq DESC 归并                      │  │ │
  │  │  │         跨 block pair 去重                                │  │ │
  │  │  │                  ▼                                        │  │ │
  │  │  │         [Block Encoder]                                  │  │ │
  │  │  │         cmpct_block_encoder.v                            │  │ │
  │  │  │         32-bit 宽流式编码 → enc_out_fifo                  │  │ │
  │  │  │                  ▼                                        │  │ │
  │  │  │         [Block Trailer Appender]                         │  │ │
  │  │  │         追加 5 字节 trailer (type + CRC32c)               │  │ │
  │  │  │                  ▼                                        │  │ │
  │  │  │         [AXI Write Engine]                               │  │ │
  │  │  │         写入 DST DDR[i * stride]                         │  │ │
  │  │  └──────────────────────────────────────────────────────────┘  │ │
  │  │                  ▼                                             │ │
  │  │         [Assembler v2]                                         │ │
  │  │         cmpct_assembler_v2.v                                   │ │
  │  │         构建 index block + metaindex + footer                   │ │
  │  │         → 写入完整 SSTable 到 DDR                               │ │
  │  │                                                                │ │
  │  │  支持 auto-split：单次运行可输出多个 SSTable                     │ │
  │  └────────────────────────────────────────────────────────────────┘ │
  └────────────────────────────────────────────────────────────────────┘
```

### 3.2 模块清单

| 模块文件 | 功能 |
|----------|------|
| `cmpct_top.v` | 顶层：AXI-Lite 寄存器接口 + CDC + 引擎实例化 |
| `cmpct_engine.v` | 引擎核心：双 parser + desc_matcher + nblock + assembler |
| `cmpct_sstable_parser_v2.v` | 流式 SSTable 解析：读 footer → 解析 index block → 输出 block handle 流 |
| `cmpct_desc_matcher.v` | 将两侧 parser 的 handle 流 zip 成 (src0, src1, dst) descriptor 流 |
| `cmpct_nblock_engine.v` | N-block 顺序调度 FSM：加载 descriptor → 启动 pair_chain → 累计计数器 |
| `cmpct_pair_chain.v` | 单对 block 完整处理链：2× source_pipe + merger + encoder + writer |
| `cmpct_source_pipe.v` | 源数据管道：AXI read engine → stream width adapter → byte skip → block decoder |
| `cmpct_block_decoder.v` | LevelDB data block 解码：varint 解析 → 4-bank BRAM → 4B/cycle 记录流输出 |
| `cmpct_merger.v` | 两路归并器：4B/cycle chunk 比较 + 注册式 MUX + 跨 block 去重 |
| `cmpct_block_encoder.v` | 32-bit 宽流式编码器：shared/unshared/value varint + 数据 → byte 流 |
| `cmpct_assembler_v2.v` | SSTable 组装器：index block + metaindex + footer 构建 + AXI 写出 |
| `cmpct_infra.v` | 基础设施：AXI read/write engine, stream_fifo, stream_width_adapter, byte_skip_adapter |
| `cmpct_sdpram.v` | 简单双端口 RAM 模板（保证 BRAM 推断） |

### 3.3 AXI-Lite 寄存器映射 (cmpct_top.v)

| 偏移 | 名称 | 读写 | 说明 |
|------|------|------|------|
| 0x0000 | CTRL | W | [0]=start (self-clear), [1]=clear (self-clear) |
| 0x0004 | STATUS | R | [0]=busy, [1]=done, [2]=error |
| 0x0008/0C | SRC0_SSTABLE_BASE | W | SRC0 SSTable DDR 地址 [63:0] |
| 0x0010 | SRC0_SSTABLE_SIZE | W | SRC0 字节数 |
| 0x0014/18 | SRC1_SSTABLE_BASE | W | SRC1 SSTable DDR 地址 [63:0] |
| 0x001C | SRC1_SSTABLE_SIZE | W | SRC1 字节数 |
| 0x0020/24 | DST_BASE | W | 输出块 DDR 基址 [63:0] |
| 0x0028 | DST_BLOCK_STRIDE | W | 每个输出槽字节跨度 |
| 0x002C/30 | MID_BASE | W | 中间缓冲区 DDR 地址 [63:0] |
| 0x0034 | BLOCK_PAIR_COUNT | R | 已处理 block pair 数 |
| 0x0038 | MAX_FILE_SIZE | W | 最大输出 SSTable 大小（0=不分裂） |
| 0x003C | SSTABLE_COUNT | R | 产出的 SSTable 数量 |
| 0x0040 | SRC0_DECODED | R | src0 解码记录总数 |
| 0x0044 | SRC1_DECODED | R | src1 解码记录总数 |
| 0x0048 | SRC0_BYTES_READ | R | src0 读取字节数 |
| 0x004C | SRC1_BYTES_READ | R | src1 读取字节数 |
| 0x0050 | MERGE_OUTPUT_BYTES | R | 归并输出字节数 |
| 0x0054 | MERGE_DECODED | R | 归并解码记录数 |
| 0x0058 | MERGE_MERGED | R | 归并保留记录数 |
| 0x005C | MERGE_DROPPED | R | 归并丢弃记录数 |
| 0x0060 | STAGE5_INPUT | R | 编码器输入记录数 |
| 0x0064 | STAGE5_ENCODED | R | 编码器输出记录数 |
| 0x0068 | STAGE5_OUTPUT_BYTES | R | 编码输出块字节数 |
| 0x006C | STAGE5_BYTES_WRITTEN | R | 写入 DDR 字节数 |
| 0x0070 | PERF_CYCLE_COUNT | R | 本次运行 UI 时钟周期数 |
| 0x0100+ | DST_OUTPUT_BYTES[i] | R | 每个输出块字节数 (4B × MAX_BLOCK_PAIRS) |
| 0x0500+ | SSTABLE_SIZES[i] | R | 每个输出 SSTable 字节数 |

### 3.4 关键设计参数

| 参数 | 当前值 | 说明 |
|------|--------|------|
| MAX_BLOCK_PAIRS | 32 | 单次运行最多 block pair 数 |
| STAGE4_MAX_BLOCK_BYTES | 4096 | 源 data block 最大字节 |
| STAGE5_MAX_BLOCK_BYTES | 4096 | 输出 data block 最大字节 |
| MERGE_MAX_RECORDS | 256 | 单 block 最大记录数 |
| MERGE_MAX_USER_KEY_BYTES | 64 | 最大 user key 长度 |
| MERGE_MAX_VALUE_BYTES | 1024 | 最大 value 长度 |
| STAGE5_RESTART_INTERVAL | 16 | 输出 restart interval |
| MAX_SSTABLES | 16 | auto-split 最大输出 SSTable 数 |
| AXI_DATA_WIDTH | 512 | AXI 总线位宽 |

---

## 四、时序优化 (2026-05-13)

针对 300 MHz 时钟的关键路径进行了以下优化：

| 编号 | 模块 | 优化内容 | 目的 |
|------|------|----------|------|
| OPT-T1 | `cmpct_assembler_v2.v` | `entry_bytes_for` 拆分为两拍 (ST_COMPUTE_IDX → ST_COMPUTE_IDX_S2) | 打断 ~15 级 varint+乘法组合链 |
| OPT-T2 | `cmpct_merger.v` | ST_FINALIZE 寄存 selected 维度，预计算 emit_in_tag 标志 | 打断 source→MUX→比较 ~10 级链 |
| OPT-T3 | `cmpct_block_decoder.v` | 预寄存 prev_key_mem 写入基地址 `pkm_wr_base_r` | 打断 ADD→array-decode 路径 |
| OPT-T4 | `cmpct_pair_chain.v` | byte FIFO → merger 之间加 1 级 pipeline 寄存器 | 打断异步 LUTRAM 读→merger 组合路径 |

### Bug 修复 (同批次)

| Bug | 模块 | 原因 | 修复 |
|-----|------|------|------|
| heavy_dup 仿真挂死 | `cmpct_pair_chain.v` | `front_clear` 清除 encoder 输出适配器，导致 pair N 末尾字节丢失 | 适配器改为 `clear` only |
| enc_done/wr_done 竞争 | `cmpct_nblock_engine.v` | 两个 done 同拍到达丢失 wr_done 上升沿 | 增加 `wr_done_pending` 锁存 |

### 综合时序结果

| 指标 | 值 | 状态 |
|------|-----|------|
| WNS (Setup) | -0.471 ns | 未完全收敛 |
| TNS | -1086.67 ns | — |
| WHS (Hold) | +0.008 ns | ✅ 通过 |
| 关键路径 | `cmpct_block_decoder` BRAM bank 读取地址生成 | 需进一步优化 |

> 注：尽管 WNS 略负，实际硬件 1 GB 连续测试零错误，当前温度/电压条件下可正常工作。

---

## 五、测试结果

### 5.1 仿真测试 (Icarus Verilog)

运行脚本：`organized/sim/integration/run_all_tests.sh`

| 测试 | 描述 | 结果 |
|------|------|------|
| axil_2pair | 合成数据，2 block pairs | ✅ PASS |
| axil_1blk | 合成数据，1 block pair | ✅ PASS |
| asym_4pair | 非对称 src0=2blk src1=4blk | ✅ PASS |
| split_mode | auto-split 模式 | ✅ PASS |
| heavy_dup | 50% 重复 key | ✅ PASS |
| large_12blk | 12 block pairs + auto-split | ✅ PASS |
| real_sst | 真实 LevelDB SSTable (12 blocks, 8 dups) | ✅ PASS |

**仿真结果：7/7 PASS**

### 5.2 硬件板级测试 — 功能验证

运行脚本：`test/test_cmpct_sstable_engine_bp1_xdma.sh`

| Phase | 场景 | 数据 | 结果 | 周期数 |
|-------|------|------|------|--------|
| A | 1-pair baseline | 254B×2 | ✅ PASS | 1,237 |
| B | 2-pair pipeline | 373B+311B | ✅ PASS | 1,550 |
| C | 4-pair asymmetric | 362B+568B | ✅ PASS | — |
| D | 12-pair split | 2012B×2 | ✅ PASS | 7,932 |
| E | 12-pair streaming | 2012B×2 | ✅ PASS | 8,094 |
| F | 3× back-to-back stability | 2012B×2 ×3 | ✅ PASS | ~8,200 |
| G | 真实 LevelDB (4 blocks) | 4365B×2 | ✅ PASS | 12,928 |

**板级功能验证：7/7 PASS**

### 5.3 硬件板级测试 — GB 级压力 & 性能

运行脚本：`test/test_cmpct_sstable_engine_gb_xdma.sh`

| 指标 | 值 |
|------|-----|
| 总处理数据量 | **1024.46 MB** |
| 总轮次 | 2126 pass / **0 fail** |
| 每轮输入 | 505,278 bytes (200 block pairs, 8000 records) |
| 每 50 轮全量校验 | 全部通过 |
| 总耗时 (wall) | 33.92 s |
| **纯硬件吞吐** | **97.4 MB/s** (@300MHz) |
| 平均 HW 周期/轮 | 989,049 cycles (~3.30 ms) |
| Host 端吞吐 | 30.2 MB/s (含 XDMA 寄存器轮询开销) |
| 周期波动 | < 10 cycles（极其稳定） |

---

## 六、目录结构

```
leveldb_compaction_offload/
├── organized/
│   ├── rtl_v2/                     # RTL 源文件
│   │   ├── cmpct_top.v             # 顶层 AXI-Lite 包装 + CDC
│   │   ├── cmpct_engine.v          # 引擎核心（parser + matcher + nblock + assembler）
│   │   ├── cmpct_sstable_parser_v2.v  # 流式 SSTable 解析器
│   │   ├── cmpct_desc_matcher.v    # block handle 流 zip → descriptor 流
│   │   ├── cmpct_nblock_engine.v   # N-block 顺序调度 FSM
│   │   ├── cmpct_pair_chain.v      # 单对 block 处理链（decode+merge+encode+write）
│   │   ├── cmpct_source_pipe.v     # 源数据管道（AXI read → decoder）
│   │   ├── cmpct_block_decoder.v   # data block 解码器（4-bank BRAM, 4B/cycle）
│   │   ├── cmpct_merger.v          # 两路归并器（4B/cycle chunk compare）
│   │   ├── cmpct_block_encoder.v   # 流式编码器（32-bit wide）
│   │   ├── cmpct_assembler_v2.v    # SSTable 组装器（index+meta+footer）
│   │   ├── cmpct_infra.v           # 基础设施（AXI engines, FIFOs, adapters）
│   │   └── cmpct_sdpram.v          # 双端口 RAM 模板
│   ├── sim/
│   │   └── integration/            # 仿真 testbench + 运行脚本
│   │       ├── run_all_tests.sh    # 全量仿真回归
│   │       ├── tb_sstable_engine_*.v  # 各场景 testbench
│   │       └── fixtures/           # 仿真用 fixture 文件
│   └── docs/                       # 设计文档
├── test/                           # 硬件上板测试脚本
│   ├── test_cmpct_sstable_engine_bp1_xdma.sh      # 多阶段功能验证
│   ├── test_cmpct_sstable_engine_gb_xdma.sh        # GB 级压力 & 性能测试
│   ├── test_cmpct_sstable_engine_streaming_xdma.sh # 流式测试
│   ├── test_cmpct_sstable_engine_stress_xdma.sh    # 压力测试
│   └── test_cmpct_v2_xdma_suite.sh                 # 综合测试套件
├── driver/                         # 主机端 C++ 驱动（开发中）
└── STATUS.md                       # 本文件
```

---

## 七、当前进度与后续计划

### ✅ 已完成

1. 完整 RTL 流水线：SSTable 解析 → block 解码 → 两路归并去重 → 编码 → SSTable 组装
2. 支持 auto-split（单次运行输出多个 SSTable）
3. 支持不对称 block pair（`desc_matcher` 处理不等数量的 block）
4. Block trailer 自动追加（CRC32c）
5. 时序优化 4 项（OPT-T1~T4），bug 修复 2 项
6. 仿真全量回归 7/7 PASS
7. 硬件板级功能验证 7/7 PASS
8. **1 GB 连续压力测试 2126 轮零错误，纯硬件吞吐 97.4 MB/s**

### 🔧 待改进

1. **时序收敛**：WNS = -0.471 ns，关键路径在 `cmpct_block_decoder` BRAM 地址生成。需进一步拆分 emit 阶段的地址计算逻辑
2. **Host 端吞吐优化**：当前 30 MB/s 受限于逐次 reg 轮询。可改用中断模式或 batch 提交
3. **主机驱动 LevelDB 集成**：开发 `fpga_compaction.cc`，接入 LevelDB compaction 流程
4. **Snappy 压缩支持**：当前仅支持 kNoCompression
