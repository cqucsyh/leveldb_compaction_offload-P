// gen_real_sstable.cc
//
// Uses the real LevelDB TableBuilder to produce two SSTable files
// with known key-value content for RTL simulation.
//
// SRC0: 12 data blocks, each with 4 records  → 48 records
// SRC1: 12 data blocks, each with 4 records  → 48 records
// 8 duplicate user keys between SRC0 & SRC1 (SRC0 has higher seq → newer)
//
// Expected merge results:
//   total_decoded   = 48 + 48 = 96
//   total_merged    = 96 - 8 = 88   (8 older dups dropped)
//   total_dropped   = 8
//
// Outputs:
//   fixtures/src0_real.sst     - SRC0 SSTable binary (real LevelDB format)
//   fixtures/src1_real.sst     - SRC1 SSTable binary
//   fixtures/real_sstable_info.txt  - expected counters
//
// Build:
//   g++ -std=c++17 -I/home/yh/pp4/leveldb/include -I/home/yh/pp4/leveldb \
//       -o gen_real_sstable gen_real_sstable.cc \
//       /home/yh/pp4/leveldb/build_bench/libleveldb.a -lpthread
//
// NOTE: Uses kNoCompression so RTL can process raw blocks.
//       Uses small block_size (256 bytes) and block_restart_interval=2
//       to match RTL decoder's restart_interval expectation.

#include <cassert>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "leveldb/env.h"
#include "leveldb/options.h"
#include "leveldb/table.h"
#include "leveldb/table_builder.h"
#include "db/dbformat.h"
#include "util/coding.h"

static const char* FIXTURE_DIR = "fixtures";

// Build an internal key: user_key + PackSequenceAndType
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

// Generate SRC0 records: 12 blocks × 4 records = 48 records
// Keys: "key_0000" .. "key_0047"  (with some shared with SRC1)
// Seq: 1000 downward (newer)
static std::vector<std::vector<KVRecord>> MakeSrc0() {
    std::vector<std::vector<KVRecord>> blocks;
    int key_idx = 0;
    for (int b = 0; b < 12; b++) {
        std::vector<KVRecord> block;
        for (int r = 0; r < 4; r++) {
            char uk[32];
            snprintf(uk, sizeof(uk), "key_%04d", key_idx);
            uint64_t seq = 1000 - key_idx;
            block.push_back({MakeInternalKey(uk, seq), 
                            std::string("src0_val_") + uk});
            key_idx++;
        }
        blocks.push_back(block);
    }
    return blocks;
}

// Generate SRC1 records: 12 blocks × 4 records = 48 records
// First 2 blocks (8 records) use keys "key_0000".."key_0007" → duplicate with SRC0
//   but with lower sequence numbers (older → will be dropped by merge)
// Remaining 10 blocks use unique keys "key_1000".."key_1039"
static std::vector<std::vector<KVRecord>> MakeSrc1() {
    std::vector<std::vector<KVRecord>> blocks;

    // 2 blocks with duplicate keys (lower seq = older)
    int key_idx = 0;
    for (int b = 0; b < 2; b++) {
        std::vector<KVRecord> block;
        for (int r = 0; r < 4; r++) {
            char uk[32];
            snprintf(uk, sizeof(uk), "key_%04d", key_idx);
            uint64_t seq = 500 - key_idx;  // lower seq than SRC0
            block.push_back({MakeInternalKey(uk, seq),
                            std::string("src1_OLD_") + uk});
            key_idx++;
        }
        blocks.push_back(block);
    }

    // 10 blocks with unique keys
    key_idx = 1000;
    for (int b = 0; b < 10; b++) {
        std::vector<KVRecord> block;
        for (int r = 0; r < 4; r++) {
            char uk[32];
            snprintf(uk, sizeof(uk), "key_%04d", key_idx);
            uint64_t seq = 500 - (key_idx - 1000);
            block.push_back({MakeInternalKey(uk, seq),
                            std::string("src1_val_") + uk});
            key_idx++;
        }
        blocks.push_back(block);
    }
    return blocks;
}

