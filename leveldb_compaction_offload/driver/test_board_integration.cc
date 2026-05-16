// test_board_integration.cc
//
// Two-phase test for the C++ compaction offload driver.
//
//  Phase 1 — Unit tests (no hardware, always run):
//    [U1] FindSStableEnd: locates footer magic in synthetic buffer
//    [U2] CanOffload:     size threshold checks
//    [U3] Graceful fail:  RunOffload returns IOError when XDMA devs missing
//
//  Phase 2 — Board integration (requires FPGA + root, run with --board):
//    [B1] Generate asymmetric fixture SSTables in C++
//         (SRC0: 2 blocks / 8 records,  SRC1: 4 blocks / 12 records)
//    [B2] RunOffload → FPGA engine
//    [B3] Verify output SSTable: footer magic present, file size > 0
//
// Build (no LevelDB needed):
//   g++ -std=c++14 -O2 -o test_board_integration \
//       test_board_integration.cc compaction_offload.cc xdma_access.cc \
//       -I/home/yh/pp4/leveldb/include \
//       -I/home/yh/pp4/leveldb \
//       -DCMPCT_OFFLOAD_ENABLED
//
// Run unit tests:
//   ./test_board_integration
//
// Run full board test:
//   sudo ./test_board_integration --board

#include "compaction_offload.h"
#include "db/dbformat.h"
#include "leveldb/env.h"
#include "leveldb/options.h"
#include "leveldb/table.h"

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <unistd.h>
#include <vector>

using namespace leveldb;

// ---------------------------------------------------------------------------
// Minimal SSTable fixture builder (mirrors the Python fixture generator)
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

// LevelDB internal key: userkey + (seq<<8 | vtype) as 8 LE bytes
static std::string ikey(const std::string& uk, uint64_t seq,
                         uint8_t vtype = 1) {
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
    return std::string("\x00\x00\x00\x00", 4);  // restart_count = 0
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
  out.append("\x00\x00\x00\x00", 4);        // CRC = 0 (hardware ignores)
  return out;
}

static std::string build_sstable(const std::vector<Recs>& blocks,
                                  int restart_interval = 2) {
  std::string buf;
  std::vector<std::pair<size_t, size_t>> data_offsets;  // (offset, raw_size)

  for (const auto& recs : blocks) {
    std::string raw = encode_block(recs, restart_interval);
    data_offsets.push_back({buf.size(), raw.size()});
    buf += block_with_trailer(raw);
  }

  // Index block
  std::vector<Rec> idx_entries;
  for (size_t i = 0; i < blocks.size(); i++) {
    std::string last_k;
    for (const auto& r : blocks[i])
      if (r.first > last_k) last_k = r.first;
    idx_entries.push_back(
        {last_k, block_handle(data_offsets[i].first, data_offsets[i].second)});
  }
  std::sort(idx_entries.begin(), idx_entries.end());
  std::string idx_raw = encode_block(idx_entries, 1);
  size_t idx_off = buf.size(), idx_sz = idx_raw.size();
  buf += block_with_trailer(idx_raw);

  // Metaindex block (empty)
  std::string meta_raw = encode_block({}, 1);
  size_t meta_off = buf.size(), meta_sz = meta_raw.size();
  buf += block_with_trailer(meta_raw);

  // Footer (48 bytes)
  std::string header = block_handle(meta_off, meta_sz) +
                       block_handle(idx_off, idx_sz);
  while (header.size() < 40) header.push_back(0);
  uint64_t magic = 0xdb4775248b80fb57ULL;
  for (int i = 0; i < 8; i++) {
    header.push_back(static_cast<char>(magic & 0xFF));
    magic >>= 8;
  }
  assert(header.size() == 48);
  buf += header;
  return buf;
}

