// gen_real_sstable_scenarios.cc
//
// Parameterized real-LevelDB SSTable generator for thorough RTL simulation.
// Generates multiple scenarios to stress different aspects of the pipeline.
//
// Build:
//   g++ -std=c++17 -O2 \
//       -I/home/yh/pp4/leveldb/include -I/home/yh/pp4/leveldb \
//       -o gen_real_sstable_scenarios gen_real_sstable_scenarios.cc \
//       /home/yh/pp4/leveldb/build_bench/libleveldb.a -lpthread
//
// Usage:
//   ./gen_real_sstable_scenarios <scenario_name>
//
// Scenarios:
//   interleave     — interleaved keys (src0/src1 keys mix in sort order)
//   heavy_dup_real — 75% duplicate keys (real LevelDB format)
//   long_value     — values up to 900 bytes (near MERGE_MAX_VALUE_BYTES)
//   asym_real      — asymmetric (src0=3 blocks, src1=8 blocks)
//   many_records   — many records per block (close to MERGE_MAX_RECORDS per pair)
//   all            — generate all scenarios

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>
#include <algorithm>

#include "leveldb/env.h"
#include "leveldb/options.h"
#include "leveldb/table_builder.h"
#include "db/dbformat.h"
#include "util/coding.h"

static const char* FIXTURE_DIR = "fixtures";

static std::string MakeInternalKey(const std::string& user_key,
                                   uint64_t seq,
                                   leveldb::ValueType type = leveldb::kTypeValue) {
    std::string result = user_key;
    leveldb::PutFixed64(&result, (seq << 8) | static_cast<uint8_t>(type));
    return result;
}

struct KVRecord {
    std::string internal_key;
    std::string value;
};

static uint64_t WriteSSTable(const std::string& path,
                             const std::vector<std::vector<KVRecord>>& blocks,
                             int block_size = 256, int restart_interval = 16) {
    leveldb::Env* env = leveldb::Env::Default();
    leveldb::WritableFile* file;
    leveldb::Status s = env->NewWritableFile(path, &file);
    if (!s.ok()) { fprintf(stderr, "Cannot create %s: %s\n", path.c_str(), s.ToString().c_str()); return 0; }

    leveldb::Options opts;
    opts.compression = leveldb::kNoCompression;
    opts.block_size = block_size;
    opts.block_restart_interval = restart_interval;

    leveldb::TableBuilder builder(opts, file);
    for (auto& blk : blocks) {
        for (auto& kv : blk)
            builder.Add(kv.internal_key, kv.value);
        builder.Flush();
    }
    s = builder.Finish();
    if (!s.ok()) { fprintf(stderr, "Finish failed: %s\n", s.ToString().c_str()); delete file; return 0; }
    uint64_t fsize = builder.FileSize();
    file->Close();
    delete file;
    return fsize;
}

static void WriteMemH(const std::string& sst_path, const std::string& memh_path,
                      uint64_t base_addr) {
    std::ifstream fin(sst_path, std::ios::binary);
    std::ofstream fout(memh_path);
    char buf;
    fout << "@" << std::hex;
    char addr_buf[16];
    snprintf(addr_buf, sizeof(addr_buf), "%08lx", (unsigned long)base_addr);
    fout << addr_buf << "\n";
    while (fin.get(buf)) {
        char hex[4];
        snprintf(hex, sizeof(hex), "%02x", (unsigned char)buf);
        fout << hex << "\n";
    }
}

struct Scenario {
    std::string name;
    std::vector<std::vector<KVRecord>> src0_blocks;
    std::vector<std::vector<KVRecord>> src1_blocks;
    int block_size;
    int expected_merged;
    int expected_dropped;
};

static std::string MakeValue(const std::string& prefix, int size) {
    std::string val = prefix;
    while ((int)val.size() < size) val += 'x';
    return val.substr(0, size);
}

