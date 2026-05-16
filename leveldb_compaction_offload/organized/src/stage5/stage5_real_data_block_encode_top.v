`timescale 1ns / 1ps

module stage5_real_data_block_encode_top #(
    parameter integer AXI_ADDR_WIDTH     = 64,
    parameter integer AXI_DATA_WIDTH     = 512,
    parameter integer AXI_ID_WIDTH       = 1,
    parameter integer MAX_BURST_LEN      = 16,
    parameter integer MAX_RECORDS        = 256,
    parameter integer MAX_PAYLOAD_BYTES  = 4096,
    parameter integer MAX_BLOCK_BYTES    = 4096,
    parameter integer MAX_KEY_BYTES      = 256,
    parameter integer MAX_VALUE_BYTES    = 1024,
    parameter integer RESTART_INTERVAL   = 16
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
    output wire [31:0]                   input_record_count,
    output wire [31:0]                   encoded_entry_count,
    output wire [31:0]                   restart_count,
    output wire [31:0]                   shared_key_bytes_total,
    output wire [31:0]                   unshared_key_bytes_total,
    output wire [31:0]                   value_bytes_total,
    output wire [15:0]                   last_key_len,
    output wire [15:0]                   last_value_len,
    output wire [15:0]                   last_shared_bytes,
    output wire [15:0]                   last_non_shared_bytes,
    output wire [31:0]                   output_block_bytes,

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

    wire [AXI_DATA_WIDTH-1:0] read_beat_tdata;
    wire [AXI_KEEP_WIDTH-1:0] read_beat_tkeep;
    wire                      read_beat_tlast;
    wire                      read_beat_tvalid;
    wire                      read_beat_tready;

    wire [7:0]                read_byte_tdata;
    wire [0:0]                read_byte_tkeep;
    wire                      read_byte_tlast;
    wire                      read_byte_tvalid;
    wire                      read_byte_tready;

    wire [7:0]                enc_byte_tdata;
    wire [0:0]                enc_byte_tkeep;
    wire                      enc_byte_tlast;
    wire                      enc_byte_tvalid;
    wire                      enc_byte_tready;

    wire [AXI_DATA_WIDTH-1:0] write_beat_tdata;
    wire [AXI_KEEP_WIDTH-1:0] write_beat_tkeep;
    wire                      write_beat_tlast;
    wire                      write_beat_tvalid;
    wire                      write_beat_tready;

    wire rd_busy;
    wire rd_error;
    wire enc_busy;
    wire enc_done;
    wire enc_error;
    wire wr_busy;
    wire wr_done;
    wire wr_error;

    reg  enc_byte_tvalid_d;
    reg  wr_start_pulse_r;
    reg  wr_started;

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
        .byte_count(src_byte_count),
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
        .m_axis_tdata(read_beat_tdata),
        .m_axis_tkeep(read_beat_tkeep),
        .m_axis_tlast(read_beat_tlast),
        .m_axis_tvalid(read_beat_tvalid),
        .m_axis_tready(read_beat_tready)
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
        .s_axis_tdata(read_beat_tdata),
        .s_axis_tkeep(read_beat_tkeep),
        .s_axis_tlast(read_beat_tlast),
        .s_axis_tvalid(read_beat_tvalid),
        .s_axis_tready(read_beat_tready),
        .m_axis_tdata(read_byte_tdata),
        .m_axis_tkeep(read_byte_tkeep),
        .m_axis_tlast(read_byte_tlast),
        .m_axis_tvalid(read_byte_tvalid),
        .m_axis_tready(read_byte_tready)
    );

    real_data_block_encoder #(
        .MAX_RECORDS(MAX_RECORDS),
        .MAX_PAYLOAD_BYTES(MAX_PAYLOAD_BYTES),
        .MAX_BLOCK_BYTES(MAX_BLOCK_BYTES),
        .MAX_KEY_BYTES(MAX_KEY_BYTES),
        .MAX_VALUE_BYTES(MAX_VALUE_BYTES),
        .RESTART_INTERVAL(RESTART_INTERVAL)
    ) u_real_data_block_encoder (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .s_axis_tdata(read_byte_tdata),
        .s_axis_tkeep(read_byte_tkeep),
        .s_axis_tlast(read_byte_tlast),
        .s_axis_tvalid(read_byte_tvalid),
        .s_axis_tready(read_byte_tready),
        .m_axis_tdata(enc_byte_tdata),
        .m_axis_tkeep(enc_byte_tkeep),
        .m_axis_tlast(enc_byte_tlast),
        .m_axis_tvalid(enc_byte_tvalid),
        .m_axis_tready(enc_byte_tready),
        .busy(enc_busy),
        .done(enc_done),
        .error(enc_error),
        .input_record_count(input_record_count),
        .encoded_entry_count(encoded_entry_count),
        .restart_count(restart_count),
        .shared_key_bytes_total(shared_key_bytes_total),
        .unshared_key_bytes_total(unshared_key_bytes_total),
        .value_bytes_total(value_bytes_total),
        .last_key_len(last_key_len),
        .last_value_len(last_value_len),
        .last_shared_bytes(last_shared_bytes),
        .last_non_shared_bytes(last_non_shared_bytes),
        .output_block_bytes(output_block_bytes)
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
        .s_axis_tdata(enc_byte_tdata),
        .s_axis_tkeep(enc_byte_tkeep),
        .s_axis_tlast(enc_byte_tlast),
        .s_axis_tvalid(enc_byte_tvalid),
        .s_axis_tready(enc_byte_tready),
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
        .byte_count(output_block_bytes),
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
            enc_byte_tvalid_d <= 1'b0;
            wr_start_pulse_r  <= 1'b0;
            wr_started        <= 1'b0;
        end else if (clear) begin
            enc_byte_tvalid_d <= 1'b0;
            wr_start_pulse_r  <= 1'b0;
            wr_started        <= 1'b0;
        end else begin
            wr_start_pulse_r <= 1'b0;
            enc_byte_tvalid_d <= enc_byte_tvalid;

            if (start && !busy) begin
                wr_started <= 1'b0;
            end else if (!wr_started && enc_byte_tvalid && !enc_byte_tvalid_d) begin
                wr_start_pulse_r <= 1'b1;
                wr_started <= 1'b1;
            end
        end
    end

    assign busy  = rd_busy | enc_busy | wr_busy;
    assign done  = wr_done;
    assign error = rd_error | enc_error | wr_error;

endmodule
