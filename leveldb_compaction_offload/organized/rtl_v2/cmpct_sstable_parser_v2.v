`timescale 1ns / 1ps

// cmpct_sstable_parser (v2 — streaming)
//
// Reads a LevelDB SSTable from DDR, parses the 48-byte footer to locate
// the index block, then parses index-block entries **streaming** — no
// block_mem buffer needed.  This removes the MAX_INDEX_BYTES size limit.
//
// Flow:
//   1. Read footer (128 bytes, 2 AXI beats) — same as v1.
//   2. Decode footer: index_offset, index_size.
//   3. Read restart_count (4 bytes from end of index block, 1 AXI read).
//   4. Compute entries_end = index_size - 4*(restart_count + 1).
//   5. Stream entries_end bytes from index block start, parsing entries
//      on the fly (1 byte per cycle).
//
module cmpct_sstable_parser #(
    parameter integer AXI_ADDR_WIDTH    = 64,
    parameter integer AXI_DATA_WIDTH    = 512,
    parameter integer AXI_ID_WIDTH      = 1,
    parameter integer MAX_BURST_LEN     = 16,
    parameter integer MAX_INDEX_BYTES   = 65536,   // unused in v2 (kept for port compat)
    parameter integer MAX_BLOCK_HANDLES = 256
) (
    input  wire                                         clk,
    input  wire                                         rstn,
    input  wire                                         clear,
    input  wire                                         start,

    input  wire [AXI_ADDR_WIDTH-1:0]                    sstable_base_addr,
    input  wire [31:0]                                  sstable_size,

    output reg                                          busy,
    output reg                                          done,
    output reg                                          error,
    output reg  [31:0]                                  block_handle_count,

    output wire [MAX_BLOCK_HANDLES*AXI_ADDR_WIDTH-1:0]  block_addr_vec,
    output wire [MAX_BLOCK_HANDLES*32-1:0]              block_size_vec,

    // Streaming handle output (one handle per valid/ready beat)
    output wire                                         m_handle_valid,
    input  wire                                         m_handle_ready,
    output wire [AXI_ADDR_WIDTH-1:0]                    m_handle_addr,
    output wire [31:0]                                  m_handle_size,
    output reg                                          all_handles_done,

    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_araddr,
    output wire [7:0]                 m_axi_arlen,
    output wire [2:0]                 m_axi_arsize,
    output wire [1:0]                 m_axi_arburst,
    output wire                       m_axi_arvalid,
    input  wire                       m_axi_arready,
    input  wire [AXI_DATA_WIDTH-1:0]  m_axi_rdata,
    input  wire [1:0]                 m_axi_rresp,
    input  wire                       m_axi_rlast,
    input  wire                       m_axi_rvalid,
    output wire                       m_axi_rready
);

    localparam integer AXI_BEAT_BYTES = AXI_DATA_WIDTH / 8;  // 64
    localparam integer MBH            = MAX_BLOCK_HANDLES;

    // -----------------------------------------------------------------------
    // State encoding (5-bit for 17 states)
    // -----------------------------------------------------------------------
    localparam [4:0] ST_IDLE          = 5'd0;
    localparam [4:0] ST_FOOTER_CLR    = 5'd1;
    localparam [4:0] ST_FOOTER_STR    = 5'd2;
    localparam [4:0] ST_FOOTER_CAP    = 5'd3;
    localparam [4:0] ST_FOOTER_FETCH  = 5'd4;
    localparam [4:0] ST_FOOTER_PARSE  = 5'd5;
    localparam [4:0] ST_INDEX_CLR     = 5'd6;
    localparam [4:0] ST_RCNT_STR      = 5'd7;
    localparam [4:0] ST_RCNT_CAP      = 5'd8;
    localparam [4:0] ST_RCNT_PARSE    = 5'd9;
    localparam [4:0] ST_ENTRY_CLR     = 5'd10;
    localparam [4:0] ST_ENTRY_STR     = 5'd11;
    localparam [4:0] ST_ENTRY_SKIP    = 5'd12;  // skip alignment bytes
    localparam [4:0] ST_PARSE_ENTRY   = 5'd13;
    localparam [4:0] ST_STREAM_SKIP   = 5'd14;  // consume N bytes from stream
    localparam [4:0] ST_DONE          = 5'd15;

    // Footer parse sub-phases
    localparam [1:0] FP_META_OFF  = 2'd0;
    localparam [1:0] FP_META_SIZE = 2'd1;
    localparam [1:0] FP_IDX_OFF   = 2'd2;
    localparam [1:0] FP_IDX_SIZE  = 2'd3;

    // Entry parse sub-states
    localparam [2:0] EP_SHARED_LEN  = 3'd0;
    localparam [2:0] EP_UNSHARED    = 3'd1;
    localparam [2:0] EP_VALUE_LEN   = 3'd2;
    localparam [2:0] EP_SKIP_KEY    = 3'd3;
    localparam [2:0] EP_BLK_OFFSET  = 3'd4;
    localparam [2:0] EP_BLK_SIZE    = 3'd5;
    localparam [2:0] EP_HANDLE_PUSH = 3'd6;

    // -----------------------------------------------------------------------
    // Footer buffer (128 bytes — tiny, kept as reg array)
    // -----------------------------------------------------------------------
    reg [7:0] footer_buf [0:127];

    // -----------------------------------------------------------------------
    // AXI read engine + stream_width_adapter
    // -----------------------------------------------------------------------
    reg                       rd_clear_r;
    reg                       rd_start_r;
    reg [AXI_ADDR_WIDTH-1:0]  rd_base_r;
    reg [31:0]                rd_count_r;

    wire rd_busy, rd_done, rd_error;

    wire [AXI_DATA_WIDTH-1:0]     beat_tdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] beat_tkeep;
    wire                          beat_tlast, beat_tvalid, beat_tready;

    wire [7:0] byte_tdata;
    wire [0:0] byte_tkeep;
    wire       byte_tlast, byte_tvalid, byte_tready;

    axi_read_engine #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),     .MAX_BURST_LEN(MAX_BURST_LEN)
    ) u_rd (
        .clk(clk), .rstn(rstn), .clear(rd_clear_r), .start(rd_start_r),
        .base_addr(rd_base_r), .byte_count(rd_count_r),
        .busy(rd_busy), .done(rd_done), .error(rd_error),
        .bytes_read(), .beats_read(),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),  .m_axi_arburst(m_axi_arburst),
        .m_axi_arid(),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),     .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),     .m_axi_rid({AXI_ID_WIDTH{1'b0}}),
        .m_axi_rvalid(m_axi_rvalid),   .m_axi_rready(m_axi_rready),
        .m_axis_tdata(beat_tdata), .m_axis_tkeep(beat_tkeep),
        .m_axis_tlast(beat_tlast), .m_axis_tvalid(beat_tvalid),
        .m_axis_tready(beat_tready)
    );

    stream_width_adapter #(
        .IN_DATA_WIDTH(AXI_DATA_WIDTH), .IN_KEEP_WIDTH(AXI_DATA_WIDTH/8),
        .OUT_DATA_WIDTH(8), .OUT_KEEP_WIDTH(1)
    ) u_adapt (
        .clk(clk), .rstn(rstn), .clear(rd_clear_r),
        .s_axis_tdata(beat_tdata), .s_axis_tkeep(beat_tkeep),
        .s_axis_tlast(beat_tlast), .s_axis_tvalid(beat_tvalid),
        .s_axis_tready(beat_tready),
        .m_axis_tdata(byte_tdata), .m_axis_tkeep(byte_tkeep),
        .m_axis_tlast(byte_tlast), .m_axis_tvalid(byte_tvalid),
        .m_axis_tready(byte_tready)
    );

    // byte_tready: asserted when FSM is consuming from byte stream
    assign byte_tready = (state == ST_FOOTER_CAP)
                       | (state == ST_RCNT_CAP)
                       | ((state == ST_ENTRY_SKIP) && (r_cap_skip > 32'd0))
                       | (state == ST_STREAM_SKIP)
                       | ((state == ST_PARSE_ENTRY) && (ep_state != EP_HANDLE_PUSH)
                                                    && (ep_state != EP_SKIP_KEY));

    // -----------------------------------------------------------------------
    // FSM registers
    // -----------------------------------------------------------------------
    reg [4:0] state;
    reg [1:0] fp_state;
    reg [2:0] ep_state;

    reg [AXI_ADDR_WIDTH-1:0] r_base;
    reg [31:0]               r_size;

    // Footer read
    reg [AXI_ADDR_WIDTH-1:0] r_footer_rd_base;
    reg [5:0]                r_footer_skip;

    // Capture control
    reg [31:0] r_cap_skip;
    reg [31:0] r_cap_remain;
    reg [31:0] r_cap_wptr;

    // Index read
    reg [AXI_ADDR_WIDTH-1:0] r_idx_rd_base;
    reg [31:0]               r_idx_rd_count;
    reg [31:0]               r_idx_rd_skip;
    reg [31:0]               r_idx_actual;   // index block byte count

    // Decoded footer values
    reg [63:0] r_idx_offset;
    reg [63:0] r_idx_size;

    // Index parse state
    reg [31:0] r_entries_end;
    reg [31:0] r_parse_pos;    // byte position within entries region
    reg [31:0] r_handle_idx;
    reg [31:0] r_skip_count;   // bytes remaining in stream skip

    // Entry fields
    reg [31:0] r_shared_len;
    reg [31:0] r_unshared_len;
    reg [31:0] r_value_len;
    reg [31:0] r_val_used;

    // Current block handle
    reg [63:0] r_blk_off;

    // Shared varint decoder
    reg [63:0] r_va;
    reg [6:0]  r_vs;

    // Footer parse
    reg [7:0] r_fp_pos;

    // Pipeline registers
    reg [7:0] r_rc_b3, r_rc_b2, r_rc_b1, r_rc_b0;
    reg [7:0] r_fetched_ftr_byte;

    // Restart count read
    reg [AXI_ADDR_WIDTH-1:0] r_rcnt_rd_base;
    reg [31:0]               r_rcnt_rd_count;
    reg [31:0]               r_rcnt_skip;
    reg [2:0]                r_rcnt_cap_idx;   // 0..3 bytes captured

    // Return state after stream skip
    reg [4:0]  r_skip_return_state;
    reg [2:0]  r_skip_return_ep;

    // Per-handle scratch
    reg [AXI_ADDR_WIDTH-1:0] r_addr [0:MBH-1];
    reg [31:0]               r_bsz  [0:MBH-1];

    // Streaming handle registers
    reg                       r_handle_valid;
    reg [AXI_ADDR_WIDTH-1:0]  r_handle_addr;
    reg [31:0]                r_handle_size;
    reg [31:0]                r_handle_skip;

    assign m_handle_valid = r_handle_valid;
    assign m_handle_addr  = r_handle_addr;
    assign m_handle_size  = r_handle_size;

    // Module-level scratch
    reg [7:0]  fsm_b;
    reg [31:0] fsm_rc32;
    reg [63:0] fsm_varint_val;
    reg [AXI_ADDR_WIDTH-1:0] fsm_idx_abs;
    reg [AXI_ADDR_WIDTH-1:0] fsm_rcnt_abs;

    integer j;

    // -----------------------------------------------------------------------
    // Packed output vectors
    // -----------------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < MBH; gi = gi + 1) begin : gen_out
            assign block_addr_vec[gi*AXI_ADDR_WIDTH +: AXI_ADDR_WIDTH] = r_addr[gi];
            assign block_size_vec[gi*32 +: 32]                          = r_bsz[gi];
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Main FSM
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rstn) begin
            state             <= ST_IDLE;
            busy              <= 1'b0;
            done              <= 1'b0;
            error             <= 1'b0;
            block_handle_count <= 32'd0;
            rd_clear_r        <= 1'b0;
            rd_start_r        <= 1'b0;
            r_handle_valid    <= 1'b0;
            all_handles_done  <= 1'b0;
            for (j = 0; j < MBH; j = j + 1) begin
                r_addr[j] <= {AXI_ADDR_WIDTH{1'b0}};
                r_bsz[j]  <= 32'd0;
            end
        end else if (clear) begin
            state      <= ST_IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            error      <= 1'b0;
            rd_clear_r <= 1'b0;
            rd_start_r <= 1'b0;
            r_handle_valid   <= 1'b0;
            all_handles_done <= 1'b0;
        end else begin
            rd_clear_r <= 1'b0;
            rd_start_r <= 1'b0;
            done       <= 1'b0;

            case (state)

                // ----------------------------------------------------------
                ST_IDLE: begin
                    if (start && !busy) begin
                        if (sstable_size < 32'd128) begin
                            error <= 1'b1;
                        end else begin
                            r_base       <= sstable_base_addr;
                            r_size       <= sstable_size;
                            busy         <= 1'b1;
                            error        <= 1'b0;
                            r_handle_idx <= 32'd0;
                            for (j = 0; j < MBH; j = j + 1) begin
                                r_addr[j] <= {AXI_ADDR_WIDTH{1'b0}};
                                r_bsz[j]  <= 32'd0;
                            end
                            state <= ST_FOOTER_CLR;
                        end
                    end
                end

                // ----------------------------------------------------------
                // FOOTER READ: 128 bytes from aligned footer address
                // ----------------------------------------------------------
                ST_FOOTER_CLR: begin
                    r_footer_rd_base <= sstable_base_addr +
                        {{(AXI_ADDR_WIDTH-32){1'b0}},
                         (sstable_size - 32'd48) & ~32'h3F};
                    r_footer_skip    <= (sstable_size - 32'd48) & 6'h3F;
                    rd_clear_r       <= 1'b1;
                    state            <= ST_FOOTER_STR;
                end

                ST_FOOTER_STR: begin
                    rd_base_r  <= r_footer_rd_base;
                    rd_count_r <= 32'd128;
                    rd_start_r <= 1'b1;
                    r_cap_wptr <= 32'd0;
                    state      <= ST_FOOTER_CAP;
                end

                ST_FOOTER_CAP: begin
                    if (rd_error) begin
                        error <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                    end else if (byte_tvalid) begin
                        footer_buf[r_cap_wptr[6:0]] <= byte_tdata;
                        r_cap_wptr                  <= r_cap_wptr + 32'd1;
                        if (byte_tlast || r_cap_wptr == 32'd127) begin
                            r_fp_pos <= r_footer_skip;
                            fp_state <= FP_META_OFF;
                            r_va     <= 64'd0;
                            r_vs     <= 7'd0;
                            state    <= ST_FOOTER_FETCH;
                        end
                    end
                end

                ST_FOOTER_FETCH: begin
                    r_fetched_ftr_byte <= footer_buf[r_fp_pos];
                    state              <= ST_FOOTER_PARSE;
                end

                // ----------------------------------------------------------
                // FOOTER PARSE: decode 4 varint64 from footer_buf
                // ----------------------------------------------------------
                ST_FOOTER_PARSE: begin
                    fsm_b          = r_fetched_ftr_byte;
                    fsm_varint_val = r_va | ({57'd0, fsm_b[6:0]} << r_vs);

                    if (!fsm_b[7]) begin
                        r_fp_pos           <= r_fp_pos + 8'd1;
                        r_fetched_ftr_byte <= footer_buf[r_fp_pos + 8'd1];
                        r_va               <= 64'd0;
                        r_vs               <= 7'd0;
                        case (fp_state)
                            FP_META_OFF:  fp_state <= FP_META_SIZE;
                            FP_META_SIZE: fp_state <= FP_IDX_OFF;
                            FP_IDX_OFF: begin
                                r_idx_offset <= fsm_varint_val;
                                fp_state     <= FP_IDX_SIZE;
                            end
                            FP_IDX_SIZE: begin
                                r_idx_size <= fsm_varint_val;
                                state      <= ST_INDEX_CLR;
                            end
                        endcase
                    end else begin
                        r_va               <= fsm_varint_val;
                        r_vs               <= r_vs + 7'd7;
                        r_fp_pos           <= r_fp_pos + 8'd1;
                        r_fetched_ftr_byte <= footer_buf[r_fp_pos + 8'd1];
                    end
                end

                // ----------------------------------------------------------
                // INDEX_CLR: compute aligned addresses for both reads
                // ----------------------------------------------------------
                ST_INDEX_CLR: begin
                    // Compute index block absolute start address
                    fsm_idx_abs = r_base + r_idx_offset[AXI_ADDR_WIDTH-1:0];
                    r_idx_rd_base  <= {fsm_idx_abs[AXI_ADDR_WIDTH-1:6], 6'b0};
                    r_idx_rd_skip  <= {26'd0, fsm_idx_abs[5:0]};
                    r_idx_actual   <= r_idx_size[31:0];

                    // Compute restart_count read address (last 4 bytes of idx block)
                    fsm_rcnt_abs = r_base + r_idx_offset[AXI_ADDR_WIDTH-1:0]
                                   + r_idx_size[AXI_ADDR_WIDTH-1:0] - 4;
                    r_rcnt_rd_base  <= {fsm_rcnt_abs[AXI_ADDR_WIDTH-1:6], 6'b0};
                    r_rcnt_skip     <= {26'd0, fsm_rcnt_abs[5:0]};
                    r_rcnt_rd_count <= ({26'd0, fsm_rcnt_abs[5:0]} + 32'd4 + 32'd63) & ~32'h3F;

                    rd_clear_r <= 1'b1;
                    state      <= ST_RCNT_STR;
                end

                // ----------------------------------------------------------
                // RESTART COUNT READ: read last 4 bytes of index block
                // ----------------------------------------------------------
                ST_RCNT_STR: begin
                    rd_base_r    <= r_rcnt_rd_base;
                    rd_count_r   <= r_rcnt_rd_count;
                    rd_start_r   <= 1'b1;
                    r_cap_skip   <= r_rcnt_skip;
                    r_cap_remain <= 32'd4;
                    r_rcnt_cap_idx <= 3'd0;
                    state        <= ST_RCNT_CAP;
                end

                ST_RCNT_CAP: begin
                    if (rd_error) begin
                        error <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                    end else if (byte_tvalid) begin
                        if (r_cap_skip > 32'd0) begin
                            r_cap_skip <= r_cap_skip - 32'd1;
                        end else if (r_cap_remain > 32'd0) begin
                            case (r_rcnt_cap_idx)
                                3'd0: r_rc_b0 <= byte_tdata;
                                3'd1: r_rc_b1 <= byte_tdata;
                                3'd2: r_rc_b2 <= byte_tdata;
                                default: r_rc_b3 <= byte_tdata;
                            endcase
                            r_rcnt_cap_idx <= r_rcnt_cap_idx + 3'd1;
                            r_cap_remain   <= r_cap_remain - 32'd1;
                            if (r_cap_remain == 32'd1)
                                state <= ST_RCNT_PARSE;
                        end
                    end
                end

                ST_RCNT_PARSE: begin
                    if (r_idx_actual < 32'd8) begin
                        error <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                    end else begin
                        fsm_rc32 = {r_rc_b3, r_rc_b2, r_rc_b1, r_rc_b0};
                        if (4*(fsm_rc32 + 32'd1) >= r_idx_actual) begin
                            error <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                        end else begin
                            r_entries_end <= r_idx_actual - 4*(fsm_rc32 + 32'd1);
                            state         <= ST_ENTRY_CLR;
                        end
                    end
                end

                // ----------------------------------------------------------
                // ENTRY STREAMING READ: read entries_end bytes from index start
                // ----------------------------------------------------------
                ST_ENTRY_CLR: begin
                    rd_clear_r <= 1'b1;
                    // Compute aligned read count for entry region
                    r_idx_rd_count <= (r_idx_rd_skip + r_entries_end + 32'd63) & ~32'h3F;
                    state          <= ST_ENTRY_STR;
                end

                ST_ENTRY_STR: begin
                    rd_base_r    <= r_idx_rd_base;
                    rd_count_r   <= r_idx_rd_count;
                    rd_start_r   <= 1'b1;
                    r_cap_skip   <= r_idx_rd_skip;
                    r_parse_pos  <= 32'd0;
                    ep_state     <= EP_SHARED_LEN;
                    r_va         <= 64'd0;
                    r_vs         <= 7'd0;
                    state        <= ST_ENTRY_SKIP;
                end

                // Skip leading alignment bytes
                ST_ENTRY_SKIP: begin
                    if (rd_error) begin
                        error <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                    end else if (r_cap_skip == 32'd0) begin
                        // All skip bytes consumed — begin parsing
                        state <= ST_PARSE_ENTRY;
                    end else if (byte_tvalid) begin
                        r_cap_skip <= r_cap_skip - 32'd1;
                    end
                end

                // ----------------------------------------------------------
                // PARSE_ENTRY: streaming parse of index entries
                //   Consumes bytes from byte_tdata/byte_tvalid.
                // ----------------------------------------------------------
                ST_PARSE_ENTRY: begin
                    // Stop condition: all entries consumed
                    if (ep_state == EP_SHARED_LEN &&
                        r_parse_pos >= r_entries_end) begin
                        state <= ST_DONE;
                    end else if (ep_state == EP_HANDLE_PUSH) begin
                        // Wait for downstream to accept handle (no stream consumption)
                        if (m_handle_ready) begin
                            r_handle_valid <= 1'b0;
                            r_handle_idx   <= r_handle_idx + 32'd1;
                            // Skip remaining value bytes in stream
                            if (r_handle_skip > 32'd0) begin
                                r_skip_count        <= r_handle_skip;
                                r_skip_return_state <= ST_PARSE_ENTRY;
                                r_skip_return_ep    <= EP_SHARED_LEN;
                                r_va                <= 64'd0;
                                r_vs                <= 7'd0;
                                ep_state            <= EP_SHARED_LEN;
                                state               <= ST_STREAM_SKIP;
                            end else begin
                                r_va     <= 64'd0;
                                r_vs     <= 7'd0;
                                ep_state <= EP_SHARED_LEN;
                            end
                        end
                    end else if (ep_state == EP_SKIP_KEY) begin
                        // Skip unshared key bytes in stream
                        if (r_unshared_len > 32'd0) begin
                            r_skip_count        <= r_unshared_len;
                            r_skip_return_state <= ST_PARSE_ENTRY;
                            r_skip_return_ep    <= EP_BLK_OFFSET;
                            r_val_used          <= 32'd0;
                            r_va                <= 64'd0;
                            r_vs                <= 7'd0;
                            state               <= ST_STREAM_SKIP;
                        end else begin
                            r_val_used <= 32'd0;
                            r_va       <= 64'd0;
                            r_vs       <= 7'd0;
                            ep_state   <= EP_BLK_OFFSET;
                        end
                    end else if (byte_tvalid) begin
                        // Consume one byte from stream
                        fsm_b          = byte_tdata;
                        fsm_varint_val = r_va | ({57'd0, fsm_b[6:0]} << r_vs);
                        r_parse_pos    <= r_parse_pos + 32'd1;

                        case (ep_state)

                            EP_SHARED_LEN,
                            EP_UNSHARED,
                            EP_VALUE_LEN: begin
                                if (!fsm_b[7]) begin
                                    r_va <= 64'd0;
                                    r_vs <= 7'd0;
                                    case (ep_state)
                                        EP_SHARED_LEN: begin
                                            r_shared_len <= fsm_varint_val[31:0];
                                            ep_state     <= EP_UNSHARED;
                                        end
                                        EP_UNSHARED: begin
                                            r_unshared_len <= fsm_varint_val[31:0];
                                            ep_state       <= EP_VALUE_LEN;
                                        end
                                        EP_VALUE_LEN: begin
                                            r_value_len <= fsm_varint_val[31:0];
                                            ep_state    <= EP_SKIP_KEY;
                                        end
                                    endcase
                                end else begin
                                    r_va <= fsm_varint_val;
                                    r_vs <= r_vs + 7'd7;
                                end
                            end

                            EP_BLK_OFFSET: begin
                                if (!fsm_b[7]) begin
                                    r_blk_off  <= fsm_varint_val;
                                    r_val_used <= r_val_used + 32'd1;
                                    r_va       <= 64'd0;
                                    r_vs       <= 7'd0;
                                    ep_state   <= EP_BLK_SIZE;
                                end else begin
                                    r_va       <= fsm_varint_val;
                                    r_vs       <= r_vs + 7'd7;
                                    r_val_used <= r_val_used + 32'd1;
                                end
                            end

                            EP_BLK_SIZE: begin
                                if (!fsm_b[7]) begin
                                    // Handle fully decoded — push to stream
                                    r_handle_addr  <= r_base + r_blk_off[AXI_ADDR_WIDTH-1:0];
                                    r_handle_size  <= fsm_varint_val[31:0];
                                    r_handle_valid <= 1'b1;
                                    // Store in batch arrays
                                    if (r_handle_idx < MBH[31:0]) begin
                                        r_addr[r_handle_idx] <=
                                            r_base + r_blk_off[AXI_ADDR_WIDTH-1:0];
                                        r_bsz[r_handle_idx]  <=
                                            fsm_varint_val[31:0];
                                    end
                                    r_handle_skip <= r_value_len - (r_val_used + 32'd1);
                                    ep_state      <= EP_HANDLE_PUSH;
                                end else begin
                                    r_va       <= fsm_varint_val;
                                    r_vs       <= r_vs + 7'd7;
                                    r_val_used <= r_val_used + 32'd1;
                                end
                            end

                            default: state <= ST_DONE;
                        endcase
                    end
                end

                // ----------------------------------------------------------
                // STREAM_SKIP: consume r_skip_count bytes from stream
                // ----------------------------------------------------------
                ST_STREAM_SKIP: begin
                    if (rd_error) begin
                        error <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                    end else if (byte_tvalid) begin
                        r_parse_pos  <= r_parse_pos + 32'd1;
                        r_skip_count <= r_skip_count - 32'd1;
                        if (r_skip_count == 32'd1) begin
                            state    <= r_skip_return_state;
                            ep_state <= r_skip_return_ep;
                        end
                    end
                end

                // ----------------------------------------------------------
                ST_DONE: begin
                    busy              <= 1'b0;
                    done              <= 1'b1;
                    all_handles_done  <= 1'b1;
                    block_handle_count <= r_handle_idx;
                end

                default: begin
                    error <= 1'b1;
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end

            endcase
        end
    end

endmodule
