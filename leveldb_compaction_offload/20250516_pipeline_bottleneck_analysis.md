# Pipeline Bottleneck Analysis — Post P9

## 1. Current Architecture (all 64-bit data paths)

```
Source0: DDR → 512b AXI → stream_width(512→64) → byte_skip_w64 → Decoder(P9+P11: 8B capture, varint pipe)
                                                                       ↓
                                                           64b byte FIFO(128) + pipe_reg
                                                                       ↓
                                                                   Merger (P6: 64b I/O)
                                                                       ↑
                                                           64b byte FIFO(128) + pipe_reg
                                                                       ↑
Source1: DDR → 512b AXI → stream_width(512→64) → byte_skip_w64 → Decoder(P9+P11: 8B capture, varint pipe)

Merger → hdr_FIFO + 64b data FIFO(64) → Encoder(P7: 64b I/O, 8B key recv/emit)
       → 64b byte_packer → 64b FIFO(128) → trailer_appender_w64 → packer → pack(64→512) → AXI Write
```

## 2. Measured Performance

| Metric | Value |
|--------|-------|
| Clock | 300 MHz (ui_aclk) |
| HW throughput | 761 MB/s |
| Bytes/cycle (input) | 2.660 |
| Avg cycles/block-pair | 189,945 / 200 = 950 |
| Records/block-pair | 40 (20 per source) |
| **Cycles/record** | **23.75** |
| Avg raw input/record | 63.2 bytes |

## 3. Per-Record Cycle Breakdown (Merger-centric)

Steady-state cycle budget per merged record (key≈24B, value≈60B):

| Phase | Cycles | Description |
|-------|--------|-------------|
| WAIT_HEADER | 1 | Header FIFO handshake |
| CAPTURE (key) | 3 | ceil(24/8) = 3, read key from decoder |
| FETCH | 1 | Routing state |
| COMPARE_INPUTS | 2 | Pipeline-registered 64-byte compare |
| CHECK_KEEP | 2 | Pipeline-registered equality check |
| FINALIZE | 1 | Select/keep decision |
| EMIT_HEADER | 1 | Output header to encoder |
| EMIT_PAYLOAD (key) | 3 | ceil(24/8) = 3, emit key + copy prev_key |
| STREAM_VALUE | 8 | ceil(60/8) = 8, 64-bit pass-through |
| **Total** | **22** | (measured: 23.75, delta = transitions + backpressure) |

**Fixed overhead per record: ~8 cycles** (header + fetch + compare + check + finalize + emit_hdr)  
**Data-proportional: ~14 cycles** (capture + emit + stream)

## 4. Stage Throughput Comparison

| Stage | Max Throughput (B/cycle) | Current Utilization |
|-------|--------------------------|---------------------|
| DDR Read | 64 B/cycle (512b) | <5% |
| Decoder | 8 B/cycle emit | ~30% (stalls on merger) |
| **Merger** | **~4.4 B/cycle effective** | **Bottleneck** |
| Encoder | 8 B/cycle (key+value) | ~55% (fed by merger) |
| AXI Write | 64 B/cycle (512b) | <5% |

## 5. Optimization Opportunities (Priority Order)

### P10: Merger Value-Capture Overlap (est. +15-25%)

**Principle**: During ST_STREAM_VALUE (8 cycles of pure data routing), the merger is idle
w.r.t. the other source. Overlap the next record's key capture with value streaming.

**Current**: STREAM_VALUE(8) → WAIT_HEADER(1) → CAPTURE(3) → sequential  
**Proposed**: STREAM_VALUE(8) while simultaneously CAPTURE'ing next key from other source

**Saves**: 3-4 cycles/record → from 23.75 to ~19.75 = **~17% throughput gain**

**Complexity**: High — requires dual-port capture logic and concurrent FSM tracks.

---

### P11: Compare/Check Pipeline Removal (est. +8-10%)

**Principle**: The `cmp_pipe_valid = (prev_state == state)` gating adds 1 extra cycle
to both COMPARE and CHECK states. With CMP_CHUNK == MAX_USER_KEY_BYTES, comparison
always finishes in a single iteration. The registered comparator output is valid after
1 clock in the state; the additional "valid" check costs 1 cycle.

**Current**: COMPARE(2) + CHECK(2) = 4 cycles  
**Proposed**: COMPARE(1) + CHECK(1) = 2 cycles (feed combinational result directly)

**Saves**: 2 cycles/record → from 23.75 to ~21.75 = **~8.5% throughput gain**

**Complexity**: Low — remove `prev_state` check, use direct combinational or 1-stage pipe.
**Risk**: May add critical path (64-byte compare → state transition in same cycle).
Mitigation: Pre-register key memories into flat vectors for comparison.

---

### P12: Eliminate FETCH/FINALIZE Transition Cycles (est. +4-8%)

**Principle**: ST_FETCH is a 1-cycle routing state (decides next state). ST_FINALIZE is a
1-cycle decision state. Both can be folded into their predecessor states.

- After CAPTURE: directly enter COMPARE (skip FETCH) when both bufs valid
- After CHECK_KEEP: directly enter EMIT_HEADER (fold FINALIZE logic)

**Saves**: 1-2 cycles/record → ~4-8% gain

**Complexity**: Medium — requires combining state transition conditions.

---

### P13: Encoder RECV_KEY Prefetch Overlap (est. +5-10%)

**Principle**: The encoder's ST_RECV_KEY captures 8 bytes/cycle from the merge FIFO and
simultaneously performs prefix comparison. The encoder can start receiving the next
record's key while the packer/trailer are still draining the previous record's output.
This is partially enabled by OPT-BP1 (block-pair pipeline), but within a block there's
no record-level overlap.

---

### P14: Increase Clock to 350 MHz (est. +17%)

**Principle**: The design currently meets timing at 300 MHz. Attempting 350 MHz would give
a direct 17% throughput increase if timing closure succeeds.

**Risk**: May require pipelining the merger's wide comparator and key memory MUX paths.

---

## 6. Recommended Implementation Order

| # | Optimization | Est. Gain | Effort | Dependencies |
|---|---|---|---|---|
| 1 | P11: Compare/Check 2→1 cycle | +8.5% | Low | None |
| 2 | P12: Eliminate FETCH/FINALIZE | +4-8% | Medium | None |
| 3 | P10: Value∥Capture overlap | +15-25% | High | Best after P11+P12 |
| 4 | P14: Clock push 300→350 | +17% | Medium | Timing analysis |

**Combined P11+P12+P10 estimate: +30-40% throughput → ~990-1060 MB/s @ 300 MHz**

## 7. Theoretical Ceiling

With all record-level overhead eliminated, the merger is limited by:
- Key capture: ceil(key/8) cycles (unavoidable — must read key to compare)
- Key emit: ceil(key/8) cycles (unavoidable — must output key)
- Value stream: ceil(value/8) cycles (unavoidable — must pass value)

Theoretical min = 2*ceil(key/8) + ceil(value/8) = 2*3 + 8 = 14 cycles/record

At 14 cycles/record: 505,278 bytes / (8000 records × 14 cycles/record) = **4.52 bytes/cycle = 1356 MB/s**

Current: 2.660 B/cycle. Theoretical max: 4.52 B/cycle. **Current efficiency: 59%**.
