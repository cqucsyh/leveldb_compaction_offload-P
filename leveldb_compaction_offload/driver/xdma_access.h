// xdma_access.h
// Low-level XDMA device access:  register R/W (AXI-Lite user BAR) + H2C/C2H DMA.
//
// XDMA kernel driver exposes:
//   /dev/xdma0_user    – mmap/pread/pwrite at offset = AXI-Lite byte address
//   /dev/xdma0_h2c_0   – pwrite at offset = DDR byte address  (host→card)
//   /dev/xdma0_c2h_0   – pread  at offset = DDR byte address  (card→host)
//
// All functions are synchronous and single-threaded; the caller is responsible
// for serialisation when multiple threads share the same XdmaAccess instance.

#pragma once

#include <cstdint>
#include <string>

class XdmaAccess {
 public:
  XdmaAccess(const std::string& h2c_dev,
             const std::string& c2h_dev,
             const std::string& user_dev);
  ~XdmaAccess();

  // Open all three device files.  Returns true on success.
  bool Open();
  void Close();
  bool IsOpen() const { return h2c_fd_ >= 0; }

  // AXI-Lite 32-bit register access via user BAR.
  // abs_addr = axil_base + reg_offset (byte address in BAR).
  bool WriteReg(uint64_t abs_addr, uint32_t value);
  bool ReadReg(uint64_t abs_addr, uint32_t* value);

  // DMA transfers.  ddr_addr = destination/source DDR byte address.
  // Uses pwrite / pread; chunked automatically for large transfers.
  bool DmaToDevice(uint64_t ddr_addr, const void* data, size_t size);
  bool DmaFromDevice(uint64_t ddr_addr, void* data, size_t size);

  // Human-readable description of the last error.
  std::string GetError() const { return last_error_; }

 private:
  std::string h2c_dev_, c2h_dev_, user_dev_;
  int h2c_fd_, c2h_fd_, user_fd_;
  std::string last_error_;

  void SetError(const std::string& msg);
};