// Asymmetric fixture: SRC0=2 blocks / 8 records, SRC1=4 blocks / 12 records
// No cross-source duplicate keys → merged=20, dropped=0
static void make_asymmetric_fixtures(std::string* src0, std::string* src1) {
  auto val0 = [](const std::string& k) { return "v0_" + k; };
  auto val1 = [](const std::string& k) { return "v1_" + k; };
  char kbuf[16];

  // SRC0 block 0: key_0000..key_0003
  Recs b0_src0;
  for (int i : {0, 1, 2, 3}) {
    snprintf(kbuf, sizeof(kbuf), "key_%04d", i);
    std::string uk(kbuf);
    b0_src0.push_back({ikey(uk, 20 + i), val0(uk)});
  }
  // SRC0 block 1: key_0010..key_0013
  Recs b1_src0;
  for (int i : {10, 11, 12, 13}) {
    snprintf(kbuf, sizeof(kbuf), "key_%04d", i);
    std::string uk(kbuf);
    b1_src0.push_back({ikey(uk, 24 + i - 10), val0(uk)});
  }

  // SRC1 block 0: key_0004..key_0006
  Recs b0_src1;
  for (int i : {4, 5, 6}) {
    snprintf(kbuf, sizeof(kbuf), "key_%04d", i);
    std::string uk(kbuf);
    b0_src1.push_back({ikey(uk, i), val1(uk)});
  }
  // SRC1 block 1: key_0014..key_0016
  Recs b1_src1;
  for (int i : {14, 15, 16}) {
    snprintf(kbuf, sizeof(kbuf), "key_%04d", i);
    std::string uk(kbuf);
    b1_src1.push_back({ikey(uk, i - 7), val1(uk)});
  }
  // SRC1 block 2: key_0020..key_0022
  Recs b2_src1;
  for (int i : {20, 21, 22}) {
    snprintf(kbuf, sizeof(kbuf), "key_%04d", i);
    std::string uk(kbuf);
    b2_src1.push_back({ikey(uk, i - 10), val1(uk)});
  }
  // SRC1 block 3: key_0030..key_0032
  Recs b3_src1;
  for (int i : {30, 31, 32}) {
    snprintf(kbuf, sizeof(kbuf), "key_%04d", i);
    std::string uk(kbuf);
    b3_src1.push_back({ikey(uk, i - 17), val1(uk)});
  }

  *src0 = build_sstable({b0_src0, b1_src0}, 2);
  *src1 = build_sstable({b0_src1, b1_src1, b2_src1, b3_src1}, 2);
}

}  // namespace fixture

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------
static int g_pass = 0, g_fail = 0;

static void check(bool cond, const char* label) {
  if (cond) {
    printf("  [PASS] %s\n", label);
    g_pass++;
  } else {
    printf("  [FAIL] %s\n", label);
    g_fail++;
  }
}

