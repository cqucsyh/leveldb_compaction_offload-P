`timescale 1ns / 1ps

module stage4_real_internal_key_two_way_merge_stage5_sstable_chain_axil_top #(
    parameter integer AXIL_ADDR_WIDTH             = 32,
    parameter integer AXIL_DATA_WIDTH             = 32,
    parameter integer AXI_ADDR_WIDTH              = 64,
    parameter integer AXI_DATA_WIDTH              = 512,
    parameter integer AXI_STRB_WIDTH              = 64,
    parameter integer MAX_BURST_LEN               = 16,
    parameter integer MAX_SSTABLE_BYTES           = 16384,
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
    parameter integer STAGE5_RESTART_INTERVAL     = 16
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

    output reg  [AXI_DATA_WIDTH-1:0]     dbg_last_accum,
    output wire                          done,
    output wire                          busy,
    output wire                          error,
    output wire [31:0]                   bytes_done,
    output wire [31:0]                   blocks_done
);

    localparam [AXIL_ADDR_WIDTH-1:0] REG_CTRL                         = 32'h0000;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_STATUS                       = 32'h0004;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_BASE_LO                 = 32'h0008;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_BASE_HI                 = 32'h000C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_SIZE                    = 32'h0010;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_BLOCK_INDEX             = 32'h0014;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_BASE_LO                 = 32'h0018;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_BASE_HI                 = 32'h001C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_SIZE                    = 32'h0020;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_BLOCK_INDEX             = 32'h0024;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_MID_BASE_LO                  = 32'h0028;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_MID_BASE_HI                  = 32'h002C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DST_BASE_LO                  = 32'h0030;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DST_BASE_HI                  = 32'h0034;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_SELECTED_BLOCK_OFF_LO   = 32'h0038;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_SELECTED_BLOCK_OFF_HI   = 32'h003C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_SELECTED_BLOCK_SIZE     = 32'h0040;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_COMPRESSION_TYPE        = 32'h0044;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_INDEX_ENTRY_COUNT       = 32'h0048;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_SELECTED_BLOCK_OFF_LO   = 32'h004C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_SELECTED_BLOCK_OFF_HI   = 32'h0050;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_SELECTED_BLOCK_SIZE     = 32'h0054;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_COMPRESSION_TYPE        = 32'h0058;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_INDEX_ENTRY_COUNT       = 32'h005C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SOURCE0_DECODED_ENTRY_COUNT  = 32'h0060;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SOURCE1_DECODED_ENTRY_COUNT  = 32'h0064;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SOURCE0_BYTES_READ           = 32'h0068;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SOURCE1_BYTES_READ           = 32'h006C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_MERGE_OUTPUT_BYTE_COUNT      = 32'h0070;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_MERGE_DECODED_RECORD_COUNT   = 32'h0074;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_MERGE_MERGED_RECORD_COUNT    = 32'h0078;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_MERGE_DROPPED_RECORD_COUNT   = 32'h007C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_STAGE5_INPUT_RECORD_COUNT    = 32'h0080;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_STAGE5_ENCODED_ENTRY_COUNT   = 32'h0084;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_STAGE5_OUTPUT_BLOCK_BYTES    = 32'h0088;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_STAGE5_BYTES_WRITTEN         = 32'h008C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_FINAL_PREV_USER_KEY_LEN      = 32'h0090;

    reg [31:0] r_ctrl;
    reg [31:0] r_status;
    reg [63:0] r_src0_base;
    reg [31:0] r_src0_size;
    reg [31:0] r_src0_block_index;
    reg [63:0] r_src1_base;
    reg [31:0] r_src1_size;
    reg [31:0] r_src1_block_index;
    reg [63:0] r_mid_base;
    reg [63:0] r_dst_base;

    reg [AXIL_ADDR_WIDTH-1:0] awaddr_lat;
    reg                       awaddr_valid;
    reg [AXIL_ADDR_WIDTH-1:0] araddr_lat;
    reg                       araddr_pending;

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
    reg        start_toggle_ui_ff1;
    reg        start_toggle_ui_ff2;
    reg        start_toggle_ui_ff3;
    reg        clear_toggle_ui_ff1;
    reg        clear_toggle_ui_ff2;
    reg        clear_toggle_ui_ff3;
    wire start_pulse_ui = start_toggle_ui_ff3 ^ start_toggle_ui_ff2;
    wire clear_pulse_ui = clear_toggle_ui_ff3 ^ clear_toggle_ui_ff2;

    reg [63:0] cfg_src0_base_ui_ff1;
    reg [63:0] cfg_src0_base_ui_ff2;
    reg [31:0] cfg_src0_size_ui_ff1;
    reg [31:0] cfg_src0_size_ui_ff2;
    reg [31:0] cfg_src0_block_index_ui_ff1;
    reg [31:0] cfg_src0_block_index_ui_ff2;
    reg [63:0] cfg_src1_base_ui_ff1;
    reg [63:0] cfg_src1_base_ui_ff2;
    reg [31:0] cfg_src1_size_ui_ff1;
    reg [31:0] cfg_src1_size_ui_ff2;
    reg [31:0] cfg_src1_block_index_ui_ff1;
    reg [31:0] cfg_src1_block_index_ui_ff2;
    reg [63:0] cfg_mid_base_ui_ff1;
    reg [63:0] cfg_mid_base_ui_ff2;
    reg [63:0] cfg_dst_base_ui_ff1;
    reg [63:0] cfg_dst_base_ui_ff2;

    wire        top_busy_ui;
    wire        top_done_ui;
    wire        top_error_ui;
    wire [31:0] source0_decoded_entry_count_ui;
    wire [31:0] source0_bytes_read_ui;
    wire [AXI_ADDR_WIDTH-1:0] source0_selected_block_offset_ui;
    wire [31:0] source0_selected_block_size_ui;
    wire [7:0]  source0_selected_block_compression_type_ui;
    wire [31:0] source0_index_entry_count_ui;
    wire [31:0] source1_decoded_entry_count_ui;
    wire [31:0] source1_bytes_read_ui;
    wire [AXI_ADDR_WIDTH-1:0] source1_selected_block_offset_ui;
    wire [31:0] source1_selected_block_size_ui;
    wire [7:0]  source1_selected_block_compression_type_ui;
    wire [31:0] source1_index_entry_count_ui;
    wire [31:0] merge_output_byte_count_ui;
    wire [31:0] merge_decoded_record_count_ui;
    wire [31:0] merge_merged_record_count_ui;
    wire [31:0] merge_dropped_superseded_count_ui;
    wire [31:0] stage5_input_record_count_ui;
    wire [31:0] stage5_encoded_entry_count_ui;
    wire [31:0] stage5_output_block_bytes_ui;
    wire [31:0] stage5_bytes_written_ui;
    wire        final_prev_user_key_valid_ui;
    wire [15:0] final_prev_user_key_len_ui;
    wire [(MERGE_MAX_USER_KEY_BYTES*8)-1:0] final_prev_user_key_ui;

    reg done_ui_d;
    reg error_ui_d;
    reg done_toggle_ui;
    reg error_toggle_ui;
    reg done_toggle_axil_ff1;
    reg done_toggle_axil_ff2;
    reg error_toggle_axil_ff1;
    reg error_toggle_axil_ff2;
    wire done_pulse_axil  = done_toggle_axil_ff2 ^ done_toggle_axil_ff1;
    wire error_pulse_axil = error_toggle_axil_ff2 ^ error_toggle_axil_ff1;

    reg        busy_axil_ff1;
    reg        busy_axil_ff2;
    reg [31:0] source0_decoded_entry_count_axil_ff1;
    reg [31:0] source0_decoded_entry_count_axil_ff2;
    reg [31:0] source0_bytes_read_axil_ff1;
    reg [31:0] source0_bytes_read_axil_ff2;
    reg [AXI_ADDR_WIDTH-1:0] source0_selected_block_offset_axil_ff1;
    reg [AXI_ADDR_WIDTH-1:0] source0_selected_block_offset_axil_ff2;
    reg [31:0] source0_selected_block_size_axil_ff1;
    reg [31:0] source0_selected_block_size_axil_ff2;
    reg [7:0]  source0_selected_block_compression_type_axil_ff1;
    reg [7:0]  source0_selected_block_compression_type_axil_ff2;
    reg [31:0] source0_index_entry_count_axil_ff1;
    reg [31:0] source0_index_entry_count_axil_ff2;
    reg [31:0] source1_decoded_entry_count_axil_ff1;
    reg [31:0] source1_decoded_entry_count_axil_ff2;
    reg [31:0] source1_bytes_read_axil_ff1;
    reg [31:0] source1_bytes_read_axil_ff2;
    reg [AXI_ADDR_WIDTH-1:0] source1_selected_block_offset_axil_ff1;
    reg [AXI_ADDR_WIDTH-1:0] source1_selected_block_offset_axil_ff2;
    reg [31:0] source1_selected_block_size_axil_ff1;
    reg [31:0] source1_selected_block_size_axil_ff2;
    reg [7:0]  source1_selected_block_compression_type_axil_ff1;
    reg [7:0]  source1_selected_block_compression_type_axil_ff2;
    reg [31:0] source1_index_entry_count_axil_ff1;
    reg [31:0] source1_index_entry_count_axil_ff2;
    reg [31:0] merge_output_byte_count_axil_ff1;
    reg [31:0] merge_output_byte_count_axil_ff2;
    reg [31:0] merge_decoded_record_count_axil_ff1;
    reg [31:0] merge_decoded_record_count_axil_ff2;
    reg [31:0] merge_merged_record_count_axil_ff1;
    reg [31:0] merge_merged_record_count_axil_ff2;
    reg [31:0] merge_dropped_superseded_count_axil_ff1;
    reg [31:0] merge_dropped_superseded_count_axil_ff2;
    reg [31:0] stage5_input_record_count_axil_ff1;
    reg [31:0] stage5_input_record_count_axil_ff2;
    reg [31:0] stage5_encoded_entry_count_axil_ff1;
    reg [31:0] stage5_encoded_entry_count_axil_ff2;
    reg [31:0] stage5_output_block_bytes_axil_ff1;
    reg [31:0] stage5_output_block_bytes_axil_ff2;
    reg [31:0] stage5_bytes_written_axil_ff1;
    reg [31:0] stage5_bytes_written_axil_ff2;
    reg [15:0] final_prev_user_key_len_axil_ff1;
    reg [15:0] final_prev_user_key_len_axil_ff2;

    assign done        = r_status[1];
    assign busy        = busy_axil_ff2;
    assign error       = r_status[2];
    assign bytes_done  = stage5_bytes_written_axil_ff2;
    assign blocks_done = stage5_encoded_entry_count_axil_ff2;

    function [AXIL_DATA_WIDTH-1:0] axil_read_data_for_addr;
        input [AXIL_ADDR_WIDTH-1:0] addr;
        begin
            case (addr)
                REG_CTRL:                        axil_read_data_for_addr = r_ctrl;
                REG_STATUS:                      axil_read_data_for_addr = r_status;
                REG_SRC0_BASE_LO:                axil_read_data_for_addr = r_src0_base[31:0];
                REG_SRC0_BASE_HI:                axil_read_data_for_addr = r_src0_base[63:32];
                REG_SRC0_SIZE:                   axil_read_data_for_addr = r_src0_size;
                REG_SRC0_BLOCK_INDEX:            axil_read_data_for_addr = r_src0_block_index;
                REG_SRC1_BASE_LO:                axil_read_data_for_addr = r_src1_base[31:0];
                REG_SRC1_BASE_HI:                axil_read_data_for_addr = r_src1_base[63:32];
                REG_SRC1_SIZE:                   axil_read_data_for_addr = r_src1_size;
                REG_SRC1_BLOCK_INDEX:            axil_read_data_for_addr = r_src1_block_index;
                REG_MID_BASE_LO:                 axil_read_data_for_addr = r_mid_base[31:0];
                REG_MID_BASE_HI:                 axil_read_data_for_addr = r_mid_base[63:32];
                REG_DST_BASE_LO:                 axil_read_data_for_addr = r_dst_base[31:0];
                REG_DST_BASE_HI:                 axil_read_data_for_addr = r_dst_base[63:32];
                REG_SRC0_SELECTED_BLOCK_OFF_LO:  axil_read_data_for_addr = source0_selected_block_offset_axil_ff2[31:0];
                REG_SRC0_SELECTED_BLOCK_OFF_HI:  axil_read_data_for_addr = source0_selected_block_offset_axil_ff2[63:32];
                REG_SRC0_SELECTED_BLOCK_SIZE:    axil_read_data_for_addr = source0_selected_block_size_axil_ff2;
                REG_SRC0_COMPRESSION_TYPE:       axil_read_data_for_addr = {24'h0, source0_selected_block_compression_type_axil_ff2};
                REG_SRC0_INDEX_ENTRY_COUNT:      axil_read_data_for_addr = source0_index_entry_count_axil_ff2;
                REG_SRC1_SELECTED_BLOCK_OFF_LO:  axil_read_data_for_addr = source1_selected_block_offset_axil_ff2[31:0];
                REG_SRC1_SELECTED_BLOCK_OFF_HI:  axil_read_data_for_addr = source1_selected_block_offset_axil_ff2[63:32];
                REG_SRC1_SELECTED_BLOCK_SIZE:    axil_read_data_for_addr = source1_selected_block_size_axil_ff2;
                REG_SRC1_COMPRESSION_TYPE:       axil_read_data_for_addr = {24'h0, source1_selected_block_compression_type_axil_ff2};
                REG_SRC1_INDEX_ENTRY_COUNT:      axil_read_data_for_addr = source1_index_entry_count_axil_ff2;
                REG_SOURCE0_DECODED_ENTRY_COUNT: axil_read_data_for_addr = source0_decoded_entry_count_axil_ff2;
                REG_SOURCE1_DECODED_ENTRY_COUNT: axil_read_data_for_addr = source1_decoded_entry_count_axil_ff2;
                REG_SOURCE0_BYTES_READ:          axil_read_data_for_addr = source0_bytes_read_axil_ff2;
                REG_SOURCE1_BYTES_READ:          axil_read_data_for_addr = source1_bytes_read_axil_ff2;
                REG_MERGE_OUTPUT_BYTE_COUNT:     axil_read_data_for_addr = merge_output_byte_count_axil_ff2;
                REG_MERGE_DECODED_RECORD_COUNT:  axil_read_data_for_addr = merge_decoded_record_count_axil_ff2;
                REG_MERGE_MERGED_RECORD_COUNT:   axil_read_data_for_addr = merge_merged_record_count_axil_ff2;
                REG_MERGE_DROPPED_RECORD_COUNT:  axil_read_data_for_addr = merge_dropped_superseded_count_axil_ff2;
                REG_STAGE5_INPUT_RECORD_COUNT:   axil_read_data_for_addr = stage5_input_record_count_axil_ff2;
                REG_STAGE5_ENCODED_ENTRY_COUNT:  axil_read_data_for_addr = stage5_encoded_entry_count_axil_ff2;
                REG_STAGE5_OUTPUT_BLOCK_BYTES:   axil_read_data_for_addr = stage5_output_block_bytes_axil_ff2;
                REG_STAGE5_BYTES_WRITTEN:        axil_read_data_for_addr = stage5_bytes_written_axil_ff2;
                REG_FINAL_PREV_USER_KEY_LEN:     axil_read_data_for_addr = {15'h0, final_prev_user_key_valid_ui, final_prev_user_key_len_axil_ff2};
                default:                         axil_read_data_for_addr = 32'h0;
            endcase
        end
    endfunction

    always @(posedge axil_aclk) begin
        if (!axil_aresetn) begin
            s_axil_awready <= 1'b0;
            s_axil_wready  <= 1'b0;
            s_axil_bresp   <= 2'b00;
            s_axil_bvalid  <= 1'b0;
            awaddr_lat     <= {AXIL_ADDR_WIDTH{1'b0}};
            awaddr_valid   <= 1'b0;
        end else begin
            s_axil_awready <= can_accept_write && !awaddr_valid;
            s_axil_wready  <= can_accept_write;

            if (aw_hs) begin
                awaddr_lat   <= s_axil_awaddr;
                awaddr_valid <= 1'b1;
            end else if (can_accept_write && awaddr_valid && w_hs) begin
                awaddr_valid <= 1'b0;
            end

            if (can_accept_write && awaddr_valid && w_hs) begin
                s_axil_bvalid <= 1'b1;
                s_axil_bresp  <= 2'b00;
            end else if (b_hs) begin
                s_axil_bvalid <= 1'b0;
            end
        end
    end

    always @(posedge axil_aclk) begin
        if (!axil_aresetn) begin
            s_axil_arready <= 1'b1;
            s_axil_rvalid  <= 1'b0;
            s_axil_rresp   <= 2'b00;
            s_axil_rdata   <= {AXIL_DATA_WIDTH{1'b0}};
            araddr_lat     <= {AXIL_ADDR_WIDTH{1'b0}};
            araddr_pending <= 1'b0;
        end else begin
            s_axil_arready <= ~s_axil_rvalid && ~araddr_pending;
            if (ar_hs) begin
                araddr_lat     <= s_axil_araddr;
                araddr_pending <= 1'b1;
            end

            if (araddr_pending) begin
                s_axil_rvalid <= 1'b1;
                s_axil_rresp  <= 2'b00;
                s_axil_rdata  <= axil_read_data_for_addr(araddr_lat);
                araddr_pending <= 1'b0;
            end else if (r_hs) begin
                s_axil_rvalid <= 1'b0;
            end
        end
    end

    always @(posedge axil_aclk) begin
        if (!axil_aresetn) begin
            r_ctrl            <= 32'h0;
            r_status          <= 32'h0;
            r_src0_base       <= 64'h0;
            r_src0_size       <= 32'h0;
            r_src0_block_index <= 32'h0;
            r_src1_base       <= 64'h0;
            r_src1_size       <= 32'h0;
            r_src1_block_index <= 32'h0;
            r_mid_base        <= 64'h0;
            r_dst_base        <= 64'h0;
            ctrl_start_d      <= 1'b0;
            ctrl_clear_d      <= 1'b0;
            start_toggle_axil <= 1'b0;
            clear_toggle_axil <= 1'b0;
            r_status[1]       <= 1'b0;
            r_status[2]       <= 1'b0;
        end else begin
            ctrl_start_d <= r_ctrl[0];
            ctrl_clear_d <= r_ctrl[1];
            r_status[0]  <= busy_axil_ff2;

            if (can_accept_write && awaddr_valid && w_hs) begin
                case (awaddr_lat)
                    REG_CTRL: begin
                        if (s_axil_wstrb[0]) r_ctrl[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_ctrl[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_ctrl[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_ctrl[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_SRC0_BASE_LO: begin
                        if (s_axil_wstrb[0]) r_src0_base[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src0_base[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src0_base[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src0_base[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_SRC0_BASE_HI: begin
                        if (s_axil_wstrb[0]) r_src0_base[39:32] <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src0_base[47:40] <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src0_base[55:48] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src0_base[63:56] <= s_axil_wdata[31:24];
                    end
                    REG_SRC0_SIZE: begin
                        if (s_axil_wstrb[0]) r_src0_size[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src0_size[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src0_size[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src0_size[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_SRC0_BLOCK_INDEX: begin
                        if (s_axil_wstrb[0]) r_src0_block_index[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src0_block_index[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src0_block_index[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src0_block_index[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_SRC1_BASE_LO: begin
                        if (s_axil_wstrb[0]) r_src1_base[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src1_base[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src1_base[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src1_base[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_SRC1_BASE_HI: begin
                        if (s_axil_wstrb[0]) r_src1_base[39:32] <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src1_base[47:40] <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src1_base[55:48] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src1_base[63:56] <= s_axil_wdata[31:24];
                    end
                    REG_SRC1_SIZE: begin
                        if (s_axil_wstrb[0]) r_src1_size[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src1_size[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src1_size[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src1_size[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_SRC1_BLOCK_INDEX: begin
                        if (s_axil_wstrb[0]) r_src1_block_index[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src1_block_index[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src1_block_index[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src1_block_index[31:24] <= s_axil_wdata[31:24];
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
                    REG_DST_BASE_LO: begin
                        if (s_axil_wstrb[0]) r_dst_base[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_dst_base[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_dst_base[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_dst_base[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_DST_BASE_HI: begin
                        if (s_axil_wstrb[0]) r_dst_base[39:32] <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_dst_base[47:40] <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_dst_base[55:48] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_dst_base[63:56] <= s_axil_wdata[31:24];
                    end
                    default: begin
                    end
                endcase
            end

            if (ctrl_start_pulse) begin
                r_ctrl[0]   <= 1'b0;
                r_status[1] <= 1'b0;
                r_status[2] <= 1'b0;
                start_toggle_axil <= ~start_toggle_axil;
            end

            if (ctrl_clear_pulse) begin
                r_ctrl[1]   <= 1'b0;
                r_status[1] <= 1'b0;
                r_status[2] <= 1'b0;
                clear_toggle_axil <= ~clear_toggle_axil;
            end

            if (done_pulse_axil) begin
                r_status[1] <= 1'b1;
            end

            if (error_pulse_axil) begin
                r_status[2] <= 1'b1;
            end
        end
    end

    always @(posedge ui_aclk) begin
        if (!ui_aresetn) begin
            start_toggle_ui_ff1 <= 1'b0;
            start_toggle_ui_ff2 <= 1'b0;
            start_toggle_ui_ff3 <= 1'b0;
            clear_toggle_ui_ff1 <= 1'b0;
            clear_toggle_ui_ff2 <= 1'b0;
            clear_toggle_ui_ff3 <= 1'b0;
            cfg_src0_base_ui_ff1 <= 64'h0;
            cfg_src0_base_ui_ff2 <= 64'h0;
            cfg_src0_size_ui_ff1 <= 32'h0;
            cfg_src0_size_ui_ff2 <= 32'h0;
            cfg_src0_block_index_ui_ff1 <= 32'h0;
            cfg_src0_block_index_ui_ff2 <= 32'h0;
            cfg_src1_base_ui_ff1 <= 64'h0;
            cfg_src1_base_ui_ff2 <= 64'h0;
            cfg_src1_size_ui_ff1 <= 32'h0;
            cfg_src1_size_ui_ff2 <= 32'h0;
            cfg_src1_block_index_ui_ff1 <= 32'h0;
            cfg_src1_block_index_ui_ff2 <= 32'h0;
            cfg_mid_base_ui_ff1 <= 64'h0;
            cfg_mid_base_ui_ff2 <= 64'h0;
            cfg_dst_base_ui_ff1 <= 64'h0;
            cfg_dst_base_ui_ff2 <= 64'h0;
            done_ui_d <= 1'b0;
            error_ui_d <= 1'b0;
            done_toggle_ui <= 1'b0;
            error_toggle_ui <= 1'b0;
            dbg_last_accum <= {AXI_DATA_WIDTH{1'b0}};
        end else begin
            start_toggle_ui_ff1 <= start_toggle_axil;
            start_toggle_ui_ff2 <= start_toggle_ui_ff1;
            start_toggle_ui_ff3 <= start_toggle_ui_ff2;
            clear_toggle_ui_ff1 <= clear_toggle_axil;
            clear_toggle_ui_ff2 <= clear_toggle_ui_ff1;
            clear_toggle_ui_ff3 <= clear_toggle_ui_ff2;

            cfg_src0_base_ui_ff1 <= r_src0_base;
            cfg_src0_base_ui_ff2 <= cfg_src0_base_ui_ff1;
            cfg_src0_size_ui_ff1 <= r_src0_size;
            cfg_src0_size_ui_ff2 <= cfg_src0_size_ui_ff1;
            cfg_src0_block_index_ui_ff1 <= r_src0_block_index;
            cfg_src0_block_index_ui_ff2 <= cfg_src0_block_index_ui_ff1;
            cfg_src1_base_ui_ff1 <= r_src1_base;
            cfg_src1_base_ui_ff2 <= cfg_src1_base_ui_ff1;
            cfg_src1_size_ui_ff1 <= r_src1_size;
            cfg_src1_size_ui_ff2 <= cfg_src1_size_ui_ff1;
            cfg_src1_block_index_ui_ff1 <= r_src1_block_index;
            cfg_src1_block_index_ui_ff2 <= cfg_src1_block_index_ui_ff1;
            cfg_mid_base_ui_ff1 <= r_mid_base;
            cfg_mid_base_ui_ff2 <= cfg_mid_base_ui_ff1;
            cfg_dst_base_ui_ff1 <= r_dst_base;
            cfg_dst_base_ui_ff2 <= cfg_dst_base_ui_ff1;

            done_ui_d  <= top_done_ui;
            error_ui_d <= top_error_ui;
            if (top_done_ui & ~done_ui_d) begin
                done_toggle_ui <= ~done_toggle_ui;
            end
            if (top_error_ui & ~error_ui_d) begin
                error_toggle_ui <= ~error_toggle_ui;
            end

            dbg_last_accum <= {AXI_DATA_WIDTH{1'b0}};
            dbg_last_accum[31:0]    <= source0_selected_block_offset_ui[31:0];
            dbg_last_accum[63:32]   <= source0_selected_block_offset_ui[63:32];
            dbg_last_accum[95:64]   <= source0_selected_block_size_ui;
            dbg_last_accum[103:96]  <= source0_selected_block_compression_type_ui;
            dbg_last_accum[135:104] <= source0_index_entry_count_ui;
            dbg_last_accum[167:136] <= source1_selected_block_offset_ui[31:0];
            dbg_last_accum[199:168] <= source1_selected_block_offset_ui[63:32];
            dbg_last_accum[231:200] <= source1_selected_block_size_ui;
            dbg_last_accum[239:232] <= source1_selected_block_compression_type_ui;
            dbg_last_accum[271:240] <= source1_index_entry_count_ui;
            dbg_last_accum[303:272] <= merge_output_byte_count_ui;
            dbg_last_accum[335:304] <= merge_merged_record_count_ui;
            dbg_last_accum[367:336] <= stage5_bytes_written_ui;
            dbg_last_accum[399:368] <= stage5_output_block_bytes_ui;
            dbg_last_accum[415:400] <= final_prev_user_key_len_ui;
            dbg_last_accum[447:416] <= final_prev_user_key_ui[31:0];
        end
    end

    always @(posedge axil_aclk) begin
        if (!axil_aresetn) begin
            done_toggle_axil_ff1 <= 1'b0;
            done_toggle_axil_ff2 <= 1'b0;
            error_toggle_axil_ff1 <= 1'b0;
            error_toggle_axil_ff2 <= 1'b0;
            busy_axil_ff1 <= 1'b0;
            busy_axil_ff2 <= 1'b0;
            source0_decoded_entry_count_axil_ff1 <= 32'h0;
            source0_decoded_entry_count_axil_ff2 <= 32'h0;
            source0_bytes_read_axil_ff1 <= 32'h0;
            source0_bytes_read_axil_ff2 <= 32'h0;
            source0_selected_block_offset_axil_ff1 <= {AXI_ADDR_WIDTH{1'b0}};
            source0_selected_block_offset_axil_ff2 <= {AXI_ADDR_WIDTH{1'b0}};
            source0_selected_block_size_axil_ff1 <= 32'h0;
            source0_selected_block_size_axil_ff2 <= 32'h0;
            source0_selected_block_compression_type_axil_ff1 <= 8'h0;
            source0_selected_block_compression_type_axil_ff2 <= 8'h0;
            source0_index_entry_count_axil_ff1 <= 32'h0;
            source0_index_entry_count_axil_ff2 <= 32'h0;
            source1_decoded_entry_count_axil_ff1 <= 32'h0;
            source1_decoded_entry_count_axil_ff2 <= 32'h0;
            source1_bytes_read_axil_ff1 <= 32'h0;
            source1_bytes_read_axil_ff2 <= 32'h0;
            source1_selected_block_offset_axil_ff1 <= {AXI_ADDR_WIDTH{1'b0}};
            source1_selected_block_offset_axil_ff2 <= {AXI_ADDR_WIDTH{1'b0}};
            source1_selected_block_size_axil_ff1 <= 32'h0;
            source1_selected_block_size_axil_ff2 <= 32'h0;
            source1_selected_block_compression_type_axil_ff1 <= 8'h0;
            source1_selected_block_compression_type_axil_ff2 <= 8'h0;
            source1_index_entry_count_axil_ff1 <= 32'h0;
            source1_index_entry_count_axil_ff2 <= 32'h0;
            merge_output_byte_count_axil_ff1 <= 32'h0;
            merge_output_byte_count_axil_ff2 <= 32'h0;
            merge_decoded_record_count_axil_ff1 <= 32'h0;
            merge_decoded_record_count_axil_ff2 <= 32'h0;
            merge_merged_record_count_axil_ff1 <= 32'h0;
            merge_merged_record_count_axil_ff2 <= 32'h0;
            merge_dropped_superseded_count_axil_ff1 <= 32'h0;
            merge_dropped_superseded_count_axil_ff2 <= 32'h0;
            stage5_input_record_count_axil_ff1 <= 32'h0;
            stage5_input_record_count_axil_ff2 <= 32'h0;
            stage5_encoded_entry_count_axil_ff1 <= 32'h0;
            stage5_encoded_entry_count_axil_ff2 <= 32'h0;
            stage5_output_block_bytes_axil_ff1 <= 32'h0;
            stage5_output_block_bytes_axil_ff2 <= 32'h0;
            stage5_bytes_written_axil_ff1 <= 32'h0;
            stage5_bytes_written_axil_ff2 <= 32'h0;
            final_prev_user_key_len_axil_ff1 <= 16'h0;
            final_prev_user_key_len_axil_ff2 <= 16'h0;
        end else begin
            done_toggle_axil_ff1 <= done_toggle_ui;
            done_toggle_axil_ff2 <= done_toggle_axil_ff1;
            error_toggle_axil_ff1 <= error_toggle_ui;
            error_toggle_axil_ff2 <= error_toggle_axil_ff1;
            busy_axil_ff1 <= top_busy_ui;
            busy_axil_ff2 <= busy_axil_ff1;
            source0_decoded_entry_count_axil_ff1 <= source0_decoded_entry_count_ui;
            source0_decoded_entry_count_axil_ff2 <= source0_decoded_entry_count_axil_ff1;
            source0_bytes_read_axil_ff1 <= source0_bytes_read_ui;
            source0_bytes_read_axil_ff2 <= source0_bytes_read_axil_ff1;
            source0_selected_block_offset_axil_ff1 <= source0_selected_block_offset_ui;
            source0_selected_block_offset_axil_ff2 <= source0_selected_block_offset_axil_ff1;
            source0_selected_block_size_axil_ff1 <= source0_selected_block_size_ui;
            source0_selected_block_size_axil_ff2 <= source0_selected_block_size_axil_ff1;
            source0_selected_block_compression_type_axil_ff1 <= source0_selected_block_compression_type_ui;
            source0_selected_block_compression_type_axil_ff2 <= source0_selected_block_compression_type_axil_ff1;
            source0_index_entry_count_axil_ff1 <= source0_index_entry_count_ui;
            source0_index_entry_count_axil_ff2 <= source0_index_entry_count_axil_ff1;
            source1_decoded_entry_count_axil_ff1 <= source1_decoded_entry_count_ui;
            source1_decoded_entry_count_axil_ff2 <= source1_decoded_entry_count_axil_ff1;
            source1_bytes_read_axil_ff1 <= source1_bytes_read_ui;
            source1_bytes_read_axil_ff2 <= source1_bytes_read_axil_ff1;
            source1_selected_block_offset_axil_ff1 <= source1_selected_block_offset_ui;
            source1_selected_block_offset_axil_ff2 <= source1_selected_block_offset_axil_ff1;
            source1_selected_block_size_axil_ff1 <= source1_selected_block_size_ui;
            source1_selected_block_size_axil_ff2 <= source1_selected_block_size_axil_ff1;
            source1_selected_block_compression_type_axil_ff1 <= source1_selected_block_compression_type_ui;
            source1_selected_block_compression_type_axil_ff2 <= source1_selected_block_compression_type_axil_ff1;
            source1_index_entry_count_axil_ff1 <= source1_index_entry_count_ui;
            source1_index_entry_count_axil_ff2 <= source1_index_entry_count_axil_ff1;
            merge_output_byte_count_axil_ff1 <= merge_output_byte_count_ui;
            merge_output_byte_count_axil_ff2 <= merge_output_byte_count_axil_ff1;
            merge_decoded_record_count_axil_ff1 <= merge_decoded_record_count_ui;
            merge_decoded_record_count_axil_ff2 <= merge_decoded_record_count_axil_ff1;
            merge_merged_record_count_axil_ff1 <= merge_merged_record_count_ui;
            merge_merged_record_count_axil_ff2 <= merge_merged_record_count_axil_ff1;
            merge_dropped_superseded_count_axil_ff1 <= merge_dropped_superseded_count_ui;
            merge_dropped_superseded_count_axil_ff2 <= merge_dropped_superseded_count_axil_ff1;
            stage5_input_record_count_axil_ff1 <= stage5_input_record_count_ui;
            stage5_input_record_count_axil_ff2 <= stage5_input_record_count_axil_ff1;
            stage5_encoded_entry_count_axil_ff1 <= stage5_encoded_entry_count_ui;
            stage5_encoded_entry_count_axil_ff2 <= stage5_encoded_entry_count_axil_ff1;
            stage5_output_block_bytes_axil_ff1 <= stage5_output_block_bytes_ui;
            stage5_output_block_bytes_axil_ff2 <= stage5_output_block_bytes_axil_ff1;
            stage5_bytes_written_axil_ff1 <= stage5_bytes_written_ui;
            stage5_bytes_written_axil_ff2 <= stage5_bytes_written_axil_ff1;
            final_prev_user_key_len_axil_ff1 <= final_prev_user_key_len_ui;
            final_prev_user_key_len_axil_ff2 <= final_prev_user_key_len_axil_ff1;
        end
    end

    stage4_real_internal_key_two_way_merge_stage5_sstable_chain_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .MAX_SSTABLE_BYTES(MAX_SSTABLE_BYTES),
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
    ) u_stage4_real_internal_key_two_way_merge_stage5_sstable_chain_top (
        .clk(ui_aclk),
        .rstn(ui_aresetn),
        .clear(clear_pulse_ui),
        .start(start_pulse_ui),
        .seed_prev_user_key_valid(1'b0),
        .seed_prev_user_key_len(16'd0),
        .seed_prev_user_key({(MERGE_MAX_USER_KEY_BYTES*8){1'b0}}),
        .src0_base_addr(cfg_src0_base_ui_ff2),
        .src0_byte_count(cfg_src0_size_ui_ff2),
        .src0_block_index(cfg_src0_block_index_ui_ff2),
        .src1_base_addr(cfg_src1_base_ui_ff2),
        .src1_byte_count(cfg_src1_size_ui_ff2),
        .src1_block_index(cfg_src1_block_index_ui_ff2),
        .mid_base_addr(cfg_mid_base_ui_ff2),
        .dst_base_addr(cfg_dst_base_ui_ff2),
        .busy(top_busy_ui),
        .done(top_done_ui),
        .error(top_error_ui),
        .source0_decoded_entry_count(source0_decoded_entry_count_ui),
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
        .source0_bytes_read(source0_bytes_read_ui),
        .source0_beats_read(),
        .source0_selected_block_offset(source0_selected_block_offset_ui),
        .source0_selected_block_size(source0_selected_block_size_ui),
        .source0_selected_block_compression_type(source0_selected_block_compression_type_ui),
        .source0_index_entry_count(source0_index_entry_count_ui),
        .source1_decoded_entry_count(source1_decoded_entry_count_ui),
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
        .source1_bytes_read(source1_bytes_read_ui),
        .source1_beats_read(),
        .source1_selected_block_offset(source1_selected_block_offset_ui),
        .source1_selected_block_size(source1_selected_block_size_ui),
        .source1_selected_block_compression_type(source1_selected_block_compression_type_ui),
        .source1_index_entry_count(source1_index_entry_count_ui),
        .merge_bytes_written(),
        .merge_beats_written(),
        .merge_output_byte_count(merge_output_byte_count_ui),
        .merge_decoded_record_count(merge_decoded_record_count_ui),
        .merge_merged_record_count(merge_merged_record_count_ui),
        .merge_dropped_superseded_count(merge_dropped_superseded_count_ui),
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
        .stage5_bytes_written(stage5_bytes_written_ui),
        .stage5_beats_written(),
        .stage5_input_record_count(stage5_input_record_count_ui),
        .stage5_encoded_entry_count(stage5_encoded_entry_count_ui),
        .stage5_restart_count(),
        .stage5_shared_key_bytes_total(),
        .stage5_unshared_key_bytes_total(),
        .stage5_value_bytes_total(),
        .stage5_last_key_len(),
        .stage5_last_value_len(),
        .stage5_last_shared_bytes(),
        .stage5_last_non_shared_bytes(),
        .stage5_output_block_bytes(stage5_output_block_bytes_ui),
        .final_prev_user_key_valid(final_prev_user_key_valid_ui),
        .final_prev_user_key_len(final_prev_user_key_len_ui),
        .final_prev_user_key(final_prev_user_key_ui),
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
