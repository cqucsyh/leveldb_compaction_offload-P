`timescale 1ns / 1ps

module tb_stage4_real_data_block_decode_top;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer MEM_BYTES      = 4096;
    localparam integer TEST_BYTES     = 36;
    localparam [63:0] SRC_ADDR        = 64'h0000_0000_0000_0000;

    reg                         clk;
    reg                         rstn;
    reg                         clear;
    reg                         start;
    reg  [AXI_ADDR_WIDTH-1:0]   src_base_addr;
    reg  [31:0]                 byte_count;
    wire                        busy;
    wire                        done;
    wire                        error;
    wire [31:0]                 bytes_read;
    wire [31:0]                 beats_read;
    wire                        record_valid;
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

    integer i;
    integer seen_records;
    reg [15:0] observed_key_len [0:2];
    reg [15:0] observed_value_len [0:2];
    reg [15:0] observed_shared_len [0:2];
    reg [15:0] observed_non_shared_len [0:2];

    stage4_real_data_block_decode_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MAX_BURST_LEN(16),
        .MAX_BLOCK_BYTES(256),
        .MAX_KEY_BYTES(64)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .src_base_addr(src_base_addr),
        .byte_count(byte_count),
        .busy(busy),
        .done(done),
        .error(error),
        .bytes_read(bytes_read),
        .beats_read(beats_read),
        .record_valid(record_valid),
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
        .m_axi_rready(m_axi_rready)
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
        .s_axi_awaddr({AXI_ADDR_WIDTH{1'b0}}),
        .s_axi_awlen(8'd0),
        .s_axi_awsize(3'd0),
        .s_axi_awburst(2'd0),
        .s_axi_awid(1'b0),
        .s_axi_awvalid(1'b0),
        .s_axi_awready(),
        .s_axi_wdata({AXI_DATA_WIDTH{1'b0}}),
        .s_axi_wstrb({AXI_DATA_WIDTH/8{1'b0}}),
        .s_axi_wlast(1'b0),
        .s_axi_wvalid(1'b0),
        .s_axi_wready(),
        .s_axi_bresp(),
        .s_axi_bid(),
        .s_axi_bvalid(),
        .s_axi_bready(1'b0)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rstn = 1'b0;
        clear = 1'b0;
        start = 1'b0;
        src_base_addr = SRC_ADDR;
        byte_count = TEST_BYTES;
        seen_records = 0;
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

        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (3) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        while (!done && !error) begin
            @(posedge clk);
            if (record_valid) begin
                if (seen_records > 2) begin
                    $display("Too many record_valid pulses");
                    $finish_and_return(1);
                end
                observed_key_len[seen_records] = last_key_len;
                observed_value_len[seen_records] = last_value_len;
                observed_shared_len[seen_records] = last_shared_bytes;
                observed_non_shared_len[seen_records] = last_non_shared_bytes;
                seen_records = seen_records + 1;
            end
        end

        if (error) begin
            $display("Stage4 real data block decoder reported error");
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
        if (shared_key_bytes_total != 32'd2) begin
            $display("shared_key_bytes_total mismatch got=%0d", shared_key_bytes_total);
            $finish_and_return(1);
        end
        if (unshared_key_bytes_total != 32'd9) begin
            $display("unshared_key_bytes_total mismatch got=%0d", unshared_key_bytes_total);
            $finish_and_return(1);
        end
        if (value_bytes_total != 32'd6) begin
            $display("value_bytes_total mismatch got=%0d", value_bytes_total);
            $finish_and_return(1);
        end
        if (restart_array_offset != 32'd24) begin
            $display("restart_array_offset mismatch got=%0d", restart_array_offset);
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
        if (seen_records != 3) begin
            $display("seen_records mismatch got=%0d", seen_records);
            $finish_and_return(1);
        end
        if (observed_key_len[0] != 16'd3 || observed_value_len[0] != 16'd2 || observed_shared_len[0] != 16'd0 || observed_non_shared_len[0] != 16'd3) begin
            $display("record0 metadata mismatch");
            $finish_and_return(1);
        end
        if (observed_key_len[1] != 16'd4 || observed_value_len[1] != 16'd2 || observed_shared_len[1] != 16'd2 || observed_non_shared_len[1] != 16'd2) begin
            $display("record1 metadata mismatch");
            $finish_and_return(1);
        end
        if (observed_key_len[2] != 16'd4 || observed_value_len[2] != 16'd2 || observed_shared_len[2] != 16'd0 || observed_non_shared_len[2] != 16'd4) begin
            $display("record2 metadata mismatch");
            $finish_and_return(1);
        end
        if (last_key_len != 16'd4 || last_value_len != 16'd2 || last_shared_bytes != 16'd0 || last_non_shared_bytes != 16'd4) begin
            $display("last record summary mismatch");
            $finish_and_return(1);
        end

        $display("PASS stage4_real_data_block_decode_top");
        $finish;
    end

endmodule
