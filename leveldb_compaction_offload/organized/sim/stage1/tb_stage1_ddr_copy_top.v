`timescale 1ns / 1ps

module tb_stage1_ddr_copy_top;

    localparam integer AXI_ADDR_WIDTH = 64;
    localparam integer AXI_DATA_WIDTH = 512;
    localparam integer AXI_ID_WIDTH   = 1;
    localparam integer MEM_BYTES      = 65536;
    localparam [63:0] SRC_ADDR        = 64'h0000_0000_0000_0400;
    localparam [63:0] DST_ADDR        = 64'h0000_0000_0000_2000;
    localparam integer BYTE_COUNT     = 4096;
    localparam integer AXI_BEAT_BYTES = AXI_DATA_WIDTH / 8;
    localparam integer TOTAL_BEATS    = (BYTE_COUNT + AXI_BEAT_BYTES - 1) / AXI_BEAT_BYTES;

    reg clk;
    reg rstn;
    reg clear;
    reg start;

    wire busy;
    wire done;
    wire error;
    wire [31:0] bytes_read;
    wire [31:0] bytes_written;
    wire [31:0] beats_read;
    wire [31:0] beats_written;
    wire [$clog2(32+1)-1:0] fifo_occupancy;

    wire [AXI_ADDR_WIDTH-1:0] m_axi_araddr;
    wire [7:0]                m_axi_arlen;
    wire [2:0]                m_axi_arsize;
    wire [1:0]                m_axi_arburst;
    wire [AXI_ID_WIDTH-1:0]   m_axi_arid;
    wire                      m_axi_arvalid;
    wire                      m_axi_arready;
    wire [AXI_DATA_WIDTH-1:0] m_axi_rdata;
    wire [1:0]                m_axi_rresp;
    wire                      m_axi_rlast;
    wire [AXI_ID_WIDTH-1:0]   m_axi_rid;
    wire                      m_axi_rvalid;
    wire                      m_axi_rready;

    wire [AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
    wire [7:0]                m_axi_awlen;
    wire [2:0]                m_axi_awsize;
    wire [1:0]                m_axi_awburst;
    wire [AXI_ID_WIDTH-1:0]   m_axi_awid;
    wire                      m_axi_awvalid;
    wire                      m_axi_awready;
    wire [AXI_DATA_WIDTH-1:0] m_axi_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb;
    wire                      m_axi_wlast;
    wire                      m_axi_wvalid;
    wire                      m_axi_wready;
    wire [1:0]                m_axi_bresp;
    wire [AXI_ID_WIDTH-1:0]   m_axi_bid;
    wire                      m_axi_bvalid;
    wire                      m_axi_bready;

    integer i;
    integer burst_read_hits;
    integer burst_write_hits;
    integer cycles_start;
    integer cycles_done;
    integer bytes_per_cycle_times_100;

    stage1_ddr_copy_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(16),
        .FIFO_DEPTH(32)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .src_base_addr(SRC_ADDR),
        .dst_base_addr(DST_ADDR),
        .byte_count(BYTE_COUNT),
        .busy(busy),
        .done(done),
        .error(error),
        .bytes_read(bytes_read),
        .bytes_written(bytes_written),
        .beats_read(beats_read),
        .beats_written(beats_written),
        .fifo_occupancy(fifo_occupancy),
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
        .READ_LATENCY(2)
    ) mem (
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

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (m_axi_arvalid && m_axi_arready && (m_axi_arlen != 8'd0)) begin
            burst_read_hits <= burst_read_hits + 1;
        end
        if (m_axi_awvalid && m_axi_awready && (m_axi_awlen != 8'd0)) begin
            burst_write_hits <= burst_write_hits + 1;
        end
    end

    initial begin
        clk = 1'b0;
        rstn = 1'b0;
        clear = 1'b0;
        start = 1'b0;
        burst_read_hits = 0;
        burst_write_hits = 0;
        cycles_start = 0;
        cycles_done = 0;

        for (i = 0; i < MEM_BYTES; i = i + 1) begin
            mem.mem[i] = 8'h00;
        end

        for (i = 0; i < BYTE_COUNT; i = i + 1) begin
            mem.mem[SRC_ADDR + i] = (i * 7 + 8'h3d) & 8'hff;
        end

        repeat (8) @(posedge clk);
        rstn = 1'b1;
        repeat (4) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        cycles_start = 0;
        @(negedge clk);
        start = 1'b0;

        while (!done) begin
            @(posedge clk);
            cycles_start = cycles_start + 1;
            if (cycles_start > 5000) begin
                $display("TIMEOUT busy=%0d done=%0d error=%0d fifo_occ=%0d bytes_read=%0d bytes_written=%0d beats_read=%0d beats_written=%0d rd_state_busy=%0d rd_wait=%0d rd_beats_rem=%0d wr_state=%0d wr_beats_rem=%0d wr_burst_idx=%0d arv=%0d arr=%0d rv=%0d rr=%0d awv=%0d awr=%0d wv=%0d wr=%0d bv=%0d br=%0d",
                    busy,
                    done,
                    error,
                    fifo_occupancy,
                    bytes_read,
                    bytes_written,
                    beats_read,
                    beats_written,
                    dut.u_axi_read_engine.busy,
                    dut.u_axi_read_engine.waiting_for_r,
                    dut.u_axi_read_engine.beats_remaining,
                    dut.u_axi_write_engine.state,
                    dut.u_axi_write_engine.beats_remaining,
                    dut.u_axi_write_engine.burst_index,
                    m_axi_arvalid,
                    m_axi_arready,
                    m_axi_rvalid,
                    m_axi_rready,
                    m_axi_awvalid,
                    m_axi_awready,
                    m_axi_wvalid,
                    m_axi_wready,
                    m_axi_bvalid,
                    m_axi_bready);
                $finish_and_return(1);
            end
        end
        cycles_done = cycles_start;

        if (error) begin
            $display("ERROR flag asserted");
            $finish_and_return(1);
        end

        if (bytes_read != BYTE_COUNT) begin
            $display("bytes_read mismatch: %0d expected %0d", bytes_read, BYTE_COUNT);
            $finish_and_return(1);
        end

        if (bytes_written != BYTE_COUNT) begin
            $display("bytes_written mismatch: %0d expected %0d", bytes_written, BYTE_COUNT);
            $finish_and_return(1);
        end

        if (beats_read != TOTAL_BEATS) begin
            $display("beats_read mismatch: %0d expected %0d", beats_read, TOTAL_BEATS);
            $finish_and_return(1);
        end

        if (beats_written != TOTAL_BEATS) begin
            $display("beats_written mismatch: %0d expected %0d", beats_written, TOTAL_BEATS);
            $finish_and_return(1);
        end

        for (i = 0; i < BYTE_COUNT; i = i + 1) begin
            if (mem.mem[DST_ADDR + i] !== mem.mem[SRC_ADDR + i]) begin
                $display("COPY mismatch at byte %0d src=%02x dst=%02x", i, mem.mem[SRC_ADDR + i], mem.mem[DST_ADDR + i]);
                $finish_and_return(1);
            end
        end

        if (burst_read_hits == 0) begin
            $display("No multi-beat read burst observed");
            $finish_and_return(1);
        end

        if (burst_write_hits == 0) begin
            $display("No multi-beat write burst observed");
            $finish_and_return(1);
        end

        bytes_per_cycle_times_100 = (BYTE_COUNT * 100) / cycles_done;
        $display("PASS stage1 copy: cycles=%0d bytes_per_cycle_x100=%0d burst_reads=%0d burst_writes=%0d", cycles_done, bytes_per_cycle_times_100, burst_read_hits, burst_write_hits);
        $finish;
    end

endmodule
