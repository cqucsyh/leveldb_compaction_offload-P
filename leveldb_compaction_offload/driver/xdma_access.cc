// xdma_access.cc

#include "xdma_access.h"

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

static constexpr size_t kDmaChunk = 4 * 1024 * 1024;  // 4 MB per pwrite/pread

XdmaAccess::XdmaAccess(const std::string& h2c_dev,
                       const std::string& c2h_dev,
                       const std::string& user_dev)
    : h2c_dev_(h2c_dev),
      c2h_dev_(c2h_dev),
      user_dev_(user_dev),
      h2c_fd_(-1),
      c2h_fd_(-1),
      user_fd_(-1) {}

XdmaAccess::~XdmaAccess() { Close(); }

bool XdmaAccess::Open() {
  h2c_fd_ = open(h2c_dev_.c_str(), O_WRONLY);
  if (h2c_fd_ < 0) {
    SetError("open " + h2c_dev_ + ": " + strerror(errno));
    return false;
  }
  c2h_fd_ = open(c2h_dev_.c_str(), O_RDONLY);
  if (c2h_fd_ < 0) {
    SetError("open " + c2h_dev_ + ": " + strerror(errno));
    return false;
  }
  user_fd_ = open(user_dev_.c_str(), O_RDWR);
  if (user_fd_ < 0) {
    SetError("open " + user_dev_ + ": " + strerror(errno));
    return false;
  }
  return true;
}

void XdmaAccess::Close() {
  if (h2c_fd_  >= 0) { close(h2c_fd_);  h2c_fd_  = -1; }
  if (c2h_fd_  >= 0) { close(c2h_fd_);  c2h_fd_  = -1; }
  if (user_fd_ >= 0) { close(user_fd_); user_fd_ = -1; }
}

void XdmaAccess::SetError(const std::string& msg) { last_error_ = msg; }

bool XdmaAccess::WriteReg(uint64_t abs_addr, uint32_t value) {
  ssize_t n = pwrite(user_fd_, &value, 4, static_cast<off_t>(abs_addr));
  if (n != 4) {
    SetError("WriteReg @0x" + std::to_string(abs_addr) + ": " + strerror(errno));
    return false;
  }
  return true;
}

bool XdmaAccess::ReadReg(uint64_t abs_addr, uint32_t* value) {
  ssize_t n = pread(user_fd_, value, 4, static_cast<off_t>(abs_addr));
  if (n != 4) {
    SetError("ReadReg @0x" + std::to_string(abs_addr) + ": " + strerror(errno));
    return false;
  }
  return true;
}

bool XdmaAccess::DmaToDevice(uint64_t ddr_addr, const void* data, size_t size) {
  const uint8_t* p = static_cast<const uint8_t*>(data);
  size_t remaining = size;
  uint64_t addr = ddr_addr;
  while (remaining > 0) {
    size_t chunk = (remaining < kDmaChunk) ? remaining : kDmaChunk;
    ssize_t n = pwrite(h2c_fd_, p, chunk, static_cast<off_t>(addr));
    if (n < 0) {
      SetError("DmaToDevice @0x" + std::to_string(addr) + ": " + strerror(errno));
      return false;
    }
    p         += n;
    addr      += static_cast<uint64_t>(n);
    remaining -= static_cast<size_t>(n);
  }
  return true;
}

bool XdmaAccess::DmaFromDevice(uint64_t ddr_addr, void* data, size_t size) {
  uint8_t* p = static_cast<uint8_t*>(data);
  size_t remaining = size;
  uint64_t addr = ddr_addr;
  while (remaining > 0) {
    size_t chunk = (remaining < kDmaChunk) ? remaining : kDmaChunk;
    ssize_t n = pread(c2h_fd_, p, chunk, static_cast<off_t>(addr));
    if (n < 0) {
      SetError("DmaFromDevice @0x" + std::to_string(addr) + ": " + strerror(errno));
      return false;
    }
    p         += n;
    addr      += static_cast<uint64_t>(n);
    remaining -= static_cast<size_t>(n);
  }
  return true;
}
