// test_split_board.cc
//
// Board-level test for the SSTable split feature.
//
// Generates 4-block SSTables (same topology as gen_test_sstable_split.py),
// runs through the FPGA SSTable engine twice:
//   Phase A — max_file_size=0  (no split) → sstable_count==1
//   Phase B — max_file_size=300 (split)   → sstable_count>=2
//
// For each phase it DMA-reads the output region, scans for LevelDB footer
// magic to identify sub-SSTable boundaries, and checks that the count and
// sizes match what the hardware reports via AXI-Lite status registers.
//
// Build:
//   g++ -std=c++14 -O2 -g \
//       -I/home/yh/pp4/leveldb/include \
//       -I/home/yh/pp4/leveldb \
//       test_split_board.cc compaction_offload.cc xdma_access.cc \
//       /home/yh/pp4/leveldb/build_bench/libleveldb.a -lpthread \
//       -o test_split_board
//
// Run (requires root and XDMA devices):
//   sudo ./test_split_board

#include "xdma_access.h"
#include "compaction_offload.h"

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <chrono>
#include <unistd.h>

// ---------------------------------------------------------------------------
// Minimal SSTable fixture builder (mirrors gen_test_sstable_split.py)
// ---------------------------------------------------------------------------
namespace fixture {

static std::string varint(uint64_t v) {
  std::string out;
  do {
    uint8_t b = static_cast<uint8_t>(v & 0x7F);
    v >>= 7;
    if (v) b |= 0x80;
    out.push_back(static_cast<char>(b));
  } while (v);
  return out;
}

static std::string block_handle(uint64_t off, uint64_t sz) {
  return varint(off) + varint(sz);
}

static std::string ikey(const std::string& uk, uint64_t seq, uint8_t vtype = 1) {
  std::string k = uk;
  uint64_t tag = (seq << 8) | vtype;
  for (int i = 0; i < 8; i++) {
    k.push_back(static_cast<char>(tag & 0xFF));
    tag >>= 8;
  }
  return k;
}

using Rec  = std::pair<std::string, std::string>;
using Recs = std::vector<Rec>;

static std::string encode_block(const Recs& recs, int restart_interval = 2) {
  if (recs.empty()) {
    return std::string("\x00\x00\x00\x00", 4);
  }
  std::string buf;
  std::vector<uint32_t> restarts;
  std::string prev;
  for (int idx = 0; idx < static_cast<int>(recs.size()); idx++) {
    const std::string& k = recs[idx].first;
    const std::string& v = recs[idx].second;
    int shared = 0;
    if (idx % restart_interval == 0) {
      restarts.push_back(static_cast<uint32_t>(buf.size()));
    } else {
      int mn = static_cast<int>(std::min(prev.size(), k.size()));
      while (shared < mn && prev[shared] == k[shared]) shared++;
    }
    buf += varint(shared);
    buf += varint(static_cast<uint64_t>(k.size() - shared));
    buf += varint(v.size());
    buf += k.substr(static_cast<size_t>(shared));
    buf += v;
    prev = k;
  }
  for (uint32_t r : restarts) {
    char rb[4];
    rb[0] = r & 0xFF; rb[1] = (r >> 8) & 0xFF;
    rb[2] = (r >> 16) & 0xFF; rb[3] = (r >> 24) & 0xFF;
    buf.append(rb, 4);
  }
  uint32_t cnt = static_cast<uint32_t>(restarts.size());
  char cb[4];
  cb[0] = cnt & 0xFF; cb[1] = (cnt >> 8) & 0xFF;
  cb[2] = (cnt >> 16) & 0xFF; cb[3] = (cnt >> 24) & 0xFF;
  buf.append(cb, 4);
  return buf;
}

static std::string block_with_trailer(const std::string& data) {
  std::string out = data;
  out.push_back(0x00);                      // kNoCompression
  out.append("\x00\x00\x00\x00", 4);        // CRC = 0
  return out;
}

static std::string build_sstable(const std::vector<Recs>& blocks,
                                  int restart_interval = 2) {
  std::string buf;
  std::vector<std::pair<size_t, size_t>> data_offsets;
  for (const auto& recs : blocks) {
    std::string raw = encode_block(recs, restart_interval);
    data_offsets.push_back({buf.size(), raw.size()});
    buf += block_with_trailer(raw);
  }
  std::vector<Rec> idx_entries;
  for (size_t i = 0; i < blocks.size(); i++) {
    std::string last_k;
    for (const auto& r : blocks[i])
      if (r.first > last_k) last_k = r.first;
    idx_entries.push_back({last_k, block_handle(data_offsets[i].first,
                                                 data_offsets[i].second)});
  }
  std::sort(idx_entries.begin(), idx_entries.end());
  std::string idx_raw = encode_block(idx_entries, 1);
  size_t idx_off = buf.size(), idx_sz = idx_raw.size();
  buf += block_with_trailer(idx_raw);
  std::string meta_raw = encode_block({}, 1);
  size_t meta_off = buf.size(), meta_sz = meta_raw.size();
  buf += block_with_trailer(meta_raw);
  std::string header = block_handle(meta_off, meta_sz) +
                       block_handle(idx_off, idx_sz);
  while (header.size() < 40) header.push_back(0);
  // Use the non-standard magic that matches the Python fixture generator
  uint64_t magic = 0x57fb808b24e46a97ULL;
  for (int i = 0; i < 8; i++) {
    header.push_back(static_cast<char>(magic & 0xFF));
    magic >>= 8;
  }
  assert(header.size() == 48);
  buf += header;
  return buf;
}

// 4-block SRC0: key_0000..key_0015 (4 recs/block)
static std::string make_src0_split() {
  std::vector<Recs> blocks(4);
  for (int blk = 0; blk < 4; blk++) {
    for (int i = 0; i < 4; i++) {
      int idx = blk * 4 + i;
      char kb[16]; snprintf(kb, sizeof(kb), "key_%04d", idx);
      std::string uk(kb);
      blocks[blk].push_back({ikey(uk, 100 + idx), "val_" + uk});
    }
  }
  return build_sstable(blocks, 2);
}

// 4-block SRC1: 2 recs/block, one dup + one unique per block
static std::string make_src1_split() {
  int dup_keys[] = {1, 5, 9, 13};
  std::vector<Recs> blocks(4);
  for (int blk = 0; blk < 4; blk++) {
    char kb[16];
    // Duplicate (older seq)
    snprintf(kb, sizeof(kb), "key_%04d", dup_keys[blk]);
    std::string dk(kb);
    blocks[blk].push_back({ikey(dk, 50 + blk), "old_" + dk});
    // Unique
    snprintf(kb, sizeof(kb), "key_%04d", 16 + blk);
    std::string uk(kb);
    blocks[blk].push_back({ikey(uk, 60 + blk), "old_" + uk});
  }
  return build_sstable(blocks, 2);
}

}  // namespace fixture