static bool write_tmp(const std::string& path, const std::string& data) {
  FILE* f = fopen(path.c_str(), "wb");
  if (!f) return false;
  fwrite(data.data(), 1, data.size(), f);
  fclose(f);
  return true;
}

 static void check_leveldb_table(const char* path, size_t file_size,
                                int expected_records,
                                const char* expected_first_user_key,
                                const char* expected_last_user_key,
                                const char* prefix) {
  Options options;
  options.paranoid_checks = true;

  RandomAccessFile* file = nullptr;
  Status s = Env::Default()->NewRandomAccessFile(path, &file);
  {
    char label[256];
    snprintf(label, sizeof(label), "%s open RandomAccessFile", prefix);
    check(s.ok(), label);
  }
  if (!s.ok()) return;

  Table* table = nullptr;
  s = Table::Open(options, file, file_size, &table);
  {
    char label[256];
    snprintf(label, sizeof(label), "%s Table::Open", prefix);
    check(s.ok(), label);
    if (!s.ok()) {
      printf("    %s Table::Open status: %s\n", prefix, s.ToString().c_str());
    }
  }
  if (!s.ok()) {
    delete file;
    return;
  }

  ReadOptions ro;
  ro.verify_checksums = true;
  Iterator* it = table->NewIterator(ro);

  it->SeekToFirst();
  {
    char label[256];
    snprintf(label, sizeof(label), "%s iterator SeekToFirst valid", prefix);
    check(it->Valid(), label);
  }

  int count = 0;
  std::string first_user_key;
  std::string last_user_key;
  ParsedInternalKey pik;
  InternalKeyComparator icmp(BytewiseComparator());
  std::string prev_key_storage;
  bool have_prev = false;
  for (; it->Valid(); it->Next()) {
    bool parsed = ParseInternalKey(it->key(), &pik);
    {
      char label[256];
      snprintf(label, sizeof(label), "%s ParseInternalKey during scan", prefix);
      check(parsed, label);
    }
    if (!parsed) break;
    if (count == 0) first_user_key = pik.user_key.ToString();
    last_user_key = pik.user_key.ToString();
    if (have_prev) {
      char label[256];
      snprintf(label, sizeof(label), "%s iterator order monotonic", prefix);
      check(icmp.Compare(Slice(prev_key_storage), it->key()) < 0, label);
    }
    prev_key_storage.assign(it->key().data(), it->key().size());
    have_prev = true;
    count++;
  }
  {
    char label[256];
    snprintf(label, sizeof(label), "%s iterator status after full scan", prefix);
    check(it->status().ok(), label);
    if (!it->status().ok()) {
      printf("    %s iterator scan status: %s\n", prefix,
             it->status().ToString().c_str());
    }
  }
  {
    char label[256];
    snprintf(label, sizeof(label), "%s record count == %d", prefix, expected_records);
    check(count == expected_records, label);
  }
  {
    char label[256];
    snprintf(label, sizeof(label), "%s first user key == %s", prefix,
             expected_first_user_key);
    check(first_user_key == expected_first_user_key, label);
  }
  {
    char label[256];
    snprintf(label, sizeof(label), "%s last user key == %s", prefix,
             expected_last_user_key);
    check(last_user_key == expected_last_user_key, label);
  }

  it->SeekToLast();
  {
    char label[256];
    snprintf(label, sizeof(label), "%s iterator SeekToLast valid", prefix);
    check(it->Valid(), label);
  }
  if (it->Valid()) {
    bool parsed = ParseInternalKey(it->key(), &pik);
    {
      char label[256];
      snprintf(label, sizeof(label), "%s ParseInternalKey at last entry", prefix);
      check(parsed, label);
    }
    if (parsed) {
      char label[256];
      snprintf(label, sizeof(label), "%s SeekToLast user key == %s", prefix,
               expected_last_user_key);
      check(pik.user_key.ToString() == expected_last_user_key, label);
    }
  }
  {
    char label[256];
    snprintf(label, sizeof(label), "%s iterator status after SeekToLast", prefix);
    check(it->status().ok(), label);
    if (!it->status().ok()) {
      printf("    %s iterator last status: %s\n", prefix,
             it->status().ToString().c_str());
    }
  }

  delete it;
  delete table;
  delete file;
 }

