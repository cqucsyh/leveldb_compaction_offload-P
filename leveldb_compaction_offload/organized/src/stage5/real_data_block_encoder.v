`timescale 1ns / 1ps

module real_data_block_encoder #(
    parameter integer MAX_RECORDS       = 256,
    parameter integer MAX_PAYLOAD_BYTES = 4096,
    parameter integer MAX_BLOCK_BYTES   = 4096,
    parameter integer MAX_KEY_BYTES     = 256,
    parameter integer MAX_VALUE_BYTES   = 1024,
    parameter integer RESTART_INTERVAL  = 16
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
    output wire [7:0]  m_axis_tdata,
    output wire [0:0]  m_axis_tkeep,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         busy,
    output reg         done,
    output reg         error,
    output reg  [31:0] input_record_count,
    output reg  [31:0] encoded_entry_count,
    output reg  [31:0] restart_count,
    output reg  [31:0] shared_key_bytes_total,
    output reg  [31:0] unshared_key_bytes_total,
    output reg  [31:0] value_bytes_total,
    output reg  [15:0] last_key_len,
    output reg  [15:0] last_value_len,
    output reg  [15:0] last_shared_bytes,
    output reg  [15:0] last_non_shared_bytes,
    output reg  [31:0] output_block_bytes
);

    localparam [4:0] ST_IDLE                 = 5'd0;
    localparam [4:0] ST_READ_COUNT0          = 5'd1;
    localparam [4:0] ST_READ_COUNT1          = 5'd2;
    localparam [4:0] ST_READ_COUNT2          = 5'd3;
    localparam [4:0] ST_READ_COUNT3          = 5'd4;
    localparam [4:0] ST_READ_KEYLEN0         = 5'd5;
    localparam [4:0] ST_READ_KEYLEN1         = 5'd6;
    localparam [4:0] ST_READ_VALLEN0         = 5'd7;
    localparam [4:0] ST_READ_VALLEN1         = 5'd8;
    localparam [4:0] ST_READ_KEY             = 5'd9;
    localparam [4:0] ST_READ_VALUE           = 5'd10;
    localparam [4:0] ST_PREP_RECORD          = 5'd11;
    localparam [4:0] ST_CALC_SHARED          = 5'd12;
    localparam [4:0] ST_WRITE_SHARED         = 5'd13;
    localparam [4:0] ST_WRITE_UNSHARED       = 5'd14;
    localparam [4:0] ST_WRITE_VALUE_LEN      = 5'd15;
    localparam [4:0] ST_WRITE_KEY            = 5'd16;
    localparam [4:0] ST_WRITE_VALUE          = 5'd17;
    localparam [4:0] ST_APPEND_RESTARTS      = 5'd18;
    localparam [4:0] ST_APPEND_RESTART_COUNT = 5'd19;
    localparam [4:0] ST_OUTPUT               = 5'd20;

    reg [4:0] state;

    reg [7:0]  payload_mem [0:MAX_PAYLOAD_BYTES-1];
    reg [31:0] key_offset_mem [0:MAX_RECORDS-1];
    reg [31:0] value_offset_mem [0:MAX_RECORDS-1];
    reg [15:0] key_len_mem [0:MAX_RECORDS-1];
    reg [15:0] value_len_mem [0:MAX_RECORDS-1];
    reg [31:0] restart_offset_mem [0:MAX_RECORDS-1];
    (* ram_style = "block" *) reg [7:0] block_mem [0:MAX_BLOCK_BYTES-1];

    reg [31:0] expected_record_count;
    reg [31:0] capture_record_index;
    reg [31:0] payload_count;
    reg [15:0] current_key_len;
    reg [15:0] current_value_len;
    reg [15:0] current_bytes_remaining;

    reg [31:0] encode_record_index;
    reg [31:0] entries_since_restart;
    reg [15:0] shared_calc_index;
    reg [15:0] current_shared_len;
    reg [15:0] current_unshared_len;
    reg [2:0]  varint_index;
    reg [31:0] block_write_index;
    reg [15:0] block_copy_index;
    reg [31:0] restart_emit_index;
    reg [1:0]  fixed32_byte_index;
    reg [31:0] output_index;

    wire input_accept;
    wire output_accept;
    wire capture_state;
    wire [2:0] shared_varint_len;
    wire [2:0] unshared_varint_len;
    wire [2:0] value_varint_len;

    function automatic [2:0] varint32_len;
        input [31:0] value;
        begin
            if (value < 32'd128) begin
                varint32_len = 3'd1;
            end else if (value < 32'd16384) begin
                varint32_len = 3'd2;
            end else if (value < 32'd2097152) begin
                varint32_len = 3'd3;
            end else if (value < 32'd268435456) begin
                varint32_len = 3'd4;
            end else begin
                varint32_len = 3'd5;
            end
        end
    endfunction

    function automatic [7:0] varint32_get_byte;
        input [31:0] value;
        input [2:0]  index;
        input [2:0]  total_len;
        reg [31:0] shifted;
        begin
            shifted = value >> (index * 7);
            varint32_get_byte = shifted[6:0];
            if (index + 3'd1 < total_len) begin
                varint32_get_byte = shifted[6:0] | 8'h80;
            end
        end
    endfunction

    function automatic [7:0] fixed32_get_byte;
        input [31:0] value;
        input [1:0]  index;
        begin
            case (index)
                2'd0: fixed32_get_byte = value[7:0];
                2'd1: fixed32_get_byte = value[15:8];
                2'd2: fixed32_get_byte = value[23:16];
                default: fixed32_get_byte = value[31:24];
            endcase
        end
    endfunction

    assign capture_state = (state == ST_READ_COUNT0) ||
                           (state == ST_READ_COUNT1) ||
                           (state == ST_READ_COUNT2) ||
                           (state == ST_READ_COUNT3) ||
                           (state == ST_READ_KEYLEN0) ||
                           (state == ST_READ_KEYLEN1) ||
                           (state == ST_READ_VALLEN0) ||
                           (state == ST_READ_VALLEN1) ||
                           (state == ST_READ_KEY) ||
                           (state == ST_READ_VALUE);

    assign s_axis_tready = busy && !error && capture_state;
    assign input_accept = s_axis_tvalid && s_axis_tready && s_axis_tkeep[0];
    assign output_accept = m_axis_tvalid && m_axis_tready;

    assign shared_varint_len = varint32_len(current_shared_len);
    assign unshared_varint_len = varint32_len(current_unshared_len);
    assign value_varint_len = varint32_len(value_len_mem[encode_record_index]);

    assign m_axis_tdata = block_mem[output_index];
    assign m_axis_tkeep = 1'b1;
    assign m_axis_tvalid = busy && (state == ST_OUTPUT);
    assign m_axis_tlast = (state == ST_OUTPUT) && (output_index + 32'd1 == output_block_bytes);

    always @(posedge clk) begin
        if (!rstn) begin
            busy                   <= 1'b0;
            done                   <= 1'b0;
            error                  <= 1'b0;
            input_record_count     <= 32'd0;
            encoded_entry_count    <= 32'd0;
            restart_count          <= 32'd0;
            shared_key_bytes_total <= 32'd0;
            unshared_key_bytes_total <= 32'd0;
            value_bytes_total      <= 32'd0;
            last_key_len           <= 16'd0;
            last_value_len         <= 16'd0;
            last_shared_bytes      <= 16'd0;
            last_non_shared_bytes  <= 16'd0;
            output_block_bytes     <= 32'd0;
            state                  <= ST_IDLE;
            expected_record_count  <= 32'd0;
            capture_record_index   <= 32'd0;
            payload_count          <= 32'd0;
            current_key_len        <= 16'd0;
            current_value_len      <= 16'd0;
            current_bytes_remaining <= 16'd0;
            encode_record_index    <= 32'd0;
            entries_since_restart  <= 32'd0;
            shared_calc_index      <= 16'd0;
            current_shared_len     <= 16'd0;
            current_unshared_len   <= 16'd0;
            varint_index           <= 3'd0;
            block_write_index      <= 32'd0;
            block_copy_index       <= 16'd0;
            restart_emit_index     <= 32'd0;
            fixed32_byte_index     <= 2'd0;
            output_index           <= 32'd0;
        end else if (clear) begin
            busy                   <= 1'b0;
            done                   <= 1'b0;
            error                  <= 1'b0;
            input_record_count     <= 32'd0;
            encoded_entry_count    <= 32'd0;
            restart_count          <= 32'd0;
            shared_key_bytes_total <= 32'd0;
            unshared_key_bytes_total <= 32'd0;
            value_bytes_total      <= 32'd0;
            last_key_len           <= 16'd0;
            last_value_len         <= 16'd0;
            last_shared_bytes      <= 16'd0;
            last_non_shared_bytes  <= 16'd0;
            output_block_bytes     <= 32'd0;
            state                  <= ST_IDLE;
            expected_record_count  <= 32'd0;
            capture_record_index   <= 32'd0;
            payload_count          <= 32'd0;
            current_key_len        <= 16'd0;
            current_value_len      <= 16'd0;
            current_bytes_remaining <= 16'd0;
            encode_record_index    <= 32'd0;
            entries_since_restart  <= 32'd0;
            shared_calc_index      <= 16'd0;
            current_shared_len     <= 16'd0;
            current_unshared_len   <= 16'd0;
            varint_index           <= 3'd0;
            block_write_index      <= 32'd0;
            block_copy_index       <= 16'd0;
            restart_emit_index     <= 32'd0;
            fixed32_byte_index     <= 2'd0;
            output_index           <= 32'd0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                busy                   <= 1'b1;
                done                   <= 1'b0;
                error                  <= 1'b0;
                input_record_count     <= 32'd0;
                encoded_entry_count    <= 32'd0;
                restart_count          <= 32'd0;
                shared_key_bytes_total <= 32'd0;
                unshared_key_bytes_total <= 32'd0;
                value_bytes_total      <= 32'd0;
                last_key_len           <= 16'd0;
                last_value_len         <= 16'd0;
                last_shared_bytes      <= 16'd0;
                last_non_shared_bytes  <= 16'd0;
                output_block_bytes     <= 32'd0;
                state                  <= ST_READ_COUNT0;
                expected_record_count  <= 32'd0;
                capture_record_index   <= 32'd0;
                payload_count          <= 32'd0;
                current_key_len        <= 16'd0;
                current_value_len      <= 16'd0;
                current_bytes_remaining <= 16'd0;
                encode_record_index    <= 32'd0;
                entries_since_restart  <= 32'd0;
                shared_calc_index      <= 16'd0;
                current_shared_len     <= 16'd0;
                current_unshared_len   <= 16'd0;
                varint_index           <= 3'd0;
                block_write_index      <= 32'd0;
                block_copy_index       <= 16'd0;
                restart_emit_index     <= 32'd0;
                fixed32_byte_index     <= 2'd0;
                output_index           <= 32'd0;
            end else if (busy && !error) begin
                case (state)
                    ST_READ_COUNT0: begin
                        if (input_accept) begin
                            expected_record_count[7:0] <= s_axis_tdata;
                            state <= ST_READ_COUNT1;
                        end
                    end

                    ST_READ_COUNT1: begin
                        if (input_accept) begin
                            expected_record_count[15:8] <= s_axis_tdata;
                            state <= ST_READ_COUNT2;
                        end
                    end

                    ST_READ_COUNT2: begin
                        if (input_accept) begin
                            expected_record_count[23:16] <= s_axis_tdata;
                            state <= ST_READ_COUNT3;
                        end
                    end

                    ST_READ_COUNT3: begin
                        if (input_accept) begin
                            expected_record_count[31:24] <= s_axis_tdata;
                            input_record_count <= {s_axis_tdata, expected_record_count[23:0]};
                            if ({s_axis_tdata, expected_record_count[23:0]} > MAX_RECORDS) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else if ({s_axis_tdata, expected_record_count[23:0]} == 32'd0) begin
                                if (!s_axis_tlast) begin
                                    busy  <= 1'b0;
                                    error <= 1'b1;
                                    state <= ST_IDLE;
                                end else begin
                                    restart_count <= 32'd1;
                                    restart_offset_mem[0] <= 32'd0;
                                    block_write_index <= 32'd0;
                                    restart_emit_index <= 32'd0;
                                    fixed32_byte_index <= 2'd0;
                                    state <= ST_APPEND_RESTARTS;
                                end
                            end else if (s_axis_tlast) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                capture_record_index <= 32'd0;
                                state <= ST_READ_KEYLEN0;
                            end
                        end
                    end

                    ST_READ_KEYLEN0: begin
                        if (input_accept) begin
                            current_key_len[7:0] <= s_axis_tdata;
                            state <= ST_READ_KEYLEN1;
                        end
                    end

                    ST_READ_KEYLEN1: begin
                        if (input_accept) begin
                            current_key_len[15:8] <= s_axis_tdata;
                            state <= ST_READ_VALLEN0;
                        end
                    end

                    ST_READ_VALLEN0: begin
                        if (input_accept) begin
                            current_value_len[7:0] <= s_axis_tdata;
                            state <= ST_READ_VALLEN1;
                        end
                    end

                    ST_READ_VALLEN1: begin
                        if (input_accept) begin
                            current_value_len[15:8] <= s_axis_tdata;
                            key_len_mem[capture_record_index] <= current_key_len;
                            value_len_mem[capture_record_index] <= {s_axis_tdata, current_value_len[7:0]};
                            key_offset_mem[capture_record_index] <= payload_count;
                            if ((current_key_len > MAX_KEY_BYTES) || ({s_axis_tdata, current_value_len[7:0]} > MAX_VALUE_BYTES)) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else if (current_key_len != 16'd0) begin
                                current_bytes_remaining <= current_key_len;
                                state <= ST_READ_KEY;
                            end else begin
                                value_offset_mem[capture_record_index] <= payload_count;
                                if ({s_axis_tdata, current_value_len[7:0]} != 16'd0) begin
                                    current_bytes_remaining <= {s_axis_tdata, current_value_len[7:0]};
                                    state <= ST_READ_VALUE;
                                end else if (capture_record_index + 32'd1 == {s_axis_tdata, expected_record_count[23:0]}) begin
                                    if (!s_axis_tlast) begin
                                        busy  <= 1'b0;
                                        error <= 1'b1;
                                        state <= ST_IDLE;
                                    end else begin
                                        restart_count <= 32'd1;
                                        restart_offset_mem[0] <= 32'd0;
                                        block_write_index <= 32'd0;
                                        encode_record_index <= 32'd0;
                                        entries_since_restart <= 32'd0;
                                        state <= ST_PREP_RECORD;
                                    end
                                end else if (s_axis_tlast) begin
                                    busy  <= 1'b0;
                                    error <= 1'b1;
                                    state <= ST_IDLE;
                                end else begin
                                    capture_record_index <= capture_record_index + 32'd1;
                                    state <= ST_READ_KEYLEN0;
                                end
                            end
                        end
                    end

                    ST_READ_KEY: begin
                        if (input_accept) begin
                            if (payload_count >= MAX_PAYLOAD_BYTES) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else if (s_axis_tlast && (current_bytes_remaining != 16'd1)) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                payload_mem[payload_count] <= s_axis_tdata;
                                payload_count <= payload_count + 32'd1;
                                if (current_bytes_remaining == 16'd1) begin
                                    value_offset_mem[capture_record_index] <= payload_count + 32'd1;
                                    if (current_value_len != 16'd0) begin
                                        current_bytes_remaining <= current_value_len;
                                        state <= ST_READ_VALUE;
                                    end else if (capture_record_index + 32'd1 == expected_record_count) begin
                                        if (!s_axis_tlast) begin
                                            busy  <= 1'b0;
                                            error <= 1'b1;
                                            state <= ST_IDLE;
                                        end else begin
                                            restart_count <= 32'd1;
                                            restart_offset_mem[0] <= 32'd0;
                                            block_write_index <= 32'd0;
                                            encode_record_index <= 32'd0;
                                            entries_since_restart <= 32'd0;
                                            state <= ST_PREP_RECORD;
                                        end
                                    end else if (s_axis_tlast) begin
                                        busy  <= 1'b0;
                                        error <= 1'b1;
                                        state <= ST_IDLE;
                                    end else begin
                                        capture_record_index <= capture_record_index + 32'd1;
                                        state <= ST_READ_KEYLEN0;
                                    end
                                end else begin
                                    current_bytes_remaining <= current_bytes_remaining - 16'd1;
                                end
                            end
                        end
                    end

                    ST_READ_VALUE: begin
                        if (input_accept) begin
                            if (payload_count >= MAX_PAYLOAD_BYTES) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else if (s_axis_tlast && (current_bytes_remaining != 16'd1)) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                payload_mem[payload_count] <= s_axis_tdata;
                                payload_count <= payload_count + 32'd1;
                                if (current_bytes_remaining == 16'd1) begin
                                    if (capture_record_index + 32'd1 == expected_record_count) begin
                                        if (!s_axis_tlast) begin
                                            busy  <= 1'b0;
                                            error <= 1'b1;
                                            state <= ST_IDLE;
                                        end else begin
                                            restart_count <= 32'd1;
                                            restart_offset_mem[0] <= 32'd0;
                                            block_write_index <= 32'd0;
                                            encode_record_index <= 32'd0;
                                            entries_since_restart <= 32'd0;
                                            state <= ST_PREP_RECORD;
                                        end
                                    end else if (s_axis_tlast) begin
                                        busy  <= 1'b0;
                                        error <= 1'b1;
                                        state <= ST_IDLE;
                                    end else begin
                                        capture_record_index <= capture_record_index + 32'd1;
                                        state <= ST_READ_KEYLEN0;
                                    end
                                end else begin
                                    current_bytes_remaining <= current_bytes_remaining - 16'd1;
                                end
                            end
                        end
                    end

                    ST_PREP_RECORD: begin
                        if (encode_record_index >= expected_record_count) begin
                            restart_emit_index <= 32'd0;
                            fixed32_byte_index <= 2'd0;
                            state <= ST_APPEND_RESTARTS;
                        end else if (entries_since_restart == RESTART_INTERVAL) begin
                            restart_offset_mem[restart_count] <= block_write_index;
                            restart_count <= restart_count + 32'd1;
                            entries_since_restart <= 32'd0;
                            current_shared_len <= 16'd0;
                            current_unshared_len <= key_len_mem[encode_record_index];
                            varint_index <= 3'd0;
                            state <= ST_WRITE_SHARED;
                        end else if (encode_record_index == 32'd0) begin
                            current_shared_len <= 16'd0;
                            current_unshared_len <= key_len_mem[encode_record_index];
                            varint_index <= 3'd0;
                            state <= ST_WRITE_SHARED;
                        end else begin
                            shared_calc_index <= 16'd0;
                            current_shared_len <= 16'd0;
                            state <= ST_CALC_SHARED;
                        end
                    end

                    ST_CALC_SHARED: begin
                        if ((shared_calc_index < key_len_mem[encode_record_index]) &&
                            (shared_calc_index < key_len_mem[encode_record_index - 32'd1]) &&
                            (payload_mem[key_offset_mem[encode_record_index] + shared_calc_index] ==
                             payload_mem[key_offset_mem[encode_record_index - 32'd1] + shared_calc_index])) begin
                            shared_calc_index <= shared_calc_index + 16'd1;
                            current_shared_len <= shared_calc_index + 16'd1;
                        end else begin
                            current_unshared_len <= key_len_mem[encode_record_index] - current_shared_len;
                            varint_index <= 3'd0;
                            state <= ST_WRITE_SHARED;
                        end
                    end

                    ST_WRITE_SHARED: begin
                        if (block_write_index >= MAX_BLOCK_BYTES) begin
                            busy  <= 1'b0;
                            error <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            block_mem[block_write_index] <= varint32_get_byte(current_shared_len, varint_index, shared_varint_len);
                            block_write_index <= block_write_index + 32'd1;
                            if (varint_index + 3'd1 >= shared_varint_len) begin
                                varint_index <= 3'd0;
                                state <= ST_WRITE_UNSHARED;
                            end else begin
                                varint_index <= varint_index + 3'd1;
                            end
                        end
                    end

                    ST_WRITE_UNSHARED: begin
                        if (block_write_index >= MAX_BLOCK_BYTES) begin
                            busy  <= 1'b0;
                            error <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            block_mem[block_write_index] <= varint32_get_byte(current_unshared_len, varint_index, unshared_varint_len);
                            block_write_index <= block_write_index + 32'd1;
                            if (varint_index + 3'd1 >= unshared_varint_len) begin
                                varint_index <= 3'd0;
                                state <= ST_WRITE_VALUE_LEN;
                            end else begin
                                varint_index <= varint_index + 3'd1;
                            end
                        end
                    end

                    ST_WRITE_VALUE_LEN: begin
                        if (block_write_index >= MAX_BLOCK_BYTES) begin
                            busy  <= 1'b0;
                            error <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            block_mem[block_write_index] <= varint32_get_byte(value_len_mem[encode_record_index], varint_index, value_varint_len);
                            block_write_index <= block_write_index + 32'd1;
                            if (varint_index + 3'd1 >= value_varint_len) begin
                                block_copy_index <= 16'd0;
                                state <= ST_WRITE_KEY;
                            end else begin
                                varint_index <= varint_index + 3'd1;
                            end
                        end
                    end

                    ST_WRITE_KEY: begin
                        if (block_copy_index < current_unshared_len) begin
                            if (block_write_index >= MAX_BLOCK_BYTES) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                block_mem[block_write_index] <= payload_mem[key_offset_mem[encode_record_index] + current_shared_len + block_copy_index];
                                block_write_index <= block_write_index + 32'd1;
                                block_copy_index <= block_copy_index + 16'd1;
                            end
                        end else begin
                            block_copy_index <= 16'd0;
                            state <= ST_WRITE_VALUE;
                        end
                    end

                    ST_WRITE_VALUE: begin
                        if (block_copy_index < value_len_mem[encode_record_index]) begin
                            if (block_write_index >= MAX_BLOCK_BYTES) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                block_mem[block_write_index] <= payload_mem[value_offset_mem[encode_record_index] + block_copy_index];
                                block_write_index <= block_write_index + 32'd1;
                                block_copy_index <= block_copy_index + 16'd1;
                            end
                        end else begin
                            encoded_entry_count <= encoded_entry_count + 32'd1;
                            shared_key_bytes_total <= shared_key_bytes_total + current_shared_len;
                            unshared_key_bytes_total <= unshared_key_bytes_total + current_unshared_len;
                            value_bytes_total <= value_bytes_total + value_len_mem[encode_record_index];
                            last_key_len <= key_len_mem[encode_record_index];
                            last_value_len <= value_len_mem[encode_record_index];
                            last_shared_bytes <= current_shared_len;
                            last_non_shared_bytes <= current_unshared_len;
                            encode_record_index <= encode_record_index + 32'd1;
                            entries_since_restart <= entries_since_restart + 32'd1;
                            state <= ST_PREP_RECORD;
                        end
                    end

                    ST_APPEND_RESTARTS: begin
                        if (restart_emit_index < restart_count) begin
                            if (block_write_index >= MAX_BLOCK_BYTES) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                block_mem[block_write_index] <= fixed32_get_byte(restart_offset_mem[restart_emit_index], fixed32_byte_index);
                                block_write_index <= block_write_index + 32'd1;
                                if (fixed32_byte_index == 2'd3) begin
                                    fixed32_byte_index <= 2'd0;
                                    restart_emit_index <= restart_emit_index + 32'd1;
                                end else begin
                                    fixed32_byte_index <= fixed32_byte_index + 2'd1;
                                end
                            end
                        end else begin
                            fixed32_byte_index <= 2'd0;
                            state <= ST_APPEND_RESTART_COUNT;
                        end
                    end

                    ST_APPEND_RESTART_COUNT: begin
                        if (block_write_index >= MAX_BLOCK_BYTES) begin
                            busy  <= 1'b0;
                            error <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            block_mem[block_write_index] <= fixed32_get_byte(restart_count, fixed32_byte_index);
                            block_write_index <= block_write_index + 32'd1;
                            if (fixed32_byte_index == 2'd3) begin
                                output_block_bytes <= block_write_index + 32'd1;
                                output_index <= 32'd0;
                                state <= ST_OUTPUT;
                            end else begin
                                fixed32_byte_index <= fixed32_byte_index + 2'd1;
                            end
                        end
                    end

                    ST_OUTPUT: begin
                        if (output_accept) begin
                            if (output_index + 32'd1 == output_block_bytes) begin
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                output_index <= output_index + 32'd1;
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
