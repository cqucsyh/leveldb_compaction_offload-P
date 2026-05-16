`timescale 1ns / 1ps

module axi_read_engine #(
    parameter integer AXI_ADDR_WIDTH = 64,
    parameter integer AXI_DATA_WIDTH = 512,
    parameter integer AXI_ID_WIDTH   = 1,
    parameter integer MAX_BURST_LEN  = 16
) (
    input  wire                              clk,
    input  wire                              rstn,
    input  wire                              clear,
    input  wire                              start,
    input  wire [AXI_ADDR_WIDTH-1:0]         base_addr,
    input  wire [31:0]                       byte_count,
    output reg                               busy,
    output reg                               done,
    output reg                               error,
    output reg  [31:0]                       bytes_read,
    output reg  [31:0]                       beats_read,

    output reg  [AXI_ADDR_WIDTH-1:0]         m_axi_araddr,
    output reg  [7:0]                        m_axi_arlen,
    output reg  [2:0]                        m_axi_arsize,
    output reg  [1:0]                        m_axi_arburst,
    output reg  [AXI_ID_WIDTH-1:0]           m_axi_arid,
    output reg                               m_axi_arvalid,
    input  wire                              m_axi_arready,
    input  wire [AXI_DATA_WIDTH-1:0]         m_axi_rdata,
    input  wire [1:0]                        m_axi_rresp,
    input  wire                              m_axi_rlast,
    input  wire [AXI_ID_WIDTH-1:0]           m_axi_rid,
    input  wire                              m_axi_rvalid,
    output wire                              m_axi_rready,

    output wire [AXI_DATA_WIDTH-1:0]         m_axis_tdata,
    output wire [(AXI_DATA_WIDTH/8)-1:0]     m_axis_tkeep,
    output wire                              m_axis_tlast,
    output wire                              m_axis_tvalid,
    input  wire                              m_axis_tready
);

    localparam integer AXI_KEEP_WIDTH = AXI_DATA_WIDTH / 8;
    localparam integer AXI_BEAT_BYTES = AXI_DATA_WIDTH / 8;
    localparam integer AXI_BEAT_SHIFT = $clog2(AXI_BEAT_BYTES);
    localparam [2:0]   AXI_BURST_SIZE = AXI_BEAT_SHIFT[2:0];

    reg [31:0]                beats_remaining;
    reg [31:0]                beats_in_burst_remaining;
    reg [AXI_ADDR_WIDTH-1:0]  next_addr;
    reg                       waiting_for_r;

    reg [AXI_DATA_WIDTH-1:0]  out_data;
    reg [AXI_KEEP_WIDTH-1:0]  out_keep;
    reg                       out_last;
    reg                       out_valid;

    wire                      out_accept;
    wire                      can_take_r;
    wire [31:0]               total_beats_start;
    wire [7:0]                next_burst_len;
    wire                      current_is_last;
    wire [AXI_KEEP_WIDTH-1:0] final_keep_mask;

    integer i;
    reg [AXI_KEEP_WIDTH-1:0] final_keep_mask_r;
    reg [31:0] bytes_this_beat;

    assign total_beats_start = (byte_count + AXI_BEAT_BYTES - 1) >> AXI_BEAT_SHIFT;
    assign next_burst_len = (beats_remaining > MAX_BURST_LEN) ? MAX_BURST_LEN[7:0] : beats_remaining[7:0];
    assign current_is_last = (beats_remaining == 32'd1);

    always @(*) begin
        final_keep_mask_r = {AXI_KEEP_WIDTH{1'b0}};
        if (byte_count[AXI_BEAT_SHIFT-1:0] == {AXI_BEAT_SHIFT{1'b0}}) begin
            final_keep_mask_r = {AXI_KEEP_WIDTH{1'b1}};
        end else begin
            for (i = 0; i < AXI_KEEP_WIDTH; i = i + 1) begin
                if (i < byte_count[AXI_BEAT_SHIFT-1:0]) begin
                    final_keep_mask_r[i] = 1'b1;
                end
            end
        end
    end

    assign final_keep_mask = final_keep_mask_r;
    assign m_axis_tdata  = out_data;
    assign m_axis_tkeep  = out_keep;
    assign m_axis_tlast  = out_last;
    assign m_axis_tvalid = out_valid;

    assign out_accept = out_valid && m_axis_tready;
    assign can_take_r = (!out_valid) || m_axis_tready;
    assign m_axi_rready = can_take_r;

    always @(posedge clk) begin
        if (!rstn) begin
            busy                       <= 1'b0;
            done                       <= 1'b0;
            error                      <= 1'b0;
            bytes_read                 <= 32'd0;
            beats_read                 <= 32'd0;
            beats_remaining            <= 32'd0;
            beats_in_burst_remaining   <= 32'd0;
            next_addr                  <= {AXI_ADDR_WIDTH{1'b0}};
            waiting_for_r              <= 1'b0;
            m_axi_araddr               <= {AXI_ADDR_WIDTH{1'b0}};
            m_axi_arlen                <= 8'd0;
            m_axi_arsize               <= AXI_BURST_SIZE;
            m_axi_arburst              <= 2'b01;
            m_axi_arid                 <= {AXI_ID_WIDTH{1'b0}};
            m_axi_arvalid              <= 1'b0;
            out_data                   <= {AXI_DATA_WIDTH{1'b0}};
            out_keep                   <= {AXI_KEEP_WIDTH{1'b0}};
            out_last                   <= 1'b0;
            out_valid                  <= 1'b0;
        end else if (clear) begin
            busy                       <= 1'b0;
            done                       <= 1'b0;
            error                      <= 1'b0;
            bytes_read                 <= 32'd0;
            beats_read                 <= 32'd0;
            beats_remaining            <= 32'd0;
            beats_in_burst_remaining   <= 32'd0;
            next_addr                  <= {AXI_ADDR_WIDTH{1'b0}};
            waiting_for_r              <= 1'b0;
            m_axi_araddr               <= {AXI_ADDR_WIDTH{1'b0}};
            m_axi_arlen                <= 8'd0;
            m_axi_arsize               <= AXI_BURST_SIZE;
            m_axi_arburst              <= 2'b01;
            m_axi_arid                 <= {AXI_ID_WIDTH{1'b0}};
            m_axi_arvalid              <= 1'b0;
            out_data                   <= {AXI_DATA_WIDTH{1'b0}};
            out_keep                   <= {AXI_KEEP_WIDTH{1'b0}};
            out_last                   <= 1'b0;
            out_valid                  <= 1'b0;
        end else begin
            done <= 1'b0;

            if (out_accept && !m_axi_rvalid) begin
                out_valid <= 1'b0;
            end

            if (start && !busy) begin
                busy                     <= (byte_count != 32'd0);
                error                    <= 1'b0;
                done                     <= (byte_count == 32'd0);
                bytes_read               <= 32'd0;
                beats_read               <= 32'd0;
                beats_remaining          <= total_beats_start;
                beats_in_burst_remaining <= 32'd0;
                next_addr                <= base_addr;
                waiting_for_r            <= 1'b0;
                m_axi_arvalid            <= 1'b0;
                out_valid                <= 1'b0;
            end else if (busy) begin
                if (!m_axi_arvalid && !waiting_for_r && (beats_remaining != 32'd0)) begin
                    m_axi_araddr  <= next_addr;
                    m_axi_arlen   <= next_burst_len - 8'd1;
                    m_axi_arsize  <= AXI_BURST_SIZE;
                    m_axi_arburst <= 2'b01;
                    m_axi_arid    <= {AXI_ID_WIDTH{1'b0}};
                    m_axi_arvalid <= 1'b1;
                end

                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid            <= 1'b0;
                    waiting_for_r            <= 1'b1;
                    beats_in_burst_remaining <= next_burst_len;
                    next_addr                <= next_addr + ({ {(AXI_ADDR_WIDTH-8){1'b0}}, next_burst_len } << AXI_BEAT_SHIFT);
                end

                if (m_axi_rvalid && can_take_r) begin
                    out_data  <= m_axi_rdata;
                    out_keep  <= current_is_last ? final_keep_mask : {AXI_KEEP_WIDTH{1'b1}};
                    out_last  <= current_is_last;
                    out_valid <= 1'b1;

                    if (m_axi_rresp != 2'b00) begin
                        error <= 1'b1;
                    end

                    bytes_this_beat = current_is_last ? ((byte_count[AXI_BEAT_SHIFT-1:0] == {AXI_BEAT_SHIFT{1'b0}}) ? AXI_BEAT_BYTES : byte_count[AXI_BEAT_SHIFT-1:0]) : AXI_BEAT_BYTES;
                    bytes_read <= bytes_read + bytes_this_beat;
                    beats_read <= beats_read + 32'd1;

                    if (beats_remaining != 32'd0) begin
                        beats_remaining <= beats_remaining - 32'd1;
                    end

                    if (beats_in_burst_remaining != 32'd0) begin
                        beats_in_burst_remaining <= beats_in_burst_remaining - 32'd1;
                        if (beats_in_burst_remaining == 32'd1) begin
                            waiting_for_r <= 1'b0;
                        end
                    end

                    if ((m_axi_rlast != 1'b1) && (beats_in_burst_remaining == 32'd1)) begin
                        error <= 1'b1;
                    end
                    if ((m_axi_rlast == 1'b1) && (beats_in_burst_remaining != 32'd1)) begin
                        error <= 1'b1;
                    end

                    if (current_is_last) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        waiting_for_r <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
