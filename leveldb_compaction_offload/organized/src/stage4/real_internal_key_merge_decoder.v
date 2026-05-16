`timescale 1ns / 1ps

module real_internal_key_merge_decoder #(
    parameter integer MAX_USER_KEY_BYTES = 256,
    parameter integer MAX_KEY_BYTES      = 264,
    parameter integer MAX_VALUE_BYTES    = 1024,
    parameter integer MAX_RECORD_BYTES   = 2048
) (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire        start,
    input  wire        source_done,
    input  wire        s_record_valid,
    output wire        s_record_ready,
    input  wire [15:0] s_record_key_len,
    input  wire [15:0] s_record_value_len,
    input  wire [7:0]  s_axis_tdata,
    input  wire [0:0]  s_axis_tkeep,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
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
    output reg         last_record_keep
);

    localparam [2:0] ST_IDLE        = 3'd0;
    localparam [2:0] ST_WAIT_HEADER = 3'd1;
    localparam [2:0] ST_CAPTURE     = 3'd2;
    localparam [2:0] ST_COMPARE     = 3'd3;
    localparam [2:0] ST_FINALIZE    = 3'd4;
    localparam [2:0] ST_EMIT_HEADER = 3'd5;
    localparam [2:0] ST_EMIT_PAYLOAD = 3'd6;

    reg [2:0] state;
    reg       source_done_seen;
    reg       have_prev_user_key;
    reg [15:0] prev_user_key_len;
    reg [15:0] current_key_len;
    reg [15:0] current_value_len;
    reg [15:0] current_user_key_len;
    reg [31:0] current_payload_total;
    reg [31:0] capture_index;
    reg [31:0] emit_index;
    reg [15:0] compare_index;
    reg [63:0] current_tag;
    reg        keep_current_record;

    reg [7:0] prev_user_key_mem [0:MAX_USER_KEY_BYTES-1];
    reg [7:0] current_user_key_mem [0:MAX_USER_KEY_BYTES-1];
    reg [7:0] record_mem [0:MAX_RECORD_BYTES-1];

    wire input_accept;
    wire payload_accept;

    integer idx;

    assign s_record_ready = busy && !error && (state == ST_WAIT_HEADER);
    assign s_axis_tready = busy && !error && (state == ST_CAPTURE);
    assign input_accept = s_record_valid && s_record_ready;
    assign payload_accept = s_axis_tvalid && s_axis_tready && s_axis_tkeep[0];

    assign m_record_valid = busy && !error && (state == ST_EMIT_HEADER);
    assign m_record_key_len = current_key_len;
    assign m_record_value_len = current_value_len;
    assign m_axis_tdata = record_mem[emit_index];
    assign m_axis_tkeep = 1'b1;
    assign m_axis_tvalid = busy && !error && (state == ST_EMIT_PAYLOAD);
    assign m_axis_tlast = (state == ST_EMIT_PAYLOAD) && (emit_index + 32'd1 == current_payload_total);

    always @(posedge clk) begin
        if (!rstn) begin
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            decoded_record_count <= 32'd0;
            merged_record_count <= 32'd0;
            dropped_superseded_count <= 32'd0;
            value_record_count <= 32'd0;
            delete_record_count <= 32'd0;
            user_key_bytes_total <= 32'd0;
            value_bytes_total <= 32'd0;
            last_user_key_len <= 16'd0;
            last_sequence <= 56'd0;
            last_value_type <= 8'd0;
            last_record_keep <= 1'b0;
            state <= ST_IDLE;
            source_done_seen <= 1'b0;
            have_prev_user_key <= 1'b0;
            prev_user_key_len <= 16'd0;
            current_key_len <= 16'd0;
            current_value_len <= 16'd0;
            current_user_key_len <= 16'd0;
            current_payload_total <= 32'd0;
            capture_index <= 32'd0;
            emit_index <= 32'd0;
            compare_index <= 16'd0;
            current_tag <= 64'd0;
            keep_current_record <= 1'b0;
            for (idx = 0; idx < MAX_USER_KEY_BYTES; idx = idx + 1) begin
                prev_user_key_mem[idx] <= 8'd0;
                current_user_key_mem[idx] <= 8'd0;
            end
            for (idx = 0; idx < MAX_RECORD_BYTES; idx = idx + 1) begin
                record_mem[idx] <= 8'd0;
            end
        end else if (clear) begin
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            decoded_record_count <= 32'd0;
            merged_record_count <= 32'd0;
            dropped_superseded_count <= 32'd0;
            value_record_count <= 32'd0;
            delete_record_count <= 32'd0;
            user_key_bytes_total <= 32'd0;
            value_bytes_total <= 32'd0;
            last_user_key_len <= 16'd0;
            last_sequence <= 56'd0;
            last_value_type <= 8'd0;
            last_record_keep <= 1'b0;
            state <= ST_IDLE;
            source_done_seen <= 1'b0;
            have_prev_user_key <= 1'b0;
            prev_user_key_len <= 16'd0;
            current_key_len <= 16'd0;
            current_value_len <= 16'd0;
            current_user_key_len <= 16'd0;
            current_payload_total <= 32'd0;
            capture_index <= 32'd0;
            emit_index <= 32'd0;
            compare_index <= 16'd0;
            current_tag <= 64'd0;
            keep_current_record <= 1'b0;
            for (idx = 0; idx < MAX_USER_KEY_BYTES; idx = idx + 1) begin
                prev_user_key_mem[idx] <= 8'd0;
                current_user_key_mem[idx] <= 8'd0;
            end
            for (idx = 0; idx < MAX_RECORD_BYTES; idx = idx + 1) begin
                record_mem[idx] <= 8'd0;
            end
        end else begin
            done <= 1'b0;

            if (source_done) begin
                source_done_seen <= 1'b1;
            end

            if (start && !busy) begin
                busy <= 1'b1;
                done <= 1'b0;
                error <= 1'b0;
                decoded_record_count <= 32'd0;
                merged_record_count <= 32'd0;
                dropped_superseded_count <= 32'd0;
                value_record_count <= 32'd0;
                delete_record_count <= 32'd0;
                user_key_bytes_total <= 32'd0;
                value_bytes_total <= 32'd0;
                last_user_key_len <= 16'd0;
                last_sequence <= 56'd0;
                last_value_type <= 8'd0;
                last_record_keep <= 1'b0;
                state <= ST_WAIT_HEADER;
                source_done_seen <= 1'b0;
                have_prev_user_key <= 1'b0;
                prev_user_key_len <= 16'd0;
                current_key_len <= 16'd0;
                current_value_len <= 16'd0;
                current_user_key_len <= 16'd0;
                current_payload_total <= 32'd0;
                capture_index <= 32'd0;
                emit_index <= 32'd0;
                compare_index <= 16'd0;
                current_tag <= 64'd0;
                keep_current_record <= 1'b0;
            end else if (busy && !error) begin
                case (state)
                    ST_WAIT_HEADER: begin
                        if (input_accept) begin
                            if ((s_record_key_len < 16'd8) ||
                                (s_record_key_len > MAX_KEY_BYTES[15:0]) ||
                                (s_record_value_len > MAX_VALUE_BYTES[15:0]) ||
                                ({16'd0, s_record_key_len} + {16'd0, s_record_value_len} > MAX_RECORD_BYTES[31:0]) ||
                                (s_record_key_len - 16'd8 > MAX_USER_KEY_BYTES[15:0])) begin
                                busy <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                current_key_len <= s_record_key_len;
                                current_value_len <= s_record_value_len;
                                current_user_key_len <= s_record_key_len - 16'd8;
                                current_payload_total <= {16'd0, s_record_key_len} + {16'd0, s_record_value_len};
                                capture_index <= 32'd0;
                                emit_index <= 32'd0;
                                compare_index <= 16'd0;
                                current_tag <= 64'd0;
                                keep_current_record <= 1'b0;
                                state <= ST_CAPTURE;
                            end
                        end else if (source_done_seen) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            error <= 1'b0;
                            state <= ST_IDLE;
                        end
                    end

                    ST_CAPTURE: begin
                        if (payload_accept) begin
                            if (capture_index >= current_payload_total) begin
                                busy <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                record_mem[capture_index] <= s_axis_tdata;
                                if (capture_index < {16'd0, current_user_key_len}) begin
                                    current_user_key_mem[capture_index[15:0]] <= s_axis_tdata;
                                end else if (capture_index < {16'd0, current_key_len}) begin
                                    case (capture_index - {16'd0, current_user_key_len})
                                        32'd0: current_tag[7:0] <= s_axis_tdata;
                                        32'd1: current_tag[15:8] <= s_axis_tdata;
                                        32'd2: current_tag[23:16] <= s_axis_tdata;
                                        32'd3: current_tag[31:24] <= s_axis_tdata;
                                        32'd4: current_tag[39:32] <= s_axis_tdata;
                                        32'd5: current_tag[47:40] <= s_axis_tdata;
                                        32'd6: current_tag[55:48] <= s_axis_tdata;
                                        default: current_tag[63:56] <= s_axis_tdata;
                                    endcase
                                end

                                if (capture_index + 32'd1 == current_payload_total) begin
                                    if (!s_axis_tlast) begin
                                        busy <= 1'b0;
                                        error <= 1'b1;
                                        state <= ST_IDLE;
                                    end else begin
                                        compare_index <= 16'd0;
                                        state <= ST_COMPARE;
                                    end
                                end else if (s_axis_tlast) begin
                                    busy <= 1'b0;
                                    error <= 1'b1;
                                    state <= ST_IDLE;
                                end else begin
                                    capture_index <= capture_index + 32'd1;
                                end
                            end
                        end
                    end

                    ST_COMPARE: begin
                        if (!have_prev_user_key) begin
                            keep_current_record <= 1'b1;
                            state <= ST_FINALIZE;
                        end else if (current_user_key_len != prev_user_key_len) begin
                            keep_current_record <= 1'b1;
                            state <= ST_FINALIZE;
                        end else if (compare_index >= current_user_key_len) begin
                            keep_current_record <= 1'b0;
                            state <= ST_FINALIZE;
                        end else if (current_user_key_mem[compare_index] != prev_user_key_mem[compare_index]) begin
                            keep_current_record <= 1'b1;
                            state <= ST_FINALIZE;
                        end else begin
                            compare_index <= compare_index + 16'd1;
                        end
                    end

                    ST_FINALIZE: begin
                        decoded_record_count <= decoded_record_count + 32'd1;
                        user_key_bytes_total <= user_key_bytes_total + {16'd0, current_user_key_len};
                        value_bytes_total <= value_bytes_total + {16'd0, current_value_len};
                        last_user_key_len <= current_user_key_len;
                        last_sequence <= current_tag[63:8];
                        last_value_type <= current_tag[7:0];
                        last_record_keep <= keep_current_record;
                        if (current_tag[7:0] == 8'h00) begin
                            delete_record_count <= delete_record_count + 32'd1;
                        end else begin
                            value_record_count <= value_record_count + 32'd1;
                        end
                        if (keep_current_record) begin
                            merged_record_count <= merged_record_count + 32'd1;
                        end else begin
                            dropped_superseded_count <= dropped_superseded_count + 32'd1;
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
                        if (keep_current_record) begin
                            emit_index <= 32'd0;
                            state <= ST_EMIT_HEADER;
                        end else if (source_done_seen) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            error <= 1'b0;
                            state <= ST_IDLE;
                        end else begin
                            state <= ST_WAIT_HEADER;
                        end
                    end

                    ST_EMIT_HEADER: begin
                        if (m_record_valid && m_record_ready) begin
                            emit_index <= 32'd0;
                            state <= ST_EMIT_PAYLOAD;
                        end
                    end

                    ST_EMIT_PAYLOAD: begin
                        if (m_axis_tvalid && m_axis_tready) begin
                            if (emit_index + 32'd1 == current_payload_total) begin
                                if (source_done_seen) begin
                                    busy <= 1'b0;
                                    done <= 1'b1;
                                    error <= 1'b0;
                                    state <= ST_IDLE;
                                end else begin
                                    state <= ST_WAIT_HEADER;
                                end
                            end else begin
                                emit_index <= emit_index + 32'd1;
                            end
                        end
                    end

                    default: begin
                        state <= ST_IDLE;
                    end
                endcase
            end
        end
    end
endmodule
