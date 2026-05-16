`timescale 1ns / 1ps

module tb_real_internal_key_two_way_merge_stage5_chain_top_v2;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer MEM_BYTES      = 16384;
    localparam integer SRC0_RECORDS   = 4;
    localparam integer SRC1_RECORDS   = 5;
    localparam integer SRC0_BYTES     = 47;
    localparam integer SRC1_BYTES     = 60;
    localparam integer MID_BYTES      = 99;
    localparam integer DST_BYTES      = 97;
    localparam [63:0] MID_ADDR        = 64'h0000_0000_0000_0200;
    localparam [63:0] DST_ADDR        = 64'h0000_0000_0000_0400;

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

    reg  [AXI_ADDR_WIDTH-1:0]   mid_base_addr;
    reg  [AXI_ADDR_WIDTH-1:0]   dst_base_addr;
    wire                        busy;
    wire                        done;
    wire                        error;
    wire                        merge_done;
    wire                        stage5_done;
    wire [31:0]                 merge_bytes_written;
    wire [31:0]                 merge_beats_written;
    wire [31:0]                 merge_output_byte_count;
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

    reg [7:0] expected_dst [0:DST_BYTES-1];

    integer i;
    integer src0_rec_index;
    integer src0_byte_index;
    integer src1_rec_index;
    integer src1_byte_index;
    reg     src0_in_payload;
    reg     src1_in_payload;
    reg     saw_merge_done;
    reg     saw_stage5_done;

    integer start_cycle;
    integer done_cycle;

    real_internal_key_two_way_merge_stage5_chain_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MAX_BURST_LEN(16),
        .MERGE_MAX_USER_KEY_BYTES(256),
        .MERGE_MAX_KEY_BYTES(264),
        .MERGE_MAX_VALUE_BYTES(1024),
        .MERGE_MAX_RECORD_BYTES(2048),
        .MERGE_MAX_RECORDS(256),
        .MERGE_MAX_OUTPUT_BYTES(1024),
        .STAGE5_MAX_RECORDS(256),
        .STAGE5_MAX_PAYLOAD_BYTES(1024),
        .STAGE5_MAX_BLOCK_BYTES(1024),
        .STAGE5_MAX_KEY_BYTES(256),
        .STAGE5_MAX_VALUE_BYTES(1024),
        .STAGE5_RESTART_INTERVAL(16)
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
        .mid_base_addr(mid_base_addr),
        .dst_base_addr(dst_base_addr),
        .busy(busy),
        .done(done),
        .error(error),
        .merge_done(merge_done),
        .stage5_done(stage5_done),
        .merge_bytes_written(merge_bytes_written),
        .merge_beats_written(merge_beats_written),
        .merge_output_byte_count(merge_output_byte_count),
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
        .final_prev_user_key_valid(),
        .final_prev_user_key_len(),
        .final_prev_user_key(),
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

    always @(posedge clk) begin
        if (!rstn || clear) begin
            saw_merge_done  <= 1'b0;
            saw_stage5_done <= 1'b0;
        end else begin
            if (merge_done) saw_merge_done  <= 1'b1;
            if (stage5_done) saw_stage5_done <= 1'b1;
        end
    end

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
                while (!s0_record_ready) @(negedge clk);
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
                    while (!s0_axis_tready) @(negedge clk);
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
                while (!s1_record_ready) @(negedge clk);
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
                    while (!s1_axis_tready) @(negedge clk);
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
        mid_base_addr = MID_ADDR;
        dst_base_addr = DST_ADDR;
        saw_merge_done  = 1'b0;
        saw_stage5_done = 1'b0;
        start_cycle = 0;
        done_cycle  = 0;

        for (i = 0; i < MEM_BYTES; i = i + 1) mem.mem[i] = 8'hA5;

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

        expected_dst[0] = 8'h00; expected_dst[1] = 8'h0b; expected_dst[2] = 8'h01; expected_dst[3] = "a";
        expected_dst[4] = "n"; expected_dst[5] = "t"; expected_dst[6] = 8'h01; expected_dst[7] = 8'h64;
        expected_dst[8] = 8'h00; expected_dst[9] = 8'h00; expected_dst[10] = 8'h00; expected_dst[11] = 8'h00;
        expected_dst[12] = 8'h00; expected_dst[13] = 8'h00; expected_dst[14] = "A";
        expected_dst[15] = 8'h00; expected_dst[16] = 8'h0b; expected_dst[17] = 8'h01; expected_dst[18] = "b";
        expected_dst[19] = "e"; expected_dst[20] = "e"; expected_dst[21] = 8'h01; expected_dst[22] = 8'h6e;
        expected_dst[23] = 8'h00; expected_dst[24] = 8'h00; expected_dst[25] = 8'h00; expected_dst[26] = 8'h00;
        expected_dst[27] = 8'h00; expected_dst[28] = 8'h00; expected_dst[29] = "B";
        expected_dst[30] = 8'h00; expected_dst[31] = 8'h0b; expected_dst[32] = 8'h01; expected_dst[33] = "c";
        expected_dst[34] = "a"; expected_dst[35] = "t"; expected_dst[36] = 8'h01; expected_dst[37] = 8'h61;
        expected_dst[38] = 8'h00; expected_dst[39] = 8'h00; expected_dst[40] = 8'h00; expected_dst[41] = 8'h00;
        expected_dst[42] = 8'h00; expected_dst[43] = 8'h00; expected_dst[44] = "C";
        expected_dst[45] = 8'h00; expected_dst[46] = 8'h0b; expected_dst[47] = 8'h00; expected_dst[48] = "d";
        expected_dst[49] = "o"; expected_dst[50] = "g"; expected_dst[51] = 8'h00; expected_dst[52] = 8'h5a;
        expected_dst[53] = 8'h00; expected_dst[54] = 8'h00; expected_dst[55] = 8'h00; expected_dst[56] = 8'h00;
        expected_dst[57] = 8'h00; expected_dst[58] = 8'h00;
        expected_dst[59] = 8'h00; expected_dst[60] = 8'h0b; expected_dst[61] = 8'h01; expected_dst[62] = "e";
        expected_dst[63] = "e"; expected_dst[64] = "l"; expected_dst[65] = 8'h01; expected_dst[66] = 8'h50;
        expected_dst[67] = 8'h00; expected_dst[68] = 8'h00; expected_dst[69] = 8'h00; expected_dst[70] = 8'h00;
        expected_dst[71] = 8'h00; expected_dst[72] = 8'h00; expected_dst[73] = "E";
        expected_dst[74] = 8'h00; expected_dst[75] = 8'h0b; expected_dst[76] = 8'h01; expected_dst[77] = "y";
        expected_dst[78] = "a"; expected_dst[79] = "k"; expected_dst[80] = 8'h01; expected_dst[81] = 8'h32;
        expected_dst[82] = 8'h00; expected_dst[83] = 8'h00; expected_dst[84] = 8'h00; expected_dst[85] = 8'h00;
        expected_dst[86] = 8'h00; expected_dst[87] = 8'h00; expected_dst[88] = "Y";
        expected_dst[89] = 8'h00; expected_dst[90] = 8'h00; expected_dst[91] = 8'h00; expected_dst[92] = 8'h00;
        expected_dst[93] = 8'h01; expected_dst[94] = 8'h00; expected_dst[95] = 8'h00; expected_dst[96] = 8'h00;

        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (3) @(posedge clk);

        @(negedge clk);
        start      = 1'b1;
        start_cycle = $time / 10;
        @(negedge clk);
        start = 1'b0;

        fork
            drive_source0();
            drive_source1();
        join_none

        for (i = 0; i < 12000; i = i + 1) begin
            @(posedge clk);
            if (done || error) begin
                done_cycle = $time / 10;
                i = 12000;
            end
        end

        if (!done && !error) begin
            $display("FAIL: timeout waiting for done");
            $finish_and_return(1);
        end

        @(posedge clk);

        if (error) begin
            $display("FAIL: error asserted");
            $finish_and_return(1);
        end
        if (!saw_merge_done) begin
            $display("FAIL: merge_done pulse was not observed");
            $finish_and_return(1);
        end
        if (!saw_stage5_done) begin
            $display("FAIL: stage5_done pulse was not observed");
            $finish_and_return(1);
        end

        if (merge_output_byte_count != 32'd71) begin
            $display("FAIL: merge_output_byte_count mismatch got=%0d exp=71 (key+val bytes only, no counted-stream header)", merge_output_byte_count);
            $finish_and_return(1);
        end
        if (merge_decoded_record_count != 32'd9) begin
            $display("FAIL: merge_decoded_record_count mismatch got=%0d exp=9", merge_decoded_record_count);
            $finish_and_return(1);
        end
        if (merge_merged_record_count != 32'd6) begin
            $display("FAIL: merge_merged_record_count mismatch got=%0d exp=6", merge_merged_record_count);
            $finish_and_return(1);
        end
        if (merge_dropped_superseded_count != 32'd3) begin
            $display("FAIL: merge_dropped_superseded_count mismatch got=%0d exp=3", merge_dropped_superseded_count);
            $finish_and_return(1);
        end
        if (merge_value_record_count != 32'd8) begin
            $display("FAIL: merge_value_record_count mismatch got=%0d exp=8", merge_value_record_count);
            $finish_and_return(1);
        end
        if (merge_delete_record_count != 32'd1) begin
            $display("FAIL: merge_delete_record_count mismatch got=%0d exp=1", merge_delete_record_count);
            $finish_and_return(1);
        end
        if (merge_user_key_bytes_total != 32'd27) begin
            $display("FAIL: merge_user_key_bytes_total mismatch got=%0d exp=27", merge_user_key_bytes_total);
            $finish_and_return(1);
        end
        if (merge_value_bytes_total != 32'd8) begin
            $display("FAIL: merge_value_bytes_total mismatch got=%0d exp=8", merge_value_bytes_total);
            $finish_and_return(1);
        end
        if (merge_last_user_key_len != 16'd3) begin
            $display("FAIL: merge_last_user_key_len mismatch got=%0d exp=3", merge_last_user_key_len);
            $finish_and_return(1);
        end
        if (merge_last_sequence != 56'd49) begin
            $display("FAIL: merge_last_sequence mismatch got=%0d exp=49", merge_last_sequence);
            $finish_and_return(1);
        end
        if (merge_last_value_type != 8'h01) begin
            $display("FAIL: merge_last_value_type mismatch got=%0h exp=01", merge_last_value_type);
            $finish_and_return(1);
        end

        if (stage5_bytes_written != 32'd97) begin
            $display("FAIL: stage5_bytes_written mismatch got=%0d exp=97", stage5_bytes_written);
            $finish_and_return(1);
        end
        if (stage5_beats_written != 32'd2) begin
            $display("FAIL: stage5_beats_written mismatch got=%0d exp=2", stage5_beats_written);
            $finish_and_return(1);
        end
        if (stage5_input_record_count != 32'd6) begin
            $display("FAIL: stage5_input_record_count mismatch got=%0d exp=6", stage5_input_record_count);
            $finish_and_return(1);
        end
        if (stage5_encoded_entry_count != 32'd6) begin
            $display("FAIL: stage5_encoded_entry_count mismatch got=%0d exp=6", stage5_encoded_entry_count);
            $finish_and_return(1);
        end
        if (stage5_restart_count != 32'd1) begin
            $display("FAIL: stage5_restart_count mismatch got=%0d exp=1", stage5_restart_count);
            $finish_and_return(1);
        end
        if (stage5_output_block_bytes != 32'd97) begin
            $display("FAIL: stage5_output_block_bytes mismatch got=%0d exp=97", stage5_output_block_bytes);
            $finish_and_return(1);
        end

        if (merge_bytes_written != 32'd0) begin
            $display("FAIL: [bypass] merge_bytes_written should be 0, got=%0d", merge_bytes_written);
            $finish_and_return(1);
        end
        if (stage5_bytes_read != 32'd0) begin
            $display("FAIL: [bypass] stage5_bytes_read should be 0, got=%0d", stage5_bytes_read);
            $finish_and_return(1);
        end

        for (i = 0; i < MID_BYTES; i = i + 1) begin
            if (mem.mem[MID_ADDR + i] !== 8'hA5) begin
                $display("FAIL: [bypass] mid DDR was written (idx=%0d got=%02x), expected untouched 0xA5",
                         i, mem.mem[MID_ADDR + i]);
                $finish_and_return(1);
            end
        end

        for (i = 0; i < DST_BYTES; i = i + 1) begin
            if (mem.mem[DST_ADDR + i] !== expected_dst[i]) begin
                $display("FAIL: dst mismatch idx=%0d got=%02x exp=%02x",
                         i, mem.mem[DST_ADDR + i], expected_dst[i]);
                $finish_and_return(1);
            end
        end
        if (mem.mem[DST_ADDR + DST_BYTES] !== 8'hA5) begin
            $display("FAIL: dst tail byte modified unexpectedly got=%02x",
                     mem.mem[DST_ADDR + DST_BYTES]);
            $finish_and_return(1);
        end

        $display("PASS [v2-bypass] mid_ddr_untouched dst_bytes=%0d kept=%0d dropped=%0d cycles=%0d",
                 stage5_output_block_bytes,
                 merge_merged_record_count,
                 merge_dropped_superseded_count,
                 done_cycle - start_cycle);
        $finish;
    end

endmodule