// Write an SSTable using real LevelDB TableBuilder
// Returns file size on success, 0 on failure
static uint64_t WriteSSTable(const std::string& path,
                             const std::vector<std::vector<KVRecord>>& blocks) {
    leveldb::Env* env = leveldb::Env::Default();
    leveldb::WritableFile* file;
    leveldb::Status s = env->NewWritableFile(path, &file);
    if (!s.ok()) {
        fprintf(stderr, "Cannot create %s: %s\n", path.c_str(), s.ToString().c_str());
        return 0;
    }

    leveldb::Options opts;
    opts.compression = leveldb::kNoCompression;
    opts.block_size = 256;              // small blocks → many data blocks
    opts.block_restart_interval = 16;

    leveldb::TableBuilder builder(opts, file);

    for (size_t b = 0; b < blocks.size(); b++) {
        for (size_t r = 0; r < blocks[b].size(); r++) {
            builder.Add(blocks[b][r].internal_key, blocks[b][r].value);
        }
        // Force a block flush after each logical block
        builder.Flush();
    }

    s = builder.Finish();
    if (!s.ok()) {
        fprintf(stderr, "Finish failed: %s\n", s.ToString().c_str());
        delete file;
        return 0;
    }

    uint64_t fsize = builder.FileSize();
    s = file->Close();
    delete file;
    if (!s.ok()) {
        fprintf(stderr, "Close failed: %s\n", s.ToString().c_str());
        return 0;
    }
    return fsize;
}

// Count data blocks by iterating through the SSTable
static int CountDataBlocks(const std::string& path, uint64_t file_size) {
    leveldb::Env* env = leveldb::Env::Default();
    leveldb::RandomAccessFile* file;
    leveldb::Status s = env->NewRandomAccessFile(path, &file);
    if (!s.ok()) return -1;

    leveldb::Options opts;
    opts.compression = leveldb::kNoCompression;
    leveldb::Table* table = nullptr;
    s = leveldb::Table::Open(opts, file, file_size, &table);
    if (!s.ok()) {
        delete file;
        return -1;
    }

    // Count entries via iterator
    leveldb::ReadOptions ro;
    leveldb::Iterator* it = table->NewIterator(ro);
    int count = 0;
    for (it->SeekToFirst(); it->Valid(); it->Next()) {
        count++;
    }
    delete it;
    delete table;
    delete file;
    return count;
}

// Write memh file from binary
static void WriteMemH(const std::string& sst_path, const std::string& memh_path,
                      uint64_t base_addr) {
    std::ifstream fin(sst_path, std::ios::binary);
    std::ofstream fout(memh_path);

    char buf;
    fout << "@" << std::hex;
    // Print base address with 8-digit zero padding
    char addr_buf[16];
    snprintf(addr_buf, sizeof(addr_buf), "%08lx", (unsigned long)base_addr);
    fout << addr_buf << "\n";

    while (fin.get(buf)) {
        char hex[4];
        snprintf(hex, sizeof(hex), "%02x", (unsigned char)buf);
        fout << hex << "\n";
    }
}

