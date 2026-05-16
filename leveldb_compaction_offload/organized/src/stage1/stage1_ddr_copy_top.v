`timescale 1ns / 1ps

module stage1_ddr_copy_top #(
    parameter integer AXI_ADDR_WIDTH = 64,
    parameter integer AXI_DATA_WIDTH = 512,
    parameter integer AXI_ID_WIDTH   = 1,
    parameter integer MAX_BURST_LEN  = 16,
    parameter integer FIFO_DEPTH     = 32
) (
    input  wire                              clk,
    input  wire                              rstn,
    input  wire                              clear,
    input  wire                              start,
    input  wire [AXI_ADDR_WIDTH-1:0]         src_base_addr,
    input  wire [AXI_ADDR_WIDTH-1:0]         dst_base_addr,
    input  wire [31:0]                       byte_count,
    output wire                              busy,
    output wire                              done,
    output wire                              error,
    output wire [31:0]                       bytes_read,
    output wire [31:0]                       bytes_written,
    output wire [31:0]                       beats_read,
    output wire [31:0]                       beats_written,
    output wire [$clog2(FIFO_DEPTH+1)-1:0]   fifo_occupancy,

    output wire [AXI_ADDR_WIDTH-1:0]         m_axi_araddr,
    output wire [7:0]                        m_axi_arlen,
    output wire [2:0]                        m_axi_arsize,
    output wire [1:0]                        m_axi_arburst,
    output wire [AXI_ID_WIDTH-1:0]           m_axi_arid,
    output wire                              m_axi_arvalid,
    input  wire                              m_axi_arready,
    input  wire [AXI_DATA_WIDTH-1:0]         m_axi_rdata,
    input  wire [1:0]                        m_axi_rresp,
    input  wire                              m_axi_rlast,
    input  wire [AXI_ID_WIDTH-1:0]           m_axi_rid,
    input  wire                              m_axi_rvalid,
    output wire                              m_axi_rready,

    output wire [AXI_ADDR_WIDTH-1:0]         m_axi_awaddr,
    output wire [7:0]                        m_axi_awlen,
    output wire [2:0]                        m_axi_awsize,
    output wire [1:0]                        m_axi_awburst,
    output wire [AXI_ID_WIDTH-1:0]           m_axi_awid,
    output wire                              m_axi_awvalid,
    input  wire                              m_axi_awready,
    output wire [AXI_DATA_WIDTH-1:0]         m_axi_wdata,
    output wire [(AXI_DATA_WIDTH/8)-1:0]     m_axi_wstrb,
    output wire                              m_axi_wlast,
    output wire                              m_axi_wvalid,
    input  wire                              m_axi_wready,
    input  wire [1:0]                        m_axi_bresp,
    input  wire [AXI_ID_WIDTH-1:0]           m_axi_bid,
    input  wire                              m_axi_bvalid,
    output wire                              m_axi_bready
);

    localparam integer AXI_KEEP_WIDTH = AXI_DATA_WIDTH / 8;
    localparam integer FIFO_DATA_WIDTH = AXI_DATA_WIDTH + AXI_KEEP_WIDTH + 1;

    wire [AXI_DATA_WIDTH-1:0]     rd_tdata;
    wire [AXI_KEEP_WIDTH-1:0]     rd_tkeep;
    wire                          rd_tlast;
    wire                          rd_tvalid;
    wire                          rd_tready;

    wire [FIFO_DATA_WIDTH-1:0]    fifo_in_data;
    wire [FIFO_DATA_WIDTH-1:0]    fifo_out_data;
    wire                          fifo_in_ready;
    wire                          fifo_out_valid;
    wire                          fifo_out_ready;
    wire                          rd_tlast_fifo;
    wire [AXI_KEEP_WIDTH-1:0]     rd_tkeep_fifo;
    wire [AXI_DATA_WIDTH-1:0]     rd_tdata_fifo;

    wire                          rd_busy;
    wire                          rd_done;
    wire                          rd_error;
    wire                          wr_busy;
    wire                          wr_done;
    wire                          wr_error;

    assign fifo_in_data = {rd_tlast, rd_tkeep, rd_tdata};
    assign {rd_tlast_fifo, rd_tkeep_fifo, rd_tdata_fifo} = fifo_out_data;

    axi_read_engine #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN)
    ) u_axi_read_engine (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .base_addr(src_base_addr),
        .byte_count(byte_count),
        .busy(rd_busy),
        .done(rd_done),
        .error(rd_error),
        .bytes_read(bytes_read),
        .beats_read(beats_read),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arid(m_axi_arid),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rid(m_axi_rid),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axis_tdata(rd_tdata),
        .m_axis_tkeep(rd_tkeep),
        .m_axis_tlast(rd_tlast),
        .m_axis_tvalid(rd_tvalid),
        .m_axis_tready(rd_tready)
    );

    stream_fifo #(
        .DATA_WIDTH(FIFO_DATA_WIDTH),
        .DEPTH(FIFO_DEPTH)
    ) u_stream_fifo (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .s_data(fifo_in_data),
        .s_valid(rd_tvalid),
        .s_ready(rd_tready),
        .m_data(fifo_out_data),
        .m_valid(fifo_out_valid),
        .m_ready(fifo_out_ready),
        .occupancy(fifo_occupancy)
    );

    axi_write_engine #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN)
    ) u_axi_write_engine (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .base_addr(dst_base_addr),
        .byte_count(byte_count),
        .busy(wr_busy),
        .done(wr_done),
        .error(wr_error),
        .bytes_written(bytes_written),
        .beats_written(beats_written),
        .s_axis_tdata(rd_tdata_fifo),
        .s_axis_tkeep(rd_tkeep_fifo),
        .s_axis_tlast(rd_tlast_fifo),
        .s_axis_tvalid(fifo_out_valid),
        .s_axis_tready(fifo_out_ready),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awid(m_axi_awid),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bid(m_axi_bid),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready)
    );

    assign busy  = rd_busy | wr_busy;
    assign done  = wr_done;
    assign error = rd_error | wr_error;

endmodule
