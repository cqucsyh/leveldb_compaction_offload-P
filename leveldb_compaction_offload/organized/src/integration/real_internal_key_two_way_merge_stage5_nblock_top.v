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
