`timescale 1ns / 1ps

module tb_real_data_block_encoder_multibeat;

    localparam integer RECORD_COUNT = 17;
    localparam integer MAX_INPUT_BYTES = 1024;
    localparam integer MAX_BLOCK_BYTES = 1024;

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

    reg [7:0] input_bytes [0:MAX_INPUT_BYTES-1];
    reg [7:0] expected_block [0:MAX_BLOCK_BYTES-1];
    reg [7:0] observed_block [0:MAX_BLOCK_BYTES-1];
    reg [7:0] cur_key [0:31];
    reg [7:0] prev_key [0:31];
    reg [7:0] cur_val [0:31];

    integer input_len;
    integer expected_len;
    integer observed_len;
    integer send_idx;
    integer i;
    integer shared;
    integer non_shared;
    integer restart_offsets [0:31];
    integer restart_count_exp;
    integer entries_since_restart;
    integer key_len_i;
    integer value_len_i;
    integer restart_array_offset;

    real_data_block_encoder #(
        .MAX_RECORDS(32),
        .MAX_PAYLOAD_BYTES(1024),
        .MAX_BLOCK_BYTES(1024),
        .MAX_KEY_BYTES(32),
        .MAX_VALUE_BYTES(32),
        .RESTART_INTERVAL(16)
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

    task append_input_byte;
        input [7:0] value;
        begin
            input_bytes[input_len] = value;
            input_len = input_len + 1;
        end
    endtask

    task append_expected_byte;
        input [7:0] value;
        begin
            expected_block[expected_len] = value;
            expected_len = expected_len + 1;
        end
    endtask

    task append_fixed32_le;
        input integer value;
        begin
            append_expected_byte(value[7:0]);
            append_expected_byte(value[15:8]);
            append_expected_byte(value[23:16]);
            append_expected_byte(value[31:24]);
        end
    endtask

    task build_record_bytes;
        input integer rec_idx;
        begin
            cur_key[0]  = "p";
            cur_key[1]  = "r";
            cur_key[2]  = "e";
            cur_key[3]  = "f";
            cur_key[4]  = "i";
            cur_key[5]  = "x";
            cur_key[6]  = "_";
            cur_key[7]  = "s";
            cur_key[8]  = "h";
            cur_key[9]  = "a";
            cur_key[10] = "r";
            cur_key[11] = "e";
            cur_key[12] = "d";
            cur_key[13] = "_";
            cur_key[14] = "0" + ((rec_idx / 10) % 10);
            cur_key[15] = "0" + (rec_idx % 10);
            key_len_i = 16;

            cur_val[0] = "p";
            cur_val[1] = "v";
            cur_val[2] = "0" + ((rec_idx / 10) % 10);
            cur_val[3] = "0" + (rec_idx % 10);
            value_len_i = 4;
        end
    endtask

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
        expected_len = 0;
        observed_len = 0;
        restart_count_exp = 0;
        entries_since_restart = 0;
        restart_array_offset = 0;
        for (i = 0; i < 32; i = i + 1) begin
            restart_offsets[i] = 0;
        end

        append_input_byte(RECORD_COUNT[7:0]);
        append_input_byte(RECORD_COUNT[15:8]);
        append_input_byte(RECORD_COUNT[23:16]);
        append_input_byte(RECORD_COUNT[31:24]);

        restart_offsets[0] = 0;
        restart_count_exp = 1;

        for (i = 0; i < RECORD_COUNT; i = i + 1) begin
            build_record_bytes(i);
            append_input_byte(key_len_i[7:0]);
            append_input_byte(key_len_i[15:8]);
            append_input_byte(value_len_i[7:0]);
            append_input_byte(value_len_i[15:8]);
            for (send_idx = 0; send_idx < key_len_i; send_idx = send_idx + 1) begin
                append_input_byte(cur_key[send_idx]);
            end
            for (send_idx = 0; send_idx < value_len_i; send_idx = send_idx + 1) begin
                append_input_byte(cur_val[send_idx]);
            end

            if ((i == 0) || (entries_since_restart == 16)) begin
                shared = 0;
                if (i != 0) begin
                    restart_offsets[restart_count_exp] = expected_len;
                    restart_count_exp = restart_count_exp + 1;
                end
                entries_since_restart = 0;
            end else begin
                shared = 0;
                while ((shared < key_len_i) && (cur_key[shared] == prev_key[shared])) begin
                    shared = shared + 1;
                end
            end
            non_shared = key_len_i - shared;
            append_expected_byte(shared[7:0]);
            append_expected_byte(non_shared[7:0]);
            append_expected_byte(value_len_i[7:0]);
            for (send_idx = shared; send_idx < key_len_i; send_idx = send_idx + 1) begin
                append_expected_byte(cur_key[send_idx]);
            end
            for (send_idx = 0; send_idx < value_len_i; send_idx = send_idx + 1) begin
                append_expected_byte(cur_val[send_idx]);
            end
            entries_since_restart = entries_since_restart + 1;
            for (send_idx = 0; send_idx < key_len_i; send_idx = send_idx + 1) begin
                prev_key[send_idx] = cur_key[send_idx];
            end
        end

        restart_array_offset = expected_len;
        for (i = 0; i < restart_count_exp; i = i + 1) begin
            append_fixed32_le(restart_offsets[i]);
        end
        append_fixed32_le(restart_count_exp);

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
                observed_block[observed_len] = m_axis_tdata;
                observed_len = observed_len + 1;
            end
        end

        if (error) begin
            $display("Encoder reported error in multi-beat case");
            $finish_and_return(1);
        end

        if (observed_len != expected_len) begin
            $display("Encoded block length mismatch got=%0d exp=%0d", observed_len, expected_len);
            $finish_and_return(1);
        end

        for (i = 0; i < expected_len; i = i + 1) begin
            if (observed_block[i] !== expected_block[i]) begin
                $display("Encoded byte mismatch idx=%0d got=%02x exp=%02x", i, observed_block[i], expected_block[i]);
                $finish_and_return(1);
            end
        end

        if (input_record_count !== RECORD_COUNT ||
            encoded_entry_count !== RECORD_COUNT ||
            restart_count !== restart_count_exp ||
            last_key_len !== 16'd16 ||
            last_value_len !== 16'd4 ||
            output_block_bytes !== expected_len) begin
            $display("Encoder counter mismatch in multi-beat case");
            $finish_and_return(1);
        end

        $display("PASS real_data_block_encoder multibeat");
        $finish;
    end

endmodule
