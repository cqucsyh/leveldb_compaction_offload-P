`timescale 1ns / 1ps

module tb_real_data_block_encoder;

    reg clk;
    reg rstn;
    reg clear;
    reg start;
    reg [7:0] s_axis_tdata;
    reg [0:0] s_axis_tkeep;
    reg s_axis_tlast;
    reg s_axis_tvalid;
    wire s_axis_tready;
    wire [7:0] m_axis_tdata;
    wire [0:0] m_axis_tkeep;
    wire m_axis_tlast;
    wire m_axis_tvalid;
    reg  m_axis_tready;
    wire busy;
    wire done;
    wire error;
    wire [31:0] input_record_count;
    wire [31:0] encoded_entry_count;
    wire [31:0] restart_count;
    wire [31:0] shared_key_bytes_total;
    wire [31:0] unshared_key_bytes_total;
    wire [31:0] value_bytes_total;
    wire [15:0] last_key_len;
    wire [15:0] last_value_len;
    wire [15:0] last_shared_bytes;
    wire [15:0] last_non_shared_bytes;
    wire [31:0] output_block_bytes;

    reg [7:0] input_bytes [0:32];
    reg [7:0] expected_block [0:35];
    reg [7:0] observed_block [0:63];
    integer input_len;
    integer expected_len;
    integer send_idx;
    integer out_idx;

    real_data_block_encoder #(
        .MAX_RECORDS(8),
        .MAX_PAYLOAD_BYTES(128),
        .MAX_BLOCK_BYTES(128),
        .MAX_KEY_BYTES(16),
        .MAX_VALUE_BYTES(16),
        .RESTART_INTERVAL(2)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .busy(busy),
        .done(done),
        .error(error),
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
        .output_block_bytes(output_block_bytes)
    );

    always #5 clk = ~clk;

    task send_byte;
        input [7:0] data_byte;
        input       last_byte;
        begin
            @(negedge clk);
            s_axis_tdata  = data_byte;
            s_axis_tkeep  = 1'b1;
            s_axis_tlast  = last_byte;
            s_axis_tvalid = 1'b1;
            while (!(s_axis_tvalid && s_axis_tready)) begin
                @(posedge clk);
            end
            @(negedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tlast  = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rstn = 1'b0;
        clear = 1'b0;
        start = 1'b0;
        s_axis_tdata = 8'd0;
        s_axis_tkeep = 1'b0;
        s_axis_tlast = 1'b0;
        s_axis_tvalid = 1'b0;
        m_axis_tready = 1'b1;
        input_len = 0;
        expected_len = 36;
        out_idx = 0;

        input_bytes[0]  = 8'h03;
        input_bytes[1]  = 8'h00;
        input_bytes[2]  = 8'h00;
        input_bytes[3]  = 8'h00;
        input_bytes[4]  = 8'h03;
        input_bytes[5]  = 8'h00;
        input_bytes[6]  = 8'h02;
        input_bytes[7]  = 8'h00;
        input_bytes[8]  = 8'h63;
        input_bytes[9]  = 8'h61;
        input_bytes[10] = 8'h74;
        input_bytes[11] = 8'h76;
        input_bytes[12] = 8'h31;
        input_bytes[13] = 8'h04;
        input_bytes[14] = 8'h00;
        input_bytes[15] = 8'h02;
        input_bytes[16] = 8'h00;
        input_bytes[17] = 8'h63;
        input_bytes[18] = 8'h61;
        input_bytes[19] = 8'h72;
        input_bytes[20] = 8'h73;
        input_bytes[21] = 8'h76;
        input_bytes[22] = 8'h32;
        input_bytes[23] = 8'h04;
        input_bytes[24] = 8'h00;
        input_bytes[25] = 8'h02;
        input_bytes[26] = 8'h00;
        input_bytes[27] = 8'h64;
        input_bytes[28] = 8'h6f;
        input_bytes[29] = 8'h67;
        input_bytes[30] = 8'h65;
        input_bytes[31] = 8'h76;
        input_bytes[32] = 8'h33;
        input_len = 33;

        expected_block[0]  = 8'h00;
        expected_block[1]  = 8'h03;
        expected_block[2]  = 8'h02;
        expected_block[3]  = 8'h63;
        expected_block[4]  = 8'h61;
        expected_block[5]  = 8'h74;
        expected_block[6]  = 8'h76;
        expected_block[7]  = 8'h31;
        expected_block[8]  = 8'h02;
        expected_block[9]  = 8'h02;
        expected_block[10] = 8'h02;
        expected_block[11] = 8'h72;
        expected_block[12] = 8'h73;
        expected_block[13] = 8'h76;
        expected_block[14] = 8'h32;
        expected_block[15] = 8'h00;
        expected_block[16] = 8'h04;
        expected_block[17] = 8'h02;
        expected_block[18] = 8'h64;
        expected_block[19] = 8'h6f;
        expected_block[20] = 8'h67;
        expected_block[21] = 8'h65;
        expected_block[22] = 8'h76;
        expected_block[23] = 8'h33;
        expected_block[24] = 8'h00;
        expected_block[25] = 8'h00;
        expected_block[26] = 8'h00;
        expected_block[27] = 8'h00;
        expected_block[28] = 8'h0f;
        expected_block[29] = 8'h00;
        expected_block[30] = 8'h00;
        expected_block[31] = 8'h00;
        expected_block[32] = 8'h02;
        expected_block[33] = 8'h00;
        expected_block[34] = 8'h00;
        expected_block[35] = 8'h00;

        repeat (4) @(posedge clk);
        rstn = 1'b1;
        repeat (2) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        for (send_idx = 0; send_idx < input_len; send_idx = send_idx + 1) begin
            send_byte(input_bytes[send_idx], (send_idx == input_len - 1));
        end

        while (!done && !error) begin
            @(posedge clk);
            if (m_axis_tvalid && m_axis_tready) begin
                observed_block[out_idx] = m_axis_tdata;
                out_idx = out_idx + 1;
            end
        end

        if (error) begin
            $display("Encoder reported error");
            $finish_and_return(1);
        end

        if (out_idx != expected_len) begin
            $display("Encoded block length mismatch got=%0d exp=%0d", out_idx, expected_len);
            $finish_and_return(1);
        end

        for (send_idx = 0; send_idx < expected_len; send_idx = send_idx + 1) begin
            if (observed_block[send_idx] !== expected_block[send_idx]) begin
                $display("Encoded byte mismatch idx=%0d got=%02x exp=%02x", send_idx, observed_block[send_idx], expected_block[send_idx]);
                $finish_and_return(1);
            end
        end

        if (input_record_count !== 32'd3 ||
            encoded_entry_count !== 32'd3 ||
            restart_count !== 32'd2 ||
            shared_key_bytes_total !== 32'd2 ||
            unshared_key_bytes_total !== 32'd9 ||
            value_bytes_total !== 32'd6 ||
            last_key_len !== 16'd4 ||
            last_value_len !== 16'd2 ||
            last_shared_bytes !== 16'd0 ||
            last_non_shared_bytes !== 16'd4 ||
            output_block_bytes !== 32'd36) begin
            $display("Encoder counter mismatch");
            $finish_and_return(1);
        end

        $display("PASS real_data_block_encoder");
        $finish;
    end

endmodule
