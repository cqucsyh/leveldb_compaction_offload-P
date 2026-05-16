`timescale 1ns / 1ps

module stage3_internal_key_merge_axil_top #(
    parameter integer AXIL_ADDR_WIDTH     = 32,
    parameter integer AXIL_DATA_WIDTH     = 32,
    parameter integer AXI_ADDR_WIDTH      = 64,
    parameter integer AXI_DATA_WIDTH      = 512,
    parameter integer AXI_STRB_WIDTH      = 64,
    parameter integer MAX_BURST_LEN       = 16,
    parameter integer MAX_USER_KEY_BYTES  = 64
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

    localparam [AXIL_ADDR_WIDTH-1:0] REG_CTRL                     = 32'h0000;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_STATUS                   = 32'h0004;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC_BASE_LO              = 32'h0008;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC_BASE_HI              = 32'h000C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_SRC_SIZE                 = 32'h0010;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_HEADER_RECORD_COUNT      = 32'h0014;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DECODED_RECORD_COUNT     = 32'h0018;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_MERGED_RECORD_COUNT      = 32'h001C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DROPPED_SUPERSEDED_COUNT = 32'h0020;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_VALUE_RECORD_COUNT       = 32'h0024;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_DELETE_RECORD_COUNT      = 32'h0028;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_USER_KEY_BYTES_TOTAL     = 32'h002C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_VALUE_BYTES_TOTAL        = 32'h0030;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_LAST_USER_KEY_LEN        = 32'h0034;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_LAST_SEQUENCE_LO         = 32'h0038;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_LAST_SEQUENCE_HI         = 32'h003C;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_LAST_RECORD_FLAGS        = 32'h0040;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_BYTES_READ               = 32'h0044;
    localparam [AXIL_ADDR_WIDTH-1:0] REG_BEATS_READ               = 32'h0048;

    reg [31:0] r_ctrl;
    reg [31:0] r_status;
    reg [63:0] r_src_base;
    reg [31:0] r_src_size;

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

    wire start_pulse_ui = start_toggle_ui_ff3 ^ start_toggle_ui_ff2;
    wire clear_pulse_ui = clear_toggle_ui_ff3 ^ clear_toggle_ui_ff2;

    wire        merge_busy_ui;
    wire        merge_done_ui;
    wire        merge_error_ui;
    wire        merge_record_valid_ui;
    wire        merge_record_keep_ui;
    wire [31:0] merge_header_record_count_ui;
    wire [31:0] merge_decoded_record_count_ui;
    wire [31:0] merge_merged_record_count_ui;
    wire [31:0] merge_dropped_superseded_count_ui;
    wire [31:0] merge_value_record_count_ui;
    wire [31:0] merge_delete_record_count_ui;
    wire [31:0] merge_user_key_bytes_total_ui;
    wire [31:0] merge_value_bytes_total_ui;
    wire [15:0] merge_last_user_key_len_ui;
    wire [55:0] merge_last_sequence_ui;
    wire [7:0]  merge_last_value_type_ui;
    wire        merge_last_record_keep_ui;
    wire [31:0] merge_bytes_read_ui;
    wire [31:0] merge_beats_read_ui;

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
    reg [31:0] header_record_count_axil_ff1;
    reg [31:0] header_record_count_axil_ff2;
    reg [31:0] decoded_record_count_axil_ff1;
    reg [31:0] decoded_record_count_axil_ff2;
    reg [31:0] merged_record_count_axil_ff1;
    reg [31:0] merged_record_count_axil_ff2;
    reg [31:0] dropped_superseded_count_axil_ff1;
    reg [31:0] dropped_superseded_count_axil_ff2;
    reg [31:0] value_record_count_axil_ff1;
    reg [31:0] value_record_count_axil_ff2;
    reg [31:0] delete_record_count_axil_ff1;
    reg [31:0] delete_record_count_axil_ff2;
    reg [31:0] user_key_bytes_total_axil_ff1;
    reg [31:0] user_key_bytes_total_axil_ff2;
    reg [31:0] value_bytes_total_axil_ff1;
    reg [31:0] value_bytes_total_axil_ff2;
    reg [15:0] last_user_key_len_axil_ff1;
    reg [15:0] last_user_key_len_axil_ff2;
    reg [55:0] last_sequence_axil_ff1;
    reg [55:0] last_sequence_axil_ff2;
    reg [7:0]  last_value_type_axil_ff1;
    reg [7:0]  last_value_type_axil_ff2;
    reg        last_record_keep_axil_ff1;
    reg        last_record_keep_axil_ff2;
    reg [31:0] bytes_read_axil_ff1;
    reg [31:0] bytes_read_axil_ff2;
    reg [31:0] beats_read_axil_ff1;
    reg [31:0] beats_read_axil_ff2;

    wire [AXI_ADDR_WIDTH-1:0] m_axi_araddr_i;
    wire [7:0]                m_axi_arlen_i;
    wire [2:0]                m_axi_arsize_i;
    wire [1:0]                m_axi_arburst_i;
    wire                      m_axi_arvalid_i;
    wire                      m_axi_rready_i;

    assign m_axi_araddr  = m_axi_araddr_i;
    assign m_axi_arlen   = m_axi_arlen_i;
    assign m_axi_arsize  = m_axi_arsize_i;
    assign m_axi_arburst = m_axi_arburst_i;
    assign m_axi_arvalid = m_axi_arvalid_i;
    assign m_axi_rready  = m_axi_rready_i;

    assign m_axi_awaddr  = {AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_awlen   = 8'd0;
    assign m_axi_awsize  = 3'd0;
    assign m_axi_awburst = 2'd0;
    assign m_axi_awvalid = 1'b0;
    assign m_axi_wdata   = {AXI_DATA_WIDTH{1'b0}};
    assign m_axi_wstrb   = {AXI_STRB_WIDTH{1'b0}};
    assign m_axi_wlast   = 1'b0;
    assign m_axi_wvalid  = 1'b0;
    assign m_axi_bready  = 1'b0;

    assign done       = done_ui_latched;
    assign busy       = merge_busy_ui;
    assign error      = error_ui_latched;
    assign bytes_done = merge_bytes_read_ui;
    assign blocks_done = merge_decoded_record_count_ui;

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
                    REG_CTRL:                     s_axil_rdata <= r_ctrl;
                    REG_STATUS:                   s_axil_rdata <= r_status;
                    REG_SRC_BASE_LO:              s_axil_rdata <= r_src_base[31:0];
                    REG_SRC_BASE_HI:              s_axil_rdata <= r_src_base[63:32];
                    REG_SRC_SIZE:                 s_axil_rdata <= r_src_size;
                    REG_HEADER_RECORD_COUNT:      s_axil_rdata <= header_record_count_axil_ff2;
                    REG_DECODED_RECORD_COUNT:     s_axil_rdata <= decoded_record_count_axil_ff2;
                    REG_MERGED_RECORD_COUNT:      s_axil_rdata <= merged_record_count_axil_ff2;
                    REG_DROPPED_SUPERSEDED_COUNT: s_axil_rdata <= dropped_superseded_count_axil_ff2;
                    REG_VALUE_RECORD_COUNT:       s_axil_rdata <= value_record_count_axil_ff2;
                    REG_DELETE_RECORD_COUNT:      s_axil_rdata <= delete_record_count_axil_ff2;
                    REG_USER_KEY_BYTES_TOTAL:     s_axil_rdata <= user_key_bytes_total_axil_ff2;
                    REG_VALUE_BYTES_TOTAL:        s_axil_rdata <= value_bytes_total_axil_ff2;
                    REG_LAST_USER_KEY_LEN:        s_axil_rdata <= {16'h0, last_user_key_len_axil_ff2};
                    REG_LAST_SEQUENCE_LO:         s_axil_rdata <= last_sequence_axil_ff2[31:0];
                    REG_LAST_SEQUENCE_HI:         s_axil_rdata <= {8'h0, last_sequence_axil_ff2[55:32]};
                    REG_LAST_RECORD_FLAGS:        s_axil_rdata <= {23'h0, last_record_keep_axil_ff2, last_value_type_axil_ff2};
                    REG_BYTES_READ:               s_axil_rdata <= bytes_read_axil_ff2;
                    REG_BEATS_READ:               s_axil_rdata <= beats_read_axil_ff2;
                    default:                      s_axil_rdata <= 32'h0;
                endcase
            end else if (r_hs) begin
                s_axil_rvalid <= 1'b0;
            end
        end
    end

    always @(posedge axil_aclk) begin
        if (!axil_aresetn) begin
            r_ctrl <= 32'h0;
            r_status <= 32'h0;
            r_src_base <= 64'h0;
            r_src_size <= 32'h0;
            ctrl_start_d <= 1'b0;
            ctrl_clear_d <= 1'b0;
            start_toggle_axil <= 1'b0;
            clear_toggle_axil <= 1'b0;
            cfg_src_base_axil <= 64'h0;
            cfg_src_size_axil <= 32'h0;
            busy_axil_ff1 <= 1'b0;
            busy_axil_ff2 <= 1'b0;
            header_record_count_axil_ff1 <= 32'h0;
            header_record_count_axil_ff2 <= 32'h0;
            decoded_record_count_axil_ff1 <= 32'h0;
            decoded_record_count_axil_ff2 <= 32'h0;
            merged_record_count_axil_ff1 <= 32'h0;
            merged_record_count_axil_ff2 <= 32'h0;
            dropped_superseded_count_axil_ff1 <= 32'h0;
            dropped_superseded_count_axil_ff2 <= 32'h0;
            value_record_count_axil_ff1 <= 32'h0;
            value_record_count_axil_ff2 <= 32'h0;
            delete_record_count_axil_ff1 <= 32'h0;
            delete_record_count_axil_ff2 <= 32'h0;
            user_key_bytes_total_axil_ff1 <= 32'h0;
            user_key_bytes_total_axil_ff2 <= 32'h0;
            value_bytes_total_axil_ff1 <= 32'h0;
            value_bytes_total_axil_ff2 <= 32'h0;
            last_user_key_len_axil_ff1 <= 16'h0;
            last_user_key_len_axil_ff2 <= 16'h0;
            last_sequence_axil_ff1 <= 56'h0;
            last_sequence_axil_ff2 <= 56'h0;
            last_value_type_axil_ff1 <= 8'h0;
            last_value_type_axil_ff2 <= 8'h0;
            last_record_keep_axil_ff1 <= 1'b0;
            last_record_keep_axil_ff2 <= 1'b0;
            bytes_read_axil_ff1 <= 32'h0;
            bytes_read_axil_ff2 <= 32'h0;
            beats_read_axil_ff1 <= 32'h0;
            beats_read_axil_ff2 <= 32'h0;
        end else begin
            ctrl_start_d <= r_ctrl[0];
            ctrl_clear_d <= r_ctrl[1];

            busy_axil_ff1 <= merge_busy_ui;
            busy_axil_ff2 <= busy_axil_ff1;
            header_record_count_axil_ff1 <= merge_header_record_count_ui;
            header_record_count_axil_ff2 <= header_record_count_axil_ff1;
            decoded_record_count_axil_ff1 <= merge_decoded_record_count_ui;
            decoded_record_count_axil_ff2 <= decoded_record_count_axil_ff1;
            merged_record_count_axil_ff1 <= merge_merged_record_count_ui;
            merged_record_count_axil_ff2 <= merged_record_count_axil_ff1;
            dropped_superseded_count_axil_ff1 <= merge_dropped_superseded_count_ui;
            dropped_superseded_count_axil_ff2 <= dropped_superseded_count_axil_ff1;
            value_record_count_axil_ff1 <= merge_value_record_count_ui;
            value_record_count_axil_ff2 <= value_record_count_axil_ff1;
            delete_record_count_axil_ff1 <= merge_delete_record_count_ui;
            delete_record_count_axil_ff2 <= delete_record_count_axil_ff1;
            user_key_bytes_total_axil_ff1 <= merge_user_key_bytes_total_ui;
            user_key_bytes_total_axil_ff2 <= user_key_bytes_total_axil_ff1;
            value_bytes_total_axil_ff1 <= merge_value_bytes_total_ui;
            value_bytes_total_axil_ff2 <= value_bytes_total_axil_ff1;
            last_user_key_len_axil_ff1 <= merge_last_user_key_len_ui;
            last_user_key_len_axil_ff2 <= last_user_key_len_axil_ff1;
            last_sequence_axil_ff1 <= merge_last_sequence_ui;
            last_sequence_axil_ff2 <= last_sequence_axil_ff1;
            last_value_type_axil_ff1 <= merge_last_value_type_ui;
            last_value_type_axil_ff2 <= last_value_type_axil_ff1;
            last_record_keep_axil_ff1 <= merge_last_record_keep_ui;
            last_record_keep_axil_ff2 <= last_record_keep_axil_ff1;
            bytes_read_axil_ff1 <= merge_bytes_read_ui;
            bytes_read_axil_ff2 <= bytes_read_axil_ff1;
            beats_read_axil_ff1 <= merge_beats_read_ui;
            beats_read_axil_ff2 <= beats_read_axil_ff1;

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
                    default: begin
                    end
                endcase
            end

            if (ctrl_start_pulse) begin
                r_ctrl[0] <= 1'b0;
                r_status[1] <= 1'b0;
                r_status[2] <= 1'b0;
                cfg_src_base_axil <= r_src_base;
                cfg_src_size_axil <= r_src_size;
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

            if (start_pulse_ui || clear_pulse_ui) begin
                done_ui_latched <= 1'b0;
                error_ui_latched <= 1'b0;
            end

            done_ui_d <= merge_done_ui;
            error_ui_d <= merge_error_ui;
            if (merge_done_ui && !done_ui_d) begin
                done_toggle_ui <= ~done_toggle_ui;
                done_ui_latched <= 1'b1;
            end
            if (merge_error_ui && !error_ui_d) begin
                error_toggle_ui <= ~error_toggle_ui;
                error_ui_latched <= 1'b1;
            end

            dbg_last_accum <= {
                {(AXI_DATA_WIDTH-448){1'b0}},
                {23'h0, merge_last_record_keep_ui, merge_last_value_type_ui},
                {8'h0, merge_last_sequence_ui[55:32]},
                merge_last_sequence_ui[31:0],
                {16'h0, merge_last_user_key_len_ui},
                merge_beats_read_ui,
                merge_bytes_read_ui,
                merge_value_bytes_total_ui,
                merge_user_key_bytes_total_ui,
                merge_delete_record_count_ui,
                merge_value_record_count_ui,
                merge_dropped_superseded_count_ui,
                merge_merged_record_count_ui,
                merge_decoded_record_count_ui,
                merge_header_record_count_ui
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

    stage3_internal_key_merge_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .MAX_USER_KEY_BYTES(MAX_USER_KEY_BYTES)
    ) u_stage3_internal_key_merge_top (
        .clk(ui_aclk),
        .rstn(ui_aresetn),
        .clear(clear_pulse_ui),
        .start(start_pulse_ui),
        .src_base_addr(cfg_src_base_ui_ff2),
        .byte_count(cfg_src_size_ui_ff2),
        .busy(merge_busy_ui),
        .done(merge_done_ui),
        .error(merge_error_ui),
        .bytes_read(merge_bytes_read_ui),
        .beats_read(merge_beats_read_ui),
        .record_valid(merge_record_valid_ui),
        .record_keep(merge_record_keep_ui),
        .header_record_count(merge_header_record_count_ui),
        .decoded_record_count(merge_decoded_record_count_ui),
        .merged_record_count(merge_merged_record_count_ui),
        .dropped_superseded_count(merge_dropped_superseded_count_ui),
        .value_record_count(merge_value_record_count_ui),
        .delete_record_count(merge_delete_record_count_ui),
        .user_key_bytes_total(merge_user_key_bytes_total_ui),
        .value_bytes_total(merge_value_bytes_total_ui),
        .last_user_key_len(merge_last_user_key_len_ui),
        .last_sequence(merge_last_sequence_ui),
        .last_value_type(merge_last_value_type_ui),
        .last_record_keep(merge_last_record_keep_ui),
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
        .m_axi_rready(m_axi_rready_i)
    );

endmodule