// ---------------------------------------------------------------------------
// Phase 1 — Unit tests
// ---------------------------------------------------------------------------
static void run_unit_tests() {
  printf("\n=== Phase 1: Unit Tests ===\n");

  // [U1] FindSStableEnd
  {
    printf("\n[U1] FindSStableEnd\n");

    // Build a buffer with some preamble + real LevelDB magic at a known offset
    // Real LevelDB kTableMagicNumber = 0xdb4775248b80fb57 (little-endian)
    const uint8_t magic[8] = {0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb};
    std::vector<uint8_t> buf(256, 0xAB);
    // Place magic at offset 100 (SSTable ends at 108)
    memcpy(buf.data() + 100, magic, 8);

    size_t end = CompactionOffloadDriver::FindSStableEnd(buf.data(), buf.size());
    check(end == 108, "magic at offset 100 → end == 108");

    // Magic at the very end of the buffer
    std::vector<uint8_t> buf2(64, 0);
    memcpy(buf2.data() + 56, magic, 8);
    end = CompactionOffloadDriver::FindSStableEnd(buf2.data(), buf2.size());
    check(end == 64, "magic at tail → end == buf.size()");

    // No magic → returns 0
    std::vector<uint8_t> buf3(32, 0);
    end = CompactionOffloadDriver::FindSStableEnd(buf3.data(), buf3.size());
    check(end == 0, "no magic → 0");

    // Actual fixture SSTable contains its own magic
    std::string src0_data, src1_data;
    fixture::make_asymmetric_fixtures(&src0_data, &src1_data);
    const uint8_t* p = reinterpret_cast<const uint8_t*>(src0_data.data());
    end = CompactionOffloadDriver::FindSStableEnd(p, src0_data.size());
    check(end == src0_data.size(), "FindSStableEnd on generated SRC0 == file size");
  }

  // [U2] CanOffload
  {
    printf("\n[U2] CanOffload\n");
    auto& drv = CompactionOffloadDriver::Get();

    check(drv.CanOffload(512, 1024), "512B + 1024B → can offload");
    check(drv.CanOffload(1024 * 1024, 1024 * 1024),
          "1MB + 1MB  → can offload (at limit)");
    check(!drv.CanOffload(1024 * 1024 + 1, 0),
          "1MB+1 byte → cannot offload (SRC0 over limit)");
    check(!drv.CanOffload(0, 1024 * 1024 + 1),
          "1MB+1 byte → cannot offload (SRC1 over limit)");
  }

  // [U3] Graceful fail without XDMA devices
  {
    printf("\n[U3] Graceful fail (non-existent XDMA device paths)\n");
    CompactionOffloadDriver::Config bad_cfg;
    bad_cfg.h2c_dev  = "/dev/no_such_h2c";
    bad_cfg.c2h_dev  = "/dev/no_such_c2h";
    bad_cfg.user_dev = "/dev/no_such_user";

    std::string src0_data, src1_data;
    fixture::make_asymmetric_fixtures(&src0_data, &src1_data);

    // Write fixture to /tmp
    write_tmp("/tmp/cmpct_test_src0.bin", src0_data);
    write_tmp("/tmp/cmpct_test_src1.bin", src1_data);

    CompactionOffloadDriver drv_bad;
    drv_bad.SetConfig(bad_cfg);
    size_t out_sz = 0;
    Status s = drv_bad.RunOffload("/tmp/cmpct_test_src0.bin", src0_data.size(),
                                   "/tmp/cmpct_test_src1.bin", src1_data.size(),
                                   "/tmp/cmpct_test_out.bin",  &out_sz);
    check(!s.ok(), "RunOffload returns non-OK with missing XDMA devices");
    check(s.IsIOError(),
          "Status is IOError (not corruption/invalid)");
    printf("         Status: %s\n", s.ToString().c_str());

    unlink("/tmp/cmpct_test_src0.bin");
    unlink("/tmp/cmpct_test_src1.bin");
  }

  // [U4] Multi-SSTable pre-merge path (P1):
  //   Simulate BuildMergedSSTableForOffload by manually building a merged
  //   SSTable from two independent sub-fixtures, then verify its structure.
  {
    printf("\n[U4] Multi-SSTable pre-merge path\n");

    // Sub-fixture A: key_0000..key_0001 (1 block, 2 records)
    fixture::Recs blk_a;
    for (int i : {0, 1}) {
      char kb[16]; snprintf(kb, sizeof(kb), "key_%04d", i);
      std::string uk(kb);
      blk_a.push_back({fixture::ikey(uk, 20 + i), "v0_" + uk});
    }
    // Sub-fixture B: key_0010..key_0011 (1 block, 2 records)
    fixture::Recs blk_b;
    for (int i : {10, 11}) {
      char kb[16]; snprintf(kb, sizeof(kb), "key_%04d", i);
      std::string uk(kb);
      blk_b.push_back({fixture::ikey(uk, 24 + i - 10), "v0_" + uk});
    }

    // Two separate single-block SSTables (= two input files on level-N side)
    std::string sub_a = fixture::build_sstable({blk_a}, 2);
    std::string sub_b = fixture::build_sstable({blk_b}, 2);

    // Merged SSTable (= output of BuildMergedSSTableForOffload)
    std::string merged = fixture::build_sstable({blk_a, blk_b}, 2);

    check(sub_a.size() > 0,   "sub-SSTable A built");
    check(sub_b.size() > 0,   "sub-SSTable B built");
    check(merged.size() > 0,  "merged SSTable built");

    // Merged must be larger than either sub (has more data)
    check(merged.size() > sub_a.size(), "merged > sub_a (more data)");
    check(merged.size() > sub_b.size(), "merged > sub_b (more data)");

    // Merged footer magic is valid
    const uint8_t* mp = reinterpret_cast<const uint8_t*>(merged.data());
    size_t end = CompactionOffloadDriver::FindSStableEnd(mp, merged.size());
    check(end == merged.size(), "merged SSTable footer magic present");

    // Total size is still within hardware limits
    check(CompactionOffloadDriver::Get().CanOffload(merged.size(), 568),
          "merged SRC0 + typical SRC1 within hardware limits");

    printf("  sub_a=%zu bytes  sub_b=%zu bytes  merged=%zu bytes\n",
           sub_a.size(), sub_b.size(), merged.size());
  }
}

