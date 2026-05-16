`timescale 1ns / 1ps

module stage5_real_data_block_encode_axil_top #(
    parameter integer AXIL_ADDR_WIDTH    = 32,
    parameter integer AXIL_DATA_WIDTH    = 32,
    parameter integer AXI_ADDR_WIDTH     = 64,
    parameter integer AXI_DATA_WIDTH     = 512,
    parameter integer AXI_STRB_WIDTH     = 64,
    parameter integer MAX_BURST_LEN      = 16,
    parameter integer MAX_RECORDS        = 256,
    parameter integer MAX_PAYLOAD_BYTES  = 4096,
    parameter integer MAX_BLOCK_BYTES    = 4096,
    parameter integer MAX_KEY_BYTES      = 256,
    parameter integer MAX_VALUE_BYTES    = 1024,
    parameter integer RESTART_INTERVAL   = 16
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axil_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000, ASSOCIATED_BUSIF s_axil, ASSOCIATED_RESET axil_aresetn" *)
    input  wire                        axil_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axil_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                        axil_aresetn,

    input  wire [AXIL_ADDR_WIDTH-1:0]   s_axil_awaddr,
    input  wire                         s_axil_awvalid,
    output reg                          s_axil_awready,
    input  wire [AXIL_DATA_WIDTH-1:0]   s_axil_wdata,
    input  wire [AXIL_DATA_WIDTH/8-1:0] s_axil_wstrb,
    input  wire                         s_axil_wvalid,
    output reg                          s_axil_wready,
    output reg  [1:0]                   s_axil_bresp,
    output reg                          s_axil_bvalid,
    input  wire                         s_axil_bready,
    input  wire [AXIL_ADDR_WIDTH-1:0]   s_axil_araddr,
    input  wire                         s_axil_arvalid,
    output reg                          s_axil_arready,
    output reg  [AXIL_DATA_WIDTH-1:0]   s_axil_rdata,
    output reg  [1:0]                   s_axil_rresp,
    output reg                          s_axil_rvalid,
    input  wire                         s_axil_rready,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ui_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 300000000, ASSOCIATED_BUSIF m_axi, ASSOCIATED_RESET ui_aresetn" *)
    input  wire                        ui_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ui_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                        ui_aresetn,

    output wire [AXI_ADDR_WIDTH-1:0]   m_axi_araddr,
    output wire [7:0]                  m_axi_arlen,
    output wire [2:0]                  m_axi_arsize,
    output wire [1:0]                  m_axi_arburst,
    output wire                        m_axi_arvalid,
    input  wire                        m_axi_arready,
    input  wire [AXI_DATA_WIDTH-1:0]   m_axi_rdata,
    input  wire [1:0]                  m_axi_rresp,
    input  wire                        m_axi_rlast,
    input  wire                        m_axi_rvalid,
    output wire                        m_axi_rready,

    output wire [AXI_ADDR_WIDTH-1:0]   m_axi_awaddr,
    output wire [7:0]                  m_axi_awlen,
    output wire [2:0]                  m_axi_awsize,
    output wire [1:0]                  m_axi_awburst,
    output wire                        m_axi_awvalid,
    input  wire                        m_axi_awready,
    output wire [AXI_DATA_WIDTH-1:0]   m_axi_wdata,
    output wire [AXI_STRB_WIDTH-1:0]   m_axi_wstrb,
    output wire                        m_axi_wlast,
    output wire                        m_axi_wvalid,
    input  wire                        m_axi_wready,
    input  wire [1:0]                  m_axi_bresp,
    input  wire                        m_axi_bvalid,
    output wire                        m_axi_bready,

    output reg  [AXI_DATA_WIDTH-1:0]   dbg_last_accum,
    output wire                        done,
    output wire                        busy,
    output wire                        error,
    output wire [31:0]                 bytes_done,
    output wire [31:0]                 blocks_done
);

    localparam [AXIL_ADDR_WIDTH-1:0] REG_CTRL                   = 32'h0000;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_STATUS                 = 32'h0004;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC_BASE_LO            = 32'h0008;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC_BASE_HI            = 32'h000C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC_SIZE               = 32'h0010;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DST_BASE_LO            = 32'h0014;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DST_BASE_HI            = 32'h0018;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_INPUT_RECORD_COUNT     = 32'h001C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_ENCODED_ENTRY_COUNT    = 32'h0020;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_RESTART_COUNT          = 32'h0024;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SHARED_KEY_BYTES_TOTAL = 32'h0028;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_UNSHARED_KEY_BYTES_TOTAL = 32'h002C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_VALUE_BYTES_TOTAL      = 32'h0030;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_LAST_KEY_LEN           = 32'h0034;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_LAST_VALUE_LEN         = 32'h0038;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_LAST_SHARED_BYTES      = 32'h003C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_LAST_NON_SHARED_BYTES  = 32'h0040;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_OUTPUT_BLOCK_BYTES     = 32'h0044;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_BYTES_READ             = 32'h0048;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_BEATS_READ             = 32'h004C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_BYTES_WRITTEN          = 32'h0050;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_BEATS_WRITTEN          = 32'h0054;

    reg [31:0] r_ctrl;
    reg [31:0] r_status;
    reg [63:0] r_src_base;
    reg [31:0] r_src_size;
    reg [63:0] r_dst_base;

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
    reg [63:0] cfg_src_base_axil;
    reg [31:0] cfg_src_size_axil;
    reg [63:0] cfg_dst_base_axil;

    reg        start_toggle_ui_ff1;
    reg        start_toggle_ui_ff2;
    reg        start_toggle_ui_ff3;
    reg        clear_toggle_ui_ff1;
    reg        clear_toggle_ui_ff2;
    reg        clear_toggle_ui_ff3;
    reg [63:0] cfg_src_base_ui_ff1;
    reg [63:0] cfg_src_base_ui_ff2;
    reg [31:0] cfg_src_size_ui_ff1;
    reg [31:0] cfg_src_size_ui_ff2;
    reg [63:0] cfg_dst_base_ui_ff1;
    reg [63:0] cfg_dst_base_ui_ff2;

    wire start_pulse_ui = start_toggle_ui_ff3 ^ start_toggle_ui_ff2;
    wire clear_pulse_ui = clear_toggle_ui_ff3 ^ clear_toggle_ui_ff2;

    wire        encode_busy_ui;
    wire        encode_done_ui;
    wire        encode_error_ui;
    wire [31:0] encode_bytes_read_ui;
    wire [31:0] encode_beats_read_ui;
    wire [31:0] encode_bytes_written_ui;
    wire [31:0] encode_beats_written_ui;
    wire [31:0] encode_input_record_count_ui;
    wire [31:0] encode_encoded_entry_count_ui;
    wire [31:0] encode_restart_count_ui;
    wire [31:0] encode_shared_key_bytes_total_ui;
    wire [31:0] encode_unshared_key_bytes_total_ui;
    wire [31:0] encode_value_bytes_total_ui;
    wire [15:0] encode_last_key_len_ui;
    wire [15:0] encode_last_value_len_ui;
    wire [15:0] encode_last_shared_bytes_ui;
    wire [15:0] encode_last_non_shared_bytes_ui;
    wire [31:0] encode_output_block_bytes_ui;

    reg         done_ui_latched;
    reg         error_ui_latched;
    reg         done_ui_d;
    reg         error_ui_d;
    reg         done_toggle_ui;
    reg         error_toggle_ui;

    reg done_toggle_axil_ff1;
    reg done_toggle_axil_ff2;
    reg error_toggle_axil_ff1;
    reg error_toggle_axil_ff2;
    wire done_pulse_axil  = done_toggle_axil_ff2 ^ done_toggle_axil_ff1;
    wire error_pulse_axil = error_toggle_axil_ff2 ^ error_toggle_axil_ff1;

    reg        busy_axil_ff1;
    reg        busy_axil_ff2;
    reg [31:0] input_record_count_axil_ff1;
    reg [31:0] input_record_count_axil_ff2;
    reg [31:0] encoded_entry_count_axil_ff1;
    reg [31:0] encoded_entry_count_axil_ff2;
    reg [31:0] restart_count_axil_ff1;
    reg [31:0] restart_count_axil_ff2;
    reg [31:0] shared_key_bytes_total_axil_ff1;
    reg [31:0] shared_key_bytes_total_axil_ff2;
    reg [31:0] unshared_key_bytes_total_axil_ff1;
    reg [31:0] unshared_key_bytes_total_axil_ff2;
    reg [31:0] value_bytes_total_axil_ff1;
    reg [31:0] value_bytes_total_axil_ff2;
    reg [15:0] last_key_len_axil_ff1;
    reg [15:0] last_key_len_axil_ff2;
    reg [15:0] last_value_len_axil_ff1;
    reg [15:0] last_value_len_axil_ff2;
    reg [15:0] last_shared_bytes_axil_ff1;
    reg [15:0] last_shared_bytes_axil_ff2;
    reg [15:0] last_non_shared_bytes_axil_ff1;
    reg [15:0] last_non_shared_bytes_axil_ff2;
    reg [31:0] output_block_bytes_axil_ff1;
    reg [31:0] output_block_bytes_axil_ff2;
    reg [31:0] bytes_read_axil_ff1;
    reg [31:0] bytes_read_axil_ff2;
    reg [31:0] beats_read_axil_ff1;
    reg [31:0] beats_read_axil_ff2;
    reg [31:0] bytes_written_axil_ff1;
    reg [31:0] bytes_written_axil_ff2;
    reg [31:0] beats_written_axil_ff1;
    reg [31:0] beats_written_axil_ff2;

    wire [AXI_ADDR_WIDTH-1:0] m_axi_araddr_i;
    wire [7:0]                m_axi_arlen_i;
    wire [2:0]                m_axi_arsize_i;
    wire [1:0]                m_axi_arburst_i;
    wire                      m_axi_arvalid_i;
    wire                      m_axi_rready_i;
    wire [AXI_ADDR_WIDTH-1:0] m_axi_awaddr_i;
    wire [7:0]                m_axi_awlen_i;
    wire [2:0]                m_axi_awsize_i;
    wire [1:0]                m_axi_awburst_i;
    wire                      m_axi_awvalid_i;
    wire [AXI_DATA_WIDTH-1:0] m_axi_wdata_i;
    wire [AXI_STRB_WIDTH-1:0] m_axi_wstrb_i;
    wire                      m_axi_wlast_i;
    wire                      m_axi_wvalid_i;
    wire                      m_axi_bready_i;

    assign m_axi_araddr  = m_axi_araddr_i;
    assign m_axi_arlen   = m_axi_arlen_i;
    assign m_axi_arsize  = m_axi_arsize_i;
    assign m_axi_arburst = m_axi_arburst_i;
    assign m_axi_arvalid = m_axi_arvalid_i;
    assign m_axi_rready  = m_axi_rready_i;
    assign m_axi_awaddr  = m_axi_awaddr_i;
    assign m_axi_awlen   = m_axi_awlen_i;
    assign m_axi_awsize  = m_axi_awsize_i;
    assign m_axi_awburst = m_axi_awburst_i;
    assign m_axi_awvalid = m_axi_awvalid_i;
    assign m_axi_wdata   = m_axi_wdata_i;
    assign m_axi_wstrb   = m_axi_wstrb_i;
    assign m_axi_wlast   = m_axi_wlast_i;
    assign m_axi_wvalid  = m_axi_wvalid_i;
    assign m_axi_bready  = m_axi_bready_i;

    assign done       = done_ui_latched;
    assign busy       = encode_busy_ui;
    assign error      = error_ui_latched;
    assign bytes_done = encode_bytes_written_ui;
    assign blocks_done = encode_encoded_entry_count_ui;

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
                    REG_CTRL:                    s_axil_rdata <= r_ctrl;
                    REG_STATUS:                  s_axil_rdata <= r_status;
                    REG_SRC_BASE_LO:             s_axil_rdata <= r_src_base[31:0];
                    REG_SRC_BASE_HI:             s_axil_rdata <= r_src_base[63:32];
                    REG_SRC_SIZE:                s_axil_rdata <= r_src_size;
                    REG_DST_BASE_LO:             s_axil_rdata <= r_dst_base[31:0];
                    REG_DST_BASE_HI:             s_axil_rdata <= r_dst_base[63:32];
                    REG_INPUT_RECORD_COUNT:      s_axil_rdata <= input_record_count_axil_ff2;
                    REG_ENCODED_ENTRY_COUNT:     s_axil_rdata <= encoded_entry_count_axil_ff2;
                    REG_RESTART_COUNT:           s_axil_rdata <= restart_count_axil_ff2;
                    REG_SHARED_KEY_BYTES_TOTAL:  s_axil_rdata <= shared_key_bytes_total_axil_ff2;
                    REG_UNSHARED_KEY_BYTES_TOTAL:s_axil_rdata <= unshared_key_bytes_total_axil_ff2;
                    REG_VALUE_BYTES_TOTAL:       s_axil_rdata <= value_bytes_total_axil_ff2;
                    REG_LAST_KEY_LEN:            s_axil_rdata <= {16'h0, last_key_len_axil_ff2};
                    REG_LAST_VALUE_LEN:          s_axil_rdata <= {16'h0, last_value_len_axil_ff2};
                    REG_LAST_SHARED_BYTES:       s_axil_rdata <= {16'h0, last_shared_bytes_axil_ff2};
                    REG_LAST_NON_SHARED_BYTES:   s_axil_rdata <= {16'h0, last_non_shared_bytes_axil_ff2};
                    REG_OUTPUT_BLOCK_BYTES:      s_axil_rdata <= output_block_bytes_axil_ff2;
                    REG_BYTES_READ:              s_axil_rdata <= bytes_read_axil_ff2;
                    REG_BEATS_READ:              s_axil_rdata <= beats_read_axil_ff2;
                    REG_BYTES_WRITTEN:           s_axil_rdata <= bytes_written_axil_ff2;
                    REG_BEATS_WRITTEN:           s_axil_rdata <= beats_written_axil_ff2;
                    default:                     s_axil_rdata <= 32'h0;
                endcase
            end else if (r_hs) begin
                s_axil_rvalid <= 1'b0;
            end
        end
    end

    always @(posedge axil_aclk) begin
        if (!axil_aresetn) begin
            r_ctrl                         <= 32'h0;
            r_status                       <= 32'h0;
            r_src_base                     <= 64'h0;
            r_src_size                     <= 32'h0;
            r_dst_base                     <= 64'h0;
            ctrl_start_d                   <= 1'b0;
            ctrl_clear_d                   <= 1'b0;
            start_toggle_axil              <= 1'b0;
            clear_toggle_axil              <= 1'b0;
            cfg_src_base_axil              <= 64'h0;
            cfg_src_size_axil              <= 32'h0;
            cfg_dst_base_axil              <= 64'h0;
            busy_axil_ff1                  <= 1'b0;
            busy_axil_ff2                  <= 1'b0;
            input_record_count_axil_ff1    <= 32'h0;
            input_record_count_axil_ff2    <= 32'h0;
            encoded_entry_count_axil_ff1   <= 32'h0;
            encoded_entry_count_axil_ff2   <= 32'h0;
            restart_count_axil_ff1         <= 32'h0;
            restart_count_axil_ff2         <= 32'h0;
            shared_key_bytes_total_axil_ff1 <= 32'h0;
            shared_key_bytes_total_axil_ff2 <= 32'h0;
            unshared_key_bytes_total_axil_ff1 <= 32'h0;
            unshared_key_bytes_total_axil_ff2 <= 32'h0;
            value_bytes_total_axil_ff1     <= 32'h0;
            value_bytes_total_axil_ff2     <= 32'h0;
            last_key_len_axil_ff1          <= 16'h0;
            last_key_len_axil_ff2          <= 16'h0;
            last_value_len_axil_ff1        <= 16'h0;
            last_value_len_axil_ff2        <= 16'h0;
            last_shared_bytes_axil_ff1     <= 16'h0;
            last_shared_bytes_axil_ff2     <= 16'h0;
            last_non_shared_bytes_axil_ff1 <= 16'h0;
            last_non_shared_bytes_axil_ff2 <= 16'h0;
            output_block_bytes_axil_ff1    <= 32'h0;
            output_block_bytes_axil_ff2    <= 32'h0;
            bytes_read_axil_ff1            <= 32'h0;
            bytes_read_axil_ff2            <= 32'h0;
            beats_read_axil_ff1            <= 32'h0;
            beats_read_axil_ff2            <= 32'h0;
            bytes_written_axil_ff1         <= 32'h0;
            bytes_written_axil_ff2         <= 32'h0;
            beats_written_axil_ff1         <= 32'h0;
            beats_written_axil_ff2         <= 32'h0;
        end else begin
            ctrl_start_d <= r_ctrl[0];
            ctrl_clear_d <= r_ctrl[1];
            cfg_src_base_axil <= r_src_base;
            cfg_src_size_axil <= r_src_size;
            cfg_dst_base_axil <= r_dst_base;

            busy_axil_ff1 <= encode_busy_ui;
            busy_axil_ff2 <= busy_axil_ff1;
            input_record_count_axil_ff1 <= encode_input_record_count_ui;
            input_record_count_axil_ff2 <= input_record_count_axil_ff1;
            encoded_entry_count_axil_ff1 <= encode_encoded_entry_count_ui;
            encoded_entry_count_axil_ff2 <= encoded_entry_count_axil_ff1;
            restart_count_axil_ff1 <= encode_restart_count_ui;
            restart_count_axil_ff2 <= restart_count_axil_ff1;
            shared_key_bytes_total_axil_ff1 <= encode_shared_key_bytes_total_ui;
            shared_key_bytes_total_axil_ff2 <= shared_key_bytes_total_axil_ff1;
            unshared_key_bytes_total_axil_ff1 <= encode_unshared_key_bytes_total_ui;
            unshared_key_bytes_total_axil_ff2 <= unshared_key_bytes_total_axil_ff1;
            value_bytes_total_axil_ff1 <= encode_value_bytes_total_ui;
            value_bytes_total_axil_ff2 <= value_bytes_total_axil_ff1;
            last_key_len_axil_ff1 <= encode_last_key_len_ui;
            last_key_len_axil_ff2 <= last_key_len_axil_ff1;
            last_value_len_axil_ff1 <= encode_last_value_len_ui;
            last_value_len_axil_ff2 <= last_value_len_axil_ff1;
            last_shared_bytes_axil_ff1 <= encode_last_shared_bytes_ui;
            last_shared_bytes_axil_ff2 <= last_shared_bytes_axil_ff1;
            last_non_shared_bytes_axil_ff1 <= encode_last_non_shared_bytes_ui;
            last_non_shared_bytes_axil_ff2 <= last_non_shared_bytes_axil_ff1;
            output_block_bytes_axil_ff1 <= encode_output_block_bytes_ui;
            output_block_bytes_axil_ff2 <= output_block_bytes_axil_ff1;
            bytes_read_axil_ff1 <= encode_bytes_read_ui;
            bytes_read_axil_ff2 <= bytes_read_axil_ff1;
            beats_read_axil_ff1 <= encode_beats_read_ui;
            beats_read_axil_ff2 <= beats_read_axil_ff1;
            bytes_written_axil_ff1 <= encode_bytes_written_ui;
            bytes_written_axil_ff2 <= bytes_written_axil_ff1;
            beats_written_axil_ff1 <= encode_beats_written_ui;
            beats_written_axil_ff2 <= beats_written_axil_ff1;

            r_status[0] <= busy_axil_ff2;

            if (can_accept_write && awaddr_valid && w_hs) begin
                case (awaddr_lat)
                    REG_CTRL: begin
                        if (s_axil_wstrb[0]) r_ctrl[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_ctrl[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_ctrl[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_ctrl[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_SRC_BASE_LO: begin
                        if (s_axil_wstrb[0]) r_src_base[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src_base[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src_base[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src_base[31:24] <= s_axil_wdata[31:24];
                    end
                    REG_SRC_BASE_HI: begin
                        if (s_axil_wstrb[0]) r_src_base[39:32] <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src_base[47:40] <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src_base[55:48] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src_base[63:56] <= s_axil_wdata[31:24];
                    end
                    REG_SRC_SIZE: begin
                        if (s_axil_wstrb[0]) r_src_size[7:0]   <= s_axil_wdata[7:0];
                        if (s_axil_wstrb[1]) r_src_size[15:8]  <= s_axil_wdata[15:8];
                        if (s_axil_wstrb[2]) r_src_size[23:16] <= s_axil_wdata[23:16];
                        if (s_axil_wstrb[3]) r_src_size[31:24] <= s_axil_wdata[31:24];
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
                r_ctrl[0] <= 1'b0;
                r_status[1] <= 1'b0;
                r_status[2] <= 1'b0;
                start_toggle_axil <= ~start_toggle_axil;
            end

            if (ctrl_clear_pulse) begin
                r_ctrl[1] <= 1'b0;
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
            cfg_src_base_ui_ff1 <= 64'h0;
            cfg_src_base_ui_ff2 <= 64'h0;
            cfg_src_size_ui_ff1 <= 32'h0;
            cfg_src_size_ui_ff2 <= 32'h0;
            cfg_dst_base_ui_ff1 <= 64'h0;
            cfg_dst_base_ui_ff2 <= 64'h0;
            done_ui_d <= 1'b0;
            error_ui_d <= 1'b0;
            done_toggle_ui <= 1'b0;
            error_toggle_ui <= 1'b0;
            done_ui_latched <= 1'b0;
            error_ui_latched <= 1'b0;
            dbg_last_accum <= {AXI_DATA_WIDTH{1'b0}};
        end else begin
            start_toggle_ui_ff1 <= start_toggle_axil;
            start_toggle_ui_ff2 <= start_toggle_ui_ff1;
            start_toggle_ui_ff3 <= start_toggle_ui_ff2;
            clear_toggle_ui_ff1 <= clear_toggle_axil;
            clear_toggle_ui_ff2 <= clear_toggle_ui_ff1;
            clear_toggle_ui_ff3 <= clear_toggle_ui_ff2;

            cfg_src_base_ui_ff1 <= cfg_src_base_axil;
            cfg_src_base_ui_ff2 <= cfg_src_base_ui_ff1;
            cfg_src_size_ui_ff1 <= cfg_src_size_axil;
            cfg_src_size_ui_ff2 <= cfg_src_size_ui_ff1;
            cfg_dst_base_ui_ff1 <= cfg_dst_base_axil;
            cfg_dst_base_ui_ff2 <= cfg_dst_base_ui_ff1;

            if (start_pulse_ui || clear_pulse_ui) begin
                done_ui_latched  <= 1'b0;
                error_ui_latched <= 1'b0;
            end

            done_ui_d <= encode_done_ui;
            error_ui_d <= encode_error_ui;
            if (encode_done_ui && !done_ui_d) begin
                done_toggle_ui <= ~done_toggle_ui;
                done_ui_latched <= 1'b1;
            end
            if (encode_error_ui && !error_ui_d) begin
                error_toggle_ui <= ~error_toggle_ui;
                error_ui_latched <= 1'b1;
            end

            dbg_last_accum <= {
                {(AXI_DATA_WIDTH-416){1'b0}},
                beats_written_axil_ff2,
                bytes_written_axil_ff2,
                beats_read_axil_ff2,
                bytes_read_axil_ff2,
                output_block_bytes_axil_ff2,
                {16'h0, last_non_shared_bytes_axil_ff2},
                {16'h0, last_shared_bytes_axil_ff2},
                {16'h0, last_value_len_axil_ff2},
                {16'h0, last_key_len_axil_ff2},
                value_bytes_total_axil_ff2,
                unshared_key_bytes_total_axil_ff2,
                shared_key_bytes_total_axil_ff2,
                restart_count_axil_ff2,
                encoded_entry_count_axil_ff2,
                input_record_count_axil_ff2
            };
        end
    end

    always @(posedge axil_aclk) begin
        if (!axil_aresetn) begin
            done_toggle_axil_ff1 <= 1'b0;
            done_toggle_axil_ff2 <= 1'b0;
            error_toggle_axil_ff1 <= 1'b0;
            error_toggle_axil_ff2 <= 1'b0;
        end else begin
            done_toggle_axil_ff1 <= done_toggle_ui;
            done_toggle_axil_ff2 <= done_toggle_axil_ff1;
            error_toggle_axil_ff1 <= error_toggle_ui;
            error_toggle_axil_ff2 <= error_toggle_axil_ff1;
        end
    end

    stage5_real_data_block_encode_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .MAX_RECORDS(MAX_RECORDS),
        .MAX_PAYLOAD_BYTES(MAX_PAYLOAD_BYTES),
        .MAX_BLOCK_BYTES(MAX_BLOCK_BYTES),
        .MAX_KEY_BYTES(MAX_KEY_BYTES),
        .MAX_VALUE_BYTES(MAX_VALUE_BYTES),
        .RESTART_INTERVAL(RESTART_INTERVAL)
    ) u_stage5_real_data_block_encode_top (
        .clk(ui_aclk),
        .rstn(ui_aresetn),
        .clear(clear_pulse_ui),
        .start(start_pulse_ui),
        .src_base_addr(cfg_src_base_ui_ff2),
        .src_byte_count(cfg_src_size_ui_ff2),
        .dst_base_addr(cfg_dst_base_ui_ff2),
        .busy(encode_busy_ui),
        .done(encode_done_ui),
        .error(encode_error_ui),
        .bytes_read(encode_bytes_read_ui),
        .beats_read(encode_beats_read_ui),
        .bytes_written(encode_bytes_written_ui),
        .beats_written(encode_beats_written_ui),
        .input_record_count(encode_input_record_count_ui),
        .encoded_entry_count(encode_encoded_entry_count_ui),
        .restart_count(encode_restart_count_ui),
        .shared_key_bytes_total(encode_shared_key_bytes_total_ui),
        .unshared_key_bytes_total(encode_unshared_key_bytes_total_ui),
        .value_bytes_total(encode_value_bytes_total_ui),
        .last_key_len(encode_last_key_len_ui),
        .last_value_len(encode_last_value_len_ui),
        .last_shared_bytes(encode_last_shared_bytes_ui),
        .last_non_shared_bytes(encode_last_non_shared_bytes_ui),
        .output_block_bytes(encode_output_block_bytes_ui),
        .m_axi_araddr(m_axi_araddr_i),
        .m_axi_arlen(m_axi_arlen_i),
        .m_axi_arsize(m_axi_arsize_i),
        .m_axi_arburst(m_axi_arburst_i),
        .m_axi_arid(),
        .m_axi_arvalid(m_axi_arvalid_i),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rid(1'b0),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready_i),
        .m_axi_awaddr(m_axi_awaddr_i),
        .m_axi_awlen(m_axi_awlen_i),
        .m_axi_awsize(m_axi_awsize_i),
        .m_axi_awburst(m_axi_awburst_i),
        .m_axi_awid(),
        .m_axi_awvalid(m_axi_awvalid_i),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata_i),
        .m_axi_wstrb(m_axi_wstrb_i),
        .m_axi_wlast(m_axi_wlast_i),
        .m_axi_wvalid(m_axi_wvalid_i),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bid(1'b0),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready_i)
    );

endmodule
