`timescale 1ns / 1ps

module tb_stage4_real_internal_key_two_way_merge_stage5_nblock_top;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer MAX_BLOCK_PAIRS = 3;
    localparam integer MEM_BYTES      = 16384;
    localparam integer SRC0B0_BYTES   = 42;
    localparam integer SRC1B0_BYTES   = 42;
    localparam integer SRC0B1_BYTES   = 44;
    localparam integer SRC1B1_BYTES   = 46;
    localparam integer SRC0B2_BYTES   = 23;
    localparam integer SRC1B2_BYTES   = 23;
    localparam integer DST0_BYTES     = 53;
    localparam integer DST1_BYTES     = 38;
    localparam integer DST2_BYTES     = 23;
    localparam [63:0] SRC0_ADDR0      = 64'h0000_0000_0000_0000;
    localparam [63:0] SRC1_ADDR0      = 64'h0000_0000_0000_0100;
    localparam [63:0] SRC0_ADDR1      = 64'h0000_0000_0000_0200;
    localparam [63:0] SRC1_ADDR1      = 64'h0000_0000_0000_0300;
    localparam [63:0] SRC0_ADDR2      = 64'h0000_0000_0000_0400;
    localparam [63:0] SRC1_ADDR2      = 64'h0000_0000_0000_0500;
    localparam [63:0] MID_ADDR        = 64'h0000_0000_0000_0600;
    localparam [63:0] DST_ADDR0       = 64'h0000_0000_0000_0800;
    localparam [63:0] DST_ADDR1       = 64'h0000_0000_0000_0c00;
    localparam [63:0] DST_ADDR2       = 64'h0000_0000_0000_1000;

    reg                         clk;
    reg                         rstn;
    reg                         clear;
    reg                         start;
    reg  [31:0]                 block_pair_count;
    reg  [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] src0_base_addr_vec;
    reg  [MAX_BLOCK_PAIRS*32-1:0]             src0_byte_count_vec;
    reg  [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] src1_base_addr_vec;
    reg  [MAX_BLOCK_PAIRS*32-1:0]             src1_byte_count_vec;
    reg  [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] dst_base_addr_vec;
    reg  [AXI_ADDR_WIDTH-1:0]   mid_base_addr;
    wire                        busy;
    wire                        done;
    wire                        error;
    wire [31:0]                 active_block_index;
    wire [31:0]                 blocks_completed;
    wire [MAX_BLOCK_PAIRS*32-1:0] dst_output_block_bytes_vec;
    wire [31:0]                 total_source0_decoded_entry_count;
    wire [31:0]                 total_source1_decoded_entry_count;
    wire [31:0]                 total_source0_bytes_read;
    wire [31:0]                 total_source1_bytes_read;
    wire [31:0]                 total_merge_output_byte_count;
    wire [31:0]                 total_merge_decoded_record_count;
    wire [31:0]                 total_merge_merged_record_count;
    wire [31:0]                 total_merge_dropped_superseded_count;
    wire [31:0]                 total_stage5_input_record_count;
    wire [31:0]                 total_stage5_encoded_entry_count;
    wire [31:0]                 total_stage5_output_block_bytes;
    wire [31:0]                 total_stage5_bytes_written;

    wire [AXI_ADDR_WIDTH-1:0]   m_axi_src0_araddr;
    wire [7:0]                  m_axi_src0_arlen;
    wire [2:0]                  m_axi_src0_arsize;
    wire [1:0]                  m_axi_src0_arburst;
    wire                        m_axi_src0_arvalid;
    wire                        m_axi_src0_arready;
    wire [AXI_DATA_WIDTH-1:0]   m_axi_src0_rdata;
    wire [1:0]                  m_axi_src0_rresp;
    wire                        m_axi_src0_rlast;
    wire                        m_axi_src0_rvalid;
    wire                        m_axi_src0_rready;

    wire [AXI_ADDR_WIDTH-1:0]   m_axi_src1_araddr;
    wire [7:0]                  m_axi_src1_arlen;
    wire [2:0]                  m_axi_src1_arsize;
    wire [1:0]                  m_axi_src1_arburst;
    wire                        m_axi_src1_arvalid;
    wire                        m_axi_src1_arready;
    wire [AXI_DATA_WIDTH-1:0]   m_axi_src1_rdata;
    wire [1:0]                  m_axi_src1_rresp;
    wire                        m_axi_src1_rlast;
    wire                        m_axi_src1_rvalid;
    wire                        m_axi_src1_rready;

    wire [AXI_ADDR_WIDTH-1:0]   m_axi_chain_araddr;
    wire [7:0]                  m_axi_chain_arlen;
    wire [2:0]                  m_axi_chain_arsize;
    wire [1:0]                  m_axi_chain_arburst;
    wire                        m_axi_chain_arvalid;
    wire                        m_axi_chain_arready;
    wire [AXI_DATA_WIDTH-1:0]   m_axi_chain_rdata;
    wire [1:0]                  m_axi_chain_rresp;
    wire                        m_axi_chain_rlast;
    wire                        m_axi_chain_rvalid;
    wire                        m_axi_chain_rready;
    wire [AXI_ADDR_WIDTH-1:0]   m_axi_chain_awaddr;
    wire [7:0]                  m_axi_chain_awlen;
    wire [2:0]                  m_axi_chain_awsize;
    wire [1:0]                  m_axi_chain_awburst;
    wire                        m_axi_chain_awvalid;
    wire                        m_axi_chain_awready;
    wire [AXI_DATA_WIDTH-1:0]   m_axi_chain_wdata;
    wire [AXI_DATA_WIDTH/8-1:0] m_axi_chain_wstrb;
    wire                        m_axi_chain_wlast;
    wire                        m_axi_chain_wvalid;
    wire                        m_axi_chain_wready;
    wire [1:0]                  m_axi_chain_bresp;
    wire                        m_axi_chain_bvalid;
    wire                        m_axi_chain_bready;

    reg [7:0] src0b0 [0:SRC0B0_BYTES-1];
    reg [7:0] src1b0 [0:SRC1B0_BYTES-1];
    reg [7:0] src0b1 [0:SRC0B1_BYTES-1];
    reg [7:0] src1b1 [0:SRC1B1_BYTES-1];
    reg [7:0] src0b2 [0:SRC0B2_BYTES-1];
    reg [7:0] src1b2 [0:SRC1B2_BYTES-1];
    reg [7:0] dst0  [0:DST0_BYTES-1];
    reg [7:0] dst1  [0:DST1_BYTES-1];
    reg [7:0] dst2  [0:DST2_BYTES-1];

    integer i;
    integer wait_cycles;

    stage4_real_internal_key_two_way_merge_stage5_nblock_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MAX_BURST_LEN(16),
        .STAGE4_MAX_BLOCK_BYTES(4096),
        .STAGE4_MAX_KEY_BYTES(264),
        .MERGE_MAX_USER_KEY_BYTES(256),
        .MERGE_MAX_KEY_BYTES(264),
        .MERGE_MAX_VALUE_BYTES(1024),
        .MERGE_MAX_RECORD_BYTES(2048),
        .MERGE_MAX_RECORDS(256),
        .MERGE_MAX_OUTPUT_BYTES(1024),
        .STAGE5_MAX_RECORDS(256),
        .STAGE5_MAX_PAYLOAD_BYTES(1024),
        .STAGE5_MAX_BLOCK_BYTES(1024),
        .STAGE5_MAX_KEY_BYTES(256),
        .STAGE5_MAX_VALUE_BYTES(1024),
        .STAGE5_RESTART_INTERVAL(16),
        .MAX_BLOCK_PAIRS(MAX_BLOCK_PAIRS)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .block_pair_count(block_pair_count),
        .src0_base_addr_vec(src0_base_addr_vec),
        .src0_byte_count_vec(src0_byte_count_vec),
        .src1_base_addr_vec(src1_base_addr_vec),
        .src1_byte_count_vec(src1_byte_count_vec),
        .dst_base_addr_vec(dst_base_addr_vec),
        .mid_base_addr(mid_base_addr),
        .busy(busy),
        .done(done),
        .error(error),
        .active_block_index(active_block_index),
        .blocks_completed(blocks_completed),
        .dst_output_block_bytes_vec(dst_output_block_bytes_vec),
        .total_source0_decoded_entry_count(total_source0_decoded_entry_count),
        .total_source1_decoded_entry_count(total_source1_decoded_entry_count),
        .total_source0_bytes_read(total_source0_bytes_read),
        .total_source1_bytes_read(total_source1_bytes_read),
        .total_merge_output_byte_count(total_merge_output_byte_count),
        .total_merge_decoded_record_count(total_merge_decoded_record_count),
        .total_merge_merged_record_count(total_merge_merged_record_count),
        .total_merge_dropped_superseded_count(total_merge_dropped_superseded_count),
        .total_stage5_input_record_count(total_stage5_input_record_count),
        .total_stage5_encoded_entry_count(total_stage5_encoded_entry_count),
        .total_stage5_output_block_bytes(total_stage5_output_block_bytes),
        .total_stage5_bytes_written(total_stage5_bytes_written),
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

    axi_ram_model #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MEM_BYTES(MEM_BYTES),
        .READ_LATENCY(2)
    ) mem_src0 (
        .clk(clk),
        .rstn(rstn),
        .s_axi_araddr(m_axi_src0_araddr),
        .s_axi_arlen(m_axi_src0_arlen),
        .s_axi_arsize(m_axi_src0_arsize),
        .s_axi_arburst(m_axi_src0_arburst),
        .s_axi_arid(1'b0),
        .s_axi_arvalid(m_axi_src0_arvalid),
        .s_axi_arready(m_axi_src0_arready),
        .s_axi_rdata(m_axi_src0_rdata),
        .s_axi_rresp(m_axi_src0_rresp),
        .s_axi_rlast(m_axi_src0_rlast),
        .s_axi_rid(),
        .s_axi_rvalid(m_axi_src0_rvalid),
        .s_axi_rready(m_axi_src0_rready),
        .s_axi_awaddr({AXI_ADDR_WIDTH{1'b0}}),
        .s_axi_awlen(8'd0),
        .s_axi_awsize(3'd0),
        .s_axi_awburst(2'd0),
        .s_axi_awid(1'b0),
        .s_axi_awvalid(1'b0),
        .s_axi_awready(),
        .s_axi_wdata({AXI_DATA_WIDTH{1'b0}}),
        .s_axi_wstrb({(AXI_DATA_WIDTH/8){1'b0}}),
        .s_axi_wlast(1'b0),
        .s_axi_wvalid(1'b0),
        .s_axi_wready(),
        .s_axi_bresp(),
        .s_axi_bid(),
        .s_axi_bvalid(),
        .s_axi_bready(1'b0)
    );

    axi_ram_model #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MEM_BYTES(MEM_BYTES),
        .READ_LATENCY(2)
    ) mem_src1 (
        .clk(clk),
        .rstn(rstn),
        .s_axi_araddr(m_axi_src1_araddr),
        .s_axi_arlen(m_axi_src1_arlen),
        .s_axi_arsize(m_axi_src1_arsize),
        .s_axi_arburst(m_axi_src1_arburst),
        .s_axi_arid(1'b0),
        .s_axi_arvalid(m_axi_src1_arvalid),
        .s_axi_arready(m_axi_src1_arready),
        .s_axi_rdata(m_axi_src1_rdata),
        .s_axi_rresp(m_axi_src1_rresp),
        .s_axi_rlast(m_axi_src1_rlast),
        .s_axi_rid(),
        .s_axi_rvalid(m_axi_src1_rvalid),
        .s_axi_rready(m_axi_src1_rready),
        .s_axi_awaddr({AXI_ADDR_WIDTH{1'b0}}),
        .s_axi_awlen(8'd0),
        .s_axi_awsize(3'd0),
        .s_axi_awburst(2'd0),
        .s_axi_awid(1'b0),
        .s_axi_awvalid(1'b0),
        .s_axi_awready(),
        .s_axi_wdata({AXI_DATA_WIDTH{1'b0}}),
        .s_axi_wstrb({(AXI_DATA_WIDTH/8){1'b0}}),
        .s_axi_wlast(1'b0),
        .s_axi_wvalid(1'b0),
        .s_axi_wready(),
        .s_axi_bresp(),
        .s_axi_bid(),
        .s_axi_bvalid(),
        .s_axi_bready(1'b0)
    );

    axi_ram_model #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MEM_BYTES(MEM_BYTES),
        .READ_LATENCY(2)
    ) mem_chain (
        .clk(clk),
        .rstn(rstn),
        .s_axi_araddr(m_axi_chain_araddr),
        .s_axi_arlen(m_axi_chain_arlen),
        .s_axi_arsize(m_axi_chain_arsize),
        .s_axi_arburst(m_axi_chain_arburst),
        .s_axi_arid(1'b0),
        .s_axi_arvalid(m_axi_chain_arvalid),
        .s_axi_arready(m_axi_chain_arready),
        .s_axi_rdata(m_axi_chain_rdata),
        .s_axi_rresp(m_axi_chain_rresp),
        .s_axi_rlast(m_axi_chain_rlast),
        .s_axi_rid(),
        .s_axi_rvalid(m_axi_chain_rvalid),
        .s_axi_rready(m_axi_chain_rready),
        .s_axi_awaddr(m_axi_chain_awaddr),
        .s_axi_awlen(m_axi_chain_awlen),
        .s_axi_awsize(m_axi_chain_awsize),
        .s_axi_awburst(m_axi_chain_awburst),
        .s_axi_awid(1'b0),
        .s_axi_awvalid(m_axi_chain_awvalid),
        .s_axi_awready(m_axi_chain_awready),
        .s_axi_wdata(m_axi_chain_wdata),
        .s_axi_wstrb(m_axi_chain_wstrb),
        .s_axi_wlast(m_axi_chain_wlast),
        .s_axi_wvalid(m_axi_chain_wvalid),
        .s_axi_wready(m_axi_chain_wready),
        .s_axi_bresp(m_axi_chain_bresp),
        .s_axi_bid(),
        .s_axi_bvalid(m_axi_chain_bvalid),
        .s_axi_bready(m_axi_chain_bready)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rstn = 1'b0;
        clear = 1'b0;
        start = 1'b0;
        block_pair_count = 32'd3;
        src0_base_addr_vec = {SRC0_ADDR2, SRC0_ADDR1, SRC0_ADDR0};
        src0_byte_count_vec = {SRC0B2_BYTES[31:0], SRC0B1_BYTES[31:0], SRC0B0_BYTES[31:0]};
        src1_base_addr_vec = {SRC1_ADDR2, SRC1_ADDR1, SRC1_ADDR0};
        src1_byte_count_vec = {SRC1B2_BYTES[31:0], SRC1B1_BYTES[31:0], SRC1B0_BYTES[31:0]};
        dst_base_addr_vec = {DST_ADDR2, DST_ADDR1, DST_ADDR0};
        mid_base_addr = MID_ADDR;

        for (i = 0; i < MEM_BYTES; i = i + 1) begin
            mem_src0.mem[i] = 8'hA5;
            mem_src1.mem[i] = 8'hA5;
            mem_chain.mem[i] = 8'hA5;
        end

        src0b0[0] = 8'h00; src0b0[1] = 8'h0b; src0b0[2] = 8'h01; src0b0[3] = 8'h61; src0b0[4] = 8'h6e; src0b0[5] = 8'h74; src0b0[6] = 8'h01; src0b0[7] = 8'h64;
        src0b0[8] = 8'h00; src0b0[9] = 8'h00; src0b0[10] = 8'h00; src0b0[11] = 8'h00; src0b0[12] = 8'h00; src0b0[13] = 8'h00; src0b0[14] = 8'h41; src0b0[15] = 8'h00;
        src0b0[16] = 8'h0b; src0b0[17] = 8'h01; src0b0[18] = 8'h63; src0b0[19] = 8'h61; src0b0[20] = 8'h74; src0b0[21] = 8'h01; src0b0[22] = 8'h5f; src0b0[23] = 8'h00;
        src0b0[24] = 8'h00; src0b0[25] = 8'h00; src0b0[26] = 8'h00; src0b0[27] = 8'h00; src0b0[28] = 8'h00; src0b0[29] = 8'h61; src0b0[30] = 8'h00; src0b0[31] = 8'h00;
        src0b0[32] = 8'h00; src0b0[33] = 8'h00; src0b0[34] = 8'h0f; src0b0[35] = 8'h00; src0b0[36] = 8'h00; src0b0[37] = 8'h00; src0b0[38] = 8'h02; src0b0[39] = 8'h00;
        src0b0[40] = 8'h00; src0b0[41] = 8'h00;

        src1b0[0] = 8'h00; src1b0[1] = 8'h0b; src1b0[2] = 8'h01; src1b0[3] = 8'h62; src1b0[4] = 8'h65; src1b0[5] = 8'h65; src1b0[6] = 8'h01; src1b0[7] = 8'h6e;
        src1b0[8] = 8'h00; src1b0[9] = 8'h00; src1b0[10] = 8'h00; src1b0[11] = 8'h00; src1b0[12] = 8'h00; src1b0[13] = 8'h00; src1b0[14] = 8'h42; src1b0[15] = 8'h00;
        src1b0[16] = 8'h0b; src1b0[17] = 8'h01; src1b0[18] = 8'h63; src1b0[19] = 8'h61; src1b0[20] = 8'h74; src1b0[21] = 8'h01; src1b0[22] = 8'h61; src1b0[23] = 8'h00;
        src1b0[24] = 8'h00; src1b0[25] = 8'h00; src1b0[26] = 8'h00; src1b0[27] = 8'h00; src1b0[28] = 8'h00; src1b0[29] = 8'h58; src1b0[30] = 8'h00; src1b0[31] = 8'h00;
        src1b0[32] = 8'h00; src1b0[33] = 8'h00; src1b0[34] = 8'h0f; src1b0[35] = 8'h00; src1b0[36] = 8'h00; src1b0[37] = 8'h00; src1b0[38] = 8'h02; src1b0[39] = 8'h00;
        src1b0[40] = 8'h00; src1b0[41] = 8'h00;

        src0b1[0] = 8'h00; src0b1[1] = 8'h0b; src0b1[2] = 8'h03; src0b1[3] = 8'h63; src0b1[4] = 8'h61; src0b1[5] = 8'h74; src0b1[6] = 8'h01; src0b1[7] = 8'h5e;
        src0b1[8] = 8'h00; src0b1[9] = 8'h00; src0b1[10] = 8'h00; src0b1[11] = 8'h00; src0b1[12] = 8'h00; src0b1[13] = 8'h00; src0b1[14] = 8'h6f; src0b1[15] = 8'h6c;
        src0b1[16] = 8'h64; src0b1[17] = 8'h00; src0b1[18] = 8'h0b; src0b1[19] = 8'h01; src0b1[20] = 8'h64; src0b1[21] = 8'h6f; src0b1[22] = 8'h67; src0b1[23] = 8'h01;
        src0b1[24] = 8'h5a; src0b1[25] = 8'h00; src0b1[26] = 8'h00; src0b1[27] = 8'h00; src0b1[28] = 8'h00; src0b1[29] = 8'h00; src0b1[30] = 8'h00; src0b1[31] = 8'h44;
        src0b1[32] = 8'h00; src0b1[33] = 8'h00; src0b1[34] = 8'h00; src0b1[35] = 8'h00; src0b1[36] = 8'h11; src0b1[37] = 8'h00; src0b1[38] = 8'h00; src0b1[39] = 8'h00;
        src0b1[40] = 8'h02; src0b1[41] = 8'h00; src0b1[42] = 8'h00; src0b1[43] = 8'h00;

        src1b1[0] = 8'h00; src1b1[1] = 8'h0b; src1b1[2] = 8'h05; src1b1[3] = 8'h63; src1b1[4] = 8'h61; src1b1[5] = 8'h74; src1b1[6] = 8'h01; src1b1[7] = 8'h5d;
        src1b1[8] = 8'h00; src1b1[9] = 8'h00; src1b1[10] = 8'h00; src1b1[11] = 8'h00; src1b1[12] = 8'h00; src1b1[13] = 8'h00; src1b1[14] = 8'h6f; src1b1[15] = 8'h6c;
        src1b1[16] = 8'h64; src1b1[17] = 8'h65; src1b1[18] = 8'h72; src1b1[19] = 8'h00; src1b1[20] = 8'h0b; src1b1[21] = 8'h01; src1b1[22] = 8'h65; src1b1[23] = 8'h65;
        src1b1[24] = 8'h6c; src1b1[25] = 8'h01; src1b1[26] = 8'h50; src1b1[27] = 8'h00; src1b1[28] = 8'h00; src1b1[29] = 8'h00; src1b1[30] = 8'h00; src1b1[31] = 8'h00;
        src1b1[32] = 8'h00; src1b1[33] = 8'h45; src1b1[34] = 8'h00; src1b1[35] = 8'h00; src1b1[36] = 8'h00; src1b1[37] = 8'h00; src1b1[38] = 8'h13; src1b1[39] = 8'h00;
        src1b1[40] = 8'h00; src1b1[41] = 8'h00; src1b1[42] = 8'h02; src1b1[43] = 8'h00; src1b1[44] = 8'h00; src1b1[45] = 8'h00;

        src0b2[0] = 8'h00; src0b2[1] = 8'h0b; src0b2[2] = 8'h01; src0b2[3] = 8'h65; src0b2[4] = 8'h65; src0b2[5] = 8'h6c; src0b2[6] = 8'h01; src0b2[7] = 8'h4f;
        src0b2[8] = 8'h00; src0b2[9] = 8'h00; src0b2[10] = 8'h00; src0b2[11] = 8'h00; src0b2[12] = 8'h00; src0b2[13] = 8'h00; src0b2[14] = 8'h70; src0b2[15] = 8'h00;
        src0b2[16] = 8'h00; src0b2[17] = 8'h00; src0b2[18] = 8'h00; src0b2[19] = 8'h01; src0b2[20] = 8'h00; src0b2[21] = 8'h00; src0b2[22] = 8'h00;

        src1b2[0] = 8'h00; src1b2[1] = 8'h0b; src1b2[2] = 8'h01; src1b2[3] = 8'h66; src1b2[4] = 8'h6f; src1b2[5] = 8'h78; src1b2[6] = 8'h01; src1b2[7] = 8'h46;
        src1b2[8] = 8'h00; src1b2[9] = 8'h00; src1b2[10] = 8'h00; src1b2[11] = 8'h00; src1b2[12] = 8'h00; src1b2[13] = 8'h00; src1b2[14] = 8'h46; src1b2[15] = 8'h00;
        src1b2[16] = 8'h00; src1b2[17] = 8'h00; src1b2[18] = 8'h00; src1b2[19] = 8'h01; src1b2[20] = 8'h00; src1b2[21] = 8'h00; src1b2[22] = 8'h00;

        dst0[0] = 8'h00; dst0[1] = 8'h0b; dst0[2] = 8'h01; dst0[3] = 8'h61; dst0[4] = 8'h6e; dst0[5] = 8'h74; dst0[6] = 8'h01; dst0[7] = 8'h64;
        dst0[8] = 8'h00; dst0[9] = 8'h00; dst0[10] = 8'h00; dst0[11] = 8'h00; dst0[12] = 8'h00; dst0[13] = 8'h00; dst0[14] = 8'h41; dst0[15] = 8'h00;
        dst0[16] = 8'h0b; dst0[17] = 8'h01; dst0[18] = 8'h62; dst0[19] = 8'h65; dst0[20] = 8'h65; dst0[21] = 8'h01; dst0[22] = 8'h6e; dst0[23] = 8'h00;
        dst0[24] = 8'h00; dst0[25] = 8'h00; dst0[26] = 8'h00; dst0[27] = 8'h00; dst0[28] = 8'h00; dst0[29] = 8'h42; dst0[30] = 8'h00; dst0[31] = 8'h0b;
        dst0[32] = 8'h01; dst0[33] = 8'h63; dst0[34] = 8'h61; dst0[35] = 8'h74; dst0[36] = 8'h01; dst0[37] = 8'h61; dst0[38] = 8'h00; dst0[39] = 8'h00;
        dst0[40] = 8'h00; dst0[41] = 8'h00; dst0[42] = 8'h00; dst0[43] = 8'h00; dst0[44] = 8'h58; dst0[45] = 8'h00; dst0[46] = 8'h00; dst0[47] = 8'h00;
        dst0[48] = 8'h00; dst0[49] = 8'h01; dst0[50] = 8'h00; dst0[51] = 8'h00; dst0[52] = 8'h00;

        dst1[0] = 8'h00; dst1[1] = 8'h0b; dst1[2] = 8'h01; dst1[3] = 8'h64; dst1[4] = 8'h6f; dst1[5] = 8'h67; dst1[6] = 8'h01; dst1[7] = 8'h5a;
        dst1[8] = 8'h00; dst1[9] = 8'h00; dst1[10] = 8'h00; dst1[11] = 8'h00; dst1[12] = 8'h00; dst1[13] = 8'h00; dst1[14] = 8'h44; dst1[15] = 8'h00;
        dst1[16] = 8'h0b; dst1[17] = 8'h01; dst1[18] = 8'h65; dst1[19] = 8'h65; dst1[20] = 8'h6c; dst1[21] = 8'h01; dst1[22] = 8'h50; dst1[23] = 8'h00;
        dst1[24] = 8'h00; dst1[25] = 8'h00; dst1[26] = 8'h00; dst1[27] = 8'h00; dst1[28] = 8'h00; dst1[29] = 8'h45; dst1[30] = 8'h00; dst1[31] = 8'h00;
        dst1[32] = 8'h00; dst1[33] = 8'h00; dst1[34] = 8'h01; dst1[35] = 8'h00; dst1[36] = 8'h00; dst1[37] = 8'h00;

        dst2[0] = 8'h00; dst2[1] = 8'h0b; dst2[2] = 8'h01; dst2[3] = 8'h66; dst2[4] = 8'h6f; dst2[5] = 8'h78; dst2[6] = 8'h01; dst2[7] = 8'h46;
        dst2[8] = 8'h00; dst2[9] = 8'h00; dst2[10] = 8'h00; dst2[11] = 8'h00; dst2[12] = 8'h00; dst2[13] = 8'h00; dst2[14] = 8'h46; dst2[15] = 8'h00;
        dst2[16] = 8'h00; dst2[17] = 8'h00; dst2[18] = 8'h00; dst2[19] = 8'h01; dst2[20] = 8'h00; dst2[21] = 8'h00; dst2[22] = 8'h00;

        for (i = 0; i < SRC0B0_BYTES; i = i + 1) begin
            mem_src0.mem[SRC0_ADDR0 + i] = src0b0[i];
        end
        for (i = 0; i < SRC0B1_BYTES; i = i + 1) begin
            mem_src0.mem[SRC0_ADDR1 + i] = src0b1[i];
        end
        for (i = 0; i < SRC0B2_BYTES; i = i + 1) begin
            mem_src0.mem[SRC0_ADDR2 + i] = src0b2[i];
        end
        for (i = 0; i < SRC1B0_BYTES; i = i + 1) begin
            mem_src1.mem[SRC1_ADDR0 + i] = src1b0[i];
        end
        for (i = 0; i < SRC1B1_BYTES; i = i + 1) begin
            mem_src1.mem[SRC1_ADDR1 + i] = src1b1[i];
        end
        for (i = 0; i < SRC1B2_BYTES; i = i + 1) begin
            mem_src1.mem[SRC1_ADDR2 + i] = src1b2[i];
        end

        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (5) @(posedge clk);
        @(negedge clk);
        start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;

        wait_cycles = 0;
        while (!done && !error && (wait_cycles < 8000)) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end

        if (wait_cycles >= 8000) begin
            $display("timeout waiting for nblock done");
            $display("top state=%0d busy=%0d done=%0d error=%0d active_block_index=%0d blocks_completed=%0d", dut.state, busy, done, error, active_block_index, blocks_completed);
            $finish_and_return(1);
        end
        if (error) begin
            $display("unexpected error");
            $finish_and_return(1);
        end
        if (blocks_completed !== 32'd3) begin
            $display("blocks_completed mismatch got=%0d", blocks_completed);
            $finish_and_return(1);
        end
        if (dst_output_block_bytes_vec[0 +: 32] !== DST0_BYTES) begin
            $display("dst0 bytes mismatch got=%0d exp=%0d", dst_output_block_bytes_vec[0 +: 32], DST0_BYTES);
            $finish_and_return(1);
        end
        if (dst_output_block_bytes_vec[32 +: 32] !== DST1_BYTES) begin
            $display("dst1 bytes mismatch got=%0d exp=%0d", dst_output_block_bytes_vec[32 +: 32], DST1_BYTES);
            $finish_and_return(1);
        end
        if (dst_output_block_bytes_vec[64 +: 32] !== DST2_BYTES) begin
            $display("dst2 bytes mismatch got=%0d exp=%0d", dst_output_block_bytes_vec[64 +: 32], DST2_BYTES);
            $finish_and_return(1);
        end
        if (total_source0_decoded_entry_count !== 32'd5) begin
            $display("total_source0_decoded_entry_count mismatch got=%0d", total_source0_decoded_entry_count);
            $finish_and_return(1);
        end
        if (total_source1_decoded_entry_count !== 32'd5) begin
            $display("total_source1_decoded_entry_count mismatch got=%0d", total_source1_decoded_entry_count);
            $finish_and_return(1);
        end
        if (total_source0_bytes_read !== (SRC0B0_BYTES + SRC0B1_BYTES + SRC0B2_BYTES)) begin
            $display("total_source0_bytes_read mismatch got=%0d", total_source0_bytes_read);
            $finish_and_return(1);
        end
        if (total_source1_bytes_read !== (SRC1B0_BYTES + SRC1B1_BYTES + SRC1B2_BYTES)) begin
            $display("total_source1_bytes_read mismatch got=%0d", total_source1_bytes_read);
            $finish_and_return(1);
        end
        if (total_merge_decoded_record_count !== 32'd10) begin
            $display("total_merge_decoded_record_count mismatch got=%0d", total_merge_decoded_record_count);
            $finish_and_return(1);
        end
        if (total_merge_merged_record_count !== 32'd6) begin
            $display("total_merge_merged_record_count mismatch got=%0d", total_merge_merged_record_count);
            $finish_and_return(1);
        end
        if (total_merge_dropped_superseded_count !== 32'd4) begin
            $display("total_merge_dropped_superseded_count mismatch got=%0d", total_merge_dropped_superseded_count);
            $finish_and_return(1);
        end
        if (total_stage5_input_record_count !== 32'd6) begin
            $display("total_stage5_input_record_count mismatch got=%0d", total_stage5_input_record_count);
            $finish_and_return(1);
        end
        if (total_stage5_encoded_entry_count !== 32'd6) begin
            $display("total_stage5_encoded_entry_count mismatch got=%0d", total_stage5_encoded_entry_count);
            $finish_and_return(1);
        end
        if (total_stage5_output_block_bytes !== (DST0_BYTES + DST1_BYTES + DST2_BYTES)) begin
            $display("total_stage5_output_block_bytes mismatch got=%0d", total_stage5_output_block_bytes);
            $finish_and_return(1);
        end
        if (total_stage5_bytes_written !== (DST0_BYTES + DST1_BYTES + DST2_BYTES)) begin
            $display("total_stage5_bytes_written mismatch got=%0d", total_stage5_bytes_written);
            $finish_and_return(1);
        end

        for (i = 0; i < DST0_BYTES; i = i + 1) begin
            if (mem_chain.mem[DST_ADDR0 + i] !== dst0[i]) begin
                $display("dst0 mismatch idx=%0d got=%02x exp=%02x", i, mem_chain.mem[DST_ADDR0 + i], dst0[i]);
                $finish_and_return(1);
            end
        end
        if (mem_chain.mem[DST_ADDR0 + DST0_BYTES] !== 8'hA5) begin
            $display("dst0 tail modified unexpectedly got=%02x", mem_chain.mem[DST_ADDR0 + DST0_BYTES]);
            $finish_and_return(1);
        end
        for (i = 0; i < DST1_BYTES; i = i + 1) begin
            if (mem_chain.mem[DST_ADDR1 + i] !== dst1[i]) begin
                $display("dst1 mismatch idx=%0d got=%02x exp=%02x", i, mem_chain.mem[DST_ADDR1 + i], dst1[i]);
                $finish_and_return(1);
            end
        end
        if (mem_chain.mem[DST_ADDR1 + DST1_BYTES] !== 8'hA5) begin
            $display("dst1 tail modified unexpectedly got=%02x", mem_chain.mem[DST_ADDR1 + DST1_BYTES]);
            $finish_and_return(1);
        end
        for (i = 0; i < DST2_BYTES; i = i + 1) begin
            if (mem_chain.mem[DST_ADDR2 + i] !== dst2[i]) begin
                $display("dst2 mismatch idx=%0d got=%02x exp=%02x", i, mem_chain.mem[DST_ADDR2 + i], dst2[i]);
                $finish_and_return(1);
            end
        end
        if (mem_chain.mem[DST_ADDR2 + DST2_BYTES] !== 8'hA5) begin
            $display("dst2 tail modified unexpectedly got=%02x", mem_chain.mem[DST_ADDR2 + DST2_BYTES]);
            $finish_and_return(1);
        end

        $display("PASS: nblock sequencer processed 3 block-pairs and preserved cross-block duplicate suppression through descriptor index 2");
        $finish_and_return(0);
    end
endmodule
