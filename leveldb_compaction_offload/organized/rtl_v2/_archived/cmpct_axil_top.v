`timescale 1ns / 1ps

module stage4_real_internal_key_two_way_merge_stage5_nblock_axil_top #(
    parameter integer AXIL_ADDR_WIDTH             = 32,
    parameter integer AXIL_DATA_WIDTH             = 32,
    parameter integer AXI_ADDR_WIDTH              = 64,
    parameter integer AXI_DATA_WIDTH              = 512,
    parameter integer AXI_STRB_WIDTH              = 64,
    parameter integer MAX_BURST_LEN               = 16,
    parameter integer STAGE4_MAX_BLOCK_BYTES      = 4096,
    parameter integer STAGE4_MAX_KEY_BYTES        = 264,
    parameter integer MERGE_MAX_USER_KEY_BYTES    = 256,
    parameter integer MERGE_MAX_KEY_BYTES         = 264,
    parameter integer MERGE_MAX_VALUE_BYTES       = 1024,
    parameter integer MERGE_MAX_RECORD_BYTES      = 2048,
    parameter integer MERGE_MAX_RECORDS           = 256,
    parameter integer MERGE_MAX_OUTPUT_BYTES      = 73728,
    parameter integer STAGE5_MAX_RECORDS          = 256,
    parameter integer STAGE5_MAX_PAYLOAD_BYTES    = 4096,
    parameter integer STAGE5_MAX_BLOCK_BYTES      = 4096,
    parameter integer STAGE5_MAX_KEY_BYTES        = 256,
    parameter integer STAGE5_MAX_VALUE_BYTES      = 1024,
    parameter integer STAGE5_RESTART_INTERVAL     = 16,
    parameter integer MAX_BLOCK_PAIRS             = 8
) (
    input  wire                          axil_aclk,
    input  wire                          axil_aresetn,
    input  wire [AXIL_ADDR_WIDTH-1:0]    s_axil_awaddr,
    input  wire                          s_axil_awvalid,
    output reg                           s_axil_awready,
    input  wire [AXIL_DATA_WIDTH-1:0]    s_axil_wdata,
    input  wire [AXIL_DATA_WIDTH/8-1:0]  s_axil_wstrb,
    input  wire                          s_axil_wvalid,
    output reg                           s_axil_wready,
    output reg  [1:0]                    s_axil_bresp,
    output reg                           s_axil_bvalid,
    input  wire                          s_axil_bready,
    input  wire [AXIL_ADDR_WIDTH-1:0]    s_axil_araddr,
    input  wire                          s_axil_arvalid,
    output reg                           s_axil_arready,
    output reg  [AXIL_DATA_WIDTH-1:0]    s_axil_rdata,
    output reg  [1:0]                    s_axil_rresp,
    output reg                           s_axil_rvalid,
    input  wire                          s_axil_rready,

    input  wire                          ui_aclk,
    input  wire                          ui_aresetn,

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
    output wire [AXI_STRB_WIDTH-1:0]     m_axi_chain_wstrb,
    output wire                          m_axi_chain_wlast,
    output wire                          m_axi_chain_wvalid,
    input  wire                          m_axi_chain_wready,
    input  wire [1:0]                    m_axi_chain_bresp,
    input  wire                          m_axi_chain_bvalid,
    output wire                          m_axi_chain_bready,

    output wire                          done,
    output wire                          busy,
    output wire                          error,
    output wire [31:0]                   bytes_done,
    output wire [31:0]                   blocks_done
);

    localparam [AXIL_ADDR_WIDTH-1:0] REG_CTRL                              = 32'h0000;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_STATUS                            = 32'h0004;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_BLOCK_PAIR_COUNT                  = 32'h0008;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_MID_BASE_LO                       = 32'h000C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_MID_BASE_HI                       = 32'h0010;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_BASE0_LO                     = 32'h0014;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_BASE0_HI                     = 32'h0018;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_SIZE0                        = 32'h001C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_BASE0_LO                     = 32'h0020;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_BASE0_HI                     = 32'h0024;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_SIZE0                        = 32'h0028;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DST_BASE0_LO                      = 32'h002C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DST_BASE0_HI                      = 32'h0030;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_BASE1_LO                     = 32'h0034;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_BASE1_HI                     = 32'h0038;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_SIZE1                        = 32'h003C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_BASE1_LO                     = 32'h0040;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_BASE1_HI                     = 32'h0044;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_SIZE1                        = 32'h0048;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DST_BASE1_LO                      = 32'h004C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DST_BASE1_HI                      = 32'h0050;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_ACTIVE_BLOCK_INDEX                = 32'h0054;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_BLOCKS_COMPLETED                  = 32'h0058;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DST0_OUTPUT_BLOCK_BYTES           = 32'h005C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DST1_OUTPUT_BLOCK_BYTES           = 32'h0060;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_SOURCE0_DECODED_ENTRY_COUNT = 32'h0064;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_SOURCE1_DECODED_ENTRY_COUNT = 32'h0068;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_SOURCE0_BYTES_READ          = 32'h006C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_SOURCE1_BYTES_READ          = 32'h0070;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_MERGE_OUTPUT_BYTE_COUNT     = 32'h0074;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_MERGE_DECODED_RECORD_COUNT  = 32'h0078;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_MERGE_MERGED_RECORD_COUNT   = 32'h007C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_MERGE_DROPPED_COUNT         = 32'h0080;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_STAGE5_INPUT_RECORD_COUNT   = 32'h0084;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_STAGE5_ENCODED_ENTRY_COUNT  = 32'h0088;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_STAGE5_OUTPUT_BLOCK_BYTES   = 32'h008C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_STAGE5_BYTES_WRITTEN        = 32'h0090;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_PERF_CYCLE_COUNT                  = 32'h0094;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DESC_BASE                         = 32'h0100;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DESC_STRIDE                       = 32'h0020;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DESC_SRC0_BASE_LO_OFF            = 32'h0000;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DESC_SRC0_BASE_HI_OFF            = 32'h0004;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DESC_SRC0_SIZE_OFF               = 32'h0008;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DESC_SRC1_BASE_LO_OFF            = 32'h000C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DESC_SRC1_BASE_HI_OFF            = 32'h0010;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DESC_SRC1_SIZE_OFF               = 32'h0014;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DESC_DST_BASE_LO_OFF             = 32'h0018;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DESC_DST_BASE_HI_OFF             = 32'h001C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DESC_DST_OUTPUT_BYTES_BASE       = 32'h0200;

    reg [31:0] r_ctrl;
    reg [31:0] r_status;
    reg [31:0] r_block_pair_count;
    reg [63:0] r_mid_base;
    reg [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] r_src0_base_vec;
    reg [MAX_BLOCK_PAIRS*32-1:0]             r_src0_size_vec;
    reg [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] r_src1_base_vec;
    reg [MAX_BLOCK_PAIRS*32-1:0]             r_src1_size_vec;
    reg [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] r_dst_base_vec;

    reg [AXIL_ADDR_WIDTH-1:0] awaddr_lat;
    reg                       awaddr_valid;

    wire aw_hs = s_axil_awvalid & s_axil_awready;
    wire w_hs  = s_axil_wvalid  & s_axil_wready;
    wire b_hs  = s_axil_bvalid  & s_axil_bready;
    wire ar_hs = s_axil_arvalid & s_axil_arready;
    wire r_hs  = s_axil_rvalid  & s_axil_rready;
    wire can_accept_write = ~s_axil_bvalid;

    reg ctrl_start_d;
    reg ctrl_clear_d;
    wire ctrl_start_pulse = r_ctrl[0] & ~ctrl_start_d;
    wire ctrl_clear_pulse = r_ctrl[1] & ~ctrl_clear_d;

    reg        start_toggle_axil;
    reg        clear_toggle_axil;
    reg [31:0] cfg_block_pair_count_axil;
    reg [63:0] cfg_mid_base_axil;
    reg [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] cfg_src0_base_vec_axil;
    reg [MAX_BLOCK_PAIRS*32-1:0]             cfg_src0_size_vec_axil;
    reg [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] cfg_src1_base_vec_axil;
    reg [MAX_BLOCK_PAIRS*32-1:0]             cfg_src1_size_vec_axil;
    reg [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] cfg_dst_base_vec_axil;

    reg        start_toggle_ui_ff1;
    reg        start_toggle_ui_ff2;
    reg        start_toggle_ui_ff3;
    reg        clear_toggle_ui_ff1;
    reg        clear_toggle_ui_ff2;
    reg        clear_toggle_ui_ff3;
    reg [31:0] cfg_block_pair_count_ui_ff1;
    reg [31:0] cfg_block_pair_count_ui_ff2;
    reg [63:0] cfg_mid_base_ui_ff1;
    reg [63:0] cfg_mid_base_ui_ff2;
    reg [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] cfg_src0_base_vec_ui_ff1;
    reg [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] cfg_src0_base_vec_ui_ff2;
    reg [MAX_BLOCK_PAIRS*32-1:0]             cfg_src0_size_vec_ui_ff1;
    reg [MAX_BLOCK_PAIRS*32-1:0]             cfg_src0_size_vec_ui_ff2;
    reg [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] cfg_src1_base_vec_ui_ff1;
    reg [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] cfg_src1_base_vec_ui_ff2;
    reg [MAX_BLOCK_PAIRS*32-1:0]             cfg_src1_size_vec_ui_ff1;
    reg [MAX_BLOCK_PAIRS*32-1:0]             cfg_src1_size_vec_ui_ff2;
    reg [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] cfg_dst_base_vec_ui_ff1;
    reg [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] cfg_dst_base_vec_ui_ff2;

    wire start_pulse_ui = start_toggle_ui_ff3 ^ start_toggle_ui_ff2;
    wire clear_pulse_ui = clear_toggle_ui_ff3 ^ clear_toggle_ui_ff2;

    wire                                      top_busy_ui;
    wire                                      top_done_ui;
    wire                                      top_error_ui;
    wire [31:0]                               active_block_index_ui;
    wire [31:0]                               blocks_completed_ui;
    wire [MAX_BLOCK_PAIRS*32-1:0]             dst_output_block_bytes_vec_ui;
    wire [31:0]                               total_source0_decoded_entry_count_ui;
    wire [31:0]                               total_source1_decoded_entry_count_ui;
    wire [31:0]                               total_source0_bytes_read_ui;
    wire [31:0]                               total_source1_bytes_read_ui;
    wire [31:0]                               total_merge_output_byte_count_ui;
    wire [31:0]                               total_merge_decoded_record_count_ui;
    wire [31:0]                               total_merge_merged_record_count_ui;
    wire [31:0]                               total_merge_dropped_superseded_count_ui;
    wire [31:0]                               total_stage5_input_record_count_ui;
    wire [31:0]                               total_stage5_encoded_entry_count_ui;
    wire [31:0]                               total_stage5_output_block_bytes_ui;
    wire [31:0]                               total_stage5_bytes_written_ui;

    reg done_ui_d;
    reg error_ui_d;
    reg done_toggle_ui;
    reg error_toggle_ui;

    reg        perf_counting_ui;
    reg [31:0] perf_cycle_count_ui;

    reg done_toggle_axil_ff1;
    reg done_toggle_axil_ff2;
    reg error_toggle_axil_ff1;
    reg error_toggle_axil_ff2;
    wire done_pulse_axil  = done_toggle_axil_ff2 ^ done_toggle_axil_ff1;
    wire error_pulse_axil = error_toggle_axil_ff2 ^ error_toggle_axil_ff1;

    reg        busy_axil_ff1;
    reg        busy_axil_ff2;
    reg [31:0] active_block_index_axil_ff1;
    reg [31:0] active_block_index_axil_ff2;
    reg [31:0] blocks_completed_axil_ff1;
    reg [31:0] blocks_completed_axil_ff2;
    reg [MAX_BLOCK_PAIRS*32-1:0] dst_output_block_bytes_vec_axil_ff1;
    reg [MAX_BLOCK_PAIRS*32-1:0] dst_output_block_bytes_vec_axil_ff2;
    reg [31:0] total_source0_decoded_entry_count_axil_ff1;
    reg [31:0] total_source0_decoded_entry_count_axil_ff2;
    reg [31:0] total_source1_decoded_entry_count_axil_ff1;
    reg [31:0] total_source1_decoded_entry_count_axil_ff2;
    reg [31:0] total_source0_bytes_read_axil_ff1;
    reg [31:0] total_source0_bytes_read_axil_ff2;
    reg [31:0] total_source1_bytes_read_axil_ff1;
    reg [31:0] total_source1_bytes_read_axil_ff2;
    reg [31:0] total_merge_output_byte_count_axil_ff1;
    reg [31:0] total_merge_output_byte_count_axil_ff2;
    reg [31:0] total_merge_decoded_record_count_axil_ff1;
    reg [31:0] total_merge_decoded_record_count_axil_ff2;
    reg [31:0] total_merge_merged_record_count_axil_ff1;
    reg [31:0] total_merge_merged_record_count_axil_ff2;
    reg [31:0] total_merge_dropped_superseded_count_axil_ff1;
    reg [31:0] total_merge_dropped_superseded_count_axil_ff2;
    reg [31:0] total_stage5_input_record_count_axil_ff1;
    reg [31:0] total_stage5_input_record_count_axil_ff2;
    reg [31:0] total_stage5_encoded_entry_count_axil_ff1;
    reg [31:0] total_stage5_encoded_entry_count_axil_ff2;
    reg [31:0] total_stage5_output_block_bytes_axil_ff1;
    reg [31:0] total_stage5_output_block_bytes_axil_ff2;
    reg [31:0] total_stage5_bytes_written_axil_ff1;
    reg [31:0] total_stage5_bytes_written_axil_ff2;
    reg [31:0] perf_cycle_count_axil_ff1;
    reg [31:0] perf_cycle_count_axil_ff2;

    assign done        = r_status[1];
    assign busy        = busy_axil_ff2;
    assign error       = r_status[2];
    assign bytes_done  = total_stage5_bytes_written_axil_ff2;
    assign blocks_done = blocks_completed_axil_ff2;

    integer rd_idx;
    integer wr_idx;

    always @(posedge axil_aclk) begin
        if (!axil_aresetn) begin
            s_axil_awready <= 1'b0;
            s_axil_wready  <= 1'b0;
            s_axil_bvalid  <= 1'b0;
            s_axil_bresp   <= 2'b00;
            s_axil_arready <= 1'b0;
            s_axil_rvalid  <= 1'b0;
            s_axil_rresp   <= 2'b00;
            s_axil_rdata   <= {AXIL_DATA_WIDTH{1'b0}};
            awaddr_lat     <= {AXIL_ADDR_WIDTH{1'b0}};
            awaddr_valid   <= 1'b0;
        end else begin
            s_axil_awready <= can_accept_write & ~awaddr_valid;
            if (aw_hs) begin
                awaddr_lat   <= s_axil_awaddr;
                awaddr_valid <= 1'b1;
            end

            s_axil_wready <= can_accept_write & awaddr_valid;

            if (can_accept_write && awaddr_valid && w_hs) begin
                s_axil_bvalid <= 1'b1;
                s_axil_bresp  <= 2'b00;
                awaddr_valid  <= 1'b0;
            end else if (b_hs) begin
                s_axil_bvalid <= 1'b0;
            end

            s_axil_arready <= ~s_axil_rvalid;
            if (ar_hs) begin
                s_axil_rvalid <= 1'b1;
                s_axil_rresp  <= 2'b00;
                case (s_axil_araddr)
                    REG_CTRL:                              s_axil_rdata <= r_ctrl;
                    REG_STATUS:                            s_axil_rdata <= r_status;
                    REG_BLOCK_PAIR_COUNT:                  s_axil_rdata <= r_block_pair_count;
                    REG_MID_BASE_LO:                       s_axil_rdata <= r_mid_base[31:0];
                    REG_MID_BASE_HI:                       s_axil_rdata <= r_mid_base[63:32];
                    REG_SRC0_BASE0_LO:                     s_axil_rdata <= r_src0_base_vec[0 +: 32];
                    REG_SRC0_BASE0_HI:                     s_axil_rdata <= r_src0_base_vec[32 +: 32];
                    REG_SRC0_SIZE0:                        s_axil_rdata <= r_src0_size_vec[0 +: 32];
                    REG_SRC1_BASE0_LO:                     s_axil_rdata <= r_src1_base_vec[0 +: 32];
                    REG_SRC1_BASE0_HI:                     s_axil_rdata <= r_src1_base_vec[32 +: 32];
                    REG_SRC1_SIZE0:                        s_axil_rdata <= r_src1_size_vec[0 +: 32];
                    REG_DST_BASE0_LO:                      s_axil_rdata <= r_dst_base_vec[0 +: 32];
                    REG_DST_BASE0_HI:                      s_axil_rdata <= r_dst_base_vec[32 +: 32];
                    REG_SRC0_BASE1_LO:                     s_axil_rdata <= r_src0_base_vec[AXI_ADDR_WIDTH +: 32];
                    REG_SRC0_BASE1_HI:                     s_axil_rdata <= r_src0_base_vec[AXI_ADDR_WIDTH+32 +: 32];
                    REG_SRC0_SIZE1:                        s_axil_rdata <= r_src0_size_vec[32 +: 32];
                    REG_SRC1_BASE1_LO:                     s_axil_rdata <= r_src1_base_vec[AXI_ADDR_WIDTH +: 32];
                    REG_SRC1_BASE1_HI:                     s_axil_rdata <= r_src1_base_vec[AXI_ADDR_WIDTH+32 +: 32];
                    REG_SRC1_SIZE1:                        s_axil_rdata <= r_src1_size_vec[32 +: 32];
                    REG_DST_BASE1_LO:                      s_axil_rdata <= r_dst_base_vec[AXI_ADDR_WIDTH +: 32];
                    REG_DST_BASE1_HI:                      s_axil_rdata <= r_dst_base_vec[AXI_ADDR_WIDTH+32 +: 32];
                    REG_ACTIVE_BLOCK_INDEX:                s_axil_rdata <= active_block_index_axil_ff2;
                    REG_BLOCKS_COMPLETED:                  s_axil_rdata <= blocks_completed_axil_ff2;
                    REG_DST0_OUTPUT_BLOCK_BYTES:           s_axil_rdata <= dst_output_block_bytes_vec_axil_ff2[0 +: 32];
                    REG_DST1_OUTPUT_BLOCK_BYTES:           s_axil_rdata <= dst_output_block_bytes_vec_axil_ff2[32 +: 32];
                    REG_TOTAL_SOURCE0_DECODED_ENTRY_COUNT: s_axil_rdata <= total_source0_decoded_entry_count_axil_ff2;
                    REG_TOTAL_SOURCE1_DECODED_ENTRY_COUNT: s_axil_rdata <= total_source1_decoded_entry_count_axil_ff2;
                    REG_TOTAL_SOURCE0_BYTES_READ:          s_axil_rdata <= total_source0_bytes_read_axil_ff2;
                    REG_TOTAL_SOURCE1_BYTES_READ:          s_axil_rdata <= total_source1_bytes_read_axil_ff2;
                    REG_TOTAL_MERGE_OUTPUT_BYTE_COUNT:     s_axil_rdata <= total_merge_output_byte_count_axil_ff2;
                    REG_TOTAL_MERGE_DECODED_RECORD_COUNT:  s_axil_rdata <= total_merge_decoded_record_count_axil_ff2;
                    REG_TOTAL_MERGE_MERGED_RECORD_COUNT:   s_axil_rdata <= total_merge_merged_record_count_axil_ff2;
                    REG_TOTAL_MERGE_DROPPED_COUNT:         s_axil_rdata <= total_merge_dropped_superseded_count_axil_ff2;
                    REG_TOTAL_STAGE5_INPUT_RECORD_COUNT:   s_axil_rdata <= total_stage5_input_record_count_axil_ff2;
                    REG_TOTAL_STAGE5_ENCODED_ENTRY_COUNT:  s_axil_rdata <= total_stage5_encoded_entry_count_axil_ff2;
                    REG_TOTAL_STAGE5_OUTPUT_BLOCK_BYTES:   s_axil_rdata <= total_stage5_output_block_bytes_axil_ff2;
                    REG_TOTAL_STAGE5_BYTES_WRITTEN:        s_axil_rdata <= total_stage5_bytes_written_axil_ff2;
                    REG_PERF_CYCLE_COUNT:                   s_axil_rdata <= perf_cycle_count_axil_ff2;
                    default: begin
                        s_axil_rdata <= 32'h0;
                        for (rd_idx = 0; rd_idx < MAX_BLOCK_PAIRS; rd_idx = rd_idx + 1) begin
                            if (s_axil_araddr == (REG_DESC_BASE + (rd_idx * REG_DESC_STRIDE) + REG_DESC_SRC0_BASE_LO_OFF)) s_axil_rdata <= r_src0_base_vec[(rd_idx*AXI_ADDR_WIDTH) +: 32];
                            if (s_axil_araddr == (REG_DESC_BASE + (rd_idx * REG_DESC_STRIDE) + REG_DESC_SRC0_BASE_HI_OFF)) s_axil_rdata <= r_src0_base_vec[(rd_idx*AXI_ADDR_WIDTH)+32 +: 32];
                            if (s_axil_araddr == (REG_DESC_BASE + (rd_idx * REG_DESC_STRIDE) + REG_DESC_SRC0_SIZE_OFF))    s_axil_rdata <= r_src0_size_vec[(rd_idx*32) +: 32];
                            if (s_axil_araddr == (REG_DESC_BASE + (rd_idx * REG_DESC_STRIDE) + REG_DESC_SRC1_BASE_LO_OFF)) s_axil_rdata <= r_src1_base_vec[(rd_idx*AXI_ADDR_WIDTH) +: 32];
                            if (s_axil_araddr == (REG_DESC_BASE + (rd_idx * REG_DESC_STRIDE) + REG_DESC_SRC1_BASE_HI_OFF)) s_axil_rdata <= r_src1_base_vec[(rd_idx*AXI_ADDR_WIDTH)+32 +: 32];
                            if (s_axil_araddr == (REG_DESC_BASE + (rd_idx * REG_DESC_STRIDE) + REG_DESC_SRC1_SIZE_OFF))    s_axil_rdata <= r_src1_size_vec[(rd_idx*32) +: 32];
                            if (s_axil_araddr == (REG_DESC_BASE + (rd_idx * REG_DESC_STRIDE) + REG_DESC_DST_BASE_LO_OFF))  s_axil_rdata <= r_dst_base_vec[(rd_idx*AXI_ADDR_WIDTH) +: 32];
                            if (s_axil_araddr == (REG_DESC_BASE + (rd_idx * REG_DESC_STRIDE) + REG_DESC_DST_BASE_HI_OFF))  s_axil_rdata <= r_dst_base_vec[(rd_idx*AXI_ADDR_WIDTH)+32 +: 32];
                            if (s_axil_araddr == (REG_DESC_DST_OUTPUT_BYTES_BASE + (rd_idx * 4)))                           s_axil_rdata <= dst_output_block_bytes_vec_axil_ff2[(rd_idx*32) +: 32];
                        end
                    end
                endcase
            end else if (r_hs) begin
                s_axil_rvalid <= 1'b0;
            end
        end
    end

    always @(posedge axil_aclk) begin
        if (!axil_aresetn) begin
            r_ctrl                                   <= 32'h0;
            r_status                                 <= 32'h0;
            r_block_pair_count                       <= 32'h0;
            r_mid_base                               <= 64'h0;
            r_src0_base_vec                          <= {(MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH){1'b0}};
            r_src0_size_vec                          <= {(MAX_BLOCK_PAIRS*32){1'b0}};
            r_src1_base_vec                          <= {(MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH){1'b0}};
            r_src1_size_vec                          <= {(MAX_BLOCK_PAIRS*32){1'b0}};
            r_dst_base_vec                           <= {(MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH){1'b0}};
            ctrl_start_d                             <= 1'b0;
            ctrl_clear_d                             <= 1'b0;
            start_toggle_axil                        <= 1'b0;
            clear_toggle_axil                        <= 1'b0;
            cfg_block_pair_count_axil                <= 32'h0;
            cfg_mid_base_axil                        <= 64'h0;
            cfg_src0_base_vec_axil                   <= {(MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH){1'b0}};
            cfg_src0_size_vec_axil                   <= {(MAX_BLOCK_PAIRS*32){1'b0}};
            cfg_src1_base_vec_axil                   <= {(MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH){1'b0}};
            cfg_src1_size_vec_axil                   <= {(MAX_BLOCK_PAIRS*32){1'b0}};
            cfg_dst_base_vec_axil                    <= {(MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH){1'b0}};
            busy_axil_ff1                            <= 1'b0;
            busy_axil_ff2                            <= 1'b0;
            active_block_index_axil_ff1             <= 32'h0;
            active_block_index_axil_ff2             <= 32'h0;
            blocks_completed_axil_ff1               <= 32'h0;
            blocks_completed_axil_ff2               <= 32'h0;
            dst_output_block_bytes_vec_axil_ff1     <= {(MAX_BLOCK_PAIRS*32){1'b0}};
            dst_output_block_bytes_vec_axil_ff2     <= {(MAX_BLOCK_PAIRS*32){1'b0}};
            total_source0_decoded_entry_count_axil_ff1 <= 32'h0;
            total_source0_decoded_entry_count_axil_ff2 <= 32'h0;
            total_source1_decoded_entry_count_axil_ff1 <= 32'h0;
            total_source1_decoded_entry_count_axil_ff2 <= 32'h0;
            total_source0_bytes_read_axil_ff1       <= 32'h0;
            total_source0_bytes_read_axil_ff2       <= 32'h0;
            total_source1_bytes_read_axil_ff1       <= 32'h0;
            total_source1_bytes_read_axil_ff2       <= 32'h0;
            total_merge_output_byte_count_axil_ff1  <= 32'h0;
            total_merge_output_byte_count_axil_ff2  <= 32'h0;
            total_merge_decoded_record_count_axil_ff1 <= 32'h0;
            total_merge_decoded_record_count_axil_ff2 <= 32'h0;
            total_merge_merged_record_count_axil_ff1 <= 32'h0;
            total_merge_merged_record_count_axil_ff2 <= 32'h0;
            total_merge_dropped_superseded_count_axil_ff1 <= 32'h0;
            total_merge_dropped_superseded_count_axil_ff2 <= 32'h0;
            total_stage5_input_record_count_axil_ff1 <= 32'h0;
            total_stage5_input_record_count_axil_ff2 <= 32'h0;
            total_stage5_encoded_entry_count_axil_ff1 <= 32'h0;
            total_stage5_encoded_entry_count_axil_ff2 <= 32'h0;
            total_stage5_output_block_bytes_axil_ff1 <= 32'h0;
            total_stage5_output_block_bytes_axil_ff2 <= 32'h0;
            total_stage5_bytes_written_axil_ff1     <= 32'h0;
            total_stage5_bytes_written_axil_ff2     <= 32'h0;
            perf_cycle_count_axil_ff1               <= 32'h0;
            perf_cycle_count_axil_ff2               <= 32'h0;
        end else begin
            ctrl_start_d            <= r_ctrl[0];
            ctrl_clear_d            <= r_ctrl[1];
            cfg_block_pair_count_axil <= r_block_pair_count;
            cfg_mid_base_axil       <= r_mid_base;
            cfg_src0_base_vec_axil  <= r_src0_base_vec;
            cfg_src0_size_vec_axil  <= r_src0_size_vec;
            cfg_src1_base_vec_axil  <= r_src1_base_vec;
            cfg_src1_size_vec_axil  <= r_src1_size_vec;
            cfg_dst_base_vec_axil   <= r_dst_base_vec;

            busy_axil_ff1                        <= top_busy_ui;
            busy_axil_ff2                        <= busy_axil_ff1;
            active_block_index_axil_ff1         <= active_block_index_ui;
            active_block_index_axil_ff2         <= active_block_index_axil_ff1;
            blocks_completed_axil_ff1           <= blocks_completed_ui;
            blocks_completed_axil_ff2           <= blocks_completed_axil_ff1;
            dst_output_block_bytes_vec_axil_ff1 <= dst_output_block_bytes_vec_ui;
            dst_output_block_bytes_vec_axil_ff2 <= dst_output_block_bytes_vec_axil_ff1;
            total_source0_decoded_entry_count_axil_ff1 <= total_source0_decoded_entry_count_ui;
            total_source0_decoded_entry_count_axil_ff2 <= total_source0_decoded_entry_count_axil_ff1;
            total_source1_decoded_entry_count_axil_ff1 <= total_source1_decoded_entry_count_ui;
            total_source1_decoded_entry_count_axil_ff2 <= total_source1_decoded_entry_count_axil_ff1;
            total_source0_bytes_read_axil_ff1   <= total_source0_bytes_read_ui;
            total_source0_bytes_read_axil_ff2   <= total_source0_bytes_read_axil_ff1;
            total_source1_bytes_read_axil_ff1   <= total_source1_bytes_read_ui;
            total_source1_bytes_read_axil_ff2   <= total_source1_bytes_read_axil_ff1;
            total_merge_output_byte_count_axil_ff1 <= total_merge_output_byte_count_ui;
            total_merge_output_byte_count_axil_ff2 <= total_merge_output_byte_count_axil_ff1;
            total_merge_decoded_record_count_axil_ff1 <= total_merge_decoded_record_count_ui;
            total_merge_decoded_record_count_axil_ff2 <= total_merge_decoded_record_count_axil_ff1;
            total_merge_merged_record_count_axil_ff1 <= total_merge_merged_record_count_ui;
            total_merge_merged_record_count_axil_ff2 <= total_merge_merged_record_count_axil_ff1;
            total_merge_dropped_superseded_count_axil_ff1 <= total_merge_dropped_superseded_count_ui;
            total_merge_dropped_superseded_count_axil_ff2 <= total_merge_dropped_superseded_count_axil_ff1;
            total_stage5_input_record_count_axil_ff1 <= total_stage5_input_record_count_ui;
            total_stage5_input_record_count_axil_ff2 <= total_stage5_input_record_count_axil_ff1;
            total_stage5_encoded_entry_count_axil_ff1 <= total_stage5_encoded_entry_count_ui;
            total_stage5_encoded_entry_count_axil_ff2 <= total_stage5_encoded_entry_count_axil_ff1;
            total_stage5_output_block_bytes_axil_ff1 <= total_stage5_output_block_bytes_ui;
            total_stage5_output_block_bytes_axil_ff2 <= total_stage5_output_block_bytes_axil_ff1;
            total_stage5_bytes_written_axil_ff1 <= total_stage5_bytes_written_ui;
            total_stage5_bytes_written_axil_ff2 <= total_stage5_bytes_written_axil_ff1;
            perf_cycle_count_axil_ff1           <= perf_cycle_count_ui;
            perf_cycle_count_axil_ff2           <= perf_cycle_count_axil_ff1;

            r_status[0] <= busy_axil_ff2;

            if (can_accept_write && awaddr_valid && w_hs) begin
                case (awaddr_lat)
                    REG_CTRL: begin
                        if (s_axil_wstrb[0]) r_ctrl[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_ctrl[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_ctrl[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_ctrl[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_BLOCK_PAIR_COUNT: begin
                        if (s_axil_wstrb[0]) r_block_pair_count[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_block_pair_count[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_block_pair_count[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_block_pair_count[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_MID_BASE_LO: begin
                        if (s_axil_wstrb[0]) r_mid_base[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_mid_base[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_mid_base[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_mid_base[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_MID_BASE_HI: begin
                        if (s_axil_wstrb[0]) r_mid_base[39:32] <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_mid_base[47:40] <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_mid_base[55:48] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_mid_base[63:56] <= s_axil_wdata[31:24];
                    end
                    REG_SRC0_BASE0_LO: begin
                        if (s_axil_wstrb[0]) r_src0_base_vec[0 +: 8]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src0_base_vec[8 +: 8]   <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src0_base_vec[16 +: 8]  <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src0_base_vec[24 +: 8]  <= s_axil_wdata[31:24];
                    end
                    REG_SRC0_BASE0_HI: begin
                        if (s_axil_wstrb[0]) r_src0_base_vec[32 +: 8]  <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src0_base_vec[40 +: 8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src0_base_vec[48 +: 8]  <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src0_base_vec[56 +: 8]  <= s_axil_wdata[31:24];
                    end
                    REG_SRC0_SIZE0: begin
                        if (s_axil_wstrb[0]) r_src0_size_vec[0 +: 8]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src0_size_vec[8 +: 8]   <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src0_size_vec[16 +: 8]  <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src0_size_vec[24 +: 8]  <= s_axil_wdata[31:24];
                    end
                    REG_SRC1_BASE0_LO: begin
                        if (s_axil_wstrb[0]) r_src1_base_vec[0 +: 8]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src1_base_vec[8 +: 8]   <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src1_base_vec[16 +: 8]  <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src1_base_vec[24 +: 8]  <= s_axil_wdata[31:24];
                    end
                    REG_SRC1_BASE0_HI: begin
                        if (s_axil_wstrb[0]) r_src1_base_vec[32 +: 8]  <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src1_base_vec[40 +: 8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src1_base_vec[48 +: 8]  <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src1_base_vec[56 +: 8]  <= s_axil_wdata[31:24];
                    end
                    REG_SRC1_SIZE0: begin
                        if (s_axil_wstrb[0]) r_src1_size_vec[0 +: 8]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src1_size_vec[8 +: 8]   <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src1_size_vec[16 +: 8]  <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src1_size_vec[24 +: 8]  <= s_axil_wdata[31:24];
                    end
                    REG_DST_BASE0_LO: begin
                        if (s_axil_wstrb[0]) r_dst_base_vec[0 +: 8]    <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_dst_base_vec[8 +: 8]    <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_dst_base_vec[16 +: 8]   <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_dst_base_vec[24 +: 8]   <= s_axil_wdata[31:24];
                    end
                    REG_DST_BASE0_HI: begin
                        if (s_axil_wstrb[0]) r_dst_base_vec[32 +: 8]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_dst_base_vec[40 +: 8]   <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_dst_base_vec[48 +: 8]   <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_dst_base_vec[56 +: 8]   <= s_axil_wdata[31:24];
                    end
                    REG_SRC0_BASE1_LO: begin
                        if (s_axil_wstrb[0]) r_src0_base_vec[AXI_ADDR_WIDTH+0 +: 8]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src0_base_vec[AXI_ADDR_WIDTH+8 +: 8]   <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src0_base_vec[AXI_ADDR_WIDTH+16 +: 8]  <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src0_base_vec[AXI_ADDR_WIDTH+24 +: 8]  <= s_axil_wdata[31:24];
                    end
                    REG_SRC0_BASE1_HI: begin
                        if (s_axil_wstrb[0]) r_src0_base_vec[AXI_ADDR_WIDTH+32 +: 8]  <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src0_base_vec[AXI_ADDR_WIDTH+40 +: 8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src0_base_vec[AXI_ADDR_WIDTH+48 +: 8]  <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src0_base_vec[AXI_ADDR_WIDTH+56 +: 8]  <= s_axil_wdata[31:24];
                    end
                    REG_SRC0_SIZE1: begin
                        if (s_axil_wstrb[0]) r_src0_size_vec[32 +: 8]  <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src0_size_vec[40 +: 8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src0_size_vec[48 +: 8]  <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src0_size_vec[56 +: 8]  <= s_axil_wdata[31:24];
                    end
                    REG_SRC1_BASE1_LO: begin
                        if (s_axil_wstrb[0]) r_src1_base_vec[AXI_ADDR_WIDTH+0 +: 8]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src1_base_vec[AXI_ADDR_WIDTH+8 +: 8]   <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src1_base_vec[AXI_ADDR_WIDTH+16 +: 8]  <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src1_base_vec[AXI_ADDR_WIDTH+24 +: 8]  <= s_axil_wdata[31:24];
                    end
                    REG_SRC1_BASE1_HI: begin
                        if (s_axil_wstrb[0]) r_src1_base_vec[AXI_ADDR_WIDTH+32 +: 8]  <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src1_base_vec[AXI_ADDR_WIDTH+40 +: 8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src1_base_vec[AXI_ADDR_WIDTH+48 +: 8]  <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src1_base_vec[AXI_ADDR_WIDTH+56 +: 8]  <= s_axil_wdata[31:24];
                    end
                    REG_SRC1_SIZE1: begin
                        if (s_axil_wstrb[0]) r_src1_size_vec[32 +: 8]  <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src1_size_vec[40 +: 8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src1_size_vec[48 +: 8]  <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src1_size_vec[56 +: 8]  <= s_axil_wdata[31:24];
                    end
                    REG_DST_BASE1_LO: begin
                        if (s_axil_wstrb[0]) r_dst_base_vec[AXI_ADDR_WIDTH+0 +: 8]    <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_dst_base_vec[AXI_ADDR_WIDTH+8 +: 8]    <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_dst_base_vec[AXI_ADDR_WIDTH+16 +: 8]   <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_dst_base_vec[AXI_ADDR_WIDTH+24 +: 8]   <= s_axil_wdata[31:24];
                    end
                    REG_DST_BASE1_HI: begin
                        if (s_axil_wstrb[0]) r_dst_base_vec[AXI_ADDR_WIDTH+32 +: 8]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_dst_base_vec[AXI_ADDR_WIDTH+40 +: 8]   <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_dst_base_vec[AXI_ADDR_WIDTH+48 +: 8]   <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_dst_base_vec[AXI_ADDR_WIDTH+56 +: 8]   <= s_axil_wdata[31:24];
                    end
                    default: begin
                        for (wr_idx = 0; wr_idx < MAX_BLOCK_PAIRS; wr_idx = wr_idx + 1) begin
                            if (awaddr_lat == (REG_DESC_BASE + (wr_idx * REG_DESC_STRIDE) + REG_DESC_SRC0_BASE_LO_OFF)) begin
                                if (s_axil_wstrb[0]) r_src0_base_vec[(wr_idx*AXI_ADDR_WIDTH)+0 +: 8]   <= s_axil_wdata[7:0];
                                if (s_axil_wstrb[1]) r_src0_base_vec[(wr_idx*AXI_ADDR_WIDTH)+8 +: 8]   <= s_axil_wdata[15:8];
                                if (s_axil_wstrb[2]) r_src0_base_vec[(wr_idx*AXI_ADDR_WIDTH)+16 +: 8]  <= s_axil_wdata[23:16];
                                if (s_axil_wstrb[3]) r_src0_base_vec[(wr_idx*AXI_ADDR_WIDTH)+24 +: 8]  <= s_axil_wdata[31:24];
                            end
                            if (awaddr_lat == (REG_DESC_BASE + (wr_idx * REG_DESC_STRIDE) + REG_DESC_SRC0_BASE_HI_OFF)) begin
                                if (s_axil_wstrb[0]) r_src0_base_vec[(wr_idx*AXI_ADDR_WIDTH)+32 +: 8]  <= s_axil_wdata[7:0];
                                if (s_axil_wstrb[1]) r_src0_base_vec[(wr_idx*AXI_ADDR_WIDTH)+40 +: 8]  <= s_axil_wdata[15:8];
                                if (s_axil_wstrb[2]) r_src0_base_vec[(wr_idx*AXI_ADDR_WIDTH)+48 +: 8]  <= s_axil_wdata[23:16];
                                if (s_axil_wstrb[3]) r_src0_base_vec[(wr_idx*AXI_ADDR_WIDTH)+56 +: 8]  <= s_axil_wdata[31:24];
                            end
                            if (awaddr_lat == (REG_DESC_BASE + (wr_idx * REG_DESC_STRIDE) + REG_DESC_SRC0_SIZE_OFF)) begin
                                if (s_axil_wstrb[0]) r_src0_size_vec[(wr_idx*32)+0 +: 8] <= s_axil_wdata[7:0];
                                if (s_axil_wstrb[1]) r_src0_size_vec[(wr_idx*32)+8 +: 8] <= s_axil_wdata[15:8];
                                if (s_axil_wstrb[2]) r_src0_size_vec[(wr_idx*32)+16 +: 8] <= s_axil_wdata[23:16];
                                if (s_axil_wstrb[3]) r_src0_size_vec[(wr_idx*32)+24 +: 8] <= s_axil_wdata[31:24];
                            end
                            if (awaddr_lat == (REG_DESC_BASE + (wr_idx * REG_DESC_STRIDE) + REG_DESC_SRC1_BASE_LO_OFF)) begin
                                if (s_axil_wstrb[0]) r_src1_base_vec[(wr_idx*AXI_ADDR_WIDTH)+0 +: 8]   <= s_axil_wdata[7:0];
                                if (s_axil_wstrb[1]) r_src1_base_vec[(wr_idx*AXI_ADDR_WIDTH)+8 +: 8]   <= s_axil_wdata[15:8];
                                if (s_axil_wstrb[2]) r_src1_base_vec[(wr_idx*AXI_ADDR_WIDTH)+16 +: 8]  <= s_axil_wdata[23:16];
                                if (s_axil_wstrb[3]) r_src1_base_vec[(wr_idx*AXI_ADDR_WIDTH)+24 +: 8]  <= s_axil_wdata[31:24];
                            end
                            if (awaddr_lat == (REG_DESC_BASE + (wr_idx * REG_DESC_STRIDE) + REG_DESC_SRC1_BASE_HI_OFF)) begin
                                if (s_axil_wstrb[0]) r_src1_base_vec[(wr_idx*AXI_ADDR_WIDTH)+32 +: 8]  <= s_axil_wdata[7:0];
                                if (s_axil_wstrb[1]) r_src1_base_vec[(wr_idx*AXI_ADDR_WIDTH)+40 +: 8]  <= s_axil_wdata[15:8];
                                if (s_axil_wstrb[2]) r_src1_base_vec[(wr_idx*AXI_ADDR_WIDTH)+48 +: 8]  <= s_axil_wdata[23:16];
                                if (s_axil_wstrb[3]) r_src1_base_vec[(wr_idx*AXI_ADDR_WIDTH)+56 +: 8]  <= s_axil_wdata[31:24];
                            end
                            if (awaddr_lat == (REG_DESC_BASE + (wr_idx * REG_DESC_STRIDE) + REG_DESC_SRC1_SIZE_OFF)) begin
                                if (s_axil_wstrb[0]) r_src1_size_vec[(wr_idx*32)+0 +: 8] <= s_axil_wdata[7:0];
                                if (s_axil_wstrb[1]) r_src1_size_vec[(wr_idx*32)+8 +: 8] <= s_axil_wdata[15:8];
                                if (s_axil_wstrb[2]) r_src1_size_vec[(wr_idx*32)+16 +: 8] <= s_axil_wdata[23:16];
                                if (s_axil_wstrb[3]) r_src1_size_vec[(wr_idx*32)+24 +: 8] <= s_axil_wdata[31:24];
                            end
                            if (awaddr_lat == (REG_DESC_BASE + (wr_idx * REG_DESC_STRIDE) + REG_DESC_DST_BASE_LO_OFF)) begin
                                if (s_axil_wstrb[0]) r_dst_base_vec[(wr_idx*AXI_ADDR_WIDTH)+0 +: 8]    <= s_axil_wdata[7:0];
                                if (s_axil_wstrb[1]) r_dst_base_vec[(wr_idx*AXI_ADDR_WIDTH)+8 +: 8]    <= s_axil_wdata[15:8];
                                if (s_axil_wstrb[2]) r_dst_base_vec[(wr_idx*AXI_ADDR_WIDTH)+16 +: 8]   <= s_axil_wdata[23:16];
                                if (s_axil_wstrb[3]) r_dst_base_vec[(wr_idx*AXI_ADDR_WIDTH)+24 +: 8]   <= s_axil_wdata[31:24];
                            end
                            if (awaddr_lat == (REG_DESC_BASE + (wr_idx * REG_DESC_STRIDE) + REG_DESC_DST_BASE_HI_OFF)) begin
                                if (s_axil_wstrb[0]) r_dst_base_vec[(wr_idx*AXI_ADDR_WIDTH)+32 +: 8]   <= s_axil_wdata[7:0];
                                if (s_axil_wstrb[1]) r_dst_base_vec[(wr_idx*AXI_ADDR_WIDTH)+40 +: 8]   <= s_axil_wdata[15:8];
                                if (s_axil_wstrb[2]) r_dst_base_vec[(wr_idx*AXI_ADDR_WIDTH)+48 +: 8]   <= s_axil_wdata[23:16];
                                if (s_axil_wstrb[3]) r_dst_base_vec[(wr_idx*AXI_ADDR_WIDTH)+56 +: 8]   <= s_axil_wdata[31:24];
                            end
                        end
                    end
                endcase
            end

            if (ctrl_clear_pulse || ctrl_start_pulse) begin
                r_status[1] <= 1'b0;
                r_status[2] <= 1'b0;
            end
            if (done_pulse_axil) begin
                r_status[1] <= 1'b1;
            end
            if (error_pulse_axil) begin
                r_status[2] <= 1'b1;
            end

            if (ctrl_start_pulse) begin
                start_toggle_axil <= ~start_toggle_axil;
            end
            if (ctrl_clear_pulse) begin
                clear_toggle_axil <= ~clear_toggle_axil;
            end
        end
    end

    always @(posedge ui_aclk) begin
        if (!ui_aresetn) begin
            start_toggle_ui_ff1         <= 1'b0;
            start_toggle_ui_ff2         <= 1'b0;
            start_toggle_ui_ff3         <= 1'b0;
            clear_toggle_ui_ff1         <= 1'b0;
            clear_toggle_ui_ff2         <= 1'b0;
            clear_toggle_ui_ff3         <= 1'b0;
            cfg_block_pair_count_ui_ff1 <= 32'h0;
            cfg_block_pair_count_ui_ff2 <= 32'h0;
            cfg_mid_base_ui_ff1         <= 64'h0;
            cfg_mid_base_ui_ff2         <= 64'h0;
            cfg_src0_base_vec_ui_ff1    <= {(MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH){1'b0}};
            cfg_src0_base_vec_ui_ff2    <= {(MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH){1'b0}};
            cfg_src0_size_vec_ui_ff1    <= {(MAX_BLOCK_PAIRS*32){1'b0}};
            cfg_src0_size_vec_ui_ff2    <= {(MAX_BLOCK_PAIRS*32){1'b0}};
            cfg_src1_base_vec_ui_ff1    <= {(MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH){1'b0}};
            cfg_src1_base_vec_ui_ff2    <= {(MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH){1'b0}};
            cfg_src1_size_vec_ui_ff1    <= {(MAX_BLOCK_PAIRS*32){1'b0}};
            cfg_src1_size_vec_ui_ff2    <= {(MAX_BLOCK_PAIRS*32){1'b0}};
            cfg_dst_base_vec_ui_ff1     <= {(MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH){1'b0}};
            cfg_dst_base_vec_ui_ff2     <= {(MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH){1'b0}};
            done_ui_d                   <= 1'b0;
            error_ui_d                  <= 1'b0;
            done_toggle_ui              <= 1'b0;
            error_toggle_ui             <= 1'b0;
            perf_counting_ui            <= 1'b0;
            perf_cycle_count_ui         <= 32'h0;
        end else begin
            start_toggle_ui_ff1         <= start_toggle_axil;
            start_toggle_ui_ff2         <= start_toggle_ui_ff1;
            start_toggle_ui_ff3         <= start_toggle_ui_ff2;
            clear_toggle_ui_ff1         <= clear_toggle_axil;
            clear_toggle_ui_ff2         <= clear_toggle_ui_ff1;
            clear_toggle_ui_ff3         <= clear_toggle_ui_ff2;
            cfg_block_pair_count_ui_ff1 <= cfg_block_pair_count_axil;
            cfg_block_pair_count_ui_ff2 <= cfg_block_pair_count_ui_ff1;
            cfg_mid_base_ui_ff1         <= cfg_mid_base_axil;
            cfg_mid_base_ui_ff2         <= cfg_mid_base_ui_ff1;
            cfg_src0_base_vec_ui_ff1    <= cfg_src0_base_vec_axil;
            cfg_src0_base_vec_ui_ff2    <= cfg_src0_base_vec_ui_ff1;
            cfg_src0_size_vec_ui_ff1    <= cfg_src0_size_vec_axil;
            cfg_src0_size_vec_ui_ff2    <= cfg_src0_size_vec_ui_ff1;
            cfg_src1_base_vec_ui_ff1    <= cfg_src1_base_vec_axil;
            cfg_src1_base_vec_ui_ff2    <= cfg_src1_base_vec_ui_ff1;
            cfg_src1_size_vec_ui_ff1    <= cfg_src1_size_vec_axil;
            cfg_src1_size_vec_ui_ff2    <= cfg_src1_size_vec_ui_ff1;
            cfg_dst_base_vec_ui_ff1     <= cfg_dst_base_vec_axil;
            cfg_dst_base_vec_ui_ff2     <= cfg_dst_base_vec_ui_ff1;
            done_ui_d                   <= top_done_ui;
            error_ui_d                  <= top_error_ui;
            if (top_done_ui && !done_ui_d) begin
                done_toggle_ui   <= ~done_toggle_ui;
                perf_counting_ui <= 1'b0;
            end
            if (top_error_ui && !error_ui_d) begin
                error_toggle_ui  <= ~error_toggle_ui;
                perf_counting_ui <= 1'b0;
            end
            if (start_pulse_ui) begin
                perf_counting_ui    <= 1'b1;
                perf_cycle_count_ui <= 32'h0;
            end
            if (clear_pulse_ui) begin
                perf_counting_ui    <= 1'b0;
                perf_cycle_count_ui <= 32'h0;
            end
            if (perf_counting_ui) begin
                perf_cycle_count_ui <= perf_cycle_count_ui + 32'h1;
            end
        end
    end

    always @(posedge axil_aclk) begin
        if (!axil_aresetn) begin
            done_toggle_axil_ff1  <= 1'b0;
            done_toggle_axil_ff2  <= 1'b0;
            error_toggle_axil_ff1 <= 1'b0;
            error_toggle_axil_ff2 <= 1'b0;
        end else begin
            done_toggle_axil_ff1  <= done_toggle_ui;
            done_toggle_axil_ff2  <= done_toggle_axil_ff1;
            error_toggle_axil_ff1 <= error_toggle_ui;
            error_toggle_axil_ff2 <= error_toggle_axil_ff1;
        end
    end

    stage4_real_internal_key_two_way_merge_stage5_nblock_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
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
        .MAX_BLOCK_PAIRS(MAX_BLOCK_PAIRS)
    ) u_nblock_top (
        .clk(ui_aclk),
        .rstn(ui_aresetn),
        .clear(clear_pulse_ui),
        .start(start_pulse_ui),
        .max_file_size(32'd0),
        .block_pair_count(cfg_block_pair_count_ui_ff2),
        .src0_base_addr_vec(cfg_src0_base_vec_ui_ff2),
        .src0_byte_count_vec(cfg_src0_size_vec_ui_ff2),
        .src1_base_addr_vec(cfg_src1_base_vec_ui_ff2),
        .src1_byte_count_vec(cfg_src1_size_vec_ui_ff2),
        .dst_base_addr(cfg_dst_base_vec_ui_ff2[AXI_ADDR_WIDTH-1:0]),
        .mid_base_addr(cfg_mid_base_ui_ff2),
        // OPT-P1c: streaming descriptor ports (unused, USE_DESC_STREAM=0)
        .desc_valid(1'b0),
        .desc_ready(),
        .desc_src0_addr({AXI_ADDR_WIDTH{1'b0}}),
        .desc_src0_size(32'd0),
        .desc_src1_addr({AXI_ADDR_WIDTH{1'b0}}),
        .desc_src1_size(32'd0),
        .desc_last(1'b0),
        .sstable_total_bytes(),
        .busy(top_busy_ui),
        .done(top_done_ui),
        .error(top_error_ui),
        .active_block_index(active_block_index_ui),
        .blocks_completed(blocks_completed_ui),
        .dst_output_block_bytes_vec(dst_output_block_bytes_vec_ui),
        .total_source0_decoded_entry_count(total_source0_decoded_entry_count_ui),
        .total_source1_decoded_entry_count(total_source1_decoded_entry_count_ui),
        .total_source0_bytes_read(total_source0_bytes_read_ui),
        .total_source1_bytes_read(total_source1_bytes_read_ui),
        .total_merge_output_byte_count(total_merge_output_byte_count_ui),
        .total_merge_decoded_record_count(total_merge_decoded_record_count_ui),
        .total_merge_merged_record_count(total_merge_merged_record_count_ui),
        .total_merge_dropped_superseded_count(total_merge_dropped_superseded_count_ui),
        .total_stage5_input_record_count(total_stage5_input_record_count_ui),
        .total_stage5_encoded_entry_count(total_stage5_encoded_entry_count_ui),
        .total_stage5_output_block_bytes(total_stage5_output_block_bytes_ui),
        .total_stage5_bytes_written(total_stage5_bytes_written_ui),
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
endmodule
`timescale 1ns / 1ps

