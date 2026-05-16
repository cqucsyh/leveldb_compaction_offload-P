`timescale 1ns / 1ps

module tb_stage5_real_data_block_encode_top_multibeat;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer AXI_ID_WIDTH   = 1;
    localparam integer MEM_BYTES      = 16384;
    localparam integer RECORD_COUNT   = 17;

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

    reg [7:0] input_bytes [0:1023];
    reg [7:0] expected_block [0:1023];
    reg [7:0] observed_input_bytes [0:1023];
    reg [7:0] cur_key [0:31];
    reg [7:0] prev_key [0:31];
    reg [7:0] cur_val [0:31];
    integer input_len;
    integer expected_len;
    integer observed_input_len;
    integer i;
    integer j;
    integer shared;
    integer non_shared;
    integer restart_offsets [0:31];
    integer restart_count_exp;
    integer entries_since_restart;
    integer key_len_i;
    integer value_len_i;
    integer restart_array_offset;

    stage5_real_data_block_encode_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(16),
        .MAX_RECORDS(32),
        .MAX_PAYLOAD_BYTES(1024),
        .MAX_BLOCK_BYTES(1024),
        .MAX_KEY_BYTES(32),
        .MAX_VALUE_BYTES(32),
        .RESTART_INTERVAL(16)
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

    always @(posedge clk) begin
        if (rstn && dut.read_byte_tvalid && dut.read_byte_tready) begin
            observed_input_bytes[observed_input_len] <= dut.read_byte_tdata;
            observed_input_len <= observed_input_len + 1;
        end
    end

    always #5 clk = ~clk;

    task append_input_byte;
        input [7:0] value;
        begin
            input_bytes[input_len] = value;
            input_len = input_len + 1;
        end
    endtask

    task append_expected_byte;
        input [7:0] value;
        begin
            expected_block[expected_len] = value;
            expected_len = expected_len + 1;
        end
    endtask

    task append_fixed32_le;
        input integer value;
        begin
            append_expected_byte(value[7:0]);
            append_expected_byte(value[15:8]);
            append_expected_byte(value[23:16]);
            append_expected_byte(value[31:24]);
        end
    endtask

    task build_record_bytes;
        input integer rec_idx;
        begin
            cur_key[0]  = "p";
            cur_key[1]  = "r";
            cur_key[2]  = "e";
            cur_key[3]  = "f";
            cur_key[4]  = "i";
            cur_key[5]  = "x";
            cur_key[6]  = "_";
            cur_key[7]  = "s";
            cur_key[8]  = "h";
            cur_key[9]  = "a";
            cur_key[10] = "r";
            cur_key[11] = "e";
            cur_key[12] = "d";
            cur_key[13] = "_";
            cur_key[14] = "0" + ((rec_idx / 10) % 10);
            cur_key[15] = "0" + (rec_idx % 10);
            key_len_i = 16;

            cur_val[0] = "p";
            cur_val[1] = "v";
            cur_val[2] = "0" + ((rec_idx / 10) % 10);
            cur_val[3] = "0" + (rec_idx % 10);
            value_len_i = 4;
        end
    endtask

    initial begin
        clk = 1'b0;
        rstn = 1'b0;
        clear = 1'b0;
        start = 1'b0;
        src_base_addr = 64'h0;
        src_byte_count = 32'd0;
        dst_base_addr = 64'h0000_0000_0000_1000;
        input_len = 0;
        expected_len = 0;
        observed_input_len = 0;
        restart_count_exp = 0;
        entries_since_restart = 0;
        restart_array_offset = 0;

        append_input_byte(RECORD_COUNT[7:0]);
        append_input_byte(RECORD_COUNT[15:8]);
        append_input_byte(RECORD_COUNT[23:16]);
        append_input_byte(RECORD_COUNT[31:24]);

        restart_offsets[0] = 0;
        restart_count_exp = 1;

        for (i = 0; i < RECORD_COUNT; i = i + 1) begin
            build_record_bytes(i);
            append_input_byte(key_len_i[7:0]);
            append_input_byte(key_len_i[15:8]);
            append_input_byte(value_len_i[7:0]);
            append_input_byte(value_len_i[15:8]);
            for (j = 0; j < key_len_i; j = j + 1) begin
                append_input_byte(cur_key[j]);
            end
            for (j = 0; j < value_len_i; j = j + 1) begin
                append_input_byte(cur_val[j]);
            end

            if ((i == 0) || (entries_since_restart == 16)) begin
                shared = 0;
                if (i != 0) begin
                    restart_offsets[restart_count_exp] = expected_len;
                    restart_count_exp = restart_count_exp + 1;
                end
                entries_since_restart = 0;
            end else begin
                shared = 0;
                while ((shared < key_len_i) && (cur_key[shared] == prev_key[shared])) begin
                    shared = shared + 1;
                end
            end
            non_shared = key_len_i - shared;
            append_expected_byte(shared[7:0]);
            append_expected_byte(non_shared[7:0]);
            append_expected_byte(value_len_i[7:0]);
            for (j = shared; j < key_len_i; j = j + 1) begin
                append_expected_byte(cur_key[j]);
            end
            for (j = 0; j < value_len_i; j = j + 1) begin
                append_expected_byte(cur_val[j]);
            end
            entries_since_restart = entries_since_restart + 1;
            for (j = 0; j < key_len_i; j = j + 1) begin
                prev_key[j] = cur_key[j];
            end
        end

        restart_array_offset = expected_len;
        for (i = 0; i < restart_count_exp; i = i + 1) begin
            append_fixed32_le(restart_offsets[i]);
        end
        append_fixed32_le(restart_count_exp);

        src_byte_count = input_len;

        repeat (4) @(posedge clk);
        rstn = 1'b1;
        repeat (2) @(posedge clk);

        for (i = 0; i < input_len; i = i + 1) begin
            ram.mem[i] = input_bytes[i];
        end
        for (i = 0; i < ((expected_len + 63) / 64) * 64; i = i + 1) begin
            ram.mem[dst_base_addr[15:0] + i] = 8'hA5;
        end

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        while (!done && !error) begin
            @(posedge clk);
        end

        if (error) begin
            $display("Stage5 top reported error in multibeat simulation");
            $display("bytes_read=%0d beats_read=%0d input_record_count=%0d encoded_entry_count=%0d", bytes_read, beats_read, input_record_count, encoded_entry_count);
            $display("observed_input_len=%0d expected_input_len=%0d", observed_input_len, input_len);
            for (i = 0; i < observed_input_len; i = i + 1) begin
                if (observed_input_bytes[i] !== input_bytes[i]) begin
                    $display("Input stream mismatch idx=%0d got=%02x exp=%02x", i, observed_input_bytes[i], input_bytes[i]);
                    $finish_and_return(1);
                end
            end
            $finish_and_return(1);
        end

        if (input_record_count !== RECORD_COUNT ||
            encoded_entry_count !== RECORD_COUNT ||
            restart_count !== restart_count_exp ||
            output_block_bytes !== expected_len ||
            bytes_read !== input_len ||
            bytes_written !== expected_len) begin
            $display("Stage5 top counter mismatch in multibeat simulation");
            $finish_and_return(1);
        end

        for (i = 0; i < expected_len; i = i + 1) begin
            if (ram.mem[dst_base_addr[15:0] + i] !== expected_block[i]) begin
                $display("Stage5 top output mismatch idx=%0d got=%02x exp=%02x", i, ram.mem[dst_base_addr[15:0] + i], expected_block[i]);
                $finish_and_return(1);
            end
        end

        for (i = expected_len; i < ((expected_len + 63) / 64) * 64; i = i + 1) begin
            if (ram.mem[dst_base_addr[15:0] + i] !== 8'hA5) begin
                $display("Stage5 top tail byte modified idx=%0d got=%02x", i, ram.mem[dst_base_addr[15:0] + i]);
                $finish_and_return(1);
            end
        end

        $display("PASS stage5_real_data_block_encode_top multibeat");
        $finish;
    end

endmodule
