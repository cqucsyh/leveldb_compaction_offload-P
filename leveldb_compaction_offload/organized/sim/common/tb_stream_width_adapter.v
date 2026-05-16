`timescale 1ns / 1ps

module tb_stream_width_adapter;

    reg clk;
    reg rstn;
    reg clear;
    reg [511:0] s_axis_tdata;
    reg [63:0]  s_axis_tkeep;
    reg         s_axis_tlast;
    reg         s_axis_tvalid;
    wire        s_axis_tready;
    wire [7:0]  m_axis_tdata;
    wire [0:0]  m_axis_tkeep;
    wire        m_axis_tlast;
    wire        m_axis_tvalid;
    reg         m_axis_tready;

    integer idx;

    stream_width_adapter #(
        .IN_DATA_WIDTH(512),
        .IN_KEEP_WIDTH(64),
        .OUT_DATA_WIDTH(8),
        .OUT_KEEP_WIDTH(1)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rstn = 1'b0;
        clear = 1'b0;
        s_axis_tdata = 512'd0;
        s_axis_tkeep = 64'd0;
        s_axis_tlast = 1'b0;
        s_axis_tvalid = 1'b0;
        m_axis_tready = 1'b1;

        repeat (4) @(posedge clk);
        rstn = 1'b1;
        repeat (2) @(posedge clk);

        for (idx = 0; idx < 64; idx = idx + 1) begin
            s_axis_tdata[idx*8 +: 8] = idx[7:0];
        end
        s_axis_tkeep = 64'h0000_0000_0000_00ff;
        s_axis_tlast = 1'b1;
        @(negedge clk);
        s_axis_tvalid = 1'b1;
        while (!(s_axis_tvalid && s_axis_tready)) begin
            @(posedge clk);
        end
        @(negedge clk);
        s_axis_tvalid = 1'b0;

        idx = 0;
        while (idx < 8) begin
            @(posedge clk);
            if (m_axis_tvalid && m_axis_tready) begin
                if (m_axis_tdata !== idx[7:0]) begin
                    $display("Adapter mismatch idx=%0d got=%02x", idx, m_axis_tdata);
                    $finish_and_return(1);
                end
                if (m_axis_tkeep !== 1'b1) begin
                    $display("Adapter keep mismatch idx=%0d", idx);
                    $finish_and_return(1);
                end
                if ((idx == 7) && !m_axis_tlast) begin
                    $display("Adapter last not asserted on final byte");
                    $finish_and_return(1);
                end
                if ((idx != 7) && m_axis_tlast) begin
                    $display("Adapter last asserted too early idx=%0d", idx);
                    $finish_and_return(1);
                end
                idx = idx + 1;
            end
        end

        $display("PASS stream_width_adapter");
        $finish;
    end

endmodule
