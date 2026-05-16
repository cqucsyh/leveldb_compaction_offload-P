`timescale 1ns / 1ps
// tb_sstable_asym
//
// Regression for asymmetric block-pair handling.
// SRC0: 2 data blocks   SRC1: 4 data blocks
//
// Expected behaviour after asymmetric fix (max instead of min):
//   Pair 0: merge src0.block0 [key_0000..0003] + src1.block0 [key_0004..0006]  kept=7
//   Pair 1: merge src0.block1 [key_0010..0013] + src1.block1 [key_0014..0016]  kept=7
//   Pair 2: src0=EMPTY, pass-through src1.block2 [key_0020..0022]  kept=3
//   Pair 3: src0=EMPTY, pass-through src1.block3 [key_0030..0032]  kept=3
//
// No cross-source duplicate keys → all 20 records kept.
//
// Counter expectations:
//   block_pair_count = 4
//   src0_decoded     = 8   (4+4+0+0)
//   src1_decoded     = 12  (3+3+3+3)
//   merge_decoded    = 20
//   merge_merged     = 20
//   merge_dropped    = 0
//   stage5_input     = 20
//   stage5_encoded   = 20
//   dst_output_bytes[0..3]  all > 0

module tb_sstable_asym;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer AXI_STRB_WIDTH = 64;
    localparam integer MEM_SRC        = 32768;   // 32 KB  SRC0@0x0000 + SRC1@0x4000
    localparam integer MEM_CHAIN      = 65536;   // 64 KB  DST@0x8000  + MID@0xC000

    localparam [63:0] SRC0_BASE  = 64'h0000_0000_0000_0000;
    localparam [31:0] SRC0_SIZE  = 32'd362;   // 2-block SSTable
    localparam [63:0] SRC1_BASE  = 64'h0000_0000_0000_4000;
    localparam [31:0] SRC1_SIZE  = 32'd568;   // 4-block SSTable
    localparam [63:0] DST_BASE   = 64'h0000_0000_0000_8000;
    localparam [31:0] DST_STRIDE = 32'h0000_1000;
    localparam [63:0] MID_BASE   = 64'h0000_0000_0000_C000;

    // AXI-Lite register map
    localparam [31:0] A_CTRL       = 32'h0000;
    localparam [31:0] A_STATUS     = 32'h0004;
    localparam [31:0] A_SRC0_LO   = 32'h0008;
    localparam [31:0] A_SRC0_HI   = 32'h000C;
    localparam [31:0] A_SRC0_SIZE = 32'h0010;
    localparam [31:0] A_SRC1_LO   = 32'h0014;
    localparam [31:0] A_SRC1_HI   = 32'h0018;
    localparam [31:0] A_SRC1_SIZE = 32'h001C;
    localparam [31:0] A_DST_LO    = 32'h0020;
    localparam [31:0] A_DST_HI    = 32'h0024;
    localparam [31:0] A_DST_STRIDE= 32'h0028;
    localparam [31:0] A_MID_LO    = 32'h002C;
    localparam [31:0] A_MID_HI    = 32'h0030;
    localparam [31:0] A_PAIR_COUNT= 32'h0034;
    localparam [31:0] A_SRC0_DEC  = 32'h0040;
    localparam [31:0] A_SRC1_DEC  = 32'h0044;
    localparam [31:0] A_SRC0_BYTES= 32'h0048;
    localparam [31:0] A_SRC1_BYTES= 32'h004C;
    localparam [31:0] A_MRG_OUT_B = 32'h0050;
    localparam [31:0] A_MRG_DEC   = 32'h0054;
    localparam [31:0] A_MRG_MRG   = 32'h0058;
    localparam [31:0] A_MRG_DRP   = 32'h005C;
    localparam [31:0] A_S5_INPUT  = 32'h0060;
    localparam [31:0] A_S5_ENC    = 32'h0064;
    localparam [31:0] A_S5_OUT_B  = 32'h0068;
    localparam [31:0] A_S5_WRITTEN= 32'h006C;
    localparam [31:0] A_DST_B0    = 32'h0100;
    localparam [31:0] A_DST_B1    = 32'h0104;
    localparam [31:0] A_DST_B2    = 32'h0108;
    localparam [31:0] A_DST_B3    = 32'h010C;

    // -----------------------------------------------------------------------
    // Clock / reset
    // -----------------------------------------------------------------------
    reg clk  = 0;
    reg rstn = 0;
    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // AXI-Lite signals
    // -----------------------------------------------------------------------
    reg  [31:0] s_axil_awaddr  = 0; reg  s_axil_awvalid = 0; wire s_axil_awready;
    reg  [31:0] s_axil_wdata   = 0; reg  [3:0] s_axil_wstrb = 0;
    reg         s_axil_wvalid  = 0; wire s_axil_wready;
    wire [1:0]  s_axil_bresp;       wire s_axil_bvalid; reg  s_axil_bready = 0;
    reg  [31:0] s_axil_araddr  = 0; reg  s_axil_arvalid = 0; wire s_axil_arready;
    wire [31:0] s_axil_rdata;       wire [1:0] s_axil_rresp;
    wire        s_axil_rvalid;      reg  s_axil_rready = 0;

    // -----------------------------------------------------------------------
    // AXI master wires (5 ports)
    // -----------------------------------------------------------------------
    wire [AXI_ADDR_WIDTH-1:0] p0_araddr; wire [7:0] p0_arlen; wire [2:0] p0_arsize;
    wire [1:0] p0_arburst; wire p0_arvalid, p0_arready;
    wire [AXI_DATA_WIDTH-1:0] p0_rdata; wire [1:0] p0_rresp;
    wire p0_rlast, p0_rvalid, p0_rready;

    wire [AXI_ADDR_WIDTH-1:0] p1_araddr; wire [7:0] p1_arlen; wire [2:0] p1_arsize;
    wire [1:0] p1_arburst; wire p1_arvalid, p1_arready;
    wire [AXI_DATA_WIDTH-1:0] p1_rdata; wire [1:0] p1_rresp;
    wire p1_rlast, p1_rvalid, p1_rready;

    wire [AXI_ADDR_WIDTH-1:0] s0_araddr; wire [7:0] s0_arlen; wire [2:0] s0_arsize;
    wire [1:0] s0_arburst; wire s0_arvalid, s0_arready;
    wire [AXI_DATA_WIDTH-1:0] s0_rdata; wire [1:0] s0_rresp;
    wire s0_rlast, s0_rvalid, s0_rready;

    wire [AXI_ADDR_WIDTH-1:0] s1_araddr; wire [7:0] s1_arlen; wire [2:0] s1_arsize;
    wire [1:0] s1_arburst; wire s1_arvalid, s1_arready;
    wire [AXI_DATA_WIDTH-1:0] s1_rdata; wire [1:0] s1_rresp;
    wire s1_rlast, s1_rvalid, s1_rready;

    wire [AXI_ADDR_WIDTH-1:0] ch_araddr; wire [7:0] ch_arlen; wire [2:0] ch_arsize;
    wire [1:0] ch_arburst; wire ch_arvalid, ch_arready;
    wire [AXI_DATA_WIDTH-1:0] ch_rdata; wire [1:0] ch_rresp;
    wire ch_rlast, ch_rvalid, ch_rready;
    wire [AXI_ADDR_WIDTH-1:0] ch_awaddr; wire [7:0] ch_awlen; wire [2:0] ch_awsize;
    wire [1:0] ch_awburst; wire ch_awvalid, ch_awready;
    wire [AXI_DATA_WIDTH-1:0] ch_wdata; wire [AXI_STRB_WIDTH-1:0] ch_wstrb;
    wire ch_wlast, ch_wvalid, ch_wready;
    wire [1:0] ch_bresp; wire ch_bvalid, ch_bready;

    wire dut_done, dut_busy, dut_error;
    wire [31:0] dut_blocks_done, dut_bytes_done;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    cmpct_top #(
        .AXIL_ADDR_WIDTH(32), .AXIL_DATA_WIDTH(32),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_STRB_WIDTH(AXI_STRB_WIDTH),
        .MAX_BURST_LEN(16), .MAX_INDEX_BYTES(8192), .MAX_BLOCK_PAIRS(8),
        .STAGE4_MAX_BLOCK_BYTES(4096), .STAGE4_MAX_KEY_BYTES(264),
        .MERGE_MAX_USER_KEY_BYTES(256), .MERGE_MAX_KEY_BYTES(264),
        .MERGE_MAX_VALUE_BYTES(1024),   .MERGE_MAX_RECORD_BYTES(2048),
        .MERGE_MAX_RECORDS(256),        .MERGE_MAX_OUTPUT_BYTES(73728),
        .STAGE5_MAX_RECORDS(256),       .STAGE5_MAX_PAYLOAD_BYTES(4096),
        .STAGE5_MAX_BLOCK_BYTES(4096),  .STAGE5_MAX_KEY_BYTES(256),
        .STAGE5_MAX_VALUE_BYTES(1024),  .STAGE5_RESTART_INTERVAL(16)
    ) dut (
        .axil_aclk(clk), .axil_aresetn(rstn),
        .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid),
        .s_axil_awready(s_axil_awready), .s_axil_wdata(s_axil_wdata),
        .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid),
        .s_axil_wready(s_axil_wready), .s_axil_bresp(s_axil_bresp),
        .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready), .s_axil_rdata(s_axil_rdata),
        .s_axil_rresp(s_axil_rresp), .s_axil_rvalid(s_axil_rvalid),
        .s_axil_rready(s_axil_rready),
        .ui_aclk(clk), .ui_aresetn(rstn),
        .m_axi_p0_araddr(p0_araddr),   .m_axi_p0_arlen(p0_arlen),
        .m_axi_p0_arsize(p0_arsize),   .m_axi_p0_arburst(p0_arburst),
        .m_axi_p0_arvalid(p0_arvalid), .m_axi_p0_arready(p0_arready),
        .m_axi_p0_rdata(p0_rdata),     .m_axi_p0_rresp(p0_rresp),
        .m_axi_p0_rlast(p0_rlast),     .m_axi_p0_rvalid(p0_rvalid),
        .m_axi_p0_rready(p0_rready),
        .m_axi_p1_araddr(p1_araddr),   .m_axi_p1_arlen(p1_arlen),
        .m_axi_p1_arsize(p1_arsize),   .m_axi_p1_arburst(p1_arburst),
        .m_axi_p1_arvalid(p1_arvalid), .m_axi_p1_arready(p1_arready),
        .m_axi_p1_rdata(p1_rdata),     .m_axi_p1_rresp(p1_rresp),
        .m_axi_p1_rlast(p1_rlast),     .m_axi_p1_rvalid(p1_rvalid),
        .m_axi_p1_rready(p1_rready),
        .m_axi_src0_araddr(s0_araddr),  .m_axi_src0_arlen(s0_arlen),
        .m_axi_src0_arsize(s0_arsize),  .m_axi_src0_arburst(s0_arburst),
        .m_axi_src0_arvalid(s0_arvalid),.m_axi_src0_arready(s0_arready),
        .m_axi_src0_rdata(s0_rdata),    .m_axi_src0_rresp(s0_rresp),
        .m_axi_src0_rlast(s0_rlast),    .m_axi_src0_rvalid(s0_rvalid),
        .m_axi_src0_rready(s0_rready),
        .m_axi_src1_araddr(s1_araddr),  .m_axi_src1_arlen(s1_arlen),
        .m_axi_src1_arsize(s1_arsize),  .m_axi_src1_arburst(s1_arburst),
        .m_axi_src1_arvalid(s1_arvalid),.m_axi_src1_arready(s1_arready),
        .m_axi_src1_rdata(s1_rdata),    .m_axi_src1_rresp(s1_rresp),
        .m_axi_src1_rlast(s1_rlast),    .m_axi_src1_rvalid(s1_rvalid),
        .m_axi_src1_rready(s1_rready),
        .m_axi_chain_araddr(ch_araddr), .m_axi_chain_arlen(ch_arlen),
        .m_axi_chain_arsize(ch_arsize), .m_axi_chain_arburst(ch_arburst),
        .m_axi_chain_arvalid(ch_arvalid),.m_axi_chain_arready(ch_arready),
        .m_axi_chain_rdata(ch_rdata),   .m_axi_chain_rresp(ch_rresp),
        .m_axi_chain_rlast(ch_rlast),   .m_axi_chain_rvalid(ch_rvalid),
        .m_axi_chain_rready(ch_rready),
        .m_axi_chain_awaddr(ch_awaddr), .m_axi_chain_awlen(ch_awlen),
        .m_axi_chain_awsize(ch_awsize), .m_axi_chain_awburst(ch_awburst),
        .m_axi_chain_awvalid(ch_awvalid),.m_axi_chain_awready(ch_awready),
        .m_axi_chain_wdata(ch_wdata),   .m_axi_chain_wstrb(ch_wstrb),
        .m_axi_chain_wlast(ch_wlast),   .m_axi_chain_wvalid(ch_wvalid),
        .m_axi_chain_wready(ch_wready),
        .m_axi_chain_bresp(ch_bresp),   .m_axi_chain_bvalid(ch_bvalid),
        .m_axi_chain_bready(ch_bready),
        .done(dut_done), .busy(dut_busy), .error(dut_error),
        .blocks_done(dut_blocks_done),   .bytes_done(dut_bytes_done)
    );

    // -----------------------------------------------------------------------
    // AXI RAM models
    // -----------------------------------------------------------------------
    axi_ram_model #(.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),.AXI_DATA_WIDTH(AXI_DATA_WIDTH),
                    .AXI_ID_WIDTH(1),.MEM_BYTES(MEM_SRC),.READ_LATENCY(2)) mem_p0 (
        .clk(clk),.rstn(rstn),
        .s_axi_araddr(p0_araddr),.s_axi_arlen(p0_arlen),.s_axi_arsize(p0_arsize),
        .s_axi_arburst(p0_arburst),.s_axi_arid(1'b0),.s_axi_arvalid(p0_arvalid),
        .s_axi_arready(p0_arready),.s_axi_rdata(p0_rdata),.s_axi_rresp(p0_rresp),
        .s_axi_rlast(p0_rlast),.s_axi_rid(),.s_axi_rvalid(p0_rvalid),.s_axi_rready(p0_rready),
        .s_axi_awaddr({AXI_ADDR_WIDTH{1'b0}}),.s_axi_awlen(8'd0),.s_axi_awsize(3'd0),
        .s_axi_awburst(2'd0),.s_axi_awid(1'b0),.s_axi_awvalid(1'b0),.s_axi_awready(),
        .s_axi_wdata({AXI_DATA_WIDTH{1'b0}}),.s_axi_wstrb({(AXI_DATA_WIDTH/8){1'b0}}),
        .s_axi_wlast(1'b0),.s_axi_wvalid(1'b0),.s_axi_wready(),
        .s_axi_bresp(),.s_axi_bid(),.s_axi_bvalid(),.s_axi_bready(1'b0));

    axi_ram_model #(.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),.AXI_DATA_WIDTH(AXI_DATA_WIDTH),
                    .AXI_ID_WIDTH(1),.MEM_BYTES(MEM_SRC),.READ_LATENCY(2)) mem_p1 (
        .clk(clk),.rstn(rstn),
        .s_axi_araddr(p1_araddr),.s_axi_arlen(p1_arlen),.s_axi_arsize(p1_arsize),
        .s_axi_arburst(p1_arburst),.s_axi_arid(1'b0),.s_axi_arvalid(p1_arvalid),
        .s_axi_arready(p1_arready),.s_axi_rdata(p1_rdata),.s_axi_rresp(p1_rresp),
        .s_axi_rlast(p1_rlast),.s_axi_rid(),.s_axi_rvalid(p1_rvalid),.s_axi_rready(p1_rready),
        .s_axi_awaddr({AXI_ADDR_WIDTH{1'b0}}),.s_axi_awlen(8'd0),.s_axi_awsize(3'd0),
        .s_axi_awburst(2'd0),.s_axi_awid(1'b0),.s_axi_awvalid(1'b0),.s_axi_awready(),
        .s_axi_wdata({AXI_DATA_WIDTH{1'b0}}),.s_axi_wstrb({(AXI_DATA_WIDTH/8){1'b0}}),
        .s_axi_wlast(1'b0),.s_axi_wvalid(1'b0),.s_axi_wready(),
        .s_axi_bresp(),.s_axi_bid(),.s_axi_bvalid(),.s_axi_bready(1'b0));

    axi_ram_model #(.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),.AXI_DATA_WIDTH(AXI_DATA_WIDTH),
                    .AXI_ID_WIDTH(1),.MEM_BYTES(MEM_SRC),.READ_LATENCY(2)) mem_src0 (
        .clk(clk),.rstn(rstn),
        .s_axi_araddr(s0_araddr),.s_axi_arlen(s0_arlen),.s_axi_arsize(s0_arsize),
        .s_axi_arburst(s0_arburst),.s_axi_arid(1'b0),.s_axi_arvalid(s0_arvalid),
        .s_axi_arready(s0_arready),.s_axi_rdata(s0_rdata),.s_axi_rresp(s0_rresp),
        .s_axi_rlast(s0_rlast),.s_axi_rid(),.s_axi_rvalid(s0_rvalid),.s_axi_rready(s0_rready),
        .s_axi_awaddr({AXI_ADDR_WIDTH{1'b0}}),.s_axi_awlen(8'd0),.s_axi_awsize(3'd0),
        .s_axi_awburst(2'd0),.s_axi_awid(1'b0),.s_axi_awvalid(1'b0),.s_axi_awready(),
        .s_axi_wdata({AXI_DATA_WIDTH{1'b0}}),.s_axi_wstrb({(AXI_DATA_WIDTH/8){1'b0}}),
        .s_axi_wlast(1'b0),.s_axi_wvalid(1'b0),.s_axi_wready(),
        .s_axi_bresp(),.s_axi_bid(),.s_axi_bvalid(),.s_axi_bready(1'b0));

    axi_ram_model #(.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),.AXI_DATA_WIDTH(AXI_DATA_WIDTH),
                    .AXI_ID_WIDTH(1),.MEM_BYTES(MEM_SRC),.READ_LATENCY(2)) mem_src1 (
        .clk(clk),.rstn(rstn),
        .s_axi_araddr(s1_araddr),.s_axi_arlen(s1_arlen),.s_axi_arsize(s1_arsize),
        .s_axi_arburst(s1_arburst),.s_axi_arid(1'b0),.s_axi_arvalid(s1_arvalid),
        .s_axi_arready(s1_arready),.s_axi_rdata(s1_rdata),.s_axi_rresp(s1_rresp),
        .s_axi_rlast(s1_rlast),.s_axi_rid(),.s_axi_rvalid(s1_rvalid),.s_axi_rready(s1_rready),
        .s_axi_awaddr({AXI_ADDR_WIDTH{1'b0}}),.s_axi_awlen(8'd0),.s_axi_awsize(3'd0),
        .s_axi_awburst(2'd0),.s_axi_awid(1'b0),.s_axi_awvalid(1'b0),.s_axi_awready(),
        .s_axi_wdata({AXI_DATA_WIDTH{1'b0}}),.s_axi_wstrb({(AXI_DATA_WIDTH/8){1'b0}}),
        .s_axi_wlast(1'b0),.s_axi_wvalid(1'b0),.s_axi_wready(),
        .s_axi_bresp(),.s_axi_bid(),.s_axi_bvalid(),.s_axi_bready(1'b0));

    axi_ram_model #(.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),.AXI_DATA_WIDTH(AXI_DATA_WIDTH),
                    .AXI_ID_WIDTH(1),.MEM_BYTES(MEM_CHAIN),.READ_LATENCY(2)) mem_chain (
        .clk(clk),.rstn(rstn),
        .s_axi_araddr(ch_araddr),.s_axi_arlen(ch_arlen),.s_axi_arsize(ch_arsize),
        .s_axi_arburst(ch_arburst),.s_axi_arid(1'b0),.s_axi_arvalid(ch_arvalid),
        .s_axi_arready(ch_arready),.s_axi_rdata(ch_rdata),.s_axi_rresp(ch_rresp),
        .s_axi_rlast(ch_rlast),.s_axi_rid(),.s_axi_rvalid(ch_rvalid),.s_axi_rready(ch_rready),
        .s_axi_awaddr(ch_awaddr),.s_axi_awlen(ch_awlen),.s_axi_awsize(ch_awsize),
        .s_axi_awburst(ch_awburst),.s_axi_awid(1'b0),.s_axi_awvalid(ch_awvalid),
        .s_axi_awready(ch_awready),.s_axi_wdata(ch_wdata),.s_axi_wstrb(ch_wstrb),
        .s_axi_wlast(ch_wlast),.s_axi_wvalid(ch_wvalid),.s_axi_wready(ch_wready),
        .s_axi_bresp(ch_bresp),.s_axi_bid(),.s_axi_bvalid(ch_bvalid),.s_axi_bready(ch_bready));

    // -----------------------------------------------------------------------
    // AXI-Lite BFM tasks
    // -----------------------------------------------------------------------
    reg [31:0] rd_data;
    integer    t;

    task axil_write;
        input [31:0] waddr;
        input [31:0] wdata;
        begin
            @(posedge clk); #1;
            s_axil_awaddr  = waddr;
            s_axil_awvalid = 1;
            @(posedge clk);
            while (!s_axil_awready) @(posedge clk);
            #1; s_axil_awvalid = 0;
            s_axil_wdata  = wdata;
            s_axil_wstrb  = 4'hF;
            s_axil_wvalid = 1;
            @(posedge clk);
            while (!s_axil_wready) @(posedge clk);
            #1; s_axil_wvalid = 0;
            s_axil_bready = 1;
            @(posedge clk);
            while (!s_axil_bvalid) @(posedge clk);
            #1; s_axil_bready = 0;
        end
    endtask

    task axil_read;
        input  [31:0] raddr;
        output [31:0] rdata;
        begin
            @(posedge clk); #1;
            s_axil_araddr  = raddr;
            s_axil_arvalid = 1;
            @(posedge clk);
            while (!s_axil_arready) @(posedge clk);
            #1; s_axil_arvalid = 0;
            s_axil_rready = 1;
            @(posedge clk);
            while (!s_axil_rvalid) @(posedge clk);
            rdata = s_axil_rdata;
            #1; s_axil_rready = 0;
        end
    endtask

    task chk;
        input [31:0]  got;
        input [31:0]  exp;
        input [255:0] label;
        begin
            if (got !== exp) begin
                $display("FAIL %0s: got=%0d exp=%0d", label, got, exp);
                $finish_and_return(1);
            end else
                $display("PASS %0s = %0d", label, got);
        end
    endtask

    task chk_gt0;
        input [31:0]  got;
        input [255:0] label;
        begin
            if (got == 0) begin
                $display("FAIL %0s: got=0, expected > 0", label);
                $finish_and_return(1);
            end else
                $display("PASS %0s = %0d", label, got);
        end
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    integer i;

    initial begin
        // Init chain memory sentinel
        for (i = 0; i < MEM_CHAIN; i = i + 1)
            mem_chain.mem[i] = 8'hA5;

        // Load asymmetric SSTable fixtures
        $readmemh("fixtures/src0_asym_real.memh", mem_p0.mem);
        $readmemh("fixtures/src0_asym_real.memh", mem_src0.mem);
        $readmemh("fixtures/src1_asym_real.memh", mem_p1.mem);
        $readmemh("fixtures/src1_asym_real.memh", mem_src1.mem);

        // Reset
        repeat(5) @(posedge clk);
        rstn = 1;
        repeat(10) @(posedge clk);

        $display("=== [ASYM] Configuring AXI-Lite registers ===");
        axil_write(A_SRC0_LO,    SRC0_BASE[31:0]);
        axil_write(A_SRC0_HI,    SRC0_BASE[63:32]);
        axil_write(A_SRC0_SIZE,  SRC0_SIZE);
        axil_write(A_SRC1_LO,    SRC1_BASE[31:0]);
        axil_write(A_SRC1_HI,    SRC1_BASE[63:32]);
        axil_write(A_SRC1_SIZE,  SRC1_SIZE);
        axil_write(A_DST_LO,     DST_BASE[31:0]);
        axil_write(A_DST_HI,     DST_BASE[63:32]);
        axil_write(A_DST_STRIDE, DST_STRIDE);
        axil_write(A_MID_LO,     MID_BASE[31:0]);
        axil_write(A_MID_HI,     MID_BASE[63:32]);

        $display("=== [ASYM] Starting engine (src0=2 blocks, src1=4 blocks) ===");
        axil_write(A_CTRL, 32'h1);
        axil_write(A_CTRL, 32'h0);

        $display("=== [ASYM] Waiting for completion ===");
        for (t = 0; t < 5000000; t = t + 1) begin
            @(posedge clk);
            if (dut_error) begin
                $display("FAIL: engine error at t=%0d", t);
                $display("  ts=%0d p0:%b/%b p1:%b/%b nb:%b/%b",
                    dut.u_engine.ts,
                    dut.u_engine.p0_busy, dut.u_engine.p0_done,
                    dut.u_engine.p1_busy, dut.u_engine.p1_done,
                    dut.u_engine.nb_busy, dut.u_engine.nb_done);
                $finish_and_return(1);
            end
            if (dut_done) begin
                $display("Engine done at cycle %0d", t);
                t = 5000001;
            end
        end
        if (t == 5000000) begin
            $display("TIMEOUT: busy=%b done=%b error=%b ts=%0d",
                dut_busy, dut_done, dut_error, dut.u_engine.ts);
            $display("  p0: busy=%b done=%b  p1: busy=%b done=%b",
                dut.u_engine.p0_busy, dut.u_engine.p0_done,
                dut.u_engine.p1_busy, dut.u_engine.p1_done);
            $display("  nb: busy=%b done=%b  nb_state=%0d  blk=%0d",
                dut.u_engine.nb_busy, dut.u_engine.nb_done,
                dut.u_engine.u_nblock.state,
                dut.u_engine.u_nblock.active_block_index);
            $finish_and_return(1);
        end

        $display("\n=== [ASYM] Reading counters ===");
        axil_read(A_PAIR_COUNT, rd_data); chk(rd_data, 32'd4,  "block_pair_count");
        axil_read(A_SRC0_DEC,  rd_data); chk(rd_data, 32'd8,  "src0_decoded");
        axil_read(A_SRC1_DEC,  rd_data); chk(rd_data, 32'd12, "src1_decoded");
        axil_read(A_MRG_DEC,   rd_data); chk(rd_data, 32'd20, "merge_decoded");
        axil_read(A_MRG_MRG,   rd_data); chk(rd_data, 32'd20, "merge_merged");
        axil_read(A_MRG_DRP,   rd_data); chk(rd_data, 32'd0,  "merge_dropped");
        axil_read(A_S5_INPUT,  rd_data); chk(rd_data, 32'd20, "stage5_input");
        axil_read(A_S5_ENC,    rd_data); chk(rd_data, 32'd20, "stage5_encoded");
        axil_read(A_S5_WRITTEN,rd_data); chk_gt0(rd_data,     "stage5_bytes_written");
        axil_read(A_DST_B0,    rd_data); chk_gt0(rd_data,     "dst_output_bytes[0]");
        axil_read(A_DST_B1,    rd_data); chk_gt0(rd_data,     "dst_output_bytes[1]");
        axil_read(A_DST_B2,    rd_data); chk_gt0(rd_data,     "dst_output_bytes[2] (asym pass-through)");
        axil_read(A_DST_B3,    rd_data); chk_gt0(rd_data,     "dst_output_bytes[3] (asym pass-through)");

        $display("\nPASS: asymmetric block-pair 4-block run completed successfully");
        $finish_and_return(0);
    end

    initial begin
        #100000000;
        $display("WATCHDOG TIMEOUT");
        $finish_and_return(1);
    end

endmodule
