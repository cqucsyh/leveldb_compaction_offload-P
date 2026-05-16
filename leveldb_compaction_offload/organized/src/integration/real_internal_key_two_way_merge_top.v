`timescale 1ns / 1ps

module real_internal_key_two_way_merge_top #(
    parameter integer MAX_USER_KEY_BYTES = 256,
    parameter integer MAX_KEY_BYTES      = 264,
    parameter integer MAX_VALUE_BYTES    = 1024,
    parameter integer MAX_RECORD_BYTES   = 2048,
    parameter integer MAX_RECORDS        = 256,
    parameter integer MAX_OUTPUT_BYTES   = 73728
) (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire        start,
    input  wire        seed_prev_user_key_valid,
    input  wire [15:0] seed_prev_user_key_len,
    input  wire [(MAX_USER_KEY_BYTES*8)-1:0] seed_prev_user_key,

    input  wire        source0_done,
    input  wire        s0_record_valid,
    output wire        s0_record_ready,
    input  wire [15:0] s0_record_key_len,
    input  wire [15:0] s0_record_value_len,
    input  wire [7:0]  s0_axis_tdata,
    input  wire [0:0]  s0_axis_tkeep,
    input  wire        s0_axis_tlast,
    input  wire        s0_axis_tvalid,
    output wire        s0_axis_tready,

    input  wire        source1_done,
    input  wire        s1_record_valid,
    output wire        s1_record_ready,
    input  wire [15:0] s1_record_key_len,
    input  wire [15:0] s1_record_value_len,
    input  wire [7:0]  s1_axis_tdata,
    input  wire [0:0]  s1_axis_tkeep,
    input  wire        s1_axis_tlast,
    input  wire        s1_axis_tvalid,
    output wire        s1_axis_tready,

    output wire        busy,
    output wire        done,
    output wire        error,
    output wire [31:0] output_byte_count,
    output wire [7:0]  m_axis_tdata,
    output wire [0:0]  m_axis_tkeep,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,

    output wire [31:0] merge_decoded_record_count,
    output wire [31:0] merge_merged_record_count,
    output wire [31:0] merge_dropped_superseded_count,
    output wire [31:0] merge_value_record_count,
    output wire [31:0] merge_delete_record_count,
    output wire [31:0] merge_user_key_bytes_total,
    output wire [31:0] merge_value_bytes_total,
    output wire [15:0] merge_last_user_key_len,
    output wire [55:0] merge_last_sequence,
    output wire [7:0]  merge_last_value_type,
    output wire        merge_last_record_keep,
    output wire        final_prev_user_key_valid,
    output wire [15:0] final_prev_user_key_len,
    output wire [(MAX_USER_KEY_BYTES*8)-1:0] final_prev_user_key
);

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

    real_internal_key_two_way_merge_decoder #(
        .MAX_USER_KEY_BYTES(MAX_USER_KEY_BYTES),
        .MAX_KEY_BYTES(MAX_KEY_BYTES),
        .MAX_VALUE_BYTES(MAX_VALUE_BYTES),
        .MAX_RECORD_BYTES(MAX_RECORD_BYTES)
    ) u_real_internal_key_two_way_merge_decoder (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .seed_prev_user_key_valid(seed_prev_user_key_valid),
        .seed_prev_user_key_len(seed_prev_user_key_len),
        .seed_prev_user_key(seed_prev_user_key),
        .source0_done(source0_done),
        .s0_record_valid(s0_record_valid),
        .s0_record_ready(s0_record_ready),
        .s0_record_key_len(s0_record_key_len),
        .s0_record_value_len(s0_record_value_len),
        .s0_axis_tdata(s0_axis_tdata),
        .s0_axis_tkeep(s0_axis_tkeep),
        .s0_axis_tlast(s0_axis_tlast),
        .s0_axis_tvalid(s0_axis_tvalid),
        .s0_axis_tready(s0_axis_tready),
        .source1_done(source1_done),
        .s1_record_valid(s1_record_valid),
        .s1_record_ready(s1_record_ready),
        .s1_record_key_len(s1_record_key_len),
        .s1_record_value_len(s1_record_value_len),
        .s1_axis_tdata(s1_axis_tdata),
        .s1_axis_tkeep(s1_axis_tkeep),
        .s1_axis_tlast(s1_axis_tlast),
        .s1_axis_tvalid(s1_axis_tvalid),
        .s1_axis_tready(s1_axis_tready),
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
        .last_record_keep(merge_last_record_keep),
        .final_prev_user_key_valid(final_prev_user_key_valid),
        .final_prev_user_key_len(final_prev_user_key_len),
        .final_prev_user_key(final_prev_user_key)
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

    assign busy  = merge_busy | buf_busy;
    assign done  = buf_done;
    assign error = merge_error | buf_error;

endmodule
