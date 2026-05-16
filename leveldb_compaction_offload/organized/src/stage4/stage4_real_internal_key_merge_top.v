`timescale 1ns / 1ps

module stage4_real_internal_key_merge_top #(
    parameter integer AXI_ADDR_WIDTH      = 64,
    parameter integer AXI_DATA_WIDTH      = 512,
    parameter integer AXI_ID_WIDTH        = 1,
    parameter integer MAX_BURST_LEN       = 16,
    parameter integer MAX_BLOCK_BYTES     = 4096,
    parameter integer MAX_KEY_BYTES       = 264,
    parameter integer MAX_USER_KEY_BYTES  = 256,
    parameter integer MAX_VALUE_BYTES     = 1024,
    parameter integer MAX_RECORD_BYTES    = 2048,
    parameter integer MAX_RECORDS         = 256,
    parameter integer MAX_OUTPUT_BYTES    = 73728
) (
    input  wire                          clk,
    input  wire                          rstn,
    input  wire                          clear,
    input  wire                          start,
    input  wire [AXI_ADDR_WIDTH-1:0]     src_base_addr,
    input  wire [31:0]                   src_byte_count,
    output wire                          busy,
    output wire                          done,
    output wire                          error,
    output wire [31:0]                   bytes_read,
    output wire [31:0]                   beats_read,
    output wire [31:0]                   output_byte_count,
    output wire [7:0]                    m_axis_tdata,
    output wire [0:0]                    m_axis_tkeep,
    output wire                          m_axis_tlast,
    output wire                          m_axis_tvalid,
    input  wire                          m_axis_tready,
    output wire [31:0]                   stage4_decoded_entry_count,
    output wire [31:0]                   stage4_restart_count,
    output wire [31:0]                   stage4_restart_entry_count,
    output wire [31:0]                   stage4_shared_key_bytes_total,
    output wire [31:0]                   stage4_unshared_key_bytes_total,
    output wire [31:0]                   stage4_value_bytes_total,
    output wire [15:0]                   stage4_last_key_len,
    output wire [15:0]                   stage4_last_value_len,
    output wire [15:0]                   stage4_last_shared_bytes,
    output wire [15:0]                   stage4_last_non_shared_bytes,
    output wire [31:0]                   stage4_restart_array_offset,
    output wire [31:0]                   merge_decoded_record_count,
    output wire [31:0]                   merge_merged_record_count,
    output wire [31:0]                   merge_dropped_superseded_count,
    output wire [31:0]                   merge_value_record_count,
    output wire [31:0]                   merge_delete_record_count,
    output wire [31:0]                   merge_user_key_bytes_total,
    output wire [31:0]                   merge_value_bytes_total,
    output wire [15:0]                   merge_last_user_key_len,
    output wire [55:0]                   merge_last_sequence,
    output wire [7:0]                    merge_last_value_type,
    output wire                          merge_last_record_keep,

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

    wire        emit_busy;
    wire        emit_done;
    wire        emit_error;
    wire        emit_record_valid;
    wire        emit_record_ready;
    wire [15:0] emit_record_key_len;
    wire [15:0] emit_record_value_len;
    wire [15:0] emit_record_shared_bytes;
    wire [15:0] emit_record_non_shared_bytes;
    wire [7:0]  emit_record_tdata;
    wire [0:0]  emit_record_tkeep;
    wire        emit_record_tlast;
    wire        emit_record_tvalid;
    wire        emit_record_tready;

    wire        merge_busy;
    wire        merge_done;
    wire        merge_error;
    wire        merge_record_valid;
    wire        merge_record_ready;
    wire [15:0] merge_record_key_len;
    wire [15:0] merge_record_value_len;
    wire [7:0]  merge_record_tdata;
    wire [0:0]  merge_record_tkeep;
    wire        merge_record_tlast;
    wire        merge_record_tvalid;
    wire        merge_record_tready;

    wire        buf_busy;
    wire        buf_done;
    wire        buf_error;

    stage4_real_data_block_record_emit_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .MAX_BLOCK_BYTES(MAX_BLOCK_BYTES),
        .MAX_KEY_BYTES(MAX_KEY_BYTES)
    ) u_stage4_record_emit (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .src_base_addr(src_base_addr),
        .byte_count(src_byte_count),
        .busy(emit_busy),
        .done(emit_done),
        .error(emit_error),
        .bytes_read(bytes_read),
        .beats_read(beats_read),
        .record_valid(emit_record_valid),
        .record_ready(emit_record_ready),
        .record_key_len(emit_record_key_len),
        .record_value_len(emit_record_value_len),
        .record_shared_bytes(emit_record_shared_bytes),
        .record_non_shared_bytes(emit_record_non_shared_bytes),
        .record_tdata(emit_record_tdata),
        .record_tkeep(emit_record_tkeep),
        .record_tlast(emit_record_tlast),
        .record_tvalid(emit_record_tvalid),
        .record_tready(emit_record_tready),
        .decoded_entry_count(stage4_decoded_entry_count),
        .restart_count(stage4_restart_count),
        .restart_entry_count(stage4_restart_entry_count),
        .shared_key_bytes_total(stage4_shared_key_bytes_total),
        .unshared_key_bytes_total(stage4_unshared_key_bytes_total),
        .value_bytes_total(stage4_value_bytes_total),
        .last_key_len(stage4_last_key_len),
        .last_value_len(stage4_last_value_len),
        .last_shared_bytes(stage4_last_shared_bytes),
        .last_non_shared_bytes(stage4_last_non_shared_bytes),
        .restart_array_offset(stage4_restart_array_offset),
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
        .m_axi_rready(m_axi_rready)
    );

    real_internal_key_merge_decoder #(
        .MAX_USER_KEY_BYTES(MAX_USER_KEY_BYTES),
        .MAX_KEY_BYTES(MAX_KEY_BYTES),
        .MAX_VALUE_BYTES(MAX_VALUE_BYTES),
        .MAX_RECORD_BYTES(MAX_RECORD_BYTES)
    ) u_real_internal_key_merge_decoder (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .source_done(emit_done),
        .s_record_valid(emit_record_valid),
        .s_record_ready(emit_record_ready),
        .s_record_key_len(emit_record_key_len),
        .s_record_value_len(emit_record_value_len),
        .s_axis_tdata(emit_record_tdata),
        .s_axis_tkeep(emit_record_tkeep),
        .s_axis_tlast(emit_record_tlast),
        .s_axis_tvalid(emit_record_tvalid),
        .s_axis_tready(emit_record_tready),
        .m_record_valid(merge_record_valid),
        .m_record_ready(merge_record_ready),
        .m_record_key_len(merge_record_key_len),
        .m_record_value_len(merge_record_value_len),
        .m_axis_tdata(merge_record_tdata),
        .m_axis_tkeep(merge_record_tkeep),
        .m_axis_tlast(merge_record_tlast),
        .m_axis_tvalid(merge_record_tvalid),
        .m_axis_tready(merge_record_tready),
        .busy(merge_busy),
        .done(merge_done),
        .error(merge_error),
        .decoded_record_count(merge_decoded_record_count),
        .merged_record_count(merge_merged_record_count),
        .dropped_superseded_count(merge_dropped_superseded_count),
        .value_record_count(merge_value_record_count),
        .delete_record_count(merge_delete_record_count),
        .user_key_bytes_total(merge_user_key_bytes_total),
        .value_bytes_total(merge_value_bytes_total),
        .last_user_key_len(merge_last_user_key_len),
        .last_sequence(merge_last_sequence),
        .last_value_type(merge_last_value_type),
        .last_record_keep(merge_last_record_keep)
    );

    record_emit_counted_buffer #(
        .MAX_RECORDS(MAX_RECORDS),
        .MAX_OUTPUT_BYTES(MAX_OUTPUT_BYTES)
    ) u_record_emit_counted_buffer (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .source_done(merge_done),
        .busy(buf_busy),
        .done(buf_done),
        .error(buf_error),
        .record_valid(merge_record_valid),
        .record_ready(merge_record_ready),
        .record_key_len(merge_record_key_len),
        .record_value_len(merge_record_value_len),
        .s_axis_tdata(merge_record_tdata),
        .s_axis_tkeep(merge_record_tkeep),
        .s_axis_tlast(merge_record_tlast),
        .s_axis_tvalid(merge_record_tvalid),
        .s_axis_tready(merge_record_tready),
        .output_byte_count(output_byte_count),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready)
    );

    assign busy  = emit_busy | merge_busy | buf_busy;
    assign done  = buf_done;
    assign error = emit_error | merge_error | buf_error;

endmodule
