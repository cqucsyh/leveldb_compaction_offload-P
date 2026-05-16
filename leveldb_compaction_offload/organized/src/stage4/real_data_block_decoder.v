`timescale 1ns / 1ps

module real_data_block_decoder #(
    parameter integer MAX_BLOCK_BYTES = 4096,
    parameter integer MAX_KEY_BYTES   = 256
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
    output reg  [31:0] decoded_entry_count,
    output reg  [31:0] restart_count,
    output reg  [31:0] restart_entry_count,
    output reg  [31:0] shared_key_bytes_total,
    output reg  [31:0] unshared_key_bytes_total,
    output reg  [31:0] value_bytes_total,
    output reg  [15:0] last_key_len,
    output reg  [15:0] last_value_len,
    output reg  [15:0] last_shared_bytes,
    output reg  [15:0] last_non_shared_bytes,
    output reg  [31:0] restart_array_offset
);

    localparam [3:0] ST_IDLE               = 4'd0;
    localparam [3:0] ST_CAPTURE            = 4'd1;
    localparam [3:0] ST_PREPARE            = 4'd2;
    localparam [3:0] ST_FETCH_FIXED32      = 4'd3;
    localparam [3:0] ST_CONSUME_FIXED32    = 4'd4;
    localparam [3:0] ST_FETCH_SHARED       = 4'd5;
    localparam [3:0] ST_CONSUME_SHARED     = 4'd6;
    localparam [3:0] ST_FETCH_UNSHARED     = 4'd7;
    localparam [3:0] ST_CONSUME_UNSHARED   = 4'd8;
    localparam [3:0] ST_FETCH_VALUE_LEN    = 4'd9;
    localparam [3:0] ST_CONSUME_VALUE_LEN  = 4'd10;
    localparam [3:0] ST_VALIDATE_ENTRY     = 4'd11;
    localparam [3:0] ST_COPY_KEY           = 4'd12;
    localparam [3:0] ST_SKIP_VALUE         = 4'd13;
    localparam [3:0] ST_EMIT_ENTRY         = 4'd14;
    localparam [3:0] ST_BEGIN_RESTART_SCAN = 4'd15;

    localparam       FIXED32_MODE_COUNT  = 1'b0;
    localparam       FIXED32_MODE_OFFSET = 1'b1;

    reg [3:0]  state;
    (* ram_style = "block" *) reg [7:0] block_mem [0:MAX_BLOCK_BYTES-1];
    reg [31:0] capture_count;
    reg [31:0] total_bytes;
    reg [31:0] parse_index;
    reg [31:0] shared_len;
    reg [31:0] unshared_len;
    reg [31:0] value_len;
    reg [31:0] prev_key_len;
    reg [31:0] key_copy_index;
    reg [31:0] value_skip_index;
    reg [31:0] varint_accum;
    reg [5:0]  varint_shift;
    reg [2:0]  varint_bytes;
    reg [31:0] restart_scan_index;
    reg [31:0] restart_prev_offset;
    reg [31:0] fixed32_base_addr;
    reg [31:0] fixed32_accum;
    reg [1:0]  fixed32_byte_index;
    reg        fixed32_mode;
    reg [7:0]  fetched_byte;

    reg [31:0] next_varint_value;
    reg [31:0] next_fixed32_value;

    function [31:0] insert_u8_le;
        input [31:0] accum;
        input [7:0]  byte_val;
        input [1:0]  byte_idx;
        begin
            case (byte_idx)
                2'd0: insert_u8_le = {accum[31:8],  byte_val};
                2'd1: insert_u8_le = {accum[31:16], byte_val, accum[7:0]};
                2'd2: insert_u8_le = {accum[31:24], byte_val, accum[15:0]};
                default: insert_u8_le = {byte_val, accum[23:0]};
            endcase
        end
    endfunction

    assign s_axis_tready = busy && !error && (state == ST_CAPTURE) && (capture_count < MAX_BLOCK_BYTES);

    always @(posedge clk) begin
        if (!rstn) begin
            busy                     <= 1'b0;
            done                     <= 1'b0;
            error                    <= 1'b0;
            record_valid             <= 1'b0;
            decoded_entry_count      <= 32'd0;
            restart_count            <= 32'd0;
            restart_entry_count      <= 32'd0;
            shared_key_bytes_total   <= 32'd0;
            unshared_key_bytes_total <= 32'd0;
            value_bytes_total        <= 32'd0;
            last_key_len             <= 16'd0;
            last_value_len           <= 16'd0;
            last_shared_bytes        <= 16'd0;
            last_non_shared_bytes    <= 16'd0;
            restart_array_offset     <= 32'd0;
            state                    <= ST_IDLE;
            capture_count            <= 32'd0;
            total_bytes              <= 32'd0;
            parse_index              <= 32'd0;
            shared_len               <= 32'd0;
            unshared_len             <= 32'd0;
            value_len                <= 32'd0;
            prev_key_len             <= 32'd0;
            key_copy_index           <= 32'd0;
            value_skip_index         <= 32'd0;
            varint_accum             <= 32'd0;
            varint_shift             <= 6'd0;
            varint_bytes             <= 3'd0;
            restart_scan_index       <= 32'd0;
            restart_prev_offset      <= 32'd0;
            fixed32_base_addr        <= 32'd0;
            fixed32_accum            <= 32'd0;
            fixed32_byte_index       <= 2'd0;
            fixed32_mode             <= FIXED32_MODE_COUNT;
            fetched_byte             <= 8'd0;
        end else if (clear) begin
            busy                     <= 1'b0;
            done                     <= 1'b0;
            error                    <= 1'b0;
            record_valid             <= 1'b0;
            decoded_entry_count      <= 32'd0;
            restart_count            <= 32'd0;
            restart_entry_count      <= 32'd0;
            shared_key_bytes_total   <= 32'd0;
            unshared_key_bytes_total <= 32'd0;
            value_bytes_total        <= 32'd0;
            last_key_len             <= 16'd0;
            last_value_len           <= 16'd0;
            last_shared_bytes        <= 16'd0;
            last_non_shared_bytes    <= 16'd0;
            restart_array_offset     <= 32'd0;
            state                    <= ST_IDLE;
            capture_count            <= 32'd0;
            total_bytes              <= 32'd0;
            parse_index              <= 32'd0;
            shared_len               <= 32'd0;
            unshared_len             <= 32'd0;
            value_len                <= 32'd0;
            prev_key_len             <= 32'd0;
            key_copy_index           <= 32'd0;
            value_skip_index         <= 32'd0;
            varint_accum             <= 32'd0;
            varint_shift             <= 6'd0;
            varint_bytes             <= 3'd0;
            restart_scan_index       <= 32'd0;
            restart_prev_offset      <= 32'd0;
            fixed32_base_addr        <= 32'd0;
            fixed32_accum            <= 32'd0;
            fixed32_byte_index       <= 2'd0;
            fixed32_mode             <= FIXED32_MODE_COUNT;
            fetched_byte             <= 8'd0;
        end else begin
            record_valid <= 1'b0;
            done <= 1'b0;
            next_varint_value = 32'd0;
            next_fixed32_value = 32'd0;

            if (start && !busy) begin
                busy                     <= 1'b1;
                done                     <= 1'b0;
                error                    <= 1'b0;
                record_valid             <= 1'b0;
                decoded_entry_count      <= 32'd0;
                restart_count            <= 32'd0;
                restart_entry_count      <= 32'd0;
                shared_key_bytes_total   <= 32'd0;
                unshared_key_bytes_total <= 32'd0;
                value_bytes_total        <= 32'd0;
                last_key_len             <= 16'd0;
                last_value_len           <= 16'd0;
                last_shared_bytes        <= 16'd0;
                last_non_shared_bytes    <= 16'd0;
                restart_array_offset     <= 32'd0;
                state                    <= ST_CAPTURE;
                capture_count            <= 32'd0;
                total_bytes              <= 32'd0;
                parse_index              <= 32'd0;
                shared_len               <= 32'd0;
                unshared_len             <= 32'd0;
                value_len                <= 32'd0;
                prev_key_len             <= 32'd0;
                key_copy_index           <= 32'd0;
                value_skip_index         <= 32'd0;
                varint_accum             <= 32'd0;
                varint_shift             <= 6'd0;
                varint_bytes             <= 3'd0;
                restart_scan_index       <= 32'd0;
                restart_prev_offset      <= 32'd0;
                fixed32_base_addr        <= 32'd0;
                fixed32_accum            <= 32'd0;
                fixed32_byte_index       <= 2'd0;
                fixed32_mode             <= FIXED32_MODE_COUNT;
                fetched_byte             <= 8'd0;
            end else if (busy && !error) begin
                case (state)
                    ST_CAPTURE: begin
                        if (s_axis_tvalid && s_axis_tkeep[0] && s_axis_tready) begin
                            block_mem[capture_count] <= s_axis_tdata;
                            capture_count <= capture_count + 32'd1;
                            if ((capture_count == (MAX_BLOCK_BYTES - 1)) && !s_axis_tlast) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else if (s_axis_tlast) begin
                                total_bytes <= capture_count + 32'd1;
                                state <= ST_PREPARE;
                            end
                        end
                    end

                    ST_PREPARE: begin
                        if (total_bytes < 32'd8) begin
                            busy  <= 1'b0;
                            error <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            fixed32_base_addr  <= total_bytes - 32'd4;
                            fixed32_accum      <= 32'd0;
                            fixed32_byte_index <= 2'd0;
                            fixed32_mode       <= FIXED32_MODE_COUNT;
                            state              <= ST_FETCH_FIXED32;
                        end
                    end

                    ST_FETCH_FIXED32: begin
                        fetched_byte <= block_mem[fixed32_base_addr + fixed32_byte_index];
                        state <= ST_CONSUME_FIXED32;
                    end

                    ST_CONSUME_FIXED32: begin
                        next_fixed32_value = insert_u8_le(fixed32_accum, fetched_byte, fixed32_byte_index);
                        if (fixed32_byte_index != 2'd3) begin
                            fixed32_accum      <= next_fixed32_value;
                            fixed32_byte_index <= fixed32_byte_index + 2'd1;
                            state              <= ST_FETCH_FIXED32;
                        end else if (fixed32_mode == FIXED32_MODE_COUNT) begin
                            if (next_fixed32_value == 32'd0) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else if (((next_fixed32_value + 32'd1) << 2) > total_bytes) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                restart_count        <= next_fixed32_value;
                                restart_array_offset <= total_bytes - ((next_fixed32_value + 32'd1) << 2);
                                parse_index          <= 32'd0;
                                shared_len           <= 32'd0;
                                unshared_len         <= 32'd0;
                                value_len            <= 32'd0;
                                prev_key_len         <= 32'd0;
                                key_copy_index       <= 32'd0;
                                value_skip_index     <= 32'd0;
                                varint_accum         <= 32'd0;
                                varint_shift         <= 6'd0;
                                varint_bytes         <= 3'd0;
                                restart_scan_index   <= 32'd0;
                                restart_prev_offset  <= 32'd0;
                                state                <= ST_FETCH_SHARED;
                            end
                        end else begin
                            if ((restart_scan_index == 32'd0 && next_fixed32_value != 32'd0) ||
                                (next_fixed32_value >= restart_array_offset) ||
                                (restart_scan_index != 32'd0 && next_fixed32_value <= restart_prev_offset)) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                restart_prev_offset <= next_fixed32_value;
                                restart_scan_index  <= restart_scan_index + 32'd1;
                                state               <= ST_BEGIN_RESTART_SCAN;
                            end
                        end
                    end

                    ST_FETCH_SHARED: begin
                        if (parse_index == restart_array_offset) begin
                            restart_scan_index  <= 32'd0;
                            restart_prev_offset <= 32'd0;
                            state               <= ST_BEGIN_RESTART_SCAN;
                        end else begin
                            fetched_byte <= block_mem[parse_index];
                            parse_index  <= parse_index + 32'd1;
                            state        <= ST_CONSUME_SHARED;
                        end
                    end

                    ST_CONSUME_SHARED: begin
                        if (fetched_byte[7]) begin
                            if ((varint_shift >= 6'd28) || (varint_bytes == 3'd4)) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                varint_accum <= varint_accum | ({25'd0, fetched_byte[6:0]} << varint_shift);
                                varint_shift <= varint_shift + 6'd7;
                                varint_bytes <= varint_bytes + 3'd1;
                                state        <= ST_FETCH_SHARED;
                            end
                        end else begin
                            next_varint_value = varint_accum | ({24'd0, fetched_byte} << varint_shift);
                            shared_len   <= next_varint_value;
                            varint_accum <= 32'd0;
                            varint_shift <= 6'd0;
                            varint_bytes <= 3'd0;
                            state        <= ST_FETCH_UNSHARED;
                        end
                    end

                    ST_FETCH_UNSHARED: begin
                        if (parse_index >= restart_array_offset) begin
                            busy  <= 1'b0;
                            error <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            fetched_byte <= block_mem[parse_index];
                            parse_index  <= parse_index + 32'd1;
                            state        <= ST_CONSUME_UNSHARED;
                        end
                    end

                    ST_CONSUME_UNSHARED: begin
                        if (fetched_byte[7]) begin
                            if ((varint_shift >= 6'd28) || (varint_bytes == 3'd4)) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                varint_accum <= varint_accum | ({25'd0, fetched_byte[6:0]} << varint_shift);
                                varint_shift <= varint_shift + 6'd7;
                                varint_bytes <= varint_bytes + 3'd1;
                                state        <= ST_FETCH_UNSHARED;
                            end
                        end else begin
                            next_varint_value = varint_accum | ({24'd0, fetched_byte} << varint_shift);
                            unshared_len <= next_varint_value;
                            varint_accum <= 32'd0;
                            varint_shift <= 6'd0;
                            varint_bytes <= 3'd0;
                            state        <= ST_FETCH_VALUE_LEN;
                        end
                    end

                    ST_FETCH_VALUE_LEN: begin
                        if (parse_index >= restart_array_offset) begin
                            busy  <= 1'b0;
                            error <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            fetched_byte <= block_mem[parse_index];
                            parse_index  <= parse_index + 32'd1;
                            state        <= ST_CONSUME_VALUE_LEN;
                        end
                    end

                    ST_CONSUME_VALUE_LEN: begin
                        if (fetched_byte[7]) begin
                            if ((varint_shift >= 6'd28) || (varint_bytes == 3'd4)) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                varint_accum <= varint_accum | ({25'd0, fetched_byte[6:0]} << varint_shift);
                                varint_shift <= varint_shift + 6'd7;
                                varint_bytes <= varint_bytes + 3'd1;
                                state        <= ST_FETCH_VALUE_LEN;
                            end
                        end else begin
                            next_varint_value = varint_accum | ({24'd0, fetched_byte} << varint_shift);
                            value_len    <= next_varint_value;
                            varint_accum <= 32'd0;
                            varint_shift <= 6'd0;
                            varint_bytes <= 3'd0;
                            state        <= ST_VALIDATE_ENTRY;
                        end
                    end

                    ST_VALIDATE_ENTRY: begin
                        if ((shared_len > prev_key_len) ||
                            ((shared_len + unshared_len) > MAX_KEY_BYTES) ||
                            ((parse_index + unshared_len + value_len) > restart_array_offset)) begin
                            busy  <= 1'b0;
                            error <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            key_copy_index   <= 32'd0;
                            value_skip_index <= 32'd0;
                            state            <= ST_COPY_KEY;
                        end
                    end

                    ST_COPY_KEY: begin
                        if (key_copy_index < unshared_len) begin
                            parse_index    <= parse_index + 32'd1;
                            key_copy_index <= key_copy_index + 32'd1;
                        end else begin
                            value_skip_index <= 32'd0;
                            state            <= ST_SKIP_VALUE;
                        end
                    end

                    ST_SKIP_VALUE: begin
                        if (value_skip_index < value_len) begin
                            parse_index       <= parse_index + 32'd1;
                            value_skip_index  <= value_skip_index + 32'd1;
                        end else begin
                            state <= ST_EMIT_ENTRY;
                        end
                    end

                    ST_EMIT_ENTRY: begin
                        decoded_entry_count      <= decoded_entry_count + 32'd1;
                        shared_key_bytes_total   <= shared_key_bytes_total + shared_len;
                        unshared_key_bytes_total <= unshared_key_bytes_total + unshared_len;
                        value_bytes_total        <= value_bytes_total + value_len;
                        if (shared_len == 32'd0) begin
                            restart_entry_count <= restart_entry_count + 32'd1;
                        end
                        prev_key_len          <= shared_len + unshared_len;
                        last_key_len          <= shared_len + unshared_len;
                        last_value_len        <= value_len;
                        last_shared_bytes     <= shared_len;
                        last_non_shared_bytes <= unshared_len;
                        record_valid          <= 1'b1;
                        state                 <= ST_FETCH_SHARED;
                    end

                    ST_BEGIN_RESTART_SCAN: begin
                        if (restart_scan_index < restart_count) begin
                            fixed32_base_addr  <= restart_array_offset + (restart_scan_index << 2);
                            fixed32_accum      <= 32'd0;
                            fixed32_byte_index <= 2'd0;
                            fixed32_mode       <= FIXED32_MODE_OFFSET;
                            state              <= ST_FETCH_FIXED32;
                        end else begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= ST_IDLE;
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
