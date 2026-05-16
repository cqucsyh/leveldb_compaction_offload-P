`ifdef DEAD_MERGE_PIPE
// ---------- cmpct_merge_pipe inlined into cmpct_pair_chain ----------
`timescale 1ns / 1ps

module cmpct_merge_pipe #(
    parameter integer AXI_ADDR_WIDTH              = 64,
    parameter integer AXI_DATA_WIDTH              = 512,
    parameter integer AXI_ID_WIDTH                = 1,
    parameter integer MAX_BURST_LEN               = 16,
    parameter integer MERGE_MAX_USER_KEY_BYTES    = 64,
    parameter integer MERGE_MAX_KEY_BYTES         = 72,
    parameter integer MERGE_MAX_VALUE_BYTES       = 1024,
    parameter integer MERGE_MAX_RECORD_BYTES      = 2048,
    parameter integer MERGE_MAX_RECORDS           = 256,
    parameter integer MERGE_MAX_OUTPUT_BYTES      = 73728,
    parameter integer STAGE5_MAX_RECORDS          = 256,
    parameter integer STAGE5_MAX_PAYLOAD_BYTES    = 4096,
    parameter integer STAGE5_MAX_BLOCK_BYTES      = 4096,
    parameter integer STAGE5_MAX_KEY_BYTES        = 64,
    parameter integer STAGE5_MAX_VALUE_BYTES      = 1024,
    parameter integer STAGE5_RESTART_INTERVAL     = 16
) (
    input  wire                          clk,
    input  wire                          rstn,
    input  wire                          clear,
    input  wire                          start,
    // OPT-BP1: partial clear/start for block-pair pipelining
    input  wire                          front_clear,
    input  wire                          front_start,
    input  wire                          seed_prev_user_key_valid,
    input  wire [15:0]                   seed_prev_user_key_len,
    input  wire [(MERGE_MAX_USER_KEY_BYTES*8)-1:0] seed_prev_user_key,

    input  wire                          source0_done,
    input  wire                          s0_record_valid,
    output wire                          s0_record_ready,
    input  wire [15:0]                   s0_record_key_len,
    input  wire [15:0]                   s0_record_value_len,
    // OPT-D3: 32-bit record byte streams from decoders
    input  wire [31:0]                   s0_axis_tdata,
    input  wire [3:0]                    s0_axis_tkeep,
    input  wire                          s0_axis_tlast,
    input  wire                          s0_axis_tvalid,
    output wire                          s0_axis_tready,

    input  wire                          source1_done,
    input  wire                          s1_record_valid,
    output wire                          s1_record_ready,
    input  wire [15:0]                   s1_record_key_len,
    input  wire [15:0]                   s1_record_value_len,
    input  wire [31:0]                   s1_axis_tdata,
    input  wire [3:0]                    s1_axis_tkeep,
    input  wire                          s1_axis_tlast,
    input  wire                          s1_axis_tvalid,
    output wire                          s1_axis_tready,

    input  wire [AXI_ADDR_WIDTH-1:0]     mid_base_addr,
    input  wire [AXI_ADDR_WIDTH-1:0]     dst_base_addr,
    output wire                          busy,
    output wire                          done,
    output wire                          error,
    output wire                          merge_done,
    output wire                          stage5_done,
    output wire [31:0]                   merge_bytes_written,
    output wire [31:0]                   merge_beats_written,
    output wire [31:0]                   merge_output_byte_count,
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
    output wire [31:0]                   stage5_bytes_read,
    output wire [31:0]                   stage5_beats_read,
    output wire [31:0]                   stage5_bytes_written,
    output wire [31:0]                   stage5_beats_written,
    output wire [31:0]                   stage5_input_record_count,
    output wire [31:0]                   stage5_encoded_entry_count,
    output wire [31:0]                   stage5_restart_count,
    output wire [31:0]                   stage5_shared_key_bytes_total,
    output wire [31:0]                   stage5_unshared_key_bytes_total,
    output wire [31:0]                   stage5_value_bytes_total,
    output wire [15:0]                              stage5_last_key_len,
    output wire [(STAGE5_MAX_KEY_BYTES*8)-1:0]       stage5_last_key_bytes,
    output wire [15:0]                              stage5_last_value_len,
    output wire [15:0]                              stage5_last_shared_bytes,
    output wire [15:0]                              stage5_last_non_shared_bytes,
    output wire [31:0]                              stage5_output_block_bytes,
    output wire                          final_prev_user_key_valid,
    output wire [15:0]                   final_prev_user_key_len,
    output wire [(MERGE_MAX_USER_KEY_BYTES*8)-1:0] final_prev_user_key,
    // OPT-BP1: expose encoder done for block-pair pipelining
    output wire                          enc_done_out,

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

    // OPT-W1: 32-bit wide data path
    wire [31:0] merge_byte_tdata;
    wire [3:0]  merge_byte_tkeep;
    wire        merge_byte_tlast;
    wire        merge_byte_tvalid;
    wire        merge_byte_tready;

    // OPT-A2: decoupling FIFO between merger output and encoder input (OPT-W1: 37-bit)
    wire [31:0] fifo_byte_tdata;
    wire [3:0]  fifo_byte_tkeep;
    wire        fifo_byte_tlast;
    wire        fifo_byte_tvalid;
    wire        fifo_byte_tready;

    // Record-stream bridge: merger -> encoder (Opt-A: no counted-buffer)
    wire        merge_record_valid;
    wire        merge_record_ready;
    wire [15:0] merge_record_key_len;
    wire [15:0] merge_record_value_len;

    // OPT-W1: 8-bit wires between width adapter and encoder
    wire [7:0]  enc_in_tdata;
    wire [0:0]  enc_in_tkeep;
    wire        enc_in_tlast;
    wire        enc_in_tvalid;
    wire        enc_in_tready;

    // 8-bit encoder output
    wire [7:0]  enc_out_tdata;
    wire [0:0]  enc_out_tkeep;
    wire        enc_out_tlast;
    wire        enc_out_tvalid;
    wire        enc_out_tready;

    // 32-bit packed encoder output to enc_out FIFO
    wire [31:0] enc_byte_tdata;
    wire [3:0]  enc_byte_tkeep;
    wire        enc_byte_tlast;
    wire        enc_byte_tvalid;
    wire        enc_byte_tready;

    // OPT-2C: FIFO between encoder output and trailer_appender (OPT-W1: 37-bit)
    wire [31:0] enc_fifo_tdata;
    wire [3:0]  enc_fifo_tkeep;
    wire        enc_fifo_tlast;
    wire        enc_fifo_tvalid;
    wire        enc_fifo_tready;

    wire [31:0] trail_byte_tdata;
    wire [3:0]  trail_byte_tkeep;
    wire        trail_byte_tlast;
    wire        trail_byte_tvalid;
    wire        trail_byte_tready;

    // Trail-side repack: serialize variable-tkeep trailer output to bytes,
    // then repack into dense 32-bit words before the 32→AXI pack adapter
    wire [7:0]  trail_ser_tdata;
    wire [0:0]  trail_ser_tkeep;
    wire        trail_ser_tlast;
    wire        trail_ser_tvalid;
    wire        trail_ser_tready;

    wire [31:0] trail_dense_tdata;
    wire [3:0]  trail_dense_tkeep;
    wire        trail_dense_tlast;
    wire        trail_dense_tvalid;
    wire        trail_dense_tready;

    wire [AXI_DATA_WIDTH-1:0] write_beat_tdata;
    wire [AXI_KEEP_WIDTH-1:0] write_beat_tkeep;
    wire                      write_beat_tlast;
    wire                      write_beat_tvalid;
    wire                      write_beat_tready;

    wire merge_top_busy;
    wire merge_top_done;
    wire merge_top_error;
    wire enc_busy;
    wire enc_done;
    wire enc_error;
    wire wr_busy;
    wire wr_done;
    wire wr_error;

    reg  wr_start_pulse_r;
    reg  wr_started;
    reg  write_beat_tvalid_d;

    cmpct_merger #(
        .MAX_USER_KEY_BYTES(MERGE_MAX_USER_KEY_BYTES),
        .MAX_KEY_BYTES(MERGE_MAX_KEY_BYTES),
        .MAX_VALUE_BYTES(MERGE_MAX_VALUE_BYTES),
        .MAX_RECORD_BYTES(MERGE_MAX_RECORD_BYTES)
    ) u_merger (
        .clk(clk),
        .rstn(rstn),
        .clear(clear || front_clear),
        .start(start || front_start),
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
        .busy(merge_top_busy),
        .done(merge_top_done),
        .error(merge_top_error),
        .output_byte_count(merge_output_byte_count),
        .m_record_valid(merge_record_valid),
        .m_record_ready(merge_record_ready),
        .m_record_key_len(merge_record_key_len),
        .m_record_value_len(merge_record_value_len),
        .m_axis_tdata(merge_byte_tdata),
        .m_axis_tkeep(merge_byte_tkeep),
        .m_axis_tlast(merge_byte_tlast),
        .m_axis_tvalid(merge_byte_tvalid),
        .m_axis_tready(merge_byte_tready),
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

    // OPT-A2 + OPT-W1: 37-bit stream_fifo (32 data + 4 keep + 1 last)
    stream_fifo #(
        .DATA_WIDTH(37),
        .DEPTH(64)
    ) u_merge_enc_fifo (
        .clk(clk),
        .rstn(rstn),
        .clear(clear || front_clear),
        .s_data({merge_byte_tdata, merge_byte_tkeep, merge_byte_tlast}),
        .s_valid(merge_byte_tvalid),
        .s_ready(merge_byte_tready),
        .m_data({fifo_byte_tdata, fifo_byte_tkeep, fifo_byte_tlast}),
        .m_valid(fifo_byte_tvalid),
        .m_ready(fifo_byte_tready),
        .occupancy()
    );

    // OPT-W1: Width adapter (32→8) between merge_enc FIFO and encoder
    stream_width_adapter #(
        .IN_DATA_WIDTH(32),
        .OUT_DATA_WIDTH(8)
    ) u_fifo_to_enc_w32to8 (
        .clk(clk), .rstn(rstn), .clear(clear || front_clear),
        .s_axis_tdata(fifo_byte_tdata),
        .s_axis_tkeep(fifo_byte_tkeep),
        .s_axis_tlast(fifo_byte_tlast),
        .s_axis_tvalid(fifo_byte_tvalid),
        .s_axis_tready(fifo_byte_tready),
        .m_axis_tdata(enc_in_tdata),
        .m_axis_tkeep(enc_in_tkeep),
        .m_axis_tlast(enc_in_tlast),
        .m_axis_tvalid(enc_in_tvalid),
        .m_axis_tready(enc_in_tready)
    );

    cmpct_block_encoder #(
        .MAX_RECORDS(STAGE5_MAX_RECORDS),
        .MAX_PAYLOAD_BYTES(STAGE5_MAX_PAYLOAD_BYTES),
        .MAX_BLOCK_BYTES(STAGE5_MAX_BLOCK_BYTES),
        .MAX_KEY_BYTES(STAGE5_MAX_KEY_BYTES),
        .MAX_VALUE_BYTES(STAGE5_MAX_VALUE_BYTES),
        .RESTART_INTERVAL(STAGE5_RESTART_INTERVAL)
    ) u_cmpct_block_encoder (
        .clk(clk),
        .rstn(rstn),
        .clear(clear || front_clear),
        .start(start || front_start),
        .s_record_valid(merge_record_valid),
        .s_record_ready(merge_record_ready),
        .s_record_key_len(merge_record_key_len),
        .s_record_value_len(merge_record_value_len),
        .source_done(merge_top_done),
        .s_axis_tdata(enc_in_tdata),
        .s_axis_tkeep(enc_in_tkeep),
        .s_axis_tlast(enc_in_tlast),
        .s_axis_tvalid(enc_in_tvalid),
        .s_axis_tready(enc_in_tready),
        .m_axis_tdata(enc_out_tdata),
        .m_axis_tkeep(enc_out_tkeep),
        .m_axis_tlast(enc_out_tlast),
        .m_axis_tvalid(enc_out_tvalid),
        .m_axis_tready(enc_out_tready),
        .busy(enc_busy),
        .done(enc_done),
        .error(enc_error),
        .input_record_count(stage5_input_record_count),
        .encoded_entry_count(stage5_encoded_entry_count),
        .restart_count(stage5_restart_count),
        .shared_key_bytes_total(stage5_shared_key_bytes_total),
        .unshared_key_bytes_total(stage5_unshared_key_bytes_total),
        .value_bytes_total(stage5_value_bytes_total),
        .last_key_len(stage5_last_key_len),
        .last_key_bytes(stage5_last_key_bytes),
        .last_value_len(stage5_last_value_len),
        .last_shared_bytes(stage5_last_shared_bytes),
        .last_non_shared_bytes(stage5_last_non_shared_bytes),
        .output_block_bytes(stage5_output_block_bytes)
    );

    // OPT-W1: Pack adapter (8→32) between encoder output and enc_out FIFO
    stream_pack_adapter #(
        .IN_DATA_WIDTH(8),
        .IN_KEEP_WIDTH(1),
        .OUT_DATA_WIDTH(32),
        .OUT_KEEP_WIDTH(4)
    ) u_enc_pack_adapter (
        .clk(clk), .rstn(rstn), .clear(clear),
        .s_axis_tdata(enc_out_tdata),
        .s_axis_tkeep(enc_out_tkeep),
        .s_axis_tlast(enc_out_tlast),
        .s_axis_tvalid(enc_out_tvalid),
        .s_axis_tready(enc_out_tready),
        .m_axis_tdata(enc_byte_tdata),
        .m_axis_tkeep(enc_byte_tkeep),
        .m_axis_tlast(enc_byte_tlast),
        .m_axis_tvalid(enc_byte_tvalid),
        .m_axis_tready(enc_byte_tready)
    );

    // OPT-MF1 + OPT-W1: 37-bit stream_fifo
    stream_fifo #(
        .DATA_WIDTH(37),
        .DEPTH(128)
    ) u_enc_out_fifo (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .s_data({enc_byte_tdata, enc_byte_tkeep, enc_byte_tlast}),
        .s_valid(enc_byte_tvalid),
        .s_ready(enc_byte_tready),
        .m_data({enc_fifo_tdata, enc_fifo_tkeep, enc_fifo_tlast}),
        .m_valid(enc_fifo_tvalid),
        .m_ready(enc_fifo_tready),
        .occupancy()
    );

    block_trailer_appender_w32 u_block_trailer_appender (
        .clk(clk), .rstn(rstn), .clear(clear),
        .s_axis_tdata(enc_fifo_tdata),
        .s_axis_tkeep(enc_fifo_tkeep),
        .s_axis_tlast(enc_fifo_tlast),
        .s_axis_tvalid(enc_fifo_tvalid),
        .s_axis_tready(enc_fifo_tready),
        .m_axis_tdata(trail_byte_tdata),
        .m_axis_tkeep(trail_byte_tkeep),
        .m_axis_tlast(trail_byte_tlast),
        .m_axis_tvalid(trail_byte_tvalid),
        .m_axis_tready(trail_byte_tready)
    );

    // Repack trailer appender's variable-tkeep output into dense 32-bit words
    stream_width_adapter #(
        .IN_DATA_WIDTH(32),
        .OUT_DATA_WIDTH(8)
    ) u_trail_w32to8 (
        .clk(clk), .rstn(rstn), .clear(clear),
        .s_axis_tdata(trail_byte_tdata),
        .s_axis_tkeep(trail_byte_tkeep),
        .s_axis_tlast(trail_byte_tlast),
        .s_axis_tvalid(trail_byte_tvalid),
        .s_axis_tready(trail_byte_tready),
        .m_axis_tdata(trail_ser_tdata),
        .m_axis_tkeep(trail_ser_tkeep),
        .m_axis_tlast(trail_ser_tlast),
        .m_axis_tvalid(trail_ser_tvalid),
        .m_axis_tready(trail_ser_tready)
    );

    stream_pack_adapter #(
        .IN_DATA_WIDTH(8),
        .IN_KEEP_WIDTH(1),
        .OUT_DATA_WIDTH(32),
        .OUT_KEEP_WIDTH(4)
    ) u_trail_pack8to32 (
        .clk(clk), .rstn(rstn), .clear(clear),
        .s_axis_tdata(trail_ser_tdata),
        .s_axis_tkeep(trail_ser_tkeep),
        .s_axis_tlast(trail_ser_tlast),
        .s_axis_tvalid(trail_ser_tvalid),
        .s_axis_tready(trail_ser_tready),
        .m_axis_tdata(trail_dense_tdata),
        .m_axis_tkeep(trail_dense_tkeep),
        .m_axis_tlast(trail_dense_tlast),
        .m_axis_tvalid(trail_dense_tvalid),
        .m_axis_tready(trail_dense_tready)
    );

    // OPT-W1: pack dense 32-bit words into AXI beats
    stream_pack_adapter #(
        .IN_DATA_WIDTH(32),
        .IN_KEEP_WIDTH(4),
        .OUT_DATA_WIDTH(AXI_DATA_WIDTH),
        .OUT_KEEP_WIDTH(AXI_KEEP_WIDTH)
    ) u_stream_pack_adapter (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .s_axis_tdata(trail_dense_tdata),
        .s_axis_tkeep(trail_dense_tkeep),
        .s_axis_tlast(trail_dense_tlast),
        .s_axis_tvalid(trail_dense_tvalid),
        .s_axis_tready(trail_dense_tready),
        .m_axis_tdata(write_beat_tdata),
        .m_axis_tkeep(write_beat_tkeep),
        .m_axis_tlast(write_beat_tlast),
        .m_axis_tvalid(write_beat_tvalid),
        .m_axis_tready(write_beat_tready)
    );

    // OPT-MF1: TLAST_STOP=1 allows early start with upper-bound byte_count
    axi_write_engine #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .TLAST_STOP(1)
    ) u_axi_write_engine (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(wr_start_pulse_r),
        .base_addr(dst_base_addr),
        .byte_count(STAGE5_MAX_BLOCK_BYTES + 32'd5),
        .busy(wr_busy),
        .done(wr_done),
        .error(wr_error),
        .bytes_written(stage5_bytes_written),
        .beats_written(stage5_beats_written),
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

    // OPT-MF1: Start write engine on first packed beat (not enc_done).
    // OPT-BP1: Also reset wr_started on wr_done for back-to-back block support.
    always @(posedge clk) begin
        if (!rstn) begin
            wr_start_pulse_r    <= 1'b0;
            wr_started          <= 1'b0;
            write_beat_tvalid_d <= 1'b0;
        end else if (clear) begin
            wr_start_pulse_r    <= 1'b0;
            wr_started          <= 1'b0;
            write_beat_tvalid_d <= 1'b0;
        end else begin
            wr_start_pulse_r    <= 1'b0;
            write_beat_tvalid_d <= write_beat_tvalid;
            if (start && !busy) begin
                wr_started <= 1'b0;
            end else if (wr_done) begin
                // OPT-BP1: after write finishes, re-arm first-beat detection
                // for next pipelined block
                wr_started          <= 1'b0;
                write_beat_tvalid_d <= 1'b0;
            end else if (!wr_started && write_beat_tvalid && !write_beat_tvalid_d) begin
                wr_start_pulse_r <= 1'b1;
                wr_started       <= 1'b1;
            end
        end
    end

    assign m_axi_araddr  = {AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_arlen   = 8'd0;
    assign m_axi_arsize  = 3'd0;
    assign m_axi_arburst = 2'd0;
    assign m_axi_arid    = {AXI_ID_WIDTH{1'b0}};
    assign m_axi_arvalid = 1'b0;
    assign m_axi_rready  = 1'b0;

    assign merge_done          = merge_top_done;
    assign stage5_done         = wr_done;
    assign merge_bytes_written = 32'd0;
    assign merge_beats_written = 32'd0;
    assign stage5_bytes_read   = 32'd0;
    assign stage5_beats_read   = 32'd0;
    // OPT-BP1: expose encoder done pulse
    assign enc_done_out        = enc_done;

    assign busy  = merge_top_busy | enc_busy | wr_busy;
    assign done  = wr_done;
    assign error = merge_top_error | enc_error | wr_error;

endmodule
`endif
`timescale 1ns / 1ps

module cmpct_pair_chain #(
    parameter integer AXI_ADDR_WIDTH              = 64,
    parameter integer AXI_DATA_WIDTH              = 512,
    parameter integer AXI_ID_WIDTH                = 1,
    parameter integer MAX_BURST_LEN               = 16,
    parameter integer STAGE4_MAX_BLOCK_BYTES      = 4096,
    parameter integer STAGE4_MAX_KEY_BYTES        = 72,
    parameter integer MERGE_MAX_USER_KEY_BYTES    = 64,
    parameter integer MERGE_MAX_KEY_BYTES         = 72,
    parameter integer MERGE_MAX_VALUE_BYTES       = 1024,
    parameter integer MERGE_MAX_RECORD_BYTES      = 2048,
    parameter integer MERGE_MAX_RECORDS           = 256,
    parameter integer MERGE_MAX_OUTPUT_BYTES      = 73728,
    parameter integer STAGE5_MAX_RECORDS          = 256,
    parameter integer STAGE5_MAX_PAYLOAD_BYTES    = 4096,
    parameter integer STAGE5_MAX_BLOCK_BYTES      = 4096,
    parameter integer STAGE5_MAX_KEY_BYTES        = 64,
    parameter integer STAGE5_MAX_VALUE_BYTES      = 1024,
    parameter integer STAGE5_RESTART_INTERVAL     = 16
) (
    input  wire                          clk,
    input  wire                          rstn,
    input  wire                          clear,
    input  wire                          start,
    // OPT-BP1: partial clear/start for block-pair pipelining
    input  wire                          front_clear,
    input  wire                          front_start,
    input  wire                          seed_prev_user_key_valid,
    input  wire [15:0]                   seed_prev_user_key_len,
    input  wire [(MERGE_MAX_USER_KEY_BYTES*8)-1:0] seed_prev_user_key,
    input  wire [AXI_ADDR_WIDTH-1:0]     src0_base_addr,
    input  wire [31:0]                   src0_byte_count,
    input  wire [AXI_ADDR_WIDTH-1:0]     src1_base_addr,
    input  wire [31:0]                   src1_byte_count,
    input  wire [AXI_ADDR_WIDTH-1:0]     mid_base_addr,
    input  wire [AXI_ADDR_WIDTH-1:0]     dst_base_addr,
    output wire                          busy,
    output wire                          done,
    output wire                          error,
    output wire [31:0]                   source0_decoded_entry_count,
    output wire [31:0]                   source0_restart_count,
    output wire [31:0]                   source0_restart_entry_count,
    output wire [31:0]                   source0_shared_key_bytes_total,
    output wire [31:0]                   source0_unshared_key_bytes_total,
    output wire [31:0]                   source0_value_bytes_total,
    output wire [15:0]                   source0_last_key_len,
    output wire [15:0]                   source0_last_value_len,
    output wire [15:0]                   source0_last_shared_bytes,
    output wire [15:0]                   source0_last_non_shared_bytes,
    output wire [31:0]                   source0_restart_array_offset,
    output wire [31:0]                   source0_bytes_read,
    output wire [31:0]                   source0_beats_read,
    output wire [31:0]                   source1_decoded_entry_count,
    output wire [31:0]                   source1_restart_count,
    output wire [31:0]                   source1_restart_entry_count,
    output wire [31:0]                   source1_shared_key_bytes_total,
    output wire [31:0]                   source1_unshared_key_bytes_total,
    output wire [31:0]                   source1_value_bytes_total,
    output wire [15:0]                   source1_last_key_len,
    output wire [15:0]                   source1_last_value_len,
    output wire [15:0]                   source1_last_shared_bytes,
    output wire [15:0]                   source1_last_non_shared_bytes,
    output wire [31:0]                   source1_restart_array_offset,
    output wire [31:0]                   source1_bytes_read,
    output wire [31:0]                   source1_beats_read,
    output wire [31:0]                   merge_bytes_written,
    output wire [31:0]                   merge_beats_written,
    output wire [31:0]                   merge_output_byte_count,
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
    output wire [31:0]                   stage5_bytes_read,
    output wire [31:0]                   stage5_beats_read,
    output wire [31:0]                   stage5_bytes_written,
    output wire [31:0]                   stage5_beats_written,
    output wire [31:0]                   stage5_input_record_count,
    output wire [31:0]                   stage5_encoded_entry_count,
    output wire [31:0]                   stage5_restart_count,
    output wire [31:0]                   stage5_shared_key_bytes_total,
    output wire [31:0]                   stage5_unshared_key_bytes_total,
    output wire [31:0]                   stage5_value_bytes_total,
    output wire [15:0]                              stage5_last_key_len,
    output wire [(STAGE5_MAX_KEY_BYTES*8)-1:0]       stage5_last_key_bytes,
    output wire [15:0]                              stage5_last_value_len,
    output wire [15:0]                              stage5_last_shared_bytes,
    output wire [15:0]                              stage5_last_non_shared_bytes,
    output wire [31:0]                              stage5_output_block_bytes,
    output wire                          final_prev_user_key_valid,
    output wire [15:0]                   final_prev_user_key_len,
    output wire [(MERGE_MAX_USER_KEY_BYTES*8)-1:0] final_prev_user_key,
    // OPT-BP1: expose encoder done for block-pair pipelining
    output wire                          enc_done,

    output wire [AXI_ADDR_WIDTH-1:0]     m_axi_src0_araddr,
    output wire [7:0]                    m_axi_src0_arlen,
    output wire [2:0]                    m_axi_src0_arsize,
    output wire [1:0]                    m_axi_src0_arburst,
    output wire                          m_axi_src0_arvalid,
    input  wire                          m_axi_src0_arready,
    input  wire [AXI_DATA_WIDTH-1:0]     m_axi_src0_rdata,
    input  wire [1:0]                    m_axi_src0_rresp,
    input  wire                          m_axi_src0_rlast,
    input  wire                          m_axi_src0_rvalid,
    output wire                          m_axi_src0_rready,

    output wire [AXI_ADDR_WIDTH-1:0]     m_axi_src1_araddr,
    output wire [7:0]                    m_axi_src1_arlen,
    output wire [2:0]                    m_axi_src1_arsize,
    output wire [1:0]                    m_axi_src1_arburst,
    output wire                          m_axi_src1_arvalid,
    input  wire                          m_axi_src1_arready,
    input  wire [AXI_DATA_WIDTH-1:0]     m_axi_src1_rdata,
    input  wire [1:0]                    m_axi_src1_rresp,
    input  wire                          m_axi_src1_rlast,
    input  wire                          m_axi_src1_rvalid,
    output wire                          m_axi_src1_rready,

    output wire [AXI_ADDR_WIDTH-1:0]     m_axi_chain_araddr,
    output wire [7:0]                    m_axi_chain_arlen,
    output wire [2:0]                    m_axi_chain_arsize,
    output wire [1:0]                    m_axi_chain_arburst,
    output wire                          m_axi_chain_arvalid,
    input  wire                          m_axi_chain_arready,
    input  wire [AXI_DATA_WIDTH-1:0]     m_axi_chain_rdata,
    input  wire [1:0]                    m_axi_chain_rresp,
    input  wire                          m_axi_chain_rlast,
    input  wire                          m_axi_chain_rvalid,
    output wire                          m_axi_chain_rready,
    output wire [AXI_ADDR_WIDTH-1:0]     m_axi_chain_awaddr,
    output wire [7:0]                    m_axi_chain_awlen,
    output wire [2:0]                    m_axi_chain_awsize,
    output wire [1:0]                    m_axi_chain_awburst,
    output wire                          m_axi_chain_awvalid,
    input  wire                          m_axi_chain_awready,
    output wire [AXI_DATA_WIDTH-1:0]     m_axi_chain_wdata,
    output wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_chain_wstrb,
    output wire                          m_axi_chain_wlast,
    output wire                          m_axi_chain_wvalid,
    input  wire                          m_axi_chain_wready,
    input  wire [1:0]                    m_axi_chain_bresp,
    input  wire                          m_axi_chain_bvalid,
    output wire                          m_axi_chain_bready
);

    wire        source0_busy_i;
    wire        source0_done_i;
    wire        source0_error_i;
    wire        s0_record_valid_i;
    wire        s0_record_ready_i;
    wire [15:0] s0_record_key_len_i;
    wire [15:0] s0_record_value_len_i;
    wire [15:0] s0_record_shared_bytes_i;
    wire [15:0] s0_record_non_shared_bytes_i;
    wire [63:0] s0_record_tdata_i;
    wire [7:0]  s0_record_tkeep_i;
    wire        s0_record_tlast_i;
    wire        s0_record_tvalid_i;
    wire        s0_record_tready_i;

    wire        source1_busy_i;
    wire        source1_done_i;
    wire        source1_error_i;
    wire        s1_record_valid_i;
    wire        s1_record_ready_i;
    wire [15:0] s1_record_key_len_i;
    wire [15:0] s1_record_value_len_i;
    wire [15:0] s1_record_shared_bytes_i;
    wire [15:0] s1_record_non_shared_bytes_i;
    wire [63:0] s1_record_tdata_i;
    wire [7:0]  s1_record_tkeep_i;
    wire        s1_record_tlast_i;
    wire        s1_record_tvalid_i;
    wire        s1_record_tready_i;

    wire chain_busy_i;
    wire chain_done_i;
    wire chain_error_i;

    // OPT-T1: Input decoupling FIFO wires — Source 0
    wire        s0_hdr_fifo_m_valid;
    wire [31:0] s0_hdr_fifo_m_data;
    wire        s0_hdr_fifo_m_ready;
    // P3: 73-bit = 64(tdata) + 8(tkeep) + 1(tlast)
    wire [72:0] s0_byte_fifo_m_data;
    wire        s0_byte_fifo_m_valid;
    wire        s0_byte_fifo_m_ready;

    // OPT-T1: Input decoupling FIFO wires — Source 1
    wire        s1_hdr_fifo_m_valid;
    wire [31:0] s1_hdr_fifo_m_data;
    wire        s1_hdr_fifo_m_ready;
    // P3: 73-bit = 64(tdata) + 8(tkeep) + 1(tlast)
    wire [72:0] s1_byte_fifo_m_data;
    wire        s1_byte_fifo_m_valid;
    wire        s1_byte_fifo_m_ready;

    // P3+P6: Pipeline registers between byte FIFOs and merger (73-bit)
    reg  [72:0] s0_byte_pipe_data_r;
    reg         s0_byte_pipe_valid_r;
    wire        s0_byte_pipe_ready_w;
    reg  [72:0] s1_byte_pipe_data_r;
    reg         s1_byte_pipe_valid_r;
    wire        s1_byte_pipe_ready_w;

    assign s0_byte_fifo_m_ready = !s0_byte_pipe_valid_r || s0_byte_pipe_ready_w;
    assign s1_byte_fifo_m_ready = !s1_byte_pipe_valid_r || s1_byte_pipe_ready_w;

    always @(posedge clk) begin
        if (!rstn || clear || front_clear) begin
            s0_byte_pipe_valid_r <= 1'b0;
            s1_byte_pipe_valid_r <= 1'b0;
        end else begin
            if (s0_byte_fifo_m_ready) begin
                s0_byte_pipe_valid_r <= s0_byte_fifo_m_valid;
                s0_byte_pipe_data_r  <= s0_byte_fifo_m_data;
            end
            if (s1_byte_fifo_m_ready) begin
                s1_byte_pipe_valid_r <= s1_byte_fifo_m_valid;
                s1_byte_pipe_data_r  <= s1_byte_fifo_m_data;
            end
        end
    end

    // OPT-T1: Latch source_done pulses, then gate with header FIFO empty.
    // source_done is a ONE-CYCLE pulse — combinational gating would miss it
    // if the header FIFO still has entries at that moment.
    reg  s0_source_done_latched;
    reg  s1_source_done_latched;
    always @(posedge clk) begin
        if (!rstn || clear || front_clear) begin
            s0_source_done_latched <= 1'b0;
            s1_source_done_latched <= 1'b0;
        end else begin
            if (start || front_start) begin
                s0_source_done_latched <= 1'b0;
                s1_source_done_latched <= 1'b0;
            end else begin
                if (source0_done_i) s0_source_done_latched <= 1'b1;
                if (source1_done_i) s1_source_done_latched <= 1'b1;
            end
        end
    end
    wire s0_source_done_gated = s0_source_done_latched && !s0_hdr_fifo_m_valid;
    wire s1_source_done_gated = s1_source_done_latched && !s1_hdr_fifo_m_valid;

    cmpct_source_pipe #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .MAX_BLOCK_BYTES(STAGE4_MAX_BLOCK_BYTES),
        .MAX_KEY_BYTES(STAGE4_MAX_KEY_BYTES)
    ) u_source0_emit (
        .clk(clk),
        .rstn(rstn),
        .clear(clear || front_clear),
        .start(start || front_start),
        .src_base_addr(src0_base_addr),
        .byte_count(src0_byte_count),
        .busy(source0_busy_i),
        .done(source0_done_i),
        .error(source0_error_i),
        .bytes_read(source0_bytes_read),
        .beats_read(source0_beats_read),
        .record_valid(s0_record_valid_i),
        .record_ready(s0_record_ready_i),
        .record_key_len(s0_record_key_len_i),
        .record_value_len(s0_record_value_len_i),
        .record_shared_bytes(s0_record_shared_bytes_i),
        .record_non_shared_bytes(s0_record_non_shared_bytes_i),
        .record_tdata(s0_record_tdata_i),
        .record_tkeep(s0_record_tkeep_i),
        .record_tlast(s0_record_tlast_i),
        .record_tvalid(s0_record_tvalid_i),
        .record_tready(s0_record_tready_i),
        .decoded_entry_count(source0_decoded_entry_count),
        .restart_count(source0_restart_count),
        .restart_entry_count(source0_restart_entry_count),
        .shared_key_bytes_total(source0_shared_key_bytes_total),
        .unshared_key_bytes_total(source0_unshared_key_bytes_total),
        .value_bytes_total(source0_value_bytes_total),
        .last_key_len(source0_last_key_len),
        .last_value_len(source0_last_value_len),
        .last_shared_bytes(source0_last_shared_bytes),
        .last_non_shared_bytes(source0_last_non_shared_bytes),
        .restart_array_offset(source0_restart_array_offset),
        .m_axi_araddr(m_axi_src0_araddr),
        .m_axi_arlen(m_axi_src0_arlen),
        .m_axi_arsize(m_axi_src0_arsize),
        .m_axi_arburst(m_axi_src0_arburst),
        .m_axi_arid(),
        .m_axi_arvalid(m_axi_src0_arvalid),
        .m_axi_arready(m_axi_src0_arready),
        .m_axi_rdata(m_axi_src0_rdata),
        .m_axi_rresp(m_axi_src0_rresp),
        .m_axi_rlast(m_axi_src0_rlast),
        .m_axi_rid({AXI_ID_WIDTH{1'b0}}),
        .m_axi_rvalid(m_axi_src0_rvalid),
        .m_axi_rready(m_axi_src0_rready)
    );

    cmpct_source_pipe #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .MAX_BLOCK_BYTES(STAGE4_MAX_BLOCK_BYTES),
        .MAX_KEY_BYTES(STAGE4_MAX_KEY_BYTES)
    ) u_source1_emit (
        .clk(clk),
        .rstn(rstn),
        .clear(clear || front_clear),
        .start(start || front_start),
        .src_base_addr(src1_base_addr),
        .byte_count(src1_byte_count),
        .busy(source1_busy_i),
        .done(source1_done_i),
        .error(source1_error_i),
        .bytes_read(source1_bytes_read),
        .beats_read(source1_beats_read),
        .record_valid(s1_record_valid_i),
        .record_ready(s1_record_ready_i),
        .record_key_len(s1_record_key_len_i),
        .record_value_len(s1_record_value_len_i),
        .record_shared_bytes(s1_record_shared_bytes_i),
        .record_non_shared_bytes(s1_record_non_shared_bytes_i),
        .record_tdata(s1_record_tdata_i),
        .record_tkeep(s1_record_tkeep_i),
        .record_tlast(s1_record_tlast_i),
        .record_tvalid(s1_record_tvalid_i),
        .record_tready(s1_record_tready_i),
        .decoded_entry_count(source1_decoded_entry_count),
        .restart_count(source1_restart_count),
        .restart_entry_count(source1_restart_entry_count),
        .shared_key_bytes_total(source1_shared_key_bytes_total),
        .unshared_key_bytes_total(source1_unshared_key_bytes_total),
        .value_bytes_total(source1_value_bytes_total),
        .last_key_len(source1_last_key_len),
        .last_value_len(source1_last_value_len),
        .last_shared_bytes(source1_last_shared_bytes),
        .last_non_shared_bytes(source1_last_non_shared_bytes),
        .restart_array_offset(source1_restart_array_offset),
        .m_axi_araddr(m_axi_src1_araddr),
        .m_axi_arlen(m_axi_src1_arlen),
        .m_axi_arsize(m_axi_src1_arsize),
        .m_axi_arburst(m_axi_src1_arburst),
        .m_axi_arid(),
        .m_axi_arvalid(m_axi_src1_arvalid),
        .m_axi_arready(m_axi_src1_arready),
        .m_axi_rdata(m_axi_src1_rdata),
        .m_axi_rresp(m_axi_src1_rresp),
        .m_axi_rlast(m_axi_src1_rlast),
        .m_axi_rid({AXI_ID_WIDTH{1'b0}}),
        .m_axi_rvalid(m_axi_src1_rvalid),
        .m_axi_rready(m_axi_src1_rready)
    );

    // OPT-T1: Source 0 record-header FIFO (decouple header handshake)
    stream_fifo #(.DATA_WIDTH(32), .DEPTH(4)) u_s0_hdr_fifo (
        .clk(clk), .rstn(rstn), .clear(clear || front_clear),
        .s_data({s0_record_key_len_i, s0_record_value_len_i}),
        .s_valid(s0_record_valid_i),
        .s_ready(s0_record_ready_i),
        .m_data(s0_hdr_fifo_m_data),
        .m_valid(s0_hdr_fifo_m_valid),
        .m_ready(s0_hdr_fifo_m_ready),
        .occupancy()
    );

    // P3: Source 0 byte-stream FIFO (73-bit: 64+8+1)
    stream_fifo #(.DATA_WIDTH(73), .DEPTH(128)) u_s0_byte_fifo (
        .clk(clk), .rstn(rstn), .clear(clear || front_clear),
        .s_data({s0_record_tdata_i, s0_record_tkeep_i, s0_record_tlast_i}),
        .s_valid(s0_record_tvalid_i),
        .s_ready(s0_record_tready_i),
        .m_data(s0_byte_fifo_m_data),
        .m_valid(s0_byte_fifo_m_valid),
        .m_ready(s0_byte_fifo_m_ready),
        .occupancy()
    );

    // OPT-T1: Source 1 record-header FIFO (decouple header handshake)
    stream_fifo #(.DATA_WIDTH(32), .DEPTH(4)) u_s1_hdr_fifo (
        .clk(clk), .rstn(rstn), .clear(clear || front_clear),
        .s_data({s1_record_key_len_i, s1_record_value_len_i}),
        .s_valid(s1_record_valid_i),
        .s_ready(s1_record_ready_i),
        .m_data(s1_hdr_fifo_m_data),
        .m_valid(s1_hdr_fifo_m_valid),
        .m_ready(s1_hdr_fifo_m_ready),
        .occupancy()
    );

    // P3: Source 1 byte-stream FIFO (73-bit: 64+8+1)
    stream_fifo #(.DATA_WIDTH(73), .DEPTH(128)) u_s1_byte_fifo (
        .clk(clk), .rstn(rstn), .clear(clear || front_clear),
        .s_data({s1_record_tdata_i, s1_record_tkeep_i, s1_record_tlast_i}),
        .s_valid(s1_record_tvalid_i),
        .s_ready(s1_record_tready_i),
        .m_data(s1_byte_fifo_m_data),
        .m_valid(s1_byte_fifo_m_valid),
        .m_ready(s1_byte_fifo_m_ready),
        .occupancy()
    );

    // -----------------------------------------------------------------------
    // Inlined merge+encode pipeline (was cmpct_merge_pipe)
    // -----------------------------------------------------------------------
    localparam integer AXI_KEEP_WIDTH = AXI_DATA_WIDTH / 8;

    // P6: 64-bit wide data path from merger
    wire [63:0] merge_byte_tdata;
    wire [7:0]  merge_byte_tkeep;
    wire        merge_byte_tlast;
    wire        merge_byte_tvalid;
    wire        merge_byte_tready;

    // P6: decoupling FIFO between merger output and 64→32 adapter (73-bit)
    wire [63:0] fifo_byte_tdata;
    wire [7:0]  fifo_byte_tkeep;
    wire        fifo_byte_tlast;
    wire        fifo_byte_tvalid;
    wire        fifo_byte_tready;

    // Record-stream bridge: merger -> encoder
    wire        merge_record_valid;
    wire        merge_record_ready;
    wire [15:0] merge_record_key_len;
    wire [15:0] merge_record_value_len;

    // OPT-HF: Record header FIFO (decouples merger from encoder header handshake)
    wire        hdr_fifo_m_valid;
    wire        hdr_fifo_m_ready;
    wire [31:0] hdr_fifo_m_data;
    wire [15:0] hdr_fifo_key_len  = hdr_fifo_m_data[31:16];
    wire [15:0] hdr_fifo_value_len = hdr_fifo_m_data[15:0];

    // P7: 64-bit encoder output (variable tkeep)
    wire [63:0] enc_out_tdata;
    wire [7:0]  enc_out_tkeep;
    wire        enc_out_tlast;
    wire        enc_out_tvalid;
    wire        enc_out_tready;

    // P7: Repacked dense 64-bit output from packer_64
    wire [63:0] enc_byte_tdata;
    wire [7:0]  enc_byte_tkeep;
    wire        enc_byte_tlast;
    wire        enc_byte_tvalid;
    wire        enc_byte_tready;

    // P7: FIFO between packer_64 and trailer_appender (73-bit: 64+8+1)
    wire [63:0] enc_fifo_tdata;
    wire [7:0]  enc_fifo_tkeep;
    wire        enc_fifo_tlast;
    wire        enc_fifo_tvalid;
    wire        enc_fifo_tready;

    // P7: 64-bit trailer appender output (variable tkeep for trailer word)
    wire [63:0] trail_byte_tdata;
    wire [7:0]  trail_byte_tkeep;
    wire        trail_byte_tlast;
    wire        trail_byte_tvalid;
    wire        trail_byte_tready;

    // P7: Repacked dense 64-bit output after trailer
    wire [63:0] trail_packed_tdata;
    wire [7:0]  trail_packed_tkeep;
    wire        trail_packed_tlast;
    wire        trail_packed_tvalid;
    wire        trail_packed_tready;

    wire [AXI_DATA_WIDTH-1:0] write_beat_tdata;
    wire [AXI_KEEP_WIDTH-1:0] write_beat_tkeep;
    wire                      write_beat_tlast;
    wire                      write_beat_tvalid;
    wire                      write_beat_tready;

    wire merge_top_busy;
    wire merge_top_done;
    wire merge_top_error;
    wire enc_busy;
    wire enc_error;
    wire wr_busy;
    wire wr_done;
    wire wr_error;

    reg  wr_start_pulse_r;
    reg  wr_started;
    reg  write_beat_tvalid_d;

    cmpct_merger #(
        .MAX_USER_KEY_BYTES(MERGE_MAX_USER_KEY_BYTES),
        .MAX_KEY_BYTES(MERGE_MAX_KEY_BYTES),
        .MAX_VALUE_BYTES(MERGE_MAX_VALUE_BYTES),
        .MAX_RECORD_BYTES(MERGE_MAX_RECORD_BYTES)
    ) u_merger (
        .clk(clk),
        .rstn(rstn),
        .clear(clear || front_clear),
        .start(start || front_start),
        .seed_prev_user_key_valid(seed_prev_user_key_valid),
        .seed_prev_user_key_len(seed_prev_user_key_len),
        .seed_prev_user_key(seed_prev_user_key),
        .source0_done(s0_source_done_gated),
        .s0_record_valid(s0_hdr_fifo_m_valid),
        .s0_record_ready(s0_hdr_fifo_m_ready),
        .s0_record_key_len(s0_hdr_fifo_m_data[31:16]),
        .s0_record_value_len(s0_hdr_fifo_m_data[15:0]),
        // P3+P6: connect through 73-bit pipeline registers
        .s0_axis_tdata(s0_byte_pipe_data_r[72:9]),
        .s0_axis_tkeep(s0_byte_pipe_data_r[8:1]),
        .s0_axis_tlast(s0_byte_pipe_data_r[0]),
        .s0_axis_tvalid(s0_byte_pipe_valid_r),
        .s0_axis_tready(s0_byte_pipe_ready_w),
        .source1_done(s1_source_done_gated),
        .s1_record_valid(s1_hdr_fifo_m_valid),
        .s1_record_ready(s1_hdr_fifo_m_ready),
        .s1_record_key_len(s1_hdr_fifo_m_data[31:16]),
        .s1_record_value_len(s1_hdr_fifo_m_data[15:0]),
        // P3+P6: connect through 73-bit pipeline registers
        .s1_axis_tdata(s1_byte_pipe_data_r[72:9]),
        .s1_axis_tkeep(s1_byte_pipe_data_r[8:1]),
        .s1_axis_tlast(s1_byte_pipe_data_r[0]),
        .s1_axis_tvalid(s1_byte_pipe_valid_r),
        .s1_axis_tready(s1_byte_pipe_ready_w),
        .busy(merge_top_busy),
        .done(merge_top_done),
        .error(merge_top_error),
        .output_byte_count(merge_output_byte_count),
        .m_record_valid(merge_record_valid),
        .m_record_ready(merge_record_ready),
        .m_record_key_len(merge_record_key_len),
        .m_record_value_len(merge_record_value_len),
        .m_axis_tdata(merge_byte_tdata),
        .m_axis_tkeep(merge_byte_tkeep),
        .m_axis_tlast(merge_byte_tlast),
        .m_axis_tvalid(merge_byte_tvalid),
        .m_axis_tready(merge_byte_tready),
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

    // OPT-HF: Record header FIFO — depth 4 decouples merger ST_EMIT_HEADER from encoder
    stream_fifo #(
        .DATA_WIDTH(32),
        .DEPTH(4)
    ) u_hdr_fifo (
        .clk(clk),
        .rstn(rstn),
        .clear(clear || front_clear),
        .s_data({merge_record_key_len, merge_record_value_len}),
        .s_valid(merge_record_valid),
        .s_ready(merge_record_ready),
        .m_data(hdr_fifo_m_data),
        .m_valid(hdr_fifo_m_valid),
        .m_ready(hdr_fifo_m_ready),
        .occupancy()
    );

    // P6: 73-bit stream_fifo (64 data + 8 keep + 1 last)
    stream_fifo #(
        .DATA_WIDTH(73),
        .DEPTH(64)
    ) u_merge_enc_fifo (
        .clk(clk),
        .rstn(rstn),
        .clear(clear || front_clear),
        .s_data({merge_byte_tdata, merge_byte_tkeep, merge_byte_tlast}),
        .s_valid(merge_byte_tvalid),
        .s_ready(merge_byte_tready),
        .m_data({fifo_byte_tdata, fifo_byte_tkeep, fifo_byte_tlast}),
        .m_valid(fifo_byte_tvalid),
        .m_ready(fifo_byte_tready),
        .occupancy()
    );

    // P7: Encoder takes 64-bit directly from merge FIFO (no 64→32 adapter)
    cmpct_block_encoder #(
        .MAX_RECORDS(STAGE5_MAX_RECORDS),
        .MAX_PAYLOAD_BYTES(STAGE5_MAX_PAYLOAD_BYTES),
        .MAX_BLOCK_BYTES(STAGE5_MAX_BLOCK_BYTES),
        .MAX_KEY_BYTES(STAGE5_MAX_KEY_BYTES),
        .MAX_VALUE_BYTES(STAGE5_MAX_VALUE_BYTES),
        .RESTART_INTERVAL(STAGE5_RESTART_INTERVAL)
    ) u_cmpct_block_encoder (
        .clk(clk),
        .rstn(rstn),
        .clear(clear || front_clear),
        .start(start || front_start),
        // OPT-HF: encoder reads headers from FIFO, not directly from merger
        .s_record_valid(hdr_fifo_m_valid),
        .s_record_ready(hdr_fifo_m_ready),
        .s_record_key_len(hdr_fifo_key_len),
        .s_record_value_len(hdr_fifo_value_len),
        .source_done(merge_top_done),
        // P7: 64-bit data directly from merge FIFO
        .s_axis_tdata(fifo_byte_tdata),
        .s_axis_tkeep(fifo_byte_tkeep),
        .s_axis_tlast(fifo_byte_tlast),
        .s_axis_tvalid(fifo_byte_tvalid),
        .s_axis_tready(fifo_byte_tready),
        .m_axis_tdata(enc_out_tdata),
        .m_axis_tkeep(enc_out_tkeep),
        .m_axis_tlast(enc_out_tlast),
        .m_axis_tvalid(enc_out_tvalid),
        .m_axis_tready(enc_out_tready),
        .busy(enc_busy),
        .done(enc_done),
        .error(enc_error),
        .input_record_count(stage5_input_record_count),
        .encoded_entry_count(stage5_encoded_entry_count),
        .restart_count(stage5_restart_count),
        .shared_key_bytes_total(stage5_shared_key_bytes_total),
        .unshared_key_bytes_total(stage5_unshared_key_bytes_total),
        .value_bytes_total(stage5_value_bytes_total),
        .last_key_len(stage5_last_key_len),
        .last_key_bytes(stage5_last_key_bytes),
        .last_value_len(stage5_last_value_len),
        .last_shared_bytes(stage5_last_shared_bytes),
        .last_non_shared_bytes(stage5_last_non_shared_bytes),
        .output_block_bytes(stage5_output_block_bytes)
    );

    // P7: 64-bit byte packer (8 bytes/cycle) replaces 32-bit packer
    stream_byte_packer_64 u_enc_packer (
        .clk(clk), .rstn(rstn), .clear(clear),  // NOT front_clear: pair N's bytes still in flight
        .s_axis_tdata(enc_out_tdata),
        .s_axis_tkeep(enc_out_tkeep),
        .s_axis_tlast(enc_out_tlast),
        .s_axis_tvalid(enc_out_tvalid),
        .s_axis_tready(enc_out_tready),
        .m_axis_tdata(enc_byte_tdata),
        .m_axis_tkeep(enc_byte_tkeep),
        .m_axis_tlast(enc_byte_tlast),
        .m_axis_tvalid(enc_byte_tvalid),
        .m_axis_tready(enc_byte_tready)
    );

    // P7: 73-bit FIFO (64+8+1) between packer and trailer appender
    stream_fifo #(
        .DATA_WIDTH(73),
        .DEPTH(128)
    ) u_enc_out_fifo (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .s_data({enc_byte_tdata, enc_byte_tkeep, enc_byte_tlast}),
        .s_valid(enc_byte_tvalid),
        .s_ready(enc_byte_tready),
        .m_data({enc_fifo_tdata, enc_fifo_tkeep, enc_fifo_tlast}),
        .m_valid(enc_fifo_tvalid),
        .m_ready(enc_fifo_tready),
        .occupancy()
    );

    // P7: 64-bit trailer appender (CRC computed at 8 bytes/cycle)
    block_trailer_appender_w64 u_block_trailer_appender (
        .clk(clk), .rstn(rstn), .clear(clear),
        .s_axis_tdata(enc_fifo_tdata),
        .s_axis_tkeep(enc_fifo_tkeep),
        .s_axis_tlast(enc_fifo_tlast),
        .s_axis_tvalid(enc_fifo_tvalid),
        .s_axis_tready(enc_fifo_tready),
        .m_axis_tdata(trail_byte_tdata),
        .m_axis_tkeep(trail_byte_tkeep),
        .m_axis_tlast(trail_byte_tlast),
        .m_axis_tvalid(trail_byte_tvalid),
        .m_axis_tready(trail_byte_tready)
    );

    // P7: Repack trailer output (5-byte trailer word) into dense 64-bit
    stream_byte_packer_64 u_trail_packer (
        .clk(clk), .rstn(rstn), .clear(clear),
        .s_axis_tdata(trail_byte_tdata),
        .s_axis_tkeep(trail_byte_tkeep),
        .s_axis_tlast(trail_byte_tlast),
        .s_axis_tvalid(trail_byte_tvalid),
        .s_axis_tready(trail_byte_tready),
        .m_axis_tdata(trail_packed_tdata),
        .m_axis_tkeep(trail_packed_tkeep),
        .m_axis_tlast(trail_packed_tlast),
        .m_axis_tvalid(trail_packed_tvalid),
        .m_axis_tready(trail_packed_tready)
    );

    // P7: Pack dense 64-bit words into AXI beats
    stream_pack_adapter #(
        .IN_DATA_WIDTH(64),
        .IN_KEEP_WIDTH(8),
        .OUT_DATA_WIDTH(AXI_DATA_WIDTH),
        .OUT_KEEP_WIDTH(AXI_KEEP_WIDTH)
    ) u_stream_pack_adapter (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .s_axis_tdata(trail_packed_tdata),
        .s_axis_tkeep(trail_packed_tkeep),
        .s_axis_tlast(trail_packed_tlast),
        .s_axis_tvalid(trail_packed_tvalid),
        .s_axis_tready(trail_packed_tready),
        .m_axis_tdata(write_beat_tdata),
        .m_axis_tkeep(write_beat_tkeep),
        .m_axis_tlast(write_beat_tlast),
        .m_axis_tvalid(write_beat_tvalid),
        .m_axis_tready(write_beat_tready)
    );

    // OPT-MF1: TLAST_STOP=1 allows early start with upper-bound byte_count
    axi_write_engine #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .TLAST_STOP(1)
    ) u_axi_write_engine (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(wr_start_pulse_r),
        .base_addr(dst_base_addr),
        .byte_count(STAGE5_MAX_BLOCK_BYTES + 32'd5),
        .busy(wr_busy),
        .done(wr_done),
        .error(wr_error),
        .bytes_written(stage5_bytes_written),
        .beats_written(stage5_beats_written),
        .s_axis_tdata(write_beat_tdata),
        .s_axis_tkeep(write_beat_tkeep),
        .s_axis_tlast(write_beat_tlast),
        .s_axis_tvalid(write_beat_tvalid),
        .s_axis_tready(write_beat_tready),
        .m_axi_awaddr(m_axi_chain_awaddr),
        .m_axi_awlen(m_axi_chain_awlen),
        .m_axi_awsize(m_axi_chain_awsize),
        .m_axi_awburst(m_axi_chain_awburst),
        .m_axi_awid(),
        .m_axi_awvalid(m_axi_chain_awvalid),
        .m_axi_awready(m_axi_chain_awready),
        .m_axi_wdata(m_axi_chain_wdata),
        .m_axi_wstrb(m_axi_chain_wstrb),
        .m_axi_wlast(m_axi_chain_wlast),
        .m_axi_wvalid(m_axi_chain_wvalid),
        .m_axi_wready(m_axi_chain_wready),
        .m_axi_bresp(m_axi_chain_bresp),
        .m_axi_bid({AXI_ID_WIDTH{1'b0}}),
        .m_axi_bvalid(m_axi_chain_bvalid),
        .m_axi_bready(m_axi_chain_bready)
    );

    // OPT-MF1: Start write engine on first packed beat (not enc_done).
    // OPT-BP1: Also reset wr_started on wr_done for back-to-back block support.
    always @(posedge clk) begin
        if (!rstn) begin
            wr_start_pulse_r    <= 1'b0;
            wr_started          <= 1'b0;
            write_beat_tvalid_d <= 1'b0;
        end else if (clear) begin
            wr_start_pulse_r    <= 1'b0;
            wr_started          <= 1'b0;
            write_beat_tvalid_d <= 1'b0;
        end else begin
            wr_start_pulse_r    <= 1'b0;
            write_beat_tvalid_d <= write_beat_tvalid;
            if (start && !chain_busy_i) begin
                wr_started <= 1'b0;
            end else if (wr_done) begin
                wr_started          <= 1'b0;
                write_beat_tvalid_d <= 1'b0;
            end else if (!wr_started && write_beat_tvalid && !write_beat_tvalid_d) begin
                wr_start_pulse_r <= 1'b1;
                wr_started       <= 1'b1;
            end
        end
    end

    assign m_axi_chain_araddr  = {AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_chain_arlen   = 8'd0;
    assign m_axi_chain_arsize  = 3'd0;
    assign m_axi_chain_arburst = 2'd0;
    assign m_axi_chain_arvalid = 1'b0;
    assign m_axi_chain_rready  = 1'b0;

    assign merge_bytes_written = 32'd0;
    assign merge_beats_written = 32'd0;
    assign stage5_bytes_read   = 32'd0;
    assign stage5_beats_read   = 32'd0;

    assign chain_busy_i  = merge_top_busy | enc_busy | wr_busy;
    assign chain_done_i  = wr_done;
    assign chain_error_i = merge_top_error | enc_error | wr_error;

    assign busy  = source0_busy_i | source1_busy_i | chain_busy_i;
    assign done  = chain_done_i;
    assign error = source0_error_i | source1_error_i | chain_error_i;

endmodule
