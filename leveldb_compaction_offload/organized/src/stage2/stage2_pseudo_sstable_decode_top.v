`timescale 1ns / 1ps

module stage2_pseudo_sstable_decode_top #(
    parameter integer AXI_ADDR_WIDTH = 64,
    parameter integer AXI_DATA_WIDTH = 512,
    parameter integer AXI_ID_WIDTH   = 1,
    parameter integer MAX_BURST_LEN  = 16
) (
    input  wire                          clk,
    input  wire                          rstn,
    input  wire                          clear,
    input  wire                          start,
    input  wire [AXI_ADDR_WIDTH-1:0]     src_base_addr,
    input  wire [31:0]                   byte_count,
    output wire                          busy,
    output wire                          done,
    output wire                          error,
    output wire [31:0]                   bytes_read,
    output wire [31:0]                   beats_read,
    output wire                          record_valid,
    output wire [31:0]                   header_record_count,
    output wire [31:0]                   decoded_record_count,
    output wire [31:0]                   put_record_count,
    output wire [31:0]                   delete_record_count,
    output wire [31:0]                   key_bytes_total,
    output wire [31:0]                   value_bytes_total,
    output wire [15:0]                   last_key_len,
    output wire [15:0]                   last_value_len,
    output wire                          last_record_delete,

    output wire [AXI_ADDR_WIDTH-1:0]     m_axi_araddr,
    output wire [7:0]                    m_axi_arlen,
    output wire [2:0]                    m_axi_arsize,
    output wire [1:0]                    m_axi_arburst,
    output wire [AXI_ID_WIDTH-1:0]       m_axi_arid,
    output wire                          m_axi_arvalid,
    input  wire                          m_axi_arready,
    input  wire [AXI_DATA_WIDTH-1:0]     m_axi_rdata,
    input  wire [1:0]                    m_axi_rresp,
    input  wire                          m_axi_rlast,
    input  wire [AXI_ID_WIDTH-1:0]       m_axi_rid,
    input  wire                          m_axi_rvalid,
    output wire                          m_axi_rready
);

    localparam integer AXI_KEEP_WIDTH = AXI_DATA_WIDTH / 8;

    wire [AXI_DATA_WIDTH-1:0] beat_tdata;
    wire [AXI_KEEP_WIDTH-1:0] beat_tkeep;
    wire                      beat_tlast;
    wire                      beat_tvalid;
    wire                      beat_tready;

    wire [7:0]                byte_tdata;
    wire [0:0]                byte_tkeep;
    wire                      byte_tlast;
    wire                      byte_tvalid;
    wire                      byte_tready;

    wire rd_busy;
    wire rd_done;
    wire rd_error;
    wire dec_busy;
    wire dec_done;
    wire dec_error;

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
        .m_axis_tdata(beat_tdata),
        .m_axis_tkeep(beat_tkeep),
        .m_axis_tlast(beat_tlast),
        .m_axis_tvalid(beat_tvalid),
        .m_axis_tready(beat_tready)
    );

    stream_width_adapter #(
        .IN_DATA_WIDTH(AXI_DATA_WIDTH),
        .IN_KEEP_WIDTH(AXI_KEEP_WIDTH),
        .OUT_DATA_WIDTH(8),
        .OUT_KEEP_WIDTH(1)
    ) u_stream_width_adapter (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .s_axis_tdata(beat_tdata),
        .s_axis_tkeep(beat_tkeep),
        .s_axis_tlast(beat_tlast),
        .s_axis_tvalid(beat_tvalid),
        .s_axis_tready(beat_tready),
        .m_axis_tdata(byte_tdata),
        .m_axis_tkeep(byte_tkeep),
        .m_axis_tlast(byte_tlast),
        .m_axis_tvalid(byte_tvalid),
        .m_axis_tready(byte_tready)
    );

    pseudo_sstable_decoder u_pseudo_sstable_decoder (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .s_axis_tdata(byte_tdata),
        .s_axis_tkeep(byte_tkeep),
        .s_axis_tlast(byte_tlast),
        .s_axis_tvalid(byte_tvalid),
        .s_axis_tready(byte_tready),
        .busy(dec_busy),
        .done(dec_done),
        .error(dec_error),
        .record_valid(record_valid),
        .header_record_count(header_record_count),
        .decoded_record_count(decoded_record_count),
        .put_record_count(put_record_count),
        .delete_record_count(delete_record_count),
        .key_bytes_total(key_bytes_total),
        .value_bytes_total(value_bytes_total),
        .last_key_len(last_key_len),
        .last_value_len(last_value_len),
        .last_record_delete(last_record_delete)
    );

    assign busy  = rd_busy | dec_busy;
    assign done  = dec_done;
    assign error = rd_error | dec_error;

endmodule
