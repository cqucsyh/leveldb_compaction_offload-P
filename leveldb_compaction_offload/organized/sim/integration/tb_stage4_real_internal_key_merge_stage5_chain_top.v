`timescale 1ns / 1ps

module tb_stage4_real_internal_key_merge_stage5_chain_top;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer MEM_BYTES      = 16384;
    localparam integer SRC_BYTES      = 79;
    localparam integer MID_BYTES      = 51;
    localparam integer DST_BYTES      = 56;
    localparam [63:0] SRC_ADDR        = 64'h0000_0000_0000_0000;
    localparam [63:0] MID_ADDR        = 64'h0000_0000_0000_1000;
    localparam [63:0] DST_ADDR        = 64'h0000_0000_0000_2000;

    reg                         clk;
    reg                         rstn;
    reg                         clear;
    reg                         start;
    reg  [AXI_ADDR_WIDTH-1:0]   src_base_addr;
    reg  [31:0]                 src_byte_count;
    reg  [AXI_ADDR_WIDTH-1:0]   mid_base_addr;
    reg  [AXI_ADDR_WIDTH-1:0]   dst_base_addr;
    wire                        busy;
    wire                        done;
    wire                        error;
    wire                        stage4_done;
    wire                        stage5_done;
    wire [31:0]                 stage4_bytes_read;
    wire [31:0]                 stage4_beats_read;
    wire [31:0]                 stage4_bytes_written;
    wire [31:0]                 stage4_beats_written;
    wire [31:0]                 stage4_output_byte_count;
    wire [31:0]                 stage4_decoded_entry_count;
    wire [31:0]                 stage4_restart_count;
    wire [31:0]                 stage4_restart_entry_count;
    wire [31:0]                 stage4_shared_key_bytes_total;
    wire [31:0]                 stage4_unshared_key_bytes_total;
    wire [31:0]                 stage4_value_bytes_total;
    wire [15:0]                 stage4_last_key_len;
    wire [15:0]                 stage4_last_value_len;
    wire [15:0]                 stage4_last_shared_bytes;
    wire [15:0]                 stage4_last_non_shared_bytes;
    wire [31:0]                 stage4_restart_array_offset;
    wire [31:0]                 merge_decoded_record_count;
    wire [31:0]                 merge_merged_record_count;
    wire [31:0]                 merge_dropped_superseded_count;
    wire [31:0]                 merge_value_record_count;
    wire [31:0]                 merge_delete_record_count;
    wire [31:0]                 merge_user_key_bytes_total;
    wire [31:0]                 merge_value_bytes_total;
    wire [15:0]                 merge_last_user_key_len;
    wire [55:0]                 merge_last_sequence;
    wire [7:0]                  merge_last_value_type;
    wire                        merge_last_record_keep;
    wire [31:0]                 stage5_bytes_read;
    wire [31:0]                 stage5_beats_read;
    wire [31:0]                 stage5_bytes_written;
    wire [31:0]                 stage5_beats_written;
    wire [31:0]                 stage5_input_record_count;
    wire [31:0]                 stage5_encoded_entry_count;
    wire [31:0]                 stage5_restart_count;
    wire [31:0]                 stage5_shared_key_bytes_total;
    wire [31:0]                 stage5_unshared_key_bytes_total;
    wire [31:0]                 stage5_value_bytes_total;
    wire [15:0]                 stage5_last_key_len;
    wire [15:0]                 stage5_last_value_len;
    wire [15:0]                 stage5_last_shared_bytes;
    wire [15:0]                 stage5_last_non_shared_bytes;
    wire [31:0]                 stage5_output_block_bytes;

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

    reg [7:0] expected_mid [0:50];
    reg [7:0] expected_dst [0:55];
    integer i;
    integer seen_stage4_done;
    integer seen_stage5_done;

    stage4_real_internal_key_merge_stage5_chain_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MAX_BURST_LEN(16),
        .STAGE4_MAX_BLOCK_BYTES(256),
        .STAGE4_MAX_KEY_BYTES(64),
        .STAGE4_MAX_USER_KEY_BYTES(32),
        .STAGE4_MAX_VALUE_BYTES(16),
        .STAGE4_MAX_RECORD_BYTES(64),
        .STAGE4_MAX_RECORDS(8),
        .STAGE4_MAX_OUTPUT_BYTES(512),
        .STAGE5_MAX_RECORDS(8),
        .STAGE5_MAX_PAYLOAD_BYTES(128),
        .STAGE5_MAX_BLOCK_BYTES(128),
        .STAGE5_MAX_KEY_BYTES(64),
        .STAGE5_MAX_VALUE_BYTES(16),
        .STAGE5_RESTART_INTERVAL(2)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .src_base_addr(src_base_addr),
        .src_byte_count(src_byte_count),
        .mid_base_addr(mid_base_addr),
        .dst_base_addr(dst_base_addr),
        .busy(busy),
        .done(done),
        .error(error),
        .stage4_done(stage4_done),
        .stage5_done(stage5_done),
        .stage4_bytes_read(stage4_bytes_read),
        .stage4_beats_read(stage4_beats_read),
        .stage4_bytes_written(stage4_bytes_written),
        .stage4_beats_written(stage4_beats_written),
        .stage4_output_byte_count(stage4_output_byte_count),
        .stage4_decoded_entry_count(stage4_decoded_entry_count),
        .stage4_restart_count(stage4_restart_count),
        .stage4_restart_entry_count(stage4_restart_entry_count),
        .stage4_shared_key_bytes_total(stage4_shared_key_bytes_total),
        .stage4_unshared_key_bytes_total(stage4_unshared_key_bytes_total),
        .stage4_value_bytes_total(stage4_value_bytes_total),
        .stage4_last_key_len(stage4_last_key_len),
        .stage4_last_value_len(stage4_last_value_len),
        .stage4_last_shared_bytes(stage4_last_shared_bytes),
        .stage4_last_non_shared_bytes(stage4_last_non_shared_bytes),
        .stage4_restart_array_offset(stage4_restart_array_offset),
        .merge_decoded_record_count(merge_decoded_record_count),
        .merge_merged_record_count(merge_merged_record_count),
        .merge_dropped_superseded_count(merge_dropped_superseded_count),
        .merge_value_record_count(merge_value_record_count),
        .merge_delete_record_count(merge_delete_record_count),
        .merge_user_key_bytes_total(merge_user_key_bytes_total),
        .merge_value_bytes_total(merge_value_bytes_total),
        .merge_last_user_key_len(merge_last_user_key_len),
        .merge_last_sequence(merge_last_sequence),
        .merge_last_value_type(merge_last_value_type),
        .merge_last_record_keep(merge_last_record_keep),
        .stage5_bytes_read(stage5_bytes_read),
        .stage5_beats_read(stage5_beats_read),
        .stage5_bytes_written(stage5_bytes_written),
        .stage5_beats_written(stage5_beats_written),
        .stage5_input_record_count(stage5_input_record_count),
        .stage5_encoded_entry_count(stage5_encoded_entry_count),
        .stage5_restart_count(stage5_restart_count),
        .stage5_shared_key_bytes_total(stage5_shared_key_bytes_total),
        .stage5_unshared_key_bytes_total(stage5_unshared_key_bytes_total),
        .stage5_value_bytes_total(stage5_value_bytes_total),
        .stage5_last_key_len(stage5_last_key_len),
        .stage5_last_value_len(stage5_last_value_len),
        .stage5_last_shared_bytes(stage5_last_shared_bytes),
        .stage5_last_non_shared_bytes(stage5_last_non_shared_bytes),
        .stage5_output_block_bytes(stage5_output_block_bytes),
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
        src_byte_count = SRC_BYTES;
        mid_base_addr = MID_ADDR;
        dst_base_addr = DST_ADDR;
        seen_stage4_done = 0;
        seen_stage5_done = 0;

        for (i = 0; i < MEM_BYTES; i = i + 1) begin
            mem.mem[i] = 8'hA5;
        end

        mem.mem[SRC_ADDR + 0]  = 8'h00;
        mem.mem[SRC_ADDR + 1]  = 8'h0b;
        mem.mem[SRC_ADDR + 2]  = 8'h01;
        mem.mem[SRC_ADDR + 3]  = 8'h63;
        mem.mem[SRC_ADDR + 4]  = 8'h61;
        mem.mem[SRC_ADDR + 5]  = 8'h74;
        mem.mem[SRC_ADDR + 6]  = 8'h01;
        mem.mem[SRC_ADDR + 7]  = 8'h0a;
        mem.mem[SRC_ADDR + 8]  = 8'h00;
        mem.mem[SRC_ADDR + 9]  = 8'h00;
        mem.mem[SRC_ADDR + 10] = 8'h00;
        mem.mem[SRC_ADDR + 11] = 8'h00;
        mem.mem[SRC_ADDR + 12] = 8'h00;
        mem.mem[SRC_ADDR + 13] = 8'h00;
        mem.mem[SRC_ADDR + 14] = 8'h41;
        mem.mem[SRC_ADDR + 15] = 8'h00;
        mem.mem[SRC_ADDR + 16] = 8'h0b;
        mem.mem[SRC_ADDR + 17] = 8'h01;
        mem.mem[SRC_ADDR + 18] = 8'h63;
        mem.mem[SRC_ADDR + 19] = 8'h61;
        mem.mem[SRC_ADDR + 20] = 8'h74;
        mem.mem[SRC_ADDR + 21] = 8'h01;
        mem.mem[SRC_ADDR + 22] = 8'h09;
        mem.mem[SRC_ADDR + 23] = 8'h00;
        mem.mem[SRC_ADDR + 24] = 8'h00;
        mem.mem[SRC_ADDR + 25] = 8'h00;
        mem.mem[SRC_ADDR + 26] = 8'h00;
        mem.mem[SRC_ADDR + 27] = 8'h00;
        mem.mem[SRC_ADDR + 28] = 8'h00;
        mem.mem[SRC_ADDR + 29] = 8'h42;
        mem.mem[SRC_ADDR + 30] = 8'h00;
        mem.mem[SRC_ADDR + 31] = 8'h0b;
        mem.mem[SRC_ADDR + 32] = 8'h00;
        mem.mem[SRC_ADDR + 33] = 8'h64;
        mem.mem[SRC_ADDR + 34] = 8'h6f;
        mem.mem[SRC_ADDR + 35] = 8'h67;
        mem.mem[SRC_ADDR + 36] = 8'h00;
        mem.mem[SRC_ADDR + 37] = 8'h07;
        mem.mem[SRC_ADDR + 38] = 8'h00;
        mem.mem[SRC_ADDR + 39] = 8'h00;
        mem.mem[SRC_ADDR + 40] = 8'h00;
        mem.mem[SRC_ADDR + 41] = 8'h00;
        mem.mem[SRC_ADDR + 42] = 8'h00;
        mem.mem[SRC_ADDR + 43] = 8'h00;
        mem.mem[SRC_ADDR + 44] = 8'h00;
        mem.mem[SRC_ADDR + 45] = 8'h0b;
        mem.mem[SRC_ADDR + 46] = 8'h01;
        mem.mem[SRC_ADDR + 47] = 8'h65;
        mem.mem[SRC_ADDR + 48] = 8'h65;
        mem.mem[SRC_ADDR + 49] = 8'h6c;
        mem.mem[SRC_ADDR + 50] = 8'h01;
        mem.mem[SRC_ADDR + 51] = 8'h05;
        mem.mem[SRC_ADDR + 52] = 8'h00;
        mem.mem[SRC_ADDR + 53] = 8'h00;
        mem.mem[SRC_ADDR + 54] = 8'h00;
        mem.mem[SRC_ADDR + 55] = 8'h00;
        mem.mem[SRC_ADDR + 56] = 8'h00;
        mem.mem[SRC_ADDR + 57] = 8'h00;
        mem.mem[SRC_ADDR + 58] = 8'h5a;
        mem.mem[SRC_ADDR + 59] = 8'h00;
        mem.mem[SRC_ADDR + 60] = 8'h00;
        mem.mem[SRC_ADDR + 61] = 8'h00;
        mem.mem[SRC_ADDR + 62] = 8'h00;
        mem.mem[SRC_ADDR + 63] = 8'h0f;
        mem.mem[SRC_ADDR + 64] = 8'h00;
        mem.mem[SRC_ADDR + 65] = 8'h00;
        mem.mem[SRC_ADDR + 66] = 8'h00;
        mem.mem[SRC_ADDR + 67] = 8'h1e;
        mem.mem[SRC_ADDR + 68] = 8'h00;
        mem.mem[SRC_ADDR + 69] = 8'h00;
        mem.mem[SRC_ADDR + 70] = 8'h00;
        mem.mem[SRC_ADDR + 71] = 8'h2c;
        mem.mem[SRC_ADDR + 72] = 8'h00;
        mem.mem[SRC_ADDR + 73] = 8'h00;
        mem.mem[SRC_ADDR + 74] = 8'h00;
        mem.mem[SRC_ADDR + 75] = 8'h04;
        mem.mem[SRC_ADDR + 76] = 8'h00;
        mem.mem[SRC_ADDR + 77] = 8'h00;
        mem.mem[SRC_ADDR + 78] = 8'h00;

        expected_mid[0]  = 8'h03;
        expected_mid[1]  = 8'h00;
        expected_mid[2]  = 8'h00;
        expected_mid[3]  = 8'h00;
        expected_mid[4]  = 8'h0b;
        expected_mid[5]  = 8'h00;
        expected_mid[6]  = 8'h01;
        expected_mid[7]  = 8'h00;
        expected_mid[8]  = 8'h63;
        expected_mid[9]  = 8'h61;
        expected_mid[10] = 8'h74;
        expected_mid[11] = 8'h01;
        expected_mid[12] = 8'h0a;
        expected_mid[13] = 8'h00;
        expected_mid[14] = 8'h00;
        expected_mid[15] = 8'h00;
        expected_mid[16] = 8'h00;
        expected_mid[17] = 8'h00;
        expected_mid[18] = 8'h00;
        expected_mid[19] = 8'h41;
        expected_mid[20] = 8'h0b;
        expected_mid[21] = 8'h00;
        expected_mid[22] = 8'h00;
        expected_mid[23] = 8'h00;
        expected_mid[24] = 8'h64;
        expected_mid[25] = 8'h6f;
        expected_mid[26] = 8'h67;
        expected_mid[27] = 8'h00;
        expected_mid[28] = 8'h07;
        expected_mid[29] = 8'h00;
        expected_mid[30] = 8'h00;
        expected_mid[31] = 8'h00;
        expected_mid[32] = 8'h00;
        expected_mid[33] = 8'h00;
        expected_mid[34] = 8'h00;
        expected_mid[35] = 8'h0b;
        expected_mid[36] = 8'h00;
        expected_mid[37] = 8'h01;
        expected_mid[38] = 8'h00;
        expected_mid[39] = 8'h65;
        expected_mid[40] = 8'h65;
        expected_mid[41] = 8'h6c;
        expected_mid[42] = 8'h01;
        expected_mid[43] = 8'h05;
        expected_mid[44] = 8'h00;
        expected_mid[45] = 8'h00;
        expected_mid[46] = 8'h00;
        expected_mid[47] = 8'h00;
        expected_mid[48] = 8'h00;
        expected_mid[49] = 8'h00;
        expected_mid[50] = 8'h5a;

        expected_dst[0]  = 8'h00;
        expected_dst[1]  = 8'h0b;
        expected_dst[2]  = 8'h01;
        expected_dst[3]  = 8'h63;
        expected_dst[4]  = 8'h61;
        expected_dst[5]  = 8'h74;
        expected_dst[6]  = 8'h01;
        expected_dst[7]  = 8'h0a;
        expected_dst[8]  = 8'h00;
        expected_dst[9]  = 8'h00;
        expected_dst[10] = 8'h00;
        expected_dst[11] = 8'h00;
        expected_dst[12] = 8'h00;
        expected_dst[13] = 8'h00;
        expected_dst[14] = 8'h41;
        expected_dst[15] = 8'h00;
        expected_dst[16] = 8'h0b;
        expected_dst[17] = 8'h00;
        expected_dst[18] = 8'h64;
        expected_dst[19] = 8'h6f;
        expected_dst[20] = 8'h67;
        expected_dst[21] = 8'h00;
        expected_dst[22] = 8'h07;
        expected_dst[23] = 8'h00;
        expected_dst[24] = 8'h00;
        expected_dst[25] = 8'h00;
        expected_dst[26] = 8'h00;
        expected_dst[27] = 8'h00;
        expected_dst[28] = 8'h00;
        expected_dst[29] = 8'h00;
        expected_dst[30] = 8'h0b;
        expected_dst[31] = 8'h01;
        expected_dst[32] = 8'h65;
        expected_dst[33] = 8'h65;
        expected_dst[34] = 8'h6c;
        expected_dst[35] = 8'h01;
        expected_dst[36] = 8'h05;
        expected_dst[37] = 8'h00;
        expected_dst[38] = 8'h00;
        expected_dst[39] = 8'h00;
        expected_dst[40] = 8'h00;
        expected_dst[41] = 8'h00;
        expected_dst[42] = 8'h00;
        expected_dst[43] = 8'h5a;
        expected_dst[44] = 8'h00;
        expected_dst[45] = 8'h00;
        expected_dst[46] = 8'h00;
        expected_dst[47] = 8'h00;
        expected_dst[48] = 8'h1d;
        expected_dst[49] = 8'h00;
        expected_dst[50] = 8'h00;
        expected_dst[51] = 8'h00;
        expected_dst[52] = 8'h02;
        expected_dst[53] = 8'h00;
        expected_dst[54] = 8'h00;
        expected_dst[55] = 8'h00;

        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (3) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        while (!done && !error) begin
            @(posedge clk);
            if (stage4_done) begin
                seen_stage4_done = 1;
            end
            if (stage5_done) begin
                seen_stage5_done = 1;
            end
        end

        if (error) begin
            $display("real merge -> stage5 chain reported error");
            $finish_and_return(1);
        end
        if (!seen_stage4_done || !seen_stage5_done) begin
            $display("Stage completion pulses missing seen_stage4_done=%0d seen_stage5_done=%0d", seen_stage4_done, seen_stage5_done);
            $finish_and_return(1);
        end
        if (stage4_output_byte_count != MID_BYTES) begin
            $display("stage4_output_byte_count mismatch got=%0d", stage4_output_byte_count);
            $finish_and_return(1);
        end
        if (stage4_bytes_read != SRC_BYTES || stage4_beats_read != 32'd2) begin
            $display("stage4 read counters mismatch");
            $finish_and_return(1);
        end
        if (stage4_bytes_written != MID_BYTES || stage4_beats_written != 32'd1) begin
            $display("stage4 write counters mismatch");
            $finish_and_return(1);
        end
        if (stage4_decoded_entry_count != 32'd4 || stage4_restart_count != 32'd4 || stage4_restart_entry_count != 32'd4) begin
            $display("stage4 decoded counters mismatch");
            $finish_and_return(1);
        end
        if (merge_decoded_record_count != 32'd4 || merge_merged_record_count != 32'd3 || merge_dropped_superseded_count != 32'd1) begin
            $display("merge counters mismatch");
            $finish_and_return(1);
        end
        if (merge_value_record_count != 32'd3 || merge_delete_record_count != 32'd1) begin
            $display("merge type counters mismatch");
            $finish_and_return(1);
        end
        if (merge_user_key_bytes_total != 32'd12 || merge_value_bytes_total != 32'd3) begin
            $display("merge byte counters mismatch");
            $finish_and_return(1);
        end
        if (merge_last_user_key_len != 16'd3 || merge_last_sequence != 56'd5 || merge_last_value_type != 8'h01 || merge_last_record_keep != 1'b1) begin
            $display("merge last-record summary mismatch");
            $finish_and_return(1);
        end
        if (stage5_input_record_count != 32'd3 || stage5_encoded_entry_count != 32'd3 || stage5_restart_count != 32'd2) begin
            $display("stage5 counters mismatch");
            $finish_and_return(1);
        end
        if (stage5_shared_key_bytes_total != 32'd0 || stage5_unshared_key_bytes_total != 32'd33 || stage5_value_bytes_total != 32'd2) begin
            $display("stage5 byte counters mismatch");
            $finish_and_return(1);
        end
        if (stage5_last_key_len != 16'd11 || stage5_last_value_len != 16'd1 || stage5_last_shared_bytes != 16'd0 || stage5_last_non_shared_bytes != 16'd11) begin
            $display("stage5 last-record summary mismatch");
            $finish_and_return(1);
        end
        if (stage5_bytes_read != MID_BYTES || stage5_beats_read != 32'd1) begin
            $display("stage5 read counters mismatch");
            $finish_and_return(1);
        end
        if (stage5_output_block_bytes != DST_BYTES || stage5_bytes_written != DST_BYTES || stage5_beats_written != 32'd1) begin
            $display("stage5 write counters mismatch");
            $finish_and_return(1);
        end
        for (i = 0; i < MID_BYTES; i = i + 1) begin
            if (mem.mem[MID_ADDR + i] !== expected_mid[i]) begin
                $display("mid mismatch idx=%0d got=%02x exp=%02x", i, mem.mem[MID_ADDR + i], expected_mid[i]);
                $finish_and_return(1);
            end
        end
        if (mem.mem[MID_ADDR + MID_BYTES] !== 8'hA5) begin
            $display("mid tail byte modified unexpectedly got=%02x", mem.mem[MID_ADDR + MID_BYTES]);
            $finish_and_return(1);
        end
        for (i = 0; i < DST_BYTES; i = i + 1) begin
            if (mem.mem[DST_ADDR + i] !== expected_dst[i]) begin
                $display("dst mismatch idx=%0d got=%02x exp=%02x", i, mem.mem[DST_ADDR + i], expected_dst[i]);
                $finish_and_return(1);
            end
        end
        if (mem.mem[DST_ADDR + DST_BYTES] !== 8'hA5) begin
            $display("dst tail byte modified unexpectedly got=%02x", mem.mem[DST_ADDR + DST_BYTES]);
            $finish_and_return(1);
        end

        $display("PASS stage4_real_internal_key_merge_stage5_chain_top");
        $finish;
    end

endmodule
