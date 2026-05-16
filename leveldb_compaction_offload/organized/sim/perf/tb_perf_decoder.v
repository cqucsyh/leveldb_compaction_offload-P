`timescale 1ns / 1ps

// Performance benchmark for block decoder pipeline.
// Measures total cycles from start to done for decoding a realistic LevelDB
// data block through stage4_real_data_block_record_emit_top.

module tb_perf_decoder;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer MEM_BYTES      = 4096;
    localparam integer BLOCK_BYTES     = 1555;
    localparam integer EXPECTED_ENTRIES = 20;
    localparam integer EXPECTED_RESTARTS = 2;
    localparam integer VALUE_SIZE       = 64;
    localparam integer EXPECTED_SHARED_TOTAL   = 197;
    localparam integer EXPECTED_UNSHARED_TOTAL = 203;
    localparam integer EXPECTED_VALUE_TOTAL    = 1280;
    localparam [63:0] SRC_ADDR = 64'h0000_0000_0000_0000;

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
    reg                         record_ready;
    wire [15:0]                 record_key_len;
    wire [15:0]                 record_value_len;
    wire [15:0]                 record_shared_bytes;
    wire [15:0]                 record_non_shared_bytes;
    wire [7:0]                  record_tdata;
    wire [0:0]                  record_tkeep;
    wire                        record_tlast;
    wire                        record_tvalid;
    reg                         record_tready;
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
    integer cycle_count;
    integer seen_records;
    integer seen_payload_bytes;

    stage4_real_data_block_record_emit_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(1),
        .MAX_BURST_LEN(16),
        .MAX_BLOCK_BYTES(4096),
        .MAX_KEY_BYTES(264)
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
        .record_ready(record_ready),
        .record_key_len(record_key_len),
        .record_value_len(record_value_len),
        .record_shared_bytes(record_shared_bytes),
        .record_non_shared_bytes(record_non_shared_bytes),
        .record_tdata(record_tdata),
        .record_tkeep(record_tkeep),
        .record_tlast(record_tlast),
        .record_tvalid(record_tvalid),
        .record_tready(record_tready),
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
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
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
        .s_axi_wstrb({(AXI_DATA_WIDTH/8){1'b0}}),
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
        byte_count = BLOCK_BYTES;
        record_ready = 1'b1;
        record_tready = 1'b1;
        seen_records = 0;
        seen_payload_bytes = 0;

        // Load fixture into RAM
        $readmemh("perf_block.hex", mem.mem);

        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (3) @(posedge clk);

        // Start and measure
        @(negedge clk);
        start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;

        cycle_count = 0;
        while (!done && !error && (cycle_count < 50000)) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;

            // Count records
            if (record_valid) begin
                seen_records = seen_records + 1;
            end
            if (record_tvalid && record_tready) begin
                seen_payload_bytes = seen_payload_bytes + 1;
            end
        end

        $display("========== PERFORMANCE RESULTS ==========");
        $display("Total cycles (start to done): %0d", cycle_count);
        $display("Block size: %0d bytes", BLOCK_BYTES);
        $display("Decoded entries: %0d (expected %0d)", decoded_entry_count, EXPECTED_ENTRIES);
        $display("Restart count: %0d (expected %0d)", restart_count, EXPECTED_RESTARTS);
        $display("Shared key bytes: %0d (expected %0d)", shared_key_bytes_total, EXPECTED_SHARED_TOTAL);
        $display("Unshared key bytes: %0d (expected %0d)", unshared_key_bytes_total, EXPECTED_UNSHARED_TOTAL);
        $display("Value bytes: %0d (expected %0d)", value_bytes_total, EXPECTED_VALUE_TOTAL);
        $display("Seen records: %0d", seen_records);
        $display("Seen payload bytes: %0d", seen_payload_bytes);
        $display("Throughput: %0d bytes/cycle (block_size/cycles)", BLOCK_BYTES);
        $display("=========================================");

        if (error) begin
            $display("FAIL: error flag set");
            $finish_and_return(1);
        end
        if (cycle_count >= 50000) begin
            $display("FAIL: timeout");
            $finish_and_return(1);
        end
        if (decoded_entry_count !== EXPECTED_ENTRIES) begin
            $display("FAIL: entry count mismatch");
            $finish_and_return(1);
        end
        if (shared_key_bytes_total !== EXPECTED_SHARED_TOTAL) begin
            $display("FAIL: shared bytes mismatch");
            $finish_and_return(1);
        end
        if (unshared_key_bytes_total !== EXPECTED_UNSHARED_TOTAL) begin
            $display("FAIL: unshared bytes mismatch");
            $finish_and_return(1);
        end
        if (value_bytes_total !== EXPECTED_VALUE_TOTAL) begin
            $display("FAIL: value bytes mismatch");
            $finish_and_return(1);
        end

        $display("PASS: decoder performance benchmark");
        $finish_and_return(0);
    end
endmodule
