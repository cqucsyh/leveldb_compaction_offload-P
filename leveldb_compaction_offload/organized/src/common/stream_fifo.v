`timescale 1ns / 1ps

module stream_fifo #(
    parameter integer DATA_WIDTH = 577,
    parameter integer DEPTH = 32
) (
    input  wire                   clk,
    input  wire                   rstn,
    input  wire                   clear,
    input  wire [DATA_WIDTH-1:0]  s_data,
    input  wire                   s_valid,
    output wire                   s_ready,
    output wire [DATA_WIDTH-1:0]  m_data,
    output wire                   m_valid,
    input  wire                   m_ready,
    output wire [$clog2(DEPTH+1)-1:0] occupancy
);

    localparam integer PTR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    localparam integer CNT_W = $clog2(DEPTH+1);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [PTR_W-1:0] wr_ptr;
    reg [PTR_W-1:0] rd_ptr;
    reg [CNT_W-1:0] count;

    wire do_push;
    wire do_pop;

    assign s_ready = (count < DEPTH) || ((count != 0) && m_ready);
    assign m_valid = (count != 0);
    assign m_data = mem[rd_ptr];
    assign occupancy = count;

    assign do_push = s_valid && s_ready;
    assign do_pop  = m_valid && m_ready;

    always @(posedge clk) begin
        if (!rstn) begin
            wr_ptr <= {PTR_W{1'b0}};
            rd_ptr <= {PTR_W{1'b0}};
            count  <= {CNT_W{1'b0}};
        end else if (clear) begin
            wr_ptr <= {PTR_W{1'b0}};
            rd_ptr <= {PTR_W{1'b0}};
            count  <= {CNT_W{1'b0}};
        end else begin
            if (do_push) begin
                mem[wr_ptr] <= s_data;
                if (wr_ptr == DEPTH-1) begin
                    wr_ptr <= {PTR_W{1'b0}};
                end else begin
                    wr_ptr <= wr_ptr + {{(PTR_W-1){1'b0}}, 1'b1};
                end
            end

            if (do_pop) begin
                if (rd_ptr == DEPTH-1) begin
                    rd_ptr <= {PTR_W{1'b0}};
                end else begin
                    rd_ptr <= rd_ptr + {{(PTR_W-1){1'b0}}, 1'b1};
                end
            end

            case ({do_push, do_pop})
                2'b10: count <= count + {{(CNT_W-1){1'b0}}, 1'b1};
                2'b01: count <= count - {{(CNT_W-1){1'b0}}, 1'b1};
                default: count <= count;
            endcase
        end
    end

endmodule
