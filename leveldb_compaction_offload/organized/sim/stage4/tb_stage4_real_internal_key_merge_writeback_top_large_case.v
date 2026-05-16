`timescale 1ns / 1ps

module tb_stage4_real_internal_key_merge_writeback_top_large_case;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer MEM_BYTES      = 16384;
    localparam integer SRC_BYTES      = 3493;
    localparam integer EXPECTED_BYTES = 2219;
    localparam [63:0] SRC_ADDR        = 64'h0000_0000_0000_0000;
    localparam [63:0] DST_ADDR        = 64'h0000_0000_0000_1000;

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

    reg [7:0] src_image [0:SRC_BYTES-1];
    reg [7:0] expected_image [0:EXPECTED_BYTES-1];

    integer i;
    integer fd;
    integer rc;
    integer mismatch_count;

    stage4_real_internal_key_merge_writeback_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MAX_BURST_LEN(16),
        .MAX_BLOCK_BYTES(4096),
        .MAX_KEY_BYTES(264),
        .MAX_USER_KEY_BYTES(256),
        .MAX_VALUE_BYTES(1024),
        .MAX_RECORD_BYTES(2048),
        .MAX_RECORDS(256),
        .MAX_OUTPUT_BYTES(73728)
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
        dst_base_addr = DST_ADDR;
        mismatch_count = 0;

        for (i = 0; i < MEM_BYTES; i = i + 1) begin
            mem.mem[i] = 8'hA5;
        end

        fd = $fopen("/home/yh/pp4/leveldb_compaction_offload/tmp_large_case/src_block.bin", "rb");
        if (fd == 0) begin
            $display("failed to open src_block.bin");
            $finish_and_return(1);
        end
        rc = $fread(src_image, fd);
        $fclose(fd);
        if (rc != SRC_BYTES) begin
            $display("src fread mismatch rc=%0d exp=%0d", rc, SRC_BYTES);
            $finish_and_return(1);
        end

        fd = $fopen("/home/yh/pp4/leveldb_compaction_offload/tmp_large_case/expected_mid.bin", "rb");
        if (fd == 0) begin
            $display("failed to open expected_mid.bin");
            $finish_and_return(1);
        end
        rc = $fread(expected_image, fd);
        $fclose(fd);
        if (rc != EXPECTED_BYTES) begin
            $display("expected fread mismatch rc=%0d exp=%0d", rc, EXPECTED_BYTES);
            $finish_and_return(1);
        end

        for (i = 0; i < SRC_BYTES; i = i + 1) begin
            mem.mem[SRC_ADDR + i] = src_image[i];
        end

        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (3) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        for (i = 0; i < 200000; i = i + 1) begin
            @(posedge clk);
            if (done || error) begin
                i = 200000;
            end
        end

        if (error) begin
            $display("DUT reported error");
            $finish_and_return(1);
        end
        if (!done) begin
            $display("timeout waiting for done");
            $finish_and_return(1);
        end

        if (output_byte_count != EXPECTED_BYTES) begin
            $display("output_byte_count mismatch got=%0d exp=%0d", output_byte_count, EXPECTED_BYTES);
            $finish_and_return(1);
        end
        if (bytes_written != EXPECTED_BYTES) begin
            $display("bytes_written mismatch got=%0d exp=%0d", bytes_written, EXPECTED_BYTES);
            $finish_and_return(1);
        end

        for (i = 0; i < EXPECTED_BYTES; i = i + 1) begin
            if (mem.mem[DST_ADDR + i] !== expected_image[i]) begin
                if (mismatch_count < 16) begin
                    $display("mismatch idx=%0d got=%02x exp=%02x", i, mem.mem[DST_ADDR + i], expected_image[i]);
                end
                mismatch_count = mismatch_count + 1;
            end
        end

        if (mismatch_count != 0) begin
            $display("FAIL mismatch_count=%0d", mismatch_count);
            $finish_and_return(1);
        end

        if (mem.mem[DST_ADDR + EXPECTED_BYTES] !== 8'hA5) begin
            $display("tail byte modified got=%02x", mem.mem[DST_ADDR + EXPECTED_BYTES]);
            $finish_and_return(1);
        end

        $display("PASS large-case writeback sim bytes=%0d beats_written=%0d decoded=%0d kept=%0d dropped=%0d",
                 bytes_written, beats_written, stage4_decoded_entry_count, merge_merged_record_count, merge_dropped_superseded_count);
        $finish;
    end

endmodule
