`timescale 1ns / 1ps

module tb_stage2_pseudo_sstable_decode_axil_top;

    localparam integer AXIL_ADDR_WIDTH = 32;
    localparam integer AXIL_DATA_WIDTH = 32;
    localparam integer AXI_ADDR_WIDTH  = 64;
    localparam integer AXI_DATA_WIDTH  = 512;
    localparam integer AXI_STRB_WIDTH  = AXI_DATA_WIDTH / 8;
    localparam integer MEM_BYTES       = 4096;
    localparam integer BYTE_COUNT      = 40;
    localparam [63:0] SRC_ADDR         = 64'h0000_0000_0000_0000;

    localparam [31:0] REG_CTRL                 = 32'h0000;
    localparam [31:0] REG_STATUS               = 32'h0004;
    localparam [31:0] REG_SRC_BASE_LO          = 32'h0008;
    localparam [31:0] REG_SRC_BASE_HI          = 32'h000C;
    localparam [31:0] REG_SRC_SIZE             = 32'h0010;
    localparam [31:0] REG_HEADER_RECORD_COUNT  = 32'h0014;
    localparam [31:0] REG_DECODED_RECORD_COUNT = 32'h0018;
    localparam [31:0] REG_PUT_RECORD_COUNT     = 32'h001C;
    localparam [31:0] REG_DELETE_RECORD_COUNT  = 32'h0020;
    localparam [31:0] REG_KEY_BYTES_TOTAL      = 32'h0024;
    localparam [31:0] REG_VALUE_BYTES_TOTAL    = 32'h0028;
    localparam [31:0] REG_LAST_KEY_LEN         = 32'h002C;
    localparam [31:0] REG_LAST_VALUE_LEN       = 32'h0030;
    localparam [31:0] REG_LAST_RECORD_FLAGS    = 32'h0034;
    localparam [31:0] REG_BYTES_READ           = 32'h0038;
    localparam [31:0] REG_BEATS_READ           = 32'h003C;

    reg axil_aclk;
    reg axil_aresetn;
    reg ui_aclk;
    reg ui_aresetn;

    reg  [AXIL_ADDR_WIDTH-1:0]   s_axil_awaddr;
    reg                          s_axil_awvalid;
    wire                         s_axil_awready;
    reg  [AXIL_DATA_WIDTH-1:0]   s_axil_wdata;
    reg  [AXIL_DATA_WIDTH/8-1:0] s_axil_wstrb;
    reg                          s_axil_wvalid;
    wire                         s_axil_wready;
    wire [1:0]                   s_axil_bresp;
    wire                         s_axil_bvalid;
    reg                          s_axil_bready;
    reg  [AXIL_ADDR_WIDTH-1:0]   s_axil_araddr;
    reg                          s_axil_arvalid;
    wire                         s_axil_arready;
    wire [AXIL_DATA_WIDTH-1:0]   s_axil_rdata;
    wire [1:0]                   s_axil_rresp;
    wire                         s_axil_rvalid;
    reg                          s_axil_rready;

    wire [AXI_ADDR_WIDTH-1:0]    m_axi_araddr;
    wire [7:0]                   m_axi_arlen;
    wire [2:0]                   m_axi_arsize;
    wire [1:0]                   m_axi_arburst;
    wire                         m_axi_arvalid;
    wire                         m_axi_arready;
    wire [AXI_DATA_WIDTH-1:0]    m_axi_rdata;
    wire [1:0]                   m_axi_rresp;
    wire                         m_axi_rlast;
    wire                         m_axi_rvalid;
    wire                         m_axi_rready;

    wire [AXI_ADDR_WIDTH-1:0]    m_axi_awaddr;
    wire [7:0]                   m_axi_awlen;
    wire [2:0]                   m_axi_awsize;
    wire [1:0]                   m_axi_awburst;
    wire                         m_axi_awvalid;
    wire                         m_axi_awready;
    wire [AXI_DATA_WIDTH-1:0]    m_axi_wdata;
    wire [AXI_STRB_WIDTH-1:0]    m_axi_wstrb;
    wire                         m_axi_wlast;
    wire                         m_axi_wvalid;
    wire                         m_axi_wready;
    wire [1:0]                   m_axi_bresp;
    wire                         m_axi_bvalid;
    wire                         m_axi_bready;

    wire [AXI_DATA_WIDTH-1:0]    dbg_last_accum;
    wire                         done;
    wire                         busy;
    wire                         error;
    wire [31:0]                  bytes_done;
    wire [31:0]                  blocks_done;

    integer i;
    integer poll_count;
    reg [31:0] status_reg;
    reg [31:0] header_record_count_reg;
    reg [31:0] decoded_record_count_reg;
    reg [31:0] put_record_count_reg;
    reg [31:0] delete_record_count_reg;
    reg [31:0] key_bytes_total_reg;
    reg [31:0] value_bytes_total_reg;
    reg [31:0] last_key_len_reg;
    reg [31:0] last_value_len_reg;
    reg [31:0] last_record_flags_reg;
    reg [31:0] bytes_read_reg;
    reg [31:0] beats_read_reg;
    reg aw_done;
    reg w_done;

    stage2_pseudo_sstable_decode_axil_top #(
        .AXIL_ADDR_WIDTH(AXIL_ADDR_WIDTH),
        .AXIL_DATA_WIDTH(AXIL_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_STRB_WIDTH(AXI_STRB_WIDTH),
        .MAX_BURST_LEN(16)
    ) dut (
        .axil_aclk(axil_aclk),
        .axil_aresetn(axil_aresetn),
        .s_axil_awaddr(s_axil_awaddr),
        .s_axil_awvalid(s_axil_awvalid),
        .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata),
        .s_axil_wstrb(s_axil_wstrb),
        .s_axil_wvalid(s_axil_wvalid),
        .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp),
        .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr),
        .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata),
        .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid),
        .s_axil_rready(s_axil_rready),
        .ui_aclk(ui_aclk),
        .ui_aresetn(ui_aresetn),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .dbg_last_accum(dbg_last_accum),
        .done(done),
        .busy(busy),
        .error(error),
        .bytes_done(bytes_done),
        .blocks_done(blocks_done)
    );

    axi_ram_model #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MEM_BYTES(MEM_BYTES),
        .READ_LATENCY(2)
    ) mem (
        .clk(ui_aclk),
        .rstn(ui_aresetn),
        .s_axi_araddr(m_axi_araddr),
        .s_axi_arlen(m_axi_arlen),
        .s_axi_arsize(m_axi_arsize),
        .s_axi_arburst(m_axi_arburst),
        .s_axi_arid(1'b0),
        .s_axi_arvalid(m_axi_arvalid),
        .s_axi_arready(m_axi_arready),
        .s_axi_rdata(m_axi_rdata),
        .s_axi_rresp(m_axi_rresp),
        .s_axi_rlast(m_axi_rlast),
        .s_axi_rid(),
        .s_axi_rvalid(m_axi_rvalid),
        .s_axi_rready(m_axi_rready),
        .s_axi_awaddr(m_axi_awaddr),
        .s_axi_awlen(m_axi_awlen),
        .s_axi_awsize(m_axi_awsize),
        .s_axi_awburst(m_axi_awburst),
        .s_axi_awid(1'b0),
        .s_axi_awvalid(m_axi_awvalid),
        .s_axi_awready(m_axi_awready),
        .s_axi_wdata(m_axi_wdata),
        .s_axi_wstrb(m_axi_wstrb),
        .s_axi_wlast(m_axi_wlast),
        .s_axi_wvalid(m_axi_wvalid),
        .s_axi_wready(m_axi_wready),
        .s_axi_bresp(m_axi_bresp),
        .s_axi_bid(),
        .s_axi_bvalid(m_axi_bvalid),
        .s_axi_bready(m_axi_bready)
    );

    always #2 axil_aclk = ~axil_aclk;
    always #3 ui_aclk   = ~ui_aclk;

    task automatic axil_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            aw_done = 1'b0;
            w_done  = 1'b0;
            @(negedge axil_aclk);
            s_axil_awaddr  <= addr;
            s_axil_awvalid <= 1'b1;
            s_axil_wdata   <= data;
            s_axil_wstrb   <= 4'hf;
            s_axil_wvalid  <= 1'b1;
            s_axil_bready  <= 1'b1;

            while (!(aw_done && w_done)) begin
                @(posedge axil_aclk);
                if (s_axil_awvalid && s_axil_awready) begin
                    aw_done = 1'b1;
                end
                if (s_axil_wvalid && s_axil_wready) begin
                    w_done = 1'b1;
                end
            end

            @(negedge axil_aclk);
            s_axil_awvalid <= 1'b0;
            s_axil_wvalid  <= 1'b0;

            while (!s_axil_bvalid) begin
                @(posedge axil_aclk);
            end

            @(negedge axil_aclk);
            s_axil_bready <= 1'b0;
        end
    endtask

    task automatic axil_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(negedge axil_aclk);
            s_axil_araddr  <= addr;
            s_axil_arvalid <= 1'b1;
            s_axil_rready  <= 1'b1;
            while (!s_axil_arready) begin
                @(posedge axil_aclk);
            end
            @(negedge axil_aclk);
            s_axil_arvalid <= 1'b0;
            while (!s_axil_rvalid) begin
                @(posedge axil_aclk);
            end
            data = s_axil_rdata;
            @(negedge axil_aclk);
            s_axil_rready <= 1'b0;
        end
    endtask

    initial begin
        axil_aclk = 1'b0;
        axil_aresetn = 1'b0;
        ui_aclk = 1'b0;
        ui_aresetn = 1'b0;
        s_axil_awaddr = 32'd0;
        s_axil_awvalid = 1'b0;
        s_axil_wdata = 32'd0;
        s_axil_wstrb = 4'd0;
        s_axil_wvalid = 1'b0;
        s_axil_bready = 1'b0;
        s_axil_araddr = 32'd0;
        s_axil_arvalid = 1'b0;
        s_axil_rready = 1'b0;
        status_reg = 32'd0;
        header_record_count_reg = 32'd0;
        decoded_record_count_reg = 32'd0;
        put_record_count_reg = 32'd0;
        delete_record_count_reg = 32'd0;
        key_bytes_total_reg = 32'd0;
        value_bytes_total_reg = 32'd0;
        last_key_len_reg = 32'd0;
        last_value_len_reg = 32'd0;
        last_record_flags_reg = 32'd0;
        bytes_read_reg = 32'd0;
        beats_read_reg = 32'd0;

        for (i = 0; i < MEM_BYTES; i = i + 1) begin
            mem.mem[i] = 8'h00;
        end

        mem.mem[0]  = 8'h50;
        mem.mem[1]  = 8'h53;
        mem.mem[2]  = 8'h54;
        mem.mem[3]  = 8'h42;
        mem.mem[4]  = 8'h03;
        mem.mem[5]  = 8'h00;
        mem.mem[6]  = 8'h00;
        mem.mem[7]  = 8'h00;
        mem.mem[8]  = 8'h03;
        mem.mem[9]  = 8'h00;
        mem.mem[10] = 8'h05;
        mem.mem[11] = 8'h00;
        mem.mem[12] = 8'h00;
        mem.mem[13] = "c";
        mem.mem[14] = "a";
        mem.mem[15] = "t";
        mem.mem[16] = "a";
        mem.mem[17] = "p";
        mem.mem[18] = "p";
        mem.mem[19] = "l";
        mem.mem[20] = "e";
        mem.mem[21] = 8'h03;
        mem.mem[22] = 8'h00;
        mem.mem[23] = 8'h00;
        mem.mem[24] = 8'h00;
        mem.mem[25] = 8'h01;
        mem.mem[26] = "d";
        mem.mem[27] = "o";
        mem.mem[28] = "g";
        mem.mem[29] = 8'h04;
        mem.mem[30] = 8'h00;
        mem.mem[31] = 8'h02;
        mem.mem[32] = 8'h00;
        mem.mem[33] = 8'h00;
        mem.mem[34] = "k";
        mem.mem[35] = "i";
        mem.mem[36] = "w";
        mem.mem[37] = "i";
        mem.mem[38] = "O";
        mem.mem[39] = "K";

        repeat (10) @(posedge axil_aclk);
        axil_aresetn = 1'b1;
        repeat (10) @(posedge ui_aclk);
        ui_aresetn = 1'b1;
        repeat (10) @(posedge axil_aclk);

        axil_write(REG_SRC_BASE_LO, SRC_ADDR[31:0]);
        axil_write(REG_SRC_BASE_HI, SRC_ADDR[63:32]);
        axil_write(REG_SRC_SIZE, BYTE_COUNT);
        axil_write(REG_CTRL, 32'h1);

        poll_count = 0;
        status_reg = 32'h0;
        while (!status_reg[1]) begin
            axil_read(REG_STATUS, status_reg);
            if (status_reg[2]) begin
                $display("Wrapper reported error status=%08x", status_reg);
                $finish_and_return(1);
            end
            poll_count = poll_count + 1;
            if (poll_count > 2000) begin
                $display("AXI-Lite poll timeout status=%08x", status_reg);
                $finish_and_return(1);
            end
        end

        axil_read(REG_HEADER_RECORD_COUNT, header_record_count_reg);
        axil_read(REG_DECODED_RECORD_COUNT, decoded_record_count_reg);
        axil_read(REG_PUT_RECORD_COUNT, put_record_count_reg);
        axil_read(REG_DELETE_RECORD_COUNT, delete_record_count_reg);
        axil_read(REG_KEY_BYTES_TOTAL, key_bytes_total_reg);
        axil_read(REG_VALUE_BYTES_TOTAL, value_bytes_total_reg);
        axil_read(REG_LAST_KEY_LEN, last_key_len_reg);
        axil_read(REG_LAST_VALUE_LEN, last_value_len_reg);
        axil_read(REG_LAST_RECORD_FLAGS, last_record_flags_reg);
        axil_read(REG_BYTES_READ, bytes_read_reg);
        axil_read(REG_BEATS_READ, beats_read_reg);

        if (header_record_count_reg != 32'd3) begin
            $display("header_record_count_reg mismatch got=%0d", header_record_count_reg);
            $finish_and_return(1);
        end
        if (decoded_record_count_reg != 32'd3) begin
            $display("decoded_record_count_reg mismatch got=%0d", decoded_record_count_reg);
            $finish_and_return(1);
        end
        if (put_record_count_reg != 32'd2) begin
            $display("put_record_count_reg mismatch got=%0d", put_record_count_reg);
            $finish_and_return(1);
        end
        if (delete_record_count_reg != 32'd1) begin
            $display("delete_record_count_reg mismatch got=%0d", delete_record_count_reg);
            $finish_and_return(1);
        end
        if (key_bytes_total_reg != 32'd10) begin
            $display("key_bytes_total_reg mismatch got=%0d", key_bytes_total_reg);
            $finish_and_return(1);
        end
        if (value_bytes_total_reg != 32'd7) begin
            $display("value_bytes_total_reg mismatch got=%0d", value_bytes_total_reg);
            $finish_and_return(1);
        end
        if (last_key_len_reg != 32'd4) begin
            $display("last_key_len_reg mismatch got=%0d", last_key_len_reg);
            $finish_and_return(1);
        end
        if (last_value_len_reg != 32'd2) begin
            $display("last_value_len_reg mismatch got=%0d", last_value_len_reg);
            $finish_and_return(1);
        end
        if (last_record_flags_reg != 32'd0) begin
            $display("last_record_flags_reg mismatch got=%0d", last_record_flags_reg);
            $finish_and_return(1);
        end
        if (bytes_read_reg != BYTE_COUNT) begin
            $display("bytes_read_reg mismatch got=%0d exp=%0d", bytes_read_reg, BYTE_COUNT);
            $finish_and_return(1);
        end
        if (beats_read_reg != 32'd1) begin
            $display("beats_read_reg mismatch got=%0d", beats_read_reg);
            $finish_and_return(1);
        end
        if (m_axi_awvalid || m_axi_wvalid || m_axi_bready) begin
            $display("Write AXI channel should remain idle");
            $finish_and_return(1);
        end
        if (!done || busy || error) begin
            $display("Top-level outputs mismatch done=%0d busy=%0d error=%0d", done, busy, error);
            $finish_and_return(1);
        end
        if (bytes_done != BYTE_COUNT) begin
            $display("bytes_done mismatch got=%0d", bytes_done);
            $finish_and_return(1);
        end
        if (blocks_done != 32'd3) begin
            $display("blocks_done mismatch got=%0d", blocks_done);
            $finish_and_return(1);
        end

        $display("PASS stage2_pseudo_sstable_decode_axil_top");
        $finish;
    end

endmodule
