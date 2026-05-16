`timescale 1ns / 1ps

module stage4_stage5_chain_top #(
    parameter integer AXI_ADDR_WIDTH     = 64,
    parameter integer AXI_DATA_WIDTH     = 512,
    parameter integer AXI_ID_WIDTH       = 1,
    parameter integer MAX_BURST_LEN      = 16,
    parameter integer STAGE4_MAX_BLOCK_BYTES  = 4096,
    parameter integer STAGE4_MAX_KEY_BYTES    = 256,
    parameter integer STAGE4_MAX_RECORDS      = 256,
    parameter integer STAGE4_MAX_OUTPUT_BYTES = 73728,
    parameter integer STAGE5_MAX_RECORDS      = 256,
    parameter integer STAGE5_MAX_PAYLOAD_BYTES = 4096,
    parameter integer STAGE5_MAX_BLOCK_BYTES   = 4096,
    parameter integer STAGE5_MAX_KEY_BYTES     = 256,
    parameter integer STAGE5_MAX_VALUE_BYTES   = 1024,
    parameter integer STAGE5_RESTART_INTERVAL  = 16
) (
    input  wire                          clk,
    input  wire                          rstn,
    input  wire                          clear,
    input  wire                          start,
    input  wire [AXI_ADDR_WIDTH-1:0]     src_base_addr,
    input  wire [31:0]                   src_byte_count,
    input  wire [AXI_ADDR_WIDTH-1:0]     mid_base_addr,
    input  wire [AXI_ADDR_WIDTH-1:0]     dst_base_addr,
    output wire                          busy,
    output wire                          done,
    output wire                          error,
    output wire                          stage4_done,
    output wire                          stage5_done,
    output wire [31:0]                   stage4_bytes_read,
    output wire [31:0]                   stage4_beats_read,
    output wire [31:0]                   stage4_bytes_written,
    output wire [31:0]                   stage4_beats_written,
    output wire [31:0]                   stage4_output_byte_count,
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
    output wire [15:0]                   stage5_last_key_len,
    output wire [15:0]                   stage5_last_value_len,
    output wire [15:0]                   stage5_last_shared_bytes,
    output wire [15:0]                   stage5_last_non_shared_bytes,
    output wire [31:0]                   stage5_output_block_bytes,

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

    localparam [1:0] PHASE_IDLE   = 2'd0;
    localparam [1:0] PHASE_STAGE4 = 2'd1;
    localparam [1:0] PHASE_STAGE5 = 2'd2;

    reg [1:0] phase;
    reg       stage4_done_d;
    reg       stage5_done_d;
    reg       stage5_start_r;

    wire stage4_start;
    wire stage5_start;
    wire stage4_busy_i;
    wire stage4_done_i;
    wire stage4_error_i;
    wire stage5_busy_i;
    wire stage5_done_i;
    wire stage5_error_i;

    wire [AXI_ADDR_WIDTH-1:0] stage4_m_axi_araddr;
    wire [7:0]                stage4_m_axi_arlen;
    wire [2:0]                stage4_m_axi_arsize;
    wire [1:0]                stage4_m_axi_arburst;
    wire [AXI_ID_WIDTH-1:0]   stage4_m_axi_arid;
    wire                      stage4_m_axi_arvalid;
    wire                      stage4_m_axi_arready;
    wire [AXI_DATA_WIDTH-1:0] stage4_m_axi_rdata;
    wire [1:0]                stage4_m_axi_rresp;
    wire                      stage4_m_axi_rlast;
    wire [AXI_ID_WIDTH-1:0]   stage4_m_axi_rid;
    wire                      stage4_m_axi_rvalid;
    wire                      stage4_m_axi_rready;
    wire [AXI_ADDR_WIDTH-1:0] stage4_m_axi_awaddr;
    wire [7:0]                stage4_m_axi_awlen;
    wire [2:0]                stage4_m_axi_awsize;
    wire [1:0]                stage4_m_axi_awburst;
    wire [AXI_ID_WIDTH-1:0]   stage4_m_axi_awid;
    wire                      stage4_m_axi_awvalid;
    wire                      stage4_m_axi_awready;
    wire [AXI_DATA_WIDTH-1:0] stage4_m_axi_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] stage4_m_axi_wstrb;
    wire                      stage4_m_axi_wlast;
    wire                      stage4_m_axi_wvalid;
    wire                      stage4_m_axi_wready;
    wire [1:0]                stage4_m_axi_bresp;
    wire [AXI_ID_WIDTH-1:0]   stage4_m_axi_bid;
    wire                      stage4_m_axi_bvalid;
    wire                      stage4_m_axi_bready;

    wire [AXI_ADDR_WIDTH-1:0] stage5_m_axi_araddr;
    wire [7:0]                stage5_m_axi_arlen;
    wire [2:0]                stage5_m_axi_arsize;
    wire [1:0]                stage5_m_axi_arburst;
    wire [AXI_ID_WIDTH-1:0]   stage5_m_axi_arid;
    wire                      stage5_m_axi_arvalid;
    wire                      stage5_m_axi_arready;
    wire [AXI_DATA_WIDTH-1:0] stage5_m_axi_rdata;
    wire [1:0]                stage5_m_axi_rresp;
    wire                      stage5_m_axi_rlast;
    wire [AXI_ID_WIDTH-1:0]   stage5_m_axi_rid;
    wire                      stage5_m_axi_rvalid;
    wire                      stage5_m_axi_rready;
    wire [AXI_ADDR_WIDTH-1:0] stage5_m_axi_awaddr;
    wire [7:0]                stage5_m_axi_awlen;
    wire [2:0]                stage5_m_axi_awsize;
    wire [1:0]                stage5_m_axi_awburst;
    wire [AXI_ID_WIDTH-1:0]   stage5_m_axi_awid;
    wire                      stage5_m_axi_awvalid;
    wire                      stage5_m_axi_awready;
    wire [AXI_DATA_WIDTH-1:0] stage5_m_axi_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] stage5_m_axi_wstrb;
    wire                      stage5_m_axi_wlast;
    wire                      stage5_m_axi_wvalid;
    wire                      stage5_m_axi_wready;
    wire [1:0]                stage5_m_axi_bresp;
    wire [AXI_ID_WIDTH-1:0]   stage5_m_axi_bid;
    wire                      stage5_m_axi_bvalid;
    wire                      stage5_m_axi_bready;

    assign stage4_start = start && (phase == PHASE_IDLE);
    assign stage5_start = stage5_start_r;

    stage4_real_data_block_record_emit_writeback_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .MAX_BLOCK_BYTES(STAGE4_MAX_BLOCK_BYTES),
        .MAX_KEY_BYTES(STAGE4_MAX_KEY_BYTES),
        .MAX_RECORDS(STAGE4_MAX_RECORDS),
        .MAX_OUTPUT_BYTES(STAGE4_MAX_OUTPUT_BYTES)
    ) u_stage4_writeback (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(stage4_start),
        .src_base_addr(src_base_addr),
        .src_byte_count(src_byte_count),
        .dst_base_addr(mid_base_addr),
        .busy(stage4_busy_i),
        .done(stage4_done_i),
        .error(stage4_error_i),
        .bytes_read(stage4_bytes_read),
        .beats_read(stage4_beats_read),
        .bytes_written(stage4_bytes_written),
        .beats_written(stage4_beats_written),
        .output_byte_count(stage4_output_byte_count),
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
        .m_axi_araddr(stage4_m_axi_araddr),
        .m_axi_arlen(stage4_m_axi_arlen),
        .m_axi_arsize(stage4_m_axi_arsize),
        .m_axi_arburst(stage4_m_axi_arburst),
        .m_axi_arid(stage4_m_axi_arid),
        .m_axi_arvalid(stage4_m_axi_arvalid),
        .m_axi_arready(stage4_m_axi_arready),
        .m_axi_rdata(stage4_m_axi_rdata),
        .m_axi_rresp(stage4_m_axi_rresp),
        .m_axi_rlast(stage4_m_axi_rlast),
        .m_axi_rid(stage4_m_axi_rid),
        .m_axi_rvalid(stage4_m_axi_rvalid),
        .m_axi_rready(stage4_m_axi_rready),
        .m_axi_awaddr(stage4_m_axi_awaddr),
        .m_axi_awlen(stage4_m_axi_awlen),
        .m_axi_awsize(stage4_m_axi_awsize),
        .m_axi_awburst(stage4_m_axi_awburst),
        .m_axi_awid(stage4_m_axi_awid),
        .m_axi_awvalid(stage4_m_axi_awvalid),
        .m_axi_awready(stage4_m_axi_awready),
        .m_axi_wdata(stage4_m_axi_wdata),
        .m_axi_wstrb(stage4_m_axi_wstrb),
        .m_axi_wlast(stage4_m_axi_wlast),
        .m_axi_wvalid(stage4_m_axi_wvalid),
        .m_axi_wready(stage4_m_axi_wready),
        .m_axi_bresp(stage4_m_axi_bresp),
        .m_axi_bid(stage4_m_axi_bid),
        .m_axi_bvalid(stage4_m_axi_bvalid),
        .m_axi_bready(stage4_m_axi_bready)
    );

    stage5_real_data_block_encode_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .MAX_RECORDS(STAGE5_MAX_RECORDS),
        .MAX_PAYLOAD_BYTES(STAGE5_MAX_PAYLOAD_BYTES),
        .MAX_BLOCK_BYTES(STAGE5_MAX_BLOCK_BYTES),
        .MAX_KEY_BYTES(STAGE5_MAX_KEY_BYTES),
        .MAX_VALUE_BYTES(STAGE5_MAX_VALUE_BYTES),
        .RESTART_INTERVAL(STAGE5_RESTART_INTERVAL)
    ) u_stage5_encode (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(stage5_start),
        .src_base_addr(mid_base_addr),
        .src_byte_count(stage4_output_byte_count),
        .dst_base_addr(dst_base_addr),
        .busy(stage5_busy_i),
        .done(stage5_done_i),
        .error(stage5_error_i),
        .bytes_read(stage5_bytes_read),
        .beats_read(stage5_beats_read),
        .bytes_written(stage5_bytes_written),
        .beats_written(stage5_beats_written),
        .input_record_count(stage5_input_record_count),
        .encoded_entry_count(stage5_encoded_entry_count),
        .restart_count(stage5_restart_count),
        .shared_key_bytes_total(stage5_shared_key_bytes_total),
        .unshared_key_bytes_total(stage5_unshared_key_bytes_total),
        .value_bytes_total(stage5_value_bytes_total),
        .last_key_len(stage5_last_key_len),
        .last_value_len(stage5_last_value_len),
        .last_shared_bytes(stage5_last_shared_bytes),
        .last_non_shared_bytes(stage5_last_non_shared_bytes),
        .output_block_bytes(stage5_output_block_bytes),
        .m_axi_araddr(stage5_m_axi_araddr),
        .m_axi_arlen(stage5_m_axi_arlen),
        .m_axi_arsize(stage5_m_axi_arsize),
        .m_axi_arburst(stage5_m_axi_arburst),
        .m_axi_arid(stage5_m_axi_arid),
        .m_axi_arvalid(stage5_m_axi_arvalid),
        .m_axi_arready(stage5_m_axi_arready),
        .m_axi_rdata(stage5_m_axi_rdata),
        .m_axi_rresp(stage5_m_axi_rresp),
        .m_axi_rlast(stage5_m_axi_rlast),
        .m_axi_rid(stage5_m_axi_rid),
        .m_axi_rvalid(stage5_m_axi_rvalid),
        .m_axi_rready(stage5_m_axi_rready),
        .m_axi_awaddr(stage5_m_axi_awaddr),
        .m_axi_awlen(stage5_m_axi_awlen),
        .m_axi_awsize(stage5_m_axi_awsize),
        .m_axi_awburst(stage5_m_axi_awburst),
        .m_axi_awid(stage5_m_axi_awid),
        .m_axi_awvalid(stage5_m_axi_awvalid),
        .m_axi_awready(stage5_m_axi_awready),
        .m_axi_wdata(stage5_m_axi_wdata),
        .m_axi_wstrb(stage5_m_axi_wstrb),
        .m_axi_wlast(stage5_m_axi_wlast),
        .m_axi_wvalid(stage5_m_axi_wvalid),
        .m_axi_wready(stage5_m_axi_wready),
        .m_axi_bresp(stage5_m_axi_bresp),
        .m_axi_bid(stage5_m_axi_bid),
        .m_axi_bvalid(stage5_m_axi_bvalid),
        .m_axi_bready(stage5_m_axi_bready)
    );

    always @(posedge clk) begin
        if (!rstn) begin
            phase        <= PHASE_IDLE;
            stage4_done_d <= 1'b0;
            stage5_done_d <= 1'b0;
            stage5_start_r <= 1'b0;
        end else if (clear) begin
            phase        <= PHASE_IDLE;
            stage4_done_d <= 1'b0;
            stage5_done_d <= 1'b0;
            stage5_start_r <= 1'b0;
        end else begin
            stage4_done_d  <= stage4_done_i;
            stage5_done_d  <= stage5_done_i;
            stage5_start_r <= 1'b0;

            if (start && (phase == PHASE_IDLE)) begin
                phase <= PHASE_STAGE4;
            end else if ((phase == PHASE_STAGE4) && stage4_done_i && !stage4_done_d) begin
                phase <= PHASE_STAGE5;
                stage5_start_r <= 1'b1;
            end else if ((phase == PHASE_STAGE5) && ((stage5_done_i && !stage5_done_d) || stage5_error_i)) begin
                phase <= PHASE_IDLE;
            end else if ((phase == PHASE_STAGE4) && stage4_error_i) begin
                phase <= PHASE_IDLE;
            end
        end
    end

    assign stage4_done = stage4_done_i;
    assign stage5_done = stage5_done_i;

    assign m_axi_araddr  = (phase == PHASE_STAGE5) ? stage5_m_axi_araddr  : stage4_m_axi_araddr;
    assign m_axi_arlen   = (phase == PHASE_STAGE5) ? stage5_m_axi_arlen   : stage4_m_axi_arlen;
    assign m_axi_arsize  = (phase == PHASE_STAGE5) ? stage5_m_axi_arsize  : stage4_m_axi_arsize;
    assign m_axi_arburst = (phase == PHASE_STAGE5) ? stage5_m_axi_arburst : stage4_m_axi_arburst;
    assign m_axi_arid    = (phase == PHASE_STAGE5) ? stage5_m_axi_arid    : stage4_m_axi_arid;
    assign m_axi_arvalid = (phase == PHASE_STAGE5) ? stage5_m_axi_arvalid : stage4_m_axi_arvalid;
    assign m_axi_rready  = (phase == PHASE_STAGE5) ? stage5_m_axi_rready  : stage4_m_axi_rready;

    assign stage4_m_axi_arready = (phase == PHASE_STAGE4) ? m_axi_arready : 1'b0;
    assign stage4_m_axi_rdata   = (phase == PHASE_STAGE4) ? m_axi_rdata   : {AXI_DATA_WIDTH{1'b0}};
    assign stage4_m_axi_rresp   = (phase == PHASE_STAGE4) ? m_axi_rresp   : 2'b00;
    assign stage4_m_axi_rlast   = (phase == PHASE_STAGE4) ? m_axi_rlast   : 1'b0;
    assign stage4_m_axi_rid     = (phase == PHASE_STAGE4) ? m_axi_rid     : {AXI_ID_WIDTH{1'b0}};
    assign stage4_m_axi_rvalid  = (phase == PHASE_STAGE4) ? m_axi_rvalid  : 1'b0;

    assign stage5_m_axi_arready = (phase == PHASE_STAGE5) ? m_axi_arready : 1'b0;
    assign stage5_m_axi_rdata   = (phase == PHASE_STAGE5) ? m_axi_rdata   : {AXI_DATA_WIDTH{1'b0}};
    assign stage5_m_axi_rresp   = (phase == PHASE_STAGE5) ? m_axi_rresp   : 2'b00;
    assign stage5_m_axi_rlast   = (phase == PHASE_STAGE5) ? m_axi_rlast   : 1'b0;
    assign stage5_m_axi_rid     = (phase == PHASE_STAGE5) ? m_axi_rid     : {AXI_ID_WIDTH{1'b0}};
    assign stage5_m_axi_rvalid  = (phase == PHASE_STAGE5) ? m_axi_rvalid  : 1'b0;

    assign m_axi_awaddr  = (phase == PHASE_STAGE5) ? stage5_m_axi_awaddr  : stage4_m_axi_awaddr;
    assign m_axi_awlen   = (phase == PHASE_STAGE5) ? stage5_m_axi_awlen   : stage4_m_axi_awlen;
    assign m_axi_awsize  = (phase == PHASE_STAGE5) ? stage5_m_axi_awsize  : stage4_m_axi_awsize;
    assign m_axi_awburst = (phase == PHASE_STAGE5) ? stage5_m_axi_awburst : stage4_m_axi_awburst;
    assign m_axi_awid    = (phase == PHASE_STAGE5) ? stage5_m_axi_awid    : stage4_m_axi_awid;
    assign m_axi_awvalid = (phase == PHASE_STAGE5) ? stage5_m_axi_awvalid : stage4_m_axi_awvalid;
    assign m_axi_wdata   = (phase == PHASE_STAGE5) ? stage5_m_axi_wdata   : stage4_m_axi_wdata;
    assign m_axi_wstrb   = (phase == PHASE_STAGE5) ? stage5_m_axi_wstrb   : stage4_m_axi_wstrb;
    assign m_axi_wlast   = (phase == PHASE_STAGE5) ? stage5_m_axi_wlast   : stage4_m_axi_wlast;
    assign m_axi_wvalid  = (phase == PHASE_STAGE5) ? stage5_m_axi_wvalid  : stage4_m_axi_wvalid;
    assign m_axi_bready  = (phase == PHASE_STAGE5) ? stage5_m_axi_bready  : stage4_m_axi_bready;

    assign stage4_m_axi_awready = (phase == PHASE_STAGE4) ? m_axi_awready : 1'b0;
    assign stage4_m_axi_wready  = (phase == PHASE_STAGE4) ? m_axi_wready  : 1'b0;
    assign stage4_m_axi_bresp   = (phase == PHASE_STAGE4) ? m_axi_bresp   : 2'b00;
    assign stage4_m_axi_bid     = (phase == PHASE_STAGE4) ? m_axi_bid     : {AXI_ID_WIDTH{1'b0}};
    assign stage4_m_axi_bvalid  = (phase == PHASE_STAGE4) ? m_axi_bvalid  : 1'b0;

    assign stage5_m_axi_awready = (phase == PHASE_STAGE5) ? m_axi_awready : 1'b0;
    assign stage5_m_axi_wready  = (phase == PHASE_STAGE5) ? m_axi_wready  : 1'b0;
    assign stage5_m_axi_bresp   = (phase == PHASE_STAGE5) ? m_axi_bresp   : 2'b00;
    assign stage5_m_axi_bid     = (phase == PHASE_STAGE5) ? m_axi_bid     : {AXI_ID_WIDTH{1'b0}};
    assign stage5_m_axi_bvalid  = (phase == PHASE_STAGE5) ? m_axi_bvalid  : 1'b0;

    assign busy  = (phase != PHASE_IDLE) || stage4_busy_i || stage5_busy_i;
    assign done  = stage5_done_i;
    assign error = stage4_error_i | stage5_error_i;

endmodule
