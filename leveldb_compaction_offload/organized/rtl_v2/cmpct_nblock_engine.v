`timescale 1ns / 1ps

module cmpct_nblock_engine #(
    parameter integer AXI_ADDR_WIDTH              = 64,
    parameter integer AXI_DATA_WIDTH              = 512,
    parameter integer AXI_ID_WIDTH                = 1,
    parameter integer MAX_BURST_LEN               = 16,
    parameter integer STAGE4_MAX_BLOCK_BYTES      = 4096,
    parameter integer STAGE4_MAX_KEY_BYTES        = 72,
    parameter integer MERGE_MAX_USER_KEY_BYTES    = 64,
    parameter integer MERGE_MAX_KEY_BYTES         = 72,
    parameter integer MERGE_MAX_VALUE_BYTES       = 1024,
    parameter integer MERGE_MAX_RECORD_BYTES      = 2048,
    parameter integer MERGE_MAX_RECORDS           = 256,
    parameter integer MERGE_MAX_OUTPUT_BYTES      = 73728,
    parameter integer STAGE5_MAX_RECORDS          = 256,
    parameter integer STAGE5_MAX_PAYLOAD_BYTES    = 4096,
    parameter integer STAGE5_MAX_BLOCK_BYTES      = 4096,
    parameter integer STAGE5_MAX_KEY_BYTES        = 64,
    parameter integer STAGE5_MAX_VALUE_BYTES      = 1024,
    parameter integer STAGE5_RESTART_INTERVAL     = 16,
    parameter integer MAX_BLOCK_PAIRS             = 32,
    parameter integer MAX_SSTABLES                = 16,
    parameter integer SPLIT_TAIL_MARGIN           = 4096,
    parameter integer USE_DESC_STREAM             = 0   // OPT-P1c: 1=streaming descriptors
) (
    input  wire                                      clk,
    input  wire                                      rstn,
    input  wire                                      clear,
    input  wire                                      start,
    input  wire [31:0]                               max_file_size,
    input  wire [31:0]                               block_pair_count,
    input  wire [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] src0_base_addr_vec,
    input  wire [MAX_BLOCK_PAIRS*32-1:0]             src0_byte_count_vec,
    input  wire [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] src1_base_addr_vec,
    input  wire [MAX_BLOCK_PAIRS*32-1:0]             src1_byte_count_vec,
    input  wire [AXI_ADDR_WIDTH-1:0]                 dst_base_addr,
    input  wire [AXI_ADDR_WIDTH-1:0]                 mid_base_addr,

    // OPT-P1c: Streaming descriptor input (used when USE_DESC_STREAM=1)
    input  wire                                      desc_valid,
    output wire                                      desc_ready,
    input  wire [AXI_ADDR_WIDTH-1:0]                 desc_src0_addr,
    input  wire [31:0]                               desc_src0_size,
    input  wire [AXI_ADDR_WIDTH-1:0]                 desc_src1_addr,
    input  wire [31:0]                               desc_src1_size,
    input  wire                                      desc_last,
    output reg                                       busy,
    output reg                                       done,
    output reg                                       error,
    output reg  [31:0]                               active_block_index,
    output reg  [31:0]                               blocks_completed,
    output wire [MAX_BLOCK_PAIRS*32-1:0]             dst_output_block_bytes_vec,
    output reg  [31:0]                               sstable_total_bytes,
    output reg  [31:0]                               sstable_count,
    output wire [MAX_SSTABLES*32-1:0]                sstable_sizes_vec,
    output reg  [31:0]                               total_source0_decoded_entry_count,
    output reg  [31:0]                               total_source1_decoded_entry_count,
    output reg  [31:0]                               total_source0_bytes_read,
    output reg  [31:0]                               total_source1_bytes_read,
    output reg  [31:0]                               total_merge_output_byte_count,
    output reg  [31:0]                               total_merge_decoded_record_count,
    output reg  [31:0]                               total_merge_merged_record_count,
    output reg  [31:0]                               total_merge_dropped_superseded_count,
    output reg  [31:0]                               total_stage5_input_record_count,
    output reg  [31:0]                               total_stage5_encoded_entry_count,
    output reg  [31:0]                               total_stage5_output_block_bytes,
    output reg  [31:0]                               total_stage5_bytes_written,

    output wire [AXI_ADDR_WIDTH-1:0]                 m_axi_src0_araddr,
    output wire [7:0]                                m_axi_src0_arlen,
    output wire [2:0]                                m_axi_src0_arsize,
    output wire [1:0]                                m_axi_src0_arburst,
    output wire                                      m_axi_src0_arvalid,
    input  wire                                      m_axi_src0_arready,
    input  wire [AXI_DATA_WIDTH-1:0]                 m_axi_src0_rdata,
    input  wire [1:0]                                m_axi_src0_rresp,
    input  wire                                      m_axi_src0_rlast,
    input  wire                                      m_axi_src0_rvalid,
    output wire                                      m_axi_src0_rready,

    output wire [AXI_ADDR_WIDTH-1:0]                 m_axi_src1_araddr,
    output wire [7:0]                                m_axi_src1_arlen,
    output wire [2:0]                                m_axi_src1_arsize,
    output wire [1:0]                                m_axi_src1_arburst,
    output wire                                      m_axi_src1_arvalid,
    input  wire                                      m_axi_src1_arready,
    input  wire [AXI_DATA_WIDTH-1:0]                 m_axi_src1_rdata,
    input  wire [1:0]                                m_axi_src1_rresp,
    input  wire                                      m_axi_src1_rlast,
    input  wire                                      m_axi_src1_rvalid,
    output wire                                      m_axi_src1_rready,

    output wire [AXI_ADDR_WIDTH-1:0]                 m_axi_chain_araddr,
    output wire [7:0]                                m_axi_chain_arlen,
    output wire [2:0]                                m_axi_chain_arsize,
    output wire [1:0]                                m_axi_chain_arburst,
    output wire                                      m_axi_chain_arvalid,
    input  wire                                      m_axi_chain_arready,
    input  wire [AXI_DATA_WIDTH-1:0]                 m_axi_chain_rdata,
    input  wire [1:0]                                m_axi_chain_rresp,
    input  wire                                      m_axi_chain_rlast,
    input  wire                                      m_axi_chain_rvalid,
    output wire                                      m_axi_chain_rready,
    output wire [AXI_ADDR_WIDTH-1:0]                 m_axi_chain_awaddr,
    output wire [7:0]                                m_axi_chain_awlen,
    output wire [2:0]                                m_axi_chain_awsize,
    output wire [1:0]                                m_axi_chain_awburst,
    output wire                                      m_axi_chain_awvalid,
    input  wire                                      m_axi_chain_awready,
    output wire [AXI_DATA_WIDTH-1:0]                 m_axi_chain_wdata,
    output wire [(AXI_DATA_WIDTH/8)-1:0]             m_axi_chain_wstrb,
    output wire                                      m_axi_chain_wlast,
    output wire                                      m_axi_chain_wvalid,
    input  wire                                      m_axi_chain_wready,
    input  wire [1:0]                                m_axi_chain_bresp,
    input  wire                                      m_axi_chain_bvalid,
    output wire                                      m_axi_chain_bready
);

    localparam [3:0] ST_IDLE        = 4'd0;
    localparam [3:0] ST_CLEAR       = 4'd1;
    localparam [3:0] ST_START       = 4'd2;
    localparam [3:0] ST_WAIT        = 4'd3;
    localparam [3:0] ST_ASSEMBLE    = 4'd4;
    localparam [3:0] ST_SPLIT_ASM   = 4'd5;
    localparam [3:0] ST_SPLIT_RESET = 4'd6;
    localparam [3:0] ST_POP         = 4'd7;  // OPT-P1c: pop from desc stream
    // OPT-BP1: block-pair pipeline states
    localparam [3:0] ST_WAIT_LAST   = 4'd8;   // wait for wr_done after last pair enc_done
    localparam [3:0] ST_WAIT_SPLIT  = 4'd9;   // wait for wr_done before split-assemble
    // P8: merged ST_PIPE_CLEAR + ST_PIPE_START into single ST_PIPE_RESTART
    localparam [3:0] ST_PIPE_RESTART = 4'd10;  // front-clear + deferred front-start

    reg [3:0] state;
    reg       inner_clear_r;
    reg       inner_start_r;
    reg       inner_done_d;
    reg [31:0] block_pair_count_r;
    // OPT-BP1: front-end only clear/start and pipeline tracking
    reg       inner_front_clear_r;
    reg       inner_front_start_r;
    reg       inner_enc_done_d;
    reg       pipeline_wr_pending;
    reg       pipeline_restart_r;  // for ST_POP → ST_PIPE_RESTART routing
    reg       wr_done_pending;     // OPT-T4-FIX: latch concurrent wr_done when enc_done fires
    // P8: deferred front_start — fires 1 cycle after front_clear
    reg       front_start_pending;
    // P8: descriptor pre-fetch registers
    reg [AXI_ADDR_WIDTH-1:0] next_src0_base_addr_r;
    reg [31:0]               next_src0_byte_count_r;
    reg [AXI_ADDR_WIDTH-1:0] next_src1_base_addr_r;
    reg [31:0]               next_src1_byte_count_r;
    reg                      next_desc_is_last_r;
    reg                      desc_prefetched;

    // OPT-P1c: Registered descriptor values (loaded in ST_POP or ST_CLEAR)
    reg [AXI_ADDR_WIDTH-1:0] current_src0_base_addr_r;
    reg [31:0]               current_src0_byte_count_r;
    reg [AXI_ADDR_WIDTH-1:0] current_src1_base_addr_r;
    reg [31:0]               current_src1_byte_count_r;
    reg                      desc_is_last_r;  // latched desc_last
    reg        seed_prev_user_key_valid_r;
    reg [15:0] seed_prev_user_key_len_r;
    reg [(MERGE_MAX_USER_KEY_BYTES*8)-1:0] seed_prev_user_key_r;
    reg [31:0]                               dst_output_block_bytes_mem [0:MAX_BLOCK_PAIRS-1];
    // Per-block metadata now owned by assembler v2 (written via meta_wr port)
    reg                                      asm_meta_wr_en_r;
    reg [7:0]                                asm_meta_wr_addr_r;
    reg [63:0]                               asm_meta_wr_offset_r;
    reg [31:0]                               asm_meta_wr_size_r;
    reg [15:0]                               asm_meta_wr_keylen_r;
    reg [(STAGE5_MAX_KEY_BYTES*8)-1:0]       asm_meta_wr_keybytes_r;
    reg [63:0]                               running_offset_r;
    reg                                      assemble_mode_r;
    reg                                      asm_start_r;

    // Split-mode state
    reg [31:0]                               max_file_size_r;
    reg [31:0]                               split_threshold_r;
    reg                                      split_enabled_r;
    reg [63:0]                               sst_base_offset_r;
    reg [31:0]                               blocks_in_current_sst_r;
    reg [31:0]                               first_block_of_sst_r;
    reg [31:0]                               sstable_sizes_mem [0:MAX_SSTABLES-1];

    // Assembler AXI write wires
    wire [AXI_ADDR_WIDTH-1:0] asm_awaddr;
    wire [7:0]                asm_awlen;
    wire [2:0]                asm_awsize;
    wire [1:0]                asm_awburst;
    wire                      asm_awvalid;
    wire                      asm_awready_w;
    wire [AXI_DATA_WIDTH-1:0] asm_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] asm_wstrb;
    wire                      asm_wlast;
    wire                      asm_wvalid;
    wire                      asm_wready_w;
    wire [1:0]                asm_bresp;
    wire                      asm_bvalid_w;
    wire                      asm_bready;
    wire                      asm_busy;
    wire                      asm_done;
    wire                      asm_error;
    wire [31:0]               asm_total_bytes;

    // Flatten sstable_sizes_mem for output
    genvar si;
    generate
        for (si = 0; si < MAX_SSTABLES; si = si + 1) begin : g_sst_sizes_vec
            assign sstable_sizes_vec[(si*32) +: 32] = sstable_sizes_mem[si];
        end
    endgenerate

    // P8: desc_ready in ST_POP state (only if no pre-fetch available) OR
    //     pre-fetch during ST_WAIT when not yet prefetched
    assign desc_ready = (state == ST_POP && !desc_prefetched) ||
                        (USE_DESC_STREAM && state == ST_WAIT && !desc_prefetched &&
                         !desc_is_last_r && active_block_index > 32'd0);

    wire [AXI_ADDR_WIDTH-1:0] current_dst_base_addr = dst_base_addr + sst_base_offset_r + running_offset_r;

    wire        inner_busy;
    wire        inner_done;
    wire        inner_error;
    wire [31:0] inner_source0_decoded_entry_count;
    wire [31:0] inner_source0_bytes_read;
    wire [31:0] inner_source1_decoded_entry_count;
    wire [31:0] inner_source1_bytes_read;
    wire [31:0] inner_merge_output_byte_count;
    wire [31:0] inner_merge_decoded_record_count;
    wire [31:0] inner_merge_merged_record_count;
    wire [31:0] inner_merge_dropped_superseded_count;
    wire [31:0] inner_stage5_input_record_count;
    wire [31:0] inner_stage5_encoded_entry_count;
    wire [31:0] inner_stage5_output_block_bytes;
    wire [31:0] inner_stage5_bytes_written;
    wire [15:0] inner_stage5_last_key_len;
    wire [(STAGE5_MAX_KEY_BYTES*8)-1:0] inner_stage5_last_key_bytes;
    wire        inner_final_prev_user_key_valid;
    wire [15:0] inner_final_prev_user_key_len;
    wire [(MERGE_MAX_USER_KEY_BYTES*8)-1:0] inner_final_prev_user_key;
    wire        inner_enc_done;  // OPT-BP1

    genvar gi;
    generate
        for (gi = 0; gi < MAX_BLOCK_PAIRS; gi = gi + 1) begin : g_dst_output_block_bytes_vec
            assign dst_output_block_bytes_vec[(gi*32) +: 32] = dst_output_block_bytes_mem[gi];
        end
    endgenerate

    cmpct_pair_chain #(
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
        .STAGE5_RESTART_INTERVAL(STAGE5_RESTART_INTERVAL)
    ) u_single_block_chain (
        .clk(clk),
        .rstn(rstn),
        .clear(inner_clear_r),
        .start(inner_start_r),
        .front_clear(inner_front_clear_r),
        .front_start(inner_front_start_r),
        .seed_prev_user_key_valid(seed_prev_user_key_valid_r),
        .seed_prev_user_key_len(seed_prev_user_key_len_r),
        .seed_prev_user_key(seed_prev_user_key_r),
        .src0_base_addr(current_src0_base_addr_r),
        .src0_byte_count(current_src0_byte_count_r),
        .src1_base_addr(current_src1_base_addr_r),
        .src1_byte_count(current_src1_byte_count_r),
        .mid_base_addr(mid_base_addr),
        .dst_base_addr(current_dst_base_addr),
        .busy(inner_busy),
        .done(inner_done),
        .error(inner_error),
        .source0_decoded_entry_count(inner_source0_decoded_entry_count),
        .source0_restart_count(),
        .source0_restart_entry_count(),
        .source0_shared_key_bytes_total(),
        .source0_unshared_key_bytes_total(),
        .source0_value_bytes_total(),
        .source0_last_key_len(),
        .source0_last_value_len(),
        .source0_last_shared_bytes(),
        .source0_last_non_shared_bytes(),
        .source0_restart_array_offset(),
        .source0_bytes_read(inner_source0_bytes_read),
        .source0_beats_read(),
        .source1_decoded_entry_count(inner_source1_decoded_entry_count),
        .source1_restart_count(),
        .source1_restart_entry_count(),
        .source1_shared_key_bytes_total(),
        .source1_unshared_key_bytes_total(),
        .source1_value_bytes_total(),
        .source1_last_key_len(),
        .source1_last_value_len(),
        .source1_last_shared_bytes(),
        .source1_last_non_shared_bytes(),
        .source1_restart_array_offset(),
        .source1_bytes_read(inner_source1_bytes_read),
        .source1_beats_read(),
        .merge_bytes_written(),
        .merge_beats_written(),
        .merge_output_byte_count(inner_merge_output_byte_count),
        .merge_decoded_record_count(inner_merge_decoded_record_count),
        .merge_merged_record_count(inner_merge_merged_record_count),
        .merge_dropped_superseded_count(inner_merge_dropped_superseded_count),
        .merge_value_record_count(),
        .merge_delete_record_count(),
        .merge_user_key_bytes_total(),
        .merge_value_bytes_total(),
        .merge_last_user_key_len(),
        .merge_last_sequence(),
        .merge_last_value_type(),
        .merge_last_record_keep(),
        .stage5_bytes_read(),
        .stage5_beats_read(),
        .stage5_bytes_written(inner_stage5_bytes_written),
        .stage5_beats_written(),
        .stage5_input_record_count(inner_stage5_input_record_count),
        .stage5_encoded_entry_count(inner_stage5_encoded_entry_count),
        .stage5_restart_count(),
        .stage5_shared_key_bytes_total(),
        .stage5_unshared_key_bytes_total(),
        .stage5_value_bytes_total(),
        .stage5_last_key_len(inner_stage5_last_key_len),
        .stage5_last_key_bytes(inner_stage5_last_key_bytes),
        .stage5_last_value_len(),
        .stage5_last_shared_bytes(),
        .stage5_last_non_shared_bytes(),
        .stage5_output_block_bytes(inner_stage5_output_block_bytes),
        .final_prev_user_key_valid(inner_final_prev_user_key_valid),
        .final_prev_user_key_len(inner_final_prev_user_key_len),
        .final_prev_user_key(inner_final_prev_user_key),
        .enc_done(inner_enc_done),
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
        .m_axi_chain_awaddr(inner_chain_awaddr),
        .m_axi_chain_awlen(inner_chain_awlen),
        .m_axi_chain_awsize(inner_chain_awsize),
        .m_axi_chain_awburst(inner_chain_awburst),
        .m_axi_chain_awvalid(inner_chain_awvalid),
        .m_axi_chain_awready(inner_chain_awready_w),
        .m_axi_chain_wdata(inner_chain_wdata),
        .m_axi_chain_wstrb(inner_chain_wstrb),
        .m_axi_chain_wlast(inner_chain_wlast),
        .m_axi_chain_wvalid(inner_chain_wvalid),
        .m_axi_chain_wready(inner_chain_wready_w),
        .m_axi_chain_bresp(m_axi_chain_bresp),
        .m_axi_chain_bvalid(inner_chain_bvalid_w),
        .m_axi_chain_bready(inner_chain_bready)
    );

    // Inner chain write-side internal wires
    wire [AXI_ADDR_WIDTH-1:0]        inner_chain_awaddr;
    wire [7:0]                        inner_chain_awlen;
    wire [2:0]                        inner_chain_awsize;
    wire [1:0]                        inner_chain_awburst;
    wire                              inner_chain_awvalid;
    wire                              inner_chain_awready_w;
    wire [AXI_DATA_WIDTH-1:0]         inner_chain_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0]     inner_chain_wstrb;
    wire                              inner_chain_wlast;
    wire                              inner_chain_wvalid;
    wire                              inner_chain_wready_w;
    wire                              inner_chain_bvalid_w;
    wire                              inner_chain_bready;

    // AXI write MUX: select inner chain vs assembler
    assign m_axi_chain_awaddr  = assemble_mode_r ? asm_awaddr  : inner_chain_awaddr;
    assign m_axi_chain_awlen   = assemble_mode_r ? asm_awlen   : inner_chain_awlen;
    assign m_axi_chain_awsize  = assemble_mode_r ? asm_awsize  : inner_chain_awsize;
    assign m_axi_chain_awburst = assemble_mode_r ? asm_awburst : inner_chain_awburst;
    assign m_axi_chain_awvalid = assemble_mode_r ? asm_awvalid : inner_chain_awvalid;
    assign inner_chain_awready_w = assemble_mode_r ? 1'b0 : m_axi_chain_awready;
    assign asm_awready_w         = assemble_mode_r ? m_axi_chain_awready : 1'b0;

    assign m_axi_chain_wdata   = assemble_mode_r ? asm_wdata  : inner_chain_wdata;
    assign m_axi_chain_wstrb   = assemble_mode_r ? asm_wstrb  : inner_chain_wstrb;
    assign m_axi_chain_wlast   = assemble_mode_r ? asm_wlast  : inner_chain_wlast;
    assign m_axi_chain_wvalid  = assemble_mode_r ? asm_wvalid : inner_chain_wvalid;
    assign inner_chain_wready_w  = assemble_mode_r ? 1'b0 : m_axi_chain_wready;
    assign asm_wready_w          = assemble_mode_r ? m_axi_chain_wready : 1'b0;

    assign m_axi_chain_bready  = assemble_mode_r ? asm_bready : inner_chain_bready;
    assign inner_chain_bvalid_w  = assemble_mode_r ? 1'b0 : m_axi_chain_bvalid;
    assign asm_bvalid_w          = assemble_mode_r ? m_axi_chain_bvalid : 1'b0;
    assign asm_bresp             = m_axi_chain_bresp;

    // Assembler v2: metadata written via write port (no flat vectors)
    cmpct_assembler #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .MAX_BLOCK_PAIRS(MAX_BLOCK_PAIRS),
        .MAX_KEY_BYTES(STAGE5_MAX_KEY_BYTES)
    ) u_sstable_assembler (
        .clk(clk),
        .rstn(rstn),
        .clear(inner_clear_r),
        .start(asm_start_r),
        .dst_base_addr(dst_base_addr + sst_base_offset_r),
        .data_end_offset(running_offset_r[31:0]),
        .num_blocks(blocks_in_current_sst_r),
        .meta_wr_en(asm_meta_wr_en_r),
        .meta_wr_addr(asm_meta_wr_addr_r),
        .meta_wr_offset(asm_meta_wr_offset_r),
        .meta_wr_size(asm_meta_wr_size_r),
        .meta_wr_keylen(asm_meta_wr_keylen_r),
        .meta_wr_keybytes(asm_meta_wr_keybytes_r),
        .busy(asm_busy),
        .done(asm_done),
        .error(asm_error),
        .total_bytes(asm_total_bytes),
        .m_axi_awaddr(asm_awaddr),
        .m_axi_awlen(asm_awlen),
        .m_axi_awsize(asm_awsize),
        .m_axi_awburst(asm_awburst),
        .m_axi_awvalid(asm_awvalid),
        .m_axi_awready(asm_awready_w),
        .m_axi_wdata(asm_wdata),
        .m_axi_wstrb(asm_wstrb),
        .m_axi_wlast(asm_wlast),
        .m_axi_wvalid(asm_wvalid),
        .m_axi_wready(asm_wready_w),
        .m_axi_bresp(asm_bresp),
        .m_axi_bvalid(asm_bvalid_w),
        .m_axi_bready(asm_bready)
    );

    integer i, j;
    always @(posedge clk) begin
        if (!rstn) begin
            state                                 <= ST_IDLE;
            inner_clear_r                         <= 1'b0;
            inner_start_r                         <= 1'b0;
            inner_front_clear_r                   <= 1'b0;
            inner_front_start_r                   <= 1'b0;
            asm_start_r                           <= 1'b0;
            asm_meta_wr_en_r                      <= 1'b0;
            inner_done_d                          <= 1'b0;
            inner_enc_done_d                      <= 1'b0;
            pipeline_wr_pending                   <= 1'b0;
            pipeline_restart_r                    <= 1'b0;
            wr_done_pending                       <= 1'b0;
            block_pair_count_r                    <= 32'd0;
            seed_prev_user_key_valid_r            <= 1'b0;
            seed_prev_user_key_len_r              <= 16'd0;
            seed_prev_user_key_r                  <= {(MERGE_MAX_USER_KEY_BYTES*8){1'b0}};
            busy                                  <= 1'b0;
            done                                  <= 1'b0;
            error                                 <= 1'b0;
            active_block_index                    <= 32'd0;
            blocks_completed                      <= 32'd0;
            running_offset_r                      <= 64'd0;
            assemble_mode_r                       <= 1'b0;
            sstable_total_bytes                   <= 32'd0;
            sstable_count                         <= 32'd0;
            max_file_size_r                       <= 32'd0;
            split_threshold_r                     <= 32'd0;
            split_enabled_r                       <= 1'b0;
            sst_base_offset_r                     <= 64'd0;
            blocks_in_current_sst_r               <= 32'd0;
            first_block_of_sst_r                  <= 32'd0;
            total_source0_decoded_entry_count     <= 32'd0;
            total_source1_decoded_entry_count     <= 32'd0;
            total_source0_bytes_read              <= 32'd0;
            total_source1_bytes_read              <= 32'd0;
            total_merge_output_byte_count         <= 32'd0;
            total_merge_decoded_record_count      <= 32'd0;
            total_merge_merged_record_count       <= 32'd0;
            total_merge_dropped_superseded_count  <= 32'd0;
            total_stage5_input_record_count       <= 32'd0;
            total_stage5_encoded_entry_count      <= 32'd0;
            total_stage5_output_block_bytes       <= 32'd0;
            total_stage5_bytes_written            <= 32'd0;
            for (i = 0; i < MAX_BLOCK_PAIRS; i = i + 1)
                dst_output_block_bytes_mem[i] <= 32'd0;
            for (j = 0; j < MAX_SSTABLES; j = j + 1)
                sstable_sizes_mem[j] <= 32'd0;
        end else if (clear) begin
            state                                 <= ST_IDLE;
            inner_clear_r                         <= 1'b0;
            inner_start_r                         <= 1'b0;
            inner_front_clear_r                   <= 1'b0;
            inner_front_start_r                   <= 1'b0;
            asm_start_r                           <= 1'b0;
            asm_meta_wr_en_r                      <= 1'b0;
            inner_done_d                          <= 1'b0;
            inner_enc_done_d                      <= 1'b0;
            pipeline_wr_pending                   <= 1'b0;
            pipeline_restart_r                    <= 1'b0;
            wr_done_pending                       <= 1'b0;
            block_pair_count_r                    <= 32'd0;
            seed_prev_user_key_valid_r            <= 1'b0;
            seed_prev_user_key_len_r              <= 16'd0;
            seed_prev_user_key_r                  <= {(MERGE_MAX_USER_KEY_BYTES*8){1'b0}};
            busy                                  <= 1'b0;
            done                                  <= 1'b0;
            error                                 <= 1'b0;
            active_block_index                    <= 32'd0;
            blocks_completed                      <= 32'd0;
            running_offset_r                      <= 64'd0;
            assemble_mode_r                       <= 1'b0;
            sstable_total_bytes                   <= 32'd0;
            sstable_count                         <= 32'd0;
            max_file_size_r                       <= 32'd0;
            split_threshold_r                     <= 32'd0;
            split_enabled_r                       <= 1'b0;
            sst_base_offset_r                     <= 64'd0;
            blocks_in_current_sst_r               <= 32'd0;
            first_block_of_sst_r                  <= 32'd0;
            total_source0_decoded_entry_count     <= 32'd0;
            total_source1_decoded_entry_count     <= 32'd0;
            total_source0_bytes_read              <= 32'd0;
            total_source1_bytes_read              <= 32'd0;
            total_merge_output_byte_count         <= 32'd0;
            total_merge_decoded_record_count      <= 32'd0;
            total_merge_merged_record_count       <= 32'd0;
            total_merge_dropped_superseded_count  <= 32'd0;
            total_stage5_input_record_count       <= 32'd0;
            total_stage5_encoded_entry_count      <= 32'd0;
            total_stage5_output_block_bytes       <= 32'd0;
            total_stage5_bytes_written            <= 32'd0;
            for (i = 0; i < MAX_BLOCK_PAIRS; i = i + 1)
                dst_output_block_bytes_mem[i] <= 32'd0;
            for (j = 0; j < MAX_SSTABLES; j = j + 1)
                sstable_sizes_mem[j] <= 32'd0;
        end else begin
            inner_clear_r       <= 1'b0;
            inner_start_r       <= 1'b0;
            inner_front_clear_r <= 1'b0;
            inner_front_start_r <= 1'b0;
            asm_start_r         <= 1'b0;
            asm_meta_wr_en_r    <= 1'b0;
            inner_done_d        <= inner_done;
            inner_enc_done_d    <= inner_enc_done;
            done                <= 1'b0;
            error               <= 1'b0;

            // P8: fire deferred front_start one cycle after front_clear
            if (front_start_pending) begin
                inner_front_start_r <= 1'b1;
                front_start_pending <= 1'b0;
            end

            // P8: descriptor pre-fetch — latch during ST_WAIT
            if (state == ST_WAIT && USE_DESC_STREAM && desc_valid && desc_ready &&
                !desc_prefetched) begin
                next_src0_base_addr_r  <= desc_src0_addr;
                next_src0_byte_count_r <= desc_src0_size;
                next_src1_base_addr_r  <= desc_src1_addr;
                next_src1_byte_count_r <= desc_src1_size;
                next_desc_is_last_r    <= desc_last;
                desc_prefetched        <= 1'b1;
            end

            // OPT-BP1: Clear pipeline_wr_pending on wr_done edge (state-independent).
            // If enc_done in the case statement also sets pipeline_wr_pending on the
            // same cycle, the case's later non-blocking assignment wins — correct
            // because the old pending was consumed and a new one is set.
            if (inner_done && !inner_done_d && pipeline_wr_pending)
                pipeline_wr_pending <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start && !busy) begin
                        if (!USE_DESC_STREAM &&
                            ((block_pair_count == 32'd0) || (block_pair_count > MAX_BLOCK_PAIRS))) begin
                            error <= 1'b1;
                        end else begin
                            state                                <= USE_DESC_STREAM ? ST_POP : ST_CLEAR;
                            busy                                 <= 1'b1;
                            block_pair_count_r                   <= USE_DESC_STREAM ? 32'd0 : block_pair_count;
                            desc_is_last_r                       <= 1'b0;
                            active_block_index                   <= 32'd0;
                            blocks_completed                     <= 32'd0;
                            running_offset_r                     <= 64'd0;
                            assemble_mode_r                      <= 1'b0;
                            sstable_total_bytes                  <= 32'd0;
                            sstable_count                        <= 32'd0;
                            sst_base_offset_r                    <= 64'd0;
                            blocks_in_current_sst_r              <= 32'd0;
                            first_block_of_sst_r                 <= 32'd0;
                            max_file_size_r                      <= max_file_size;
                            split_enabled_r                      <= (max_file_size > SPLIT_TAIL_MARGIN);
                            split_threshold_r                    <= max_file_size - SPLIT_TAIL_MARGIN;
                            pipeline_wr_pending                  <= 1'b0;
                            pipeline_restart_r                   <= 1'b0;
                            wr_done_pending                      <= 1'b0;
                            front_start_pending                  <= 1'b0;
                            desc_prefetched                      <= 1'b0;
                            total_source0_decoded_entry_count    <= 32'd0;
                            total_source1_decoded_entry_count    <= 32'd0;
                            total_source0_bytes_read             <= 32'd0;
                            total_source1_bytes_read             <= 32'd0;
                            total_merge_output_byte_count        <= 32'd0;
                            total_merge_decoded_record_count     <= 32'd0;
                            total_merge_merged_record_count      <= 32'd0;
                            total_merge_dropped_superseded_count <= 32'd0;
                            total_stage5_input_record_count      <= 32'd0;
                            total_stage5_encoded_entry_count     <= 32'd0;
                            total_stage5_output_block_bytes      <= 32'd0;
                            total_stage5_bytes_written           <= 32'd0;
                            seed_prev_user_key_valid_r           <= 1'b0;
                            seed_prev_user_key_len_r             <= 16'd0;
                            seed_prev_user_key_r                 <= {(MERGE_MAX_USER_KEY_BYTES*8){1'b0}};
                            for (i = 0; i < MAX_BLOCK_PAIRS; i = i + 1)
                                dst_output_block_bytes_mem[i] <= 32'd0;
                            for (j = 0; j < MAX_SSTABLES; j = j + 1)
                                sstable_sizes_mem[j] <= 32'd0;
                        end
                    end
                end

                // OPT-P1c: Pop next descriptor from stream
                ST_POP: begin
                    if (desc_prefetched) begin
                        // P8: use pre-fetched descriptor (skip stream handshake)
                        current_src0_base_addr_r  <= next_src0_base_addr_r;
                        current_src0_byte_count_r <= next_src0_byte_count_r;
                        current_src1_base_addr_r  <= next_src1_base_addr_r;
                        current_src1_byte_count_r <= next_src1_byte_count_r;
                        desc_is_last_r            <= next_desc_is_last_r;
                        desc_prefetched           <= 1'b0;
                        state                     <= pipeline_restart_r ? ST_PIPE_RESTART : ST_CLEAR;
                    end else if (desc_valid) begin
                        current_src0_base_addr_r  <= desc_src0_addr;
                        current_src0_byte_count_r <= desc_src0_size;
                        current_src1_base_addr_r  <= desc_src1_addr;
                        current_src1_byte_count_r <= desc_src1_size;
                        desc_is_last_r            <= desc_last;
                        state                     <= pipeline_restart_r ? ST_PIPE_RESTART : ST_CLEAR;
                    end
                end

                ST_CLEAR: begin
                    // In vector mode, load descriptors from vectors
                    if (!USE_DESC_STREAM) begin
                        current_src0_base_addr_r  <= src0_base_addr_vec[(active_block_index*AXI_ADDR_WIDTH) +: AXI_ADDR_WIDTH];
                        current_src0_byte_count_r <= src0_byte_count_vec[(active_block_index*32) +: 32];
                        current_src1_base_addr_r  <= src1_base_addr_vec[(active_block_index*AXI_ADDR_WIDTH) +: AXI_ADDR_WIDTH];
                        current_src1_byte_count_r <= src1_byte_count_vec[(active_block_index*32) +: 32];
                    end
                    inner_clear_r <= 1'b1;
                    state         <= ST_START;
                end

                ST_START: begin
                    inner_start_r <= 1'b1;
                    state         <= ST_WAIT;
                end

                // OPT-BP1: Main wait state — detect enc_done early for pipelining
                ST_WAIT: begin
                    if (inner_error) begin
                        busy  <= 1'b0;
                        error <= 1'b1;
                        state <= ST_IDLE;
                    end else if (inner_enc_done && !inner_enc_done_d) begin
                        // ---- Encoder finished: capture per-block metadata early ----
                        dst_output_block_bytes_mem[blocks_in_current_sst_r] <= inner_stage5_output_block_bytes + 32'd5;
                        // Write metadata to assembler via memory port
                        asm_meta_wr_en_r       <= 1'b1;
                        asm_meta_wr_addr_r     <= blocks_in_current_sst_r[7:0];
                        asm_meta_wr_offset_r   <= running_offset_r;
                        asm_meta_wr_size_r     <= inner_stage5_output_block_bytes + 32'd5;
                        asm_meta_wr_keylen_r   <= inner_stage5_last_key_len;
                        asm_meta_wr_keybytes_r <= inner_stage5_last_key_bytes;
                        running_offset_r <= (running_offset_r + {32'd0, inner_stage5_output_block_bytes + 32'd5} + 64'd63) & ~64'd63;
                        blocks_in_current_sst_r <= blocks_in_current_sst_r + 32'd1;

                        blocks_completed                     <= blocks_completed + 32'd1;
                        total_source0_decoded_entry_count    <= total_source0_decoded_entry_count + inner_source0_decoded_entry_count;
                        total_source1_decoded_entry_count    <= total_source1_decoded_entry_count + inner_source1_decoded_entry_count;
                        total_source0_bytes_read             <= total_source0_bytes_read + inner_source0_bytes_read;
                        total_source1_bytes_read             <= total_source1_bytes_read + inner_source1_bytes_read;
                        total_merge_output_byte_count        <= total_merge_output_byte_count + inner_merge_output_byte_count;
                        total_merge_decoded_record_count     <= total_merge_decoded_record_count + inner_merge_decoded_record_count;
                        total_merge_merged_record_count      <= total_merge_merged_record_count + inner_merge_merged_record_count;
                        total_merge_dropped_superseded_count <= total_merge_dropped_superseded_count + inner_merge_dropped_superseded_count;
                        total_stage5_input_record_count      <= total_stage5_input_record_count + inner_stage5_input_record_count;
                        total_stage5_encoded_entry_count     <= total_stage5_encoded_entry_count + inner_stage5_encoded_entry_count;
                        total_stage5_output_block_bytes      <= total_stage5_output_block_bytes + inner_stage5_output_block_bytes;
                        // OPT-BP1: use output_block_bytes+5 as proxy for bytes_written (exact for TLAST_STOP mode)
                        total_stage5_bytes_written           <= total_stage5_bytes_written + inner_stage5_output_block_bytes + 32'd5;
                        seed_prev_user_key_valid_r           <= inner_final_prev_user_key_valid;
                        seed_prev_user_key_len_r             <= inner_final_prev_user_key_len;
                        seed_prev_user_key_r                 <= inner_final_prev_user_key;

                        // Determine if this was the last pair
                        if (USE_DESC_STREAM ? desc_is_last_r
                                            : ((active_block_index + 32'd1) >= block_pair_count_r)) begin
                            // OPT-BP1: last pair — wait for wr_done before assembling
                            // OPT-T4-FIX: latch if wr_done fires concurrently with enc_done
                            wr_done_pending <= (inner_done && !inner_done_d);
                            state <= ST_WAIT_LAST;
                        end else if ((split_enabled_r &&
                                     (running_offset_r[31:0] >= split_threshold_r)) ||
                                    (blocks_in_current_sst_r + 32'd1 >= MAX_BLOCK_PAIRS)) begin
                            // OPT-BP1: split — wait for wr_done before assembling
                            // OPT-T4-FIX: latch if wr_done fires concurrently with enc_done
                            wr_done_pending <= (inner_done && !inner_done_d);
                            state <= ST_WAIT_SPLIT;
                        end else begin
                            // P8: pipeline — front_clear/start next pair while write continues
                            pipeline_wr_pending <= 1'b1;
                            pipeline_restart_r  <= 1'b1;
                            active_block_index  <= active_block_index + 32'd1;
                            // P8: if descriptor is pre-fetched, skip ST_POP
                            if (USE_DESC_STREAM && desc_prefetched) begin
                                current_src0_base_addr_r  <= next_src0_base_addr_r;
                                current_src0_byte_count_r <= next_src0_byte_count_r;
                                current_src1_base_addr_r  <= next_src1_base_addr_r;
                                current_src1_byte_count_r <= next_src1_byte_count_r;
                                desc_is_last_r            <= next_desc_is_last_r;
                                desc_prefetched           <= 1'b0;
                                state                     <= ST_PIPE_RESTART;
                            end else begin
                                state <= USE_DESC_STREAM ? ST_POP : ST_PIPE_RESTART;
                            end
                        end
                    end
                end

                // OPT-BP1: Wait for write engine to finish the last pair before assembling
                ST_WAIT_LAST: begin
                    if (inner_error) begin
                        busy  <= 1'b0;
                        error <= 1'b1;
                        state <= ST_IDLE;
                    // OPT-T4-FIX: also check wr_done_pending for concurrent pulse
                    end else if ((inner_done && !inner_done_d) || wr_done_pending) begin
                        wr_done_pending <= 1'b0;
                        if (pipeline_wr_pending) begin
                            // This is the previous pair's wr_done — keep waiting
                            pipeline_wr_pending <= 1'b0;
                        end else begin
                            // This is the last pair's wr_done — final assemble
                            assemble_mode_r <= 1'b1;
                            asm_start_r     <= 1'b1;
                            state           <= ST_ASSEMBLE;
                        end
                    end
                end

                // OPT-BP1: Wait for write engine to finish before split-assembling
                ST_WAIT_SPLIT: begin
                    if (inner_error) begin
                        busy  <= 1'b0;
                        error <= 1'b1;
                        state <= ST_IDLE;
                    // OPT-T4-FIX: also check wr_done_pending for concurrent pulse
                    end else if ((inner_done && !inner_done_d) || wr_done_pending) begin
                        wr_done_pending <= 1'b0;
                        if (pipeline_wr_pending) begin
                            pipeline_wr_pending <= 1'b0;
                        end else begin
                            assemble_mode_r <= 1'b1;
                            asm_start_r     <= 1'b1;
                            state           <= ST_SPLIT_ASM;
                        end
                    end
                end

                // P8: Combined pipeline restart — front_clear now, front_start next cycle
                ST_PIPE_RESTART: begin
                    // In vector mode, load next pair's descriptors
                    if (!USE_DESC_STREAM) begin
                        current_src0_base_addr_r  <= src0_base_addr_vec[(active_block_index*AXI_ADDR_WIDTH) +: AXI_ADDR_WIDTH];
                        current_src0_byte_count_r <= src0_byte_count_vec[(active_block_index*32) +: 32];
                        current_src1_base_addr_r  <= src1_base_addr_vec[(active_block_index*AXI_ADDR_WIDTH) +: AXI_ADDR_WIDTH];
                        current_src1_byte_count_r <= src1_byte_count_vec[(active_block_index*32) +: 32];
                    end
                    inner_front_clear_r <= 1'b1;
                    front_start_pending <= 1'b1;  // P8: fires front_start next cycle
                    pipeline_restart_r  <= 1'b0;
                    state               <= ST_WAIT;
                end

                ST_ASSEMBLE: begin
                    if (asm_error) begin
                        busy            <= 1'b0;
                        error           <= 1'b1;
                        assemble_mode_r <= 1'b0;
                        state           <= ST_IDLE;
                    end else if (asm_done) begin
                        // Record final SSTable
                        sstable_sizes_mem[sstable_count] <= running_offset_r[31:0] + asm_total_bytes;
                        sstable_total_bytes <= running_offset_r[31:0] + asm_total_bytes;
                        sstable_count       <= sstable_count + 32'd1;
                        busy            <= 1'b0;
                        done            <= 1'b1;
                        assemble_mode_r <= 1'b0;
                        state           <= ST_IDLE;
                    end
                end

                // ------ Split path: assemble current sub-SSTable ------
                ST_SPLIT_ASM: begin
                    if (asm_error) begin
                        busy            <= 1'b0;
                        error           <= 1'b1;
                        assemble_mode_r <= 1'b0;
                        state           <= ST_IDLE;
                    end else if (asm_done) begin
                        // Record this sub-SSTable's size
                        sstable_sizes_mem[sstable_count] <= running_offset_r[31:0] + asm_total_bytes;
                        sstable_count <= sstable_count + 32'd1;
                        // Advance global DST offset (64-byte aligned)
                        sst_base_offset_r <= (sst_base_offset_r
                            + {32'd0, running_offset_r[31:0] + asm_total_bytes}
                            + 64'd63) & ~64'd63;
                        assemble_mode_r <= 1'b0;
                        state           <= ST_SPLIT_RESET;
                    end
                end

                // ------ Split path: reset per-SSTable state, continue ------
                ST_SPLIT_RESET: begin
                    running_offset_r        <= 64'd0;
                    blocks_in_current_sst_r <= 32'd0;
                    first_block_of_sst_r    <= active_block_index + 32'd1;
                    // Clear per-block output bytes for next sub-SSTable
                    for (i = 0; i < MAX_BLOCK_PAIRS; i = i + 1)
                        dst_output_block_bytes_mem[i] <= 32'd0;
                    active_block_index <= active_block_index + 32'd1;
                    state              <= USE_DESC_STREAM ? ST_POP : ST_CLEAR;
                end

                default: begin
                    busy  <= 1'b0;
                    error <= 1'b1;
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule
