`timescale 1ns / 1ps
module tb_p6_stress_bench;
    localparam integer MAX_BLOCK_BYTES = 16384;
    localparam integer MAX_KEY_BYTES   = 264;
    localparam integer BLOCK_BYTES     = 8693;
    reg         clk, rstn, clear, start;
    reg  [31:0] block_byte_count;
    reg  [5:0]  cap_align_offset;
    reg  [63:0] s_axis_tdata;
    reg  [7:0]  s_axis_tkeep;
    reg         s_axis_tlast, s_axis_tvalid;
    wire        s_axis_tready, busy, done, error, record_valid;
    reg         record_ready;
    wire [15:0] record_key_len, record_value_len, record_shared_bytes, record_non_shared_bytes;
    wire [63:0] m_axis_tdata;
    wire [7:0]  m_axis_tkeep;
    wire        m_axis_tlast, m_axis_tvalid;
    reg         m_axis_tready;
    wire [31:0] decoded_entry_count, restart_count, restart_entry_count;
    wire [31:0] shared_key_bytes_total, unshared_key_bytes_total, value_bytes_total;
    wire [15:0] last_key_len, last_value_len, last_shared_bytes, last_non_shared_bytes;
    wire [31:0] restart_array_offset;
    reg [7:0] block_data [0:MAX_BLOCK_BYTES-1];
    integer feed_idx;
    cmpct_block_decoder #(.MAX_BLOCK_BYTES(MAX_BLOCK_BYTES),.MAX_KEY_BYTES(MAX_KEY_BYTES)) dut (
        .clk(clk),.rstn(rstn),.clear(clear),.start(start),
        .block_byte_count(block_byte_count),.cap_align_offset(cap_align_offset),
        .s_axis_tdata(s_axis_tdata),.s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),.s_axis_tvalid(s_axis_tvalid),.s_axis_tready(s_axis_tready),
        .busy(busy),.done(done),.error(error),
        .record_valid(record_valid),.record_ready(record_ready),
        .record_key_len(record_key_len),.record_value_len(record_value_len),
        .record_shared_bytes(record_shared_bytes),.record_non_shared_bytes(record_non_shared_bytes),
        .m_axis_tdata(m_axis_tdata),.m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast),.m_axis_tvalid(m_axis_tvalid),.m_axis_tready(m_axis_tready),
        .decoded_entry_count(decoded_entry_count),.restart_count(restart_count),
        .restart_entry_count(restart_entry_count),
        .shared_key_bytes_total(shared_key_bytes_total),
        .unshared_key_bytes_total(unshared_key_bytes_total),
        .value_bytes_total(value_bytes_total),
        .last_key_len(last_key_len),.last_value_len(last_value_len),
        .last_shared_bytes(last_shared_bytes),.last_non_shared_bytes(last_non_shared_bytes),
        .restart_array_offset(restart_array_offset)
    );
    always #5 clk = ~clk;
    task run_decode(input integer width_bytes, output integer cycles, output integer entries);
        integer i;
        begin
            @(posedge clk); clear <= 1; @(posedge clk); clear <= 0; @(posedge clk);
            block_byte_count <= BLOCK_BYTES; cap_align_offset <= 0;
            start <= 1; @(posedge clk); start <= 0;
            feed_idx = 0; cycles = 0; entries = 0;
            while (!done && !error && cycles < 500000) begin
                @(posedge clk); cycles = cycles + 1;
                if (record_valid && record_ready) entries = entries + 1;
                if (s_axis_tready && feed_idx < BLOCK_BYTES) begin
                    s_axis_tvalid <= 1; s_axis_tdata <= 64'd0; s_axis_tkeep <= 8'h00;
                    for (i = 0; i < width_bytes && (feed_idx+i) < BLOCK_BYTES; i = i+1) begin
                        s_axis_tdata[i*8 +: 8] <= block_data[feed_idx+i];
                        s_axis_tkeep[i] <= 1;
                    end
                    s_axis_tlast <= (feed_idx + width_bytes >= BLOCK_BYTES) ? 1 : 0;
                    feed_idx = feed_idx + width_bytes;
                end else if (feed_idx >= BLOCK_BYTES) begin
                    s_axis_tvalid <= 0; s_axis_tlast <= 0;
                end
            end
            while (busy && cycles < 500000) begin
                @(posedge clk); cycles = cycles + 1;
                if (record_valid && record_ready) entries = entries + 1;
            end
            s_axis_tvalid <= 0; s_axis_tlast <= 0;
        end
    endtask
    integer cn,cw,en,ew;
    initial begin
        clk=0;rstn=0;clear=0;start=0;block_byte_count=0;cap_align_offset=0;
        s_axis_tdata=0;s_axis_tkeep=0;s_axis_tlast=0;s_axis_tvalid=0;
        record_ready=1;m_axis_tready=1;
        $readmemh("stress_src0.hex", block_data);
        repeat(5) @(posedge clk); rstn<=1; repeat(5) @(posedge clk);
        run_decode(1,cn,en);
        $display("=== NARROW (1B) === cycles=%0d entries=%0d err=%0b",cn,en,error);
        repeat(10) @(posedge clk);
        run_decode(8,cw,ew);
        $display("=== WIDE   (8B) === cycles=%0d entries=%0d err=%0b",cw,ew,error);
        $display("P6 speedup: %0d -> %0d cycles (-%0d%%)",cn,cw,(cn-cw)*100/cn);
        if (error||en!=ew||en==0) begin $display("FAIL"); $finish_and_return(1); end
        $display("PASS: %0d entries",en);
        $finish;
    end
endmodule
