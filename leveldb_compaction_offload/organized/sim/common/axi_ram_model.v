`timescale 1ns / 1ps

module axi_ram_model #(
    parameter integer AXI_ADDR_WIDTH = 64,
    parameter integer AXI_DATA_WIDTH = 512,
    parameter integer AXI_ID_WIDTH   = 1,
    parameter integer MEM_BYTES      = 65536,
    parameter integer READ_LATENCY   = 2
) (
    input  wire                              clk,
    input  wire                              rstn,
    input  wire [AXI_ADDR_WIDTH-1:0]         s_axi_araddr,
    input  wire [7:0]                        s_axi_arlen,
    input  wire [2:0]                        s_axi_arsize,
    input  wire [1:0]                        s_axi_arburst,
    input  wire [AXI_ID_WIDTH-1:0]           s_axi_arid,
    input  wire                              s_axi_arvalid,
    output reg                               s_axi_arready,
    output reg  [AXI_DATA_WIDTH-1:0]         s_axi_rdata,
    output reg  [1:0]                        s_axi_rresp,
    output reg                               s_axi_rlast,
    output reg  [AXI_ID_WIDTH-1:0]           s_axi_rid,
    output reg                               s_axi_rvalid,
    input  wire                              s_axi_rready,

    input  wire [AXI_ADDR_WIDTH-1:0]         s_axi_awaddr,
    input  wire [7:0]                        s_axi_awlen,
    input  wire [2:0]                        s_axi_awsize,
    input  wire [1:0]                        s_axi_awburst,
    input  wire [AXI_ID_WIDTH-1:0]           s_axi_awid,
    input  wire                              s_axi_awvalid,
    output reg                               s_axi_awready,
    input  wire [AXI_DATA_WIDTH-1:0]         s_axi_wdata,
    input  wire [(AXI_DATA_WIDTH/8)-1:0]     s_axi_wstrb,
    input  wire                              s_axi_wlast,
    input  wire                              s_axi_wvalid,
    output reg                               s_axi_wready,
    output reg  [1:0]                        s_axi_bresp,
    output reg  [AXI_ID_WIDTH-1:0]           s_axi_bid,
    output reg                               s_axi_bvalid,
    input  wire                              s_axi_bready
);

    localparam integer AXI_KEEP_WIDTH = AXI_DATA_WIDTH / 8;
    localparam integer AXI_BEAT_BYTES = AXI_DATA_WIDTH / 8;

    reg [7:0] mem [0:MEM_BYTES-1];

    reg [AXI_ADDR_WIDTH-1:0] rd_addr;
    reg [7:0]                rd_len;
    reg [7:0]                rd_idx;
    reg [AXI_ID_WIDTH-1:0]   rd_id;
    reg                      rd_active;
    reg [7:0]                rd_latency_cnt;

    reg [AXI_ADDR_WIDTH-1:0] wr_addr;
    reg [7:0]                wr_len;
    reg [7:0]                wr_idx;
    reg [AXI_ID_WIDTH-1:0]   wr_id;
    reg                      wr_active;

    integer i;
    integer base;

    task automatic load_word;
        input integer addr;
        output [AXI_DATA_WIDTH-1:0] data;
        integer j;
        begin
            data = {AXI_DATA_WIDTH{1'b0}};
            for (j = 0; j < AXI_BEAT_BYTES; j = j + 1) begin
                if ((addr + j) < MEM_BYTES) begin
                    data[j*8 +: 8] = mem[addr + j];
                end
            end
        end
    endtask

    always @(posedge clk) begin
        if (!rstn) begin
            s_axi_arready <= 1'b1;
            s_axi_rdata   <= {AXI_DATA_WIDTH{1'b0}};
            s_axi_rresp   <= 2'b00;
            s_axi_rlast   <= 1'b0;
            s_axi_rid     <= {AXI_ID_WIDTH{1'b0}};
            s_axi_rvalid  <= 1'b0;
            rd_addr       <= {AXI_ADDR_WIDTH{1'b0}};
            rd_len        <= 8'd0;
            rd_idx        <= 8'd0;
            rd_id         <= {AXI_ID_WIDTH{1'b0}};
            rd_active     <= 1'b0;
            rd_latency_cnt <= 8'd0;

            s_axi_awready <= 1'b1;
            s_axi_wready  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            s_axi_bid     <= {AXI_ID_WIDTH{1'b0}};
            s_axi_bvalid  <= 1'b0;
            wr_addr       <= {AXI_ADDR_WIDTH{1'b0}};
            wr_len        <= 8'd0;
            wr_idx        <= 8'd0;
            wr_id         <= {AXI_ID_WIDTH{1'b0}};
            wr_active     <= 1'b0;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                rd_addr        <= s_axi_araddr;
                rd_len         <= s_axi_arlen;
                rd_idx         <= 8'd0;
                rd_id          <= s_axi_arid;
                rd_active      <= 1'b1;
                rd_latency_cnt <= READ_LATENCY[7:0];
                s_axi_arready  <= 1'b0;
            end

            if (rd_active && !s_axi_rvalid) begin
                if (rd_latency_cnt != 8'd0) begin
                    rd_latency_cnt <= rd_latency_cnt - 8'd1;
                end else begin
                    load_word(rd_addr, s_axi_rdata);
                    s_axi_rresp  <= 2'b00;
                    s_axi_rid    <= rd_id;
                    s_axi_rlast  <= (rd_idx == rd_len);
                    s_axi_rvalid <= 1'b1;
                end
            end

            if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
                if (s_axi_rlast) begin
                    rd_active    <= 1'b0;
                    s_axi_arready <= 1'b1;
                end else begin
                    rd_idx        <= rd_idx + 8'd1;
                    rd_addr       <= rd_addr + AXI_BEAT_BYTES;
                    rd_latency_cnt <= 8'd0;
                end
            end

            if (s_axi_awvalid && s_axi_awready) begin
                wr_addr      <= s_axi_awaddr;
                wr_len       <= s_axi_awlen;
                wr_idx       <= 8'd0;
                wr_id        <= s_axi_awid;
                wr_active    <= 1'b1;
                s_axi_awready <= 1'b0;
                s_axi_wready <= 1'b1;
            end

            if (wr_active && s_axi_wvalid && s_axi_wready) begin
                base = wr_addr;
                for (i = 0; i < AXI_BEAT_BYTES; i = i + 1) begin
                    if (s_axi_wstrb[i] && ((base + i) < MEM_BYTES)) begin
                        mem[base + i] <= s_axi_wdata[i*8 +: 8];
                    end
                end

                if (s_axi_wlast) begin
                    s_axi_wready <= 1'b0;
                    s_axi_bvalid <= 1'b1;
                    s_axi_bresp  <= 2'b00;
                    s_axi_bid    <= wr_id;
                    wr_active    <= 1'b0;
                end else begin
                    wr_idx  <= wr_idx + 8'd1;
                    wr_addr <= wr_addr + AXI_BEAT_BYTES;
                end
            end

            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid  <= 1'b0;
                s_axi_awready <= 1'b1;
            end
        end
    end

endmodule
