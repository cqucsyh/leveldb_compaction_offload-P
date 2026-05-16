`timescale 1ns / 1ps

module stage3_internal_key_merge_top #(
    parameter integer AXI_ADDR_WIDTH     = 64,
    parameter integer AXI_DATA_WIDTH     = 512,
    parameter integer AXI_ID_WIDTH       = 1,
    parameter integer MAX_BURST_LEN      = 16,
    parameter integer MAX_USER_KEY_BYTES = 64
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
    output wire                          record_keep,
    output wire [31:0]                   header_record_count,
    output wire [31:0]                   decoded_record_count,
    output wire [31:0]                   merged_record_count,
    output wire [31:0]                   dropped_superseded_count,
    output wire [31:0]                   value_record_count,
    output wire [31:0]                   delete_record_count,
    output wire [31:0]                   user_key_bytes_total,
    output wire [31:0]                   value_bytes_total,
    output wire [15:0]                   last_user_key_len,
    output wire [55:0]                   last_sequence,
    output wire [7:0]                    last_value_type,
    output wire                          last_record_keep,

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
    wire rd_error;
    wire merge_busy;
    wire merge_done;
    wire merge_error;

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
        .done(),
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

    pseudo_internal_key_merge_decoder #(
        .MAX_USER_KEY_BYTES(MAX_USER_KEY_BYTES)
    ) u_pseudo_internal_key_merge_decoder (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .s_axis_tdata(byte_tdata),
        .s_axis_tkeep(byte_tkeep),
        .s_axis_tlast(byte_tlast),
        .s_axis_tvalid(byte_tvalid),
        .s_axis_tready(byte_tready),
        .busy(merge_busy),
        .done(merge_done),
        .error(merge_error),
        .record_valid(record_valid),
        .record_keep(record_keep),
        .header_record_count(header_record_count),
        .decoded_record_count(decoded_record_count),
        .merged_record_count(merged_record_count),
        .dropped_superseded_count(dropped_superseded_count),
        .value_record_count(value_record_count),
        .delete_record_count(delete_record_count),
        .user_key_bytes_total(user_key_bytes_total),
        .value_bytes_total(value_bytes_total),
        .last_user_key_len(last_user_key_len),
        .last_sequence(last_sequence),
        .last_value_type(last_value_type),
        .last_record_keep(last_record_keep)
    );

    assign busy  = rd_busy | merge_busy;
    assign done  = merge_done;
    assign error = rd_error | merge_error;

endmodule
