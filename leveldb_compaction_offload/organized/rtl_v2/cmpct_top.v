`timescale 1ns / 1ps

// cmpct_top
//
// AXI-Lite wrapper for the full SSTable-aware compaction engine.
// Follows the same dual-clock CDC toggle-sync pattern as cmpct_axil_top.v.
//
// Register map (32-bit, byte-addressable):
//   0x0000  REG_CTRL                 [0]=start (self-clear), [1]=clear (self-clear)
//   0x0004  REG_STATUS               [0]=busy,  [1]=done,   [2]=error
//   0x0008  REG_SRC0_SSTABLE_BASE_LO SRC0 SSTable DDR base [31:0]
//   0x000C  REG_SRC0_SSTABLE_BASE_HI SRC0 SSTable DDR base [63:32]
//   0x0010  REG_SRC0_SSTABLE_SIZE    SRC0 SSTable byte size
//   0x0014  REG_SRC1_SSTABLE_BASE_LO SRC1 SSTable DDR base [31:0]
//   0x0018  REG_SRC1_SSTABLE_BASE_HI SRC1 SSTable DDR base [63:32]
//   0x001C  REG_SRC1_SSTABLE_SIZE    SRC1 SSTable byte size
//   0x0020  REG_DST_BASE_LO          Output-block base addr [31:0]
//   0x0024  REG_DST_BASE_HI          Output-block base addr [63:32]
//   0x0028  REG_DST_BLOCK_STRIDE     Bytes per output slot
//   0x002C  REG_MID_BASE_LO          MID scratch DDR addr [31:0]
//   0x0030  REG_MID_BASE_HI          MID scratch DDR addr [63:32]
//   0x0034  REG_BLOCK_PAIR_COUNT_OUT (RO) processed block pairs
//   0x0040  REG_TOTAL_SRC0_DECODED
//   0x0044  REG_TOTAL_SRC1_DECODED
//   0x0048  REG_TOTAL_SRC0_BYTES_READ
//   0x004C  REG_TOTAL_SRC1_BYTES_READ
//   0x0050  REG_TOTAL_MERGE_OUTPUT_BYTES
//   0x0054  REG_TOTAL_MERGE_DECODED
//   0x0058  REG_TOTAL_MERGE_MERGED
//   0x005C  REG_TOTAL_MERGE_DROPPED
//   0x0060  REG_TOTAL_STAGE5_INPUT
//   0x0064  REG_TOTAL_STAGE5_ENCODED
//   0x0068  REG_TOTAL_STAGE5_OUTPUT_BYTES
//   0x006C  REG_TOTAL_STAGE5_BYTES_WRITTEN
//   0x0070  REG_PERF_CYCLE_COUNT     UI-clock cycles between start and done
//   0x0038  REG_MAX_FILE_SIZE        Max output SSTable size (0=no split)
//   0x003C  REG_SSTABLE_COUNT (RO)   Number of output SSTables produced
//   0x0100  REG_DST_OUTPUT_BYTES[0]  dst block[0] encoded bytes (RO)
//   0x0104  REG_DST_OUTPUT_BYTES[1]  ...
//   ...     (MAX_BLOCK_PAIRS entries x 4 bytes)
//   0x0500  REG_SSTABLE_SIZES[0]    output SSTable[0] total bytes (RO)
//   0x0504  REG_SSTABLE_SIZES[1]    ...
//   ...     (MAX_SSTABLES entries x 4 bytes)

module cmpct_top #(
    parameter integer AXIL_ADDR_WIDTH          = 32,
    parameter integer AXIL_DATA_WIDTH          = 32,
    parameter integer AXI_ADDR_WIDTH           = 64,
    parameter integer AXI_DATA_WIDTH           = 512,
    parameter integer AXI_STRB_WIDTH           = 64,
    parameter integer MAX_BURST_LEN            = 16,
    parameter integer MAX_INDEX_BYTES          = 16384,
    parameter integer MAX_BLOCK_PAIRS          = 32,
    parameter integer STAGE4_MAX_BLOCK_BYTES   = 4096,
    parameter integer STAGE4_MAX_KEY_BYTES     = 72,
    parameter integer MERGE_MAX_USER_KEY_BYTES = 64,
    parameter integer MERGE_MAX_KEY_BYTES      = 72,
    parameter integer MERGE_MAX_VALUE_BYTES    = 1024,
    parameter integer MERGE_MAX_RECORD_BYTES   = 2048,
    parameter integer MERGE_MAX_RECORDS        = 256,
    parameter integer MERGE_MAX_OUTPUT_BYTES   = 73728,
    parameter integer STAGE5_MAX_RECORDS       = 256,
    parameter integer STAGE5_MAX_PAYLOAD_BYTES = 4096,
    parameter integer STAGE5_MAX_BLOCK_BYTES   = 4096,
    parameter integer STAGE5_MAX_KEY_BYTES     = 64,
    parameter integer STAGE5_MAX_VALUE_BYTES   = 1024,
    parameter integer STAGE5_RESTART_INTERVAL  = 16,
    parameter integer MAX_SSTABLES              = 16,
    parameter integer SPLIT_TAIL_MARGIN         = 4096
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

    // Parser0 AXI read port (SSTable0 DDR access)
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

    // Parser1 AXI read port (SSTable1 DDR access)
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

    // nblock SRC0 AXI read port
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

    // nblock SRC1 AXI read port
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

    // nblock chain AXI port (read + write for MID/DST)
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
    output wire [31:0]                   blocks_done,
    output wire [31:0]                   bytes_done,

    // OPT-IRQ / P5: MSI-X interrupt request — active-high 1-cycle pulse on done or error
    output reg                           usr_irq_req
);

    // -----------------------------------------------------------------------
    // Register address map
    // -----------------------------------------------------------------------
    localparam [AXIL_ADDR_WIDTH-1:0] REG_CTRL                    = 32'h0000;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_STATUS                  = 32'h0004;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_SSTABLE_BASE_LO    = 32'h0008;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_SSTABLE_BASE_HI    = 32'h000C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC0_SSTABLE_SIZE       = 32'h0010;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_SSTABLE_BASE_LO    = 32'h0014;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_SSTABLE_BASE_HI    = 32'h0018;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC1_SSTABLE_SIZE       = 32'h001C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DST_BASE_LO             = 32'h0020;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DST_BASE_HI             = 32'h0024;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DST_BLOCK_STRIDE        = 32'h0028;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_MID_BASE_LO             = 32'h002C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_MID_BASE_HI             = 32'h0030;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_BLOCK_PAIR_COUNT_OUT    = 32'h0034;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_SRC0_DECODED      = 32'h0040;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_SRC1_DECODED      = 32'h0044;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_SRC0_BYTES_READ   = 32'h0048;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_SRC1_BYTES_READ   = 32'h004C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_MERGE_OUTPUT_BYTES= 32'h0050;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_MERGE_DECODED     = 32'h0054;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_MERGE_MERGED      = 32'h0058;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_MERGE_DROPPED     = 32'h005C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_STAGE5_INPUT      = 32'h0060;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_STAGE5_ENCODED    = 32'h0064;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_STAGE5_OUT_BYTES  = 32'h0068;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_TOTAL_STAGE5_WRITTEN    = 32'h006C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_MAX_FILE_SIZE           = 32'h0038;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SSTABLE_COUNT           = 32'h003C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_PERF_CYCLE_COUNT        = 32'h0070;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DST_OUTPUT_BYTES_BASE   = 32'h0100;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SSTABLE_SIZES_BASE      = 32'h0500;

    // -----------------------------------------------------------------------
    // AXI-Lite domain shadow registers
    // -----------------------------------------------------------------------
    reg [31:0] r_ctrl;
    reg [31:0] r_status;
    reg [63:0] r_src0_base;
    reg [31:0] r_src0_size;
    reg [63:0] r_src1_base;
    reg [31:0] r_src1_size;
    reg [63:0] r_dst_base;
    reg [31:0] r_dst_stride;
    reg [63:0] r_mid_base;
    reg [31:0] r_max_file_size;

    reg [AXIL_ADDR_WIDTH-1:0] awaddr_lat;
    reg                       awaddr_valid;

    wire aw_hs = s_axil_awvalid & s_axil_awready;
    wire w_hs  = s_axil_wvalid  & s_axil_wready;
    wire b_hs  = s_axil_bvalid  & s_axil_bready;
    wire ar_hs = s_axil_arvalid & s_axil_arready;
    wire r_hs  = s_axil_rvalid  & s_axil_rready;
    wire can_accept_write = ~s_axil_bvalid;

    reg ctrl_start_d, ctrl_clear_d;
    wire ctrl_start_pulse = r_ctrl[0] & ~ctrl_start_d;
    wire ctrl_clear_pulse = r_ctrl[1] & ~ctrl_clear_d;

    // -----------------------------------------------------------------------
    // CDC: AXIL → UI  (toggle for start/clear, double-FF for config)
    // -----------------------------------------------------------------------
    reg        start_toggle_axil, clear_toggle_axil;
    reg [63:0] cfg_src0_base_axil;
    reg [31:0] cfg_src0_size_axil;
    reg [63:0] cfg_src1_base_axil;
    reg [31:0] cfg_src1_size_axil;
    reg [63:0] cfg_dst_base_axil;
    reg [31:0] cfg_dst_stride_axil;
    reg [63:0] cfg_mid_base_axil;
    reg [31:0] cfg_max_file_size_axil;

    reg        start_toggle_ui_ff1, start_toggle_ui_ff2, start_toggle_ui_ff3;
    reg        clear_toggle_ui_ff1, clear_toggle_ui_ff2, clear_toggle_ui_ff3;
    reg [63:0] cfg_src0_base_ui_ff1,   cfg_src0_base_ui_ff2;
    reg [31:0] cfg_src0_size_ui_ff1,   cfg_src0_size_ui_ff2;
    reg [63:0] cfg_src1_base_ui_ff1,   cfg_src1_base_ui_ff2;
    reg [31:0] cfg_src1_size_ui_ff1,   cfg_src1_size_ui_ff2;
    reg [63:0] cfg_dst_base_ui_ff1,    cfg_dst_base_ui_ff2;
    reg [31:0] cfg_dst_stride_ui_ff1,  cfg_dst_stride_ui_ff2;
    reg [63:0] cfg_mid_base_ui_ff1,    cfg_mid_base_ui_ff2;
    reg [31:0] cfg_max_file_size_ui_ff1, cfg_max_file_size_ui_ff2;

    wire start_pulse_ui = start_toggle_ui_ff3 ^ start_toggle_ui_ff2;
    wire clear_pulse_ui = clear_toggle_ui_ff3 ^ clear_toggle_ui_ff2;

    // -----------------------------------------------------------------------
    // CDC: UI → AXIL  (double-FF for status/counters, toggle for done/error)
    // -----------------------------------------------------------------------
    wire        top_busy_ui, top_done_ui, top_error_ui;
    wire [31:0] block_pair_count_out_ui;
    wire [MAX_BLOCK_PAIRS*32-1:0] dst_output_block_bytes_vec_ui;
    wire [31:0] total_src0_decoded_ui,    total_src1_decoded_ui;
    wire [31:0] total_src0_bytes_read_ui, total_src1_bytes_read_ui;
    wire [31:0] total_merge_output_bytes_ui;
    wire [31:0] total_merge_decoded_ui,   total_merge_merged_ui;
    wire [31:0] total_merge_dropped_ui;
    wire [31:0] total_stage5_input_ui,    total_stage5_encoded_ui;
    wire [31:0] total_stage5_out_bytes_ui, total_stage5_written_ui;
    wire [31:0] sstable_count_ui;
    wire [MAX_SSTABLES*32-1:0] sstable_sizes_vec_ui;

    reg done_ui_d, error_ui_d;
    reg done_toggle_ui, error_toggle_ui;
    reg done_toggle_axil_ff1, done_toggle_axil_ff2;
    reg error_toggle_axil_ff1, error_toggle_axil_ff2;
    wire done_pulse_axil  = done_toggle_axil_ff2  ^ done_toggle_axil_ff1;
    wire error_pulse_axil = error_toggle_axil_ff2 ^ error_toggle_axil_ff1;

    reg        perf_counting_ui;
    reg [31:0] perf_cycle_count_ui;

    reg        busy_axil_ff1, busy_axil_ff2;
    reg [31:0] block_pair_count_out_axil_ff1,   block_pair_count_out_axil_ff2;
    reg [31:0] total_src0_dec_axil_ff1,    total_src0_dec_axil_ff2;
    reg [31:0] total_src1_dec_axil_ff1,    total_src1_dec_axil_ff2;
    reg [31:0] total_src0_rd_axil_ff1,     total_src0_rd_axil_ff2;
    reg [31:0] total_src1_rd_axil_ff1,     total_src1_rd_axil_ff2;
    reg [31:0] total_merge_out_axil_ff1,   total_merge_out_axil_ff2;
    reg [31:0] total_merge_dec_axil_ff1,   total_merge_dec_axil_ff2;
    reg [31:0] total_merge_mrg_axil_ff1,   total_merge_mrg_axil_ff2;
    reg [31:0] total_merge_drp_axil_ff1,   total_merge_drp_axil_ff2;
    reg [31:0] total_s5_in_axil_ff1,       total_s5_in_axil_ff2;
    reg [31:0] total_s5_enc_axil_ff1,      total_s5_enc_axil_ff2;
    reg [31:0] total_s5_out_axil_ff1,      total_s5_out_axil_ff2;
    reg [31:0] total_s5_wr_axil_ff1,       total_s5_wr_axil_ff2;
    reg [31:0] perf_count_axil_ff1,        perf_count_axil_ff2;
    reg [31:0] sstable_count_axil_ff1,     sstable_count_axil_ff2;

    // Array readback CDC handshake (replaces 24K-bit wide-vector CDC)
    reg        arr_req_toggle_axil;
    reg        arr_req_sel_axil;      // 0=dst_bytes, 1=sst_sizes
    reg  [8:0] arr_req_idx_axil;
    reg        arr_req_toggle_ui_ff1, arr_req_toggle_ui_ff2, arr_req_toggle_ui_ff3;
    reg        arr_req_sel_ui_ff1, arr_req_sel_ui_ff2;
    reg  [8:0] arr_req_idx_ui_ff1, arr_req_idx_ui_ff2;
    reg        arr_resp_toggle_ui;
    reg [31:0] arr_resp_data_ui;
    reg        arr_resp_toggle_axil_ff1, arr_resp_toggle_axil_ff2, arr_resp_toggle_axil_ff3;
    reg [31:0] arr_resp_data_axil_ff1, arr_resp_data_axil_ff2;
    wire       arr_resp_pulse_axil = arr_resp_toggle_axil_ff3 ^ arr_resp_toggle_axil_ff2;
    wire       arr_req_pulse_ui    = arr_req_toggle_ui_ff3 ^ arr_req_toggle_ui_ff2;
    reg        rd_fsm_wait;           // 1 = waiting for cross-domain array response

    assign done       = r_status[1];
    assign busy       = busy_axil_ff2;
    assign error      = r_status[2];
    assign blocks_done = block_pair_count_out_axil_ff2;
    assign bytes_done  = total_s5_wr_axil_ff2;

    integer rd_idx, arr_k;

    // -----------------------------------------------------------------------
    // AXI-Lite read channel
    // -----------------------------------------------------------------------
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
            rd_fsm_wait    <= 1'b0;
            arr_req_toggle_axil <= 1'b0;
            arr_req_sel_axil    <= 1'b0;
            arr_req_idx_axil    <= 9'd0;
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

            // --- Read response handshake ---
            if (r_hs) s_axil_rvalid <= 1'b0;

            // --- Read channel FSM: immediate for scalars, deferred for arrays ---
            if (rd_fsm_wait) begin
                // Waiting for cross-domain array response
                s_axil_arready <= 1'b0;
                if (arr_resp_pulse_axil) begin
                    s_axil_rvalid <= 1'b1;
                    s_axil_rdata  <= arr_resp_data_axil_ff2;
                    s_axil_rresp  <= 2'b00;
                    rd_fsm_wait   <= 1'b0;
                end
            end else begin
                s_axil_arready <= ~s_axil_rvalid;
                if (ar_hs) begin
                    if (s_axil_araddr >= REG_DST_OUTPUT_BYTES_BASE &&
                        s_axil_araddr < (REG_DST_OUTPUT_BYTES_BASE + MAX_BLOCK_PAIRS*4)) begin
                        // Array read: dst_output_bytes — initiate CDC handshake
                        arr_req_sel_axil    <= 1'b0;
                        arr_req_idx_axil    <= (s_axil_araddr - REG_DST_OUTPUT_BYTES_BASE) >> 2;
                        arr_req_toggle_axil <= ~arr_req_toggle_axil;
                        rd_fsm_wait         <= 1'b1;
                    end else if (s_axil_araddr >= REG_SSTABLE_SIZES_BASE &&
                                 s_axil_araddr < (REG_SSTABLE_SIZES_BASE + MAX_SSTABLES*4)) begin
                        // Array read: sstable_sizes — initiate CDC handshake
                        arr_req_sel_axil    <= 1'b1;
                        arr_req_idx_axil    <= (s_axil_araddr - REG_SSTABLE_SIZES_BASE) >> 2;
                        arr_req_toggle_axil <= ~arr_req_toggle_axil;
                        rd_fsm_wait         <= 1'b1;
                    end else begin
                        // Immediate scalar read
                        s_axil_rvalid <= 1'b1;
                        s_axil_rresp  <= 2'b00;
                        case (s_axil_araddr)
                            REG_CTRL:                   s_axil_rdata <= r_ctrl;
                            REG_STATUS:                 s_axil_rdata <= r_status;
                            REG_SRC0_SSTABLE_BASE_LO:   s_axil_rdata <= r_src0_base[31:0];
                            REG_SRC0_SSTABLE_BASE_HI:   s_axil_rdata <= r_src0_base[63:32];
                            REG_SRC0_SSTABLE_SIZE:      s_axil_rdata <= r_src0_size;
                            REG_SRC1_SSTABLE_BASE_LO:   s_axil_rdata <= r_src1_base[31:0];
                            REG_SRC1_SSTABLE_BASE_HI:   s_axil_rdata <= r_src1_base[63:32];
                            REG_SRC1_SSTABLE_SIZE:      s_axil_rdata <= r_src1_size;
                            REG_DST_BASE_LO:            s_axil_rdata <= r_dst_base[31:0];
                            REG_DST_BASE_HI:            s_axil_rdata <= r_dst_base[63:32];
                            REG_DST_BLOCK_STRIDE:       s_axil_rdata <= r_dst_stride;
                            REG_MID_BASE_LO:            s_axil_rdata <= r_mid_base[31:0];
                            REG_MID_BASE_HI:            s_axil_rdata <= r_mid_base[63:32];
                            REG_MAX_FILE_SIZE:          s_axil_rdata <= r_max_file_size;
                            REG_SSTABLE_COUNT:          s_axil_rdata <= sstable_count_axil_ff2;
                            REG_BLOCK_PAIR_COUNT_OUT:   s_axil_rdata <= block_pair_count_out_axil_ff2;
                            REG_TOTAL_SRC0_DECODED:     s_axil_rdata <= total_src0_dec_axil_ff2;
                            REG_TOTAL_SRC1_DECODED:     s_axil_rdata <= total_src1_dec_axil_ff2;
                            REG_TOTAL_SRC0_BYTES_READ:  s_axil_rdata <= total_src0_rd_axil_ff2;
                            REG_TOTAL_SRC1_BYTES_READ:  s_axil_rdata <= total_src1_rd_axil_ff2;
                            REG_TOTAL_MERGE_OUTPUT_BYTES: s_axil_rdata <= total_merge_out_axil_ff2;
                            REG_TOTAL_MERGE_DECODED:    s_axil_rdata <= total_merge_dec_axil_ff2;
                            REG_TOTAL_MERGE_MERGED:     s_axil_rdata <= total_merge_mrg_axil_ff2;
                            REG_TOTAL_MERGE_DROPPED:    s_axil_rdata <= total_merge_drp_axil_ff2;
                            REG_TOTAL_STAGE5_INPUT:     s_axil_rdata <= total_s5_in_axil_ff2;
                            REG_TOTAL_STAGE5_ENCODED:   s_axil_rdata <= total_s5_enc_axil_ff2;
                            REG_TOTAL_STAGE5_OUT_BYTES: s_axil_rdata <= total_s5_out_axil_ff2;
                            REG_TOTAL_STAGE5_WRITTEN:   s_axil_rdata <= total_s5_wr_axil_ff2;
                            REG_PERF_CYCLE_COUNT:       s_axil_rdata <= perf_count_axil_ff2;
                            default:                    s_axil_rdata <= 32'h0;
                        endcase
                    end
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // AXI-Lite write + CDC toggle generation + status latch
    // -----------------------------------------------------------------------
    always @(posedge axil_aclk) begin
        if (!axil_aresetn) begin
            r_ctrl              <= 32'h0;
            r_status            <= 32'h0;
            r_src0_base         <= 64'h0;
            r_src0_size         <= 32'h0;
            r_src1_base         <= 64'h0;
            r_src1_size         <= 32'h0;
            r_dst_base          <= 64'h0;
            r_dst_stride        <= 32'h0;
            r_mid_base          <= 64'h0;
            r_max_file_size     <= 32'h0;
            ctrl_start_d        <= 1'b0;
            ctrl_clear_d        <= 1'b0;
            start_toggle_axil   <= 1'b0;
            clear_toggle_axil   <= 1'b0;
            cfg_src0_base_axil  <= 64'h0;
            cfg_src0_size_axil  <= 32'h0;
            cfg_src1_base_axil  <= 64'h0;
            cfg_src1_size_axil  <= 32'h0;
            cfg_dst_base_axil   <= 64'h0;
            cfg_dst_stride_axil <= 32'h0;
            cfg_mid_base_axil   <= 64'h0;
            cfg_max_file_size_axil <= 32'h0;
            busy_axil_ff1       <= 1'b0;
            busy_axil_ff2       <= 1'b0;
            block_pair_count_out_axil_ff1 <= 32'h0;
            block_pair_count_out_axil_ff2 <= 32'h0;
            arr_resp_toggle_axil_ff1 <= 1'b0;
            arr_resp_toggle_axil_ff2 <= 1'b0;
            arr_resp_toggle_axil_ff3 <= 1'b0;
            arr_resp_data_axil_ff1   <= 32'h0;
            arr_resp_data_axil_ff2   <= 32'h0;
            total_src0_dec_axil_ff1  <= 32'h0; total_src0_dec_axil_ff2  <= 32'h0;
            total_src1_dec_axil_ff1  <= 32'h0; total_src1_dec_axil_ff2  <= 32'h0;
            total_src0_rd_axil_ff1   <= 32'h0; total_src0_rd_axil_ff2   <= 32'h0;
            total_src1_rd_axil_ff1   <= 32'h0; total_src1_rd_axil_ff2   <= 32'h0;
            total_merge_out_axil_ff1 <= 32'h0; total_merge_out_axil_ff2 <= 32'h0;
            total_merge_dec_axil_ff1 <= 32'h0; total_merge_dec_axil_ff2 <= 32'h0;
            total_merge_mrg_axil_ff1 <= 32'h0; total_merge_mrg_axil_ff2 <= 32'h0;
            total_merge_drp_axil_ff1 <= 32'h0; total_merge_drp_axil_ff2 <= 32'h0;
            total_s5_in_axil_ff1     <= 32'h0; total_s5_in_axil_ff2     <= 32'h0;
            total_s5_enc_axil_ff1    <= 32'h0; total_s5_enc_axil_ff2    <= 32'h0;
            total_s5_out_axil_ff1    <= 32'h0; total_s5_out_axil_ff2    <= 32'h0;
            total_s5_wr_axil_ff1     <= 32'h0; total_s5_wr_axil_ff2     <= 32'h0;
            perf_count_axil_ff1      <= 32'h0; perf_count_axil_ff2      <= 32'h0;
            sstable_count_axil_ff1   <= 32'h0; sstable_count_axil_ff2   <= 32'h0;
        end else begin
            ctrl_start_d        <= r_ctrl[0];
            ctrl_clear_d        <= r_ctrl[1];
            cfg_src0_base_axil  <= r_src0_base;
            cfg_src0_size_axil  <= r_src0_size;
            cfg_src1_base_axil  <= r_src1_base;
            cfg_src1_size_axil  <= r_src1_size;
            cfg_dst_base_axil   <= r_dst_base;
            cfg_dst_stride_axil <= r_dst_stride;
            cfg_mid_base_axil      <= r_mid_base;
            cfg_max_file_size_axil <= r_max_file_size;

            busy_axil_ff1 <= top_busy_ui;
            busy_axil_ff2 <= busy_axil_ff1;
            block_pair_count_out_axil_ff1 <= block_pair_count_out_ui;
            block_pair_count_out_axil_ff2 <= block_pair_count_out_axil_ff1;
            arr_resp_toggle_axil_ff1 <= arr_resp_toggle_ui;
            arr_resp_toggle_axil_ff2 <= arr_resp_toggle_axil_ff1;
            arr_resp_toggle_axil_ff3 <= arr_resp_toggle_axil_ff2;
            arr_resp_data_axil_ff1   <= arr_resp_data_ui;
            arr_resp_data_axil_ff2   <= arr_resp_data_axil_ff1;
            total_src0_dec_axil_ff1  <= total_src0_decoded_ui;
            total_src0_dec_axil_ff2  <= total_src0_dec_axil_ff1;
            total_src1_dec_axil_ff1  <= total_src1_decoded_ui;
            total_src1_dec_axil_ff2  <= total_src1_dec_axil_ff1;
            total_src0_rd_axil_ff1   <= total_src0_bytes_read_ui;
            total_src0_rd_axil_ff2   <= total_src0_rd_axil_ff1;
            total_src1_rd_axil_ff1   <= total_src1_bytes_read_ui;
            total_src1_rd_axil_ff2   <= total_src1_rd_axil_ff1;
            total_merge_out_axil_ff1 <= total_merge_output_bytes_ui;
            total_merge_out_axil_ff2 <= total_merge_out_axil_ff1;
            total_merge_dec_axil_ff1 <= total_merge_decoded_ui;
            total_merge_dec_axil_ff2 <= total_merge_dec_axil_ff1;
            total_merge_mrg_axil_ff1 <= total_merge_merged_ui;
            total_merge_mrg_axil_ff2 <= total_merge_mrg_axil_ff1;
            total_merge_drp_axil_ff1 <= total_merge_dropped_ui;
            total_merge_drp_axil_ff2 <= total_merge_drp_axil_ff1;
            total_s5_in_axil_ff1     <= total_stage5_input_ui;
            total_s5_in_axil_ff2     <= total_s5_in_axil_ff1;
            total_s5_enc_axil_ff1    <= total_stage5_encoded_ui;
            total_s5_enc_axil_ff2    <= total_s5_enc_axil_ff1;
            total_s5_out_axil_ff1    <= total_stage5_out_bytes_ui;
            total_s5_out_axil_ff2    <= total_s5_out_axil_ff1;
            total_s5_wr_axil_ff1     <= total_stage5_written_ui;
            total_s5_wr_axil_ff2     <= total_s5_wr_axil_ff1;
            perf_count_axil_ff1      <= perf_cycle_count_ui;
            perf_count_axil_ff2      <= perf_count_axil_ff1;
            sstable_count_axil_ff1   <= sstable_count_ui;
            sstable_count_axil_ff2   <= sstable_count_axil_ff1;

            r_status[0] <= busy_axil_ff2;

            if (can_accept_write && awaddr_valid && w_hs) begin
                case (awaddr_lat)
                    REG_CTRL: begin
                        if (s_axil_wstrb[0]) r_ctrl[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_ctrl[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_ctrl[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_ctrl[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_SRC0_SSTABLE_BASE_LO: begin
                        if (s_axil_wstrb[0]) r_src0_base[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src0_base[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src0_base[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src0_base[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_SRC0_SSTABLE_BASE_HI: begin
                        if (s_axil_wstrb[0]) r_src0_base[39:32] <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src0_base[47:40] <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src0_base[55:48] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src0_base[63:56] <= s_axil_wdata[31:24];
                    end
                    REG_SRC0_SSTABLE_SIZE: begin
                        if (s_axil_wstrb[0]) r_src0_size[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src0_size[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src0_size[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src0_size[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_SRC1_SSTABLE_BASE_LO: begin
                        if (s_axil_wstrb[0]) r_src1_base[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src1_base[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src1_base[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src1_base[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_SRC1_SSTABLE_BASE_HI: begin
                        if (s_axil_wstrb[0]) r_src1_base[39:32] <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src1_base[47:40] <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src1_base[55:48] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src1_base[63:56] <= s_axil_wdata[31:24];
                    end
                    REG_SRC1_SSTABLE_SIZE: begin
                        if (s_axil_wstrb[0]) r_src1_size[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src1_size[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src1_size[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src1_size[31:24] <= s_axil_wdata[31:24];
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
                    REG_DST_BLOCK_STRIDE: begin
                        if (s_axil_wstrb[0]) r_dst_stride[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_dst_stride[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_dst_stride[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_dst_stride[31:24] <= s_axil_wdata[31:24];
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
                    REG_MAX_FILE_SIZE: begin
                        if (s_axil_wstrb[0]) r_max_file_size[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_max_file_size[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_max_file_size[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_max_file_size[31:24] <= s_axil_wdata[31:24];
                    end
                    default: ;
                endcase
            end

            if (ctrl_clear_pulse || ctrl_start_pulse) begin
                r_status[1] <= 1'b0;
                r_status[2] <= 1'b0;
            end
            if (done_pulse_axil)  r_status[1] <= 1'b1;
            if (error_pulse_axil) r_status[2] <= 1'b1;
            if (ctrl_start_pulse) start_toggle_axil <= ~start_toggle_axil;
            if (ctrl_clear_pulse) clear_toggle_axil <= ~clear_toggle_axil;
        end
    end

    // -----------------------------------------------------------------------
    // Done/error toggle CDC (UI → AXIL)
    // -----------------------------------------------------------------------
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

    // -----------------------------------------------------------------------
    // UI-domain: CDC capture + perf counter + done/error detection
    // -----------------------------------------------------------------------
    always @(posedge ui_aclk) begin
        if (!ui_aresetn) begin
            start_toggle_ui_ff1 <= 1'b0;
            start_toggle_ui_ff2 <= 1'b0;
            start_toggle_ui_ff3 <= 1'b0;
            clear_toggle_ui_ff1 <= 1'b0;
            clear_toggle_ui_ff2 <= 1'b0;
            clear_toggle_ui_ff3 <= 1'b0;
            cfg_src0_base_ui_ff1   <= 64'h0; cfg_src0_base_ui_ff2   <= 64'h0;
            cfg_src0_size_ui_ff1   <= 32'h0; cfg_src0_size_ui_ff2   <= 32'h0;
            cfg_src1_base_ui_ff1   <= 64'h0; cfg_src1_base_ui_ff2   <= 64'h0;
            cfg_src1_size_ui_ff1   <= 32'h0; cfg_src1_size_ui_ff2   <= 32'h0;
            cfg_dst_base_ui_ff1    <= 64'h0; cfg_dst_base_ui_ff2    <= 64'h0;
            cfg_dst_stride_ui_ff1  <= 32'h0; cfg_dst_stride_ui_ff2  <= 32'h0;
            cfg_mid_base_ui_ff1    <= 64'h0; cfg_mid_base_ui_ff2    <= 64'h0;
            cfg_max_file_size_ui_ff1 <= 32'h0; cfg_max_file_size_ui_ff2 <= 32'h0;
            done_ui_d              <= 1'b0;
            error_ui_d             <= 1'b0;
            done_toggle_ui         <= 1'b0;
            error_toggle_ui        <= 1'b0;
            perf_counting_ui       <= 1'b0;
            perf_cycle_count_ui    <= 32'h0;
            arr_req_toggle_ui_ff1  <= 1'b0;
            arr_req_toggle_ui_ff2  <= 1'b0;
            arr_req_toggle_ui_ff3  <= 1'b0;
            arr_req_sel_ui_ff1     <= 1'b0;
            arr_req_sel_ui_ff2     <= 1'b0;
            arr_req_idx_ui_ff1     <= 9'd0;
            arr_req_idx_ui_ff2     <= 9'd0;
            arr_resp_toggle_ui     <= 1'b0;
            arr_resp_data_ui       <= 32'h0;
            usr_irq_req            <= 1'b0;
        end else begin
            start_toggle_ui_ff1 <= start_toggle_axil;
            start_toggle_ui_ff2 <= start_toggle_ui_ff1;
            start_toggle_ui_ff3 <= start_toggle_ui_ff2;
            clear_toggle_ui_ff1 <= clear_toggle_axil;
            clear_toggle_ui_ff2 <= clear_toggle_ui_ff1;
            clear_toggle_ui_ff3 <= clear_toggle_ui_ff2;
            cfg_src0_base_ui_ff1  <= cfg_src0_base_axil;  cfg_src0_base_ui_ff2  <= cfg_src0_base_ui_ff1;
            cfg_src0_size_ui_ff1  <= cfg_src0_size_axil;  cfg_src0_size_ui_ff2  <= cfg_src0_size_ui_ff1;
            cfg_src1_base_ui_ff1  <= cfg_src1_base_axil;  cfg_src1_base_ui_ff2  <= cfg_src1_base_ui_ff1;
            cfg_src1_size_ui_ff1  <= cfg_src1_size_axil;  cfg_src1_size_ui_ff2  <= cfg_src1_size_ui_ff1;
            cfg_dst_base_ui_ff1   <= cfg_dst_base_axil;   cfg_dst_base_ui_ff2   <= cfg_dst_base_ui_ff1;
            cfg_dst_stride_ui_ff1 <= cfg_dst_stride_axil; cfg_dst_stride_ui_ff2 <= cfg_dst_stride_ui_ff1;
            cfg_mid_base_ui_ff1   <= cfg_mid_base_axil;   cfg_mid_base_ui_ff2   <= cfg_mid_base_ui_ff1;
            cfg_max_file_size_ui_ff1 <= cfg_max_file_size_axil; cfg_max_file_size_ui_ff2 <= cfg_max_file_size_ui_ff1;

            // Array readback request CDC sync (AXIL → UI)
            arr_req_toggle_ui_ff1 <= arr_req_toggle_axil;
            arr_req_toggle_ui_ff2 <= arr_req_toggle_ui_ff1;
            arr_req_toggle_ui_ff3 <= arr_req_toggle_ui_ff2;
            arr_req_sel_ui_ff1    <= arr_req_sel_axil;
            arr_req_sel_ui_ff2    <= arr_req_sel_ui_ff1;
            arr_req_idx_ui_ff1    <= arr_req_idx_axil;
            arr_req_idx_ui_ff2    <= arr_req_idx_ui_ff1;

            // Array readback responder: mux one 32-bit value and toggle response
            if (arr_req_pulse_ui) begin
                arr_resp_data_ui <= 32'h0;
                if (!arr_req_sel_ui_ff2) begin
                    for (arr_k = 0; arr_k < MAX_BLOCK_PAIRS; arr_k = arr_k + 1) begin
                        if (arr_req_idx_ui_ff2 == arr_k[8:0])
                            arr_resp_data_ui <= dst_output_block_bytes_vec_ui[(arr_k*32) +: 32];
                    end
                end else begin
                    for (arr_k = 0; arr_k < MAX_SSTABLES; arr_k = arr_k + 1) begin
                        if (arr_req_idx_ui_ff2 == arr_k[8:0])
                            arr_resp_data_ui <= sstable_sizes_vec_ui[(arr_k*32) +: 32];
                    end
                end
                arr_resp_toggle_ui <= ~arr_resp_toggle_ui;
            end

            done_ui_d  <= top_done_ui;
            error_ui_d <= top_error_ui;
            usr_irq_req <= 1'b0;  // OPT-IRQ: default deassert
            if (top_done_ui && !done_ui_d) begin
                done_toggle_ui   <= ~done_toggle_ui;
                perf_counting_ui <= 1'b0;
                usr_irq_req      <= 1'b1;  // OPT-IRQ: pulse on done
            end
            if (top_error_ui && !error_ui_d) begin
                error_toggle_ui  <= ~error_toggle_ui;
                perf_counting_ui <= 1'b0;
                usr_irq_req      <= 1'b1;  // OPT-IRQ: pulse on error
            end
            if (start_pulse_ui) begin
                perf_counting_ui    <= 1'b1;
                perf_cycle_count_ui <= 32'h0;
            end
            if (clear_pulse_ui) begin
                perf_counting_ui    <= 1'b0;
                perf_cycle_count_ui <= 32'h0;
            end
            if (perf_counting_ui)
                perf_cycle_count_ui <= perf_cycle_count_ui + 32'h1;
        end
    end

    // -----------------------------------------------------------------------
    // DUT instantiation
    // -----------------------------------------------------------------------
    cmpct_engine #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .MAX_INDEX_BYTES(MAX_INDEX_BYTES),
        .MAX_BLOCK_PAIRS(MAX_BLOCK_PAIRS),
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
        .MAX_SSTABLES(MAX_SSTABLES),
        .SPLIT_TAIL_MARGIN(SPLIT_TAIL_MARGIN)
    ) u_engine (
        .clk(ui_aclk),
        .rstn(ui_aresetn),
        .clear(clear_pulse_ui),
        .start(start_pulse_ui),
        .max_file_size(cfg_max_file_size_ui_ff2),
        .src0_sstable_base(cfg_src0_base_ui_ff2),
        .src0_sstable_size(cfg_src0_size_ui_ff2),
        .src1_sstable_base(cfg_src1_base_ui_ff2),
        .src1_sstable_size(cfg_src1_size_ui_ff2),
        .dst_base_addr(cfg_dst_base_ui_ff2),
        .dst_block_stride(cfg_dst_stride_ui_ff2),
        .mid_base_addr(cfg_mid_base_ui_ff2),
        .busy(top_busy_ui),
        .done(top_done_ui),
        .error(top_error_ui),
        .block_pair_count_out(block_pair_count_out_ui),
        .dst_output_block_bytes_vec(dst_output_block_bytes_vec_ui),
        .total_src0_decoded(total_src0_decoded_ui),
        .total_src1_decoded(total_src1_decoded_ui),
        .total_src0_bytes_read(total_src0_bytes_read_ui),
        .total_src1_bytes_read(total_src1_bytes_read_ui),
        .total_merge_output_bytes(total_merge_output_bytes_ui),
        .total_merge_decoded_records(total_merge_decoded_ui),
        .total_merge_merged_records(total_merge_merged_ui),
        .total_merge_dropped_records(total_merge_dropped_ui),
        .total_stage5_input_records(total_stage5_input_ui),
        .total_stage5_encoded_entries(total_stage5_encoded_ui),
        .total_stage5_output_block_bytes(total_stage5_out_bytes_ui),
        .total_stage5_bytes_written(total_stage5_written_ui),
        .sstable_count(sstable_count_ui),
        .sstable_sizes_vec(sstable_sizes_vec_ui),
        .m_axi_p0_araddr(m_axi_p0_araddr), .m_axi_p0_arlen(m_axi_p0_arlen),
        .m_axi_p0_arsize(m_axi_p0_arsize), .m_axi_p0_arburst(m_axi_p0_arburst),
        .m_axi_p0_arvalid(m_axi_p0_arvalid), .m_axi_p0_arready(m_axi_p0_arready),
        .m_axi_p0_rdata(m_axi_p0_rdata), .m_axi_p0_rresp(m_axi_p0_rresp),
        .m_axi_p0_rlast(m_axi_p0_rlast), .m_axi_p0_rvalid(m_axi_p0_rvalid),
        .m_axi_p0_rready(m_axi_p0_rready),
        .m_axi_p1_araddr(m_axi_p1_araddr), .m_axi_p1_arlen(m_axi_p1_arlen),
        .m_axi_p1_arsize(m_axi_p1_arsize), .m_axi_p1_arburst(m_axi_p1_arburst),
        .m_axi_p1_arvalid(m_axi_p1_arvalid), .m_axi_p1_arready(m_axi_p1_arready),
        .m_axi_p1_rdata(m_axi_p1_rdata), .m_axi_p1_rresp(m_axi_p1_rresp),
        .m_axi_p1_rlast(m_axi_p1_rlast), .m_axi_p1_rvalid(m_axi_p1_rvalid),
        .m_axi_p1_rready(m_axi_p1_rready),
        .m_axi_src0_araddr(m_axi_src0_araddr), .m_axi_src0_arlen(m_axi_src0_arlen),
        .m_axi_src0_arsize(m_axi_src0_arsize), .m_axi_src0_arburst(m_axi_src0_arburst),
        .m_axi_src0_arvalid(m_axi_src0_arvalid), .m_axi_src0_arready(m_axi_src0_arready),
        .m_axi_src0_rdata(m_axi_src0_rdata), .m_axi_src0_rresp(m_axi_src0_rresp),
        .m_axi_src0_rlast(m_axi_src0_rlast), .m_axi_src0_rvalid(m_axi_src0_rvalid),
        .m_axi_src0_rready(m_axi_src0_rready),
        .m_axi_src1_araddr(m_axi_src1_araddr), .m_axi_src1_arlen(m_axi_src1_arlen),
        .m_axi_src1_arsize(m_axi_src1_arsize), .m_axi_src1_arburst(m_axi_src1_arburst),
        .m_axi_src1_arvalid(m_axi_src1_arvalid), .m_axi_src1_arready(m_axi_src1_arready),
        .m_axi_src1_rdata(m_axi_src1_rdata), .m_axi_src1_rresp(m_axi_src1_rresp),
        .m_axi_src1_rlast(m_axi_src1_rlast), .m_axi_src1_rvalid(m_axi_src1_rvalid),
        .m_axi_src1_rready(m_axi_src1_rready),
        .m_axi_chain_araddr(m_axi_chain_araddr), .m_axi_chain_arlen(m_axi_chain_arlen),
        .m_axi_chain_arsize(m_axi_chain_arsize), .m_axi_chain_arburst(m_axi_chain_arburst),
        .m_axi_chain_arvalid(m_axi_chain_arvalid), .m_axi_chain_arready(m_axi_chain_arready),
        .m_axi_chain_rdata(m_axi_chain_rdata), .m_axi_chain_rresp(m_axi_chain_rresp),
        .m_axi_chain_rlast(m_axi_chain_rlast), .m_axi_chain_rvalid(m_axi_chain_rvalid),
        .m_axi_chain_rready(m_axi_chain_rready),
        .m_axi_chain_awaddr(m_axi_chain_awaddr), .m_axi_chain_awlen(m_axi_chain_awlen),
        .m_axi_chain_awsize(m_axi_chain_awsize), .m_axi_chain_awburst(m_axi_chain_awburst),
        .m_axi_chain_awvalid(m_axi_chain_awvalid), .m_axi_chain_awready(m_axi_chain_awready),
        .m_axi_chain_wdata(m_axi_chain_wdata), .m_axi_chain_wstrb(m_axi_chain_wstrb),
        .m_axi_chain_wlast(m_axi_chain_wlast), .m_axi_chain_wvalid(m_axi_chain_wvalid),
        .m_axi_chain_wready(m_axi_chain_wready),
        .m_axi_chain_bresp(m_axi_chain_bresp), .m_axi_chain_bvalid(m_axi_chain_bvalid),
        .m_axi_chain_bready(m_axi_chain_bready)
    );

endmodule

// ---------------------------------------------------------------------------
// BD-friendly top (Vivado interface annotations)
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module cmpct_top_bd #(
    parameter integer AXIL_ADDR_WIDTH          = 32,
    parameter integer AXIL_DATA_WIDTH          = 32,
    parameter integer AXI_ADDR_WIDTH           = 64,
    parameter integer AXI_DATA_WIDTH           = 512,
    parameter integer AXI_STRB_WIDTH           = 64,
    parameter integer MAX_BURST_LEN            = 16,
    parameter integer MAX_INDEX_BYTES          = 8192,
    parameter integer MAX_BLOCK_PAIRS          = 8,
    parameter integer STAGE4_MAX_BLOCK_BYTES   = 4096,
    parameter integer STAGE4_MAX_KEY_BYTES     = 72,
    parameter integer MERGE_MAX_USER_KEY_BYTES = 64,
    parameter integer MERGE_MAX_KEY_BYTES      = 72,
    parameter integer MERGE_MAX_VALUE_BYTES    = 1024,
    parameter integer MERGE_MAX_RECORD_BYTES   = 2048,
    parameter integer MERGE_MAX_RECORDS        = 256,
    parameter integer MERGE_MAX_OUTPUT_BYTES   = 73728,
    parameter integer STAGE5_MAX_RECORDS       = 256,
    parameter integer STAGE5_MAX_PAYLOAD_BYTES = 4096,
    parameter integer STAGE5_MAX_BLOCK_BYTES   = 4096,
    parameter integer STAGE5_MAX_KEY_BYTES     = 64,
    parameter integer STAGE5_MAX_VALUE_BYTES   = 1024,
    parameter integer STAGE5_RESTART_INTERVAL  = 16,
    parameter integer MAX_SSTABLES              = 8,
    parameter integer SPLIT_TAIL_MARGIN         = 4096
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axil_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME axil_aclk, ASSOCIATED_BUSIF s_axil, ASSOCIATED_RESET axil_aresetn, FREQ_HZ 250000000" *)
    input  wire axil_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axil_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME axil_aresetn, POLARITY ACTIVE_LOW" *)
    input  wire axil_aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axil, ADDR_WIDTH 32, DATA_WIDTH 32, PROTOCOL AXI4LITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 1" *)
    input  wire [AXIL_ADDR_WIDTH-1:0]    s_axil_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil AWVALID" *)
    input  wire                          s_axil_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil AWREADY" *)
    output wire                          s_axil_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil WDATA" *)
    input  wire [AXIL_DATA_WIDTH-1:0]    s_axil_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil WSTRB" *)
    input  wire [AXIL_DATA_WIDTH/8-1:0]  s_axil_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil WVALID" *)
    input  wire                          s_axil_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil WREADY" *)
    output wire                          s_axil_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil BRESP" *)
    output wire [1:0]                    s_axil_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil BVALID" *)
    output wire                          s_axil_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil BREADY" *)
    input  wire                          s_axil_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil ARADDR" *)
    input  wire [AXIL_ADDR_WIDTH-1:0]    s_axil_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil ARVALID" *)
    input  wire                          s_axil_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil ARREADY" *)
    output wire                          s_axil_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil RDATA" *)
    output wire [AXIL_DATA_WIDTH-1:0]    s_axil_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil RRESP" *)
    output wire [1:0]                    s_axil_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil RVALID" *)
    output wire                          s_axil_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil RREADY" *)
    input  wire                          s_axil_rready,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ui_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ui_aclk, ASSOCIATED_BUSIF m_axi_p0:m_axi_p1:m_axi_src0:m_axi_src1:m_axi_chain, ASSOCIATED_RESET ui_aresetn, FREQ_HZ 300000000" *)
    input  wire ui_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ui_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ui_aresetn, POLARITY ACTIVE_LOW" *)
    input  wire ui_aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p0 ARADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi_p0, ADDR_WIDTH 64, DATA_WIDTH 512, PROTOCOL AXI4, ID_WIDTH 0, HAS_BURST 1, MAX_BURST_LENGTH 16, READ_WRITE_MODE READ_ONLY" *)
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_p0_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p0 ARLEN" *)
    output wire [7:0]                 m_axi_p0_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p0 ARSIZE" *)
    output wire [2:0]                 m_axi_p0_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p0 ARBURST" *)
    output wire [1:0]                 m_axi_p0_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p0 ARVALID" *)
    output wire                       m_axi_p0_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p0 ARREADY" *)
    input  wire                       m_axi_p0_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p0 RDATA" *)
    input  wire [AXI_DATA_WIDTH-1:0]  m_axi_p0_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p0 RRESP" *)
    input  wire [1:0]                 m_axi_p0_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p0 RLAST" *)
    input  wire                       m_axi_p0_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p0 RVALID" *)
    input  wire                       m_axi_p0_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p0 RREADY" *)
    output wire                       m_axi_p0_rready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p1 ARADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi_p1, ADDR_WIDTH 64, DATA_WIDTH 512, PROTOCOL AXI4, ID_WIDTH 0, HAS_BURST 1, MAX_BURST_LENGTH 16, READ_WRITE_MODE READ_ONLY" *)
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_p1_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p1 ARLEN" *)
    output wire [7:0]                 m_axi_p1_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p1 ARSIZE" *)
    output wire [2:0]                 m_axi_p1_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p1 ARBURST" *)
    output wire [1:0]                 m_axi_p1_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p1 ARVALID" *)
    output wire                       m_axi_p1_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p1 ARREADY" *)
    input  wire                       m_axi_p1_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p1 RDATA" *)
    input  wire [AXI_DATA_WIDTH-1:0]  m_axi_p1_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p1 RRESP" *)
    input  wire [1:0]                 m_axi_p1_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p1 RLAST" *)
    input  wire                       m_axi_p1_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p1 RVALID" *)
    input  wire                       m_axi_p1_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_p1 RREADY" *)
    output wire                       m_axi_p1_rready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src0 ARADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi_src0, ADDR_WIDTH 64, DATA_WIDTH 512, PROTOCOL AXI4, ID_WIDTH 0, HAS_BURST 1, MAX_BURST_LENGTH 16, READ_WRITE_MODE READ_ONLY" *)
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_src0_araddr,
    output wire [7:0]                 m_axi_src0_arlen,
    output wire [2:0]                 m_axi_src0_arsize,
    output wire [1:0]                 m_axi_src0_arburst,
    output wire                       m_axi_src0_arvalid,
    input  wire                       m_axi_src0_arready,
    input  wire [AXI_DATA_WIDTH-1:0]  m_axi_src0_rdata,
    input  wire [1:0]                 m_axi_src0_rresp,
    input  wire                       m_axi_src0_rlast,
    input  wire                       m_axi_src0_rvalid,
    output wire                       m_axi_src0_rready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_src1 ARADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi_src1, ADDR_WIDTH 64, DATA_WIDTH 512, PROTOCOL AXI4, ID_WIDTH 0, HAS_BURST 1, MAX_BURST_LENGTH 16, READ_WRITE_MODE READ_ONLY" *)
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_src1_araddr,
    output wire [7:0]                 m_axi_src1_arlen,
    output wire [2:0]                 m_axi_src1_arsize,
    output wire [1:0]                 m_axi_src1_arburst,
    output wire                       m_axi_src1_arvalid,
    input  wire                       m_axi_src1_arready,
    input  wire [AXI_DATA_WIDTH-1:0]  m_axi_src1_rdata,
    input  wire [1:0]                 m_axi_src1_rresp,
    input  wire                       m_axi_src1_rlast,
    input  wire                       m_axi_src1_rvalid,
    output wire                       m_axi_src1_rready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_chain ARADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi_chain, ADDR_WIDTH 64, DATA_WIDTH 512, PROTOCOL AXI4, ID_WIDTH 0, HAS_BURST 1, MAX_BURST_LENGTH 16, READ_WRITE_MODE READ_WRITE" *)
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_chain_araddr,
    output wire [7:0]                 m_axi_chain_arlen,
    output wire [2:0]                 m_axi_chain_arsize,
    output wire [1:0]                 m_axi_chain_arburst,
    output wire                       m_axi_chain_arvalid,
    input  wire                       m_axi_chain_arready,
    input  wire [AXI_DATA_WIDTH-1:0]  m_axi_chain_rdata,
    input  wire [1:0]                 m_axi_chain_rresp,
    input  wire                       m_axi_chain_rlast,
    input  wire                       m_axi_chain_rvalid,
    output wire                       m_axi_chain_rready,
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_chain_awaddr,
    output wire [7:0]                 m_axi_chain_awlen,
    output wire [2:0]                 m_axi_chain_awsize,
    output wire [1:0]                 m_axi_chain_awburst,
    output wire                       m_axi_chain_awvalid,
    input  wire                       m_axi_chain_awready,
    output wire [AXI_DATA_WIDTH-1:0]  m_axi_chain_wdata,
    output wire [AXI_STRB_WIDTH-1:0]  m_axi_chain_wstrb,
    output wire                       m_axi_chain_wlast,
    output wire                       m_axi_chain_wvalid,
    input  wire                       m_axi_chain_wready,
    input  wire [1:0]                 m_axi_chain_bresp,
    input  wire                       m_axi_chain_bvalid,
    output wire                       m_axi_chain_bready,

    output wire done,
    output wire busy,
    output wire error,
    output wire [31:0] blocks_done,
    output wire [31:0] bytes_done,

    // OPT-IRQ / P5: MSI-X interrupt request
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 usr_irq_req INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME usr_irq_req, SENSITIVITY EDGE_RISING" *)
    output wire usr_irq_req
);

    cmpct_top #(
        .AXIL_ADDR_WIDTH(AXIL_ADDR_WIDTH),
        .AXIL_DATA_WIDTH(AXIL_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_STRB_WIDTH(AXI_STRB_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .MAX_INDEX_BYTES(MAX_INDEX_BYTES),
        .MAX_BLOCK_PAIRS(MAX_BLOCK_PAIRS),
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
        .MAX_SSTABLES(MAX_SSTABLES),
        .SPLIT_TAIL_MARGIN(SPLIT_TAIL_MARGIN)
    ) u_axil_top (
        .axil_aclk(axil_aclk), .axil_aresetn(axil_aresetn),
        .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata),   .s_axil_wstrb(s_axil_wstrb),     .s_axil_wvalid(s_axil_wvalid),  .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp),   .s_axil_bvalid(s_axil_bvalid),   .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata),   .s_axil_rresp(s_axil_rresp),     .s_axil_rvalid(s_axil_rvalid),  .s_axil_rready(s_axil_rready),
        .ui_aclk(ui_aclk), .ui_aresetn(ui_aresetn),
        .m_axi_p0_araddr(m_axi_p0_araddr), .m_axi_p0_arlen(m_axi_p0_arlen),
        .m_axi_p0_arsize(m_axi_p0_arsize), .m_axi_p0_arburst(m_axi_p0_arburst),
        .m_axi_p0_arvalid(m_axi_p0_arvalid), .m_axi_p0_arready(m_axi_p0_arready),
        .m_axi_p0_rdata(m_axi_p0_rdata), .m_axi_p0_rresp(m_axi_p0_rresp),
        .m_axi_p0_rlast(m_axi_p0_rlast), .m_axi_p0_rvalid(m_axi_p0_rvalid), .m_axi_p0_rready(m_axi_p0_rready),
        .m_axi_p1_araddr(m_axi_p1_araddr), .m_axi_p1_arlen(m_axi_p1_arlen),
        .m_axi_p1_arsize(m_axi_p1_arsize), .m_axi_p1_arburst(m_axi_p1_arburst),
        .m_axi_p1_arvalid(m_axi_p1_arvalid), .m_axi_p1_arready(m_axi_p1_arready),
        .m_axi_p1_rdata(m_axi_p1_rdata), .m_axi_p1_rresp(m_axi_p1_rresp),
        .m_axi_p1_rlast(m_axi_p1_rlast), .m_axi_p1_rvalid(m_axi_p1_rvalid), .m_axi_p1_rready(m_axi_p1_rready),
        .m_axi_src0_araddr(m_axi_src0_araddr), .m_axi_src0_arlen(m_axi_src0_arlen),
        .m_axi_src0_arsize(m_axi_src0_arsize), .m_axi_src0_arburst(m_axi_src0_arburst),
        .m_axi_src0_arvalid(m_axi_src0_arvalid), .m_axi_src0_arready(m_axi_src0_arready),
        .m_axi_src0_rdata(m_axi_src0_rdata), .m_axi_src0_rresp(m_axi_src0_rresp),
        .m_axi_src0_rlast(m_axi_src0_rlast), .m_axi_src0_rvalid(m_axi_src0_rvalid), .m_axi_src0_rready(m_axi_src0_rready),
        .m_axi_src1_araddr(m_axi_src1_araddr), .m_axi_src1_arlen(m_axi_src1_arlen),
        .m_axi_src1_arsize(m_axi_src1_arsize), .m_axi_src1_arburst(m_axi_src1_arburst),
        .m_axi_src1_arvalid(m_axi_src1_arvalid), .m_axi_src1_arready(m_axi_src1_arready),
        .m_axi_src1_rdata(m_axi_src1_rdata), .m_axi_src1_rresp(m_axi_src1_rresp),
        .m_axi_src1_rlast(m_axi_src1_rlast), .m_axi_src1_rvalid(m_axi_src1_rvalid), .m_axi_src1_rready(m_axi_src1_rready),
        .m_axi_chain_araddr(m_axi_chain_araddr), .m_axi_chain_arlen(m_axi_chain_arlen),
        .m_axi_chain_arsize(m_axi_chain_arsize), .m_axi_chain_arburst(m_axi_chain_arburst),
        .m_axi_chain_arvalid(m_axi_chain_arvalid), .m_axi_chain_arready(m_axi_chain_arready),
        .m_axi_chain_rdata(m_axi_chain_rdata), .m_axi_chain_rresp(m_axi_chain_rresp),
        .m_axi_chain_rlast(m_axi_chain_rlast), .m_axi_chain_rvalid(m_axi_chain_rvalid), .m_axi_chain_rready(m_axi_chain_rready),
        .m_axi_chain_awaddr(m_axi_chain_awaddr), .m_axi_chain_awlen(m_axi_chain_awlen),
        .m_axi_chain_awsize(m_axi_chain_awsize), .m_axi_chain_awburst(m_axi_chain_awburst),
        .m_axi_chain_awvalid(m_axi_chain_awvalid), .m_axi_chain_awready(m_axi_chain_awready),
        .m_axi_chain_wdata(m_axi_chain_wdata), .m_axi_chain_wstrb(m_axi_chain_wstrb),
        .m_axi_chain_wlast(m_axi_chain_wlast), .m_axi_chain_wvalid(m_axi_chain_wvalid), .m_axi_chain_wready(m_axi_chain_wready),
        .m_axi_chain_bresp(m_axi_chain_bresp), .m_axi_chain_bvalid(m_axi_chain_bvalid), .m_axi_chain_bready(m_axi_chain_bready),
        .done(done), .busy(busy), .error(error), .blocks_done(blocks_done), .bytes_done(bytes_done),
        .usr_irq_req(usr_irq_req)
    );

endmodule
