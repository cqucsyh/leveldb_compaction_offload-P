`timescale 1ns / 1ps

module stage4_real_internal_key_merge_writeback_top #(
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
    input  wire [AXI_ADDR_WIDTH-1:0]     dst_base_addr,
    output wire                          busy,
    output wire                          done,
    output wire                          error,
    output wire [31:0]                   bytes_read,
    output wire [31:0]                   beats_read,
    output wire [31:0]                   bytes_written,
    output wire [31:0]                   beats_written,
    output wire [31:0]                   output_byte_count,
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
    output wire                          m_axi_rready,

    output wire [AXI_ADDR_WIDTH-1:0]     m_axi_awaddr,
    output wire [7:0]                    m_axi_awlen,
    output wire [2:0]                    m_axi_awsize,
    output wire [1:0]                    m_axi_awburst,
    output wire [AXI_ID_WIDTH-1:0]       m_axi_awid,
    output wire                          m_axi_awvalid,
    input  wire                          m_axi_awready,
    output wire [AXI_DATA_WIDTH-1:0]     m_axi_wdata,
    output wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output wire                          m_axi_wlast,
    output wire                          m_axi_wvalid,
    input  wire                          m_axi_wready,
    input  wire [1:0]                    m_axi_bresp,
    input  wire [AXI_ID_WIDTH-1:0]       m_axi_bid,
    input  wire                          m_axi_bvalid,
    output wire                          m_axi_bready
);

    localparam integer AXI_KEEP_WIDTH = AXI_DATA_WIDTH / 8;

    wire [7:0]  merge_byte_tdata;
    wire [0:0]  merge_byte_tkeep;
    wire        merge_byte_tlast;
    wire        merge_byte_tvalid;
    wire        merge_byte_tready;

    wire [AXI_DATA_WIDTH-1:0] write_beat_tdata;
    wire [AXI_KEEP_WIDTH-1:0] write_beat_tkeep;
    wire                      write_beat_tlast;
    wire                      write_beat_tvalid;
    wire                      write_beat_tready;

    wire merge_top_busy;
    wire merge_top_done;
    wire merge_top_error;
    wire wr_busy;
    wire wr_done;
    wire wr_error;

    reg  merge_byte_tvalid_d;
    reg  wr_start_pulse_r;
    reg  wr_started;

    stage4_real_internal_key_merge_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .MAX_BLOCK_BYTES(MAX_BLOCK_BYTES),
        .MAX_KEY_BYTES(MAX_KEY_BYTES),
        .MAX_USER_KEY_BYTES(MAX_USER_KEY_BYTES),
        .MAX_VALUE_BYTES(MAX_VALUE_BYTES),
        .MAX_RECORD_BYTES(MAX_RECORD_BYTES),
        .MAX_RECORDS(MAX_RECORDS),
        .MAX_OUTPUT_BYTES(MAX_OUTPUT_BYTES)
    ) u_stage4_real_internal_key_merge_top (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .src_base_addr(src_base_addr),
        .src_byte_count(src_byte_count),
        .busy(merge_top_busy),
        .done(merge_top_done),
        .error(merge_top_error),
        .bytes_read(bytes_read),
        .beats_read(beats_read),
        .output_byte_count(output_byte_count),
        .m_axis_tdata(merge_byte_tdata),
        .m_axis_tkeep(merge_byte_tkeep),
        .m_axis_tlast(merge_byte_tlast),
        .m_axis_tvalid(merge_byte_tvalid),
        .m_axis_tready(merge_byte_tready),
        .stage4_decoded_entry_count(stage4_decoded_entry_count),
        .stage4_restart_count(stage4_restart_count),
        .stage4_restart_entry_count(stage4_restart_entry_count),
        .stage4_shared_key_bytes_total(stage4_shared_key_bytes_total),
        .stage4_unshared_key_bytes_total(stage4_unshared_key_bytes_total),
        .stage4_value_bytes_total(stage4_value_bytes_total),
        .stage4_last_key_len(stage4_last_key_len),
        .stage4_last_value_len(stage4_last_value_len),
        .stage4_last_shared_bytes(stage4_last_shared_bytes),
        .stage4_last_non_shared_bytes(stage4_last_non_shared_bytes),
        .stage4_restart_array_offset(stage4_restart_array_offset),
        .merge_decoded_record_count(merge_decoded_record_count),
        .merge_merged_record_count(merge_merged_record_count),
        .merge_dropped_superseded_count(merge_dropped_superseded_count),
        .merge_value_record_count(merge_value_record_count),
        .merge_delete_record_count(merge_delete_record_count),
        .merge_user_key_bytes_total(merge_user_key_bytes_total),
        .merge_value_bytes_total(merge_value_bytes_total),
        .merge_last_user_key_len(merge_last_user_key_len),
        .merge_last_sequence(merge_last_sequence),
        .merge_last_value_type(merge_last_value_type),
        .merge_last_record_keep(merge_last_record_keep),
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

    stream_pack_adapter #(
        .IN_DATA_WIDTH(8),
        .IN_KEEP_WIDTH(1),
        .OUT_DATA_WIDTH(AXI_DATA_WIDTH),
        .OUT_KEEP_WIDTH(AXI_KEEP_WIDTH)
    ) u_stream_pack_adapter (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .s_axis_tdata(merge_byte_tdata),
        .s_axis_tkeep(merge_byte_tkeep),
        .s_axis_tlast(merge_byte_tlast),
        .s_axis_tvalid(merge_byte_tvalid),
        .s_axis_tready(merge_byte_tready),
        .m_axis_tdata(write_beat_tdata),
        .m_axis_tkeep(write_beat_tkeep),
        .m_axis_tlast(write_beat_tlast),
        .m_axis_tvalid(write_beat_tvalid),
        .m_axis_tready(write_beat_tready)
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
        .start(wr_start_pulse_r),
        .base_addr(dst_base_addr),
        .byte_count(output_byte_count),
        .busy(wr_busy),
        .done(wr_done),
        .error(wr_error),
        .bytes_written(bytes_written),
        .beats_written(beats_written),
        .s_axis_tdata(write_beat_tdata),
        .s_axis_tkeep(write_beat_tkeep),
        .s_axis_tlast(write_beat_tlast),
        .s_axis_tvalid(write_beat_tvalid),
        .s_axis_tready(write_beat_tready),
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

    always @(posedge clk) begin
        if (!rstn) begin
            merge_byte_tvalid_d <= 1'b0;
            wr_start_pulse_r    <= 1'b0;
            wr_started          <= 1'b0;
        end else if (clear) begin
            merge_byte_tvalid_d <= 1'b0;
            wr_start_pulse_r    <= 1'b0;
            wr_started          <= 1'b0;
        end else begin
            wr_start_pulse_r <= 1'b0;
            merge_byte_tvalid_d <= merge_byte_tvalid;

            if (start && !busy) begin
                wr_started <= 1'b0;
            end else if (!wr_started && merge_byte_tvalid && !merge_byte_tvalid_d) begin
                wr_start_pulse_r <= 1'b1;
                wr_started <= 1'b1;
            end
        end
    end

    assign busy  = merge_top_busy | wr_busy;
    assign done  = wr_done;
    assign error = merge_top_error | wr_error;

endmodule
