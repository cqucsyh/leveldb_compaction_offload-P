`timescale 1ns / 1ps

module real_internal_key_two_way_merge_decoder #(
    parameter integer MAX_USER_KEY_BYTES = 256,
    parameter integer MAX_KEY_BYTES      = 264,
    parameter integer MAX_VALUE_BYTES    = 1024,
    parameter integer MAX_RECORD_BYTES   = 2048
) (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire        start,
    input  wire        seed_prev_user_key_valid,
    input  wire [15:0] seed_prev_user_key_len,
    input  wire [(MAX_USER_KEY_BYTES*8)-1:0] seed_prev_user_key,

    input  wire        source0_done,
    input  wire        s0_record_valid,
    output wire        s0_record_ready,
    input  wire [15:0] s0_record_key_len,
    input  wire [15:0] s0_record_value_len,
    input  wire [7:0]  s0_axis_tdata,
    input  wire [0:0]  s0_axis_tkeep,
    input  wire        s0_axis_tlast,
    input  wire        s0_axis_tvalid,
    output wire        s0_axis_tready,

    input  wire        source1_done,
    input  wire        s1_record_valid,
    output wire        s1_record_ready,
    input  wire [15:0] s1_record_key_len,
    input  wire [15:0] s1_record_value_len,
    input  wire [7:0]  s1_axis_tdata,
    input  wire [0:0]  s1_axis_tkeep,
    input  wire        s1_axis_tlast,
    input  wire        s1_axis_tvalid,
    output wire        s1_axis_tready,

    output wire        m_record_valid,
    input  wire        m_record_ready,
    output wire [15:0] m_record_key_len,
    output wire [15:0] m_record_value_len,
    output wire [7:0]  m_axis_tdata,
    output wire [0:0]  m_axis_tkeep,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,

    output reg         busy,
    output reg         done,
    output reg         error,
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
    output reg         last_record_keep,
    output wire        final_prev_user_key_valid,
    output wire [15:0] final_prev_user_key_len,
    output wire [(MAX_USER_KEY_BYTES*8)-1:0] final_prev_user_key
);

    localparam [3:0] ST_IDLE           = 4'd0;
    localparam [3:0] ST_FETCH          = 4'd1;
    localparam [3:0] ST_WAIT0_HEADER   = 4'd2;
    localparam [3:0] ST_CAPTURE0       = 4'd3;
    localparam [3:0] ST_WAIT1_HEADER   = 4'd4;
    localparam [3:0] ST_CAPTURE1       = 4'd5;
    localparam [3:0] ST_COMPARE_INPUTS = 4'd6;
    localparam [3:0] ST_CHECK_KEEP     = 4'd7;
    localparam [3:0] ST_FINALIZE       = 4'd8;
    localparam [3:0] ST_EMIT_HEADER    = 4'd9;
    localparam [3:0] ST_EMIT_PAYLOAD   = 4'd10;

    reg [3:0] state;

    reg       source_done_seen0;
    reg       source_done_seen1;
    reg       buf_valid0;
    reg       buf_valid1;
    reg       have_prev_user_key;
    reg       selected_source;
    reg       keep_selected;

    reg [15:0] prev_user_key_len;
    reg [15:0] compare_index;
    reg [31:0] emit_index;
    reg [31:0] capture_index;

    reg [15:0] key_len0;
    reg [15:0] value_len0;
    reg [15:0] user_key_len0;
    reg [31:0] payload_total0;
    reg [63:0] tag0;

    reg [15:0] key_len1;
    reg [15:0] value_len1;
    reg [15:0] user_key_len1;
    reg [31:0] payload_total1;
    reg [63:0] tag1;

    reg [7:0] prev_user_key_mem [0:MAX_USER_KEY_BYTES-1];
    reg [7:0] user_key_mem0 [0:MAX_USER_KEY_BYTES-1];
    reg [7:0] user_key_mem1 [0:MAX_USER_KEY_BYTES-1];
    reg [7:0] record_mem0 [0:MAX_RECORD_BYTES-1];
    reg [7:0] record_mem1 [0:MAX_RECORD_BYTES-1];

    integer idx;

    wire input_accept0;
    wire payload_accept0;
    wire input_accept1;
    wire payload_accept1;
    wire [15:0] selected_key_len_w;
    wire [15:0] selected_value_len_w;
    wire [15:0] selected_user_key_len_w;
    wire [31:0] selected_payload_total_w;
    wire [63:0] selected_tag_w;
    wire [7:0]  selected_compare_byte_w;
    wire [7:0]  selected_emit_byte_w;

    assign s0_record_ready = busy && !error && (state == ST_WAIT0_HEADER);
    assign s0_axis_tready  = busy && !error && (state == ST_CAPTURE0);
    assign s1_record_ready = busy && !error && (state == ST_WAIT1_HEADER);
    assign s1_axis_tready  = busy && !error && (state == ST_CAPTURE1);

    assign input_accept0   = s0_record_valid && s0_record_ready;
    assign payload_accept0 = s0_axis_tvalid && s0_axis_tready && s0_axis_tkeep[0];
    assign input_accept1   = s1_record_valid && s1_record_ready;
    assign payload_accept1 = s1_axis_tvalid && s1_axis_tready && s1_axis_tkeep[0];

    assign selected_key_len_w      = selected_source ? key_len1 : key_len0;
    assign selected_value_len_w    = selected_source ? value_len1 : value_len0;
    assign selected_user_key_len_w = selected_source ? user_key_len1 : user_key_len0;
    assign selected_payload_total_w = selected_source ? payload_total1 : payload_total0;
    assign selected_tag_w          = selected_source ? tag1 : tag0;
    assign selected_compare_byte_w = selected_source ? user_key_mem1[compare_index] : user_key_mem0[compare_index];
    assign selected_emit_byte_w    = selected_source ? record_mem1[emit_index] : record_mem0[emit_index];

    assign m_record_valid     = busy && !error && (state == ST_EMIT_HEADER);
    assign m_record_key_len   = selected_key_len_w;
    assign m_record_value_len = selected_value_len_w;
    assign m_axis_tdata       = selected_emit_byte_w;
    assign m_axis_tkeep       = 1'b1;
    assign m_axis_tvalid      = busy && !error && (state == ST_EMIT_PAYLOAD);
    assign m_axis_tlast       = (state == ST_EMIT_PAYLOAD) && (emit_index + 32'd1 == selected_payload_total_w);

    assign final_prev_user_key_valid = have_prev_user_key;
    assign final_prev_user_key_len   = prev_user_key_len;

    genvar prev_key_idx;
    generate
        for (prev_key_idx = 0; prev_key_idx < MAX_USER_KEY_BYTES; prev_key_idx = prev_key_idx + 1) begin : gen_final_prev_key
            assign final_prev_user_key[(prev_key_idx*8) +: 8] = prev_user_key_mem[prev_key_idx];
        end
    endgenerate

    always @(posedge clk) begin
        if (!rstn) begin
            busy                     <= 1'b0;
            done                     <= 1'b0;
            error                    <= 1'b0;
            decoded_record_count     <= 32'd0;
            merged_record_count      <= 32'd0;
            dropped_superseded_count <= 32'd0;
            value_record_count       <= 32'd0;
            delete_record_count      <= 32'd0;
            user_key_bytes_total     <= 32'd0;
            value_bytes_total        <= 32'd0;
            last_user_key_len        <= 16'd0;
            last_sequence            <= 56'd0;
            last_value_type          <= 8'd0;
            last_record_keep         <= 1'b0;
            state                    <= ST_IDLE;
            source_done_seen0        <= 1'b0;
            source_done_seen1        <= 1'b0;
            buf_valid0               <= 1'b0;
            buf_valid1               <= 1'b0;
            have_prev_user_key       <= 1'b0;
            selected_source          <= 1'b0;
            keep_selected            <= 1'b0;
            prev_user_key_len        <= 16'd0;
            compare_index            <= 16'd0;
            emit_index               <= 32'd0;
            capture_index            <= 32'd0;
            key_len0                 <= 16'd0;
            value_len0               <= 16'd0;
            user_key_len0            <= 16'd0;
            payload_total0           <= 32'd0;
            tag0                     <= 64'd0;
            key_len1                 <= 16'd0;
            value_len1               <= 16'd0;
            user_key_len1            <= 16'd0;
            payload_total1           <= 32'd0;
            tag1                     <= 64'd0;
            for (idx = 0; idx < MAX_USER_KEY_BYTES; idx = idx + 1) begin
                prev_user_key_mem[idx] <= 8'd0;
                user_key_mem0[idx]     <= 8'd0;
                user_key_mem1[idx]     <= 8'd0;
            end
        end else if (clear) begin
            busy                     <= 1'b0;
            done                     <= 1'b0;
            error                    <= 1'b0;
            decoded_record_count     <= 32'd0;
            merged_record_count      <= 32'd0;
            dropped_superseded_count <= 32'd0;
            value_record_count       <= 32'd0;
            delete_record_count      <= 32'd0;
            user_key_bytes_total     <= 32'd0;
            value_bytes_total        <= 32'd0;
            last_user_key_len        <= 16'd0;
            last_sequence            <= 56'd0;
            last_value_type          <= 8'd0;
            last_record_keep         <= 1'b0;
            state                    <= ST_IDLE;
            source_done_seen0        <= 1'b0;
            source_done_seen1        <= 1'b0;
            buf_valid0               <= 1'b0;
            buf_valid1               <= 1'b0;
            have_prev_user_key       <= 1'b0;
            selected_source          <= 1'b0;
            keep_selected            <= 1'b0;
            prev_user_key_len        <= 16'd0;
            compare_index            <= 16'd0;
            emit_index               <= 32'd0;
            capture_index            <= 32'd0;
            key_len0                 <= 16'd0;
            value_len0               <= 16'd0;
            user_key_len0            <= 16'd0;
            payload_total0           <= 32'd0;
            tag0                     <= 64'd0;
            key_len1                 <= 16'd0;
            value_len1               <= 16'd0;
            user_key_len1            <= 16'd0;
            payload_total1           <= 32'd0;
            tag1                     <= 64'd0;
            for (idx = 0; idx < MAX_USER_KEY_BYTES; idx = idx + 1) begin
                prev_user_key_mem[idx] <= 8'd0;
                user_key_mem0[idx]     <= 8'd0;
                user_key_mem1[idx]     <= 8'd0;
            end
        end else begin
            done <= 1'b0;

            if (source0_done) begin
                source_done_seen0 <= 1'b1;
            end
            if (source1_done) begin
                source_done_seen1 <= 1'b1;
            end

            if (start && !busy) begin
                busy                     <= 1'b1;
                done                     <= 1'b0;
                error                    <= 1'b0;
                decoded_record_count     <= 32'd0;
                merged_record_count      <= 32'd0;
                dropped_superseded_count <= 32'd0;
                value_record_count       <= 32'd0;
                delete_record_count      <= 32'd0;
                user_key_bytes_total     <= 32'd0;
                value_bytes_total        <= 32'd0;
                last_user_key_len        <= 16'd0;
                last_sequence            <= 56'd0;
                last_value_type          <= 8'd0;
                last_record_keep         <= 1'b0;
                state                    <= ST_FETCH;
                source_done_seen0        <= 1'b0;
                source_done_seen1        <= 1'b0;
                buf_valid0               <= 1'b0;
                buf_valid1               <= 1'b0;
                have_prev_user_key       <= seed_prev_user_key_valid;
                selected_source          <= 1'b0;
                keep_selected            <= 1'b0;
                prev_user_key_len        <= seed_prev_user_key_valid ? seed_prev_user_key_len : 16'd0;
                compare_index            <= 16'd0;
                emit_index               <= 32'd0;
                capture_index            <= 32'd0;
                key_len0                 <= 16'd0;
                value_len0               <= 16'd0;
                user_key_len0            <= 16'd0;
                payload_total0           <= 32'd0;
                tag0                     <= 64'd0;
                key_len1                 <= 16'd0;
                value_len1               <= 16'd0;
                user_key_len1            <= 16'd0;
                payload_total1           <= 32'd0;
                tag1                     <= 64'd0;
                for (idx = 0; idx < MAX_USER_KEY_BYTES; idx = idx + 1) begin
                    if (seed_prev_user_key_valid && (idx < seed_prev_user_key_len)) begin
                        prev_user_key_mem[idx] <= seed_prev_user_key[(idx*8) +: 8];
                    end else begin
                        prev_user_key_mem[idx] <= 8'd0;
                    end
                end
            end else if (busy && !error) begin
                case (state)
                    ST_FETCH: begin
                        if (!buf_valid0 && !source_done_seen0) begin
                            state <= ST_WAIT0_HEADER;
                        end else if (!buf_valid1 && !source_done_seen1) begin
                            state <= ST_WAIT1_HEADER;
                        end else if (buf_valid0 || buf_valid1) begin
                            compare_index <= 16'd0;
                            state <= ST_COMPARE_INPUTS;
                        end else begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            error <= 1'b0;
                            state <= ST_IDLE;
                        end
                    end

                    ST_WAIT0_HEADER: begin
                        if (input_accept0) begin
                            if ((s0_record_key_len < 16'd8) ||
                                (s0_record_key_len > MAX_KEY_BYTES[15:0]) ||
                                (s0_record_value_len > MAX_VALUE_BYTES[15:0]) ||
                                ({16'd0, s0_record_key_len} + {16'd0, s0_record_value_len} > MAX_RECORD_BYTES[31:0]) ||
                                (s0_record_key_len - 16'd8 > MAX_USER_KEY_BYTES[15:0])) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                key_len0       <= s0_record_key_len;
                                value_len0     <= s0_record_value_len;
                                user_key_len0  <= s0_record_key_len - 16'd8;
                                payload_total0 <= {16'd0, s0_record_key_len} + {16'd0, s0_record_value_len};
                                tag0           <= 64'd0;
                                capture_index  <= 32'd0;
                                state          <= ST_CAPTURE0;
                            end
                        end else if (source_done_seen0) begin
                            state <= ST_FETCH;
                        end
                    end

                    ST_CAPTURE0: begin
                        if (payload_accept0) begin
                            if (capture_index >= payload_total0) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                record_mem0[capture_index] <= s0_axis_tdata;
                                if (capture_index < {16'd0, user_key_len0}) begin
                                    user_key_mem0[capture_index[15:0]] <= s0_axis_tdata;
                                end else if (capture_index < {16'd0, key_len0}) begin
                                    case (capture_index - {16'd0, user_key_len0})
                                        32'd0: tag0[7:0]   <= s0_axis_tdata;
                                        32'd1: tag0[15:8]  <= s0_axis_tdata;
                                        32'd2: tag0[23:16] <= s0_axis_tdata;
                                        32'd3: tag0[31:24] <= s0_axis_tdata;
                                        32'd4: tag0[39:32] <= s0_axis_tdata;
                                        32'd5: tag0[47:40] <= s0_axis_tdata;
                                        32'd6: tag0[55:48] <= s0_axis_tdata;
                                        default: tag0[63:56] <= s0_axis_tdata;
                                    endcase
                                end

                                if (capture_index + 32'd1 == payload_total0) begin
                                    if (!s0_axis_tlast) begin
                                        busy  <= 1'b0;
                                        error <= 1'b1;
                                        state <= ST_IDLE;
                                    end else begin
                                        buf_valid0 <= 1'b1;
                                        state      <= ST_FETCH;
                                    end
                                end else if (s0_axis_tlast) begin
                                    busy  <= 1'b0;
                                    error <= 1'b1;
                                    state <= ST_IDLE;
                                end else begin
                                    capture_index <= capture_index + 32'd1;
                                end
                            end
                        end
                    end

                    ST_WAIT1_HEADER: begin
                        if (input_accept1) begin
                            if ((s1_record_key_len < 16'd8) ||
                                (s1_record_key_len > MAX_KEY_BYTES[15:0]) ||
                                (s1_record_value_len > MAX_VALUE_BYTES[15:0]) ||
                                ({16'd0, s1_record_key_len} + {16'd0, s1_record_value_len} > MAX_RECORD_BYTES[31:0]) ||
                                (s1_record_key_len - 16'd8 > MAX_USER_KEY_BYTES[15:0])) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                key_len1       <= s1_record_key_len;
                                value_len1     <= s1_record_value_len;
                                user_key_len1  <= s1_record_key_len - 16'd8;
                                payload_total1 <= {16'd0, s1_record_key_len} + {16'd0, s1_record_value_len};
                                tag1           <= 64'd0;
                                capture_index  <= 32'd0;
                                state          <= ST_CAPTURE1;
                            end
                        end else if (source_done_seen1) begin
                            state <= ST_FETCH;
                        end
                    end

                    ST_CAPTURE1: begin
                        if (payload_accept1) begin
                            if (capture_index >= payload_total1) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                record_mem1[capture_index] <= s1_axis_tdata;
                                if (capture_index < {16'd0, user_key_len1}) begin
                                    user_key_mem1[capture_index[15:0]] <= s1_axis_tdata;
                                end else if (capture_index < {16'd0, key_len1}) begin
                                    case (capture_index - {16'd0, user_key_len1})
                                        32'd0: tag1[7:0]   <= s1_axis_tdata;
                                        32'd1: tag1[15:8]  <= s1_axis_tdata;
                                        32'd2: tag1[23:16] <= s1_axis_tdata;
                                        32'd3: tag1[31:24] <= s1_axis_tdata;
                                        32'd4: tag1[39:32] <= s1_axis_tdata;
                                        32'd5: tag1[47:40] <= s1_axis_tdata;
                                        32'd6: tag1[55:48] <= s1_axis_tdata;
                                        default: tag1[63:56] <= s1_axis_tdata;
                                    endcase
                                end

                                if (capture_index + 32'd1 == payload_total1) begin
                                    if (!s1_axis_tlast) begin
                                        busy  <= 1'b0;
                                        error <= 1'b1;
                                        state <= ST_IDLE;
                                    end else begin
                                        buf_valid1 <= 1'b1;
                                        state      <= ST_FETCH;
                                    end
                                end else if (s1_axis_tlast) begin
                                    busy  <= 1'b0;
                                    error <= 1'b1;
                                    state <= ST_IDLE;
                                end else begin
                                    capture_index <= capture_index + 32'd1;
                                end
                            end
                        end
                    end

                    ST_COMPARE_INPUTS: begin
                        if (!buf_valid0) begin
                            selected_source <= 1'b1;
                            compare_index   <= 16'd0;
                            state           <= ST_CHECK_KEEP;
                        end else if (!buf_valid1) begin
                            selected_source <= 1'b0;
                            compare_index   <= 16'd0;
                            state           <= ST_CHECK_KEEP;
                        end else if ((compare_index < user_key_len0) &&
                                     (compare_index < user_key_len1) &&
                                     (user_key_mem0[compare_index] != user_key_mem1[compare_index])) begin
                            selected_source <= (user_key_mem0[compare_index] < user_key_mem1[compare_index]) ? 1'b0 : 1'b1;
                            compare_index   <= 16'd0;
                            state           <= ST_CHECK_KEEP;
                        end else if ((compare_index < user_key_len0) &&
                                     (compare_index < user_key_len1)) begin
                            compare_index <= compare_index + 16'd1;
                        end else if (user_key_len0 != user_key_len1) begin
                            selected_source <= (user_key_len0 < user_key_len1) ? 1'b0 : 1'b1;
                            compare_index   <= 16'd0;
                            state           <= ST_CHECK_KEEP;
                        end else begin
                            selected_source <= (tag0 >= tag1) ? 1'b0 : 1'b1;
                            compare_index   <= 16'd0;
                            state           <= ST_CHECK_KEEP;
                        end
                    end

                    ST_CHECK_KEEP: begin
                        if (!have_prev_user_key) begin
                            keep_selected <= 1'b1;
                            state         <= ST_FINALIZE;
                        end else if (selected_user_key_len_w != prev_user_key_len) begin
                            keep_selected <= 1'b1;
                            state         <= ST_FINALIZE;
                        end else if (compare_index >= selected_user_key_len_w) begin
                            keep_selected <= 1'b0;
                            state         <= ST_FINALIZE;
                        end else if (selected_compare_byte_w != prev_user_key_mem[compare_index]) begin
                            keep_selected <= 1'b1;
                            state         <= ST_FINALIZE;
                        end else begin
                            compare_index <= compare_index + 16'd1;
                        end
                    end

                    ST_FINALIZE: begin
                        decoded_record_count <= decoded_record_count + 32'd1;
                        user_key_bytes_total <= user_key_bytes_total + {16'd0, selected_user_key_len_w};
                        value_bytes_total    <= value_bytes_total + {16'd0, selected_value_len_w};
                        last_user_key_len    <= selected_user_key_len_w;
                        last_sequence        <= selected_tag_w[63:8];
                        last_value_type      <= selected_tag_w[7:0];
                        last_record_keep     <= keep_selected;
                        if (selected_tag_w[7:0] == 8'h00) begin
                            delete_record_count <= delete_record_count + 32'd1;
                        end else begin
                            value_record_count <= value_record_count + 32'd1;
                        end
                        if (keep_selected) begin
                            merged_record_count <= merged_record_count + 32'd1;
                        end else begin
                            dropped_superseded_count <= dropped_superseded_count + 32'd1;
                        end
                        have_prev_user_key <= 1'b1;
                        prev_user_key_len  <= selected_user_key_len_w;
                        for (idx = 0; idx < MAX_USER_KEY_BYTES; idx = idx + 1) begin
                            if (idx < selected_user_key_len_w) begin
                                prev_user_key_mem[idx] <= selected_source ? user_key_mem1[idx] : user_key_mem0[idx];
                            end else begin
                                prev_user_key_mem[idx] <= 8'd0;
                            end
                        end
                        if (keep_selected) begin
                            emit_index <= 32'd0;
                            state      <= ST_EMIT_HEADER;
                        end else begin
                            if (selected_source) begin
                                buf_valid1 <= 1'b0;
                            end else begin
                                buf_valid0 <= 1'b0;
                            end
                            state <= ST_FETCH;
                        end
                    end

                    ST_EMIT_HEADER: begin
                        if (m_record_valid && m_record_ready) begin
                            emit_index <= 32'd0;
                            state      <= ST_EMIT_PAYLOAD;
                        end
                    end

                    ST_EMIT_PAYLOAD: begin
                        if (m_axis_tvalid && m_axis_tready) begin
                            if (emit_index + 32'd1 == selected_payload_total_w) begin
                                if (selected_source) begin
                                    buf_valid1 <= 1'b0;
                                end else begin
                                    buf_valid0 <= 1'b0;
                                end
                                state <= ST_FETCH;
                            end else begin
                                emit_index <= emit_index + 32'd1;
                            end
                        end
                    end

                    default: begin
                        busy  <= 1'b0;
                        error <= 1'b1;
                        state <= ST_IDLE;
                    end
                endcase
            end
        end
    end
endmodule
