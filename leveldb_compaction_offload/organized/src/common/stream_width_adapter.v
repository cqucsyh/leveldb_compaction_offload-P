`timescale 1ns / 1ps

module stream_width_adapter #(
    parameter integer IN_DATA_WIDTH = 512,
    parameter integer IN_KEEP_WIDTH = IN_DATA_WIDTH / 8,
    parameter integer OUT_DATA_WIDTH = 8,
    parameter integer OUT_KEEP_WIDTH = (OUT_DATA_WIDTH + 7) / 8
) (
    input  wire                        clk,
    input  wire                        rstn,
    input  wire                        clear,
    input  wire [IN_DATA_WIDTH-1:0]    s_axis_tdata,
    input  wire [IN_KEEP_WIDTH-1:0]    s_axis_tkeep,
    input  wire                        s_axis_tlast,
    input  wire                        s_axis_tvalid,
    output wire                        s_axis_tready,
    output wire [OUT_DATA_WIDTH-1:0]   m_axis_tdata,
    output wire [OUT_KEEP_WIDTH-1:0]   m_axis_tkeep,
    output wire                        m_axis_tlast,
    output wire                        m_axis_tvalid,
    input  wire                        m_axis_tready
);

    localparam integer OUT_BYTES = OUT_DATA_WIDTH / 8;
    localparam integer IN_BYTES  = IN_DATA_WIDTH / 8;
    localparam integer IDX_W     = (IN_BYTES <= 2) ? 1 : $clog2(IN_BYTES + 1);

    reg [IN_DATA_WIDTH-1:0] hold_data;
    reg [IN_KEEP_WIDTH-1:0] hold_keep;
    reg                     hold_last;
    reg                     hold_valid;
    reg [IDX_W-1:0]         hold_index;
    reg [IDX_W-1:0]         hold_count;

    wire [OUT_DATA_WIDTH-1:0] cur_data;
    wire [OUT_KEEP_WIDTH-1:0] cur_keep;
    wire                      cur_beat_last;
    wire                      cur_last;
    wire                      advance;

    integer i;
    reg [IDX_W-1:0] valid_count_comb;

    always @(*) begin
        valid_count_comb = {IDX_W{1'b0}};
        for (i = 0; i < IN_BYTES; i = i + 1) begin
            if (s_axis_tkeep[i]) begin
                valid_count_comb = valid_count_comb + {{(IDX_W-1){1'b0}}, 1'b1};
            end
        end
    end

    assign cur_data = hold_data[hold_index*OUT_DATA_WIDTH +: OUT_DATA_WIDTH];
    assign cur_keep = hold_keep[hold_index*OUT_KEEP_WIDTH +: OUT_KEEP_WIDTH];
    assign cur_beat_last = (hold_index + OUT_BYTES >= hold_count);
    assign cur_last = hold_last && cur_beat_last;

    assign m_axis_tdata  = cur_data;
    assign m_axis_tkeep  = cur_keep;
    assign m_axis_tlast  = cur_last;
    assign m_axis_tvalid = hold_valid;

    assign s_axis_tready = !hold_valid;
    assign advance = hold_valid && m_axis_tready;

    always @(posedge clk) begin
        if (!rstn) begin
            hold_data  <= {IN_DATA_WIDTH{1'b0}};
            hold_keep  <= {IN_KEEP_WIDTH{1'b0}};
            hold_last  <= 1'b0;
            hold_valid <= 1'b0;
            hold_index <= {IDX_W{1'b0}};
            hold_count <= {IDX_W{1'b0}};
        end else if (clear) begin
            hold_data  <= {IN_DATA_WIDTH{1'b0}};
            hold_keep  <= {IN_KEEP_WIDTH{1'b0}};
            hold_last  <= 1'b0;
            hold_valid <= 1'b0;
            hold_index <= {IDX_W{1'b0}};
            hold_count <= {IDX_W{1'b0}};
        end else begin
            if (s_axis_tvalid && s_axis_tready) begin
                hold_data  <= s_axis_tdata;
                hold_keep  <= s_axis_tkeep;
                hold_last  <= s_axis_tlast;
                hold_valid <= 1'b1;
                hold_index <= {IDX_W{1'b0}};
                hold_count <= valid_count_comb;
            end else if (advance) begin
                if (cur_beat_last) begin
                    hold_valid <= 1'b0;
                    hold_index <= {IDX_W{1'b0}};
                end else begin
                    hold_index <= hold_index + OUT_BYTES[IDX_W-1:0];
                end
            end
        end
    end

endmodule