// ---------------------------------------------------------------------------
// AXI-Lite register map (must match cmpct_sstable_engine_axil_top.v)
// ---------------------------------------------------------------------------
static constexpr uint64_t kRegCtrl         = 0x0000;
static constexpr uint64_t kRegStatus       = 0x0004;
static constexpr uint64_t kRegSrc0BaseLo   = 0x0008;
static constexpr uint64_t kRegSrc0BaseHi   = 0x000C;
static constexpr uint64_t kRegSrc0Size     = 0x0010;
static constexpr uint64_t kRegSrc1BaseLo   = 0x0014;
static constexpr uint64_t kRegSrc1BaseHi   = 0x0018;
static constexpr uint64_t kRegSrc1Size     = 0x001C;
static constexpr uint64_t kRegDstBaseLo    = 0x0020;
static constexpr uint64_t kRegDstBaseHi    = 0x0024;
static constexpr uint64_t kRegDstStride    = 0x0028;
static constexpr uint64_t kRegMidBaseLo    = 0x002C;
static constexpr uint64_t kRegMidBaseHi    = 0x0030;
static constexpr uint64_t kRegBlockPairOut = 0x0034;
static constexpr uint64_t kRegMaxFileSize  = 0x0038;
static constexpr uint64_t kRegSstableCount = 0x003C;
static constexpr uint64_t kRegSrc0Decoded  = 0x0040;
static constexpr uint64_t kRegSrc1Decoded  = 0x0044;
static constexpr uint64_t kRegMrgDecoded   = 0x0054;
static constexpr uint64_t kRegMrgMerged    = 0x0058;
static constexpr uint64_t kRegMrgDropped   = 0x005C;
static constexpr uint64_t kRegS5Input      = 0x0060;
static constexpr uint64_t kRegS5Encoded    = 0x0064;
static constexpr uint64_t kRegS5Written    = 0x006C;
static constexpr uint64_t kRegPerfCycles   = 0x0070;
static constexpr uint64_t kRegSstSizesBase = 0x0500;

// STATUS bits
static constexpr uint32_t kStatusBusy  = 0x1;
static constexpr uint32_t kStatusDone  = 0x2;
static constexpr uint32_t kStatusError = 0x4;

