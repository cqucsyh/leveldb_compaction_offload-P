`timescale 1ns / 1ps

module pseudo_internal_key_merge_decoder #(
    parameter integer MAX_USER_KEY_BYTES = 64
) (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire        start,
    input  wire [7:0]  s_axis_tdata,
    input  wire [0:0]  s_axis_tkeep,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    output reg         busy,
    output reg         done,
    output reg         error,
    output reg         record_valid,
    output reg         record_keep,
    output reg  [31:0] header_record_count,
    output reg  [31:0] decoded_record_count,
    output reg  [31:0] merged_record_count,
    output reg  [31:0] dropped_superseded_count,
    output reg  [31:0] value_record_count,
    output reg  [31:0] delete_record_count,
    output reg  [31:0] user_key_bytes_total,
    output reg  [31:0] value_bytes_total,
    output reg  [15:0] last_user_key_len,
    output reg  [55:0] last_sequence,
    output reg  [7:0]  last_value_type,
    output reg         last_record_keep
);

    localparam [3:0] ST_MAGIC0     = 4'd0;
    localparam [3:0] ST_MAGIC1     = 4'd1;
    localparam [3:0] ST_MAGIC2     = 4'd2;
    localparam [3:0] ST_MAGIC3     = 4'd3;
    localparam [3:0] ST_COUNT0     = 4'd4;
    localparam [3:0] ST_COUNT1     = 4'd5;
    localparam [3:0] ST_COUNT2     = 4'd6;
    localparam [3:0] ST_COUNT3     = 4'd7;
    localparam [3:0] ST_KEYLEN0    = 4'd8;
    localparam [3:0] ST_KEYLEN1    = 4'd9;
    localparam [3:0] ST_VALLEN0    = 4'd10;
    localparam [3:0] ST_VALLEN1    = 4'd11;
    localparam [3:0] ST_KEY        = 4'd12;
    localparam [3:0] ST_VALUE      = 4'd13;
    localparam [3:0] ST_FINISH_REC = 4'd14;

    reg [3:0]  state;
    reg [15:0] current_key_len;
    reg [15:0] current_value_len;
    reg [15:0] current_user_key_len;
    reg [15:0] key_bytes_remaining;
    reg [15:0] value_bytes_remaining;
    reg [15:0] current_key_index;
    reg [63:0] current_tag;
    reg        pending_record_end_tlast;
    reg        have_prev_user_key;
    reg [15:0] prev_user_key_len;

    reg [7:0] current_user_key_mem [0:MAX_USER_KEY_BYTES-1];
    reg [7:0] prev_user_key_mem    [0:MAX_USER_KEY_BYTES-1];

    wire input_accept;

    reg        fatal_error_now;
    reg        same_user_key_now;
    reg        end_ok_now;
    reg [31:0] decoded_records_next;
    reg [31:0] expected_records_cmp;
    reg [63:0] current_tag_next;
    reg [15:0] current_value_len_next;
    integer idx;
    integer key_cmp_idx;
    integer tag_byte_index;

    assign s_axis_tready = busy && !error && (state != ST_FINISH_REC);
    assign input_accept = s_axis_tvalid && s_axis_tready && s_axis_tkeep[0];

    always @(posedge clk) begin
        if (!rstn) begin
            busy                    <= 1'b0;
            done                    <= 1'b0;
            error                   <= 1'b0;
            record_valid            <= 1'b0;
            record_keep             <= 1'b0;
            header_record_count     <= 32'd0;
            decoded_record_count    <= 32'd0;
            merged_record_count     <= 32'd0;
            dropped_superseded_count <= 32'd0;
            value_record_count      <= 32'd0;
            delete_record_count     <= 32'd0;
            user_key_bytes_total    <= 32'd0;
            value_bytes_total       <= 32'd0;
            last_user_key_len       <= 16'd0;
            last_sequence           <= 56'd0;
            last_value_type         <= 8'd0;
            last_record_keep        <= 1'b0;
            state                   <= ST_MAGIC0;
            current_key_len         <= 16'd0;
            current_value_len       <= 16'd0;
            current_user_key_len    <= 16'd0;
            key_bytes_remaining     <= 16'd0;
            value_bytes_remaining   <= 16'd0;
            current_key_index       <= 16'd0;
            current_tag             <= 64'd0;
            pending_record_end_tlast <= 1'b0;
            have_prev_user_key      <= 1'b0;
            prev_user_key_len       <= 16'd0;
            for (idx = 0; idx < MAX_USER_KEY_BYTES; idx = idx + 1) begin
                current_user_key_mem[idx] <= 8'd0;
                prev_user_key_mem[idx] <= 8'd0;
            end
        end else if (clear) begin
            busy                    <= 1'b0;
            done                    <= 1'b0;
            error                   <= 1'b0;
            record_valid            <= 1'b0;
            record_keep             <= 1'b0;
            header_record_count     <= 32'd0;
            decoded_record_count    <= 32'd0;
            merged_record_count     <= 32'd0;
            dropped_superseded_count <= 32'd0;
            value_record_count      <= 32'd0;
            delete_record_count     <= 32'd0;
            user_key_bytes_total    <= 32'd0;
            value_bytes_total       <= 32'd0;
            last_user_key_len       <= 16'd0;
            last_sequence           <= 56'd0;
            last_value_type         <= 8'd0;
            last_record_keep        <= 1'b0;
            state                   <= ST_MAGIC0;
            current_key_len         <= 16'd0;
            current_value_len       <= 16'd0;
            current_user_key_len    <= 16'd0;
            key_bytes_remaining     <= 16'd0;
            value_bytes_remaining   <= 16'd0;
            current_key_index       <= 16'd0;
            current_tag             <= 64'd0;
            pending_record_end_tlast <= 1'b0;
            have_prev_user_key      <= 1'b0;
            prev_user_key_len       <= 16'd0;
            for (idx = 0; idx < MAX_USER_KEY_BYTES; idx = idx + 1) begin
                current_user_key_mem[idx] <= 8'd0;
                prev_user_key_mem[idx] <= 8'd0;
            end
        end else begin
            record_valid <= 1'b0;
            record_keep  <= 1'b0;

            if (start && !busy) begin
                busy                    <= 1'b1;
                done                    <= 1'b0;
                error                   <= 1'b0;
                record_valid            <= 1'b0;
                record_keep             <= 1'b0;
                header_record_count     <= 32'd0;
                decoded_record_count    <= 32'd0;
                merged_record_count     <= 32'd0;
                dropped_superseded_count <= 32'd0;
                value_record_count      <= 32'd0;
                delete_record_count     <= 32'd0;
                user_key_bytes_total    <= 32'd0;
                value_bytes_total       <= 32'd0;
                last_user_key_len       <= 16'd0;
                last_sequence           <= 56'd0;
                last_value_type         <= 8'd0;
                last_record_keep        <= 1'b0;
                state                   <= ST_MAGIC0;
                current_key_len         <= 16'd0;
                current_value_len       <= 16'd0;
                current_user_key_len    <= 16'd0;
                key_bytes_remaining     <= 16'd0;
                value_bytes_remaining   <= 16'd0;
                current_key_index       <= 16'd0;
                current_tag             <= 64'd0;
                pending_record_end_tlast <= 1'b0;
                have_prev_user_key      <= 1'b0;
                prev_user_key_len       <= 16'd0;
                for (idx = 0; idx < MAX_USER_KEY_BYTES; idx = idx + 1) begin
                    current_user_key_mem[idx] <= 8'd0;
                    prev_user_key_mem[idx] <= 8'd0;
                end
            end else if (busy && (state == ST_FINISH_REC)) begin
                same_user_key_now = have_prev_user_key && (current_user_key_len == prev_user_key_len);
                if (same_user_key_now) begin
                    for (key_cmp_idx = 0; key_cmp_idx < MAX_USER_KEY_BYTES; key_cmp_idx = key_cmp_idx + 1) begin
                        if ((key_cmp_idx < current_user_key_len) &&
                            (current_user_key_mem[key_cmp_idx] != prev_user_key_mem[key_cmp_idx])) begin
                            same_user_key_now = 1'b0;
                        end
                    end
                end

                fatal_error_now = 1'b0;
                decoded_records_next = decoded_record_count + 32'd1;
                expected_records_cmp = header_record_count;
                end_ok_now = 1'b0;

                record_valid <= 1'b1;
                record_keep <= !same_user_key_now;
                last_record_keep <= !same_user_key_now;
                decoded_record_count <= decoded_records_next;
                last_user_key_len <= current_user_key_len;
                last_sequence <= current_tag[63:8];
                last_value_type <= current_tag[7:0];

                if (current_tag[7:0] == 8'h00) begin
                    delete_record_count <= delete_record_count + 32'd1;
                end else begin
                    value_record_count <= value_record_count + 32'd1;
                end

                if (same_user_key_now) begin
                    dropped_superseded_count <= dropped_superseded_count + 32'd1;
                end else begin
                    merged_record_count <= merged_record_count + 32'd1;
                end

                if (decoded_records_next > expected_records_cmp) begin
                    fatal_error_now = 1'b1;
                end

                have_prev_user_key <= 1'b1;
                prev_user_key_len <= current_user_key_len;
                for (idx = 0; idx < MAX_USER_KEY_BYTES; idx = idx + 1) begin
                    if (idx < current_user_key_len) begin
                        prev_user_key_mem[idx] <= current_user_key_mem[idx];
                    end else begin
                        prev_user_key_mem[idx] <= 8'd0;
                    end
                end

                if (pending_record_end_tlast) begin
                    end_ok_now = (decoded_records_next == expected_records_cmp);
                end

                if (fatal_error_now) begin
                    busy  <= 1'b0;
                    done  <= 1'b0;
                    error <= 1'b1;
                end else if (pending_record_end_tlast) begin
                    busy <= 1'b0;
                    if (end_ok_now) begin
                        done  <= 1'b1;
                        error <= 1'b0;
                    end else begin
                        done  <= 1'b0;
                        error <= 1'b1;
                    end
                end else begin
                    state <= ST_KEYLEN0;
                end
            end else if (input_accept && busy) begin
                fatal_error_now = 1'b0;
                expected_records_cmp = header_record_count;
                end_ok_now = 1'b0;
                current_tag_next = current_tag;
                current_value_len_next = current_value_len;
                tag_byte_index = 0;

                case (state)
                    ST_MAGIC0: begin
                        if (s_axis_tdata != 8'h50) begin
                            fatal_error_now = 1'b1;
                        end else begin
                            state <= ST_MAGIC1;
                        end
                    end
                    ST_MAGIC1: begin
                        if (s_axis_tdata != 8'h53) begin
                            fatal_error_now = 1'b1;
                        end else begin
                            state <= ST_MAGIC2;
                        end
                    end
                    ST_MAGIC2: begin
                        if (s_axis_tdata != 8'h54) begin
                            fatal_error_now = 1'b1;
                        end else begin
                            state <= ST_MAGIC3;
                        end
                    end
                    ST_MAGIC3: begin
                        if (s_axis_tdata != 8'h33) begin
                            fatal_error_now = 1'b1;
                        end else begin
                            state <= ST_COUNT0;
                        end
                    end
                    ST_COUNT0: begin
                        header_record_count[7:0] <= s_axis_tdata;
                        state <= ST_COUNT1;
                    end
                    ST_COUNT1: begin
                        header_record_count[15:8] <= s_axis_tdata;
                        state <= ST_COUNT2;
                    end
                    ST_COUNT2: begin
                        header_record_count[23:16] <= s_axis_tdata;
                        state <= ST_COUNT3;
                    end
                    ST_COUNT3: begin
                        header_record_count[31:24] <= s_axis_tdata;
                        expected_records_cmp = {s_axis_tdata, header_record_count[23:0]};
                        if (s_axis_tlast) begin
                            busy <= 1'b0;
                            if (expected_records_cmp == 32'd0) begin
                                done  <= 1'b1;
                                error <= 1'b0;
                            end else begin
                                done  <= 1'b0;
                                error <= 1'b1;
                            end
                        end else begin
                            state <= ST_KEYLEN0;
                        end
                    end
                    ST_KEYLEN0: begin
                        current_key_len[7:0] <= s_axis_tdata;
                        state <= ST_KEYLEN1;
                    end
                    ST_KEYLEN1: begin
                        current_key_len[15:8] <= s_axis_tdata;
                        state <= ST_VALLEN0;
                    end
                    ST_VALLEN0: begin
                        current_value_len[7:0] <= s_axis_tdata;
                        state <= ST_VALLEN1;
                    end
                    ST_VALLEN1: begin
                        current_value_len_next = {s_axis_tdata, current_value_len[7:0]};
                        current_value_len <= current_value_len_next;
                        if (current_key_len < 16'd8) begin
                            fatal_error_now = 1'b1;
                        end else if ((current_key_len - 16'd8) > MAX_USER_KEY_BYTES) begin
                            fatal_error_now = 1'b1;
                        end else begin
                            current_user_key_len <= current_key_len - 16'd8;
                            key_bytes_remaining <= current_key_len;
                            value_bytes_remaining <= current_value_len_next;
                            current_key_index <= 16'd0;
                            current_tag <= 64'd0;
                            pending_record_end_tlast <= 1'b0;
                            for (idx = 0; idx < MAX_USER_KEY_BYTES; idx = idx + 1) begin
                                current_user_key_mem[idx] <= 8'd0;
                            end
                            state <= ST_KEY;
                        end
                    end
                    ST_KEY: begin
                        if (key_bytes_remaining == 16'd0) begin
                            fatal_error_now = 1'b1;
                        end else begin
                            if (current_key_index < current_user_key_len) begin
                                current_user_key_mem[current_key_index] <= s_axis_tdata;
                                user_key_bytes_total <= user_key_bytes_total + 32'd1;
                            end else begin
                                tag_byte_index = current_key_index - current_user_key_len;
                                current_tag_next[tag_byte_index*8 +: 8] = s_axis_tdata;
                                current_tag <= current_tag_next;
                            end

                            if (key_bytes_remaining == 16'd1) begin
                                if (current_tag_next[7:0] > 8'h01) begin
                                    fatal_error_now = 1'b1;
                                end else if ((current_tag_next[7:0] == 8'h00) && (current_value_len != 16'd0)) begin
                                    fatal_error_now = 1'b1;
                                end else if (current_value_len == 16'd0) begin
                                    pending_record_end_tlast <= s_axis_tlast;
                                    state <= ST_FINISH_REC;
                                end else begin
                                    state <= ST_VALUE;
                                end
                            end

                            key_bytes_remaining <= key_bytes_remaining - 16'd1;
                            current_key_index <= current_key_index + 16'd1;
                        end
                    end
                    ST_VALUE: begin
                        if (value_bytes_remaining == 16'd0) begin
                            fatal_error_now = 1'b1;
                        end else begin
                            value_bytes_total <= value_bytes_total + 32'd1;
                            if (value_bytes_remaining == 16'd1) begin
                                value_bytes_remaining <= 16'd0;
                                pending_record_end_tlast <= s_axis_tlast;
                                state <= ST_FINISH_REC;
                            end else begin
                                value_bytes_remaining <= value_bytes_remaining - 16'd1;
                            end
                        end
                    end
                    default: begin
                        fatal_error_now = 1'b1;
                    end
                endcase

                if (fatal_error_now) begin
                    busy  <= 1'b0;
                    done  <= 1'b0;
                    error <= 1'b1;
                end
            end
        end
    end

endmodule
