`timescale 1ns / 1ps

module tb_real_internal_key_two_way_merge_decoder;

    localparam integer SRC0_RECORDS = 4;
    localparam integer SRC1_RECORDS = 5;
    localparam integer OUT_RECORDS  = 6;
    localparam integer SRC0_BYTES   = 47;
    localparam integer SRC1_BYTES   = 60;
    localparam integer OUT_BYTES    = 71;

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

    wire       m_record_valid;
    reg        m_record_ready;
    wire [15:0] m_record_key_len;
    wire [15:0] m_record_value_len;
    wire [7:0] m_axis_tdata;
    wire [0:0] m_axis_tkeep;
    wire       m_axis_tlast;
    wire       m_axis_tvalid;
    reg        m_axis_tready;

    wire       busy;
    wire       done;
    wire       error;
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

    reg [15:0] exp_key_len [0:OUT_RECORDS-1];
    reg [15:0] exp_val_len [0:OUT_RECORDS-1];
    reg [31:0] exp_offset  [0:OUT_RECORDS-1];
    reg [31:0] exp_total   [0:OUT_RECORDS-1];
    reg [7:0]  exp_payload [0:OUT_BYTES-1];

    integer i;
    integer out_record_index;
    integer out_payload_index;
    integer src0_rec_index;
    integer src0_byte_index;
    integer src1_rec_index;
    integer src1_byte_index;
    reg     src0_in_payload;
    reg     src1_in_payload;

    real_internal_key_two_way_merge_decoder #(
        .MAX_USER_KEY_BYTES(256),
        .MAX_KEY_BYTES(264),
        .MAX_VALUE_BYTES(1024),
        .MAX_RECORD_BYTES(2048)
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
        .last_record_keep(last_record_keep),
        .final_prev_user_key_valid(),
        .final_prev_user_key_len(),
        .final_prev_user_key()
    );

    always #5 clk = ~clk;

    task automatic drive_source0;
        integer rec_idx;
        integer byte_idx;
        begin
            source0_done      = 1'b0;
            s0_record_valid   = 1'b0;
            s0_record_key_len = 16'd0;
            s0_record_value_len = 16'd0;
            s0_axis_tdata     = 8'd0;
            s0_axis_tkeep     = 1'b1;
            s0_axis_tlast     = 1'b0;
            s0_axis_tvalid    = 1'b0;
            src0_rec_index    = 0;
            src0_byte_index   = 0;
            src0_in_payload   = 1'b0;
            wait (busy);
            for (rec_idx = 0; rec_idx < SRC0_RECORDS; rec_idx = rec_idx + 1) begin
                src0_rec_index    = rec_idx;
                src0_in_payload   = 1'b0;
                @(negedge clk);
                s0_record_key_len = src0_key_len[rec_idx];
                s0_record_value_len = src0_val_len[rec_idx];
                s0_record_valid   = 1'b1;
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
                    s0_axis_tdata   = src0_payload[src0_offset[rec_idx] + byte_idx];
                    s0_axis_tlast   = (byte_idx + 1 == src0_total[rec_idx]);
                    s0_axis_tvalid  = 1'b1;
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
            source0_done   = 1'b1;
            @(posedge clk);
            @(negedge clk);
            source0_done   = 1'b0;
        end
    endtask

    task automatic drive_source1;
        integer rec_idx;
        integer byte_idx;
        begin
            source1_done      = 1'b0;
            s1_record_valid   = 1'b0;
            s1_record_key_len = 16'd0;
            s1_record_value_len = 16'd0;
            s1_axis_tdata     = 8'd0;
            s1_axis_tkeep     = 1'b1;
            s1_axis_tlast     = 1'b0;
            s1_axis_tvalid    = 1'b0;
            src1_rec_index    = 0;
            src1_byte_index   = 0;
            src1_in_payload   = 1'b0;
            wait (busy);
            for (rec_idx = 0; rec_idx < SRC1_RECORDS; rec_idx = rec_idx + 1) begin
                src1_rec_index    = rec_idx;
                src1_in_payload   = 1'b0;
                @(negedge clk);
                s1_record_key_len = src1_key_len[rec_idx];
                s1_record_value_len = src1_val_len[rec_idx];
                s1_record_valid   = 1'b1;
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
                    s1_axis_tdata   = src1_payload[src1_offset[rec_idx] + byte_idx];
                    s1_axis_tlast   = (byte_idx + 1 == src1_total[rec_idx]);
                    s1_axis_tvalid  = 1'b1;
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
            source1_done   = 1'b1;
            @(posedge clk);
            @(negedge clk);
            source1_done   = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (!rstn || clear) begin
            out_record_index  <= 0;
            out_payload_index <= 0;
        end else begin
            if (m_record_valid && m_record_ready) begin
                if (out_record_index >= OUT_RECORDS) begin
                    $display("unexpected extra output header");
                    $finish_and_return(1);
                end
                if (m_record_key_len !== exp_key_len[out_record_index]) begin
                    $display("output key_len mismatch rec=%0d got=%0d exp=%0d", out_record_index, m_record_key_len, exp_key_len[out_record_index]);
                    $finish_and_return(1);
                end
                if (m_record_value_len !== exp_val_len[out_record_index]) begin
                    $display("output value_len mismatch rec=%0d got=%0d exp=%0d", out_record_index, m_record_value_len, exp_val_len[out_record_index]);
                    $finish_and_return(1);
                end
                out_payload_index <= 0;
            end

            if (m_axis_tvalid && m_axis_tready) begin
                if (out_record_index >= OUT_RECORDS) begin
                    $display("unexpected extra output payload");
                    $finish_and_return(1);
                end
                if (m_axis_tdata !== exp_payload[exp_offset[out_record_index] + out_payload_index]) begin
                    $display("output payload mismatch rec=%0d byte=%0d got=%02x exp=%02x",
                             out_record_index,
                             out_payload_index,
                             m_axis_tdata,
                             exp_payload[exp_offset[out_record_index] + out_payload_index]);
                    $finish_and_return(1);
                end
                if (m_axis_tkeep !== 1'b1) begin
                    $display("unexpected tkeep rec=%0d byte=%0d", out_record_index, out_payload_index);
                    $finish_and_return(1);
                end
                if (out_payload_index + 1 == exp_total[out_record_index]) begin
                    if (!m_axis_tlast) begin
                        $display("missing tlast rec=%0d", out_record_index);
                        $finish_and_return(1);
                    end
                    out_record_index  <= out_record_index + 1;
                    out_payload_index <= 0;
                end else begin
                    if (m_axis_tlast) begin
                        $display("early tlast rec=%0d byte=%0d", out_record_index, out_payload_index);
                        $finish_and_return(1);
                    end
                    out_payload_index <= out_payload_index + 1;
                end
            end
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
        m_record_ready = 1'b1;
        m_axis_tready  = 1'b1;

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

        for (i = 0; i < OUT_RECORDS; i = i + 1) begin
            exp_key_len[i] = 16'd11;
            exp_val_len[i] = 16'd1;
            exp_offset[i]  = 32'd0;
            exp_total[i]   = 32'd12;
        end
        exp_val_len[3] = 16'd0;
        exp_total[3]   = 32'd11;
        exp_offset[0]  = 32'd0;
        exp_offset[1]  = 32'd12;
        exp_offset[2]  = 32'd24;
        exp_offset[3]  = 32'd36;
        exp_offset[4]  = 32'd47;
        exp_offset[5]  = 32'd59;

        exp_payload[0]  = "a"; exp_payload[1]  = "n"; exp_payload[2]  = "t"; exp_payload[3]  = 8'h01;
        exp_payload[4]  = 8'h64; exp_payload[5]  = 8'h00; exp_payload[6]  = 8'h00; exp_payload[7]  = 8'h00;
        exp_payload[8]  = 8'h00; exp_payload[9]  = 8'h00; exp_payload[10] = 8'h00; exp_payload[11] = "A";
        exp_payload[12] = "b"; exp_payload[13] = "e"; exp_payload[14] = "e"; exp_payload[15] = 8'h01;
        exp_payload[16] = 8'h6e; exp_payload[17] = 8'h00; exp_payload[18] = 8'h00; exp_payload[19] = 8'h00;
        exp_payload[20] = 8'h00; exp_payload[21] = 8'h00; exp_payload[22] = 8'h00; exp_payload[23] = "B";
        exp_payload[24] = "c"; exp_payload[25] = "a"; exp_payload[26] = "t"; exp_payload[27] = 8'h01;
        exp_payload[28] = 8'h61; exp_payload[29] = 8'h00; exp_payload[30] = 8'h00; exp_payload[31] = 8'h00;
        exp_payload[32] = 8'h00; exp_payload[33] = 8'h00; exp_payload[34] = 8'h00; exp_payload[35] = "C";
        exp_payload[36] = "d"; exp_payload[37] = "o"; exp_payload[38] = "g"; exp_payload[39] = 8'h00;
        exp_payload[40] = 8'h5a; exp_payload[41] = 8'h00; exp_payload[42] = 8'h00; exp_payload[43] = 8'h00;
        exp_payload[44] = 8'h00; exp_payload[45] = 8'h00; exp_payload[46] = 8'h00;
        exp_payload[47] = "e"; exp_payload[48] = "e"; exp_payload[49] = "l"; exp_payload[50] = 8'h01;
        exp_payload[51] = 8'h50; exp_payload[52] = 8'h00; exp_payload[53] = 8'h00; exp_payload[54] = 8'h00;
        exp_payload[55] = 8'h00; exp_payload[56] = 8'h00; exp_payload[57] = 8'h00; exp_payload[58] = "E";
        exp_payload[59] = "y"; exp_payload[60] = "a"; exp_payload[61] = "k"; exp_payload[62] = 8'h01;
        exp_payload[63] = 8'h32; exp_payload[64] = 8'h00; exp_payload[65] = 8'h00; exp_payload[66] = 8'h00;
        exp_payload[67] = 8'h00; exp_payload[68] = 8'h00; exp_payload[69] = 8'h00; exp_payload[70] = "Y";

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

        for (i = 0; i < 2000; i = i + 1) begin
            @(posedge clk);
            if (done || error) begin
                i = 2000;
            end
        end

        if (error) begin
            $display("DUT reported error state=%0d src0_rec=%0d src0_byte=%0d src0_in_payload=%0d src1_rec=%0d src1_byte=%0d src1_in_payload=%0d buf0=%0d buf1=%0d sel=%0d cmp=%0d",
                     dut.state,
                     src0_rec_index,
                     src0_byte_index,
                     src0_in_payload,
                     src1_rec_index,
                     src1_byte_index,
                     src1_in_payload,
                     dut.buf_valid0,
                     dut.buf_valid1,
                     dut.selected_source,
                     dut.compare_index);
            $finish_and_return(1);
        end
        if (!done) begin
            $display("timeout waiting for done state=%0d src0_done=%0d src1_done=%0d buf0=%0d buf1=%0d sel=%0d cmp=%0d decoded=%0d kept=%0d dropped=%0d",
                     dut.state,
                     dut.source_done_seen0,
                     dut.source_done_seen1,
                     dut.buf_valid0,
                     dut.buf_valid1,
                     dut.selected_source,
                     dut.compare_index,
                     decoded_record_count,
                     merged_record_count,
                     dropped_superseded_count);
            $finish_and_return(1);
        end
        if (out_record_index != OUT_RECORDS) begin
            $display("output record count mismatch got=%0d exp=%0d", out_record_index, OUT_RECORDS);
            $finish_and_return(1);
        end
        if (decoded_record_count != 32'd9) begin
            $display("decoded_record_count mismatch got=%0d", decoded_record_count);
            $finish_and_return(1);
        end
        if (merged_record_count != 32'd6) begin
            $display("merged_record_count mismatch got=%0d", merged_record_count);
            $finish_and_return(1);
        end
        if (dropped_superseded_count != 32'd3) begin
            $display("dropped_superseded_count mismatch got=%0d", dropped_superseded_count);
            $finish_and_return(1);
        end
        if (value_record_count != 32'd8) begin
            $display("value_record_count mismatch got=%0d", value_record_count);
            $finish_and_return(1);
        end
        if (delete_record_count != 32'd1) begin
            $display("delete_record_count mismatch got=%0d", delete_record_count);
            $finish_and_return(1);
        end
        if (user_key_bytes_total != 32'd27) begin
            $display("user_key_bytes_total mismatch got=%0d", user_key_bytes_total);
            $finish_and_return(1);
        end
        if (value_bytes_total != 32'd8) begin
            $display("value_bytes_total mismatch got=%0d", value_bytes_total);
            $finish_and_return(1);
        end
        if (last_user_key_len != 16'd3) begin
            $display("last_user_key_len mismatch got=%0d", last_user_key_len);
            $finish_and_return(1);
        end
        if (last_sequence != 56'd49) begin
            $display("last_sequence mismatch got=%0d", last_sequence);
            $finish_and_return(1);
        end
        if (last_value_type != 8'd1) begin
            $display("last_value_type mismatch got=%0d", last_value_type);
            $finish_and_return(1);
        end
        if (last_record_keep != 1'b0) begin
            $display("last_record_keep mismatch got=%0d", last_record_keep);
            $finish_and_return(1);
        end

        $display("PASS real_internal_key_two_way_merge_decoder decoded=%0d kept=%0d dropped=%0d",
                 decoded_record_count,
                 merged_record_count,
                 dropped_superseded_count);
        $finish;
    end

endmodule