// DDR layout
static constexpr uint64_t kSrc0Ddr = 0x00000000ULL;
static constexpr uint64_t kSrc1Ddr = 0x00100000ULL;
static constexpr uint64_t kDstDdr  = 0x00200000ULL;
static constexpr uint64_t kMidDdr  = 0x00300000ULL;
static constexpr uint32_t kDstStride = 0x00010000U;  // 64 KB per output slot

// LevelDB hardware output magic
static const uint8_t kMagic[8] = {0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static int g_pass = 0, g_fail = 0;

static void check(bool cond, const char* label) {
  if (cond) { printf("  [PASS] %s\n", label); g_pass++; }
  else      { printf("  [FAIL] %s\n", label); g_fail++; }
}

static void check_eq(uint32_t got, uint32_t exp, const char* label) {
  char buf[256];
  snprintf(buf, sizeof(buf), "%s: got=%u exp=%u", label, got, exp);
  check(got == exp, buf);
}

static void check_ge(uint32_t got, uint32_t minv, const char* label) {
  char buf[256];
  snprintf(buf, sizeof(buf), "%s: got=%u (>= %u)", label, got, minv);
  check(got >= minv, buf);
}

static void check_gt0(uint32_t got, const char* label) {
  char buf[256];
  snprintf(buf, sizeof(buf), "%s: got=%u (> 0)", label, got);
  check(got > 0, buf);
}

static uint64_t NowMs() {
  using namespace std::chrono;
  return static_cast<uint64_t>(
      duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count());
}

static uint32_t reg_read(XdmaAccess& x, uint64_t base, uint64_t off) {
  uint32_t v = 0;
  x.ReadReg(base + off, &v);
  return v;
}

static void reg_write(XdmaAccess& x, uint64_t base, uint64_t off, uint32_t v) {
  x.WriteReg(base + off, v);
}

// Count SSTable magic occurrences in buf, return positions (byte past magic).
static std::vector<size_t> find_all_sstable_ends(const uint8_t* buf, size_t len) {
  std::vector<size_t> ends;
  if (len < 8) return ends;
  for (size_t i = 8; i <= len; i++) {
    if (memcmp(buf + i - 8, kMagic, 8) == 0) {
      ends.push_back(i);
    }
  }
  return ends;
}

// ---------------------------------------------------------------------------
// Run one phase: DMA fixtures, configure, start, poll, read back & verify
// ---------------------------------------------------------------------------
static bool run_phase(XdmaAccess& xdma, uint64_t axil_base,
                      const std::string& src0, const std::string& src1,
                      uint32_t max_file_size, const char* phase_name,
                      // expected counters
                      uint32_t exp_pairs, uint32_t exp_s0_dec,
                      uint32_t exp_s1_dec, uint32_t exp_mrg_merged,
                      uint32_t exp_mrg_dropped, uint32_t exp_s5_input,
                      uint32_t exp_s5_encoded,
                      // split expectations
                      uint32_t exp_min_sst_count) {
  printf("\n=== %s ===\n", phase_name);
  int prev_fail = g_fail;

  // Clear engine
  reg_write(xdma, axil_base, kRegCtrl, 0x2);
  usleep(10000);
  reg_write(xdma, axil_base, kRegCtrl, 0x0);
  usleep(5000);

  // DMA source SSTables to DDR
  printf("  DMA SRC0 (%zu B) → 0x%08llx\n", src0.size(),
         (unsigned long long)kSrc0Ddr);
  if (!xdma.DmaToDevice(kSrc0Ddr, src0.data(), src0.size())) {
    printf("  [FAIL] DMA SRC0 failed: %s\n", xdma.GetError().c_str());
    g_fail++; return false;
  }
  printf("  DMA SRC1 (%zu B) → 0x%08llx\n", src1.size(),
         (unsigned long long)kSrc1Ddr);
  if (!xdma.DmaToDevice(kSrc1Ddr, src1.data(), src1.size())) {
    printf("  [FAIL] DMA SRC1 failed: %s\n", xdma.GetError().c_str());
    g_fail++; return false;
  }

  // Fill DST region with 0xA5 (sentinel for tail preservation check)
  size_t dst_fill = 0x40000;  // 256 KB
  std::vector<uint8_t> fill_buf(dst_fill, 0xA5);
  xdma.DmaToDevice(kDstDdr, fill_buf.data(), fill_buf.size());

  // Program registers
  reg_write(xdma, axil_base, kRegSrc0BaseLo, static_cast<uint32_t>(kSrc0Ddr));
  reg_write(xdma, axil_base, kRegSrc0BaseHi, static_cast<uint32_t>(kSrc0Ddr >> 32));
  reg_write(xdma, axil_base, kRegSrc0Size,   static_cast<uint32_t>(src0.size()));
  reg_write(xdma, axil_base, kRegSrc1BaseLo, static_cast<uint32_t>(kSrc1Ddr));
  reg_write(xdma, axil_base, kRegSrc1BaseHi, static_cast<uint32_t>(kSrc1Ddr >> 32));
  reg_write(xdma, axil_base, kRegSrc1Size,   static_cast<uint32_t>(src1.size()));
  reg_write(xdma, axil_base, kRegDstBaseLo,  static_cast<uint32_t>(kDstDdr));
  reg_write(xdma, axil_base, kRegDstBaseHi,  static_cast<uint32_t>(kDstDdr >> 32));
  reg_write(xdma, axil_base, kRegDstStride,  kDstStride);
  reg_write(xdma, axil_base, kRegMidBaseLo,  static_cast<uint32_t>(kMidDdr));
  reg_write(xdma, axil_base, kRegMidBaseHi,  static_cast<uint32_t>(kMidDdr >> 32));
  reg_write(xdma, axil_base, kRegMaxFileSize, max_file_size);

  // Start
  printf("  Starting engine...\n");
  reg_write(xdma, axil_base, kRegCtrl, 0x1);

  // Poll
  uint64_t deadline = NowMs() + 30000;  // 30 s timeout
  uint32_t status = 0;
  do {
    usleep(1000);
    status = reg_read(xdma, axil_base, kRegStatus);
  } while (!(status & (kStatusDone | kStatusError)) && NowMs() < deadline);

  if (status & kStatusError) {
    printf("  [FAIL] Engine error! STATUS=0x%08x\n", status);
    g_fail++;
    // Dump some registers
    printf("    pair_count=%u  perf_cycles=%u\n",
           reg_read(xdma, axil_base, kRegBlockPairOut),
           reg_read(xdma, axil_base, kRegPerfCycles));
    return false;
  }
  if (!(status & kStatusDone)) {
    printf("  [FAIL] Timeout! STATUS=0x%08x\n", status);
    g_fail++;
    return false;
  }

  uint32_t perf = reg_read(xdma, axil_base, kRegPerfCycles);
  printf("  Engine done, perf_cycles=%u\n", perf);

  // Verify counters
  check_eq(reg_read(xdma, axil_base, kRegBlockPairOut), exp_pairs,  "block_pair_count");
  check_eq(reg_read(xdma, axil_base, kRegSrc0Decoded),  exp_s0_dec, "src0_decoded");
  check_eq(reg_read(xdma, axil_base, kRegSrc1Decoded),  exp_s1_dec, "src1_decoded");
  check_eq(reg_read(xdma, axil_base, kRegMrgMerged),    exp_mrg_merged,  "merge_merged");
  check_eq(reg_read(xdma, axil_base, kRegMrgDropped),   exp_mrg_dropped, "merge_dropped");
  check_eq(reg_read(xdma, axil_base, kRegS5Input),      exp_s5_input,    "stage5_input");
  check_eq(reg_read(xdma, axil_base, kRegS5Encoded),    exp_s5_encoded,  "stage5_encoded");
  check_gt0(reg_read(xdma, axil_base, kRegS5Written),   "stage5_written");

  // Verify split counters
  uint32_t sst_count = reg_read(xdma, axil_base, kRegSstableCount);
  check_ge(sst_count, exp_min_sst_count, "sstable_count");

  // Read per-SSTable sizes
  uint32_t total_sst_bytes = 0;
  printf("  SSTable count = %u:\n", sst_count);
  for (uint32_t i = 0; i < sst_count && i < 8; i++) {
    uint32_t sz = reg_read(xdma, axil_base, kRegSstSizesBase + i * 4);
    printf("    SSTable[%u] size = %u bytes\n", i, sz);
    check_gt0(sz, "sstable_size[i]");
    total_sst_bytes += sz;
  }
  printf("  Total output bytes across %u SSTables: %u\n", sst_count, total_sst_bytes);

  // DMA back output and verify footer magic(s)
  std::vector<uint8_t> out_buf(dst_fill);
  if (!xdma.DmaFromDevice(kDstDdr, out_buf.data(), out_buf.size())) {
    printf("  [FAIL] DMA DST read failed: %s\n", xdma.GetError().c_str());
    g_fail++;
    return false;
  }

  auto ends = find_all_sstable_ends(out_buf.data(), out_buf.size());
  printf("  Found %zu LevelDB footer magic(s) in output region\n", ends.size());
  for (size_t i = 0; i < ends.size(); i++) {
    printf("    magic[%zu] at byte offset %zu\n", i, ends[i]);
  }

  {
    char label[256];
    snprintf(label, sizeof(label),
             "footer magic count (%zu) >= sstable_count (%u)",
             ends.size(), sst_count);
    check(ends.size() >= sst_count, label);
  }

  // For the first SSTable, verify it's a plausible output
  if (!ends.empty()) {
    size_t first_end = ends[0];
    char label[256];
    snprintf(label, sizeof(label),
             "first SSTable ends at byte %zu (> 48, plausible)", first_end);
    check(first_end > 48, label);
  }

  bool phase_ok = (g_fail == prev_fail);
  printf("  %s: %s\n", phase_name, phase_ok ? "PASS" : "FAIL");
  return phase_ok;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main() {
  printf("=== SSTable Split Board Test ===\n");

  // Build fixtures
  std::string src0 = fixture::make_src0_split();
  std::string src1 = fixture::make_src1_split();
  printf("SRC0: %zu bytes (4 blocks, 16 records)\n", src0.size());
  printf("SRC1: %zu bytes (4 blocks, 8 records)\n",  src1.size());

  // Expected counters (same for both phases — same input data):
  // 16 src0 decoded, 8 src1 decoded
  // 4 dups → 20 merged, 4 dropped
  // 20 stage5 input/encoded
  const uint32_t EXP_PAIRS    = 4;
  const uint32_t EXP_S0_DEC   = 16;
  const uint32_t EXP_S1_DEC   = 8;
  const uint32_t EXP_MERGED   = 20;
  const uint32_t EXP_DROPPED  = 4;
  const uint32_t EXP_S5_IN    = 20;
  const uint32_t EXP_S5_ENC   = 20;

  // Open XDMA
  XdmaAccess xdma("/dev/xdma0_h2c_0", "/dev/xdma0_c2h_0", "/dev/xdma0_user");
  if (!xdma.Open()) {
    printf("FATAL: cannot open XDMA devices: %s\n", xdma.GetError().c_str());
    printf("  Make sure XDMA driver is loaded and you have root privileges.\n");
    return 1;
  }
  printf("XDMA devices opened OK\n\n");

  uint64_t axil_base = 0x0;

  // Phase A: No split (baseline regression)
  run_phase(xdma, axil_base, src0, src1,
            0,  // max_file_size = 0 → no split
            "Phase A: No Split",
            EXP_PAIRS, EXP_S0_DEC, EXP_S1_DEC,
            EXP_MERGED, EXP_DROPPED, EXP_S5_IN, EXP_S5_ENC,
            1);  // expect at least 1 SSTable

  // Phase B: Aggressive split
  // Hardware SPLIT_TAIL_MARGIN=4096, so max_file_size must be > 4096 to enable.
  // split_threshold = max_file_size - 4096.
  // Per-block-pair output ≈ 141 B, so threshold=104 (max_file_size=4200)
  // should trigger a split after every block pair → 4 SSTables.
  run_phase(xdma, axil_base, src0, src1,
            4200,  // threshold=104 → split after each block pair
            "Phase B: Aggressive Split (max_file_size=4200)",
            EXP_PAIRS, EXP_S0_DEC, EXP_S1_DEC,
            EXP_MERGED, EXP_DROPPED, EXP_S5_IN, EXP_S5_ENC,
            2);  // expect at least 2 SSTables

  // Phase C: Moderate split
  // threshold = 4400 - 4096 = 304; per-BP aligned offset ≈ 192;
  // R2 (after 2 BPs) ≈ 384 >= 304 → split after BP2 (3+1 blocks)
  run_phase(xdma, axil_base, src0, src1,
            4400,  // threshold=304 → split after 2 block pairs
            "Phase C: Moderate Split (max_file_size=4400)",
            EXP_PAIRS, EXP_S0_DEC, EXP_S1_DEC,
            EXP_MERGED, EXP_DROPPED, EXP_S5_IN, EXP_S5_ENC,
            2);  // expect at least 2 SSTables

  // Phase D: Large max_file_size (no split expected)
  // threshold = 10000 - 4096 = 5904 → total output 563 < 5904, no split
  run_phase(xdma, axil_base, src0, src1,
            10000,  // threshold=5904 → total output fits, no split
            "Phase D: Large max_file_size (no split expected)",
            EXP_PAIRS, EXP_S0_DEC, EXP_S1_DEC,
            EXP_MERGED, EXP_DROPPED, EXP_S5_IN, EXP_S5_ENC,
            1);  // expect exactly 1 SSTable

  printf("\n========================================\n");
  printf("Summary: %d passed, %d failed\n", g_pass, g_fail);
  printf("========================================\n");
  return g_fail == 0 ? 0 : 1;
}