int main() {
    // Create fixtures directory
    std::string cmd = std::string("mkdir -p ") + FIXTURE_DIR;
    system(cmd.c_str());

    auto src0_blocks = MakeSrc0();
    auto src1_blocks = MakeSrc1();

    int src0_total_records = 0, src1_total_records = 0;
    for (auto& b : src0_blocks) src0_total_records += b.size();
    for (auto& b : src1_blocks) src1_total_records += b.size();

    std::string src0_path = std::string(FIXTURE_DIR) + "/src0_real.sst";
    std::string src1_path = std::string(FIXTURE_DIR) + "/src1_real.sst";

    printf("=== Building SRC0 SSTable ===\n");
    printf("  %zu logical blocks, %d records total\n", src0_blocks.size(), src0_total_records);
    uint64_t src0_size = WriteSSTable(src0_path, src0_blocks);
    if (!src0_size) return 1;
    printf("  Written: %s  (%lu bytes)\n", src0_path.c_str(), (unsigned long)src0_size);

    printf("=== Building SRC1 SSTable ===\n");
    printf("  %zu logical blocks, %d records total\n", src1_blocks.size(), src1_total_records);
    uint64_t src1_size = WriteSSTable(src1_path, src1_blocks);
    if (!src1_size) return 1;
    printf("  Written: %s  (%lu bytes)\n", src1_path.c_str(), (unsigned long)src1_size);

    // Verify by reading back
    int src0_readback = CountDataBlocks(src0_path, src0_size);
    int src1_readback = CountDataBlocks(src1_path, src1_size);
    printf("\n=== Readback verification ===\n");
    printf("  SRC0: %d records (expected %d)\n", src0_readback, src0_total_records);
    printf("  SRC1: %d records (expected %d)\n", src1_readback, src1_total_records);
    if (src0_readback != src0_total_records || src1_readback != src1_total_records) {
        fprintf(stderr, "ERROR: readback mismatch!\n");
        return 1;
    }

    // Write memh files
    uint64_t SRC0_BASE = 0x00000000;
    uint64_t SRC1_BASE = 0x00010000;

    WriteMemH(src0_path, std::string(FIXTURE_DIR) + "/src0_real.memh", SRC0_BASE);
    WriteMemH(src1_path, std::string(FIXTURE_DIR) + "/src1_real.memh", SRC1_BASE);
    printf("\n=== Wrote .memh files ===\n");
    printf("  SRC0: base=0x%lx  size=%lu\n", (unsigned long)SRC0_BASE, (unsigned long)src0_size);
    printf("  SRC1: base=0x%lx  size=%lu\n", (unsigned long)SRC1_BASE, (unsigned long)src1_size);

    // Write info file with expected counters
    int dup_keys = 8;  // keys key_0000..key_0007 appear in both
    int total_merged = src0_total_records + src1_total_records - dup_keys;
    int total_dropped = dup_keys;

    std::string info_path = std::string(FIXTURE_DIR) + "/real_sstable_info.txt";
    FILE* info = fopen(info_path.c_str(), "w");
    fprintf(info, "src0_size=%lu\n", (unsigned long)src0_size);
    fprintf(info, "src1_size=%lu\n", (unsigned long)src1_size);
    fprintf(info, "src0_base=0x%lx\n", (unsigned long)SRC0_BASE);
    fprintf(info, "src1_base=0x%lx\n", (unsigned long)SRC1_BASE);
    fprintf(info, "src0_blocks=%zu\n", src0_blocks.size());
    fprintf(info, "src1_blocks=%zu\n", src1_blocks.size());
    fprintf(info, "src0_records=%d\n", src0_total_records);
    fprintf(info, "src1_records=%d\n", src1_total_records);
    fprintf(info, "duplicate_keys=%d\n", dup_keys);
    fprintf(info, "expected_block_pairs=%zu\n",
            std::max(src0_blocks.size(), src1_blocks.size()));
    fprintf(info, "expected_merge_decoded=%d\n", src0_total_records + src1_total_records);
    fprintf(info, "expected_merge_merged=%d\n", total_merged);
    fprintf(info, "expected_merge_dropped=%d\n", total_dropped);
    fclose(info);

    printf("\n=== Expected merge counters ===\n");
    printf("  block_pairs      = %zu (max(%zu, %zu))\n",
           std::max(src0_blocks.size(), src1_blocks.size()),
           src0_blocks.size(), src1_blocks.size());
    printf("  src0_decoded     = %d\n", src0_total_records);
    printf("  src1_decoded     = %d\n", src1_total_records);
    printf("  merge_decoded    = %d\n", src0_total_records + src1_total_records);
    printf("  merge_merged     = %d\n", total_merged);
    printf("  merge_dropped    = %d\n", total_dropped);
    printf("  sstable_count    >= 2  (12 blocks > MAX_BLOCK_PAIRS=8)\n");

    return 0;
}
