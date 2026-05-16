`timescale 1ns / 1ps

module tb_stage3_internal_key_merge_top;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer MEM_BYTES      = 4096;
    localparam integer TEST_BYTES     = 73;
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
    wire                        record_keep;
    wire [31:0]                 header_record_count;
    wire [31:0]                 decoded_record_count;
    wire [31:0]                 merged_record_count;
    wire [31:0]                 dropped_superseded_count;
    wire [31:0]                 value_record_count;
    wire [31:0]                 delete_record_count;
    wire [31:0]                 user_key_bytes_total;
    wire [31:0]                 value_bytes_total;
    wire [15:0]                 last_user_key_len;
    wire [55:0]                 last_sequence;
    wire [7:0]                  last_value_type;
    wire                        last_record_keep;

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
    reg observed_keep [0:3];
    reg [55:0] observed_seq [0:3];
    reg [7:0]  observed_type [0:3];
    reg [15:0] observed_user_key_len [0:3];

    stage3_internal_key_merge_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MAX_BURST_LEN(16),
        .MAX_USER_KEY_BYTES(16)
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
        .record_keep(record_keep),
        .header_record_count(header_record_count),
        .decoded_record_count(decoded_record_count),
        .merged_record_count(merged_record_count),
        .dropped_superseded_count(dropped_superseded_count),
        .value_record_count(value_record_count),
        .delete_record_count(delete_record_count),
        .user_key_bytes_total(user_key_bytes_total),
        .value_bytes_total(value_bytes_total),
        .last_user_key_len(last_user_key_len),
        .last_sequence(last_sequence),
        .last_value_type(last_value_type),
        .last_record_keep(last_record_keep),
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

        mem.mem[0]  = 8'h50;
        mem.mem[1]  = 8'h53;
        mem.mem[2]  = 8'h54;
        mem.mem[3]  = 8'h33;
        mem.mem[4]  = 8'h04;
        mem.mem[5]  = 8'h00;
        mem.mem[6]  = 8'h00;
        mem.mem[7]  = 8'h00;

        mem.mem[8]  = 8'h0b;
        mem.mem[9]  = 8'h00;
        mem.mem[10] = 8'h01;
        mem.mem[11] = 8'h00;
        mem.mem[12] = "c";
        mem.mem[13] = "a";
        mem.mem[14] = "t";
        mem.mem[15] = 8'h01;
        mem.mem[16] = 8'h64;
        mem.mem[17] = 8'h00;
        mem.mem[18] = 8'h00;
        mem.mem[19] = 8'h00;
        mem.mem[20] = 8'h00;
        mem.mem[21] = 8'h00;
        mem.mem[22] = 8'h00;
        mem.mem[23] = "A";

        mem.mem[24] = 8'h0b;
        mem.mem[25] = 8'h00;
        mem.mem[26] = 8'h01;
        mem.mem[27] = 8'h00;
        mem.mem[28] = "c";
        mem.mem[29] = "a";
        mem.mem[30] = "t";
        mem.mem[31] = 8'h01;
        mem.mem[32] = 8'h63;
        mem.mem[33] = 8'h00;
        mem.mem[34] = 8'h00;
        mem.mem[35] = 8'h00;
        mem.mem[36] = 8'h00;
        mem.mem[37] = 8'h00;
        mem.mem[38] = 8'h00;
        mem.mem[39] = "B";

        mem.mem[40] = 8'h0b;
        mem.mem[41] = 8'h00;
        mem.mem[42] = 8'h00;
        mem.mem[43] = 8'h00;
        mem.mem[44] = "d";
        mem.mem[45] = "o";
        mem.mem[46] = "g";
        mem.mem[47] = 8'h00;
        mem.mem[48] = 8'h05;
        mem.mem[49] = 8'h00;
        mem.mem[50] = 8'h00;
        mem.mem[51] = 8'h00;
        mem.mem[52] = 8'h00;
        mem.mem[53] = 8'h00;
        mem.mem[54] = 8'h00;

        mem.mem[55] = 8'h0c;
        mem.mem[56] = 8'h00;
        mem.mem[57] = 8'h02;
        mem.mem[58] = 8'h00;
        mem.mem[59] = "e";
        mem.mem[60] = "e";
        mem.mem[61] = "l";
        mem.mem[62] = "0";
        mem.mem[63] = 8'h01;
        mem.mem[64] = 8'h09;
        mem.mem[65] = 8'h00;
        mem.mem[66] = 8'h00;
        mem.mem[67] = 8'h00;
        mem.mem[68] = 8'h00;
        mem.mem[69] = 8'h00;
        mem.mem[70] = 8'h00;
        mem.mem[71] = "O";
        mem.mem[72] = "K";

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
                if (seen_records > 3) begin
                    $display("Too many record_valid pulses");
                    $finish_and_return(1);
                end
                observed_keep[seen_records] = record_keep;
                observed_seq[seen_records] = last_sequence;
                observed_type[seen_records] = last_value_type;
                observed_user_key_len[seen_records] = last_user_key_len;
                seen_records = seen_records + 1;
            end
        end

        if (error) begin
            $display("Stage3 merge decoder reported error");
            $finish_and_return(1);
        end

        if (header_record_count != 32'd4) begin
            $display("header_record_count mismatch got=%0d", header_record_count);
            $finish_and_return(1);
        end
        if (decoded_record_count != 32'd4) begin
            $display("decoded_record_count mismatch got=%0d", decoded_record_count);
            $finish_and_return(1);
        end
        if (merged_record_count != 32'd3) begin
            $display("merged_record_count mismatch got=%0d", merged_record_count);
            $finish_and_return(1);
        end
        if (dropped_superseded_count != 32'd1) begin
            $display("dropped_superseded_count mismatch got=%0d", dropped_superseded_count);
            $finish_and_return(1);
        end
        if (value_record_count != 32'd3) begin
            $display("value_record_count mismatch got=%0d", value_record_count);
            $finish_and_return(1);
        end
        if (delete_record_count != 32'd1) begin
            $display("delete_record_count mismatch got=%0d", delete_record_count);
            $finish_and_return(1);
        end
        if (user_key_bytes_total != 32'd13) begin
            $display("user_key_bytes_total mismatch got=%0d", user_key_bytes_total);
            $finish_and_return(1);
        end
        if (value_bytes_total != 32'd4) begin
            $display("value_bytes_total mismatch got=%0d", value_bytes_total);
            $finish_and_return(1);
        end
        if (bytes_read != 32'd73) begin
            $display("bytes_read mismatch got=%0d", bytes_read);
            $finish_and_return(1);
        end
        if (beats_read != 32'd2) begin
            $display("beats_read mismatch got=%0d", beats_read);
            $finish_and_return(1);
        end
        if (seen_records != 4) begin
            $display("seen_records mismatch got=%0d", seen_records);
            $finish_and_return(1);
        end
        if (observed_keep[0] != 1'b1 || observed_seq[0] != 56'd100 || observed_type[0] != 8'h01 || observed_user_key_len[0] != 16'd3) begin
            $display("record0 merged metadata mismatch");
            $finish_and_return(1);
        end
        if (observed_keep[1] != 1'b0 || observed_seq[1] != 56'd99 || observed_type[1] != 8'h01 || observed_user_key_len[1] != 16'd3) begin
            $display("record1 merged metadata mismatch");
            $finish_and_return(1);
        end
        if (observed_keep[2] != 1'b1 || observed_seq[2] != 56'd5 || observed_type[2] != 8'h00 || observed_user_key_len[2] != 16'd3) begin
            $display("record2 merged metadata mismatch");
            $finish_and_return(1);
        end
        if (observed_keep[3] != 1'b1 || observed_seq[3] != 56'd9 || observed_type[3] != 8'h01 || observed_user_key_len[3] != 16'd4) begin
            $display("record3 merged metadata mismatch");
            $finish_and_return(1);
        end
        if (last_user_key_len != 16'd4) begin
            $display("last_user_key_len mismatch got=%0d", last_user_key_len);
            $finish_and_return(1);
        end
        if (last_sequence != 56'd9) begin
            $display("last_sequence mismatch got=%0d", last_sequence);
            $finish_and_return(1);
        end
        if (last_value_type != 8'h01) begin
            $display("last_value_type mismatch got=%0d", last_value_type);
            $finish_and_return(1);
        end
        if (last_record_keep != 1'b1) begin
            $display("last_record_keep mismatch got=%0d", last_record_keep);
            $finish_and_return(1);
        end

        $display("PASS stage3_internal_key_merge_top");
        $finish;
    end

endmodule
