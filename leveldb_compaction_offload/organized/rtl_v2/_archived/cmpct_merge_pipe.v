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
`timescale 1ns / 1ps

module real_internal_key_two_way_merge_writeback_top #(
    parameter integer AXI_ADDR_WIDTH      = 64,
    parameter integer AXI_DATA_WIDTH      = 512,
    parameter integer AXI_ID_WIDTH        = 1,
    parameter integer MAX_BURST_LEN       = 16,
    parameter integer MAX_USER_KEY_BYTES  = 256,
    parameter integer MAX_KEY_BYTES       = 264,
    parameter integer MAX_VALUE_BYTES     = 1024,
    parameter integer MAX_RECORD_BYTES    = 2048,
    parameter integer MAX_RECORDS         = 256,
    parameter integer MAX_OUTPUT_BYTES    = 73728
) (
    input  wire                          clk,
    input  wire                          rstn,
    input  wire                          clear,
    input  wire                          start,
    input  wire                          seed_prev_user_key_valid,
    input  wire [15:0]                   seed_prev_user_key_len,
    input  wire [(MAX_USER_KEY_BYTES*8)-1:0] seed_prev_user_key,

    input  wire                          source0_done,
    input  wire                          s0_record_valid,
    output wire                          s0_record_ready,
    input  wire [15:0]                   s0_record_key_len,
    input  wire [15:0]                   s0_record_value_len,
    // OPT-D3/CAP4: 32-bit input from decoder
    input  wire [31:0]                   s0_axis_tdata,
    input  wire [3:0]                    s0_axis_tkeep,
    input  wire                          s0_axis_tlast,
    input  wire                          s0_axis_tvalid,
    output wire                          s0_axis_tready,

    input  wire                          source1_done,
    input  wire                          s1_record_valid,
    output wire                          s1_record_ready,
    input  wire [15:0]                   s1_record_key_len,
    input  wire [15:0]                   s1_record_value_len,
    // OPT-D3/CAP4: 32-bit input from decoder
    input  wire [31:0]                   s1_axis_tdata,
    input  wire [3:0]                    s1_axis_tkeep,
    input  wire                          s1_axis_tlast,
    input  wire                          s1_axis_tvalid,
    output wire                          s1_axis_tready,

    input  wire [AXI_ADDR_WIDTH-1:0]     dst_base_addr,
    output wire                          busy,
    output wire                          done,
    output wire                          error,
    output wire [31:0]                   bytes_written,
    output wire [31:0]                   beats_written,
    output wire [31:0]                   output_byte_count,
    output wire [31:0]                   merge_decoded_record_count,
    output wire [31:0]                   merge_merged_record_count,
    output wire [31:0]                   merge_dropped_superseded_count,
    output wire [31:0]                   merge_value_record_count,
    output wire [31:0]                   merge_delete_record_count,
    output wire [31:0]                   merge_user_key_bytes_total,
    output wire [31:0]                   merge_value_bytes_total,
    output wire [15:0]                   merge_last_user_key_len,
    output wire [55:0]                   merge_last_sequence,
    output wire [7:0]                    merge_last_value_type,
    output wire                          merge_last_record_keep,
    output wire                          final_prev_user_key_valid,
    output wire [15:0]                   final_prev_user_key_len,
    output wire [(MAX_USER_KEY_BYTES*8)-1:0] final_prev_user_key,

    output wire [AXI_ADDR_WIDTH-1:0]     m_axi_awaddr,
    output wire [7:0]                    m_axi_awlen,
    output wire [2:0]                    m_axi_awsize,
    output wire [1:0]                    m_axi_awburst,
    output wire [AXI_ID_WIDTH-1:0]       m_axi_awid,
    output wire                          m_axi_awvalid,
    input  wire                          m_axi_awready,
    output wire [AXI_DATA_WIDTH-1:0]     m_axi_wdata,
    output wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output wire                          m_axi_wlast,
    output wire                          m_axi_wvalid,
    input  wire                          m_axi_wready,
    input  wire [1:0]                    m_axi_bresp,
    input  wire [AXI_ID_WIDTH-1:0]       m_axi_bid,
    input  wire                          m_axi_bvalid,
    output wire                          m_axi_bready
);

    localparam integer AXI_KEEP_WIDTH = AXI_DATA_WIDTH / 8;

    // OPT-W1/CAP4: merger output is 32-bit
    wire [31:0] merge_byte_tdata;
    wire [3:0]  merge_byte_tkeep;
    wire        merge_byte_tlast;
    wire        merge_byte_tvalid;
    wire        merge_byte_tready;

    // Record-stream header signals (not consumed here; m_record_ready tied high
    // so the decoder can immediately proceed from header to payload emission)
    wire        merge_record_valid_nc;
    wire [15:0] merge_record_key_len_nc;
    wire [15:0] merge_record_value_len_nc;

    wire [AXI_DATA_WIDTH-1:0] write_beat_tdata;
    wire [AXI_KEEP_WIDTH-1:0] write_beat_tkeep;
    wire                      write_beat_tlast;
    wire                      write_beat_tvalid;
    wire                      write_beat_tready;

    wire merge_top_busy;
    wire merge_top_done;
    wire merge_top_error;
    wire wr_busy;
    wire wr_done;
    wire wr_error;

    reg merge_byte_tvalid_d;
    reg wr_start_pulse_r;
    reg wr_started;

    real_internal_key_two_way_merge_top #(
        .MAX_USER_KEY_BYTES(MAX_USER_KEY_BYTES),
        .MAX_KEY_BYTES(MAX_KEY_BYTES),
        .MAX_VALUE_BYTES(MAX_VALUE_BYTES),
        .MAX_RECORD_BYTES(MAX_RECORD_BYTES),
        .MAX_RECORDS(MAX_RECORDS),
        .MAX_OUTPUT_BYTES(MAX_OUTPUT_BYTES)
    ) u_real_internal_key_two_way_merge_top (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .seed_prev_user_key_valid(seed_prev_user_key_valid),
        .seed_prev_user_key_len(seed_prev_user_key_len),
        .seed_prev_user_key(seed_prev_user_key),
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
        .busy(merge_top_busy),
        .done(merge_top_done),
        .error(merge_top_error),
        .output_byte_count(output_byte_count),
        .m_record_valid(merge_record_valid_nc),
        .m_record_ready(1'b1),
        .m_record_key_len(merge_record_key_len_nc),
        .m_record_value_len(merge_record_value_len_nc),
        .m_axis_tdata(merge_byte_tdata),
        .m_axis_tkeep(merge_byte_tkeep),
        .m_axis_tlast(merge_byte_tlast),
        .m_axis_tvalid(merge_byte_tvalid),
        .m_axis_tready(merge_byte_tready),
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
        .final_prev_user_key_valid(final_prev_user_key_valid),
        .final_prev_user_key_len(final_prev_user_key_len),
        .final_prev_user_key(final_prev_user_key)
    );

    // OPT-W1/CAP4: pack 32-bit merger output to AXI width
    stream_pack_adapter #(
        .IN_DATA_WIDTH(32),
        .IN_KEEP_WIDTH(4),
        .OUT_DATA_WIDTH(AXI_DATA_WIDTH),
        .OUT_KEEP_WIDTH(AXI_KEEP_WIDTH)
    ) u_stream_pack_adapter (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .s_axis_tdata(merge_byte_tdata),
        .s_axis_tkeep(merge_byte_tkeep),
        .s_axis_tlast(merge_byte_tlast),
        .s_axis_tvalid(merge_byte_tvalid),
        .s_axis_tready(merge_byte_tready),
        .m_axis_tdata(write_beat_tdata),
        .m_axis_tkeep(write_beat_tkeep),
        .m_axis_tlast(write_beat_tlast),
        .m_axis_tvalid(write_beat_tvalid),
        .m_axis_tready(write_beat_tready)
    );

    axi_write_engine #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN)
    ) u_axi_write_engine (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(wr_start_pulse_r),
        .base_addr(dst_base_addr),
        .byte_count(output_byte_count),
        .busy(wr_busy),
        .done(wr_done),
        .error(wr_error),
        .bytes_written(bytes_written),
        .beats_written(beats_written),
        .s_axis_tdata(write_beat_tdata),
        .s_axis_tkeep(write_beat_tkeep),
        .s_axis_tlast(write_beat_tlast),
        .s_axis_tvalid(write_beat_tvalid),
        .s_axis_tready(write_beat_tready),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awid(m_axi_awid),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bid(m_axi_bid),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready)
    );

    always @(posedge clk) begin
        if (!rstn) begin
            merge_byte_tvalid_d <= 1'b0;
            wr_start_pulse_r    <= 1'b0;
            wr_started          <= 1'b0;
        end else if (clear) begin
            merge_byte_tvalid_d <= 1'b0;
            wr_start_pulse_r    <= 1'b0;
            wr_started          <= 1'b0;
        end else begin
            wr_start_pulse_r    <= 1'b0;
            merge_byte_tvalid_d <= merge_byte_tvalid;

            if (start && !busy) begin
                wr_started <= 1'b0;
            end else if (!wr_started && merge_byte_tvalid && !merge_byte_tvalid_d) begin
                wr_start_pulse_r <= 1'b1;
                wr_started       <= 1'b1;
            end
        end
    end

    assign busy  = merge_top_busy | wr_busy;
    assign done  = wr_done;
    assign error = merge_top_error | wr_error;

endmodule
