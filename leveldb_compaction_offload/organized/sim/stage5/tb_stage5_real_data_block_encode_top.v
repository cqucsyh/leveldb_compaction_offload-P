`timescale 1ns / 1ps

module tb_stage5_real_data_block_encode_top;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer AXI_ID_WIDTH   = 1;
    localparam integer MEM_BYTES      = 8192;

    reg                         clk;
    reg                         rstn;
    reg                         clear;
    reg                         start;
    reg  [AXI_ADDR_WIDTH-1:0]   src_base_addr;
    reg  [31:0]                 src_byte_count;
    reg  [AXI_ADDR_WIDTH-1:0]   dst_base_addr;
    wire                        busy;
    wire                        done;
    wire                        error;
    wire [31:0]                 bytes_read;
    wire [31:0]                 beats_read;
    wire [31:0]                 bytes_written;
    wire [31:0]                 beats_written;
    wire [31:0]                 input_record_count;
    wire [31:0]                 encoded_entry_count;
    wire [31:0]                 restart_count;
    wire [31:0]                 shared_key_bytes_total;
    wire [31:0]                 unshared_key_bytes_total;
    wire [31:0]                 value_bytes_total;
    wire [15:0]                 last_key_len;
    wire [15:0]                 last_value_len;
    wire [15:0]                 last_shared_bytes;
    wire [15:0]                 last_non_shared_bytes;
    wire [31:0]                 output_block_bytes;

    wire [AXI_ADDR_WIDTH-1:0]   m_axi_araddr;
    wire [7:0]                  m_axi_arlen;
    wire [2:0]                  m_axi_arsize;
    wire [1:0]                  m_axi_arburst;
    wire [AXI_ID_WIDTH-1:0]     m_axi_arid;
    wire                        m_axi_arvalid;
    wire                        m_axi_arready;
    wire [AXI_DATA_WIDTH-1:0]   m_axi_rdata;
    wire [1:0]                  m_axi_rresp;
    wire                        m_axi_rlast;
    wire [AXI_ID_WIDTH-1:0]     m_axi_rid;
    wire                        m_axi_rvalid;
    wire                        m_axi_rready;

    wire [AXI_ADDR_WIDTH-1:0]   m_axi_awaddr;
    wire [7:0]                  m_axi_awlen;
    wire [2:0]                  m_axi_awsize;
    wire [1:0]                  m_axi_awburst;
    wire [AXI_ID_WIDTH-1:0]     m_axi_awid;
    wire                        m_axi_awvalid;
    wire                        m_axi_awready;
    wire [AXI_DATA_WIDTH-1:0]   m_axi_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb;
    wire                        m_axi_wlast;
    wire                        m_axi_wvalid;
    wire                        m_axi_wready;
    wire [1:0]                  m_axi_bresp;
    wire [AXI_ID_WIDTH-1:0]     m_axi_bid;
    wire                        m_axi_bvalid;
    wire                        m_axi_bready;

    reg [7:0] source_bytes [0:32];
    reg [7:0] expected_block [0:35];
    integer i;

    stage5_real_data_block_encode_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(16),
        .MAX_RECORDS(8),
        .MAX_PAYLOAD_BYTES(128),
        .MAX_BLOCK_BYTES(128),
        .MAX_KEY_BYTES(16),
        .MAX_VALUE_BYTES(16),
        .RESTART_INTERVAL(2)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .src_base_addr(src_base_addr),
        .src_byte_count(src_byte_count),
        .dst_base_addr(dst_base_addr),
        .busy(busy),
        .done(done),
        .error(error),
        .bytes_read(bytes_read),
        .beats_read(beats_read),
        .bytes_written(bytes_written),
        .beats_written(beats_written),
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
        .output_block_bytes(output_block_bytes),
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

    axi_ram_model #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MEM_BYTES(MEM_BYTES),
        .READ_LATENCY(1)
    ) ram (
        .clk(clk),
        .rstn(rstn),
        .s_axi_araddr(m_axi_araddr),
        .s_axi_arlen(m_axi_arlen),
        .s_axi_arsize(m_axi_arsize),
        .s_axi_arburst(m_axi_arburst),
        .s_axi_arid(m_axi_arid),
        .s_axi_arvalid(m_axi_arvalid),
        .s_axi_arready(m_axi_arready),
        .s_axi_rdata(m_axi_rdata),
        .s_axi_rresp(m_axi_rresp),
        .s_axi_rlast(m_axi_rlast),
        .s_axi_rid(m_axi_rid),
        .s_axi_rvalid(m_axi_rvalid),
        .s_axi_rready(m_axi_rready),
        .s_axi_awaddr(m_axi_awaddr),
        .s_axi_awlen(m_axi_awlen),
        .s_axi_awsize(m_axi_awsize),
        .s_axi_awburst(m_axi_awburst),
        .s_axi_awid(m_axi_awid),
        .s_axi_awvalid(m_axi_awvalid),
        .s_axi_awready(m_axi_awready),
        .s_axi_wdata(m_axi_wdata),
        .s_axi_wstrb(m_axi_wstrb),
        .s_axi_wlast(m_axi_wlast),
        .s_axi_wvalid(m_axi_wvalid),
        .s_axi_wready(m_axi_wready),
        .s_axi_bresp(m_axi_bresp),
        .s_axi_bid(m_axi_bid),
        .s_axi_bvalid(m_axi_bvalid),
        .s_axi_bready(m_axi_bready)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rstn = 1'b0;
        clear = 1'b0;
        start = 1'b0;
        src_base_addr = 64'h0;
        src_byte_count = 32'd33;
        dst_base_addr = 64'h0000_0000_0000_0100;

        source_bytes[0]  = 8'h03;
        source_bytes[1]  = 8'h00;
        source_bytes[2]  = 8'h00;
        source_bytes[3]  = 8'h00;
        source_bytes[4]  = 8'h03;
        source_bytes[5]  = 8'h00;
        source_bytes[6]  = 8'h02;
        source_bytes[7]  = 8'h00;
        source_bytes[8]  = 8'h63;
        source_bytes[9]  = 8'h61;
        source_bytes[10] = 8'h74;
        source_bytes[11] = 8'h76;
        source_bytes[12] = 8'h31;
        source_bytes[13] = 8'h04;
        source_bytes[14] = 8'h00;
        source_bytes[15] = 8'h02;
        source_bytes[16] = 8'h00;
        source_bytes[17] = 8'h63;
        source_bytes[18] = 8'h61;
        source_bytes[19] = 8'h72;
        source_bytes[20] = 8'h73;
        source_bytes[21] = 8'h76;
        source_bytes[22] = 8'h32;
        source_bytes[23] = 8'h04;
        source_bytes[24] = 8'h00;
        source_bytes[25] = 8'h02;
        source_bytes[26] = 8'h00;
        source_bytes[27] = 8'h64;
        source_bytes[28] = 8'h6f;
        source_bytes[29] = 8'h67;
        source_bytes[30] = 8'h65;
        source_bytes[31] = 8'h76;
        source_bytes[32] = 8'h33;

        expected_block[0]  = 8'h00;
        expected_block[1]  = 8'h03;
        expected_block[2]  = 8'h02;
        expected_block[3]  = 8'h63;
        expected_block[4]  = 8'h61;
        expected_block[5]  = 8'h74;
        expected_block[6]  = 8'h76;
        expected_block[7]  = 8'h31;
        expected_block[8]  = 8'h02;
        expected_block[9]  = 8'h02;
        expected_block[10] = 8'h02;
        expected_block[11] = 8'h72;
        expected_block[12] = 8'h73;
        expected_block[13] = 8'h76;
        expected_block[14] = 8'h32;
        expected_block[15] = 8'h00;
        expected_block[16] = 8'h04;
        expected_block[17] = 8'h02;
        expected_block[18] = 8'h64;
        expected_block[19] = 8'h6f;
        expected_block[20] = 8'h67;
        expected_block[21] = 8'h65;
        expected_block[22] = 8'h76;
        expected_block[23] = 8'h33;
        expected_block[24] = 8'h00;
        expected_block[25] = 8'h00;
        expected_block[26] = 8'h00;
        expected_block[27] = 8'h00;
        expected_block[28] = 8'h0f;
        expected_block[29] = 8'h00;
        expected_block[30] = 8'h00;
        expected_block[31] = 8'h00;
        expected_block[32] = 8'h02;
        expected_block[33] = 8'h00;
        expected_block[34] = 8'h00;
        expected_block[35] = 8'h00;

        repeat (4) @(posedge clk);
        rstn = 1'b1;
        repeat (2) @(posedge clk);

        for (i = 0; i < 33; i = i + 1) begin
            ram.mem[i] = source_bytes[i];
        end
        for (i = 0; i < 64; i = i + 1) begin
            ram.mem[16'h0100 + i] = 8'h00;
        end

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        while (!done && !error) begin
            @(posedge clk);
        end

        if (error) begin
            $display("Stage5 top reported error");
            $finish_and_return(1);
        end

        if (bytes_read !== 32'd33 || beats_read !== 32'd1 || bytes_written !== 32'd36 || beats_written !== 32'd1) begin
            $display("Stage5 IO counter mismatch");
            $finish_and_return(1);
        end

        if (input_record_count !== 32'd3 || encoded_entry_count !== 32'd3 || restart_count !== 32'd2 ||
            shared_key_bytes_total !== 32'd2 || unshared_key_bytes_total !== 32'd9 || value_bytes_total !== 32'd6 ||
            last_key_len !== 16'd4 || last_value_len !== 16'd2 || last_shared_bytes !== 16'd0 ||
            last_non_shared_bytes !== 16'd4 || output_block_bytes !== 32'd36) begin
            $display("Stage5 encode counter mismatch");
            $finish_and_return(1);
        end

        for (i = 0; i < 36; i = i + 1) begin
            if (ram.mem[16'h0100 + i] !== expected_block[i]) begin
                $display("Stage5 writeback mismatch idx=%0d got=%02x exp=%02x", i, ram.mem[16'h0100 + i], expected_block[i]);
                $finish_and_return(1);
            end
        end

        $display("PASS stage5_real_data_block_encode_top");
        $finish;
    end

endmodule
