`timescale 1ns / 1ps

module stream_pack_adapter #(
    parameter integer IN_DATA_WIDTH  = 8,
    parameter integer IN_KEEP_WIDTH  = 1,
    parameter integer OUT_DATA_WIDTH = 512,
    parameter integer OUT_KEEP_WIDTH = OUT_DATA_WIDTH / 8
) (
    input  wire                       clk,
    input  wire                       rstn,
    input  wire                       clear,
    input  wire [IN_DATA_WIDTH-1:0]   s_axis_tdata,
    input  wire [IN_KEEP_WIDTH-1:0]   s_axis_tkeep,
    input  wire                       s_axis_tlast,
    input  wire                       s_axis_tvalid,
    output wire                       s_axis_tready,
    output wire [OUT_DATA_WIDTH-1:0]  m_axis_tdata,
    output wire [OUT_KEEP_WIDTH-1:0]  m_axis_tkeep,
    output wire                       m_axis_tlast,
    output wire                       m_axis_tvalid,
    input  wire                       m_axis_tready
);

    localparam integer IN_BYTES  = IN_DATA_WIDTH / 8;
    localparam integer OUT_BYTES = OUT_DATA_WIDTH / 8;
    localparam integer COUNT_W   = (OUT_BYTES <= 2) ? 1 : $clog2(OUT_BYTES + 1);

    reg [OUT_DATA_WIDTH-1:0] pack_data;
    reg [OUT_KEEP_WIDTH-1:0] pack_keep;
    reg [COUNT_W-1:0]        pack_count;
    reg                      pack_last_pending;
    reg                      out_valid;
    reg                      out_last;

    wire input_accept;
    wire output_accept;
    wire [COUNT_W-1:0] next_count;
    wire input_fills_packet;

    assign s_axis_tready = !out_valid;
    assign input_accept = s_axis_tvalid && s_axis_tready && s_axis_tkeep[0];
    assign output_accept = out_valid && m_axis_tready;
    assign next_count = pack_count + IN_BYTES[COUNT_W-1:0];
    assign input_fills_packet = (next_count == OUT_BYTES[COUNT_W-1:0]) || s_axis_tlast;

    assign m_axis_tdata  = pack_data;
    assign m_axis_tkeep  = pack_keep;
    assign m_axis_tlast  = out_last;
    assign m_axis_tvalid = out_valid;

    always @(posedge clk) begin
        if (!rstn) begin
            pack_data         <= {OUT_DATA_WIDTH{1'b0}};
            pack_keep         <= {OUT_KEEP_WIDTH{1'b0}};
            pack_count        <= {COUNT_W{1'b0}};
            pack_last_pending <= 1'b0;
            out_valid         <= 1'b0;
            out_last          <= 1'b0;
        end else if (clear) begin
            pack_data         <= {OUT_DATA_WIDTH{1'b0}};
            pack_keep         <= {OUT_KEEP_WIDTH{1'b0}};
            pack_count        <= {COUNT_W{1'b0}};
            pack_last_pending <= 1'b0;
            out_valid         <= 1'b0;
            out_last          <= 1'b0;
        end else begin
            if (output_accept) begin
                out_valid <= 1'b0;
                out_last  <= 1'b0;
                pack_data <= {OUT_DATA_WIDTH{1'b0}};
                pack_keep <= {OUT_KEEP_WIDTH{1'b0}};
                pack_count <= {COUNT_W{1'b0}};
                pack_last_pending <= 1'b0;
            end

            if (input_accept) begin
                pack_data[pack_count*IN_DATA_WIDTH +: IN_DATA_WIDTH] <= s_axis_tdata;
                pack_keep[pack_count +: IN_BYTES] <= s_axis_tkeep;
                pack_last_pending <= s_axis_tlast;
                if (input_fills_packet) begin
                    out_valid <= 1'b1;
                    out_last  <= s_axis_tlast;
                end
                pack_count <= input_fills_packet ? {COUNT_W{1'b0}} : next_count;
            end
        end
    end

endmodule
