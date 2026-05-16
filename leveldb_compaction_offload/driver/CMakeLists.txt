cmake_minimum_required(VERSION 3.10)

# ---------------------------------------------------------------------------
# compaction_offload_driver  –  FPGA SSTable compaction offload driver
#
# This library must be linked into the same binary as LevelDB.
# Build the patched LevelDB with:
#   cmake -DCMPCT_OFFLOAD_ENABLED=ON <leveldb_src>
# ---------------------------------------------------------------------------

add_library(compaction_offload_driver STATIC
    xdma_access.cc
    compaction_offload.cc
)

target_include_directories(compaction_offload_driver PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_compile_features(compaction_offload_driver PUBLIC cxx_std_14)

# ---------------------------------------------------------------------------
# Integrate into LevelDB build
# ---------------------------------------------------------------------------
# In the LevelDB CMakeLists.txt, add these two lines:
#
#   option(CMPCT_OFFLOAD_ENABLED "Enable FPGA compaction offload" OFF)
#   if(CMPCT_OFFLOAD_ENABLED)
#     target_compile_definitions(leveldb PUBLIC CMPCT_OFFLOAD_ENABLED)
#     add_subdirectory(
#         ${CMAKE_SOURCE_DIR}/../../leveldb_compaction_offload/driver
#         ${CMAKE_BINARY_DIR}/compaction_offload_driver)
#     target_link_libraries(leveldb compaction_offload_driver)
#   endif()
