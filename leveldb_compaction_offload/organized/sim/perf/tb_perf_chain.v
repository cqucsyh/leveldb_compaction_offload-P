`timescale 1ns / 1ps

// Full-chain performance benchmark:
// source0 DDR -> decoder -> merger -> encoder -> writer -> DST DDR
// Uses stage4_real_internal_key_two_way_merge_stage5_chain_top from cmpct_pair_engine.v.

module tb_perf_chain;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer MEM_BYTES      = 65536;
    localparam integer MERGE_MAX_USER_KEY_BYTES = 256;
    localparam integer STAGE5_MAX_KEY_BYTES     = 256;

    localparam integer BLOCK0_BYTES = 1555;
    localparam integer BLOCK1_BYTES = 1557;

    localparam [63:0] SRC0_ADDR = 64'h0000_0000_0000_0000;
    localparam [63:0] SRC1_ADDR = 64'h0000_0000_0000_0000;
    localparam [63:0] MID_ADDR  = 64'h0000_0000_0000_0000;
    localparam [63:0] DST_ADDR  = 64'h0000_0000_0000_8000;

    reg                         clk;
    reg                         rstn;
    reg                         clear;
    reg                         start;

    reg  [AXI_ADDR_WIDTH-1:0]   src0_base_addr;
    reg  [31:0]                 src0_byte_count;
    reg  [AXI_ADDR_WIDTH-1:0]   src1_base_addr;
    reg  [31:0]                 src1_byte_count;
    reg  [AXI_ADDR_WIDTH-1:0]   mid_base_addr;
    reg  [AXI_ADDR_WIDTH-1:0]   dst_base_addr;

    wire                        busy;
    wire                        done;
    wire                        error;
    wire [31:0]                 merge_decoded_record_count;
    wire [31:0]                 merge_merged_record_count;
    wire [31:0]                 merge_dropped_superseded_count;
    wire [31:0]                 stage5_input_record_count;
    wire [31:0]                 stage5_encoded_entry_count;
    wire [31:0]                 stage5_bytes_written;
    wire [31:0]                 stage5_output_block_bytes;
    wire [31:0]                 source0_decoded_entry_count;
    wire [31:0]                 source1_decoded_entry_count;

    // AXI src0
    wire [AXI_ADDR_WIDTH-1:0]   m_axi_src0_araddr;
    wire [7:0]                  m_axi_src0_arlen;
    wire [2:0]                  m_axi_src0_arsize;
    wire [1:0]                  m_axi_src0_arburst;
    wire                        m_axi_src0_arvalid;
    wire                        m_axi_src0_arready;
    wire [AXI_DATA_WIDTH-1:0]   m_axi_src0_rdata;
    wire [1:0]                  m_axi_src0_rresp;
    wire                        m_axi_src0_rlast;
    wire                        m_axi_src0_rvalid;
    wire                        m_axi_src0_rready;
    // AXI src1
    wire [AXI_ADDR_WIDTH-1:0]   m_axi_src1_araddr;
    wire [7:0]                  m_axi_src1_arlen;
    wire [2:0]                  m_axi_src1_arsize;
    wire [1:0]                  m_axi_src1_arburst;
    wire                        m_axi_src1_arvalid;
    wire                        m_axi_src1_arready;
    wire [AXI_DATA_WIDTH-1:0]   m_axi_src1_rdata;
    wire [1:0]                  m_axi_src1_rresp;
    wire                        m_axi_src1_rlast;
    wire                        m_axi_src1_rvalid;
    wire                        m_axi_src1_rready;
    // AXI chain (read+write)
    wire [AXI_ADDR_WIDTH-1:0]   m_axi_chain_araddr;
    wire [7:0]                  m_axi_chain_arlen;
    wire [2:0]                  m_axi_chain_arsize;
    wire [1:0]                  m_axi_chain_arburst;
    wire                        m_axi_chain_arvalid;
    wire                        m_axi_chain_arready;
    wire [AXI_DATA_WIDTH-1:0]   m_axi_chain_rdata;
    wire [1:0]                  m_axi_chain_rresp;
    wire                        m_axi_chain_rlast;
    wire                        m_axi_chain_rvalid;
    wire                        m_axi_chain_rready;
    wire [AXI_ADDR_WIDTH-1:0]   m_axi_chain_awaddr;
    wire [7:0]                  m_axi_chain_awlen;
    wire [2:0]                  m_axi_chain_awsize;
    wire [1:0]                  m_axi_chain_awburst;
    wire                        m_axi_chain_awvalid;
    wire                        m_axi_chain_awready;
    wire [AXI_DATA_WIDTH-1:0]   m_axi_chain_wdata;
    wire [AXI_DATA_WIDTH/8-1:0] m_axi_chain_wstrb;
    wire                        m_axi_chain_wlast;
    wire                        m_axi_chain_wvalid;
    wire                        m_axi_chain_wready;
    wire [1:0]                  m_axi_chain_bresp;
    wire                        m_axi_chain_bvalid;
    wire                        m_axi_chain_bready;

    integer i, cycle_count;

    stage4_real_internal_key_two_way_merge_stage5_chain_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MAX_BURST_LEN(16),
        .STAGE4_MAX_BLOCK_BYTES(4096),
        .STAGE4_MAX_KEY_BYTES(264),
        .MERGE_MAX_USER_KEY_BYTES(MERGE_MAX_USER_KEY_BYTES),
        .MERGE_MAX_KEY_BYTES(264),
        .MERGE_MAX_VALUE_BYTES(1024),
        .MERGE_MAX_RECORD_BYTES(2048),
        .MERGE_MAX_RECORDS(256),
        .MERGE_MAX_OUTPUT_BYTES(8192),
        .STAGE5_MAX_RECORDS(256),
        .STAGE5_MAX_PAYLOAD_BYTES(8192),
        .STAGE5_MAX_BLOCK_BYTES(8192),
        .STAGE5_MAX_KEY_BYTES(STAGE5_MAX_KEY_BYTES),
        .STAGE5_MAX_VALUE_BYTES(1024),
        .STAGE5_RESTART_INTERVAL(16)
    ) dut (
        .clk(clk), .rstn(rstn), .clear(clear), .start(start),
        .seed_prev_user_key_valid(1'b0),
        .seed_prev_user_key_len(16'd0),
        .seed_prev_user_key({(MERGE_MAX_USER_KEY_BYTES*8){1'b0}}),
        .src0_base_addr(src0_base_addr), .src0_byte_count(src0_byte_count),
        .src1_base_addr(src1_base_addr), .src1_byte_count(src1_byte_count),
        .mid_base_addr(mid_base_addr),   .dst_base_addr(dst_base_addr),
        .busy(busy), .done(done), .error(error),
        .source0_decoded_entry_count(source0_decoded_entry_count),
        .source0_restart_count(),
        .source0_restart_entry_count(),
        .source0_shared_key_bytes_total(),
        .source0_unshared_key_bytes_total(),
        .source0_value_bytes_total(),
        .source0_last_key_len(),
        .source0_last_value_len(),
        .source0_last_shared_bytes(),
        .source0_last_non_shared_bytes(),
        .source0_restart_array_offset(),
        .source0_bytes_read(),
        .source0_beats_read(),
        .source1_decoded_entry_count(source1_decoded_entry_count),
        .source1_restart_count(),
        .source1_restart_entry_count(),
        .source1_shared_key_bytes_total(),
        .source1_unshared_key_bytes_total(),
        .source1_value_bytes_total(),
        .source1_last_key_len(),
        .source1_last_value_len(),
        .source1_last_shared_bytes(),
        .source1_last_non_shared_bytes(),
        .source1_restart_array_offset(),
        .source1_bytes_read(),
        .source1_beats_read(),
        .merge_bytes_written(),
        .merge_beats_written(),
        .merge_output_byte_count(),
        .merge_decoded_record_count(merge_decoded_record_count),
        .merge_merged_record_count(merge_merged_record_count),
        .merge_dropped_superseded_count(merge_dropped_superseded_count),
        .merge_value_record_count(),
        .merge_delete_record_count(),
        .merge_user_key_bytes_total(),
        .merge_value_bytes_total(),
        .merge_last_user_key_len(),
        .merge_last_sequence(),
        .merge_last_value_type(),
        .merge_last_record_keep(),
        .stage5_bytes_read(),
        .stage5_beats_read(),
        .stage5_bytes_written(stage5_bytes_written),
        .stage5_beats_written(),
        .stage5_input_record_count(stage5_input_record_count),
        .stage5_encoded_entry_count(stage5_encoded_entry_count),
        .stage5_restart_count(),
        .stage5_shared_key_bytes_total(),
        .stage5_unshared_key_bytes_total(),
        .stage5_value_bytes_total(),
        .stage5_last_key_len(),
        .stage5_last_key_bytes(),
        .stage5_last_value_len(),
        .stage5_last_shared_bytes(),
        .stage5_last_non_shared_bytes(),
        .stage5_output_block_bytes(stage5_output_block_bytes),
        .final_prev_user_key_valid(),
        .final_prev_user_key_len(),
        .final_prev_user_key(),
        .m_axi_src0_araddr(m_axi_src0_araddr),
        .m_axi_src0_arlen(m_axi_src0_arlen),
        .m_axi_src0_arsize(m_axi_src0_arsize),
        .m_axi_src0_arburst(m_axi_src0_arburst),
        .m_axi_src0_arvalid(m_axi_src0_arvalid),
        .m_axi_src0_arready(m_axi_src0_arready),
        .m_axi_src0_rdata(m_axi_src0_rdata),
        .m_axi_src0_rresp(m_axi_src0_rresp),
        .m_axi_src0_rlast(m_axi_src0_rlast),
        .m_axi_src0_rvalid(m_axi_src0_rvalid),
        .m_axi_src0_rready(m_axi_src0_rready),
        .m_axi_src1_araddr(m_axi_src1_araddr),
        .m_axi_src1_arlen(m_axi_src1_arlen),
        .m_axi_src1_arsize(m_axi_src1_arsize),
        .m_axi_src1_arburst(m_axi_src1_arburst),
        .m_axi_src1_arvalid(m_axi_src1_arvalid),
        .m_axi_src1_arready(m_axi_src1_arready),
        .m_axi_src1_rdata(m_axi_src1_rdata),
        .m_axi_src1_rresp(m_axi_src1_rresp),
        .m_axi_src1_rlast(m_axi_src1_rlast),
        .m_axi_src1_rvalid(m_axi_src1_rvalid),
        .m_axi_src1_rready(m_axi_src1_rready),
        .m_axi_chain_araddr(m_axi_chain_araddr),
        .m_axi_chain_arlen(m_axi_chain_arlen),
        .m_axi_chain_arsize(m_axi_chain_arsize),
        .m_axi_chain_arburst(m_axi_chain_arburst),
        .m_axi_chain_arvalid(m_axi_chain_arvalid),
        .m_axi_chain_arready(m_axi_chain_arready),
        .m_axi_chain_rdata(m_axi_chain_rdata),
        .m_axi_chain_rresp(m_axi_chain_rresp),
        .m_axi_chain_rlast(m_axi_chain_rlast),
        .m_axi_chain_rvalid(m_axi_chain_rvalid),
        .m_axi_chain_rready(m_axi_chain_rready),
        .m_axi_chain_awaddr(m_axi_chain_awaddr),
        .m_axi_chain_awlen(m_axi_chain_awlen),
        .m_axi_chain_awsize(m_axi_chain_awsize),
        .m_axi_chain_awburst(m_axi_chain_awburst),
        .m_axi_chain_awvalid(m_axi_chain_awvalid),
        .m_axi_chain_awready(m_axi_chain_awready),
        .m_axi_chain_wdata(m_axi_chain_wdata),
        .m_axi_chain_wstrb(m_axi_chain_wstrb),
        .m_axi_chain_wlast(m_axi_chain_wlast),
        .m_axi_chain_wvalid(m_axi_chain_wvalid),
        .m_axi_chain_wready(m_axi_chain_wready),
        .m_axi_chain_bresp(m_axi_chain_bresp),
        .m_axi_chain_bvalid(m_axi_chain_bvalid),
        .m_axi_chain_bready(m_axi_chain_bready)
    );

    // Separate AXI RAMs for src0, src1, chain(write)
    axi_ram_model #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1), .MEM_BYTES(MEM_BYTES), .READ_LATENCY(2)
    ) mem_src0 (
        .clk(clk), .rstn(rstn),
        .s_axi_araddr(m_axi_src0_araddr), .s_axi_arlen(m_axi_src0_arlen),
        .s_axi_arsize(m_axi_src0_arsize), .s_axi_arburst(m_axi_src0_arburst),
        .s_axi_arid(1'b0), .s_axi_arvalid(m_axi_src0_arvalid),
        .s_axi_arready(m_axi_src0_arready),
        .s_axi_rdata(m_axi_src0_rdata), .s_axi_rresp(m_axi_src0_rresp),
        .s_axi_rlast(m_axi_src0_rlast), .s_axi_rid(),
        .s_axi_rvalid(m_axi_src0_rvalid), .s_axi_rready(m_axi_src0_rready),
        .s_axi_awaddr(64'd0), .s_axi_awlen(8'd0), .s_axi_awsize(3'd0),
        .s_axi_awburst(2'd0), .s_axi_awid(1'b0), .s_axi_awvalid(1'b0),
        .s_axi_awready(), .s_axi_wdata({AXI_DATA_WIDTH{1'b0}}),
        .s_axi_wstrb({(AXI_DATA_WIDTH/8){1'b0}}), .s_axi_wlast(1'b0),
        .s_axi_wvalid(1'b0), .s_axi_wready(),
        .s_axi_bresp(), .s_axi_bid(), .s_axi_bvalid(), .s_axi_bready(1'b0)
    );

    axi_ram_model #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1), .MEM_BYTES(MEM_BYTES), .READ_LATENCY(2)
    ) mem_src1 (
        .clk(clk), .rstn(rstn),
        .s_axi_araddr(m_axi_src1_araddr), .s_axi_arlen(m_axi_src1_arlen),
        .s_axi_arsize(m_axi_src1_arsize), .s_axi_arburst(m_axi_src1_arburst),
        .s_axi_arid(1'b0), .s_axi_arvalid(m_axi_src1_arvalid),
        .s_axi_arready(m_axi_src1_arready),
        .s_axi_rdata(m_axi_src1_rdata), .s_axi_rresp(m_axi_src1_rresp),
        .s_axi_rlast(m_axi_src1_rlast), .s_axi_rid(),
        .s_axi_rvalid(m_axi_src1_rvalid), .s_axi_rready(m_axi_src1_rready),
        .s_axi_awaddr(64'd0), .s_axi_awlen(8'd0), .s_axi_awsize(3'd0),
        .s_axi_awburst(2'd0), .s_axi_awid(1'b0), .s_axi_awvalid(1'b0),
        .s_axi_awready(), .s_axi_wdata({AXI_DATA_WIDTH{1'b0}}),
        .s_axi_wstrb({(AXI_DATA_WIDTH/8){1'b0}}), .s_axi_wlast(1'b0),
        .s_axi_wvalid(1'b0), .s_axi_wready(),
        .s_axi_bresp(), .s_axi_bid(), .s_axi_bvalid(), .s_axi_bready(1'b0)
    );

    axi_ram_model #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1), .MEM_BYTES(MEM_BYTES), .READ_LATENCY(2)
    ) mem_chain (
        .clk(clk), .rstn(rstn),
        .s_axi_araddr(m_axi_chain_araddr), .s_axi_arlen(m_axi_chain_arlen),
        .s_axi_arsize(m_axi_chain_arsize), .s_axi_arburst(m_axi_chain_arburst),
        .s_axi_arid(1'b0), .s_axi_arvalid(m_axi_chain_arvalid),
        .s_axi_arready(m_axi_chain_arready),
        .s_axi_rdata(m_axi_chain_rdata), .s_axi_rresp(m_axi_chain_rresp),
        .s_axi_rlast(m_axi_chain_rlast), .s_axi_rid(),
        .s_axi_rvalid(m_axi_chain_rvalid), .s_axi_rready(m_axi_chain_rready),
        .s_axi_awaddr(m_axi_chain_awaddr), .s_axi_awlen(m_axi_chain_awlen),
        .s_axi_awsize(m_axi_chain_awsize), .s_axi_awburst(m_axi_chain_awburst),
        .s_axi_awid(1'b0), .s_axi_awvalid(m_axi_chain_awvalid),
        .s_axi_awready(m_axi_chain_awready),
        .s_axi_wdata(m_axi_chain_wdata), .s_axi_wstrb(m_axi_chain_wstrb),
        .s_axi_wlast(m_axi_chain_wlast), .s_axi_wvalid(m_axi_chain_wvalid),
        .s_axi_wready(m_axi_chain_wready),
        .s_axi_bresp(m_axi_chain_bresp), .s_axi_bid(),
        .s_axi_bvalid(m_axi_chain_bvalid), .s_axi_bready(m_axi_chain_bready)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0; rstn = 1'b0; clear = 1'b0; start = 1'b0;
        src0_base_addr = SRC0_ADDR;
        src0_byte_count = BLOCK0_BYTES;
        src1_base_addr = SRC1_ADDR;
        src1_byte_count = BLOCK1_BYTES;
        mid_base_addr  = MID_ADDR;
        dst_base_addr  = DST_ADDR;

        for (i = 0; i < MEM_BYTES; i = i + 1) begin
            mem_src0.mem[i] = 8'hA5;
            mem_src1.mem[i] = 8'hA5;
            mem_chain.mem[i] = 8'hA5;
        end

        $readmemh("perf_block.hex", mem_src0.mem);
        $readmemh("perf_block_src1.hex", mem_src1.mem);

        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;

        cycle_count = 0;
        while (!done && !error && (cycle_count < 100000)) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;
        end

        $display("========== FULL CHAIN PERFORMANCE ==========");
        $display("Total cycles: %0d", cycle_count);
        $display("Source0 entries decoded: %0d", source0_decoded_entry_count);
        $display("Source1 entries decoded: %0d", source1_decoded_entry_count);
        $display("Merge decoded: %0d  merged: %0d  dropped: %0d",
                 merge_decoded_record_count, merge_merged_record_count, merge_dropped_superseded_count);
        $display("Stage5 input: %0d  encoded: %0d  output_bytes: %0d  written: %0d",
                 stage5_input_record_count, stage5_encoded_entry_count,
                 stage5_output_block_bytes, stage5_bytes_written);
        $display("Source data: %0d + %0d = %0d bytes",
                 BLOCK0_BYTES, BLOCK1_BYTES, BLOCK0_BYTES + BLOCK1_BYTES);
        $display("=============================================");

        if (error) begin
            $display("FAIL: error flag set");
            $finish_and_return(1);
        end
        if (cycle_count >= 100000) begin
            $display("FAIL: timeout");
            $finish_and_return(1);
        end
        if (source0_decoded_entry_count !== 32'd20) begin
            $display("FAIL: src0 decode count mismatch got=%0d", source0_decoded_entry_count);
            $finish_and_return(1);
        end
        if (source1_decoded_entry_count !== 32'd20) begin
            $display("FAIL: src1 decode count mismatch got=%0d", source1_decoded_entry_count);
            $finish_and_return(1);
        end
        if (merge_merged_record_count !== 32'd40) begin
            $display("FAIL: merged count mismatch got=%0d", merge_merged_record_count);
            $finish_and_return(1);
        end

        $display("PASS: full chain benchmark");
        $finish_and_return(0);
    end
endmodule
