`timescale 1ns / 1ps

module tb_real_internal_key_merge_decoder;

    reg         clk;
    reg         rstn;
    reg         clear;
    reg         start;
    reg         source_done;
    reg         s_record_valid;
    wire        s_record_ready;
    reg  [15:0] s_record_key_len;
    reg  [15:0] s_record_value_len;
    reg  [7:0]  s_axis_tdata;
    reg  [0:0]  s_axis_tkeep;
    reg         s_axis_tlast;
    reg         s_axis_tvalid;
    wire        s_axis_tready;
    wire        m_record_valid;
    reg         m_record_ready;
    wire [15:0] m_record_key_len;
    wire [15:0] m_record_value_len;
    wire [7:0]  m_axis_tdata;
    wire [0:0]  m_axis_tkeep;
    wire        m_axis_tlast;
    wire        m_axis_tvalid;
    reg         m_axis_tready;
    wire        busy;
    wire        done;
    wire        error;
    wire [31:0] decoded_record_count;
    wire [31:0] merged_record_count;
    wire [31:0] dropped_superseded_count;
    wire [31:0] value_record_count;
    wire [31:0] delete_record_count;
    wire [31:0] user_key_bytes_total;
    wire [31:0] value_bytes_total;
    wire [15:0] last_user_key_len;
    wire [55:0] last_sequence;
    wire [7:0]  last_value_type;
    wire        last_record_keep;

    integer i;
    integer observed_header_count;
    integer observed_payload_count;
    integer observed_record_tlast_count;

    reg [15:0] observed_key_len [0:2];
    reg [15:0] observed_value_len [0:2];
    reg [7:0] observed_payload [0:35];
    reg [7:0] expected_payload [0:35];
    reg [63:0] send_tag;
    reg [7:0] send_key_bytes [0:10];
    integer send_j;
    integer send_payload_len;

    real_internal_key_merge_decoder #(
        .MAX_USER_KEY_BYTES(32),
        .MAX_KEY_BYTES(40),
        .MAX_VALUE_BYTES(16),
        .MAX_RECORD_BYTES(64)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .source_done(source_done),
        .s_record_valid(s_record_valid),
        .s_record_ready(s_record_ready),
        .s_record_key_len(s_record_key_len),
        .s_record_value_len(s_record_value_len),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .m_record_valid(m_record_valid),
        .m_record_ready(m_record_ready),
        .m_record_key_len(m_record_key_len),
        .m_record_value_len(m_record_value_len),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .busy(busy),
        .done(done),
        .error(error),
        .decoded_record_count(decoded_record_count),
        .merged_record_count(merged_record_count),
        .dropped_superseded_count(dropped_superseded_count),
        .value_record_count(value_record_count),
        .delete_record_count(delete_record_count),
        .user_key_bytes_total(user_key_bytes_total),
        .value_bytes_total(value_bytes_total),
        .last_user_key_len(last_user_key_len),
        .last_sequence(last_sequence),
        .last_value_type(last_value_type),
        .last_record_keep(last_record_keep)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (!rstn || clear) begin
            observed_header_count <= 0;
            observed_payload_count <= 0;
            observed_record_tlast_count <= 0;
        end else begin
            if (m_record_valid && m_record_ready) begin
                if (observed_header_count > 2) begin
                    $display("Too many kept record headers");
                    $finish_and_return(1);
                end
                observed_key_len[observed_header_count] <= m_record_key_len;
                observed_value_len[observed_header_count] <= m_record_value_len;
                observed_header_count <= observed_header_count + 1;
            end
            if (m_axis_tvalid && m_axis_tready) begin
                observed_payload[observed_payload_count] <= m_axis_tdata;
                observed_payload_count <= observed_payload_count + 1;
                if (m_axis_tkeep !== 1'b1) begin
                    $display("Unexpected m_axis_tkeep");
                    $finish_and_return(1);
                end
                if (m_axis_tlast) begin
                    observed_record_tlast_count <= observed_record_tlast_count + 1;
                end
            end
        end
    end

    task automatic pulse_source_done;
    begin
        @(negedge clk);
        source_done = 1'b1;
        @(negedge clk);
        source_done = 1'b0;
    end
    endtask

    task automatic send_byte;
        input [7:0] value;
        input       last_flag;
    begin
        @(negedge clk);
        s_axis_tdata = value;
        s_axis_tkeep = 1'b1;
        s_axis_tlast = last_flag;
        s_axis_tvalid = 1'b1;
        while (!s_axis_tready) begin
            @(negedge clk);
        end
        @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tlast = 1'b0;
        s_axis_tdata = 8'd0;
    end
    endtask

    task automatic send_record;
        input [8*3-1:0] user_key3;
        input [55:0] seq_num;
        input [7:0] value_type;
        input [7:0] value_byte;
        input integer has_value;
    begin
        send_tag = {seq_num, value_type};
        send_key_bytes[0] = user_key3[23:16];
        send_key_bytes[1] = user_key3[15:8];
        send_key_bytes[2] = user_key3[7:0];
        for (send_j = 0; send_j < 8; send_j = send_j + 1) begin
            send_key_bytes[3 + send_j] = send_tag[(8 * send_j) +: 8];
        end
        send_payload_len = 11 + has_value;

        @(negedge clk);
        s_record_key_len = 16'd11;
        s_record_value_len = has_value ? 16'd1 : 16'd0;
        s_record_valid = 1'b1;
        while (!s_record_ready) begin
            @(negedge clk);
        end
        @(negedge clk);
        s_record_valid = 1'b0;

        for (send_j = 0; send_j < 11; send_j = send_j + 1) begin
            send_byte(send_key_bytes[send_j], (send_j + 1 == send_payload_len));
        end
        if (has_value) begin
            send_byte(value_byte, 1'b1);
        end
    end
    endtask

    initial begin
        clk = 1'b0;
        rstn = 1'b0;
        clear = 1'b0;
        start = 1'b0;
        source_done = 1'b0;
        s_record_valid = 1'b0;
        s_record_key_len = 16'd0;
        s_record_value_len = 16'd0;
        s_axis_tdata = 8'd0;
        s_axis_tkeep = 1'b1;
        s_axis_tlast = 1'b0;
        s_axis_tvalid = 1'b0;
        m_record_ready = 1'b1;
        m_axis_tready = 1'b1;
        observed_header_count = 0;
        observed_payload_count = 0;
        observed_record_tlast_count = 0;
        for (i = 0; i < 36; i = i + 1) begin
            observed_payload[i] = 8'd0;
            expected_payload[i] = 8'd0;
        end

        expected_payload[0] = "c";
        expected_payload[1] = "a";
        expected_payload[2] = "t";
        expected_payload[3] = 8'h01;
        expected_payload[4] = 8'h0A;
        expected_payload[5] = 8'h00;
        expected_payload[6] = 8'h00;
        expected_payload[7] = 8'h00;
        expected_payload[8] = 8'h00;
        expected_payload[9] = 8'h00;
        expected_payload[10] = 8'h00;
        expected_payload[11] = "A";
        expected_payload[12] = "d";
        expected_payload[13] = "o";
        expected_payload[14] = "g";
        expected_payload[15] = 8'h00;
        expected_payload[16] = 8'h07;
        expected_payload[17] = 8'h00;
        expected_payload[18] = 8'h00;
        expected_payload[19] = 8'h00;
        expected_payload[20] = 8'h00;
        expected_payload[21] = 8'h00;
        expected_payload[22] = 8'h00;
        expected_payload[23] = "e";
        expected_payload[24] = "e";
        expected_payload[25] = "l";
        expected_payload[26] = 8'h01;
        expected_payload[27] = 8'h05;
        expected_payload[28] = 8'h00;
        expected_payload[29] = 8'h00;
        expected_payload[30] = 8'h00;
        expected_payload[31] = 8'h00;
        expected_payload[32] = 8'h00;
        expected_payload[33] = 8'h00;
        expected_payload[34] = "Z";

        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (3) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        send_record("cat", 56'd10, 8'h01, "A", 1);
        send_record("cat", 56'd9, 8'h01, "B", 1);
        send_record("dog", 56'd7, 8'h00, 8'h00, 0);
        send_record("eel", 56'd5, 8'h01, "Z", 1);
        pulse_source_done();

        while (!done && !error) begin
            @(posedge clk);
        end

        if (error) begin
            $display("real_internal_key_merge_decoder reported error");
            $finish_and_return(1);
        end

        if (decoded_record_count != 32'd4) begin
            $display("decoded_record_count mismatch got=%0d", decoded_record_count);
            $finish_and_return(1);
        end
        if (merged_record_count != 32'd3) begin
            $display("merged_record_count mismatch got=%0d", merged_record_count);
            $finish_and_return(1);
        end
        if (dropped_superseded_count != 32'd1) begin
            $display("dropped_superseded_count mismatch got=%0d", dropped_superseded_count);
            $finish_and_return(1);
        end
        if (value_record_count != 32'd3) begin
            $display("value_record_count mismatch got=%0d", value_record_count);
            $finish_and_return(1);
        end
        if (delete_record_count != 32'd1) begin
            $display("delete_record_count mismatch got=%0d", delete_record_count);
            $finish_and_return(1);
        end
        if (user_key_bytes_total != 32'd12) begin
            $display("user_key_bytes_total mismatch got=%0d", user_key_bytes_total);
            $finish_and_return(1);
        end
        if (value_bytes_total != 32'd3) begin
            $display("value_bytes_total mismatch got=%0d", value_bytes_total);
            $finish_and_return(1);
        end
        if (last_user_key_len != 16'd3) begin
            $display("last_user_key_len mismatch got=%0d", last_user_key_len);
            $finish_and_return(1);
        end
        if (last_sequence != 56'd5) begin
            $display("last_sequence mismatch got=%0d", last_sequence);
            $finish_and_return(1);
        end
        if (last_value_type != 8'h01) begin
            $display("last_value_type mismatch got=%0h", last_value_type);
            $finish_and_return(1);
        end
        if (last_record_keep != 1'b1) begin
            $display("last_record_keep mismatch got=%0d", last_record_keep);
            $finish_and_return(1);
        end
        if (observed_header_count != 3) begin
            $display("observed_header_count mismatch got=%0d decoded=%0d merged=%0d dropped=%0d value=%0d delete=%0d last_seq=%0d last_type=%0h last_keep=%0d payloads=%0d tlasts=%0d",
                     observed_header_count,
                     decoded_record_count,
                     merged_record_count,
                     dropped_superseded_count,
                     value_record_count,
                     delete_record_count,
                     last_sequence,
                     last_value_type,
                     last_record_keep,
                     observed_payload_count,
                     observed_record_tlast_count);
            $finish_and_return(1);
        end
        if (observed_record_tlast_count != 3) begin
            $display("observed_record_tlast_count mismatch got=%0d", observed_record_tlast_count);
            $finish_and_return(1);
        end
        if (observed_payload_count != 35) begin
            $display("observed_payload_count mismatch got=%0d", observed_payload_count);
            $finish_and_return(1);
        end
        if (observed_key_len[0] != 16'd11 || observed_value_len[0] != 16'd1) begin
            $display("record0 header mismatch");
            $finish_and_return(1);
        end
        if (observed_key_len[1] != 16'd11 || observed_value_len[1] != 16'd0) begin
            $display("record1 header mismatch");
            $finish_and_return(1);
        end
        if (observed_key_len[2] != 16'd11 || observed_value_len[2] != 16'd1) begin
            $display("record2 header mismatch");
            $finish_and_return(1);
        end
        for (i = 0; i < 35; i = i + 1) begin
            if (observed_payload[i] !== expected_payload[i]) begin
                $display("payload mismatch idx=%0d got=%02x exp=%02x", i, observed_payload[i], expected_payload[i]);
                $finish_and_return(1);
            end
        end

        $display("PASS real_internal_key_merge_decoder");
        $finish;
    end

endmodule