// ─── Scenario: interleaved keys ───
// src0 keys: a_0002, a_0004, a_0006, ...  (even)
// src1 keys: a_0001, a_0003, a_0005, ...  (odd)
// No duplicates. Keys interleave in merge.
static Scenario MakeInterleave() {
    Scenario sc;
    sc.name = "interleave";
    sc.block_size = 256;

    int src0_keys = 0, src1_keys = 0;
    for (int b = 0; b < 6; b++) {
        std::vector<KVRecord> blk0, blk1;
        for (int r = 0; r < 4; r++) {
            int idx0 = b * 8 + r * 2 + 2;
            int idx1 = b * 8 + r * 2 + 1;
            char uk0[32], uk1[32];
            snprintf(uk0, sizeof(uk0), "a_%04d", idx0);
            snprintf(uk1, sizeof(uk1), "a_%04d", idx1);
            blk0.push_back({MakeInternalKey(uk0, 1000 - idx0),
                           std::string("v0_") + uk0});
            blk1.push_back({MakeInternalKey(uk1, 1000 - idx1),
                           std::string("v1_") + uk1});
            src0_keys++; src1_keys++;
        }
        sc.src0_blocks.push_back(blk0);
        sc.src1_blocks.push_back(blk1);
    }
    sc.expected_merged = src0_keys + src1_keys;
    sc.expected_dropped = 0;
    return sc;
}

// ─── Scenario: heavy duplicates (real LevelDB) ───
// 6 blocks each, 4 records per block = 24 records per source
// First 4 blocks of src1 have the SAME keys as src0 blocks 0-3 (16 dups)
// Last 2 blocks of src1 are unique
static Scenario MakeHeavyDupReal() {
    Scenario sc;
    sc.name = "heavy_dup_real";
    sc.block_size = 256;

    int src0_keys = 0, src1_keys = 0, dups = 0;
    for (int b = 0; b < 6; b++) {
        std::vector<KVRecord> blk0;
        for (int r = 0; r < 4; r++) {
            char uk[32];
            snprintf(uk, sizeof(uk), "k_%04d", b * 4 + r);
            blk0.push_back({MakeInternalKey(uk, 2000 - (b * 4 + r)),
                           std::string("s0_") + uk});
            src0_keys++;
        }
        sc.src0_blocks.push_back(blk0);
    }
    // src1: 4 dup blocks + 2 unique blocks
    for (int b = 0; b < 4; b++) {
        std::vector<KVRecord> blk1;
        for (int r = 0; r < 4; r++) {
            char uk[32];
            snprintf(uk, sizeof(uk), "k_%04d", b * 4 + r);
            blk1.push_back({MakeInternalKey(uk, 1000 - (b * 4 + r)),
                           std::string("s1_OLD_") + uk});
            src1_keys++; dups++;
        }
        sc.src1_blocks.push_back(blk1);
    }
    for (int b = 0; b < 2; b++) {
        std::vector<KVRecord> blk1;
        for (int r = 0; r < 4; r++) {
            int idx = 5000 + b * 4 + r;
            char uk[32];
            snprintf(uk, sizeof(uk), "k_%04d", idx);
            blk1.push_back({MakeInternalKey(uk, 800 - (b * 4 + r)),
                           std::string("s1_uniq_") + uk});
            src1_keys++;
        }
        sc.src1_blocks.push_back(blk1);
    }
    sc.expected_merged = src0_keys + src1_keys - dups;
    sc.expected_dropped = dups;
    return sc;
}

