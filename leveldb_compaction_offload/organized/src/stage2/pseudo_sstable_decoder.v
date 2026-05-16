`timescale 1ns / 1ps

module pseudo_sstable_decoder (
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
    output reg  [31:0] header_record_count,
    output reg  [31:0] decoded_record_count,
    output reg  [31:0] put_record_count,
    output reg  [31:0] delete_record_count,
    output reg  [31:0] key_bytes_total,
    output reg  [31:0] value_bytes_total,
    output reg  [15:0] last_key_len,
    output reg  [15:0] last_value_len,
    output reg         last_record_delete
);

    localparam [3:0] ST_MAGIC0 = 4'd0;
    localparam [3:0] ST_MAGIC1 = 4'd1;
    localparam [3:0] ST_MAGIC2 = 4'd2;
    localparam [3:0] ST_MAGIC3 = 4'd3;
    localparam [3:0] ST_COUNT0 = 4'd4;
    localparam [3:0] ST_COUNT1 = 4'd5;
    localparam [3:0] ST_COUNT2 = 4'd6;
    localparam [3:0] ST_COUNT3 = 4'd7;
    localparam [3:0] ST_KEYLEN0 = 4'd8;
    localparam [3:0] ST_KEYLEN1 = 4'd9;
    localparam [3:0] ST_VALLEN0 = 4'd10;
    localparam [3:0] ST_VALLEN1 = 4'd11;
    localparam [3:0] ST_TYPE = 4'd12;
    localparam [3:0] ST_KEY = 4'd13;
    localparam [3:0] ST_VALUE = 4'd14;

    reg [3:0]  state;
    reg [15:0] current_key_len;
    reg [15:0] current_value_len;
    reg [15:0] key_bytes_remaining;
    reg [15:0] value_bytes_remaining;
    reg        current_delete;

    reg        record_complete_now;
    reg        fatal_error_now;
    reg [31:0] decoded_records_next;
    reg [31:0] expected_records_cmp;
    reg        end_ok_now;

    wire input_accept;

    assign s_axis_tready = busy && !error;
    assign input_accept = s_axis_tvalid && s_axis_tready && s_axis_tkeep[0];

    always @(posedge clk) begin
        if (!rstn) begin
            busy                <= 1'b0;
            done                <= 1'b0;
            error               <= 1'b0;
            record_valid        <= 1'b0;
            header_record_count <= 32'd0;
            decoded_record_count <= 32'd0;
            put_record_count    <= 32'd0;
            delete_record_count <= 32'd0;
            key_bytes_total     <= 32'd0;
            value_bytes_total   <= 32'd0;
            last_key_len        <= 16'd0;
            last_value_len      <= 16'd0;
            last_record_delete  <= 1'b0;
            state               <= ST_MAGIC0;
            current_key_len     <= 16'd0;
            current_value_len   <= 16'd0;
            key_bytes_remaining <= 16'd0;
            value_bytes_remaining <= 16'd0;
            current_delete      <= 1'b0;
        end else if (clear) begin
            busy                <= 1'b0;
            done                <= 1'b0;
            error               <= 1'b0;
            record_valid        <= 1'b0;
            header_record_count <= 32'd0;
            decoded_record_count <= 32'd0;
            put_record_count    <= 32'd0;
            delete_record_count <= 32'd0;
            key_bytes_total     <= 32'd0;
            value_bytes_total   <= 32'd0;
            last_key_len        <= 16'd0;
            last_value_len      <= 16'd0;
            last_record_delete  <= 1'b0;
            state               <= ST_MAGIC0;
            current_key_len     <= 16'd0;
            current_value_len   <= 16'd0;
            key_bytes_remaining <= 16'd0;
            value_bytes_remaining <= 16'd0;
            current_delete      <= 1'b0;
        end else begin
            record_valid <= 1'b0;
            if (start && !busy) begin
                busy                <= 1'b1;
                done                <= 1'b0;
                error               <= 1'b0;
                record_valid        <= 1'b0;
                header_record_count <= 32'd0;
                decoded_record_count <= 32'd0;
                put_record_count    <= 32'd0;
                delete_record_count <= 32'd0;
                key_bytes_total     <= 32'd0;
                value_bytes_total   <= 32'd0;
                last_key_len        <= 16'd0;
                last_value_len      <= 16'd0;
                last_record_delete  <= 1'b0;
                state               <= ST_MAGIC0;
                current_key_len     <= 16'd0;
                current_value_len   <= 16'd0;
                key_bytes_remaining <= 16'd0;
                value_bytes_remaining <= 16'd0;
                current_delete      <= 1'b0;
            end else if (input_accept && busy) begin
                record_complete_now = 1'b0;
                fatal_error_now     = 1'b0;
                decoded_records_next = decoded_record_count;
                expected_records_cmp = header_record_count;
                end_ok_now          = 1'b0;

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
                        if (s_axis_tdata != 8'h42) begin
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
                        state <= ST_KEYLEN0;
                        if (s_axis_tlast) begin
                            end_ok_now = ({s_axis_tdata, header_record_count[23:0]} == 32'd0);
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
                        current_value_len[15:8] <= s_axis_tdata;
                        state <= ST_TYPE;
                    end
                    ST_TYPE: begin
                        if (s_axis_tdata[7:1] != 7'd0) begin
                            fatal_error_now = 1'b1;
                        end else if (s_axis_tdata[0] && (current_value_len != 16'd0)) begin
                            fatal_error_now = 1'b1;
                        end else begin
                            current_delete <= s_axis_tdata[0];
                            key_bytes_remaining <= current_key_len;
                            value_bytes_remaining <= current_value_len;
                            if (current_key_len == 16'd0) begin
                                if (s_axis_tdata[0] || (current_value_len == 16'd0)) begin
                                    record_complete_now = 1'b1;
                                    decoded_records_next = decoded_record_count + 32'd1;
                                    state <= ST_KEYLEN0;
                                end else begin
                                    state <= ST_VALUE;
                                end
                            end else begin
                                state <= ST_KEY;
                            end
                        end
                    end
                    ST_KEY: begin
                        key_bytes_total <= key_bytes_total + 32'd1;
                        if (key_bytes_remaining == 16'd0) begin
                            fatal_error_now = 1'b1;
                        end else if (key_bytes_remaining == 16'd1) begin
                            if (current_delete || (current_value_len == 16'd0)) begin
                                record_complete_now = 1'b1;
                                decoded_records_next = decoded_record_count + 32'd1;
                                state <= ST_KEYLEN0;
                            end else begin
                                state <= ST_VALUE;
                            end
                            key_bytes_remaining <= 16'd0;
                        end else begin
                            key_bytes_remaining <= key_bytes_remaining - 16'd1;
                        end
                    end
                    ST_VALUE: begin
                        value_bytes_total <= value_bytes_total + 32'd1;
                        if (value_bytes_remaining == 16'd0) begin
                            fatal_error_now = 1'b1;
                        end else if (value_bytes_remaining == 16'd1) begin
                            record_complete_now = 1'b1;
                            decoded_records_next = decoded_record_count + 32'd1;
                            value_bytes_remaining <= 16'd0;
                            state <= ST_KEYLEN0;
                        end else begin
                            value_bytes_remaining <= value_bytes_remaining - 16'd1;
                        end
                    end
                    default: begin
                        fatal_error_now = 1'b1;
                    end
                endcase

                if (record_complete_now) begin
                    decoded_record_count <= decoded_records_next;
                    last_key_len <= current_key_len;
                    last_value_len <= current_value_len;
                    last_record_delete <= current_delete;
                    record_valid <= 1'b1;
                    if (current_delete) begin
                        delete_record_count <= delete_record_count + 32'd1;
                    end else begin
                        put_record_count <= put_record_count + 32'd1;
                    end
                    if (decoded_records_next > expected_records_cmp) begin
                        fatal_error_now = 1'b1;
                    end
                    if (s_axis_tlast) begin
                        end_ok_now = (decoded_records_next == expected_records_cmp);
                    end
                end

                if (fatal_error_now) begin
                    busy  <= 1'b0;
                    done  <= 1'b0;
                    error <= 1'b1;
                end else if (s_axis_tlast) begin
                    busy <= 1'b0;
                    if (end_ok_now) begin
                        done  <= 1'b1;
                        error <= 1'b0;
                    end else begin
                        done  <= 1'b0;
                        error <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
