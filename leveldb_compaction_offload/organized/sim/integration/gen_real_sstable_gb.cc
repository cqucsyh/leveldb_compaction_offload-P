// gen_real_sstable_gb.cc
//
// Generates a large SSTable pair for GB-level board stress testing.
// Each SSTable has N_BLOCKS data blocks (default 200), each with ~20 records.
// SRC0 keys: "a_XXXXXXX" (sort before SRC1)
// SRC1 keys: "b_XXXXXXX" (sort after SRC0), no overlap → merge_dropped = 0
//
// Constraints respected:
//   STAGE4_MAX_BLOCK_BYTES = 4096  → source block_size = 1500
//   STAGE5_MAX_BLOCK_BYTES = 4096  → merged output per pair < 4096
//   MAX_INDEX_BYTES         = 8192 → max ~280 blocks per SSTable
//   MERGE_MAX_VALUE_BYTES   = 1024 → value_size = 48
//
// Build:
//   g++ -std=c++17 -I/home/yh/pp4/leveldb/include -I/home/yh/pp4/leveldb \
//       -o gen_real_sstable_gb gen_real_sstable_gb.cc \
//       /home/yh/pp4/leveldb/build_bench/libleveldb.a -lpthread

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "leveldb/env.h"
#include "leveldb/options.h"
#include "leveldb/table_builder.h"
#include "db/dbformat.h"
#include "util/coding.h"

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
                             int block_size) {
    leveldb::Env* env = leveldb::Env::Default();
    leveldb::WritableFile* file;
    leveldb::Status s = env->NewWritableFile(path, &file);
    if (!s.ok()) { fprintf(stderr, "Cannot create %s: %s\n", path.c_str(), s.ToString().c_str()); return 0; }

    leveldb::Options opts;
    opts.compression = leveldb::kNoCompression;
    opts.block_size = block_size;
    opts.block_restart_interval = 16;

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

int main(int argc, char** argv) {
    int n_blocks = 200;
    int records_per_block = 20;
    int value_size = 48;
    int block_size = 1500;
    const char* outdir = "fixtures_gb";

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--blocks") && i+1 < argc) n_blocks = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rpb") && i+1 < argc) records_per_block = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--vsize") && i+1 < argc) value_size = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--bsize") && i+1 < argc) block_size = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--outdir") && i+1 < argc) outdir = argv[++i];
        else if (!strcmp(argv[i], "-h")) {
            printf("Usage: %s [--blocks N] [--rpb N] [--vsize N] [--bsize N] [--outdir DIR]\n", argv[0]);
            return 0;
        }
    }

    printf("Generating: %d blocks × %d records, value=%dB, block_size=%d\n",
           n_blocks, records_per_block, value_size, block_size);

    std::string cmd = std::string("mkdir -p ") + outdir;
    system(cmd.c_str());

    // Value template
    std::string val_template(value_size, 'V');

    // SRC0: keys "a_XXXXXXX", seq descending from 100000
    std::vector<std::vector<KVRecord>> src0_blocks;
    int total_src0 = 0;
    for (int b = 0; b < n_blocks; b++) {
        std::vector<KVRecord> blk;
        for (int r = 0; r < records_per_block; r++) {
            int idx = b * records_per_block + r;
            char uk[32]; snprintf(uk, sizeof(uk), "a_%07d", idx);
            // Fill value with index-dependent data
            std::string val = val_template;
            snprintf(&val[0], std::min((int)val.size(), 16), "s0v_%07d", idx);
            blk.push_back({MakeInternalKey(uk, 100000 - idx), val});
            total_src0++;
        }
        src0_blocks.push_back(blk);
    }

    // SRC1: keys "b_XXXXXXX", seq descending from 100000, NO overlap with SRC0
    std::vector<std::vector<KVRecord>> src1_blocks;
    int total_src1 = 0;
    for (int b = 0; b < n_blocks; b++) {
        std::vector<KVRecord> blk;
        for (int r = 0; r < records_per_block; r++) {
            int idx = b * records_per_block + r;
            char uk[32]; snprintf(uk, sizeof(uk), "b_%07d", idx);
            std::string val = val_template;
            snprintf(&val[0], std::min((int)val.size(), 16), "s1v_%07d", idx);
            blk.push_back({MakeInternalKey(uk, 100000 - idx), val});
            total_src1++;
        }
        src1_blocks.push_back(blk);
    }

    std::string src0_path = std::string(outdir) + "/src0_gb.sst";
    std::string src1_path = std::string(outdir) + "/src1_gb.sst";

    uint64_t src0_size = WriteSSTable(src0_path, src0_blocks, block_size);
    uint64_t src1_size = WriteSSTable(src1_path, src1_blocks, block_size);
    if (!src0_size || !src1_size) return 1;

    int total_decoded = total_src0 + total_src1;
    printf("\nSRC0: %s  %lu bytes, %d blocks, %d records\n", src0_path.c_str(), src0_size, n_blocks, total_src0);
    printf("SRC1: %s  %lu bytes, %d blocks, %d records\n", src1_path.c_str(), src1_size, n_blocks, total_src1);
    printf("Per-run input: %.1f KB\n", (src0_size + src1_size) / 1024.0);
    printf("Expected: pairs=%d decoded=%d merged=%d dropped=0\n", n_blocks, total_decoded, total_decoded);

    // Write info file
    std::string info_path = std::string(outdir) + "/gb_sstable_info.txt";
    FILE* f = fopen(info_path.c_str(), "w");
    fprintf(f, "src0_path=%s\nsrc1_path=%s\n", src0_path.c_str(), src1_path.c_str());
    fprintf(f, "src0_size=%lu\nsrc1_size=%lu\n", src0_size, src1_size);
    fprintf(f, "n_blocks=%d\nsrc0_records=%d\nsrc1_records=%d\n", n_blocks, total_src0, total_src1);
    fprintf(f, "expected_pairs=%d\nexpected_decoded=%d\nexpected_merged=%d\nexpected_dropped=0\n",
            n_blocks, total_decoded, total_decoded);
    fclose(f);
    return 0;
}
