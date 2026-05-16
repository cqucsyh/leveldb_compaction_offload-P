`timescale 1ns / 1ps

// sstable_data_block_handle_emitter
//
// Reads a LevelDB SSTable from DDR, parses the 48-byte footer to locate
// the index block, parses every index-block entry to extract data-block
// handles (abs DDR address + byte size, trailer excluded), and exposes up
// to MAX_BLOCK_HANDLES handles as packed register vectors.
//
// Assumptions:
//   sstable_base_addr is 64-byte (AXI-beat) aligned.
//   sstable_size >= 128 bytes.
//   Index block fits within MAX_INDEX_BYTES bytes.
//
// Footer read: 128 bytes (2 beats) from the 64-byte-aligned address that
//   contains footer_start = sstable_base + sstable_size - 48.
//   footer_skip = (sstable_size - 48) & 63  byte offset within buffer.
//
// Index read:  aligned AXI burst; leading skip bytes discarded in capture.
//
// Entry parse (one byte per cycle from block_mem, zero-latency reg array):
//   varint32 shared_len -> varint32 unshared_len -> varint32 value_len ->
//   skip unshared_len bytes (1 cycle) -> varint64 blk_offset ->
//   varint64 blk_size -> skip remaining value bytes (1 cycle).
//
module sstable_data_block_handle_emitter #(
    parameter integer AXI_ADDR_WIDTH    = 64,
    parameter integer AXI_DATA_WIDTH    = 512,
    parameter integer AXI_ID_WIDTH      = 1,
    parameter integer MAX_BURST_LEN     = 16,
    parameter integer MAX_INDEX_BYTES   = 8192,
    parameter integer MAX_BLOCK_HANDLES = 8
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

    // OPT-P1a: Streaming handle output (one handle per valid/ready beat)
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

    localparam integer AXI_BEAT_BYTES  = AXI_DATA_WIDTH / 8;  // 64
    localparam integer MBH             = MAX_BLOCK_HANDLES;    // shorthand

    // -----------------------------------------------------------------------
    // State encoding
    // -----------------------------------------------------------------------
    localparam [3:0] ST_IDLE         = 4'd0;
    localparam [3:0] ST_FOOTER_CLR   = 4'd1;
    localparam [3:0] ST_FOOTER_STR   = 4'd2;
    localparam [3:0] ST_FOOTER_CAP   = 4'd3;
    localparam [3:0] ST_FOOTER_PARSE = 4'd4;
    localparam [3:0] ST_INDEX_CLR    = 4'd5;
    localparam [3:0] ST_INDEX_STR    = 4'd6;
    localparam [3:0] ST_INDEX_CAP    = 4'd7;
    localparam [3:0] ST_PREPARSE     = 4'd8;
    localparam [3:0] ST_PARSE_ENTRY  = 4'd9;
    localparam [3:0] ST_DONE         = 4'd10;
    localparam [3:0] ST_PREPARSE2    = 4'd11;  // pipeline: arithmetic after byte latch
    localparam [3:0] ST_ENTRY_FETCH  = 4'd12;  // pipeline: fetch index byte
    localparam [3:0] ST_FOOTER_FETCH = 4'd13;  // pipeline: fetch footer byte

    // Footer parse sub-phases
    localparam [1:0] FP_META_OFF  = 2'd0;
    localparam [1:0] FP_META_SIZE = 2'd1;
    localparam [1:0] FP_IDX_OFF   = 2'd2;
    localparam [1:0] FP_IDX_SIZE  = 2'd3;

    // Entry parse sub-states
    localparam [2:0] EP_SHARED_LEN = 3'd0;
    localparam [2:0] EP_UNSHARED   = 3'd1;
    localparam [2:0] EP_VALUE_LEN  = 3'd2;
    localparam [2:0] EP_SKIP_KEY   = 3'd3;
    localparam [2:0] EP_BLK_OFFSET = 3'd4;
    localparam [2:0] EP_BLK_SIZE   = 3'd5;
    localparam [2:0] EP_HANDLE_PUSH = 3'd6;  // OPT-P1a: wait for stream accept

    // -----------------------------------------------------------------------
    // Buffers  (register arrays = zero-latency read in simulation)
    // -----------------------------------------------------------------------
    reg [7:0] footer_buf [0:127];
    reg [7:0] block_mem  [0:MAX_INDEX_BYTES-1];

    // -----------------------------------------------------------------------
    // axi_read_engine + stream_width_adapter
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

    assign byte_tready = (state == ST_FOOTER_CAP) || (state == ST_INDEX_CAP);

    // -----------------------------------------------------------------------
    // FSM registers
    // -----------------------------------------------------------------------
    reg [3:0] state;
    reg [1:0] fp_state;
    reg [2:0] ep_state;

    reg [AXI_ADDR_WIDTH-1:0]  r_base;
    reg [31:0]                r_size;

    // Footer read control
    reg [AXI_ADDR_WIDTH-1:0]  r_footer_rd_base;
    reg [5:0]                 r_footer_skip;

    // Capture control (shared between footer/index phases)
    reg [31:0]  r_cap_skip;
    reg [31:0]  r_cap_remain;
    reg [31:0]  r_cap_wptr;

    // Index read control
    reg [AXI_ADDR_WIDTH-1:0]  r_idx_rd_base;
    reg [31:0]                r_idx_rd_count;
    reg [31:0]                r_idx_rd_skip;
    reg [31:0]                r_idx_actual;   // index block byte count

    // Decoded footer values
    reg [63:0]  r_idx_offset;
    reg [63:0]  r_idx_size;

    // Index parse state
    reg [31:0]  r_entries_end;
    reg [31:0]  r_parse_pos;
    reg [31:0]  r_handle_idx;

    // Entry fields
    reg [31:0]  r_shared_len;
    reg [31:0]  r_unshared_len;
    reg [31:0]  r_value_len;
    reg [31:0]  r_val_used;      // varint bytes consumed in current value

    // Current block handle being decoded
    reg [63:0]  r_blk_off;

    // Shared varint decoder state
    reg [63:0]  r_va;    // accumulator
    reg [6:0]   r_vs;    // current shift (0, 7, 14, ..., 63)

    // Footer parse byte pointer
    reg [7:0]   r_fp_pos;   // index into footer_buf (0..127)

    // Pipeline registers for timing closure
    reg [7:0]  r_rc_b3, r_rc_b2, r_rc_b1, r_rc_b0;  // restart count bytes
    reg [7:0]  r_fetched_idx_byte;                     // pre-fetched index byte
    reg [7:0]  r_fetched_ftr_byte;                     // pre-fetched footer byte

    // Per-handle scratch (filled during parse, copied to outputs at ST_DONE)
    reg [AXI_ADDR_WIDTH-1:0]  r_addr [0:MBH-1];
    reg [31:0]                r_bsz  [0:MBH-1];

    // Module-level scratch variables (avoids local decl issues in always)
    reg [7:0]  fsm_b;           // current byte being processed
    reg [31:0] fsm_rc32;        // restart_count scratch
    reg [63:0] fsm_varint_val;  // fully assembled varint value
    reg [AXI_ADDR_WIDTH-1:0] fsm_idx_abs;
    reg [31:0] fsm_skip_rem;    // remaining value bytes to skip

    // OPT-P1a: streaming handle registers
    reg                       r_handle_valid;
    reg [AXI_ADDR_WIDTH-1:0]  r_handle_addr;
    reg [31:0]                r_handle_size;
    reg [31:0]                r_handle_skip;  // saved skip_rem for EP_HANDLE_PUSH

    assign m_handle_valid = r_handle_valid;
    assign m_handle_addr  = r_handle_addr;
    assign m_handle_size  = r_handle_size;

    integer j;

    // -----------------------------------------------------------------------
    // Drive packed output vectors directly from r_addr / r_bsz (generate loop
    // avoids variable-part-select non-blocking assignments in always blocks)
    // -----------------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < MBH; gi = gi + 1) begin : gen_out
            assign block_addr_vec[gi*AXI_ADDR_WIDTH +: AXI_ADDR_WIDTH] = r_addr[gi];
            assign block_size_vec[gi*32 +: 32]                          = r_bsz[gi];
        end
    endgenerate

    // (footer_byte / index_byte wires removed — now use pipelined registers
    //  r_fetched_ftr_byte and r_fetched_idx_byte for timing closure)

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
            rd_base_r         <= {AXI_ADDR_WIDTH{1'b0}};
            rd_count_r        <= 32'd0;
            r_base            <= {AXI_ADDR_WIDTH{1'b0}};
            r_size            <= 32'd0;
            r_idx_offset      <= 64'd0;
            r_idx_size        <= 64'd0;
            r_handle_idx      <= 32'd0;
            r_parse_pos       <= 32'd0;
            r_entries_end     <= 32'd0;
            r_va              <= 64'd0;
            r_vs              <= 7'd0;
            r_val_used        <= 32'd0;
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
                    // footer_start = base + size - 48
                    // aligned_base = base + ((size-48) & ~63)
                    // footer_skip  = (size-48) & 63  (byte offset in buffer)
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

                // ----------------------------------------------------------
                // FOOTER FETCH: latch one footer byte (pipeline stage)
                // ----------------------------------------------------------
                ST_FOOTER_FETCH: begin
                    r_fetched_ftr_byte <= footer_buf[r_fp_pos];
                    state              <= ST_FOOTER_PARSE;
                end

                // ----------------------------------------------------------
                // FOOTER PARSE: decode 4 varint64 sequentially from footer_buf
                //   Uses r_fetched_ftr_byte (registered) for timing closure.
                //   Inline pre-fetch for +1 advances avoids extra cycles.
                // ----------------------------------------------------------
                ST_FOOTER_PARSE: begin
                    fsm_b          = r_fetched_ftr_byte;
                    fsm_varint_val = r_va | ({57'd0, fsm_b[6:0]} << r_vs);

                    if (!fsm_b[7]) begin
                        // Last byte of this varint
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
                        // More bytes to come — pre-fetch next byte inline
                        r_va               <= fsm_varint_val;
                        r_vs               <= r_vs + 7'd7;
                        r_fp_pos           <= r_fp_pos + 8'd1;
                        r_fetched_ftr_byte <= footer_buf[r_fp_pos + 8'd1];
                    end
                end

                // ----------------------------------------------------------
                // INDEX BLOCK READ: aligned AXI burst, skip leading pad bytes
                // ----------------------------------------------------------
                ST_INDEX_CLR: begin
                    fsm_idx_abs  = r_base +
                                   r_idx_offset[AXI_ADDR_WIDTH-1:0];
                    r_idx_rd_base  <= {fsm_idx_abs[AXI_ADDR_WIDTH-1:6], 6'b0};
                    r_idx_rd_skip  <= {26'd0, fsm_idx_abs[5:0]};
                    r_idx_actual   <= r_idx_size[31:0];
                    // aligned read count: skip + idx_size rounded up to 64
                    r_idx_rd_count <= ({26'd0, fsm_idx_abs[5:0]} +
                                       r_idx_size[31:0] + 32'd63) & ~32'h3F;
                    rd_clear_r <= 1'b1;
                    state      <= ST_INDEX_STR;
                end

                ST_INDEX_STR: begin
                    rd_base_r    <= r_idx_rd_base;
                    rd_count_r   <= r_idx_rd_count;
                    rd_start_r   <= 1'b1;
                    r_cap_skip   <= r_idx_rd_skip;
                    r_cap_remain <= r_idx_actual;
                    r_cap_wptr   <= 32'd0;
                    state        <= ST_INDEX_CAP;
                end

                ST_INDEX_CAP: begin
                    if (rd_error) begin
                        error <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                    end else if (byte_tvalid) begin
                        if (r_cap_skip > 32'd0) begin
                            r_cap_skip <= r_cap_skip - 32'd1;
                        end else if (r_cap_remain > 32'd0) begin
                            block_mem[r_cap_wptr] <= byte_tdata;
                            r_cap_wptr   <= r_cap_wptr + 32'd1;
                            r_cap_remain <= r_cap_remain - 32'd1;
                            if (r_cap_remain == 32'd1)
                                state <= ST_PREPARSE;
                        end
                    end
                end

                // ----------------------------------------------------------
                // PREPARSE: latch restart_count bytes from block_mem
                //   (pipeline stage 1 — breaks r_idx_actual→block_mem
                //    →arithmetic critical path for timing closure)
                // ----------------------------------------------------------
                ST_PREPARSE: begin
                    if (r_idx_actual < 32'd8) begin
                        error <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                    end else begin
                        r_rc_b3 <= block_mem[r_idx_actual-1];
                        r_rc_b2 <= block_mem[r_idx_actual-2];
                        r_rc_b1 <= block_mem[r_idx_actual-3];
                        r_rc_b0 <= block_mem[r_idx_actual-4];
                        state   <= ST_PREPARSE2;
                    end
                end

                // ----------------------------------------------------------
                // PREPARSE2: compute entries_end from latched bytes
                //   (pipeline stage 2 — arithmetic on registered values)
                // ----------------------------------------------------------
                ST_PREPARSE2: begin
                    fsm_rc32 = {r_rc_b3, r_rc_b2, r_rc_b1, r_rc_b0};
                    if (4*(fsm_rc32 + 32'd1) >= r_idx_actual) begin
                        error <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                    end else begin
                        r_entries_end <= r_idx_actual - 4*(fsm_rc32 + 32'd1);
                        r_parse_pos   <= 32'd0;
                        ep_state      <= EP_SHARED_LEN;
                        r_va          <= 64'd0;
                        r_vs          <= 7'd0;
                        state         <= ST_ENTRY_FETCH;
                    end
                end

                // ----------------------------------------------------------
                // ENTRY_FETCH: latch one index byte (pipeline stage)
                //   Used after skip-advances and for initial entry.
                // ----------------------------------------------------------
                ST_ENTRY_FETCH: begin
                    r_fetched_idx_byte <= block_mem[r_parse_pos];
                    state              <= ST_PARSE_ENTRY;
                end

                // ----------------------------------------------------------
                // PARSE_ENTRY: walk index entries, one byte per cycle
                //   Uses r_fetched_idx_byte (registered) for timing closure.
                //   Inline pre-fetch block_mem[r_parse_pos+1] for +1 advances.
                // ----------------------------------------------------------
                ST_PARSE_ENTRY: begin
                    // Stop condition checked at start of each new entry
                    if (ep_state == EP_SHARED_LEN &&
                        r_parse_pos >= r_entries_end) begin
                        // OPT-P1a: removed MBH cap — parse ALL handles
                        state <= ST_DONE;
                    end else begin
                        fsm_b          = r_fetched_idx_byte;
                        fsm_varint_val = r_va | ({57'd0, fsm_b[6:0]} << r_vs);

                        case (ep_state)

                            EP_SHARED_LEN,
                            EP_UNSHARED,
                            EP_VALUE_LEN: begin
                                if (!fsm_b[7]) begin
                                    r_parse_pos        <= r_parse_pos + 32'd1;
                                    r_fetched_idx_byte <= block_mem[r_parse_pos + 32'd1];
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
                                    r_va               <= fsm_varint_val;
                                    r_vs               <= r_vs + 7'd7;
                                    r_parse_pos        <= r_parse_pos + 32'd1;
                                    r_fetched_idx_byte <= block_mem[r_parse_pos + 32'd1];
                                end
                            end

                            EP_SKIP_KEY: begin
                                // Advance parse_pos by unshared_len in 1 cycle
                                r_parse_pos <= r_parse_pos + r_unshared_len;
                                r_val_used  <= 32'd0;
                                r_va        <= 64'd0;
                                r_vs        <= 7'd0;
                                ep_state    <= EP_BLK_OFFSET;
                                state       <= ST_ENTRY_FETCH;
                            end

                            EP_BLK_OFFSET: begin
                                if (!fsm_b[7]) begin
                                    r_blk_off          <= fsm_varint_val;
                                    r_val_used         <= r_val_used + 32'd1;
                                    r_parse_pos        <= r_parse_pos + 32'd1;
                                    r_fetched_idx_byte <= block_mem[r_parse_pos + 32'd1];
                                    r_va               <= 64'd0;
                                    r_vs               <= 7'd0;
                                    ep_state           <= EP_BLK_SIZE;
                                end else begin
                                    r_va               <= fsm_varint_val;
                                    r_vs               <= r_vs + 7'd7;
                                    r_val_used         <= r_val_used + 32'd1;
                                    r_parse_pos        <= r_parse_pos + 32'd1;
                                    r_fetched_idx_byte <= block_mem[r_parse_pos + 32'd1];
                                end
                            end

                            EP_BLK_SIZE: begin
                                if (!fsm_b[7]) begin
                                    // Handle fully decoded — push to stream
                                    r_handle_addr  <= r_base + r_blk_off[AXI_ADDR_WIDTH-1:0];
                                    r_handle_size  <= fsm_varint_val[31:0];
                                    r_handle_valid <= 1'b1;
                                    // Also store in batch arrays (first MBH)
                                    if (r_handle_idx < MBH[31:0]) begin
                                        r_addr[r_handle_idx] <=
                                            r_base + r_blk_off[AXI_ADDR_WIDTH-1:0];
                                        r_bsz[r_handle_idx]  <=
                                            fsm_varint_val[31:0];
                                    end
                                    // Save skip for EP_HANDLE_PUSH
                                    r_handle_skip <= r_value_len -
                                                     (r_val_used + 32'd1);
                                    ep_state <= EP_HANDLE_PUSH;
                                end else begin
                                    r_va               <= fsm_varint_val;
                                    r_vs               <= r_vs + 7'd7;
                                    r_val_used         <= r_val_used + 32'd1;
                                    r_parse_pos        <= r_parse_pos + 32'd1;
                                    r_fetched_idx_byte <= block_mem[r_parse_pos + 32'd1];
                                end
                            end

                            // OPT-P1a: wait for downstream to accept handle
                            EP_HANDLE_PUSH: begin
                                if (m_handle_ready) begin
                                    r_handle_valid <= 1'b0;
                                    r_handle_idx   <= r_handle_idx + 32'd1;
                                    r_parse_pos    <= r_parse_pos + 32'd1 +
                                                      r_handle_skip;
                                    r_va           <= 64'd0;
                                    r_vs           <= 7'd0;
                                    ep_state       <= EP_SHARED_LEN;
                                    state          <= ST_ENTRY_FETCH;
                                end
                            end

                            default: state <= ST_DONE;
                        endcase
                    end
                end

                // ----------------------------------------------------------
                ST_DONE: begin
                    busy              <= 1'b0;
                    done              <= 1'b1;
                    all_handles_done  <= 1'b1;
                    block_handle_count <= r_handle_idx;
                    // Stay in ST_DONE until clear is asserted
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
