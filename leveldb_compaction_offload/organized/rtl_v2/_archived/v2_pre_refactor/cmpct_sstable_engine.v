`timescale 1ns / 1ps

// stage4_real_internal_key_two_way_merge_stage5_sstable_engine_top
//
// Top-level module for full SSTable-aware compaction offload.
//
// Two sstable_data_block_handle_emitter instances parse SRC0 and SRC1
// SSTables in parallel to extract data-block handles.  Once both parsers
// finish, block_pair_count = min(src0_count, src1_count) and the existing
// nblock engine runs the merge + Stage5 pipeline over matched block pairs.
//
// AXI interface layout:
//   m_axi_p0  – read-only, SRC0 SSTable parser
//   m_axi_p1  – read-only, SRC1 SSTable parser
//   m_axi_src0 / m_axi_src1 / m_axi_chain  – nblock engine (pass-through)
//
module stage4_real_internal_key_two_way_merge_stage5_sstable_engine_top #(
    parameter integer AXI_ADDR_WIDTH           = 64,
    parameter integer AXI_DATA_WIDTH           = 512,
    parameter integer AXI_ID_WIDTH             = 1,
    parameter integer MAX_BURST_LEN            = 16,
    parameter integer MAX_INDEX_BYTES          = 8192,
    parameter integer MAX_BLOCK_PAIRS          = 8,
    parameter integer STAGE4_MAX_BLOCK_BYTES   = 4096,
    parameter integer STAGE4_MAX_KEY_BYTES     = 264,
    parameter integer MERGE_MAX_USER_KEY_BYTES = 256,
    parameter integer MERGE_MAX_KEY_BYTES      = 264,
    parameter integer MERGE_MAX_VALUE_BYTES    = 1024,
    parameter integer MERGE_MAX_RECORD_BYTES   = 2048,
    parameter integer MERGE_MAX_RECORDS        = 256,
    parameter integer MERGE_MAX_OUTPUT_BYTES   = 73728,
    parameter integer STAGE5_MAX_RECORDS       = 256,
    parameter integer STAGE5_MAX_PAYLOAD_BYTES = 4096,
    parameter integer STAGE5_MAX_BLOCK_BYTES   = 4096,
    parameter integer STAGE5_MAX_KEY_BYTES     = 256,
    parameter integer STAGE5_MAX_VALUE_BYTES   = 1024,
    parameter integer STAGE5_RESTART_INTERVAL  = 16,
    parameter integer MAX_SSTABLES              = 8,
    parameter integer SPLIT_TAIL_MARGIN         = 4096
) (
    input  wire                          clk,
    input  wire                          rstn,
    input  wire                          clear,
    input  wire                          start,
    input  wire [31:0]                   max_file_size,

    // SSTable locations in DDR
    input  wire [AXI_ADDR_WIDTH-1:0]     src0_sstable_base,
    input  wire [31:0]                   src0_sstable_size,
    input  wire [AXI_ADDR_WIDTH-1:0]     src1_sstable_base,
    input  wire [31:0]                   src1_sstable_size,

    // DST/MID base addresses (per-block DST addresses computed internally)
    input  wire [AXI_ADDR_WIDTH-1:0]     dst_base_addr,   // base for output blocks
    input  wire [31:0]                   dst_block_stride, // bytes per output slot
    input  wire [AXI_ADDR_WIDTH-1:0]     mid_base_addr,

    output reg                           busy,
    output reg                           done,
    output reg                           error,

    // How many block pairs were actually processed
    output wire [31:0]                   block_pair_count_out,
    output wire [MAX_BLOCK_PAIRS*32-1:0] dst_output_block_bytes_vec,

    // Aggregate counters (pass-through from nblock)
    output wire [31:0]                   total_src0_decoded,
    output wire [31:0]                   total_src1_decoded,
    output wire [31:0]                   total_src0_bytes_read,
    output wire [31:0]                   total_src1_bytes_read,
    output wire [31:0]                   total_merge_output_bytes,
    output wire [31:0]                   total_merge_decoded_records,
    output wire [31:0]                   total_merge_merged_records,
    output wire [31:0]                   total_merge_dropped_records,
    output wire [31:0]                   total_stage5_input_records,
    output wire [31:0]                   total_stage5_encoded_entries,
    output wire [31:0]                   total_stage5_output_block_bytes,
    output wire [31:0]                   total_stage5_bytes_written,
    output wire [31:0]                   sstable_count,
    output wire [MAX_SSTABLES*32-1:0]    sstable_sizes_vec,

    // Parser0 AXI read port
    output wire [AXI_ADDR_WIDTH-1:0]     m_axi_p0_araddr,
    output wire [7:0]                    m_axi_p0_arlen,
    output wire [2:0]                    m_axi_p0_arsize,
    output wire [1:0]                    m_axi_p0_arburst,
    output wire                          m_axi_p0_arvalid,
    input  wire                          m_axi_p0_arready,
    input  wire [AXI_DATA_WIDTH-1:0]     m_axi_p0_rdata,
    input  wire [1:0]                    m_axi_p0_rresp,
    input  wire                          m_axi_p0_rlast,
    input  wire                          m_axi_p0_rvalid,
    output wire                          m_axi_p0_rready,

    // Parser1 AXI read port
    output wire [AXI_ADDR_WIDTH-1:0]     m_axi_p1_araddr,
    output wire [7:0]                    m_axi_p1_arlen,
    output wire [2:0]                    m_axi_p1_arsize,
    output wire [1:0]                    m_axi_p1_arburst,
    output wire                          m_axi_p1_arvalid,
    input  wire                          m_axi_p1_arready,
    input  wire [AXI_DATA_WIDTH-1:0]     m_axi_p1_rdata,
    input  wire [1:0]                    m_axi_p1_rresp,
    input  wire                          m_axi_p1_rlast,
    input  wire                          m_axi_p1_rvalid,
    output wire                          m_axi_p1_rready,

    // nblock engine SRC0 AXI read port
    output wire [AXI_ADDR_WIDTH-1:0]     m_axi_src0_araddr,
    output wire [7:0]                    m_axi_src0_arlen,
    output wire [2:0]                    m_axi_src0_arsize,
    output wire [1:0]                    m_axi_src0_arburst,
    output wire                          m_axi_src0_arvalid,
    input  wire                          m_axi_src0_arready,
    input  wire [AXI_DATA_WIDTH-1:0]     m_axi_src0_rdata,
    input  wire [1:0]                    m_axi_src0_rresp,
    input  wire                          m_axi_src0_rlast,
    input  wire                          m_axi_src0_rvalid,
    output wire                          m_axi_src0_rready,

    // nblock engine SRC1 AXI read port
    output wire [AXI_ADDR_WIDTH-1:0]     m_axi_src1_araddr,
    output wire [7:0]                    m_axi_src1_arlen,
    output wire [2:0]                    m_axi_src1_arsize,
    output wire [1:0]                    m_axi_src1_arburst,
    output wire                          m_axi_src1_arvalid,
    input  wire                          m_axi_src1_arready,
    input  wire [AXI_DATA_WIDTH-1:0]     m_axi_src1_rdata,
    input  wire [1:0]                    m_axi_src1_rresp,
    input  wire                          m_axi_src1_rlast,
    input  wire                          m_axi_src1_rvalid,
    output wire                          m_axi_src1_rready,

    // nblock engine chain AXI port (R/W)
    output wire [AXI_ADDR_WIDTH-1:0]     m_axi_chain_araddr,
    output wire [7:0]                    m_axi_chain_arlen,
    output wire [2:0]                    m_axi_chain_arsize,
    output wire [1:0]                    m_axi_chain_arburst,
    output wire                          m_axi_chain_arvalid,
    input  wire                          m_axi_chain_arready,
    input  wire [AXI_DATA_WIDTH-1:0]     m_axi_chain_rdata,
    input  wire [1:0]                    m_axi_chain_rresp,
    input  wire                          m_axi_chain_rlast,
    input  wire                          m_axi_chain_rvalid,
    output wire                          m_axi_chain_rready,
    output wire [AXI_ADDR_WIDTH-1:0]     m_axi_chain_awaddr,
    output wire [7:0]                    m_axi_chain_awlen,
    output wire [2:0]                    m_axi_chain_awsize,
    output wire [1:0]                    m_axi_chain_awburst,
    output wire                          m_axi_chain_awvalid,
    input  wire                          m_axi_chain_awready,
    output wire [AXI_DATA_WIDTH-1:0]     m_axi_chain_wdata,
    output wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_chain_wstrb,
    output wire                          m_axi_chain_wlast,
    output wire                          m_axi_chain_wvalid,
    input  wire                          m_axi_chain_wready,
    input  wire [1:0]                    m_axi_chain_bresp,
    input  wire                          m_axi_chain_bvalid,
    output wire                          m_axi_chain_bready
);

    // -----------------------------------------------------------------------
    // Parser instances  (OPT-P1a: with streaming handle output)
    // -----------------------------------------------------------------------
    reg  p0_clear_r, p0_start_r;
    reg  p1_clear_r, p1_start_r;

    wire        p0_busy, p0_done, p0_error;
    wire [31:0] p0_count;
    wire [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] p0_addr_vec;
    wire [MAX_BLOCK_PAIRS*32-1:0]             p0_size_vec;
    wire                          p0_handle_valid;
    wire                          p0_handle_ready;
    wire [AXI_ADDR_WIDTH-1:0]     p0_handle_addr;
    wire [31:0]                   p0_handle_size;
    wire                          p0_all_done;

    wire        p1_busy, p1_done, p1_error;
    wire [31:0] p1_count;
    wire [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] p1_addr_vec;
    wire [MAX_BLOCK_PAIRS*32-1:0]             p1_size_vec;
    wire                          p1_handle_valid;
    wire                          p1_handle_ready;
    wire [AXI_ADDR_WIDTH-1:0]     p1_handle_addr;
    wire [31:0]                   p1_handle_size;
    wire                          p1_all_done;

    sstable_data_block_handle_emitter #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .MAX_INDEX_BYTES(MAX_INDEX_BYTES),
        .MAX_BLOCK_HANDLES(MAX_BLOCK_PAIRS)
    ) u_parser0 (
        .clk(clk), .rstn(rstn),
        .clear(p0_clear_r), .start(p0_start_r),
        .sstable_base_addr(src0_sstable_base),
        .sstable_size(src0_sstable_size),
        .busy(p0_busy), .done(p0_done), .error(p0_error),
        .block_handle_count(p0_count),
        .block_addr_vec(p0_addr_vec), .block_size_vec(p0_size_vec),
        .m_handle_valid(p0_handle_valid),
        .m_handle_ready(p0_handle_ready),
        .m_handle_addr(p0_handle_addr),
        .m_handle_size(p0_handle_size),
        .all_handles_done(p0_all_done),
        .m_axi_araddr(m_axi_p0_araddr), .m_axi_arlen(m_axi_p0_arlen),
        .m_axi_arsize(m_axi_p0_arsize), .m_axi_arburst(m_axi_p0_arburst),
        .m_axi_arvalid(m_axi_p0_arvalid), .m_axi_arready(m_axi_p0_arready),
        .m_axi_rdata(m_axi_p0_rdata), .m_axi_rresp(m_axi_p0_rresp),
        .m_axi_rlast(m_axi_p0_rlast), .m_axi_rvalid(m_axi_p0_rvalid),
        .m_axi_rready(m_axi_p0_rready)
    );

    sstable_data_block_handle_emitter #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .MAX_INDEX_BYTES(MAX_INDEX_BYTES),
        .MAX_BLOCK_HANDLES(MAX_BLOCK_PAIRS)
    ) u_parser1 (
        .clk(clk), .rstn(rstn),
        .clear(p1_clear_r), .start(p1_start_r),
        .sstable_base_addr(src1_sstable_base),
        .sstable_size(src1_sstable_size),
        .busy(p1_busy), .done(p1_done), .error(p1_error),
        .block_handle_count(p1_count),
        .block_addr_vec(p1_addr_vec), .block_size_vec(p1_size_vec),
        .m_handle_valid(p1_handle_valid),
        .m_handle_ready(p1_handle_ready),
        .m_handle_addr(p1_handle_addr),
        .m_handle_size(p1_handle_size),
        .all_handles_done(p1_all_done),
        .m_axi_araddr(m_axi_p1_araddr), .m_axi_arlen(m_axi_p1_arlen),
        .m_axi_arsize(m_axi_p1_arsize), .m_axi_arburst(m_axi_p1_arburst),
        .m_axi_arvalid(m_axi_p1_arvalid), .m_axi_arready(m_axi_p1_arready),
        .m_axi_rdata(m_axi_p1_rdata), .m_axi_rresp(m_axi_p1_rresp),
        .m_axi_rlast(m_axi_p1_rlast), .m_axi_rvalid(m_axi_p1_rvalid),
        .m_axi_rready(m_axi_p1_rready)
    );

    // -----------------------------------------------------------------------
    // OPT-P1b: Descriptor pair matcher
    // -----------------------------------------------------------------------
    reg         matcher_clear_r, matcher_start_r;
    wire        matcher_busy, matcher_done;
    wire [31:0] matcher_pair_count;

    wire                      desc_valid;
    wire                      desc_ready;
    wire [AXI_ADDR_WIDTH-1:0] desc_src0_addr;
    wire [31:0]               desc_src0_size;
    wire [AXI_ADDR_WIDTH-1:0] desc_src1_addr;
    wire [31:0]               desc_src1_size;
    wire                      desc_last;

    desc_pair_matcher #(
        .ADDR_WIDTH(AXI_ADDR_WIDTH)
    ) u_matcher (
        .clk(clk), .rstn(rstn),
        .clear(matcher_clear_r), .start(matcher_start_r),
        .s0_handle_valid(p0_handle_valid),
        .s0_handle_ready(p0_handle_ready),
        .s0_handle_addr(p0_handle_addr),
        .s0_handle_size(p0_handle_size),
        .s0_all_done(p0_all_done),
        .s1_handle_valid(p1_handle_valid),
        .s1_handle_ready(p1_handle_ready),
        .s1_handle_addr(p1_handle_addr),
        .s1_handle_size(p1_handle_size),
        .s1_all_done(p1_all_done),
        .m_desc_valid(desc_valid),
        .m_desc_ready(desc_ready),
        .m_desc_src0_addr(desc_src0_addr),
        .m_desc_src0_size(desc_src0_size),
        .m_desc_src1_addr(desc_src1_addr),
        .m_desc_src1_size(desc_src1_size),
        .m_desc_last(desc_last),
        .busy(matcher_busy),
        .done(matcher_done),
        .pair_count(matcher_pair_count)
    );

    // -----------------------------------------------------------------------
    // nblock engine  (OPT-P1c: USE_DESC_STREAM=1)
    // -----------------------------------------------------------------------
    reg  nb_clear_r;
    reg  nb_start_r;
    wire nb_busy, nb_done, nb_error;
    wire [31:0] nb_blocks_completed;

    stage4_real_internal_key_two_way_merge_stage5_nblock_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .STAGE4_MAX_BLOCK_BYTES(STAGE4_MAX_BLOCK_BYTES),
        .STAGE4_MAX_KEY_BYTES(STAGE4_MAX_KEY_BYTES),
        .MERGE_MAX_USER_KEY_BYTES(MERGE_MAX_USER_KEY_BYTES),
        .MERGE_MAX_KEY_BYTES(MERGE_MAX_KEY_BYTES),
        .MERGE_MAX_VALUE_BYTES(MERGE_MAX_VALUE_BYTES),
        .MERGE_MAX_RECORD_BYTES(MERGE_MAX_RECORD_BYTES),
        .MERGE_MAX_RECORDS(MERGE_MAX_RECORDS),
        .MERGE_MAX_OUTPUT_BYTES(MERGE_MAX_OUTPUT_BYTES),
        .STAGE5_MAX_RECORDS(STAGE5_MAX_RECORDS),
        .STAGE5_MAX_PAYLOAD_BYTES(STAGE5_MAX_PAYLOAD_BYTES),
        .STAGE5_MAX_BLOCK_BYTES(STAGE5_MAX_BLOCK_BYTES),
        .STAGE5_MAX_KEY_BYTES(STAGE5_MAX_KEY_BYTES),
        .STAGE5_MAX_VALUE_BYTES(STAGE5_MAX_VALUE_BYTES),
        .STAGE5_RESTART_INTERVAL(STAGE5_RESTART_INTERVAL),
        .MAX_BLOCK_PAIRS(MAX_BLOCK_PAIRS),
        .MAX_SSTABLES(MAX_SSTABLES),
        .SPLIT_TAIL_MARGIN(SPLIT_TAIL_MARGIN),
        .USE_DESC_STREAM(1)
    ) u_nblock (
        .clk(clk), .rstn(rstn),
        .clear(nb_clear_r), .start(nb_start_r),
        .max_file_size(max_file_size),
        // Vector ports (unused in streaming mode, tie off)
        .block_pair_count(32'd0),
        .src0_base_addr_vec({(MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH){1'b0}}),
        .src0_byte_count_vec({(MAX_BLOCK_PAIRS*32){1'b0}}),
        .src1_base_addr_vec({(MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH){1'b0}}),
        .src1_byte_count_vec({(MAX_BLOCK_PAIRS*32){1'b0}}),
        .dst_base_addr(dst_base_addr),
        .mid_base_addr(mid_base_addr),
        // Streaming descriptor input from matcher
        .desc_valid(desc_valid),
        .desc_ready(desc_ready),
        .desc_src0_addr(desc_src0_addr),
        .desc_src0_size(desc_src0_size),
        .desc_src1_addr(desc_src1_addr),
        .desc_src1_size(desc_src1_size),
        .desc_last(desc_last),
        .busy(nb_busy), .done(nb_done), .error(nb_error),
        .active_block_index(), .blocks_completed(nb_blocks_completed),
        .sstable_total_bytes(),
        .sstable_count(sstable_count),
        .sstable_sizes_vec(sstable_sizes_vec),
        .dst_output_block_bytes_vec(dst_output_block_bytes_vec),
        .total_source0_decoded_entry_count(total_src0_decoded),
        .total_source1_decoded_entry_count(total_src1_decoded),
        .total_source0_bytes_read(total_src0_bytes_read),
        .total_source1_bytes_read(total_src1_bytes_read),
        .total_merge_output_byte_count(total_merge_output_bytes),
        .total_merge_decoded_record_count(total_merge_decoded_records),
        .total_merge_merged_record_count(total_merge_merged_records),
        .total_merge_dropped_superseded_count(total_merge_dropped_records),
        .total_stage5_input_record_count(total_stage5_input_records),
        .total_stage5_encoded_entry_count(total_stage5_encoded_entries),
        .total_stage5_output_block_bytes(total_stage5_output_block_bytes),
        .total_stage5_bytes_written(total_stage5_bytes_written),
        .m_axi_src0_araddr(m_axi_src0_araddr),
        .m_axi_src0_arlen(m_axi_src0_arlen),
        .m_axi_src0_arsize(m_axi_src0_arsize),
        .m_axi_src0_arburst(m_axi_src0_arburst),
        .m_axi_src0_arvalid(m_axi_src0_arvalid),
        .m_axi_src0_arready(m_axi_src0_arready),
        .m_axi_src0_rdata(m_axi_src0_rdata),
        .m_axi_src0_rresp(m_axi_src0_rresp),
        .m_axi_src0_rlast(m_axi_src0_rlast),
        .m_axi_src0_rvalid(m_axi_src0_rvalid),
        .m_axi_src0_rready(m_axi_src0_rready),
        .m_axi_src1_araddr(m_axi_src1_araddr),
        .m_axi_src1_arlen(m_axi_src1_arlen),
        .m_axi_src1_arsize(m_axi_src1_arsize),
        .m_axi_src1_arburst(m_axi_src1_arburst),
        .m_axi_src1_arvalid(m_axi_src1_arvalid),
        .m_axi_src1_arready(m_axi_src1_arready),
        .m_axi_src1_rdata(m_axi_src1_rdata),
        .m_axi_src1_rresp(m_axi_src1_rresp),
        .m_axi_src1_rlast(m_axi_src1_rlast),
        .m_axi_src1_rvalid(m_axi_src1_rvalid),
        .m_axi_src1_rready(m_axi_src1_rready),
        .m_axi_chain_araddr(m_axi_chain_araddr),
        .m_axi_chain_arlen(m_axi_chain_arlen),
        .m_axi_chain_arsize(m_axi_chain_arsize),
        .m_axi_chain_arburst(m_axi_chain_arburst),
        .m_axi_chain_arvalid(m_axi_chain_arvalid),
        .m_axi_chain_arready(m_axi_chain_arready),
        .m_axi_chain_rdata(m_axi_chain_rdata),
        .m_axi_chain_rresp(m_axi_chain_rresp),
        .m_axi_chain_rlast(m_axi_chain_rlast),
        .m_axi_chain_rvalid(m_axi_chain_rvalid),
        .m_axi_chain_rready(m_axi_chain_rready),
        .m_axi_chain_awaddr(m_axi_chain_awaddr),
        .m_axi_chain_awlen(m_axi_chain_awlen),
        .m_axi_chain_awsize(m_axi_chain_awsize),
        .m_axi_chain_awburst(m_axi_chain_awburst),
        .m_axi_chain_awvalid(m_axi_chain_awvalid),
        .m_axi_chain_awready(m_axi_chain_awready),
        .m_axi_chain_wdata(m_axi_chain_wdata),
        .m_axi_chain_wstrb(m_axi_chain_wstrb),
        .m_axi_chain_wlast(m_axi_chain_wlast),
        .m_axi_chain_wvalid(m_axi_chain_wvalid),
        .m_axi_chain_wready(m_axi_chain_wready),
        .m_axi_chain_bresp(m_axi_chain_bresp),
        .m_axi_chain_bvalid(m_axi_chain_bvalid),
        .m_axi_chain_bready(m_axi_chain_bready)
    );

    // -----------------------------------------------------------------------
    // Top-level FSM  (OPT-P1d: streaming pipeline)
    //   IDLE → CLEAR_ALL → START_ALL → WAIT_NB → IDLE
    //   All sub-modules start concurrently; parsers feed matcher which
    //   feeds nblock via streaming descriptors.
    // -----------------------------------------------------------------------
    localparam [1:0] TS_IDLE      = 2'd0;
    localparam [1:0] TS_CLEAR_ALL = 2'd1;
    localparam [1:0] TS_START_ALL = 2'd2;
    localparam [1:0] TS_WAIT_NB   = 2'd3;

    reg [1:0] ts;

    assign block_pair_count_out = nb_blocks_completed;

    always @(posedge clk) begin
        if (!rstn) begin
            ts             <= TS_IDLE;
            busy           <= 1'b0;
            done           <= 1'b0;
            error          <= 1'b0;
            p0_clear_r     <= 1'b0;
            p0_start_r     <= 1'b0;
            p1_clear_r     <= 1'b0;
            p1_start_r     <= 1'b0;
            matcher_clear_r <= 1'b0;
            matcher_start_r <= 1'b0;
            nb_clear_r     <= 1'b0;
            nb_start_r     <= 1'b0;
        end else if (clear) begin
            ts             <= TS_IDLE;
            busy           <= 1'b0;
            done           <= 1'b0;
            error          <= 1'b0;
            p0_clear_r     <= 1'b1;
            p0_start_r     <= 1'b0;
            p1_clear_r     <= 1'b1;
            p1_start_r     <= 1'b0;
            matcher_clear_r <= 1'b1;
            matcher_start_r <= 1'b0;
            nb_clear_r     <= 1'b1;
            nb_start_r     <= 1'b0;
        end else begin
            p0_clear_r      <= 1'b0;
            p0_start_r      <= 1'b0;
            p1_clear_r      <= 1'b0;
            p1_start_r      <= 1'b0;
            matcher_clear_r <= 1'b0;
            matcher_start_r <= 1'b0;
            nb_clear_r      <= 1'b0;
            nb_start_r      <= 1'b0;
            done            <= 1'b0;

            case (ts)

                TS_IDLE: begin
                    if (start && !busy) begin
                        busy            <= 1'b1;
                        error           <= 1'b0;
                        // Clear all sub-modules
                        p0_clear_r      <= 1'b1;
                        p1_clear_r      <= 1'b1;
                        matcher_clear_r <= 1'b1;
                        nb_clear_r      <= 1'b1;
                        ts              <= TS_CLEAR_ALL;
                    end
                end

                TS_CLEAR_ALL: begin
                    // One cycle after clear: start all sub-modules
                    p0_start_r      <= 1'b1;
                    p1_start_r      <= 1'b1;
                    matcher_start_r <= 1'b1;
                    nb_start_r      <= 1'b1;
                    ts              <= TS_START_ALL;
                end

                TS_START_ALL: begin
                    // Wait one cycle for starts to take effect
                    ts <= TS_WAIT_NB;
                end

                TS_WAIT_NB: begin
                    // Monitor for errors and nblock completion
                    if (p0_error || p1_error || nb_error) begin
                        error <= 1'b1;
                        busy  <= 1'b0;
                        ts    <= TS_IDLE;
                    end else if (nb_done) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        ts   <= TS_IDLE;
                    end
                end

                default: begin
                    ts <= TS_IDLE;
                end

            endcase
        end
    end

endmodule
