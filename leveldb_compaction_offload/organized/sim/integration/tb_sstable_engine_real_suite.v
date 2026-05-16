`timescale 1ns / 1ps
// tb_sstable_engine_real_suite
//
// Comprehensive multi-scenario test using real LevelDB SSTables.
// Runs 5 parameterized scenarios back-to-back via soft-reset:
//
//  1. interleave     — interleaved keys, 6 pairs, no dups
//  2. heavy_dup_real — 75% dup keys in real LevelDB format, 6 pairs
//  3. long_value     — values ~800-880 bytes, 4 pairs
//  4. asym_real      — src0=3 blocks, src1=8 blocks, no dups
//  5. many_records   — 16 records per block, 2 pairs
//
// Plus the existing real-SSTable test:
//  6. real_12blk     — 12 blocks, 8 dups, auto-split

module tb_sstable_engine_real_suite;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer AXI_STRB_WIDTH = 64;
    localparam integer MEM_SRC        = 131072;   // 128 KB
    localparam integer MEM_CHAIN      = 262144;   // 256 KB

    localparam [63:0] SRC0_BASE  = 64'h0000_0000_0000_0000;
    localparam [63:0] SRC1_BASE  = 64'h0000_0000_0001_0000;
    localparam [63:0] DST_BASE   = 64'h0000_0000_0002_0000;
    localparam [31:0] DST_STRIDE = 32'h0000_1000;
    localparam [63:0] MID_BASE   = 64'h0000_0000_0003_0000;

    // AXI-Lite register addresses
    localparam [31:0] A_CTRL       = 32'h0000;
    localparam [31:0] A_STATUS     = 32'h0004;
    localparam [31:0] A_SRC0_LO    = 32'h0008;
    localparam [31:0] A_SRC0_HI    = 32'h000C;
    localparam [31:0] A_SRC0_SIZE  = 32'h0010;
    localparam [31:0] A_SRC1_LO    = 32'h0014;
    localparam [31:0] A_SRC1_HI    = 32'h0018;
    localparam [31:0] A_SRC1_SIZE  = 32'h001C;
    localparam [31:0] A_DST_LO     = 32'h0020;
    localparam [31:0] A_DST_HI     = 32'h0024;
    localparam [31:0] A_DST_STRIDE = 32'h0028;
    localparam [31:0] A_MID_LO     = 32'h002C;
    localparam [31:0] A_MID_HI     = 32'h0030;
    localparam [31:0] A_PAIR_COUNT = 32'h0034;
    localparam [31:0] A_MAX_FSIZE  = 32'h0038;
    localparam [31:0] A_SST_COUNT  = 32'h003C;
    localparam [31:0] A_SRC0_DEC   = 32'h0040;
    localparam [31:0] A_SRC1_DEC   = 32'h0044;
    localparam [31:0] A_MRG_OUT_B  = 32'h0050;
    localparam [31:0] A_MRG_DEC    = 32'h0054;
    localparam [31:0] A_MRG_MRG    = 32'h0058;
    localparam [31:0] A_MRG_DRP    = 32'h005C;
    localparam [31:0] A_S5_INPUT   = 32'h0060;
    localparam [31:0] A_S5_ENC     = 32'h0064;
    localparam [31:0] A_S5_OUT_B   = 32'h0068;
    localparam [31:0] A_S5_WRITTEN = 32'h006C;

    // Clock / reset
    reg clk  = 0;
    reg rstn = 0;
    always #5 clk = ~clk;

    // AXI-Lite signals
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

    // AXI master wires — parser ports
    wire [AXI_ADDR_WIDTH-1:0] p0_araddr; wire [7:0] p0_arlen; wire [2:0] p0_arsize;
    wire [1:0] p0_arburst; wire p0_arvalid, p0_arready;
    wire [AXI_DATA_WIDTH-1:0] p0_rdata; wire [1:0] p0_rresp;
    wire p0_rlast, p0_rvalid, p0_rready;

    wire [AXI_ADDR_WIDTH-1:0] p1_araddr; wire [7:0] p1_arlen; wire [2:0] p1_arsize;
    wire [1:0] p1_arburst; wire p1_arvalid, p1_arready;
    wire [AXI_DATA_WIDTH-1:0] p1_rdata; wire [1:0] p1_rresp;
    wire p1_rlast, p1_rvalid, p1_rready;

    // AXI master wires — source ports
    wire [AXI_ADDR_WIDTH-1:0] s0_araddr; wire [7:0] s0_arlen; wire [2:0] s0_arsize;
    wire [1:0] s0_arburst; wire s0_arvalid, s0_arready;
    wire [AXI_DATA_WIDTH-1:0] s0_rdata; wire [1:0] s0_rresp;
    wire s0_rlast, s0_rvalid, s0_rready;

    wire [AXI_ADDR_WIDTH-1:0] s1_araddr; wire [7:0] s1_arlen; wire [2:0] s1_arsize;
    wire [1:0] s1_arburst; wire s1_arvalid, s1_arready;
    wire [AXI_DATA_WIDTH-1:0] s1_rdata; wire [1:0] s1_rresp;
    wire s1_rlast, s1_rvalid, s1_rready;

    // AXI master wires — chain (R/W)
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
        .MERGE_MAX_VALUE_BYTES(1024), .MERGE_MAX_RECORD_BYTES(2048),
        .MERGE_MAX_RECORDS(256), .MERGE_MAX_OUTPUT_BYTES(73728),
        .STAGE5_MAX_RECORDS(256), .STAGE5_MAX_PAYLOAD_BYTES(4096),
        .STAGE5_MAX_BLOCK_BYTES(4096), .STAGE5_MAX_KEY_BYTES(256),
        .STAGE5_MAX_VALUE_BYTES(1024), .STAGE5_RESTART_INTERVAL(16)
    ) dut (
        .axil_aclk(clk), .axil_aresetn(rstn),
        .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid),
        .s_axil_wready(s_axil_wready), .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready(s_axil_bready), .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready), .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp),
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

    // -----------------------------------------------------------------------
    // AXI RAM models (shared across all scenarios)
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
    // AXI-Lite BFM
    // -----------------------------------------------------------------------
    reg [31:0] rd_data;
    integer    t;

    task axil_write;
        input [31:0] waddr, wdata;
        begin
            @(posedge clk); #1;
            s_axil_awaddr = waddr; s_axil_awvalid = 1;
            @(posedge clk); while (!s_axil_awready) @(posedge clk);
            #1; s_axil_awvalid = 0;
            s_axil_wdata = wdata; s_axil_wstrb = 4'hF; s_axil_wvalid = 1;
            @(posedge clk); while (!s_axil_wready) @(posedge clk);
            #1; s_axil_wvalid = 0;
            s_axil_bready = 1;
            @(posedge clk); while (!s_axil_bvalid) @(posedge clk);
            #1; s_axil_bready = 0;
        end
    endtask

    task axil_read;
        input  [31:0] raddr;
        output [31:0] rdata;
        begin
            @(posedge clk); #1;
            s_axil_araddr = raddr; s_axil_arvalid = 1;
            @(posedge clk); while (!s_axil_arready) @(posedge clk);
            #1; s_axil_arvalid = 0;
            s_axil_rready = 1;
            @(posedge clk); while (!s_axil_rvalid) @(posedge clk);
            rdata = s_axil_rdata;
            #1; s_axil_rready = 0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Check helpers
    // -----------------------------------------------------------------------
    integer fail_count, scenario_fails;

    task chk;
        input [31:0] got, exp;
        input [255:0] label;
        begin
            if (got !== exp) begin
                $display("  FAIL %0s: got=%0d exp=%0d", label, got, exp);
                fail_count = fail_count + 1;
                scenario_fails = scenario_fails + 1;
            end else
                $display("  PASS %0s = %0d", label, got);
        end
    endtask

    task chk_gt0;
        input [31:0] got;
        input [255:0] label;
        begin
            if (got == 0) begin
                $display("  FAIL %0s: got=0, expected > 0", label);
                fail_count = fail_count + 1;
                scenario_fails = scenario_fails + 1;
            end else
                $display("  PASS %0s = %0d", label, got);
        end
    endtask

    task chk_gte;
        input [31:0] got, threshold;
        input [255:0] label;
        begin
            if (got < threshold) begin
                $display("  FAIL %0s: got=%0d expected >= %0d", label, got, threshold);
                fail_count = fail_count + 1;
                scenario_fails = scenario_fails + 1;
            end else
                $display("  PASS %0s = %0d (>= %0d)", label, got, threshold);
        end
    endtask

    // -----------------------------------------------------------------------
    // Run one scenario: load fixtures, start engine, wait, check counters
    // -----------------------------------------------------------------------
    task run_scenario;
        input [31:0] src0_size, src1_size;
        input [31:0] exp_src0_dec, exp_src1_dec;
        input [31:0] exp_merged, exp_dropped;
        input [31:0] max_file_size;
        begin
            scenario_fails = 0;

            // Hard reset between scenarios
            rstn = 0;
            repeat(5) @(posedge clk);
            rstn = 1;
            repeat(10) @(posedge clk);

            // Clear chain memory
            for (t = 0; t < MEM_CHAIN; t = t + 1)
                mem_chain.mem[t] = 8'hA5;

            // Configure registers
            axil_write(A_SRC0_LO,    SRC0_BASE[31:0]);
            axil_write(A_SRC0_HI,    SRC0_BASE[63:32]);
            axil_write(A_SRC0_SIZE,  src0_size);
            axil_write(A_SRC1_LO,    SRC1_BASE[31:0]);
            axil_write(A_SRC1_HI,    SRC1_BASE[63:32]);
            axil_write(A_SRC1_SIZE,  src1_size);
            axil_write(A_DST_LO,     DST_BASE[31:0]);
            axil_write(A_DST_HI,     DST_BASE[63:32]);
            axil_write(A_DST_STRIDE, DST_STRIDE);
            axil_write(A_MID_LO,     MID_BASE[31:0]);
            axil_write(A_MID_HI,     MID_BASE[63:32]);
            axil_write(A_MAX_FSIZE,  max_file_size);

            // Start engine
            axil_write(A_CTRL, 32'h1);
            axil_write(A_CTRL, 32'h0);

            // Wait for completion
            for (t = 0; t < 4000000; t = t + 1) begin
                @(posedge clk);
                if (dut_error) begin
                    $display("  ERROR at cycle %0d (ts=%0d nb_st=%0d blk=%0d)",
                        t, dut.u_engine.ts,
                        dut.u_engine.u_nblock.state,
                        dut.u_engine.u_nblock.active_block_index);
                    scenario_fails = scenario_fails + 1;
                    fail_count = fail_count + 1;
                    t = 4000001;
                end
                if (dut_done) begin
                    $display("  Done at cycle %0d", t);
                    t = 4000001;
                end
            end
            if (t == 4000000) begin
                $display("  TIMEOUT (nb_st=%0d blk=%0d)",
                    dut.u_engine.u_nblock.state,
                    dut.u_engine.u_nblock.active_block_index);
                scenario_fails = scenario_fails + 1;
                fail_count = fail_count + 1;
            end

            // Check counters
            repeat(20) @(posedge clk);
            axil_read(A_SRC0_DEC,   rd_data); chk(rd_data, exp_src0_dec,  "src0_decoded");
            axil_read(A_SRC1_DEC,   rd_data); chk(rd_data, exp_src1_dec,  "src1_decoded");
            axil_read(A_MRG_MRG,    rd_data); chk(rd_data, exp_merged,    "merge_merged");
            axil_read(A_MRG_DRP,    rd_data); chk(rd_data, exp_dropped,   "merge_dropped");
            axil_read(A_S5_INPUT,   rd_data); chk(rd_data, exp_merged,    "stage5_input");
            axil_read(A_S5_ENC,     rd_data); chk(rd_data, exp_merged,    "stage5_encoded");
            axil_read(A_S5_WRITTEN, rd_data); chk_gt0(rd_data,            "stage5_written");

            repeat(10) @(posedge clk);
        end
    endtask

    // -----------------------------------------------------------------------
    // Stimulus — run all scenarios sequentially
    // -----------------------------------------------------------------------
    integer i;
    integer scenario_count, pass_count;

    initial begin
        fail_count = 0;
        scenario_count = 0;
        pass_count = 0;

        repeat(5) @(posedge clk);
        rstn = 1;
        repeat(10) @(posedge clk);

        $display("============================================================");
        $display("  Real LevelDB SSTable Comprehensive Test Suite");
        $display("============================================================");

        // ── Scenario 1: interleave (6 pairs, 24+24 recs, 0 dups) ──
        $display("\n=== [1/6] interleave (6 pairs, interleaved keys) ===");
        $readmemh("fixtures/src0_interleave.memh", mem_p0.mem);
        $readmemh("fixtures/src0_interleave.memh", mem_src0.mem);
        $readmemh("fixtures/src1_interleave.memh", mem_p1.mem);
        $readmemh("fixtures/src1_interleave.memh", mem_src1.mem);
        run_scenario(32'd782, 32'd782, 32'd24, 32'd24, 32'd48, 32'd0, 32'd0);
        scenario_count = scenario_count + 1;
        if (scenario_fails == 0) begin $display("  >>> PASS"); pass_count = pass_count + 1; end
        else $display("  >>> FAIL (%0d errors)", scenario_fails);

        // ── Scenario 2: heavy_dup_real (6 pairs, 16 dups) ──
        $display("\n=== [2/6] heavy_dup_real (6 pairs, 16 duplicates) ===");
        $readmemh("fixtures/src0_heavy_dup_real.memh", mem_p0.mem);
        $readmemh("fixtures/src0_heavy_dup_real.memh", mem_src0.mem);
        $readmemh("fixtures/src1_heavy_dup_real.memh", mem_p1.mem);
        $readmemh("fixtures/src1_heavy_dup_real.memh", mem_src1.mem);
        run_scenario(32'd812, 32'd905, 32'd24, 32'd24, 32'd32, 32'd16, 32'd0);
        scenario_count = scenario_count + 1;
        if (scenario_fails == 0) begin $display("  >>> PASS"); pass_count = pass_count + 1; end
        else $display("  >>> FAIL (%0d errors)", scenario_fails);

        // ── Scenario 3: long_value (4 pairs, ~800B values) ──
        $display("\n=== [3/6] long_value (4 pairs, 350-430 byte values) ===");
        $readmemh("fixtures/src0_long_value.memh", mem_p0.mem);
        $readmemh("fixtures/src0_long_value.memh", mem_src0.mem);
        $readmemh("fixtures/src1_long_value.memh", mem_p1.mem);
        $readmemh("fixtures/src1_long_value.memh", mem_src1.mem);
        run_scenario(32'd5009, 32'd5009, 32'd12, 32'd12, 32'd24, 32'd0, 32'd0);
        scenario_count = scenario_count + 1;
        if (scenario_fails == 0) begin $display("  >>> PASS"); pass_count = pass_count + 1; end
        else $display("  >>> FAIL (%0d errors)", scenario_fails);

        // ── Scenario 4: asym_real (src0=3, src1=8, 0 dups) ──
        $display("\n=== [4/6] asym_real (src0=3 blocks, src1=8 blocks) ===");
        $readmemh("fixtures/src0_asym_real.memh", mem_p0.mem);
        $readmemh("fixtures/src0_asym_real.memh", mem_src0.mem);
        $readmemh("fixtures/src1_asym_real.memh", mem_p1.mem);
        $readmemh("fixtures/src1_asym_real.memh", mem_src1.mem);
        run_scenario(32'd450, 32'd1110, 32'd12, 32'd32, 32'd44, 32'd0, 32'd0);
        scenario_count = scenario_count + 1;
        if (scenario_fails == 0) begin $display("  >>> PASS"); pass_count = pass_count + 1; end
        else $display("  >>> FAIL (%0d errors)", scenario_fails);

        // ── Scenario 5: many_records (2 pairs, 16 recs/block) ──
        $display("\n=== [5/6] many_records (2 pairs, 16 records per block) ===");
        $readmemh("fixtures/src0_many_records.memh", mem_p0.mem);
        $readmemh("fixtures/src0_many_records.memh", mem_src0.mem);
        $readmemh("fixtures/src1_many_records.memh", mem_p1.mem);
        $readmemh("fixtures/src1_many_records.memh", mem_src1.mem);
        run_scenario(32'd911, 32'd911, 32'd32, 32'd32, 32'd64, 32'd0, 32'd0);
        scenario_count = scenario_count + 1;
        if (scenario_fails == 0) begin $display("  >>> PASS"); pass_count = pass_count + 1; end
        else $display("  >>> FAIL (%0d errors)", scenario_fails);

        // ── Scenario 6: real_12blk (12 pairs, 8 dups, auto-split) ──
        $display("\n=== [6/6] real_12blk (12 pairs, 8 dups, auto-split) ===");
        $readmemh("fixtures/src0_real.memh", mem_p0.mem);
        $readmemh("fixtures/src0_real.memh", mem_src0.mem);
        $readmemh("fixtures/src1_real.memh", mem_p1.mem);
        $readmemh("fixtures/src1_real.memh", mem_src1.mem);
        run_scenario(32'd2012, 32'd2012, 32'd48, 32'd48, 32'd88, 32'd8, 32'd0);
        scenario_count = scenario_count + 1;
        if (scenario_fails == 0) begin $display("  >>> PASS"); pass_count = pass_count + 1; end
        else $display("  >>> FAIL (%0d errors)", scenario_fails);

        // ── Summary ──
        $display("\n============================================================");
        $display("  SUMMARY: %0d/%0d scenarios PASSED", pass_count, scenario_count);
        $display("============================================================");

        if (fail_count == 0)
            $display("\nPASS: all real-LevelDB scenarios completed successfully");
        else
            $display("\nFAIL: %0d total check failures across %0d scenarios",
                fail_count, scenario_count - pass_count);

        $finish_and_return(fail_count);
    end

    initial begin
        #200000000;
        $display("WATCHDOG TIMEOUT at 200ms");
        $finish_and_return(1);
    end

endmodule