// ─── Scenario: long values ───
// Values are 350-450 bytes (substantial but fits within STAGE5 4096B limit)
// Merged output per pair: 6 records × ~420B ≈ 2520B < 4096
static Scenario MakeLongValue() {
    Scenario sc;
    sc.name = "long_value";
    sc.block_size = 2048;  // larger blocks to fit big values

    int total_src0 = 0, total_src1 = 0;
    for (int b = 0; b < 4; b++) {
        std::vector<KVRecord> blk0, blk1;
        for (int r = 0; r < 3; r++) {
            int idx0 = b * 6 + r * 2;
            int idx1 = b * 6 + r * 2 + 1;
            char uk0[32], uk1[32];
            snprintf(uk0, sizeof(uk0), "lv_%04d", idx0);
            snprintf(uk1, sizeof(uk1), "lv_%04d", idx1);
            int vlen = 350 + (idx0 % 5) * 20;  // 350..430 bytes
            blk0.push_back({MakeInternalKey(uk0, 900 - idx0),
                           MakeValue(std::string("S0_") + uk0 + "_", vlen)});
            blk1.push_back({MakeInternalKey(uk1, 900 - idx1),
                           MakeValue(std::string("S1_") + uk1 + "_", vlen)});
            total_src0++; total_src1++;
        }
        sc.src0_blocks.push_back(blk0);
        sc.src1_blocks.push_back(blk1);
    }
    sc.expected_merged = total_src0 + total_src1;
    sc.expected_dropped = 0;
    return sc;
}

// ─── Scenario: asymmetric real ───
// src0: 3 blocks, src1: 8 blocks
// No duplicates. Tests one-sided processing for blocks 3-7.
static Scenario MakeAsymReal() {
    Scenario sc;
    sc.name = "asym_real";
    sc.block_size = 256;

    int total_src0 = 0, total_src1 = 0;
    // src0: 3 blocks × 4 records
    for (int b = 0; b < 3; b++) {
        std::vector<KVRecord> blk;
        for (int r = 0; r < 4; r++) {
            char uk[32];
            snprintf(uk, sizeof(uk), "ar_%04d", b * 100 + r);
            blk.push_back({MakeInternalKey(uk, 500 - (b * 4 + r)),
                           std::string("s0_") + uk});
            total_src0++;
        }
        sc.src0_blocks.push_back(blk);
    }
    // src1: 8 blocks × 4 records
    for (int b = 0; b < 8; b++) {
        std::vector<KVRecord> blk;
        for (int r = 0; r < 4; r++) {
            char uk[32];
            snprintf(uk, sizeof(uk), "ar_%04d", b * 100 + r + 50);
            blk.push_back({MakeInternalKey(uk, 400 - (b * 4 + r)),
                           std::string("s1_") + uk});
            total_src1++;
        }
        sc.src1_blocks.push_back(blk);
    }
    sc.expected_merged = total_src0 + total_src1;
    sc.expected_dropped = 0;
    return sc;
}

// ─── Scenario: many records per block ───
// src0/src1: 2 blocks × 16 records (32 records per source)
// Tests MERGE_MAX_RECORDS handling
static Scenario MakeManyRecords() {
    Scenario sc;
    sc.name = "many_records";
    sc.block_size = 2048;

    int total_src0 = 0, total_src1 = 0;
    for (int b = 0; b < 2; b++) {
        std::vector<KVRecord> blk0, blk1;
        for (int r = 0; r < 16; r++) {
            int idx = b * 32 + r * 2;
            char uk0[32], uk1[32];
            snprintf(uk0, sizeof(uk0), "mr_%04d", idx);
            snprintf(uk1, sizeof(uk1), "mr_%04d", idx + 1);
            blk0.push_back({MakeInternalKey(uk0, 700 - idx),
                           std::string("s0_v_") + uk0});
            blk1.push_back({MakeInternalKey(uk1, 700 - (idx + 1)),
                           std::string("s1_v_") + uk1});
            total_src0++; total_src1++;
        }
        sc.src0_blocks.push_back(blk0);
        sc.src1_blocks.push_back(blk1);
    }
    sc.expected_merged = total_src0 + total_src1;
    sc.expected_dropped = 0;
    return sc;
}

