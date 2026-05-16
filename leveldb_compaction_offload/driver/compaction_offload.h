// compaction_offload.h
//
// FPGA-accelerated two-way SSTable compaction offload driver.
//
// Usage (from DBImpl::TryHardwareCompaction):
//   auto& drv = CompactionOffloadDriver::Get();
//   Status s = drv.RunOffload(file0_path, file0_size,
//                             file1_path, file1_size,
//                             out_path, &out_size);
//
// DDR layout (fixed, matches board test scripts):
//   [0x00000000, +1 MB)  SRC0 SSTable
//   [0x00100000, +1 MB)  SRC1 SSTable
//   [0x00200000, +...  )  Output assembled SSTable (DST)
//   [0x00300000, +1 MB)  Scratch (MID)
//
// Hardware constraints (from synthesis parameters):
//   MAX_BLOCK_PAIRS   = 32
//   MAX_SRC_SIZE      = 1 MB per SSTable
//   DST_BLOCK_STRIDE  = 64 KB

#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "leveldb/status.h"

namespace leveldb {

class CompactionOffloadDriver {
 public:
  struct Config {
    std::string h2c_dev         = "/dev/xdma0_h2c_0";
    std::string c2h_dev         = "/dev/xdma0_c2h_0";
    std::string user_dev        = "/dev/xdma0_user";
    uint64_t    src0_ddr_base   = 0x00000000ULL;
    uint64_t    src1_ddr_base   = 0x00100000ULL;
    uint64_t    dst_ddr_base    = 0x00200000ULL;
    uint64_t    mid_ddr_base    = 0x00300000ULL;
    uint32_t    dst_blk_stride  = 0x00010000U;   // 64 KB per output block slot
    uint64_t    axil_base       = 0x00000000ULL;
    uint32_t    timeout_ms      = 30000;
    uint64_t    max_src_bytes   = 0x00100000ULL;  // 1 MB per source SSTable
    size_t      max_out_bytes   = 0x00040000ULL;  // 256 KB read-back buffer
  };

  // Global singleton – thread-safe after initial SetConfig call.
  static CompactionOffloadDriver& Get();

  // Default-constructible: create a standalone instance with custom config.
  // The singleton Get() is the production entry point.
  CompactionOffloadDriver() = default;

  // Override defaults before first use.
  void SetConfig(const Config& cfg) { config_ = cfg; }
  const Config& GetConfig() const { return config_; }

  // Quick eligibility predicate (no I/O).
  // Returns false if the input file sizes exceed hardware limits.
  bool CanOffload(uint64_t src0_bytes, uint64_t src1_bytes) const;

  // Run the full offload pipeline:
  //   1. DMA src0/src1 SSTable files to DDR.
  //   2. Program AXI-Lite registers and start the engine.
  //   3. Poll for completion (up to config_.timeout_ms).
  //   4. DMA back the assembled output SSTable.
  //   5. Write the SSTable to out_path on disk.
  //   6. Return the exact byte size of the written SSTable.
  //
  // On any failure a non-OK status is returned and out_path is left
  // unwritten (the caller can fall back to software compaction).
  Status RunOffload(const std::string& src0_path, uint64_t src0_bytes,
                    const std::string& src1_path, uint64_t src1_bytes,
                    const std::string& out_path,  size_t*  out_size);

  // Split-aware offload: returns one raw SSTable buffer per output SSTable.
  // max_file_size is programmed into REG_MAX_FILE_SIZE (0 = no split).
  // On success, output_sstables contains one std::string per output SSTable.
  Status RunOffloadSplit(const std::string& src0_path, uint64_t src0_bytes,
                         const std::string& src1_path, uint64_t src1_bytes,
                         uint32_t max_file_size,
                         std::vector<std::string>* output_sstables);

  // Scan buf[0..len) backwards for the 8-byte LevelDB SSTable magic.
  // Returns bytes-past-magic (= total SSTable byte count), or 0 if not found.
  static size_t FindSStableEnd(const uint8_t* buf, size_t len);

  static constexpr uint32_t kMaxSstables = 16;

 private:
  Config config_;

  // AXI-Lite register offsets (must match cmpct_sstable_engine_axil_top.v)
  static constexpr uint64_t kRegCtrl       = 0x0000;
  static constexpr uint64_t kRegStatus     = 0x0004;
  static constexpr uint64_t kRegSrc0BaseLo = 0x0008;
  static constexpr uint64_t kRegSrc0BaseHi = 0x000C;
  static constexpr uint64_t kRegSrc0Size   = 0x0010;
  static constexpr uint64_t kRegSrc1BaseLo = 0x0014;
  static constexpr uint64_t kRegSrc1BaseHi = 0x0018;
  static constexpr uint64_t kRegSrc1Size   = 0x001C;
  static constexpr uint64_t kRegDstBaseLo  = 0x0020;
  static constexpr uint64_t kRegDstBaseHi  = 0x0024;
  static constexpr uint64_t kRegDstStride  = 0x0028;
  static constexpr uint64_t kRegMidBaseLo  = 0x002C;
  static constexpr uint64_t kRegMidBaseHi  = 0x0030;
  static constexpr uint64_t kRegMaxFileSize   = 0x0038;
  static constexpr uint64_t kRegSstableCount  = 0x003C;
  static constexpr uint64_t kRegSstableSizesBase = 0x0500;
  // STATUS bits
  static constexpr uint32_t kStatusBusy    = 0x1;
  static constexpr uint32_t kStatusDone    = 0x2;
  static constexpr uint32_t kStatusError   = 0x4;

  // Shared core: DMA sources, program registers, poll, read back results.
  // Returns raw output SSTable buffers.  Called by both RunOffload and
  // RunOffloadSplit.
  Status RunOffloadCore(const std::vector<uint8_t>& src0_data,
                        const std::vector<uint8_t>& src1_data,
                        uint32_t max_file_size,
                        std::vector<std::string>* output_sstables);
};

}  // namespace leveldb
