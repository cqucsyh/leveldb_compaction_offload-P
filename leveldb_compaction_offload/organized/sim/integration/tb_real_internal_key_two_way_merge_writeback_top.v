`timescale 1ns / 1ps

module tb_real_internal_key_two_way_merge_writeback_top;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer MEM_BYTES      = 8192;
    localparam integer SRC0_RECORDS   = 4;
    localparam integer SRC1_RECORDS   = 5;
    localparam integer SRC0_BYTES     = 47;
    localparam integer SRC1_BYTES     = 60;
    localparam integer OUT_BYTES      = 99;
    localparam [63:0] DST_ADDR        = 64'h0000_0000_0000_0200;

    reg                         clk;
    reg                         rstn;
    reg                         clear;
    reg                         start;

    reg                         source0_done;
    reg                         s0_record_valid;
    wire                        s0_record_ready;
    reg  [15:0]                 s0_record_key_len;
    reg  [15:0]                 s0_record_value_len;
    reg  [7:0]                  s0_axis_tdata;
    reg  [0:0]                  s0_axis_tkeep;
    reg                         s0_axis_tlast;
    reg                         s0_axis_tvalid;
    wire                        s0_axis_tready;

    reg                         source1_done;
    reg                         s1_record_valid;
    wire                        s1_record_ready;
    reg  [15:0]                 s1_record_key_len;
    reg  [15:0]                 s1_record_value_len;
    reg  [7:0]                  s1_axis_tdata;
    reg  [0:0]                  s1_axis_tkeep;
    reg                         s1_axis_tlast;
    reg                         s1_axis_tvalid;
    wire                        s1_axis_tready;

    reg  [AXI_ADDR_WIDTH-1:0]   dst_base_addr;
    wire                        busy;
    wire                        done;
    wire                        error;
    wire [31:0]                 bytes_written;
    wire [31:0]                 beats_written;
    wire [31:0]                 output_byte_count;
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

    reg [15:0] src0_key_len [0:SRC0_RECORDS-1];
    reg [15:0] src0_val_len [0:SRC0_RECORDS-1];
    reg [31:0] src0_offset  [0:SRC0_RECORDS-1];
    reg [31:0] src0_total   [0:SRC0_RECORDS-1];
    reg [7:0]  src0_payload [0:SRC0_BYTES-1];

    reg [15:0] src1_key_len [0:SRC1_RECORDS-1];
    reg [15:0] src1_val_len [0:SRC1_RECORDS-1];
    reg [31:0] src1_offset  [0:SRC1_RECORDS-1];
    reg [31:0] src1_total   [0:SRC1_RECORDS-1];
    reg [7:0]  src1_payload [0:SRC1_BYTES-1];

    reg [7:0] expected_output [0:OUT_BYTES-1];

    integer i;
    integer src0_rec_index;
    integer src0_byte_index;
    integer src1_rec_index;
    integer src1_byte_index;
    reg     src0_in_payload;
    reg     src1_in_payload;

    real_internal_key_two_way_merge_writeback_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MAX_BURST_LEN(16),
        .MAX_USER_KEY_BYTES(256),
        .MAX_KEY_BYTES(264),
        .MAX_VALUE_BYTES(1024),
        .MAX_RECORD_BYTES(2048),
        .MAX_RECORDS(256),
        .MAX_OUTPUT_BYTES(1024)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .seed_prev_user_key_valid(1'b0),
        .seed_prev_user_key_len(16'd0),
        .seed_prev_user_key({(256*8){1'b0}}),
        .source0_done(source0_done),
        .s0_record_valid(s0_record_valid),
        .s0_record_ready(s0_record_ready),
        .s0_record_key_len(s0_record_key_len),
        .s0_record_value_len(s0_record_value_len),
        .s0_axis_tdata(s0_axis_tdata),
        .s0_axis_tkeep(s0_axis_tkeep),
        .s0_axis_tlast(s0_axis_tlast),
        .s0_axis_tvalid(s0_axis_tvalid),
        .s0_axis_tready(s0_axis_tready),
        .source1_done(source1_done),
        .s1_record_valid(s1_record_valid),
        .s1_record_ready(s1_record_ready),
        .s1_record_key_len(s1_record_key_len),
        .s1_record_value_len(s1_record_value_len),
        .s1_axis_tdata(s1_axis_tdata),
        .s1_axis_tkeep(s1_axis_tkeep),
        .s1_axis_tlast(s1_axis_tlast),
        .s1_axis_tvalid(s1_axis_tvalid),
        .s1_axis_tready(s1_axis_tready),
        .dst_base_addr(dst_base_addr),
        .busy(busy),
        .done(done),
        .error(error),
        .bytes_written(bytes_written),
        .beats_written(beats_written),
        .output_byte_count(output_byte_count),
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
        .final_prev_user_key_valid(),
        .final_prev_user_key_len(),
        .final_prev_user_key(),
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
        .s_axi_araddr({AXI_ADDR_WIDTH{1'b0}}),
        .s_axi_arlen(8'd0),
        .s_axi_arsize(3'd0),
        .s_axi_arburst(2'd0),
        .s_axi_arid(1'b0),
        .s_axi_arvalid(1'b0),
        .s_axi_arready(),
        .s_axi_rdata(),
        .s_axi_rresp(),
        .s_axi_rlast(),
        .s_axi_rid(),
        .s_axi_rvalid(),
        .s_axi_rready(1'b0),
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

    task automatic drive_source0;
        integer rec_idx;
        integer byte_idx;
        begin
            source0_done        = 1'b0;
            s0_record_valid     = 1'b0;
            s0_record_key_len   = 16'd0;
            s0_record_value_len = 16'd0;
            s0_axis_tdata       = 8'd0;
            s0_axis_tkeep       = 1'b1;
            s0_axis_tlast       = 1'b0;
            s0_axis_tvalid      = 1'b0;
            src0_rec_index      = 0;
            src0_byte_index     = 0;
            src0_in_payload     = 1'b0;
            wait (busy);
            for (rec_idx = 0; rec_idx < SRC0_RECORDS; rec_idx = rec_idx + 1) begin
                src0_rec_index = rec_idx;
                @(negedge clk);
                s0_record_key_len   = src0_key_len[rec_idx];
                s0_record_value_len = src0_val_len[rec_idx];
                s0_record_valid     = 1'b1;
                while (!s0_record_ready) begin
                    @(negedge clk);
                end
                @(posedge clk);
                @(negedge clk);
                s0_record_valid = 1'b0;
                src0_in_payload = 1'b1;
                for (byte_idx = 0; byte_idx < src0_total[rec_idx]; byte_idx = byte_idx + 1) begin
                    src0_byte_index = byte_idx;
                    @(negedge clk);
                    s0_axis_tdata  = src0_payload[src0_offset[rec_idx] + byte_idx];
                    s0_axis_tlast  = (byte_idx + 1 == src0_total[rec_idx]);
                    s0_axis_tvalid = 1'b1;
                    while (!s0_axis_tready) begin
                        @(negedge clk);
                    end
                    @(posedge clk);
                end
                @(negedge clk);
                s0_axis_tvalid  = 1'b0;
                s0_axis_tlast   = 1'b0;
                src0_byte_index = 0;
                src0_in_payload = 1'b0;
            end
            src0_rec_index = SRC0_RECORDS;
            @(negedge clk);
            source0_done = 1'b1;
            @(posedge clk);
            @(negedge clk);
            source0_done = 1'b0;
        end
    endtask

    task automatic drive_source1;
        integer rec_idx;
        integer byte_idx;
        begin
            source1_done        = 1'b0;
            s1_record_valid     = 1'b0;
            s1_record_key_len   = 16'd0;
            s1_record_value_len = 16'd0;
            s1_axis_tdata       = 8'd0;
            s1_axis_tkeep       = 1'b1;
            s1_axis_tlast       = 1'b0;
            s1_axis_tvalid      = 1'b0;
            src1_rec_index      = 0;
            src1_byte_index     = 0;
            src1_in_payload     = 1'b0;
            wait (busy);
            for (rec_idx = 0; rec_idx < SRC1_RECORDS; rec_idx = rec_idx + 1) begin
                src1_rec_index = rec_idx;
                @(negedge clk);
                s1_record_key_len   = src1_key_len[rec_idx];
                s1_record_value_len = src1_val_len[rec_idx];
                s1_record_valid     = 1'b1;
                while (!s1_record_ready) begin
                    @(negedge clk);
                end
                @(posedge clk);
                @(negedge clk);
                s1_record_valid = 1'b0;
                src1_in_payload = 1'b1;
                for (byte_idx = 0; byte_idx < src1_total[rec_idx]; byte_idx = byte_idx + 1) begin
                    src1_byte_index = byte_idx;
                    @(negedge clk);
                    s1_axis_tdata  = src1_payload[src1_offset[rec_idx] + byte_idx];
                    s1_axis_tlast  = (byte_idx + 1 == src1_total[rec_idx]);
                    s1_axis_tvalid = 1'b1;
                    while (!s1_axis_tready) begin
                        @(negedge clk);
                    end
                    @(posedge clk);
                end
                @(negedge clk);
                s1_axis_tvalid  = 1'b0;
                s1_axis_tlast   = 1'b0;
                src1_byte_index = 0;
                src1_in_payload = 1'b0;
            end
            src1_rec_index = SRC1_RECORDS;
            @(negedge clk);
            source1_done = 1'b1;
            @(posedge clk);
            @(negedge clk);
            source1_done = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rstn = 1'b0;
        clear = 1'b0;
        start = 1'b0;
        source0_done = 1'b0;
        s0_record_valid = 1'b0;
        s0_record_key_len = 16'd0;
        s0_record_value_len = 16'd0;
        s0_axis_tdata = 8'd0;
        s0_axis_tkeep = 1'b1;
        s0_axis_tlast = 1'b0;
        s0_axis_tvalid = 1'b0;
        source1_done = 1'b0;
        s1_record_valid = 1'b0;
        s1_record_key_len = 16'd0;
        s1_record_value_len = 16'd0;
        s1_axis_tdata = 8'd0;
        s1_axis_tkeep = 1'b1;
        s1_axis_tlast = 1'b0;
        s1_axis_tvalid = 1'b0;
        dst_base_addr = DST_ADDR;

        for (i = 0; i < MEM_BYTES; i = i + 1) begin
            mem.mem[i] = 8'hA5;
        end

        for (i = 0; i < SRC0_RECORDS; i = i + 1) begin
            src0_key_len[i] = 16'd11;
            src0_val_len[i] = 16'd1;
            src0_offset[i]  = 32'd0;
            src0_total[i]   = 32'd12;
        end
        src0_val_len[2] = 16'd0;
        src0_total[2]   = 32'd11;
        src0_offset[0]  = 32'd0;
        src0_offset[1]  = 32'd12;
        src0_offset[2]  = 32'd24;
        src0_offset[3]  = 32'd35;

        src0_payload[0]  = "a"; src0_payload[1]  = "n"; src0_payload[2]  = "t"; src0_payload[3]  = 8'h01;
        src0_payload[4]  = 8'h64; src0_payload[5]  = 8'h00; src0_payload[6]  = 8'h00; src0_payload[7]  = 8'h00;
        src0_payload[8]  = 8'h00; src0_payload[9]  = 8'h00; src0_payload[10] = 8'h00; src0_payload[11] = "A";
        src0_payload[12] = "c"; src0_payload[13] = "a"; src0_payload[14] = "t"; src0_payload[15] = 8'h01;
        src0_payload[16] = 8'h5f; src0_payload[17] = 8'h00; src0_payload[18] = 8'h00; src0_payload[19] = 8'h00;
        src0_payload[20] = 8'h00; src0_payload[21] = 8'h00; src0_payload[22] = 8'h00; src0_payload[23] = "a";
        src0_payload[24] = "d"; src0_payload[25] = "o"; src0_payload[26] = "g"; src0_payload[27] = 8'h00;
        src0_payload[28] = 8'h5a; src0_payload[29] = 8'h00; src0_payload[30] = 8'h00; src0_payload[31] = 8'h00;
        src0_payload[32] = 8'h00; src0_payload[33] = 8'h00; src0_payload[34] = 8'h00;
        src0_payload[35] = "y"; src0_payload[36] = "a"; src0_payload[37] = "k"; src0_payload[38] = 8'h01;
        src0_payload[39] = 8'h32; src0_payload[40] = 8'h00; src0_payload[41] = 8'h00; src0_payload[42] = 8'h00;
        src0_payload[43] = 8'h00; src0_payload[44] = 8'h00; src0_payload[45] = 8'h00; src0_payload[46] = "Y";

        for (i = 0; i < SRC1_RECORDS; i = i + 1) begin
            src1_key_len[i] = 16'd11;
            src1_val_len[i] = 16'd1;
            src1_offset[i]  = 32'd12 * i;
            src1_total[i]   = 32'd12;
        end

        src1_payload[0]  = "b"; src1_payload[1]  = "e"; src1_payload[2]  = "e"; src1_payload[3]  = 8'h01;
        src1_payload[4]  = 8'h6e; src1_payload[5]  = 8'h00; src1_payload[6]  = 8'h00; src1_payload[7]  = 8'h00;
        src1_payload[8]  = 8'h00; src1_payload[9]  = 8'h00; src1_payload[10] = 8'h00; src1_payload[11] = "B";
        src1_payload[12] = "c"; src1_payload[13] = "a"; src1_payload[14] = "t"; src1_payload[15] = 8'h01;
        src1_payload[16] = 8'h61; src1_payload[17] = 8'h00; src1_payload[18] = 8'h00; src1_payload[19] = 8'h00;
        src1_payload[20] = 8'h00; src1_payload[21] = 8'h00; src1_payload[22] = 8'h00; src1_payload[23] = "C";
        src1_payload[24] = "c"; src1_payload[25] = "a"; src1_payload[26] = "t"; src1_payload[27] = 8'h01;
        src1_payload[28] = 8'h60; src1_payload[29] = 8'h00; src1_payload[30] = 8'h00; src1_payload[31] = 8'h00;
        src1_payload[32] = 8'h00; src1_payload[33] = 8'h00; src1_payload[34] = 8'h00; src1_payload[35] = "c";
        src1_payload[36] = "e"; src1_payload[37] = "e"; src1_payload[38] = "l"; src1_payload[39] = 8'h01;
        src1_payload[40] = 8'h50; src1_payload[41] = 8'h00; src1_payload[42] = 8'h00; src1_payload[43] = 8'h00;
        src1_payload[44] = 8'h00; src1_payload[45] = 8'h00; src1_payload[46] = 8'h00; src1_payload[47] = "E";
        src1_payload[48] = "y"; src1_payload[49] = "a"; src1_payload[50] = "k"; src1_payload[51] = 8'h01;
        src1_payload[52] = 8'h31; src1_payload[53] = 8'h00; src1_payload[54] = 8'h00; src1_payload[55] = 8'h00;
        src1_payload[56] = 8'h00; src1_payload[57] = 8'h00; src1_payload[58] = 8'h00; src1_payload[59] = "y";

        expected_output[0] = 8'h06; expected_output[1] = 8'h00; expected_output[2] = 8'h00; expected_output[3] = 8'h00;
        expected_output[4] = 8'h0b; expected_output[5] = 8'h00; expected_output[6] = 8'h01; expected_output[7] = 8'h00;
        expected_output[8] = "a"; expected_output[9] = "n"; expected_output[10] = "t"; expected_output[11] = 8'h01;
        expected_output[12] = 8'h64; expected_output[13] = 8'h00; expected_output[14] = 8'h00; expected_output[15] = 8'h00;
        expected_output[16] = 8'h00; expected_output[17] = 8'h00; expected_output[18] = 8'h00; expected_output[19] = "A";
        expected_output[20] = 8'h0b; expected_output[21] = 8'h00; expected_output[22] = 8'h01; expected_output[23] = 8'h00;
        expected_output[24] = "b"; expected_output[25] = "e"; expected_output[26] = "e"; expected_output[27] = 8'h01;
        expected_output[28] = 8'h6e; expected_output[29] = 8'h00; expected_output[30] = 8'h00; expected_output[31] = 8'h00;
        expected_output[32] = 8'h00; expected_output[33] = 8'h00; expected_output[34] = 8'h00; expected_output[35] = "B";
        expected_output[36] = 8'h0b; expected_output[37] = 8'h00; expected_output[38] = 8'h01; expected_output[39] = 8'h00;
        expected_output[40] = "c"; expected_output[41] = "a"; expected_output[42] = "t"; expected_output[43] = 8'h01;
        expected_output[44] = 8'h61; expected_output[45] = 8'h00; expected_output[46] = 8'h00; expected_output[47] = 8'h00;
        expected_output[48] = 8'h00; expected_output[49] = 8'h00; expected_output[50] = 8'h00; expected_output[51] = "C";
        expected_output[52] = 8'h0b; expected_output[53] = 8'h00; expected_output[54] = 8'h00; expected_output[55] = 8'h00;
        expected_output[56] = "d"; expected_output[57] = "o"; expected_output[58] = "g"; expected_output[59] = 8'h00;
        expected_output[60] = 8'h5a; expected_output[61] = 8'h00; expected_output[62] = 8'h00; expected_output[63] = 8'h00;
        expected_output[64] = 8'h00; expected_output[65] = 8'h00; expected_output[66] = 8'h00;
        expected_output[67] = 8'h0b; expected_output[68] = 8'h00; expected_output[69] = 8'h01; expected_output[70] = 8'h00;
        expected_output[71] = "e"; expected_output[72] = "e"; expected_output[73] = "l"; expected_output[74] = 8'h01;
        expected_output[75] = 8'h50; expected_output[76] = 8'h00; expected_output[77] = 8'h00; expected_output[78] = 8'h00;
        expected_output[79] = 8'h00; expected_output[80] = 8'h00; expected_output[81] = 8'h00; expected_output[82] = "E";
        expected_output[83] = 8'h0b; expected_output[84] = 8'h00; expected_output[85] = 8'h01; expected_output[86] = 8'h00;
        expected_output[87] = "y"; expected_output[88] = "a"; expected_output[89] = "k"; expected_output[90] = 8'h01;
        expected_output[91] = 8'h32; expected_output[92] = 8'h00; expected_output[93] = 8'h00; expected_output[94] = 8'h00;
        expected_output[95] = 8'h00; expected_output[96] = 8'h00; expected_output[97] = 8'h00; expected_output[98] = "Y";

        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (3) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        fork
            drive_source0();
            drive_source1();
        join_none

        for (i = 0; i < 8000; i = i + 1) begin
            @(posedge clk);
            if (done || error) begin
                i = 8000;
            end
        end

        if (error) begin
            $display("real_internal_key_two_way_merge_writeback_top reported error");
            $finish_and_return(1);
        end
        if (!done) begin
            $display("timeout waiting for done");
            $finish_and_return(1);
        end
        if (merge_decoded_record_count != 32'd9) begin
            $display("merge_decoded_record_count mismatch got=%0d", merge_decoded_record_count);
            $finish_and_return(1);
        end
        if (merge_merged_record_count != 32'd6) begin
            $display("merge_merged_record_count mismatch got=%0d", merge_merged_record_count);
            $finish_and_return(1);
        end
        if (merge_dropped_superseded_count != 32'd3) begin
            $display("merge_dropped_superseded_count mismatch got=%0d", merge_dropped_superseded_count);
            $finish_and_return(1);
        end
        if (merge_value_record_count != 32'd8) begin
            $display("merge_value_record_count mismatch got=%0d", merge_value_record_count);
            $finish_and_return(1);
        end
        if (merge_delete_record_count != 32'd1) begin
            $display("merge_delete_record_count mismatch got=%0d", merge_delete_record_count);
            $finish_and_return(1);
        end
        if (merge_user_key_bytes_total != 32'd27) begin
            $display("merge_user_key_bytes_total mismatch got=%0d", merge_user_key_bytes_total);
            $finish_and_return(1);
        end
        if (merge_value_bytes_total != 32'd8) begin
            $display("merge_value_bytes_total mismatch got=%0d", merge_value_bytes_total);
            $finish_and_return(1);
        end
        if (merge_last_user_key_len != 16'd3) begin
            $display("merge_last_user_key_len mismatch got=%0d", merge_last_user_key_len);
            $finish_and_return(1);
        end
        if (merge_last_sequence != 56'd49) begin
            $display("merge_last_sequence mismatch got=%0d", merge_last_sequence);
            $finish_and_return(1);
        end
        if (merge_last_value_type != 8'h01) begin
            $display("merge_last_value_type mismatch got=%0h", merge_last_value_type);
            $finish_and_return(1);
        end
        if (merge_last_record_keep != 1'b0) begin
            $display("merge_last_record_keep mismatch got=%0d", merge_last_record_keep);
            $finish_and_return(1);
        end
        if (output_byte_count != 32'd99) begin
            $display("output_byte_count mismatch got=%0d", output_byte_count);
            $finish_and_return(1);
        end
        if (bytes_written != 32'd99) begin
            $display("bytes_written mismatch got=%0d", bytes_written);
            $finish_and_return(1);
        end
        if (beats_written != 32'd2) begin
            $display("beats_written mismatch got=%0d", beats_written);
            $finish_and_return(1);
        end
        for (i = 0; i < OUT_BYTES; i = i + 1) begin
            if (mem.mem[DST_ADDR + i] !== expected_output[i]) begin
                $display("writeback mismatch idx=%0d got=%02x exp=%02x", i, mem.mem[DST_ADDR + i], expected_output[i]);
                $finish_and_return(1);
            end
        end
        if (mem.mem[DST_ADDR + OUT_BYTES] !== 8'hA5) begin
            $display("destination tail byte modified unexpectedly got=%02x", mem.mem[DST_ADDR + OUT_BYTES]);
            $finish_and_return(1);
        end

        $display("PASS real_internal_key_two_way_merge_writeback_top out_bytes=%0d beats_written=%0d decoded=%0d kept=%0d dropped=%0d",
                 output_byte_count,
                 beats_written,
                 merge_decoded_record_count,
                 merge_merged_record_count,
                 merge_dropped_superseded_count);
        $finish;
    end

endmodule
