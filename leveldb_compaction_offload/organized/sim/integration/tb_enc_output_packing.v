`timescale 1ns / 1ps
// tb_enc_output_packing — Regression test for encoder output byte-packing fix.
//
// Verifies that the 32→8→32 repack pipeline correctly converts the encoder's
// variable-tkeep output into dense, hole-free data in DDR.
//
// Bug symptom (before fix):
//   Encoder emits 32-bit words with partial tkeep (e.g. 0001 for varint bytes).
//   Without repacking, DDR writes via WSTRB leave sentinel (0xA5) holes at
//   bytes where tkeep=0, producing a pattern like: 00 A5 A5 A5 10 A5 A5 A5 ...
//
// Checks:
//   1. No sentinel (0xA5) holes in the output SSTable region
//   2. Each data block has comp_type == 0x00 (no compression)
//   3. Each data block has a plausible restart_count (> 0)
//   4. First entry varint headers are decodable (shared=0 for first entry)
//   5. LevelDB footer magic present at the end of the SSTable
//   6. Standard counter checks

module tb_enc_output_packing;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer AXI_STRB_WIDTH = 64;
    localparam integer MEM_SRC        = 32768;
    localparam integer MEM_CHAIN      = 65536;

    localparam [63:0] SRC0_BASE  = 64'h0000_0000_0000_0000;
    localparam [31:0] SRC0_SIZE  = 32'd254;
    localparam [63:0] SRC1_BASE  = 64'h0000_0000_0000_4000;
    localparam [31:0] SRC1_SIZE  = 32'd254;
    localparam [63:0] DST_BASE   = 64'h0000_0000_0000_8000;
    localparam [31:0] DST_STRIDE = 32'h0000_1000;
    localparam [63:0] MID_BASE   = 64'h0000_0000_0000_C000;

    localparam [7:0] SENTINEL = 8'hA5;

    // Register addresses
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
    localparam [31:0] A_SST_COUNT = 32'h003C;
    localparam [31:0] A_SRC0_DEC  = 32'h0040;
    localparam [31:0] A_SRC1_DEC  = 32'h0044;
    localparam [31:0] A_MRG_DEC   = 32'h0054;
    localparam [31:0] A_MRG_MRG   = 32'h0058;
    localparam [31:0] A_MRG_DRP   = 32'h005C;
    localparam [31:0] A_S5_INPUT  = 32'h0060;
    localparam [31:0] A_S5_ENC    = 32'h0064;
    localparam [31:0] A_S5_WRITTEN= 32'h006C;
    localparam [31:0] A_DST_B0    = 32'h0100;
    localparam [31:0] A_SST_SIZE0 = 32'h0500;

    reg clk  = 0;
    reg rstn = 0;
    always #5 clk = ~clk;

    reg  [31:0] s_axil_awaddr  = 0;
    reg         s_axil_awvalid = 0;
    wire        s_axil_awready;
    reg  [31:0] s_axil_wdata   = 0;
    reg  [3:0]  s_axil_wstrb   = 0;
    reg         s_axil_wvalid  = 0;
    wire        s_axil_wready;
    wire [1:0]  s_axil_bresp;
    wire        s_axil_bvalid;
    reg         s_axil_bready  = 0;
    reg  [31:0] s_axil_araddr  = 0;
    reg         s_axil_arvalid = 0;
    wire        s_axil_arready;
    wire [31:0] s_axil_rdata;
    wire [1:0]  s_axil_rresp;
    wire        s_axil_rvalid;
    reg         s_axil_rready  = 0;

    // AXI master wires
    wire [AXI_ADDR_WIDTH-1:0] p0_araddr;  wire [7:0] p0_arlen;  wire [2:0] p0_arsize;
    wire [1:0] p0_arburst; wire p0_arvalid, p0_arready;
    wire [AXI_DATA_WIDTH-1:0] p0_rdata; wire [1:0] p0_rresp;
    wire p0_rlast, p0_rvalid, p0_rready;

    wire [AXI_ADDR_WIDTH-1:0] p1_araddr;  wire [7:0] p1_arlen;  wire [2:0] p1_arsize;
    wire [1:0] p1_arburst; wire p1_arvalid, p1_arready;
    wire [AXI_DATA_WIDTH-1:0] p1_rdata; wire [1:0] p1_rresp;
    wire p1_rlast, p1_rvalid, p1_rready;

    wire [AXI_ADDR_WIDTH-1:0] s0_araddr;  wire [7:0] s0_arlen;  wire [2:0] s0_arsize;
    wire [1:0] s0_arburst; wire s0_arvalid, s0_arready;
    wire [AXI_DATA_WIDTH-1:0] s0_rdata; wire [1:0] s0_rresp;
    wire s0_rlast, s0_rvalid, s0_rready;

    wire [AXI_ADDR_WIDTH-1:0] s1_araddr;  wire [7:0] s1_arlen;  wire [2:0] s1_arsize;
    wire [1:0] s1_arburst; wire s1_arvalid, s1_arready;
    wire [AXI_DATA_WIDTH-1:0] s1_rdata; wire [1:0] s1_rresp;
    wire s1_rlast, s1_rvalid, s1_rready;

    wire [AXI_ADDR_WIDTH-1:0] ch_araddr;  wire [7:0] ch_arlen;  wire [2:0] ch_arsize;
    wire [1:0] ch_arburst; wire ch_arvalid, ch_arready;
    wire [AXI_DATA_WIDTH-1:0] ch_rdata; wire [1:0] ch_rresp;
    wire ch_rlast, ch_rvalid, ch_rready;
    wire [AXI_ADDR_WIDTH-1:0] ch_awaddr;  wire [7:0] ch_awlen;  wire [2:0] ch_awsize;
    wire [1:0] ch_awburst; wire ch_awvalid, ch_awready;
    wire [AXI_DATA_WIDTH-1:0] ch_wdata; wire [AXI_STRB_WIDTH-1:0] ch_wstrb;
    wire ch_wlast, ch_wvalid, ch_wready;
    wire [1:0] ch_bresp; wire ch_bvalid, ch_bready;

    wire dut_done, dut_busy, dut_error;
    wire [31:0] dut_blocks_done, dut_bytes_done;

    // DUT
    cmpct_top #(
        .AXIL_ADDR_WIDTH(32), .AXIL_DATA_WIDTH(32),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_STRB_WIDTH(AXI_STRB_WIDTH),
        .MAX_BURST_LEN(16), .MAX_INDEX_BYTES(8192), .MAX_BLOCK_PAIRS(8),
        .STAGE4_MAX_BLOCK_BYTES(4096), .STAGE4_MAX_KEY_BYTES(72),
        .MERGE_MAX_USER_KEY_BYTES(64), .MERGE_MAX_KEY_BYTES(72),
        .MERGE_MAX_VALUE_BYTES(1024), .MERGE_MAX_RECORD_BYTES(2048),
        .MERGE_MAX_RECORDS(256), .MERGE_MAX_OUTPUT_BYTES(73728),
        .STAGE5_MAX_RECORDS(256), .STAGE5_MAX_PAYLOAD_BYTES(4096),
        .STAGE5_MAX_BLOCK_BYTES(4096), .STAGE5_MAX_KEY_BYTES(64),
        .STAGE5_MAX_VALUE_BYTES(1024), .STAGE5_RESTART_INTERVAL(16)
    ) dut (
        .axil_aclk(clk), .axil_aresetn(rstn),
        .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata),   .s_axil_wstrb(s_axil_wstrb),     .s_axil_wvalid(s_axil_wvalid),
        .s_axil_wready(s_axil_wready), .s_axil_bresp(s_axil_bresp),     .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready(s_axil_bready), .s_axil_araddr(s_axil_araddr),   .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready),.s_axil_rdata(s_axil_rdata),    .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
        .ui_aclk(clk), .ui_aresetn(rstn),
        .m_axi_p0_araddr(p0_araddr), .m_axi_p0_arlen(p0_arlen), .m_axi_p0_arsize(p0_arsize),
        .m_axi_p0_arburst(p0_arburst), .m_axi_p0_arvalid(p0_arvalid), .m_axi_p0_arready(p0_arready),
        .m_axi_p0_rdata(p0_rdata), .m_axi_p0_rresp(p0_rresp), .m_axi_p0_rlast(p0_rlast),
        .m_axi_p0_rvalid(p0_rvalid), .m_axi_p0_rready(p0_rready),
        .m_axi_p1_araddr(p1_araddr), .m_axi_p1_arlen(p1_arlen), .m_axi_p1_arsize(p1_arsize),
        .m_axi_p1_arburst(p1_arburst), .m_axi_p1_arvalid(p1_arvalid), .m_axi_p1_arready(p1_arready),
        .m_axi_p1_rdata(p1_rdata), .m_axi_p1_rresp(p1_rresp), .m_axi_p1_rlast(p1_rlast),
        .m_axi_p1_rvalid(p1_rvalid), .m_axi_p1_rready(p1_rready),
        .m_axi_src0_araddr(s0_araddr), .m_axi_src0_arlen(s0_arlen), .m_axi_src0_arsize(s0_arsize),
        .m_axi_src0_arburst(s0_arburst), .m_axi_src0_arvalid(s0_arvalid), .m_axi_src0_arready(s0_arready),
        .m_axi_src0_rdata(s0_rdata), .m_axi_src0_rresp(s0_rresp), .m_axi_src0_rlast(s0_rlast),
        .m_axi_src0_rvalid(s0_rvalid), .m_axi_src0_rready(s0_rready),
        .m_axi_src1_araddr(s1_araddr), .m_axi_src1_arlen(s1_arlen), .m_axi_src1_arsize(s1_arsize),
        .m_axi_src1_arburst(s1_arburst), .m_axi_src1_arvalid(s1_arvalid), .m_axi_src1_arready(s1_arready),
        .m_axi_src1_rdata(s1_rdata), .m_axi_src1_rresp(s1_rresp), .m_axi_src1_rlast(s1_rlast),
        .m_axi_src1_rvalid(s1_rvalid), .m_axi_src1_rready(s1_rready),
        .m_axi_chain_araddr(ch_araddr), .m_axi_chain_arlen(ch_arlen), .m_axi_chain_arsize(ch_arsize),
        .m_axi_chain_arburst(ch_arburst), .m_axi_chain_arvalid(ch_arvalid), .m_axi_chain_arready(ch_arready),
        .m_axi_chain_rdata(ch_rdata), .m_axi_chain_rresp(ch_rresp), .m_axi_chain_rlast(ch_rlast),
        .m_axi_chain_rvalid(ch_rvalid), .m_axi_chain_rready(ch_rready),
        .m_axi_chain_awaddr(ch_awaddr), .m_axi_chain_awlen(ch_awlen), .m_axi_chain_awsize(ch_awsize),
        .m_axi_chain_awburst(ch_awburst), .m_axi_chain_awvalid(ch_awvalid), .m_axi_chain_awready(ch_awready),
        .m_axi_chain_wdata(ch_wdata), .m_axi_chain_wstrb(ch_wstrb), .m_axi_chain_wlast(ch_wlast),
        .m_axi_chain_wvalid(ch_wvalid), .m_axi_chain_wready(ch_wready),
        .m_axi_chain_bresp(ch_bresp), .m_axi_chain_bvalid(ch_bvalid), .m_axi_chain_bready(ch_bready),
        .done(dut_done), .busy(dut_busy), .error(dut_error),
        .blocks_done(dut_blocks_done), .bytes_done(dut_bytes_done)
    );

    // AXI RAM models (same as tb_sstable_engine_axil_1blk)
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

    // AXI-Lite BFM tasks
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

    // Helper: read byte from chain memory at DST region
    function [7:0] dst_byte;
        input [31:0] offset;
        begin
            dst_byte = mem_chain.mem[DST_BASE[15:0] + offset];
        end
    endfunction

    // Stimulus
    integer i, j, fail_count;
    reg [31:0] sst_size, blk_bytes, blk_offset;
    reg [7:0]  b;
    integer    sentinel_count, sentinel_run;
    reg [31:0] restart_count;

    initial begin
        fail_count = 0;

        // Fill chain memory with sentinel
        for (i = 0; i < MEM_CHAIN; i = i + 1)
            mem_chain.mem[i] = SENTINEL;

        // Load fixtures (same as 1blk test)
        $readmemh("fixtures/src0_sstable_1blk.memh", mem_p0.mem);
        $readmemh("fixtures/src0_sstable_1blk.memh", mem_src0.mem);
        $readmemh("fixtures/src1_sstable_1blk.memh", mem_p1.mem);
        $readmemh("fixtures/src1_sstable_1blk.memh", mem_src1.mem);

        repeat(5) @(posedge clk);
        rstn = 1;
        repeat(10) @(posedge clk);

        $display("=== tb_enc_output_packing: Encoder Output Byte-Packing Regression ===");
        $display("");

        // Configure and start
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

        axil_write(A_CTRL, 32'h1);
        axil_write(A_CTRL, 32'h0);

        // Wait for completion
        for (t = 0; t < 50000; t = t + 1) begin
            @(posedge clk);
            if (dut_error) begin
                $display("FAIL: engine error at cycle %0d", t);
                $finish_and_return(1);
            end
            if (dut_done) begin
                $display("Engine done at cycle %0d", t);
                t = 50001;
            end
        end
        if (t == 50000) begin
            $display("FAIL: TIMEOUT after 50K cycles");
            $finish_and_return(1);
        end

        // ── CHECK 1: Basic counter sanity ──
        $display("");
        $display("=== CHECK 1: Counter Sanity ===");
        axil_read(A_PAIR_COUNT, rd_data);
        if (rd_data != 32'd1) begin $display("FAIL block_pair_count=%0d exp=1", rd_data); fail_count = fail_count + 1; end
        else $display("PASS block_pair_count = %0d", rd_data);

        axil_read(A_MRG_MRG, rd_data);
        if (rd_data != 32'd8) begin $display("FAIL merge_merged=%0d exp=8", rd_data); fail_count = fail_count + 1; end
        else $display("PASS merge_merged = %0d", rd_data);

        axil_read(A_S5_ENC, rd_data);
        if (rd_data != 32'd8) begin $display("FAIL stage5_encoded=%0d exp=8", rd_data); fail_count = fail_count + 1; end
        else $display("PASS stage5_encoded = %0d", rd_data);

        axil_read(A_SST_COUNT, rd_data);
        if (rd_data != 32'd1) begin $display("FAIL sstable_count=%0d exp=1", rd_data); fail_count = fail_count + 1; end
        else $display("PASS sstable_count = %0d", rd_data);

        // Get block size and SSTable size
        axil_read(A_DST_B0, blk_bytes);
        axil_read(A_SST_SIZE0, sst_size);
        $display("PASS dst_output_bytes[0] = %0d", blk_bytes);
        $display("PASS sstable_size[0]     = %0d", sst_size);

        // ── CHECK 2: No sentinel holes in data block ──
        $display("");
        $display("=== CHECK 2: No Sentinel Holes in Data Block ===");
        $display("  Scanning %0d bytes of data block at DST offset 0...", blk_bytes);
        sentinel_count = 0;
        sentinel_run   = 0;
        for (i = 0; i < blk_bytes; i = i + 1) begin
            b = dst_byte(i);
            if (b == SENTINEL) begin
                sentinel_count = sentinel_count + 1;
                sentinel_run   = sentinel_run + 1;
            end else begin
                sentinel_run = 0;
            end
            // Detect the specific bug pattern: 3 consecutive 0xA5 bytes
            // (a varint byte followed by 3 sentinel holes)
            if (sentinel_run >= 3) begin
                $display("FAIL: 3+ consecutive sentinel bytes at offset %0d (BUG PATTERN DETECTED)", i);
                $display("  bytes[%0d..%0d]: %02x %02x %02x %02x %02x %02x %02x %02x",
                    (i > 6 ? i - 6 : 0), i + 1,
                    dst_byte(i > 6 ? i-6 : 0), dst_byte(i > 5 ? i-5 : 1),
                    dst_byte(i > 4 ? i-4 : 2), dst_byte(i > 3 ? i-3 : 3),
                    dst_byte(i > 2 ? i-2 : 4), dst_byte(i > 1 ? i-1 : 5),
                    dst_byte(i), dst_byte(i+1));
                fail_count = fail_count + 1;
                i = blk_bytes; // break
            end
        end
        if (sentinel_count == 0)
            $display("PASS: No sentinel (0xA5) bytes found in %0d-byte data block", blk_bytes);
        else if (fail_count == 0)
            $display("INFO: %0d isolated sentinel bytes (may be valid data)", sentinel_count);

        // ── CHECK 3: Block trailer (comp_type + restart_count) ──
        $display("");
        $display("=== CHECK 3: Block Trailer Verification ===");
        // comp_type is at offset [blk_bytes - 5]
        b = dst_byte(blk_bytes - 5);
        if (b != 8'h00) begin
            $display("FAIL: comp_type = 0x%02x at offset %0d, expected 0x00", b, blk_bytes - 5);
            fail_count = fail_count + 1;
        end else
            $display("PASS: comp_type = 0x00 (no compression)");

        // restart_count at [blk_bytes - 9 .. blk_bytes - 6], little-endian
        restart_count = {dst_byte(blk_bytes-6), dst_byte(blk_bytes-7),
                         dst_byte(blk_bytes-8), dst_byte(blk_bytes-9)};
        if (restart_count == 0 || restart_count > blk_bytes / 4) begin
            $display("FAIL: restart_count = %0d (implausible for %0d-byte block)", restart_count, blk_bytes);
            fail_count = fail_count + 1;
        end else
            $display("PASS: restart_count = %0d", restart_count);

        // ── CHECK 4: First entry varint headers ──
        $display("");
        $display("=== CHECK 4: First Entry Varint Headers ===");
        // First entry must have shared_len = 0
        b = dst_byte(0);
        if (b != 8'h00) begin
            $display("FAIL: first entry shared_len varint byte[0] = 0x%02x, expected 0x00", b);
            $display("  First 16 bytes: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
                dst_byte(0),  dst_byte(1),  dst_byte(2),  dst_byte(3),
                dst_byte(4),  dst_byte(5),  dst_byte(6),  dst_byte(7),
                dst_byte(8),  dst_byte(9),  dst_byte(10), dst_byte(11),
                dst_byte(12), dst_byte(13), dst_byte(14), dst_byte(15));
            fail_count = fail_count + 1;
        end else begin
            $display("PASS: shared_len = 0 (first entry)");
            // non_shared_len (byte 1) should be > 0 and < 128 for single-byte varint
            b = dst_byte(1);
            if (b == 0 || b >= 128) begin
                $display("FAIL: non_shared_len varint = 0x%02x (expected 1..127)", b);
                fail_count = fail_count + 1;
            end else
                $display("PASS: non_shared_len = %0d", b);
            // value_len (byte 2) should be reasonable
            b = dst_byte(2);
            if (b >= 128) begin
                $display("INFO: value_len uses multi-byte varint (0x%02x)", b);
            end else begin
                $display("PASS: value_len = %0d", b);
            end
        end

        // ── CHECK 5: LevelDB footer magic ──
        $display("");
        $display("=== CHECK 5: LevelDB Footer Magic ===");
        // Footer magic is the last 8 bytes of the SSTable: 57 fb 80 8b 24 75 47 db
        if (dst_byte(sst_size - 8) == 8'h57 &&
            dst_byte(sst_size - 7) == 8'hfb &&
            dst_byte(sst_size - 6) == 8'h80 &&
            dst_byte(sst_size - 5) == 8'h8b &&
            dst_byte(sst_size - 4) == 8'h24 &&
            dst_byte(sst_size - 3) == 8'h75 &&
            dst_byte(sst_size - 2) == 8'h47 &&
            dst_byte(sst_size - 1) == 8'hdb) begin
            $display("PASS: LevelDB footer magic found at SSTable offset %0d", sst_size - 8);
        end else begin
            $display("FAIL: LevelDB footer magic not found at offset %0d", sst_size - 8);
            $display("  Got: %02x %02x %02x %02x %02x %02x %02x %02x",
                dst_byte(sst_size-8), dst_byte(sst_size-7),
                dst_byte(sst_size-6), dst_byte(sst_size-5),
                dst_byte(sst_size-4), dst_byte(sst_size-3),
                dst_byte(sst_size-2), dst_byte(sst_size-1));
            $display("  Expected: 57 fb 80 8b 24 75 47 db");
            fail_count = fail_count + 1;
        end

        // ── CHECK 6: Verify sentinel preserved BEYOND SSTable ──
        $display("");
        $display("=== CHECK 6: Sentinel Preservation Beyond SSTable ===");
        // Bytes past the SSTable should still be sentinel (0xA5)
        // Check 64 bytes past end (with 64-byte alignment)
        begin : check_tail_sentinel
            integer tail_start, tail_ok;
            tail_start = ((sst_size + 63) / 64) * 64;
            tail_ok = 1;
            for (i = 0; i < 64; i = i + 1) begin
                if (dst_byte(tail_start + i) != SENTINEL) begin
                    $display("FAIL: byte at DST+%0d = 0x%02x, expected sentinel 0xA5",
                        tail_start + i, dst_byte(tail_start + i));
                    tail_ok = 0;
                    fail_count = fail_count + 1;
                    i = 64; // break
                end
            end
            if (tail_ok)
                $display("PASS: 64 bytes after SSTable end (offset %0d) are sentinel", tail_start);
        end

        // ── Summary ──
        $display("");
        $display("=== SUMMARY ===");
        if (fail_count == 0) begin
            $display("ALL CHECKS PASSED: Encoder output byte-packing is correct");
            $display("  - No sentinel holes in data block");
            $display("  - Block trailer (comp_type=0x00, restart_count) valid");
            $display("  - First entry varint headers decodable");
            $display("  - LevelDB footer magic present");
            $display("  - Sentinel preserved beyond SSTable");
            $finish_and_return(0);
        end else begin
            $display("FAILED: %0d check(s) failed", fail_count);
            $display("  First 32 bytes of DST output:");
            $display("  %02x %02x %02x %02x %02x %02x %02x %02x  %02x %02x %02x %02x %02x %02x %02x %02x",
                dst_byte(0),  dst_byte(1),  dst_byte(2),  dst_byte(3),
                dst_byte(4),  dst_byte(5),  dst_byte(6),  dst_byte(7),
                dst_byte(8),  dst_byte(9),  dst_byte(10), dst_byte(11),
                dst_byte(12), dst_byte(13), dst_byte(14), dst_byte(15));
            $display("  %02x %02x %02x %02x %02x %02x %02x %02x  %02x %02x %02x %02x %02x %02x %02x %02x",
                dst_byte(16), dst_byte(17), dst_byte(18), dst_byte(19),
                dst_byte(20), dst_byte(21), dst_byte(22), dst_byte(23),
                dst_byte(24), dst_byte(25), dst_byte(26), dst_byte(27),
                dst_byte(28), dst_byte(29), dst_byte(30), dst_byte(31));
            $finish_and_return(1);
        end
    end

    initial begin
        #10000000;
        $display("WATCHDOG TIMEOUT");
        $finish_and_return(1);
    end

endmodule
