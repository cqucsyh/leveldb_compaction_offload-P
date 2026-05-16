`timescale 1ns / 1ps

module tb_real_internal_key_two_way_merge_top;

    localparam integer SRC0_RECORDS = 4;
    localparam integer SRC1_RECORDS = 5;
    localparam integer SRC0_BYTES   = 47;
    localparam integer SRC1_BYTES   = 60;
    localparam integer OUT_BYTES    = 99;

    reg clk;
    reg rstn;
    reg clear;
    reg start;

    reg        source0_done;
    reg        s0_record_valid;
    wire       s0_record_ready;
    reg [15:0] s0_record_key_len;
    reg [15:0] s0_record_value_len;
    reg [7:0]  s0_axis_tdata;
    reg [0:0]  s0_axis_tkeep;
    reg        s0_axis_tlast;
    reg        s0_axis_tvalid;
    wire       s0_axis_tready;

    reg        source1_done;
    reg        s1_record_valid;
    wire       s1_record_ready;
    reg [15:0] s1_record_key_len;
    reg [15:0] s1_record_value_len;
    reg [7:0]  s1_axis_tdata;
    reg [0:0]  s1_axis_tkeep;
    reg        s1_axis_tlast;
    reg        s1_axis_tvalid;
    wire       s1_axis_tready;

    wire       busy;
    wire       done;
    wire       error;
    wire [31:0] output_byte_count;
    wire [7:0] m_axis_tdata;
    wire [0:0] m_axis_tkeep;
    wire       m_axis_tlast;
    wire       m_axis_tvalid;
    reg        m_axis_tready;
    wire [31:0] merge_decoded_record_count;
    wire [31:0] merge_merged_record_count;
    wire [31:0] merge_dropped_superseded_count;
    wire [31:0] merge_value_record_count;
    wire [31:0] merge_delete_record_count;
    wire [31:0] merge_user_key_bytes_total;
    wire [31:0] merge_value_bytes_total;
    wire [15:0] merge_last_user_key_len;
    wire [55:0] merge_last_sequence;
    wire [7:0]  merge_last_value_type;
    wire        merge_last_record_keep;

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

    reg [7:0]  expected_out [0:OUT_BYTES-1];

    integer i;
    integer out_byte_index;
    integer src0_rec_index;
    integer src0_byte_index;
    integer src1_rec_index;
    integer src1_byte_index;
    reg     src0_in_payload;
    reg     src1_in_payload;

    real_internal_key_two_way_merge_top #(
        .MAX_USER_KEY_BYTES(256),
        .MAX_KEY_BYTES(264),
        .MAX_VALUE_BYTES(1024),
        .MAX_RECORD_BYTES(2048),
        .MAX_RECORDS(256),
        .MAX_OUTPUT_BYTES(1024)
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
        .busy(busy),
        .done(done),
        .error(error),
        .output_byte_count(output_byte_count),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
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
        .final_prev_user_key_valid(),
        .final_prev_user_key_len(),
        .final_prev_user_key()
    );

    always #5 clk = ~clk;

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
                while (!s0_record_ready) begin
                    @(negedge clk);
                end
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
                    while (!s0_axis_tready) begin
                        @(negedge clk);
                    end
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
                while (!s1_record_ready) begin
                    @(negedge clk);
                end
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
                    while (!s1_axis_tready) begin
                        @(negedge clk);
                    end
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

    always @(posedge clk) begin
        if (!rstn || clear) begin
            out_byte_index <= 0;
        end else if (m_axis_tvalid && m_axis_tready) begin
            if (out_byte_index >= OUT_BYTES) begin
                $display("unexpected extra output byte idx=%0d", out_byte_index);
                $finish_and_return(1);
            end
            if (m_axis_tdata !== expected_out[out_byte_index]) begin
                $display("counted output mismatch idx=%0d got=%02x exp=%02x", out_byte_index, m_axis_tdata, expected_out[out_byte_index]);
                $finish_and_return(1);
            end
            if (m_axis_tkeep !== 1'b1) begin
                $display("unexpected output keep idx=%0d", out_byte_index);
                $finish_and_return(1);
            end
            if (out_byte_index + 1 == OUT_BYTES) begin
                if (!m_axis_tlast) begin
                    $display("missing final tlast");
                    $finish_and_return(1);
                end
            end else if (m_axis_tlast) begin
                $display("early tlast idx=%0d", out_byte_index);
                $finish_and_return(1);
            end
            out_byte_index <= out_byte_index + 1;
        end
    end

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
        m_axis_tready = 1'b1;
        out_byte_index = 0;

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

        expected_out[0] = 8'h06; expected_out[1] = 8'h00; expected_out[2] = 8'h00; expected_out[3] = 8'h00;
        expected_out[4] = 8'h0b; expected_out[5] = 8'h00; expected_out[6] = 8'h01; expected_out[7] = 8'h00;
        expected_out[8] = "a"; expected_out[9] = "n"; expected_out[10] = "t"; expected_out[11] = 8'h01;
        expected_out[12] = 8'h64; expected_out[13] = 8'h00; expected_out[14] = 8'h00; expected_out[15] = 8'h00;
        expected_out[16] = 8'h00; expected_out[17] = 8'h00; expected_out[18] = 8'h00; expected_out[19] = "A";
        expected_out[20] = 8'h0b; expected_out[21] = 8'h00; expected_out[22] = 8'h01; expected_out[23] = 8'h00;
        expected_out[24] = "b"; expected_out[25] = "e"; expected_out[26] = "e"; expected_out[27] = 8'h01;
        expected_out[28] = 8'h6e; expected_out[29] = 8'h00; expected_out[30] = 8'h00; expected_out[31] = 8'h00;
        expected_out[32] = 8'h00; expected_out[33] = 8'h00; expected_out[34] = 8'h00; expected_out[35] = "B";
        expected_out[36] = 8'h0b; expected_out[37] = 8'h00; expected_out[38] = 8'h01; expected_out[39] = 8'h00;
        expected_out[40] = "c"; expected_out[41] = "a"; expected_out[42] = "t"; expected_out[43] = 8'h01;
        expected_out[44] = 8'h61; expected_out[45] = 8'h00; expected_out[46] = 8'h00; expected_out[47] = 8'h00;
        expected_out[48] = 8'h00; expected_out[49] = 8'h00; expected_out[50] = 8'h00; expected_out[51] = "C";
        expected_out[52] = 8'h0b; expected_out[53] = 8'h00; expected_out[54] = 8'h00; expected_out[55] = 8'h00;
        expected_out[56] = "d"; expected_out[57] = "o"; expected_out[58] = "g"; expected_out[59] = 8'h00;
        expected_out[60] = 8'h5a; expected_out[61] = 8'h00; expected_out[62] = 8'h00; expected_out[63] = 8'h00;
        expected_out[64] = 8'h00; expected_out[65] = 8'h00; expected_out[66] = 8'h00;
        expected_out[67] = 8'h0b; expected_out[68] = 8'h00; expected_out[69] = 8'h01; expected_out[70] = 8'h00;
        expected_out[71] = "e"; expected_out[72] = "e"; expected_out[73] = "l"; expected_out[74] = 8'h01;
        expected_out[75] = 8'h50; expected_out[76] = 8'h00; expected_out[77] = 8'h00; expected_out[78] = 8'h00;
        expected_out[79] = 8'h00; expected_out[80] = 8'h00; expected_out[81] = 8'h00; expected_out[82] = "E";
        expected_out[83] = 8'h0b; expected_out[84] = 8'h00; expected_out[85] = 8'h01; expected_out[86] = 8'h00;
        expected_out[87] = "y"; expected_out[88] = "a"; expected_out[89] = "k"; expected_out[90] = 8'h01;
        expected_out[91] = 8'h32; expected_out[92] = 8'h00; expected_out[93] = 8'h00; expected_out[94] = 8'h00;
        expected_out[95] = 8'h00; expected_out[96] = 8'h00; expected_out[97] = 8'h00; expected_out[98] = "Y";

        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        fork
            drive_source0();
            drive_source1();
        join_none

        for (i = 0; i < 4000; i = i + 1) begin
            @(posedge clk);
            if (done || error) begin
                i = 4000;
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
        if (out_byte_index != OUT_BYTES) begin
            $display("output byte count mismatch by capture got=%0d exp=%0d", out_byte_index, OUT_BYTES);
            $finish_and_return(1);
        end
        if (output_byte_count != OUT_BYTES) begin
            $display("output_byte_count mismatch got=%0d exp=%0d", output_byte_count, OUT_BYTES);
            $finish_and_return(1);
        end
        if (merge_decoded_record_count != 32'd9) begin
            $display("merge_decoded_record_count mismatch got=%0d", merge_decoded_record_count);
            $finish_and_return(1);
        end
        if (merge_merged_record_count != 32'd6) begin
            $display("merge_merged_record_count mismatch got=%0d", merge_merged_record_count);
            $finish_and_return(1);
        end
        if (merge_dropped_superseded_count != 32'd3) begin
            $display("merge_dropped_superseded_count mismatch got=%0d", merge_dropped_superseded_count);
            $finish_and_return(1);
        end
        if (merge_value_record_count != 32'd8) begin
            $display("merge_value_record_count mismatch got=%0d", merge_value_record_count);
            $finish_and_return(1);
        end
        if (merge_delete_record_count != 32'd1) begin
            $display("merge_delete_record_count mismatch got=%0d", merge_delete_record_count);
            $finish_and_return(1);
        end
        if (merge_user_key_bytes_total != 32'd27) begin
            $display("merge_user_key_bytes_total mismatch got=%0d", merge_user_key_bytes_total);
            $finish_and_return(1);
        end
        if (merge_value_bytes_total != 32'd8) begin
            $display("merge_value_bytes_total mismatch got=%0d", merge_value_bytes_total);
            $finish_and_return(1);
        end
        if (merge_last_user_key_len != 16'd3) begin
            $display("merge_last_user_key_len mismatch got=%0d", merge_last_user_key_len);
            $finish_and_return(1);
        end
        if (merge_last_sequence != 56'd49) begin
            $display("merge_last_sequence mismatch got=%0d", merge_last_sequence);
            $finish_and_return(1);
        end
        if (merge_last_value_type != 8'd1) begin
            $display("merge_last_value_type mismatch got=%0d", merge_last_value_type);
            $finish_and_return(1);
        end
        if (merge_last_record_keep != 1'b0) begin
            $display("merge_last_record_keep mismatch got=%0d", merge_last_record_keep);
            $finish_and_return(1);
        end

        $display("PASS real_internal_key_two_way_merge_top out_bytes=%0d decoded=%0d kept=%0d dropped=%0d",
                 output_byte_count,
                 merge_decoded_record_count,
                 merge_merged_record_count,
                 merge_dropped_superseded_count);
        $finish;
    end

endmodule
