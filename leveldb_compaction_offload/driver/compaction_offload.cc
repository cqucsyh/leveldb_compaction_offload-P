// compaction_offload.cc

#include "compaction_offload.h"
#include "xdma_access.h"

#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#include <chrono>
#include <fstream>
#include <vector>

namespace leveldb {

// ---------------------------------------------------------------------------
// Singleton
// ---------------------------------------------------------------------------
CompactionOffloadDriver& CompactionOffloadDriver::Get() {
  static CompactionOffloadDriver instance;
  return instance;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static uint64_t NowMs() {
  using namespace std::chrono;
  return static_cast<uint64_t>(
      duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count());
}

// Read an entire file into a vector.  Returns non-OK on any error.
static Status ReadFile(const std::string& path, std::vector<uint8_t>* out) {
  int fd = open(path.c_str(), O_RDONLY);
  if (fd < 0)
    return Status::IOError(path + ": " + strerror(errno));

  struct stat st;
  if (fstat(fd, &st) < 0) {
    close(fd);
    return Status::IOError(path + " fstat: " + strerror(errno));
  }

  out->resize(static_cast<size_t>(st.st_size));
  size_t remaining = out->size();
  uint8_t* p = out->data();
  while (remaining > 0) {
    ssize_t n = read(fd, p, remaining);
    if (n <= 0) {
      close(fd);
      return Status::IOError(path + " read: " + strerror(errno));
    }
    p         += n;
    remaining -= static_cast<size_t>(n);
  }
  close(fd);
  return Status::OK();
}

// Write bytes to a file, creating it if necessary.
static Status WriteFile(const std::string& path,
                        const uint8_t* data, size_t size) {
  int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0)
    return Status::IOError(path + ": " + strerror(errno));

  size_t remaining = size;
  const uint8_t* p = data;
  while (remaining > 0) {
    ssize_t n = write(fd, p, remaining);
    if (n <= 0) {
      close(fd);
      return Status::IOError(path + " write: " + strerror(errno));
    }
    p         += n;
    remaining -= static_cast<size_t>(n);
  }
  if (fsync(fd) < 0) {
    close(fd);
    return Status::IOError(path + " fsync: " + strerror(errno));
  }
  close(fd);
  return Status::OK();
}

// ---------------------------------------------------------------------------
// LevelDB SSTable magic: 0xdb4775248b80fb57 stored little-endian
// This is the real LevelDB kTableMagicNumber written by the hardware assembler.
// ---------------------------------------------------------------------------
static const uint8_t kMagic[8] = {0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb};

// Scan buf backwards for the magic.  Return offset-past-magic (= SSTable size)
// or 0 if not found.
size_t CompactionOffloadDriver::FindSStableEnd(const uint8_t* buf, size_t len) {
  if (len < 8) return 0;
  // Start from the last possible position and scan backwards.
  // The footer is exactly 48 bytes; magic occupies the last 8 bytes.
  // So the magic is at buf[sstable_size - 8].
  for (size_t i = len; i >= 8; --i) {
    if (memcmp(buf + i - 8, kMagic, 8) == 0) {
      return i;  // bytes [0, i) form the complete SSTable
    }
  }
  return 0;
}

// ---------------------------------------------------------------------------
// CanOffload
// ---------------------------------------------------------------------------
bool CompactionOffloadDriver::CanOffload(uint64_t src0_bytes,
                                         uint64_t src1_bytes) const {
  return src0_bytes <= config_.max_src_bytes &&
         src1_bytes <= config_.max_src_bytes;
}

// ---------------------------------------------------------------------------
// RunOffloadCore — shared engine logic with split support
// ---------------------------------------------------------------------------
Status CompactionOffloadDriver::RunOffloadCore(
    const std::vector<uint8_t>& src0_data,
    const std::vector<uint8_t>& src1_data,
    uint32_t max_file_size,
    std::vector<std::string>* output_sstables) {

  output_sstables->clear();

  // ── 1. Open XDMA devices ─────────────────────────────────────────────────
  XdmaAccess xdma(config_.h2c_dev, config_.c2h_dev, config_.user_dev);
  if (!xdma.Open()) {
    return Status::IOError("XDMA open failed: " + xdma.GetError());
  }

  // ── 2. DMA source SSTables → DDR ────────────────────────────────────────
  if (!xdma.DmaToDevice(config_.src0_ddr_base,
                        src0_data.data(), src0_data.size())) {
    return Status::IOError("DMA SRC0 failed: " + xdma.GetError());
  }
  if (!xdma.DmaToDevice(config_.src1_ddr_base,
                        src1_data.data(), src1_data.size())) {
    return Status::IOError("DMA SRC1 failed: " + xdma.GetError());
  }

  // ── 3. Clear previous hardware state ────────────────────────────────────
  uint64_t base = config_.axil_base;
  xdma.WriteReg(base + kRegCtrl, 0x2);   // CTRL[1] = clear
  usleep(10000);                          // 10 ms settle
  xdma.WriteReg(base + kRegCtrl, 0x0);

  // ── 4. Program AXI-Lite registers ───────────────────────────────────────
  xdma.WriteReg(base + kRegSrc0BaseLo,
                static_cast<uint32_t>(config_.src0_ddr_base & 0xFFFFFFFFU));
  xdma.WriteReg(base + kRegSrc0BaseHi,
                static_cast<uint32_t>(config_.src0_ddr_base >> 32));
  xdma.WriteReg(base + kRegSrc0Size,
                static_cast<uint32_t>(src0_data.size()));

  xdma.WriteReg(base + kRegSrc1BaseLo,
                static_cast<uint32_t>(config_.src1_ddr_base & 0xFFFFFFFFU));
  xdma.WriteReg(base + kRegSrc1BaseHi,
                static_cast<uint32_t>(config_.src1_ddr_base >> 32));
  xdma.WriteReg(base + kRegSrc1Size,
                static_cast<uint32_t>(src1_data.size()));

  xdma.WriteReg(base + kRegDstBaseLo,
                static_cast<uint32_t>(config_.dst_ddr_base & 0xFFFFFFFFU));
  xdma.WriteReg(base + kRegDstBaseHi,
                static_cast<uint32_t>(config_.dst_ddr_base >> 32));
  xdma.WriteReg(base + kRegDstStride, config_.dst_blk_stride);

  xdma.WriteReg(base + kRegMidBaseLo,
                static_cast<uint32_t>(config_.mid_ddr_base & 0xFFFFFFFFU));
  xdma.WriteReg(base + kRegMidBaseHi,
                static_cast<uint32_t>(config_.mid_ddr_base >> 32));

  xdma.WriteReg(base + kRegMaxFileSize, max_file_size);

  // ── 5. Start engine ──────────────────────────────────────────────────────
  xdma.WriteReg(base + kRegCtrl, 0x1);   // CTRL[0] = start

  // ── 6. Poll for completion ───────────────────────────────────────────────
  uint64_t deadline = NowMs() + config_.timeout_ms;
  uint32_t status_reg = 0;
  do {
    usleep(1000);   // 1 ms polling interval
    if (!xdma.ReadReg(base + kRegStatus, &status_reg)) {
      return Status::IOError("ReadReg STATUS failed: " + xdma.GetError());
    }
  } while (!(status_reg & (kStatusDone | kStatusError)) && NowMs() < deadline);

  if (status_reg & kStatusError) {
    return Status::IOError("FPGA engine reported error (STATUS=0x" +
                           std::to_string(status_reg) + ")");
  }
  if (!(status_reg & kStatusDone)) {
    return Status::IOError("FPGA engine timed out after " +
                           std::to_string(config_.timeout_ms) + " ms");
  }

  // ── 7. Read split results from AXI-Lite ─────────────────────────────────
  uint32_t sst_count = 0;
  if (!xdma.ReadReg(base + kRegSstableCount, &sst_count)) {
    return Status::IOError("ReadReg SSTABLE_COUNT failed");
  }
  if (sst_count == 0 || sst_count > kMaxSstables) {
    return Status::Corruption(
        "invalid sstable_count=" + std::to_string(sst_count));
  }

  std::vector<uint32_t> sst_sizes(sst_count);
  for (uint32_t i = 0; i < sst_count; i++) {
    if (!xdma.ReadReg(base + kRegSstableSizesBase + i * 4, &sst_sizes[i])) {
      return Status::IOError("ReadReg SSTABLE_SIZES[" +
                             std::to_string(i) + "] failed");
    }
    if (sst_sizes[i] == 0) {
      return Status::Corruption(
          "sstable_sizes[" + std::to_string(i) + "] is 0");
    }
  }

  // ── 8. DMA back each sub-SSTable ────────────────────────────────────────
  //   In DDR, sub-SSTables are laid out at:
  //     SST[0] @ dst_ddr_base + 0
  //     SST[1] @ dst_ddr_base + align64(sst_sizes[0])
  //     SST[2] @ dst_ddr_base + align64(sst_sizes[0]) + align64(sst_sizes[1])
  //     ...
  uint64_t ddr_offset = 0;
  for (uint32_t i = 0; i < sst_count; i++) {
    uint32_t sz = sst_sizes[i];
    std::string buf(sz, '\0');
    if (!xdma.DmaFromDevice(config_.dst_ddr_base + ddr_offset,
                            reinterpret_cast<uint8_t*>(&buf[0]), sz)) {
      return Status::IOError("DMA DST read SSTable[" +
                             std::to_string(i) + "] failed: " +
                             xdma.GetError());
    }
    output_sstables->push_back(std::move(buf));
    // Advance to next 64-byte aligned boundary
    ddr_offset += (static_cast<uint64_t>(sz) + 63ULL) & ~63ULL;
  }

  return Status::OK();
}

// ---------------------------------------------------------------------------
// RunOffloadSplit — public split-aware API
// ---------------------------------------------------------------------------
Status CompactionOffloadDriver::RunOffloadSplit(
    const std::string& src0_path, uint64_t src0_bytes,
    const std::string& src1_path, uint64_t src1_bytes,
    uint32_t max_file_size,
    std::vector<std::string>* output_sstables) {

  if (!CanOffload(src0_bytes, src1_bytes)) {
    return Status::InvalidArgument("input SSTable too large for hardware offload");
  }

  std::vector<uint8_t> src0_data, src1_data;
  Status s = ReadFile(src0_path, &src0_data);
  if (!s.ok()) return s;
  s = ReadFile(src1_path, &src1_data);
  if (!s.ok()) return s;

  if (src0_data.size() != src0_bytes || src1_data.size() != src1_bytes) {
    return Status::Corruption("SSTable size mismatch after read");
  }

  return RunOffloadCore(src0_data, src1_data, max_file_size, output_sstables);
}

// ---------------------------------------------------------------------------
// RunOffload — backward-compatible single-output wrapper
// ---------------------------------------------------------------------------
Status CompactionOffloadDriver::RunOffload(
    const std::string& src0_path, uint64_t src0_bytes,
    const std::string& src1_path, uint64_t src1_bytes,
    const std::string& out_path,  size_t*  out_size) {

  std::vector<std::string> outputs;
  Status s = RunOffloadSplit(src0_path, src0_bytes,
                             src1_path, src1_bytes,
                             0,  // max_file_size=0 → no split
                             &outputs);
  if (!s.ok()) return s;

  if (outputs.empty()) {
    return Status::Corruption("hardware produced no output SSTables");
  }

  // Concatenation should not happen with max_file_size=0, but use first output.
  const std::string& sst = outputs[0];
  s = WriteFile(out_path,
                reinterpret_cast<const uint8_t*>(sst.data()), sst.size());
  if (!s.ok()) return s;

  *out_size = sst.size();
  return Status::OK();
}

}  // namespace leveldb
