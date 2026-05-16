`timescale 1ns / 1ps

module real_data_block_record_decoder #(
    parameter integer MAX_BLOCK_BYTES = 4096,
    parameter integer MAX_KEY_BYTES   = 256
) (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire        start,
    input  wire [31:0] block_byte_count,  // OPT-3A: externally provided block size
    input  wire [7:0]  s_axis_tdata,
    input  wire [0:0]  s_axis_tkeep,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    output reg         busy,
    output reg         done,
    output reg         error,
    output reg         record_valid,
    input  wire        record_ready,
    output reg  [15:0] record_key_len,
    output reg  [15:0] record_value_len,
    output reg  [15:0] record_shared_bytes,
    output reg  [15:0] record_non_shared_bytes,
    // OPT-D3: 32-bit wide output (4 bytes/cycle)
    output wire [31:0] m_axis_tdata,
    output wire [3:0]  m_axis_tkeep,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
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

    localparam [4:0] ST_IDLE               = 5'd0;
    // OPT-3A: ST_CAPTURE / ST_PREPARE removed from parse FSM;
    // capture runs as a separate concurrent process.
    localparam [4:0] ST_FETCH_FIXED32      = 5'd3;
    localparam [4:0] ST_CONSUME_FIXED32    = 5'd4;
    localparam [4:0] ST_FETCH_SHARED       = 5'd5;
    localparam [4:0] ST_CONSUME_SHARED     = 5'd6;
    localparam [4:0] ST_FETCH_UNSHARED     = 5'd7;
    localparam [4:0] ST_CONSUME_UNSHARED   = 5'd8;
    localparam [4:0] ST_FETCH_VALUE_LEN    = 5'd9;
    localparam [4:0] ST_CONSUME_VALUE_LEN  = 5'd10;
    localparam [4:0] ST_VALIDATE_ENTRY     = 5'd11;
    localparam [4:0] ST_PREP_EMIT_UNSHARED = 5'd12; // OPT-A1: replaced ST_COPY_KEY
    localparam [4:0] ST_EMIT_ENTRY         = 5'd13;
    localparam [4:0] ST_BEGIN_RESTART_SCAN = 5'd14;
    localparam [4:0] ST_EMIT_KEY_BYTES     = 5'd15;
    localparam [4:0] ST_EMIT_VALUE_BYTES   = 5'd16;
    localparam [4:0] ST_PREP_EMIT_VALUE    = 5'd17;
    localparam [4:0] ST_EMIT_UNSHARED_KEY  = 5'd18;  // OPT-A1: replaced ST_COPY_KEY_STORE

    localparam       FIXED32_MODE_COUNT  = 1'b0;
    localparam       FIXED32_MODE_OFFSET = 1'b1;

    reg [4:0]  state;
    localparam BMEM_AW = $clog2(MAX_BLOCK_BYTES);
    reg [7:0] prev_key_mem [0:MAX_KEY_BYTES-1];
    // OPT-A1: curr_key_mem removed; unshared key bytes read directly from block_mem BRAM during emit
    // OPT-3A: capture-side registers (driven by separate always block)
    reg [31:0] cap_wptr;      // how many bytes captured so far
    reg        cap_done;      // capture complete
    reg        cap_active;    // capture in progress
    reg        ra_valid;      // restart_array_offset is valid
    reg [31:0] ra_offset_r;   // computed restart_array_offset from capture
    reg [31:0] rc_count_r;    // computed restart_count from capture
    reg [31:0] tail_accum;    // shift register for last 4 bytes (restart_count LE)
    reg        cap_error;     // capture overflow error
    reg [31:0] parse_index;
    reg [31:0] shared_len;
    reg [31:0] unshared_len;
    reg [31:0] value_len;
    reg [31:0] prev_key_len;
    reg [31:0] key_copy_index;
    reg [31:0] varint_accum;
    reg [5:0]  varint_shift;
    reg [2:0]  varint_bytes;
    reg [31:0] restart_scan_index;
    reg [31:0] restart_prev_offset;
    reg [31:0] fixed32_base_addr;
    reg [31:0] fixed32_accum;
    reg [1:0]  fixed32_byte_index;
    reg        fixed32_mode;
    wire [7:0] fetched_byte;
    reg [31:0] key_base_index;
    reg [31:0] value_base_index;
    reg [31:0] next_entry_index;
    reg [31:0] emit_index;
    reg        post_emit;        // OPT-D3 fix: set after emit→FETCH_SHARED, prevents parsing restart bytes

    reg [31:0] next_varint_value;
    reg [31:0] next_fixed32_value;

    wire [31:0] current_key_len_w;
    wire        output_accept;

    // OPT-D3: 4 bytes emitted per cycle — remaining byte count in current phase
    reg  [31:0] emit_remain;      // bytes remaining in current emit phase

    // ---- BRAM via 4-bank interleaved cmpct_sdpram (OPT-D3) ----
    // Each bank stores every 4th byte: bank[b] stores addresses where addr[1:0]==b.
    // Write: 1 byte/cycle into bank cap_wptr[1:0] at word address cap_wptr>>2.
    // Read:  all 4 banks in parallel → 4 bytes/cycle.
    //        For parse (single byte): read all banks at parse_addr>>2, mux by parse_addr[1:0].
    //        For emit (4 bytes):      each bank gets its own address based on emit base.
    localparam BMEM_WORD_AW = (BMEM_AW > 2) ? (BMEM_AW - 2) : 1;

    wire        bram_we_comb = s_axis_tvalid && s_axis_tkeep[0] && s_axis_tready;
    wire        entries_done_w = ra_valid && (parse_index >= ra_offset_r);
    wire        varint_overflow_w = (varint_shift >= 6'd28) || (varint_bytes == 3'd4);

    // Per-bank write enables
    wire [3:0] bank_we;
    assign bank_we[0] = bram_we_comb && (cap_wptr[1:0] == 2'd0);
    assign bank_we[1] = bram_we_comb && (cap_wptr[1:0] == 2'd1);
    assign bank_we[2] = bram_we_comb && (cap_wptr[1:0] == 2'd2);
    assign bank_we[3] = bram_we_comb && (cap_wptr[1:0] == 2'd3);

    // Bank read data outputs
    wire [7:0] bank_rdata [0:3];

    // Read address / enable per bank
    reg [BMEM_AW-1:0] bank_raddr [0:3];
    reg                bank_re   [0:3];

    // --- Parse-phase: single-byte read from BRAM ---
    reg [31:0] parse_rd_addr_comb;
    reg        parse_rd_en_comb;

    always @(*) begin
        parse_rd_en_comb = 1'b0;
        parse_rd_addr_comb = parse_index;
        if (busy && !error && !cap_error) begin
            case (state)
                ST_FETCH_FIXED32: begin
                    if (fixed32_base_addr + {30'd0, fixed32_byte_index} < cap_wptr) begin
                        parse_rd_addr_comb = fixed32_base_addr + {30'd0, fixed32_byte_index};
                        parse_rd_en_comb = 1'b1;
                    end
                end
                ST_FETCH_SHARED: begin
                    if (!entries_done_w && parse_index < cap_wptr)
                        parse_rd_en_comb = 1'b1;
                end
                ST_CONSUME_SHARED: begin
                    if (fetched_byte[7]) begin
                        if (!varint_overflow_w && parse_index < cap_wptr)
                            parse_rd_en_comb = 1'b1;
                    end else if (!entries_done_w && parse_index < cap_wptr)
                        parse_rd_en_comb = 1'b1;
                end
                ST_FETCH_UNSHARED: begin
                    if (!entries_done_w && parse_index < cap_wptr)
                        parse_rd_en_comb = 1'b1;
                end
                ST_CONSUME_UNSHARED: begin
                    if (fetched_byte[7]) begin
                        if (!varint_overflow_w && parse_index < cap_wptr)
                            parse_rd_en_comb = 1'b1;
                    end else if (!entries_done_w && parse_index < cap_wptr)
                        parse_rd_en_comb = 1'b1;
                end
                ST_FETCH_VALUE_LEN: begin
                    if (!entries_done_w && parse_index < cap_wptr)
                        parse_rd_en_comb = 1'b1;
                end
                ST_CONSUME_VALUE_LEN: begin
                    if (fetched_byte[7] && !varint_overflow_w && parse_index < cap_wptr)
                        parse_rd_en_comb = 1'b1;
                end
                default: ;
            endcase
        end
    end

    // --- Emit-phase: 4-byte parallel read from 4 banks (OPT-D3) ---
    // emit_rd_base is the byte address of the first byte to read in the current emit beat.
    reg [31:0] emit_rd_base_comb;
    reg        emit_rd_en_comb;

    always @(*) begin
        emit_rd_en_comb = 1'b0;
        emit_rd_base_comb = 32'd0;
        if (busy && !error && !cap_error) begin
            case (state)
                ST_PREP_EMIT_UNSHARED: begin
                    if (key_base_index + key_copy_index + 32'd3 < cap_wptr) begin
                        emit_rd_base_comb = key_base_index + key_copy_index;
                        emit_rd_en_comb = 1'b1;
                    end
                end
                ST_EMIT_UNSHARED_KEY: begin
                    if (output_accept && emit_remain > 32'd4) begin
                        if (key_base_index + key_copy_index + 32'd4 + 32'd3 < cap_wptr) begin
                            emit_rd_base_comb = key_base_index + key_copy_index + 32'd4;
                            emit_rd_en_comb = 1'b1;
                        end
                    end
                end
                ST_PREP_EMIT_VALUE: begin
                    if (value_base_index + emit_index + 32'd3 < cap_wptr) begin
                        emit_rd_base_comb = value_base_index + emit_index;
                        emit_rd_en_comb = 1'b1;
                    end
                end
                ST_EMIT_VALUE_BYTES: begin
                    if (output_accept && emit_remain > 32'd4) begin
                        if (value_base_index + emit_index + 32'd4 + 32'd3 < cap_wptr) begin
                            emit_rd_base_comb = value_base_index + emit_index + 32'd4;
                            emit_rd_en_comb = 1'b1;
                        end
                    end
                end
                default: ;
            endcase
        end
    end

    // --- Bank address generation ---
    // For parse: all banks read at parse_rd_addr>>2; fetched_byte selected by parse_rd_addr[1:0].
    // For emit:  bank b reads at (emit_base + ((b - emit_base[1:0]) & 3)) >> 2.
    //            If b < emit_base[1:0], the byte wraps to the next word → addr = (emit_base>>2)+1.
    wire [1:0] emit_offset = emit_rd_base_comb[1:0];
    wire        is_emit_phase = (state == ST_PREP_EMIT_UNSHARED) || (state == ST_EMIT_UNSHARED_KEY) ||
                                (state == ST_PREP_EMIT_VALUE)    || (state == ST_EMIT_VALUE_BYTES);

    // OPT-D3: compute per-bank read addresses
    always @(*) begin : bank_addr_gen
        integer b;
        for (b = 0; b < 4; b = b + 1) begin
            if (is_emit_phase && emit_rd_en_comb) begin
                // Emit: bank b stores bytes where addr[1:0]==b.
                // For emit word starting at emit_base:
                //   bank b reads byte at position (emit_base + ((b - emit_offset) & 3))
                //   If b >= emit_offset: same word as emit_base → word_addr = emit_base >> 2
                //   If b <  emit_offset: next word             → word_addr = (emit_base >> 2) + 1
                if (b[1:0] >= emit_offset)
                    bank_raddr[b] = {{(BMEM_AW - BMEM_WORD_AW){1'b0}}, emit_rd_base_comb[BMEM_AW-1:2]};
                else
                    bank_raddr[b] = {{(BMEM_AW - BMEM_WORD_AW){1'b0}}, emit_rd_base_comb[BMEM_AW-1:2]} + {{(BMEM_AW-1){1'b0}}, 1'b1};
                bank_re[b] = 1'b1;
            end else begin
                // Parse: all banks read from same word address
                bank_raddr[b] = parse_rd_addr_comb[BMEM_AW-1:0] >> 2;
                bank_re[b] = parse_rd_en_comb;
            end
        end
    end

    // Instantiate 4 BRAM banks
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : gen_bank
            cmpct_sdpram #(
                .DEPTH ((MAX_BLOCK_BYTES + 3) / 4),
                .WIDTH (8)
            ) u_block_bank (
                .clk   (clk),
                .we    (bank_we[gi]),
                .waddr (cap_wptr[BMEM_AW-1:2]),
                .wdata (s_axis_tdata),
                .re    (bank_re[gi]),
                .raddr (bank_raddr[gi][BMEM_WORD_AW-1:0]),
                .rdata (bank_rdata[gi])
            );
        end
    endgenerate

    // Parse: select single byte from appropriate bank (1-cycle latency)
    reg [1:0] parse_rd_addr_d;  // delayed low 2 bits for bank selection
    always @(posedge clk) begin
        if (parse_rd_en_comb)
            parse_rd_addr_d <= parse_rd_addr_comb[1:0];
    end
    assign fetched_byte = bank_rdata[parse_rd_addr_d];

    // OPT-D3: Compose 4-byte emit word from bank outputs, reordered by emit offset
    // emit_offset_d is the delayed emit_rd_base[1:0] from the previous cycle
    reg [1:0] emit_offset_d;
    always @(posedge clk) begin
        if (emit_rd_en_comb)
            emit_offset_d <= emit_rd_base_comb[1:0];
    end

    // Barrel-shift bank outputs: byte k of emit word = bank[(emit_offset_d + k) % 4]
    wire [7:0] emit_byte0 = bank_rdata[(emit_offset_d + 2'd0) & 2'd3];
    wire [7:0] emit_byte1 = bank_rdata[(emit_offset_d + 2'd1) & 2'd3];
    wire [7:0] emit_byte2 = bank_rdata[(emit_offset_d + 2'd2) & 2'd3];
    wire [7:0] emit_byte3 = bank_rdata[(emit_offset_d + 2'd3) & 2'd3];
    wire [31:0] bram_emit_word = {emit_byte3, emit_byte2, emit_byte1, emit_byte0};

    integer i;

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

    // OPT-3A: s_axis_tready driven by capture process, not parse FSM
    assign s_axis_tready = cap_active && !cap_error && (cap_wptr < MAX_BLOCK_BYTES);
    assign current_key_len_w = shared_len + unshared_len;

    // OPT-D3: 32-bit emit data path
    // Number of valid bytes this beat for shared-prefix emit
    wire [31:0] shared_emit_cnt = (shared_len - emit_index >= 32'd4) ? 32'd4 :
                                   shared_len - emit_index;
    // Compose 32-bit word from prev_key_mem for shared prefix
    wire [7:0] pkm_b0 = prev_key_mem[emit_index];
    wire [7:0] pkm_b1 = (shared_emit_cnt > 32'd1) ? prev_key_mem[emit_index + 32'd1] : 8'd0;
    wire [7:0] pkm_b2 = (shared_emit_cnt > 32'd2) ? prev_key_mem[emit_index + 32'd2] : 8'd0;
    wire [7:0] pkm_b3 = (shared_emit_cnt > 32'd3) ? prev_key_mem[emit_index + 32'd3] : 8'd0;
    wire [31:0] shared_emit_word = {pkm_b3, pkm_b2, pkm_b1, pkm_b0};

    // Number of valid bytes this beat for BRAM-based emit
    wire [31:0] bram_emit_cnt = (emit_remain >= 32'd4) ? 32'd4 : emit_remain;

    // Generate tkeep from valid byte count
    wire [3:0] emit_tkeep_from_cnt;
    wire [31:0] active_emit_cnt = (state == ST_EMIT_KEY_BYTES) ? shared_emit_cnt : bram_emit_cnt;
    assign emit_tkeep_from_cnt = (active_emit_cnt >= 32'd4) ? 4'b1111 :
                                 (active_emit_cnt == 32'd3) ? 4'b0111 :
                                 (active_emit_cnt == 32'd2) ? 4'b0011 :
                                 (active_emit_cnt == 32'd1) ? 4'b0001 : 4'b0000;

    assign m_axis_tdata = (state == ST_EMIT_KEY_BYTES) ? shared_emit_word : bram_emit_word;
    assign m_axis_tkeep = emit_tkeep_from_cnt;
    assign m_axis_tvalid = busy && !error &&
                           ((state == ST_EMIT_KEY_BYTES) ||
                            (state == ST_EMIT_UNSHARED_KEY) ||
                            (state == ST_EMIT_VALUE_BYTES));
    assign output_accept = m_axis_tvalid && m_axis_tready;

    // OPT-D3: tlast on the final beat of the entire record
    wire        is_last_shared_beat  = (state == ST_EMIT_KEY_BYTES) &&
                                       (unshared_len == 32'd0) && (value_len == 32'd0) &&
                                       (emit_index + shared_emit_cnt >= shared_len);
    wire        is_last_unshared_beat = (state == ST_EMIT_UNSHARED_KEY) &&
                                        (value_len == 32'd0) &&
                                        (emit_remain <= 32'd4);
    wire        is_last_value_beat    = (state == ST_EMIT_VALUE_BYTES) &&
                                        (emit_remain <= 32'd4);
    assign m_axis_tlast = is_last_shared_beat || is_last_unshared_beat || is_last_value_beat;

    // =========================================================================
    // OPT-3A: Merged capture + parse process — single always block so that
    // Vivado can infer block RAM for block_mem.  Capture sub-process runs
    // before the FSM case statement (last-NB-wins for start-cycle overrides).
    // =========================================================================
    always @(posedge clk) begin
        if (!rstn) begin
            cap_wptr     <= 32'd0;
            cap_done     <= 1'b0;
            cap_active   <= 1'b0;
            ra_valid     <= 1'b0;
            ra_offset_r  <= 32'd0;
            rc_count_r   <= 32'd0;
            tail_accum   <= 32'd0;
            cap_error    <= 1'b0;
            busy                     <= 1'b0;
            done                     <= 1'b0;
            error                    <= 1'b0;
            record_valid             <= 1'b0;
            record_key_len           <= 16'd0;
            record_value_len         <= 16'd0;
            record_shared_bytes      <= 16'd0;
            record_non_shared_bytes  <= 16'd0;
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
            parse_index              <= 32'd0;
            shared_len               <= 32'd0;
            unshared_len             <= 32'd0;
            value_len                <= 32'd0;
            prev_key_len             <= 32'd0;
            key_copy_index           <= 32'd0;
            varint_accum             <= 32'd0;
            varint_shift             <= 6'd0;
            varint_bytes             <= 3'd0;
            restart_scan_index       <= 32'd0;
            restart_prev_offset      <= 32'd0;
            fixed32_base_addr        <= 32'd0;
            fixed32_accum            <= 32'd0;
            fixed32_byte_index       <= 2'd0;
            fixed32_mode             <= FIXED32_MODE_COUNT;
            key_base_index           <= 32'd0;
            value_base_index         <= 32'd0;
            next_entry_index         <= 32'd0;
            emit_index               <= 32'd0;
            emit_remain              <= 32'd0;
            post_emit                <= 1'b0;
        end else if (clear) begin
            cap_wptr     <= 32'd0;
            cap_done     <= 1'b0;
            cap_active   <= 1'b0;
            ra_valid     <= 1'b0;
            ra_offset_r  <= 32'd0;
            rc_count_r   <= 32'd0;
            tail_accum   <= 32'd0;
            cap_error    <= 1'b0;
            busy                     <= 1'b0;
            done                     <= 1'b0;
            error                    <= 1'b0;
            record_valid             <= 1'b0;
            record_key_len           <= 16'd0;
            record_value_len         <= 16'd0;
            record_shared_bytes      <= 16'd0;
            record_non_shared_bytes  <= 16'd0;
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
            parse_index              <= 32'd0;
            shared_len               <= 32'd0;
            unshared_len             <= 32'd0;
            value_len                <= 32'd0;
            prev_key_len             <= 32'd0;
            key_copy_index           <= 32'd0;
            varint_accum             <= 32'd0;
            varint_shift             <= 6'd0;
            varint_bytes             <= 3'd0;
            restart_scan_index       <= 32'd0;
            restart_prev_offset      <= 32'd0;
            fixed32_base_addr        <= 32'd0;
            fixed32_accum            <= 32'd0;
            fixed32_byte_index       <= 2'd0;
            fixed32_mode             <= FIXED32_MODE_COUNT;
            key_base_index           <= 32'd0;
            value_base_index         <= 32'd0;
            next_entry_index         <= 32'd0;
            emit_index               <= 32'd0;
            emit_remain              <= 32'd0;
            post_emit                <= 1'b0;
        end else begin
            record_valid <= 1'b0;
            done <= 1'b0;
            next_varint_value = 32'd0;
            next_fixed32_value = 32'd0;

            // ---- Capture sub-process (writes block_mem, concurrent with parse) ----
            if (start && !busy) begin
                cap_wptr     <= 32'd0;
                cap_done     <= 1'b0;
                cap_active   <= 1'b1;
                ra_valid     <= 1'b0;
                ra_offset_r  <= 32'd0;
                rc_count_r   <= 32'd0;
                tail_accum   <= 32'd0;
                cap_error    <= 1'b0;
            end else if (cap_active && !cap_error) begin
                if (s_axis_tvalid && s_axis_tkeep[0] && s_axis_tready) begin
                    tail_accum <= {s_axis_tdata, tail_accum[31:8]};
                    if ((cap_wptr == (MAX_BLOCK_BYTES - 1)) && !s_axis_tlast) begin
                        cap_error  <= 1'b1;
                        cap_active <= 1'b0;
                    end else if (s_axis_tlast) begin
                        cap_done   <= 1'b1;
                        cap_active <= 1'b0;
                        cap_wptr   <= cap_wptr + 32'd1;
                    end else begin
                        cap_wptr   <= cap_wptr + 32'd1;
                    end
                end
            end

            // One cycle after cap_done: tail_accum is stable, compute restart info
            if (cap_done && !ra_valid && !cap_error) begin
                if (cap_wptr < 32'd8) begin
                    cap_error <= 1'b1;
                end else if (tail_accum == 32'd0) begin
                    cap_error <= 1'b1;
                end else if (((tail_accum + 32'd1) << 2) > cap_wptr) begin
                    cap_error <= 1'b1;
                end else begin
                    rc_count_r  <= tail_accum;
                    ra_offset_r <= cap_wptr - ((tail_accum + 32'd1) << 2);
                    ra_valid    <= 1'b1;
                end
            end

            // ---- Parse FSM ----
            if (start && !busy) begin
                busy                     <= 1'b1;
                done                     <= 1'b0;
                error                    <= 1'b0;
                record_valid             <= 1'b0;
                record_key_len           <= 16'd0;
                record_value_len         <= 16'd0;
                record_shared_bytes      <= 16'd0;
                record_non_shared_bytes  <= 16'd0;
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
                state                    <= ST_FETCH_SHARED;
                post_emit                <= 1'b0;
                parse_index              <= 32'd0;
                shared_len               <= 32'd0;
                unshared_len             <= 32'd0;
                value_len                <= 32'd0;
                prev_key_len             <= 32'd0;
                key_copy_index           <= 32'd0;
                varint_accum             <= 32'd0;
                varint_shift             <= 6'd0;
                varint_bytes             <= 3'd0;
                restart_scan_index       <= 32'd0;
                restart_prev_offset      <= 32'd0;
                fixed32_base_addr        <= 32'd0;
                fixed32_accum            <= 32'd0;
                fixed32_byte_index       <= 2'd0;
                fixed32_mode             <= FIXED32_MODE_OFFSET;
                key_base_index           <= 32'd0;
                value_base_index         <= 32'd0;
                next_entry_index         <= 32'd0;
                emit_index               <= 32'd0;
                emit_remain              <= 32'd0;
            end else if (busy && !error) begin
                if (cap_error) begin
                    busy  <= 1'b0;
                    error <= 1'b1;
                    state <= ST_IDLE;
                end else begin
                case (state)
                    // OPT-3A: ST_FETCH_FIXED32 only used for restart offset
                    // validation (FIXED32_MODE_OFFSET); restart_count extraction
                    // is handled by the capture process.
                    ST_FETCH_FIXED32: begin
                        if (fixed32_base_addr + {30'd0, fixed32_byte_index} < cap_wptr) begin
                            state <= ST_CONSUME_FIXED32;
                        end
                        // else: stall until capture catches up
                    end

                    ST_CONSUME_FIXED32: begin
                        next_fixed32_value = insert_u8_le(fixed32_accum, fetched_byte, fixed32_byte_index);
                        if (fixed32_byte_index != 2'd3) begin
                            fixed32_accum      <= next_fixed32_value;
                            fixed32_byte_index <= fixed32_byte_index + 2'd1;
                            state              <= ST_FETCH_FIXED32;
                        end else begin
                            // FIXED32_MODE_OFFSET: validate restart offset
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

                    // OPT-3A: entries-done check uses ra_valid/ra_offset_r;
                    // data-available check uses cap_wptr.
                    ST_FETCH_SHARED: begin
                        if (ra_valid && parse_index >= ra_offset_r) begin
                            // All entries parsed; latch restart info and scan offsets
                            restart_count        <= rc_count_r;
                            restart_array_offset <= ra_offset_r;
                            restart_scan_index   <= 32'd0;
                            restart_prev_offset  <= 32'd0;
                            post_emit            <= 1'b0;
                            state                <= ST_BEGIN_RESTART_SCAN;
                        end else if (post_emit && !ra_valid) begin
                            // OPT-D3 fix: returned from emit but ra_valid not yet set;
                            // stall to avoid parsing restart array bytes as entry data.
                        end else if (parse_index < cap_wptr) begin
                            parse_index  <= parse_index + 32'd1;
                            post_emit    <= 1'b0;
                            state        <= ST_CONSUME_SHARED;
                        end
                        // else: stall (data not yet captured)
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
                                // OPT-3A: inline prefetch with cap_wptr guard
                                if (parse_index < cap_wptr) begin
                                    parse_index  <= parse_index + 32'd1;
                                end else begin
                                    state <= ST_FETCH_SHARED;
                                end
                            end
                        end else begin
                            next_varint_value = varint_accum | ({24'd0, fetched_byte} << varint_shift);
                            shared_len   <= next_varint_value;
                            varint_accum <= 32'd0;
                            varint_shift <= 6'd0;
                            varint_bytes <= 3'd0;
                            if (ra_valid && parse_index >= ra_offset_r) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else if (parse_index < cap_wptr) begin
                                parse_index  <= parse_index + 32'd1;
                                state        <= ST_CONSUME_UNSHARED;
                            end else begin
                                state <= ST_FETCH_UNSHARED;
                            end
                        end
                    end

                    ST_FETCH_UNSHARED: begin
                        if (ra_valid && parse_index >= ra_offset_r) begin
                            busy  <= 1'b0;
                            error <= 1'b1;
                            state <= ST_IDLE;
                        end else if (parse_index < cap_wptr) begin
                            parse_index  <= parse_index + 32'd1;
                            state        <= ST_CONSUME_UNSHARED;
                        end
                        // else: stall
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
                                if (parse_index < cap_wptr) begin
                                    parse_index  <= parse_index + 32'd1;
                                end else begin
                                    state <= ST_FETCH_UNSHARED;
                                end
                            end
                        end else begin
                            next_varint_value = varint_accum | ({24'd0, fetched_byte} << varint_shift);
                            unshared_len <= next_varint_value;
                            varint_accum <= 32'd0;
                            varint_shift <= 6'd0;
                            varint_bytes <= 3'd0;
                            if (ra_valid && parse_index >= ra_offset_r) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else if (parse_index < cap_wptr) begin
                                parse_index  <= parse_index + 32'd1;
                                state        <= ST_CONSUME_VALUE_LEN;
                            end else begin
                                state <= ST_FETCH_VALUE_LEN;
                            end
                        end
                    end

                    ST_FETCH_VALUE_LEN: begin
                        if (ra_valid && parse_index >= ra_offset_r) begin
                            busy  <= 1'b0;
                            error <= 1'b1;
                            state <= ST_IDLE;
                        end else if (parse_index < cap_wptr) begin
                            parse_index  <= parse_index + 32'd1;
                            state        <= ST_CONSUME_VALUE_LEN;
                        end
                        // else: stall
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
                                if (parse_index < cap_wptr) begin
                                    parse_index  <= parse_index + 32'd1;
                                end else begin
                                    state <= ST_FETCH_VALUE_LEN;
                                end
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
                            (ra_valid && ((parse_index + unshared_len + value_len) > ra_offset_r))) begin
                            busy  <= 1'b0;
                            error <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            key_base_index   <= parse_index;
                            value_base_index <= parse_index + unshared_len;
                            next_entry_index <= parse_index + unshared_len + value_len;
                            key_copy_index   <= 32'd0;
                            // OPT-A1: skip copy phase entirely; emit directly
                            state <= ST_EMIT_ENTRY;
                        end
                    end

                    // OPT-D3: prep first 4-byte BRAM read for unshared key emit
                    ST_PREP_EMIT_UNSHARED: begin
                        // Wait for 4-bank read to be issued (emit_rd_en_comb)
                        // The combinational logic checks key_base_index + key_copy_index + 3 < cap_wptr
                        // For final partial word (< 4 bytes), still need all data captured
                        if (emit_rd_en_comb) begin
                            emit_remain <= unshared_len - key_copy_index;
                            state <= ST_EMIT_UNSHARED_KEY;
                        end else if (unshared_len - key_copy_index < 32'd4 &&
                                    key_base_index + key_copy_index + (unshared_len - key_copy_index) <= cap_wptr) begin
                            // Partial final word: fewer than 4 bytes remain, but all captured
                            emit_remain <= unshared_len - key_copy_index;
                            state <= ST_EMIT_UNSHARED_KEY;
                        end
                        // else: stall until capture catches up
                    end

                    // OPT-D3: emit unshared key bytes from BRAM at 4 bytes/cycle
                    ST_EMIT_UNSHARED_KEY: begin
                        if (output_accept) begin
                            // Update prev_key_mem with up to 4 unshared key bytes
                            prev_key_mem[shared_len + key_copy_index] <= bram_emit_word[7:0];
                            if (emit_remain > 32'd1)
                                prev_key_mem[shared_len + key_copy_index + 32'd1] <= bram_emit_word[15:8];
                            if (emit_remain > 32'd2)
                                prev_key_mem[shared_len + key_copy_index + 32'd2] <= bram_emit_word[23:16];
                            if (emit_remain > 32'd3)
                                prev_key_mem[shared_len + key_copy_index + 32'd3] <= bram_emit_word[31:24];

                            if (emit_remain <= 32'd4) begin
                                // Unshared key done
                                if (value_len != 32'd0) begin
                                    emit_index <= 32'd0;
                                    state      <= ST_PREP_EMIT_VALUE;
                                end else begin
                                    post_emit <= 1'b1;
                                    state <= ST_FETCH_SHARED;
                                end
                            end else begin
                                // More unshared bytes: prefetch next 4 if available
                                key_copy_index <= key_copy_index + 32'd4;
                                emit_remain    <= emit_remain - 32'd4;
                                if (!emit_rd_en_comb) begin
                                    // Next 4 bytes not yet captured; stall
                                    state <= ST_PREP_EMIT_UNSHARED;
                                end
                                // else: emit_rd_en_comb issued next read, stay in this state
                            end
                        end
                    end

                    ST_EMIT_ENTRY: begin
                        if (record_ready) begin
                            decoded_entry_count      <= decoded_entry_count + 32'd1;
                            shared_key_bytes_total   <= shared_key_bytes_total + shared_len;
                            unshared_key_bytes_total <= unshared_key_bytes_total + unshared_len;
                            value_bytes_total        <= value_bytes_total + value_len;
                            if (shared_len == 32'd0) begin
                                restart_entry_count <= restart_entry_count + 32'd1;
                            end
                            prev_key_len         <= current_key_len_w;
                            last_key_len         <= current_key_len_w[15:0];
                            last_value_len       <= value_len[15:0];
                            last_shared_bytes    <= shared_len[15:0];
                            last_non_shared_bytes <= unshared_len[15:0];
                            record_key_len       <= current_key_len_w[15:0];
                            record_value_len     <= value_len[15:0];
                            record_shared_bytes  <= shared_len[15:0];
                            record_non_shared_bytes <= unshared_len[15:0];
                            record_valid         <= 1'b1;
                            parse_index          <= next_entry_index;
                            emit_index           <= 32'd0;
                            key_copy_index       <= 32'd0;
                            // OPT-A1: route to shared/unshared/value phases
                            if (shared_len != 32'd0) begin
                                state <= ST_EMIT_KEY_BYTES;
                            end else if (unshared_len != 32'd0) begin
                                state <= ST_PREP_EMIT_UNSHARED;
                            end else if (value_len != 32'd0) begin
                                state <= ST_PREP_EMIT_VALUE;
                            end else begin
                                post_emit <= 1'b1;
                                state <= ST_FETCH_SHARED;
                            end
                        end
                    end

                    // OPT-D3: emit shared key prefix from prev_key_mem at 4 bytes/cycle
                    ST_EMIT_KEY_BYTES: begin
                        if (output_accept) begin
                            if (emit_index + shared_emit_cnt >= shared_len) begin
                                // Shared prefix done; route to next phase
                                if (unshared_len != 32'd0) begin
                                    key_copy_index <= 32'd0;
                                    state <= ST_PREP_EMIT_UNSHARED;
                                end else if (value_len != 32'd0) begin
                                    emit_index <= 32'd0;
                                    state      <= ST_PREP_EMIT_VALUE;
                                end else begin
                                    post_emit <= 1'b1;
                                    state <= ST_FETCH_SHARED;
                                end
                            end else begin
                                emit_index <= emit_index + shared_emit_cnt;
                            end
                        end
                    end

                    // OPT-D3: stall if value data not yet captured (4-byte check)
                    ST_PREP_EMIT_VALUE: begin
                        if (emit_rd_en_comb) begin
                            emit_remain <= value_len - emit_index;
                            state       <= ST_EMIT_VALUE_BYTES;
                        end else if (value_len - emit_index < 32'd4 &&
                                    value_base_index + emit_index + (value_len - emit_index) <= cap_wptr) begin
                            // Partial final word
                            emit_remain <= value_len - emit_index;
                            state       <= ST_EMIT_VALUE_BYTES;
                        end
                        // else: stall
                    end

                    // OPT-D3: emit value bytes from BRAM at 4 bytes/cycle
                    ST_EMIT_VALUE_BYTES: begin
                        if (output_accept) begin
                            if (emit_remain <= 32'd4) begin
                                post_emit <= 1'b1;
                                state <= ST_FETCH_SHARED;
                            end else begin
                                emit_index  <= emit_index + 32'd4;
                                emit_remain <= emit_remain - 32'd4;
                                if (!emit_rd_en_comb) begin
                                    // Next 4 bytes not yet captured; stall
                                    state <= ST_PREP_EMIT_VALUE;
                                end
                                // else: stay, next read already issued
                            end
                        end
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
                end // cap_error else
            end

        end
    end

endmodule
