`timescale 1ns / 1ps

module axi_write_engine #(
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
    output reg  [31:0]                       bytes_written,
    output reg  [31:0]                       beats_written,

    input  wire [AXI_DATA_WIDTH-1:0]         s_axis_tdata,
    input  wire [(AXI_DATA_WIDTH/8)-1:0]     s_axis_tkeep,
    input  wire                              s_axis_tlast,
    input  wire                              s_axis_tvalid,
    output wire                              s_axis_tready,

    output reg  [AXI_ADDR_WIDTH-1:0]         m_axi_awaddr,
    output reg  [7:0]                        m_axi_awlen,
    output reg  [2:0]                        m_axi_awsize,
    output reg  [1:0]                        m_axi_awburst,
    output reg  [AXI_ID_WIDTH-1:0]           m_axi_awid,
    output reg                               m_axi_awvalid,
    input  wire                              m_axi_awready,
    output reg  [AXI_DATA_WIDTH-1:0]         m_axi_wdata,
    output reg  [(AXI_DATA_WIDTH/8)-1:0]     m_axi_wstrb,
    output reg                               m_axi_wlast,
    output reg                               m_axi_wvalid,
    input  wire                              m_axi_wready,
    input  wire [1:0]                        m_axi_bresp,
    input  wire [AXI_ID_WIDTH-1:0]           m_axi_bid,
    input  wire                              m_axi_bvalid,
    output reg                               m_axi_bready
);

    localparam integer AXI_KEEP_WIDTH = AXI_DATA_WIDTH / 8;
    localparam integer AXI_BEAT_BYTES = AXI_DATA_WIDTH / 8;
    localparam integer AXI_BEAT_SHIFT = $clog2(AXI_BEAT_BYTES);
    localparam [2:0]   AXI_BURST_SIZE = AXI_BEAT_SHIFT[2:0];

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_AW   = 2'd1;
    localparam [1:0] ST_W    = 2'd2;
    localparam [1:0] ST_B    = 2'd3;

    reg [1:0]                state;
    reg [31:0]               beats_remaining;
    reg [31:0]               burst_beats;
    reg [31:0]               burst_index;
    reg [AXI_ADDR_WIDTH-1:0] cur_addr;

    wire [7:0] next_burst_len;
    wire       take_input;
    wire       w_handshake;
    wire [31:0] bytes_this_beat;

    assign next_burst_len = (beats_remaining > MAX_BURST_LEN) ? MAX_BURST_LEN[7:0] : beats_remaining[7:0];
    assign s_axis_tready = busy && (state == ST_W) && !m_axi_wvalid;
    assign take_input = s_axis_tvalid && s_axis_tready;
    assign w_handshake = m_axi_wvalid && m_axi_wready;
    assign bytes_this_beat = keep_popcount(m_axi_wstrb);

    function automatic [31:0] keep_popcount;
        input [AXI_KEEP_WIDTH-1:0] keep;
        integer i;
        begin
            keep_popcount = 32'd0;
            for (i = 0; i < AXI_KEEP_WIDTH; i = i + 1) begin
                if (keep[i]) begin
                    keep_popcount = keep_popcount + 32'd1;
                end
            end
        end
    endfunction

    always @(posedge clk) begin
        if (!rstn) begin
            busy            <= 1'b0;
            done            <= 1'b0;
            error           <= 1'b0;
            bytes_written   <= 32'd0;
            beats_written   <= 32'd0;
            state           <= ST_IDLE;
            beats_remaining <= 32'd0;
            burst_beats     <= 32'd0;
            burst_index     <= 32'd0;
            cur_addr        <= {AXI_ADDR_WIDTH{1'b0}};
            m_axi_awaddr    <= {AXI_ADDR_WIDTH{1'b0}};
            m_axi_awlen     <= 8'd0;
            m_axi_awsize    <= AXI_BURST_SIZE;
            m_axi_awburst   <= 2'b01;
            m_axi_awid      <= {AXI_ID_WIDTH{1'b0}};
            m_axi_awvalid   <= 1'b0;
            m_axi_wdata     <= {AXI_DATA_WIDTH{1'b0}};
            m_axi_wstrb     <= {AXI_KEEP_WIDTH{1'b0}};
            m_axi_wlast     <= 1'b0;
            m_axi_wvalid    <= 1'b0;
            m_axi_bready    <= 1'b0;
        end else if (clear) begin
            busy            <= 1'b0;
            done            <= 1'b0;
            error           <= 1'b0;
            bytes_written   <= 32'd0;
            beats_written   <= 32'd0;
            state           <= ST_IDLE;
            beats_remaining <= 32'd0;
            burst_beats     <= 32'd0;
            burst_index     <= 32'd0;
            cur_addr        <= {AXI_ADDR_WIDTH{1'b0}};
            m_axi_awaddr    <= {AXI_ADDR_WIDTH{1'b0}};
            m_axi_awlen     <= 8'd0;
            m_axi_awsize    <= AXI_BURST_SIZE;
            m_axi_awburst   <= 2'b01;
            m_axi_awid      <= {AXI_ID_WIDTH{1'b0}};
            m_axi_awvalid   <= 1'b0;
            m_axi_wdata     <= {AXI_DATA_WIDTH{1'b0}};
            m_axi_wstrb     <= {AXI_KEEP_WIDTH{1'b0}};
            m_axi_wlast     <= 1'b0;
            m_axi_wvalid    <= 1'b0;
            m_axi_bready    <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                busy            <= (byte_count != 32'd0);
                done            <= (byte_count == 32'd0);
                error           <= 1'b0;
                bytes_written   <= 32'd0;
                beats_written   <= 32'd0;
                beats_remaining <= (byte_count + AXI_BEAT_BYTES - 1) >> AXI_BEAT_SHIFT;
                burst_beats     <= 32'd0;
                burst_index     <= 32'd0;
                cur_addr        <= base_addr;
                m_axi_awvalid   <= 1'b0;
                m_axi_wvalid    <= 1'b0;
                m_axi_bready    <= 1'b0;
                state           <= (byte_count == 32'd0) ? ST_IDLE : ST_AW;
            end else if (busy) begin
                case (state)
                    ST_AW: begin
                        if (!m_axi_awvalid) begin
                            burst_beats   <= next_burst_len;
                            burst_index   <= 32'd0;
                            m_axi_awaddr  <= cur_addr;
                            m_axi_awlen   <= next_burst_len - 8'd1;
                            m_axi_awsize  <= AXI_BURST_SIZE;
                            m_axi_awburst <= 2'b01;
                            m_axi_awid    <= {AXI_ID_WIDTH{1'b0}};
                            m_axi_awvalid <= 1'b1;
                        end

                        if (m_axi_awvalid && m_axi_awready) begin
                            m_axi_awvalid <= 1'b0;
                            state         <= ST_W;
                        end
                    end

                    ST_W: begin
                        if (take_input) begin
                            m_axi_wdata  <= s_axis_tdata;
                            m_axi_wstrb  <= s_axis_tkeep;
                            m_axi_wlast  <= (burst_index + 32'd1 == burst_beats);
                            m_axi_wvalid <= 1'b1;
                        end

                        if (w_handshake) begin
                            m_axi_wvalid    <= 1'b0;
                            bytes_written   <= bytes_written + bytes_this_beat;
                            beats_written   <= beats_written + 32'd1;
                            beats_remaining <= beats_remaining - 32'd1;
                            burst_index     <= burst_index + 32'd1;

                            if (m_axi_wlast) begin
                                m_axi_bready <= 1'b1;
                                state        <= ST_B;
                            end
                        end
                    end

                    ST_B: begin
                        if (m_axi_bvalid && m_axi_bready) begin
                            m_axi_bready <= 1'b0;
                            if (m_axi_bresp != 2'b00) begin
                                error <= 1'b1;
                            end

                            cur_addr <= cur_addr + (burst_beats << AXI_BEAT_SHIFT);
                            if (beats_remaining == 32'd0) begin
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                state <= ST_AW;
                            end
                        end
                    end

                    default: begin
                        state <= ST_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
