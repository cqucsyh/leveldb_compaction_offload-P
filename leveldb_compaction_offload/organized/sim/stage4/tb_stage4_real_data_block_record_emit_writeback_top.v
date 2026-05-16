`timescale 1ns / 1ps

module tb_stage4_real_data_block_record_emit_writeback_top;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer MEM_BYTES      = 8192;
    localparam integer TEST_BYTES     = 36;
    localparam [63:0] SRC_ADDR        = 64'h0000_0000_0000_0000;
    localparam [63:0] DST_ADDR        = 64'h0000_0000_0000_0100;

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
    wire [31:0]                 output_byte_count;
    wire [31:0]                 decoded_entry_count;
    wire [31:0]                 restart_count;
    wire [31:0]                 restart_entry_count;
    wire [31:0]                 shared_key_bytes_total;
    wire [31:0]                 unshared_key_bytes_total;
    wire [31:0]                 value_bytes_total;
    wire [15:0]                 last_key_len;
    wire [15:0]                 last_value_len;
    wire [15:0]                 last_shared_bytes;
    wire [15:0]                 last_non_shared_bytes;
    wire [31:0]                 restart_array_offset;

    wire [AXI_ADDR_WIDTH-1:0]   m_axi_araddr;
    wire [7:0]                  m_axi_arlen;
    wire [2:0]                  m_axi_arsize;
    wire [1:0]                  m_axi_arburst;
    wire                        m_axi_arvalid;
    wire                        m_axi_arready;
    wire [AXI_DATA_WIDTH-1:0]   m_axi_rdata;
    wire [1:0]                  m_axi_rresp;
    wire                        m_axi_rlast;
    wire                        m_axi_rvalid;
    wire                        m_axi_rready;

    wire [AXI_ADDR_WIDTH-1:0]   m_axi_awaddr;
    wire [7:0]                  m_axi_awlen;
    wire [2:0]                  m_axi_awsize;
    wire [1:0]                  m_axi_awburst;
    wire                        m_axi_awvalid;
    wire                        m_axi_awready;
    wire [AXI_DATA_WIDTH-1:0]   m_axi_wdata;
    wire [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb;
    wire                        m_axi_wlast;
    wire                        m_axi_wvalid;
    wire                        m_axi_wready;
    wire [1:0]                  m_axi_bresp;
    wire                        m_axi_bvalid;
    wire                        m_axi_bready;

    reg [7:0] expected_output [0:32];
    integer i;

    stage4_real_data_block_record_emit_writeback_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MAX_BURST_LEN(16),
        .MAX_BLOCK_BYTES(256),
        .MAX_KEY_BYTES(64),
        .MAX_RECORDS(8),
        .MAX_OUTPUT_BYTES(512)
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
        .output_byte_count(output_byte_count),
        .decoded_entry_count(decoded_entry_count),
        .restart_count(restart_count),
        .restart_entry_count(restart_entry_count),
        .shared_key_bytes_total(shared_key_bytes_total),
        .unshared_key_bytes_total(unshared_key_bytes_total),
        .value_bytes_total(value_bytes_total),
        .last_key_len(last_key_len),
        .last_value_len(last_value_len),
        .last_shared_bytes(last_shared_bytes),
        .last_non_shared_bytes(last_non_shared_bytes),
        .restart_array_offset(restart_array_offset),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arid(),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rid(1'b0),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awid(),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bid(1'b0),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready)
    );

    axi_ram_model #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MEM_BYTES(MEM_BYTES),
        .READ_LATENCY(2)
    ) mem (
        .clk(clk),
        .rstn(rstn),
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

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rstn = 1'b0;
        clear = 1'b0;
        start = 1'b0;
        src_base_addr = SRC_ADDR;
        src_byte_count = TEST_BYTES;
        dst_base_addr = DST_ADDR;

        for (i = 0; i < MEM_BYTES; i = i + 1) begin
            mem.mem[i] = 8'h00;
        end

        mem.mem[0]  = 8'h00;
        mem.mem[1]  = 8'h03;
        mem.mem[2]  = 8'h02;
        mem.mem[3]  = "c";
        mem.mem[4]  = "a";
        mem.mem[5]  = "t";
        mem.mem[6]  = "v";
        mem.mem[7]  = "1";
        mem.mem[8]  = 8'h02;
        mem.mem[9]  = 8'h02;
        mem.mem[10] = 8'h02;
        mem.mem[11] = "r";
        mem.mem[12] = "s";
        mem.mem[13] = "v";
        mem.mem[14] = "2";
        mem.mem[15] = 8'h00;
        mem.mem[16] = 8'h04;
        mem.mem[17] = 8'h02;
        mem.mem[18] = "d";
        mem.mem[19] = "o";
        mem.mem[20] = "g";
        mem.mem[21] = "e";
        mem.mem[22] = "v";
        mem.mem[23] = "3";
        mem.mem[24] = 8'h00;
        mem.mem[25] = 8'h00;
        mem.mem[26] = 8'h00;
        mem.mem[27] = 8'h00;
        mem.mem[28] = 8'h0f;
        mem.mem[29] = 8'h00;
        mem.mem[30] = 8'h00;
        mem.mem[31] = 8'h00;
        mem.mem[32] = 8'h02;
        mem.mem[33] = 8'h00;
        mem.mem[34] = 8'h00;
        mem.mem[35] = 8'h00;

        expected_output[0]  = 8'h03;
        expected_output[1]  = 8'h00;
        expected_output[2]  = 8'h00;
        expected_output[3]  = 8'h00;
        expected_output[4]  = 8'h03;
        expected_output[5]  = 8'h00;
        expected_output[6]  = 8'h02;
        expected_output[7]  = 8'h00;
        expected_output[8]  = 8'h63;
        expected_output[9]  = 8'h61;
        expected_output[10] = 8'h74;
        expected_output[11] = 8'h76;
        expected_output[12] = 8'h31;
        expected_output[13] = 8'h04;
        expected_output[14] = 8'h00;
        expected_output[15] = 8'h02;
        expected_output[16] = 8'h00;
        expected_output[17] = 8'h63;
        expected_output[18] = 8'h61;
        expected_output[19] = 8'h72;
        expected_output[20] = 8'h73;
        expected_output[21] = 8'h76;
        expected_output[22] = 8'h32;
        expected_output[23] = 8'h04;
        expected_output[24] = 8'h00;
        expected_output[25] = 8'h02;
        expected_output[26] = 8'h00;
        expected_output[27] = 8'h64;
        expected_output[28] = 8'h6f;
        expected_output[29] = 8'h67;
        expected_output[30] = 8'h65;
        expected_output[31] = 8'h76;
        expected_output[32] = 8'h33;

        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (3) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        while (!done && !error) begin
            @(posedge clk);
        end

        if (error) begin
            $display("Stage4 real record emit writeback top reported error");
            $finish_and_return(1);
        end
        if (output_byte_count != 32'd33) begin
            $display("output_byte_count mismatch got=%0d", output_byte_count);
            $finish_and_return(1);
        end
        if (decoded_entry_count != 32'd3) begin
            $display("decoded_entry_count mismatch got=%0d", decoded_entry_count);
            $finish_and_return(1);
        end
        if (restart_count != 32'd2) begin
            $display("restart_count mismatch got=%0d", restart_count);
            $finish_and_return(1);
        end
        if (restart_entry_count != 32'd2) begin
            $display("restart_entry_count mismatch got=%0d", restart_entry_count);
            $finish_and_return(1);
        end
        if (bytes_read != 32'd36) begin
            $display("bytes_read mismatch got=%0d", bytes_read);
            $finish_and_return(1);
        end
        if (beats_read != 32'd1) begin
            $display("beats_read mismatch got=%0d", beats_read);
            $finish_and_return(1);
        end
        if (bytes_written != 32'd33) begin
            $display("bytes_written mismatch got=%0d", bytes_written);
            $finish_and_return(1);
        end
        if (beats_written != 32'd1) begin
            $display("beats_written mismatch got=%0d", beats_written);
            $finish_and_return(1);
        end
        if (last_key_len != 16'd4 || last_value_len != 16'd2 || last_shared_bytes != 16'd0 || last_non_shared_bytes != 16'd4) begin
            $display("last record summary mismatch");
            $finish_and_return(1);
        end
        for (i = 0; i < 33; i = i + 1) begin
            if (mem.mem[DST_ADDR + i] !== expected_output[i]) begin
                $display("writeback mismatch idx=%0d got=%02x exp=%02x", i, mem.mem[DST_ADDR + i], expected_output[i]);
                $finish_and_return(1);
            end
        end

        $display("PASS stage4_real_data_block_record_emit_writeback_top");
        $finish;
    end

endmodule