module real_internal_key_two_way_merge_stage5_nblock_top #(
    parameter integer AXIL_ADDR_WIDTH             = 32,
    parameter integer AXIL_DATA_WIDTH             = 32,
    parameter integer AXI_ADDR_WIDTH              = 64,
    parameter integer AXI_DATA_WIDTH              = 512,
    parameter integer AXI_STRB_WIDTH              = 64,
    parameter integer MAX_BURST_LEN               = 16,
    parameter integer STAGE4_MAX_BLOCK_BYTES      = 4096,
    parameter integer STAGE4_MAX_KEY_BYTES        = 264,
    parameter integer MERGE_MAX_USER_KEY_BYTES    = 256,
    parameter integer MERGE_MAX_KEY_BYTES         = 264,
    parameter integer MERGE_MAX_VALUE_BYTES       = 1024,
    parameter integer MERGE_MAX_RECORD_BYTES      = 2048,
    parameter integer MERGE_MAX_RECORDS           = 256,
    parameter integer MERGE_MAX_OUTPUT_BYTES      = 73728,
    parameter integer STAGE5_MAX_RECORDS          = 256,
    parameter integer STAGE5_MAX_PAYLOAD_BYTES    = 4096,
    parameter integer STAGE5_MAX_BLOCK_BYTES      = 4096,
    parameter integer STAGE5_MAX_KEY_BYTES        = 256,
    parameter integer STAGE5_MAX_VALUE_BYTES      = 1024,
    parameter integer STAGE5_RESTART_INTERVAL     = 16,
    parameter integer MAX_BLOCK_PAIRS             = 8
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axil_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME axil_aclk, ASSOCIATED_BUSIF s_axil, ASSOCIATED_RESET axil_aresetn, FREQ_HZ 250000000" *)
    input  wire                        axil_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axil_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME axil_aresetn, POLARITY ACTIVE_LOW" *)
    input  wire                        axil_aresetn,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axil, ADDR_WIDTH 32, DATA_WIDTH 32, PROTOCOL AXI4LITE, FREQ_HZ 250000000, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 1" *)
    input  wire [AXIL_ADDR_WIDTH-1:0]   s_axil_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil AWVALID" *)
    input  wire                        s_axil_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil AWREADY" *)
    output wire                        s_axil_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil WDATA" *)
    input  wire [AXIL_DATA_WIDTH-1:0]   s_axil_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil WSTRB" *)
    input  wire [AXIL_DATA_WIDTH/8-1:0] s_axil_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil WVALID" *)
    input  wire                        s_axil_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil WREADY" *)
    output wire                        s_axil_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil BRESP" *)
    output wire [1:0]                  s_axil_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil BVALID" *)
    output wire                        s_axil_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil BREADY" *)
    input  wire                        s_axil_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil ARADDR" *)
    input  wire [AXIL_ADDR_WIDTH-1:0]   s_axil_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil ARVALID" *)
    input  wire                        s_axil_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil ARREADY" *)
    output wire                        s_axil_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil RDATA" *)
    output wire [AXIL_DATA_WIDTH-1:0]   s_axil_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil RRESP" *)
    output wire [1:0]                  s_axil_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil RVALID" *)
    output wire                        s_axil_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil RREADY" *)
    input  wire                        s_axil_rready,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ui_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ui_aclk, ASSOCIATED_BUSIF m_axi_src0:m_axi_src1:m_axi_chain, ASSOCIATED_RESET ui_aresetn, FREQ_HZ 300000000" *)
    input  wire                        ui_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ui_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ui_aresetn, POLARITY ACTIVE_LOW" *)
    input  wire                        ui_aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src0 ARADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi_src0, ADDR_WIDTH 64, DATA_WIDTH 512, PROTOCOL AXI4, FREQ_HZ 300000000, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_ONLY, HAS_BURST 1, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 0, HAS_BRESP 0, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 16, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 0" *)
    output wire [AXI_ADDR_WIDTH-1:0]   m_axi_src0_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src0 ARLEN" *)
    output wire [7:0]                  m_axi_src0_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src0 ARSIZE" *)
    output wire [2:0]                  m_axi_src0_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src0 ARBURST" *)
    output wire [1:0]                  m_axi_src0_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src0 ARVALID" *)
    output wire                        m_axi_src0_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src0 ARREADY" *)
    input  wire                        m_axi_src0_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src0 RDATA" *)
    input  wire [AXI_DATA_WIDTH-1:0]   m_axi_src0_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src0 RRESP" *)
    input  wire [1:0]                  m_axi_src0_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src0 RLAST" *)
    input  wire                        m_axi_src0_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src0 RVALID" *)
    input  wire                        m_axi_src0_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src0 RREADY" *)
    output wire                        m_axi_src0_rready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src1 ARADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi_src1, ADDR_WIDTH 64, DATA_WIDTH 512, PROTOCOL AXI4, FREQ_HZ 300000000, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_ONLY, HAS_BURST 1, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 0, HAS_BRESP 0, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 16, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 0" *)
    output wire [AXI_ADDR_WIDTH-1:0]   m_axi_src1_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src1 ARLEN" *)
    output wire [7:0]                  m_axi_src1_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src1 ARSIZE" *)
    output wire [2:0]                  m_axi_src1_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src1 ARBURST" *)
    output wire [1:0]                  m_axi_src1_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src1 ARVALID" *)
    output wire                        m_axi_src1_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src1 ARREADY" *)
    input  wire                        m_axi_src1_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src1 RDATA" *)
    input  wire [AXI_DATA_WIDTH-1:0]   m_axi_src1_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src1 RRESP" *)
    input  wire [1:0]                  m_axi_src1_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src1 RLAST" *)
    input  wire                        m_axi_src1_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src1 RVALID" *)
    input  wire                        m_axi_src1_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src1 RREADY" *)
    output wire                        m_axi_src1_rready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain ARADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi_chain, ADDR_WIDTH 64, DATA_WIDTH 512, PROTOCOL AXI4, FREQ_HZ 300000000, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 1, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 16, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1" *)
    output wire [AXI_ADDR_WIDTH-1:0]   m_axi_chain_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain ARLEN" *)
    output wire [7:0]                  m_axi_chain_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain ARSIZE" *)
    output wire [2:0]                  m_axi_chain_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain ARBURST" *)
    output wire [1:0]                  m_axi_chain_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain ARVALID" *)
    output wire                        m_axi_chain_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain ARREADY" *)
    input  wire                        m_axi_chain_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain RDATA" *)
    input  wire [AXI_DATA_WIDTH-1:0]   m_axi_chain_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain RRESP" *)
    input  wire [1:0]                  m_axi_chain_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain RLAST" *)
    input  wire                        m_axi_chain_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain RVALID" *)
    input  wire                        m_axi_chain_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain RREADY" *)
    output wire                        m_axi_chain_rready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain AWADDR" *)
    output wire [AXI_ADDR_WIDTH-1:0]   m_axi_chain_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain AWLEN" *)
    output wire [7:0]                  m_axi_chain_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain AWSIZE" *)
    output wire [2:0]                  m_axi_chain_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain AWBURST" *)
    output wire [1:0]                  m_axi_chain_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain AWVALID" *)
    output wire                        m_axi_chain_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain AWREADY" *)
    input  wire                        m_axi_chain_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain WDATA" *)
    output wire [AXI_DATA_WIDTH-1:0]   m_axi_chain_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain WSTRB" *)
    output wire [AXI_STRB_WIDTH-1:0]   m_axi_chain_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain WLAST" *)
    output wire                        m_axi_chain_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain WVALID" *)
    output wire                        m_axi_chain_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain WREADY" *)
    input  wire                        m_axi_chain_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain BRESP" *)
    input  wire [1:0]                  m_axi_chain_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain BVALID" *)
    input  wire                        m_axi_chain_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain BREADY" *)
    output wire                        m_axi_chain_bready,

    output wire                        done,
    output wire                        busy,
    output wire                        error,
    output wire [31:0]                 bytes_done,
    output wire [31:0]                 blocks_done
);

    stage4_real_internal_key_two_way_merge_stage5_nblock_axil_top #(
        .AXIL_ADDR_WIDTH(AXIL_ADDR_WIDTH),
        .AXIL_DATA_WIDTH(AXIL_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_STRB_WIDTH(AXI_STRB_WIDTH),
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
        .MAX_BLOCK_PAIRS(MAX_BLOCK_PAIRS)
    ) u_nblock_axil_top (
        .axil_aclk(axil_aclk),
        .axil_aresetn(axil_aresetn),
        .s_axil_awaddr(s_axil_awaddr),
        .s_axil_awvalid(s_axil_awvalid),
        .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata),
        .s_axil_wstrb(s_axil_wstrb),
        .s_axil_wvalid(s_axil_wvalid),
        .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp),
        .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr),
        .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata),
        .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid),
        .s_axil_rready(s_axil_rready),
        .ui_aclk(ui_aclk),
        .ui_aresetn(ui_aresetn),
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
        .m_axi_chain_bready(m_axi_chain_bready),
        .done(done),
        .busy(busy),
        .error(error),
        .bytes_done(bytes_done),
        .blocks_done(blocks_done)
    );
endmodule