// ---------------------------------------------------------------------------
// Phase 2 — Board integration test
// ---------------------------------------------------------------------------
static void run_board_test() {
  printf("\n=== Phase 2: Board Integration Test ===\n");

  // Generate fixture SSTables
  std::string src0_data, src1_data;
  fixture::make_asymmetric_fixtures(&src0_data, &src1_data);

  printf("  SRC0: %zu bytes  (%s)\n", src0_data.size(),
         CompactionOffloadDriver::Get().CanOffload(src0_data.size(), src1_data.size())
             ? "eligible" : "TOO LARGE");
  printf("  SRC1: %zu bytes\n", src1_data.size());

  // Write fixture files to /tmp
  const char* src0_path = "/tmp/cmpct_board_src0.ldb";
  const char* src1_path = "/tmp/cmpct_board_src1.ldb";
  const char* out_path  = "/tmp/cmpct_board_out.ldb";

  if (!write_tmp(src0_path, src0_data) || !write_tmp(src1_path, src1_data)) {
    printf("  [FAIL] Could not write fixture files to /tmp\n");
    g_fail++;
    return;
  }
  printf("  Fixture files written to /tmp/cmpct_board_src{0,1}.ldb\n");

  // Run offload
  printf("  Calling CompactionOffloadDriver::RunOffload ...\n");
  size_t out_size = 0;
  Status s = CompactionOffloadDriver::Get().RunOffload(
      src0_path, src0_data.size(),
      src1_path, src1_data.size(),
      out_path,  &out_size);

  if (!s.ok()) {
    printf("  [FAIL] RunOffload failed: %s\n", s.ToString().c_str());
    g_fail++;
    goto cleanup;
  }
  printf("  RunOffload returned OK, out_size = %zu bytes\n", out_size);
  check(out_size > 0,   "output SSTable size > 0");
  check(out_size <= CompactionOffloadDriver::Get().GetConfig().max_out_bytes,
        "output SSTable size within read-back limit");

  // Verify output file contains footer magic
  {
    std::ifstream f(out_path, std::ios::binary);
    if (!f) {
      check(false, "output file exists and readable");
      goto cleanup;
    }
    std::vector<uint8_t> out_buf((std::istreambuf_iterator<char>(f)),
                                  std::istreambuf_iterator<char>());
    f.close();
    check(out_buf.size() == out_size, "file size matches reported out_size");

    size_t end = CompactionOffloadDriver::FindSStableEnd(
        out_buf.data(), out_buf.size());
    check(end == out_size, "LevelDB footer magic found at correct position");

    // Check that the last 8 bytes are the real LevelDB magic (0xdb4775248b80fb57)
    const uint8_t magic[8] = {0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb};
    check(out_buf.size() >= 8 &&
          memcmp(out_buf.data() + out_buf.size() - 8, magic, 8) == 0,
          "last 8 bytes == LevelDB magic");

    check_leveldb_table(out_path, out_size, 20, "key_0000", "key_0032", "[B1]");
  }

cleanup:
  unlink(src0_path);
  unlink(src1_path);
  // Keep out_path for post-mortem inspection on failure
  if (g_fail == 0) unlink(out_path);
  else printf("  Output file kept at %s for inspection\n", out_path);
}

// ---------------------------------------------------------------------------
// Phase 2B — Board test: P1 pre-merge path
//   Two level-N sub-files are merged into a single SRC0 SSTable on the host
//   (simulating BuildMergedSSTableForOffload), then the merged file is offloaded
//   to hardware together with the 4-block SRC1 fixture.
// ---------------------------------------------------------------------------
static void run_board_test_multi() {
  printf("\n=== Phase 2B: Board Test — P1 Pre-Merge Path ===\n");

  const int prev_fail = g_fail;

  // Sub-fixture A for SRC0 (= what would be file 0 on level-N)
  fixture::Recs blk_a;
  for (int i : {0, 1, 2, 3}) {
    char kb[16]; snprintf(kb, sizeof(kb), "key_%04d", i);
    std::string uk(kb);
    blk_a.push_back({fixture::ikey(uk, 20 + i), "v0_" + uk});
  }
  // Sub-fixture B for SRC0 (= what would be file 1 on level-N)
  fixture::Recs blk_b;
  for (int i : {10, 11, 12, 13}) {
    char kb[16]; snprintf(kb, sizeof(kb), "key_%04d", i);
    std::string uk(kb);
    blk_b.push_back({fixture::ikey(uk, 24 + i - 10), "v0_" + uk});
  }

  // Merged SRC0 = result of BuildMergedSSTableForOffload(files=[A,B])
  std::string merged_src0 = fixture::build_sstable({blk_a, blk_b}, 2);

  // SRC1: original 4-block asymmetric fixture (unchanged)
  std::string src0_dummy, src1_data;
  fixture::make_asymmetric_fixtures(&src0_dummy, &src1_data);

  printf("  merged_src0: %zu bytes (2 sub-files combined)\n", merged_src0.size());
  printf("  src1       : %zu bytes (4 blocks, unchanged)\n", src1_data.size());

  const char* src0_path = "/tmp/cmpct_b2_merged_src0.ldb";
  const char* src1_path = "/tmp/cmpct_b2_src1.ldb";
  const char* out_path  = "/tmp/cmpct_b2_out.ldb";

  if (!write_tmp(src0_path, merged_src0) || !write_tmp(src1_path, src1_data)) {
    printf("  [FAIL] Could not write fixture files\n");
    g_fail++;
    return;
  }

  printf("  Calling RunOffload (pre-merged SRC0) ...\n");
  size_t out_size = 0;
  Status s = CompactionOffloadDriver::Get().RunOffload(
      src0_path, merged_src0.size(),
      src1_path, src1_data.size(),
      out_path,  &out_size);

  if (!s.ok()) {
    printf("  [FAIL] RunOffload failed: %s\n", s.ToString().c_str());
    g_fail++;
    goto cleanup2;
  }
  printf("  RunOffload OK, out_size = %zu bytes\n", out_size);
  check(out_size > 0, "[B2] pre-merged output size > 0");

  {
    std::ifstream f(out_path, std::ios::binary);
    if (!f) { check(false, "[B2] output file readable"); goto cleanup2; }
    std::vector<uint8_t> out_buf((std::istreambuf_iterator<char>(f)),
                                  std::istreambuf_iterator<char>());
    f.close();

    size_t end = CompactionOffloadDriver::FindSStableEnd(
        out_buf.data(), out_buf.size());
    check(end == out_size, "[B2] footer magic at correct position");

    const uint8_t magic[8] = {0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb};
    check(out_buf.size() >= 8 &&
          memcmp(out_buf.data() + out_buf.size() - 8, magic, 8) == 0,
          "[B2] last 8 bytes == LevelDB magic");

    check_leveldb_table(out_path, out_size, 20, "key_0000", "key_0032", "[B2]");

    if (g_fail == prev_fail)
      printf("  Pre-merge path: all checks PASS  (%zu B output)\n", out_size);
  }

cleanup2:
  unlink(src0_path);
  unlink(src1_path);
  if (g_fail == prev_fail) unlink(out_path);
  else printf("  Output kept at %s for inspection\n", out_path);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char* argv[]) {
  bool board = false;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--board") == 0) board = true;
  }

  printf("=== Compaction Offload Driver Test ===\n");

  run_unit_tests();

  if (board) {
    run_board_test();
    run_board_test_multi();
  } else {
    printf("\n(Skipping board tests; re-run with --board for hardware tests)\n");
  }

  printf("\n=== Summary: %d passed, %d failed ===\n", g_pass, g_fail);
  return g_fail == 0 ? 0 : 1;
}
