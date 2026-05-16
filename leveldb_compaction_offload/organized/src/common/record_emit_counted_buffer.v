`timescale 1ns / 1ps

module record_emit_counted_buffer #(
    parameter integer MAX_RECORDS      = 256,
    parameter integer MAX_OUTPUT_BYTES = 73728
) (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire        start,
    input  wire        source_done,
    output reg         busy,
    output reg         done,
    output reg         error,
    input  wire        record_valid,
    output wire        record_ready,
    input  wire [15:0] record_key_len,
    input  wire [15:0] record_value_len,
    input  wire [7:0]  s_axis_tdata,
    input  wire [0:0]  s_axis_tkeep,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    output wire [31:0] output_byte_count,
    output wire [7:0]  m_axis_tdata,
    output wire [0:0]  m_axis_tkeep,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready
);

    localparam [2:0] ST_IDLE             = 3'd0;
    localparam [2:0] ST_CAPTURE_HEADER   = 3'd1;
    localparam [2:0] ST_WRITE_HEADER     = 3'd2;
    localparam [2:0] ST_CAPTURE_PAYLOAD  = 3'd3;
    localparam [2:0] ST_OUTPUT           = 3'd4;

    reg [2:0] state;
    (* ram_style = "block" *) reg [7:0] out_mem [0:MAX_OUTPUT_BYTES-1];
    reg [31:0] write_index;
    reg [31:0] read_index;
    reg [31:0] payload_bytes_remaining;
    reg [31:0] record_count;
    reg [15:0] header_key_len_reg;
    reg [15:0] header_value_len_reg;
    reg [31:0] header_payload_total_reg;
    reg [1:0]  header_byte_index;
    reg        source_done_seen;
    reg [7:0]  mem_rd_data_reg;
    reg        mem_rd_valid_reg;
    reg        mem_rd_last_reg;
    reg [7:0]  out_data_reg;
    reg        out_valid_reg;
    reg        out_last_reg;

    wire output_accept;
    wire [31:0] payload_total_w;

    assign payload_total_w = {16'd0, record_key_len} + {16'd0, record_value_len};
    assign record_ready = busy && !error && (state == ST_CAPTURE_HEADER);
    assign s_axis_tready = busy && !error && (state == ST_CAPTURE_PAYLOAD);
    assign output_byte_count = write_index;
    assign m_axis_tdata = out_data_reg;
    assign m_axis_tkeep = 1'b1;
    assign m_axis_tvalid = out_valid_reg;
    assign output_accept = m_axis_tvalid && m_axis_tready;
    assign m_axis_tlast = out_valid_reg && out_last_reg;

    always @(posedge clk) begin
        if (!rstn) begin
            busy                    <= 1'b0;
            done                    <= 1'b0;
            error                   <= 1'b0;
            state                   <= ST_IDLE;
            write_index             <= 32'd0;
            read_index              <= 32'd0;
            payload_bytes_remaining <= 32'd0;
            record_count            <= 32'd0;
            header_key_len_reg      <= 16'd0;
            header_value_len_reg    <= 16'd0;
            header_payload_total_reg <= 32'd0;
            header_byte_index       <= 2'd0;
            source_done_seen        <= 1'b0;
            mem_rd_data_reg         <= 8'd0;
            mem_rd_valid_reg        <= 1'b0;
            mem_rd_last_reg         <= 1'b0;
            out_data_reg            <= 8'd0;
            out_valid_reg           <= 1'b0;
            out_last_reg            <= 1'b0;
        end else if (clear) begin
            busy                    <= 1'b0;
            done                    <= 1'b0;
            error                   <= 1'b0;
            state                   <= ST_IDLE;
            write_index             <= 32'd0;
            read_index              <= 32'd0;
            payload_bytes_remaining <= 32'd0;
            record_count            <= 32'd0;
            header_key_len_reg      <= 16'd0;
            header_value_len_reg    <= 16'd0;
            header_payload_total_reg <= 32'd0;
            header_byte_index       <= 2'd0;
            source_done_seen        <= 1'b0;
            mem_rd_data_reg         <= 8'd0;
            mem_rd_valid_reg        <= 1'b0;
            mem_rd_last_reg         <= 1'b0;
            out_data_reg            <= 8'd0;
            out_valid_reg           <= 1'b0;
            out_last_reg            <= 1'b0;
        end else begin
            done <= 1'b0;
            if (mem_rd_valid_reg && out_valid_reg) begin
                mem_rd_valid_reg <= 1'b0;
            end

            if (start && !busy) begin
                busy                    <= 1'b1;
                done                    <= 1'b0;
                error                   <= 1'b0;
                state                   <= ST_CAPTURE_HEADER;
                write_index             <= 32'd4;
                read_index              <= 32'd0;
                payload_bytes_remaining <= 32'd0;
                record_count            <= 32'd0;
                header_key_len_reg      <= 16'd0;
                header_value_len_reg    <= 16'd0;
                header_payload_total_reg <= 32'd0;
                header_byte_index       <= 2'd0;
                source_done_seen        <= 1'b0;
                mem_rd_data_reg         <= 8'd0;
                mem_rd_valid_reg        <= 1'b0;
                mem_rd_last_reg         <= 1'b0;
                out_data_reg            <= 8'd0;
                out_valid_reg           <= 1'b0;
                out_last_reg            <= 1'b0;
            end else if (busy && !error) begin
                if (source_done) begin
                    source_done_seen <= 1'b1;
                end

                case (state)
                    ST_CAPTURE_HEADER: begin
                        if (record_valid && record_ready) begin
                            if ((record_count >= MAX_RECORDS) || ((write_index + 32'd4 + payload_total_w) > MAX_OUTPUT_BYTES)) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                header_key_len_reg       <= record_key_len;
                                header_value_len_reg     <= record_value_len;
                                header_payload_total_reg <= payload_total_w;
                                header_byte_index        <= 2'd0;
                                state                    <= ST_WRITE_HEADER;
                            end
                        end else if (source_done_seen) begin
                            state      <= ST_OUTPUT;
                            read_index <= 32'd0;
                            mem_rd_valid_reg <= 1'b0;
                            mem_rd_last_reg  <= 1'b0;
                            out_valid_reg <= 1'b0;
                            out_last_reg  <= 1'b0;
                        end
                    end

                    ST_WRITE_HEADER: begin
                        case (header_byte_index)
                            2'd0: out_mem[write_index] <= header_key_len_reg[7:0];
                            2'd1: out_mem[write_index + 32'd1] <= header_key_len_reg[15:8];
                            2'd2: out_mem[write_index + 32'd2] <= header_value_len_reg[7:0];
                            default: out_mem[write_index + 32'd3] <= header_value_len_reg[15:8];
                        endcase

                        if (header_byte_index == 2'd3) begin
                            write_index             <= write_index + 32'd4;
                            payload_bytes_remaining <= header_payload_total_reg;
                            if (header_payload_total_reg == 32'd0) begin
                                record_count <= record_count + 32'd1;
                                state        <= ST_CAPTURE_HEADER;
                            end else begin
                                state <= ST_CAPTURE_PAYLOAD;
                            end
                        end else begin
                            header_byte_index <= header_byte_index + 2'd1;
                        end
                    end

                    ST_CAPTURE_PAYLOAD: begin
                        if (source_done) begin
                            busy  <= 1'b0;
                            error <= 1'b1;
                            state <= ST_IDLE;
                        end else if (s_axis_tvalid && s_axis_tkeep[0] && s_axis_tready) begin
                            if (write_index >= MAX_OUTPUT_BYTES) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else if ((payload_bytes_remaining == 32'd1 && !s_axis_tlast) ||
                                         (payload_bytes_remaining != 32'd1 && s_axis_tlast)) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                out_mem[write_index] <= s_axis_tdata;
                                write_index <= write_index + 32'd1;
                                if (payload_bytes_remaining == 32'd1) begin
                                    payload_bytes_remaining <= 32'd0;
                                    record_count <= record_count + 32'd1;
                                    state <= ST_CAPTURE_HEADER;
                                end else begin
                                    payload_bytes_remaining <= payload_bytes_remaining - 32'd1;
                                end
                            end
                        end
                    end

                    ST_OUTPUT: begin
                        if (output_accept) begin
                            out_valid_reg <= 1'b0;
                            if (out_last_reg) begin
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                read_index <= read_index + 32'd1;
                            end
                        end else if (!out_valid_reg) begin
                            if (mem_rd_valid_reg) begin
                                out_data_reg     <= mem_rd_data_reg;
                                out_last_reg     <= mem_rd_last_reg;
                                out_valid_reg    <= 1'b1;
                                mem_rd_valid_reg <= 1'b0;
                            end else if (read_index < write_index) begin
                                if (read_index < 32'd4) begin
                                    case (read_index[1:0])
                                        2'd0: out_data_reg <= record_count[7:0];
                                        2'd1: out_data_reg <= record_count[15:8];
                                        2'd2: out_data_reg <= record_count[23:16];
                                        default: out_data_reg <= record_count[31:24];
                                    endcase
                                    out_last_reg  <= (read_index + 32'd1 == write_index);
                                    out_valid_reg <= 1'b1;
                                end else begin
                                    mem_rd_data_reg  <= out_mem[read_index];
                                    mem_rd_last_reg  <= (read_index + 32'd1 == write_index);
                                    mem_rd_valid_reg <= 1'b1;
                                end
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