static void GenerateScenario(const Scenario& sc) {
    std::string cmd = std::string("mkdir -p ") + FIXTURE_DIR;
    system(cmd.c_str());

    uint64_t SRC0_BASE = 0x00000000;
    uint64_t SRC1_BASE = 0x00010000;

    std::string src0_sst = std::string(FIXTURE_DIR) + "/src0_" + sc.name + ".sst";
    std::string src1_sst = std::string(FIXTURE_DIR) + "/src1_" + sc.name + ".sst";
    std::string src0_memh = std::string(FIXTURE_DIR) + "/src0_" + sc.name + ".memh";
    std::string src1_memh = std::string(FIXTURE_DIR) + "/src1_" + sc.name + ".memh";

    int src0_recs = 0, src1_recs = 0;
    for (auto& b : sc.src0_blocks) src0_recs += b.size();
    for (auto& b : sc.src1_blocks) src1_recs += b.size();

    printf("\n=== Scenario: %s ===\n", sc.name.c_str());
    printf("  SRC0: %zu blocks, %d records\n", sc.src0_blocks.size(), src0_recs);
    printf("  SRC1: %zu blocks, %d records\n", sc.src1_blocks.size(), src1_recs);

    uint64_t src0_size = WriteSSTable(src0_sst, sc.src0_blocks, sc.block_size);
    uint64_t src1_size = WriteSSTable(src1_sst, sc.src1_blocks, sc.block_size);
    if (!src0_size || !src1_size) {
        fprintf(stderr, "  ERROR: SSTable generation failed\n");
        return;
    }
    printf("  SRC0 size: %lu bytes\n", (unsigned long)src0_size);
    printf("  SRC1 size: %lu bytes\n", (unsigned long)src1_size);

    WriteMemH(src0_sst, src0_memh, SRC0_BASE);
    WriteMemH(src1_sst, src1_memh, SRC1_BASE);

    // Write info file
    std::string info_path = std::string(FIXTURE_DIR) + "/" + sc.name + "_info.txt";
    FILE* f = fopen(info_path.c_str(), "w");
    fprintf(f, "scenario=%s\n", sc.name.c_str());
    fprintf(f, "src0_size=%lu\n", (unsigned long)src0_size);
    fprintf(f, "src1_size=%lu\n", (unsigned long)src1_size);
    fprintf(f, "src0_blocks=%zu\n", sc.src0_blocks.size());
    fprintf(f, "src1_blocks=%zu\n", sc.src1_blocks.size());
    fprintf(f, "src0_records=%d\n", src0_recs);
    fprintf(f, "src1_records=%d\n", src1_recs);
    fprintf(f, "block_pairs=%zu\n", std::max(sc.src0_blocks.size(), sc.src1_blocks.size()));
    fprintf(f, "expected_merged=%d\n", sc.expected_merged);
    fprintf(f, "expected_dropped=%d\n", sc.expected_dropped);
    fclose(f);

    printf("  Expected: merged=%d dropped=%d\n", sc.expected_merged, sc.expected_dropped);
    printf("  Wrote: %s, %s, %s\n", src0_memh.c_str(), src1_memh.c_str(), info_path.c_str());
}

int main(int argc, char** argv) {
    std::string target = (argc > 1) ? argv[1] : "all";

    std::vector<Scenario> scenarios;
    if (target == "interleave" || target == "all") scenarios.push_back(MakeInterleave());
    if (target == "heavy_dup_real" || target == "all") scenarios.push_back(MakeHeavyDupReal());
    if (target == "long_value" || target == "all") scenarios.push_back(MakeLongValue());
    if (target == "asym_real" || target == "all") scenarios.push_back(MakeAsymReal());
    if (target == "many_records" || target == "all") scenarios.push_back(MakeManyRecords());

    if (scenarios.empty()) {
        fprintf(stderr, "Unknown scenario: %s\n", target.c_str());
        fprintf(stderr, "Valid: interleave heavy_dup_real long_value asym_real many_records all\n");
        return 1;
    }

    for (auto& sc : scenarios) GenerateScenario(sc);
    printf("\nDone: %zu scenarios generated.\n", scenarios.size());
    return 0;
}
