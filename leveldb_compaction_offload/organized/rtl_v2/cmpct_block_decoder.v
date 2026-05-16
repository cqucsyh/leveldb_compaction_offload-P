`timescale 1ns / 1ps

module cmpct_block_decoder #(
    parameter integer MAX_BLOCK_BYTES = 4096,
    parameter integer MAX_KEY_BYTES   = 256
) (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire        start,
    input  wire [31:0] block_byte_count,  // OPT-3A: externally provided block size
    // P9: 64-bit wide input (8 bytes/cycle capture)
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
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
    // P3: 64-bit wide output (8 bytes/cycle)
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
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

    // OPT-D4: Safe parse limit — conservative upper bound for data region.
    // The restart array is at least 4 bytes (count word). With restart_interval=16
    // and minimum entry size >= 11 bytes, max restarts = ceil(B/(11*16)).
    // RESTART_GUARD = MAX_BLOCK_BYTES/16 + 4 covers all valid LevelDB blocks.
    localparam RESTART_GUARD = (MAX_BLOCK_BYTES >> 4) + 4;
    reg [31:0] safe_parse_limit_r;  // = block_byte_count - RESTART_GUARD (or 0)

    // OPT-T3: Pre-registered prev_key_mem write base to break ADD→array-decode path
    reg [31:0] pkm_wr_base_r;    // = shared_len + key_copy_index (pre-computed)

    reg [31:0] next_varint_value;
    reg [31:0] next_fixed32_value;

    wire [31:0] current_key_len_w;
    wire        output_accept;

    // OPT-D3: 4 bytes emitted per cycle — remaining byte count in current phase
    reg  [31:0] emit_remain;      // bytes remaining in current emit phase

    // ---- BRAM via 8-bank interleaved cmpct_sdpram (P3/P9) ----
    // Each bank stores every 8th byte: bank[b] stores addresses where addr[2:0]==b.
    // P9: Write up to 8 bytes/cycle from 64-bit input, routing by cap_wptr alignment.
    // Read:  all 8 banks in parallel → 8 bytes/cycle.
    //        For parse (single byte): read all banks at parse_addr>>3, mux by parse_addr[2:0].
    //        For emit (8 bytes):      each bank gets its own address based on emit base.
    localparam BMEM_WORD_AW = (BMEM_AW > 3) ? (BMEM_AW - 3) : 1;

    // P9: Count valid bytes in input beat (popcount of tkeep)
    wire [3:0] s_axis_byte_count = {3'b0, s_axis_tkeep[0]} + {3'b0, s_axis_tkeep[1]}
                                 + {3'b0, s_axis_tkeep[2]} + {3'b0, s_axis_tkeep[3]}
                                 + {3'b0, s_axis_tkeep[4]} + {3'b0, s_axis_tkeep[5]}
                                 + {3'b0, s_axis_tkeep[6]} + {3'b0, s_axis_tkeep[7]};

    wire        bram_we_comb = s_axis_tvalid && (s_axis_tkeep != 8'd0) && s_axis_tready;
    wire        entries_done_w = ra_valid && (parse_index >= ra_offset_r);
    wire        varint_overflow_w = (varint_shift >= 6'd28) || (varint_bytes == 3'd4);

    // P9: Per-bank write enables — up to 8 banks written simultaneously.
    // Bank b is written if input byte at position ((b - cap_wptr[2:0]) & 7) is valid.
    wire [2:0] cap_offset = cap_wptr[2:0];
    wire [7:0] bank_we;
    genvar gwi;
    generate
        for (gwi = 0; gwi < 8; gwi = gwi + 1) begin : gen_bank_we
            // Which input byte position maps to this bank?
            wire [2:0] byte_pos = (gwi[2:0] - cap_offset) & 3'b111;  // barrel rotation
            assign bank_we[gwi] = bram_we_comb && s_axis_tkeep[byte_pos];
        end
    endgenerate

    // P9: Per-bank write data — route input byte to correct bank
    wire [7:0] bank_wdata [0:7];
    generate
        for (gwi = 0; gwi < 8; gwi = gwi + 1) begin : gen_bank_wdata
            wire [2:0] byte_pos_w = (gwi[2:0] - cap_offset) & 3'b111;
            assign bank_wdata[gwi] = s_axis_tdata[byte_pos_w*8 +: 8];
        end
    endgenerate

    // P9: Per-bank write address — bank b gets word addr cap_wptr>>3 if b >= cap_offset,
    //     else (cap_wptr>>3)+1 (the byte wraps to next word)
    wire [BMEM_WORD_AW-1:0] cap_waddr_base = cap_wptr[BMEM_AW-1:3];
    wire [BMEM_WORD_AW-1:0] cap_waddr_next = cap_wptr[BMEM_AW-1:3] + {{(BMEM_WORD_AW-1){1'b0}}, 1'b1};
    wire [BMEM_WORD_AW-1:0] bank_waddr [0:7];
    generate
        for (gwi = 0; gwi < 8; gwi = gwi + 1) begin : gen_bank_waddr
            assign bank_waddr[gwi] = (gwi[2:0] >= cap_offset) ? cap_waddr_base : cap_waddr_next;
        end
    endgenerate

    // Bank read data outputs
    wire [7:0] bank_rdata [0:7];

    // Read address / enable per bank
    reg [BMEM_AW-1:0] bank_raddr [0:7];
    reg                bank_re   [0:7];

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

    // --- Emit-phase: 8-byte parallel read from 8 banks (P3) ---
    // emit_rd_base is the byte address of the first byte to read in the current emit beat.
    reg [31:0] emit_rd_base_comb;
    reg        emit_rd_en_comb;

    always @(*) begin
        emit_rd_en_comb = 1'b0;
        emit_rd_base_comb = 32'd0;
        if (busy && !error && !cap_error) begin
            case (state)
                ST_PREP_EMIT_UNSHARED: begin
                    if (key_base_index + key_copy_index + 32'd7 < cap_wptr) begin
                        emit_rd_base_comb = key_base_index + key_copy_index;
                        emit_rd_en_comb = 1'b1;
                    end
                end
                ST_EMIT_UNSHARED_KEY: begin
                    if (output_accept && emit_remain > 32'd8) begin
                        if (key_base_index + key_copy_index + 32'd8 + 32'd7 < cap_wptr) begin
                            emit_rd_base_comb = key_base_index + key_copy_index + 32'd8;
                            emit_rd_en_comb = 1'b1;
                        end
                    end
                end
                ST_PREP_EMIT_VALUE: begin
                    if (value_base_index + emit_index + 32'd7 < cap_wptr) begin
                        emit_rd_base_comb = value_base_index + emit_index;
                        emit_rd_en_comb = 1'b1;
                    end
                end
                ST_EMIT_VALUE_BYTES: begin
                    if (output_accept && emit_remain > 32'd8) begin
                        if (value_base_index + emit_index + 32'd8 + 32'd7 < cap_wptr) begin
                            emit_rd_base_comb = value_base_index + emit_index + 32'd8;
                            emit_rd_en_comb = 1'b1;
                        end
                    end
                end
                default: ;
            endcase
        end
    end

    // --- Bank address generation ---
    // For parse: all banks read at parse_rd_addr>>3; fetched_byte selected by parse_rd_addr[2:0].
    // For emit:  bank b reads at (emit_base + ((b - emit_base[2:0]) & 7)) >> 3.
    //            If b < emit_base[2:0], the byte wraps to the next word → addr = (emit_base>>3)+1.
    wire [2:0] emit_offset = emit_rd_base_comb[2:0];
    wire        is_emit_phase = (state == ST_PREP_EMIT_UNSHARED) || (state == ST_EMIT_UNSHARED_KEY) ||
                                (state == ST_PREP_EMIT_VALUE)    || (state == ST_EMIT_VALUE_BYTES);

    // P3: compute per-bank read addresses (8 banks)
    always @(*) begin : bank_addr_gen
        integer b;
        for (b = 0; b < 8; b = b + 1) begin
            if (is_emit_phase && emit_rd_en_comb) begin
                // Emit: bank b stores bytes where addr[2:0]==b.
                // For emit word starting at emit_base:
                //   If b >= emit_offset: same word as emit_base → word_addr = emit_base >> 3
                //   If b <  emit_offset: next word             → word_addr = (emit_base >> 3) + 1
                if (b[2:0] >= emit_offset)
                    bank_raddr[b] = {{(BMEM_AW - BMEM_WORD_AW){1'b0}}, emit_rd_base_comb[BMEM_AW-1:3]};
                else
                    bank_raddr[b] = {{(BMEM_AW - BMEM_WORD_AW){1'b0}}, emit_rd_base_comb[BMEM_AW-1:3]} + {{(BMEM_AW-1){1'b0}}, 1'b1};
                bank_re[b] = 1'b1;
            end else begin
                // Parse: all banks read from same word address
                bank_raddr[b] = parse_rd_addr_comb[BMEM_AW-1:0] >> 3;
                bank_re[b] = parse_rd_en_comb;
            end
        end
    end

    // P9: Instantiate 8 BRAM banks with per-bank write data/address
    generate
        for (gwi = 0; gwi < 8; gwi = gwi + 1) begin : gen_bank
            cmpct_sdpram #(
                .DEPTH ((MAX_BLOCK_BYTES + 7) / 8),
                .WIDTH (8)
            ) u_block_bank (
                .clk   (clk),
                .we    (bank_we[gwi]),
                .waddr (bank_waddr[gwi]),
                .wdata (bank_wdata[gwi]),
                .re    (bank_re[gwi]),
                .raddr (bank_raddr[gwi][BMEM_WORD_AW-1:0]),
                .rdata (bank_rdata[gwi])
            );
        end
    endgenerate

    // Parse: select single byte from appropriate bank (1-cycle latency)
    reg [2:0] parse_rd_addr_d;  // delayed low 3 bits for bank selection
    always @(posedge clk) begin
        if (parse_rd_en_comb)
            parse_rd_addr_d <= parse_rd_addr_comb[2:0];
    end
    assign fetched_byte = bank_rdata[parse_rd_addr_d];

    // P3: Compose 8-byte emit word from bank outputs, reordered by emit offset
    // emit_offset_d is the delayed emit_rd_base[2:0] from the previous cycle
    reg [2:0] emit_offset_d;
    always @(posedge clk) begin
        if (emit_rd_en_comb)
            emit_offset_d <= emit_rd_base_comb[2:0];
    end

    // Barrel-shift bank outputs: byte k of emit word = bank[(emit_offset_d + k) % 8]
    wire [7:0] emit_byte0 = bank_rdata[(emit_offset_d + 3'd0) & 3'd7];
    wire [7:0] emit_byte1 = bank_rdata[(emit_offset_d + 3'd1) & 3'd7];
    wire [7:0] emit_byte2 = bank_rdata[(emit_offset_d + 3'd2) & 3'd7];
    wire [7:0] emit_byte3 = bank_rdata[(emit_offset_d + 3'd3) & 3'd7];
    wire [7:0] emit_byte4 = bank_rdata[(emit_offset_d + 3'd4) & 3'd7];
    wire [7:0] emit_byte5 = bank_rdata[(emit_offset_d + 3'd5) & 3'd7];
    wire [7:0] emit_byte6 = bank_rdata[(emit_offset_d + 3'd6) & 3'd7];
    wire [7:0] emit_byte7 = bank_rdata[(emit_offset_d + 3'd7) & 3'd7];
    wire [63:0] bram_emit_word = {emit_byte7, emit_byte6, emit_byte5, emit_byte4,
                                  emit_byte3, emit_byte2, emit_byte1, emit_byte0};

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

    // P9: s_axis_tready driven by capture process.
    // Accept if there's room for at least 1 byte (final beat may be partial with tlast).
    // Overflow is caught in the capture FSM if cap_wptr + byte_count > MAX without tlast.
    assign s_axis_tready = cap_active && !cap_error && (cap_wptr < MAX_BLOCK_BYTES);

    assign current_key_len_w = shared_len + unshared_len;

    // P3: 64-bit emit data path (8 bytes/cycle)
    // Number of valid bytes this beat for shared-prefix emit
    wire [31:0] shared_emit_cnt = (shared_len - emit_index >= 32'd8) ? 32'd8 :
                                   shared_len - emit_index;
    // Compose 64-bit word from prev_key_mem for shared prefix
    wire [7:0] pkm_b0 = prev_key_mem[emit_index];
    wire [7:0] pkm_b1 = (shared_emit_cnt > 32'd1) ? prev_key_mem[emit_index + 32'd1] : 8'd0;
    wire [7:0] pkm_b2 = (shared_emit_cnt > 32'd2) ? prev_key_mem[emit_index + 32'd2] : 8'd0;
    wire [7:0] pkm_b3 = (shared_emit_cnt > 32'd3) ? prev_key_mem[emit_index + 32'd3] : 8'd0;
    wire [7:0] pkm_b4 = (shared_emit_cnt > 32'd4) ? prev_key_mem[emit_index + 32'd4] : 8'd0;
    wire [7:0] pkm_b5 = (shared_emit_cnt > 32'd5) ? prev_key_mem[emit_index + 32'd5] : 8'd0;
    wire [7:0] pkm_b6 = (shared_emit_cnt > 32'd6) ? prev_key_mem[emit_index + 32'd6] : 8'd0;
    wire [7:0] pkm_b7 = (shared_emit_cnt > 32'd7) ? prev_key_mem[emit_index + 32'd7] : 8'd0;
    wire [63:0] shared_emit_word = {pkm_b7, pkm_b6, pkm_b5, pkm_b4,
                                    pkm_b3, pkm_b2, pkm_b1, pkm_b0};

    // Number of valid bytes this beat for BRAM-based emit
    wire [31:0] bram_emit_cnt = (emit_remain >= 32'd8) ? 32'd8 : emit_remain;

    // Generate tkeep from valid byte count (8-bit)
    wire [7:0] emit_tkeep_from_cnt;
    wire [31:0] active_emit_cnt = (state == ST_EMIT_KEY_BYTES) ? shared_emit_cnt : bram_emit_cnt;
    assign emit_tkeep_from_cnt = (active_emit_cnt >= 32'd8) ? 8'b11111111 :
                                 (active_emit_cnt == 32'd7) ? 8'b01111111 :
                                 (active_emit_cnt == 32'd6) ? 8'b00111111 :
                                 (active_emit_cnt == 32'd5) ? 8'b00011111 :
                                 (active_emit_cnt == 32'd4) ? 8'b00001111 :
                                 (active_emit_cnt == 32'd3) ? 8'b00000111 :
                                 (active_emit_cnt == 32'd2) ? 8'b00000011 :
                                 (active_emit_cnt == 32'd1) ? 8'b00000001 : 8'b00000000;

    assign m_axis_tdata = (state == ST_EMIT_KEY_BYTES) ? shared_emit_word : bram_emit_word;
    assign m_axis_tkeep = emit_tkeep_from_cnt;
    assign m_axis_tvalid = busy && !error &&
                           ((state == ST_EMIT_KEY_BYTES) ||
                            (state == ST_EMIT_UNSHARED_KEY) ||
                            (state == ST_EMIT_VALUE_BYTES));
    assign output_accept = m_axis_tvalid && m_axis_tready;

    // P3: tlast on the final beat of the entire record
    wire        is_last_shared_beat  = (state == ST_EMIT_KEY_BYTES) &&
                                       (unshared_len == 32'd0) && (value_len == 32'd0) &&
                                       (emit_index + shared_emit_cnt >= shared_len);
    wire        is_last_unshared_beat = (state == ST_EMIT_UNSHARED_KEY) &&
                                        (value_len == 32'd0) &&
                                        (emit_remain <= 32'd8);
    wire        is_last_value_beat    = (state == ST_EMIT_VALUE_BYTES) &&
                                        (emit_remain <= 32'd8);
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
            safe_parse_limit_r       <= 32'd0;
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
            safe_parse_limit_r       <= 32'd0;
        end else begin
            record_valid <= 1'b0;
            done <= 1'b0;
            next_varint_value = 32'd0;
            next_fixed32_value = 32'd0;

            // ---- P9: Capture sub-process (8 bytes/cycle from 64-bit input) ----
            if (start && !busy) begin
                cap_wptr     <= 32'd0;
                cap_done     <= 1'b0;
                cap_active   <= 1'b1;
                ra_valid     <= 1'b0;
                ra_offset_r  <= 32'd0;
                rc_count_r   <= 32'd0;
                tail_accum   <= 32'd0;
                cap_error    <= 1'b0;
                // OPT-D4: compute safe parse limit at start
                safe_parse_limit_r <= (block_byte_count > RESTART_GUARD[31:0])
                                    ? (block_byte_count - RESTART_GUARD[31:0])
                                    : 32'd0;
            end else if (cap_active && !cap_error) begin
                if (s_axis_tvalid && (s_axis_tkeep != 8'd0) && s_axis_tready) begin
                    // P9: Update tail_accum with the last 4 bytes of this beat.
                    // Shift in valid bytes from LSB to MSB order in tail_accum.
                    // We need the last 4 captured bytes overall — update a sliding
                    // window by shifting in s_axis_byte_count bytes.
                    case (s_axis_byte_count)
                        4'd1: tail_accum <= {s_axis_tdata[7:0],   tail_accum[31:8]};
                        4'd2: tail_accum <= {s_axis_tdata[15:0],  tail_accum[31:16]};
                        4'd3: tail_accum <= {s_axis_tdata[23:0],  tail_accum[31:24]};
                        4'd4: tail_accum <= s_axis_tdata[31:0];
                        4'd5: tail_accum <= s_axis_tdata[39:8];
                        4'd6: tail_accum <= s_axis_tdata[47:16];
                        4'd7: tail_accum <= s_axis_tdata[55:24];
                        default: tail_accum <= s_axis_tdata[63:32]; // 8 bytes
                    endcase

                    if ((cap_wptr + {28'd0, s_axis_byte_count} > MAX_BLOCK_BYTES) &&
                        !s_axis_tlast) begin
                        cap_error  <= 1'b1;
                        cap_active <= 1'b0;
                    end else if (s_axis_tlast) begin
                        cap_done   <= 1'b1;
                        cap_active <= 1'b0;
                        cap_wptr   <= cap_wptr + {28'd0, s_axis_byte_count};
                    end else begin
                        cap_wptr   <= cap_wptr + {28'd0, s_axis_byte_count};
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
                        end else if (post_emit && !ra_valid && (parse_index >= safe_parse_limit_r)) begin
                            // OPT-D4: stall only when near restart array boundary.
                            // When parse_index < safe_parse_limit_r, it's safe to
                            // continue parsing; we can't be in the restart array yet.
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
                            // OPT-T3: pre-compute write base for upcoming unshared emit
                            pkm_wr_base_r    <= shared_len;
                            // OPT-A1: skip copy phase entirely; emit directly
                            state <= ST_EMIT_ENTRY;
                        end
                    end

                    // P3: prep first 8-byte BRAM read for unshared key emit
                    ST_PREP_EMIT_UNSHARED: begin
                        // Wait for 8-bank read to be issued (emit_rd_en_comb)
                        // The combinational logic checks key_base_index + key_copy_index + 7 < cap_wptr
                        // For final partial word (< 8 bytes), still need all data captured
                        if (emit_rd_en_comb) begin
                            emit_remain <= unshared_len - key_copy_index;
                            state <= ST_EMIT_UNSHARED_KEY;
                        end else if (unshared_len - key_copy_index < 32'd8 &&
                                    key_base_index + key_copy_index + (unshared_len - key_copy_index) <= cap_wptr) begin
                            // Partial final word: fewer than 8 bytes remain, but all captured
                            emit_remain <= unshared_len - key_copy_index;
                            state <= ST_EMIT_UNSHARED_KEY;
                        end
                        // else: stall until capture catches up
                    end

                    // P3: emit unshared key bytes from BRAM at 8 bytes/cycle
                    ST_EMIT_UNSHARED_KEY: begin
                        if (output_accept) begin
                            // P3: Write up to 8 bytes to prev_key_mem
                            prev_key_mem[pkm_wr_base_r] <= bram_emit_word[7:0];
                            if (emit_remain > 32'd1)
                                prev_key_mem[pkm_wr_base_r + 32'd1] <= bram_emit_word[15:8];
                            if (emit_remain > 32'd2)
                                prev_key_mem[pkm_wr_base_r + 32'd2] <= bram_emit_word[23:16];
                            if (emit_remain > 32'd3)
                                prev_key_mem[pkm_wr_base_r + 32'd3] <= bram_emit_word[31:24];
                            if (emit_remain > 32'd4)
                                prev_key_mem[pkm_wr_base_r + 32'd4] <= bram_emit_word[39:32];
                            if (emit_remain > 32'd5)
                                prev_key_mem[pkm_wr_base_r + 32'd5] <= bram_emit_word[47:40];
                            if (emit_remain > 32'd6)
                                prev_key_mem[pkm_wr_base_r + 32'd6] <= bram_emit_word[55:48];
                            if (emit_remain > 32'd7)
                                prev_key_mem[pkm_wr_base_r + 32'd7] <= bram_emit_word[63:56];

                            if (emit_remain <= 32'd8) begin
                                // Unshared key done
                                if (value_len != 32'd0) begin
                                    emit_index <= 32'd0;
                                    state      <= ST_PREP_EMIT_VALUE;
                                end else begin
                                    post_emit <= 1'b1;
                                    state <= ST_FETCH_SHARED;
                                end
                            end else begin
                                // More unshared bytes: prefetch next 8 if available
                                key_copy_index  <= key_copy_index + 32'd8;
                                pkm_wr_base_r   <= pkm_wr_base_r + 32'd8;
                                emit_remain     <= emit_remain - 32'd8;
                                if (!emit_rd_en_comb) begin
                                    // Next 8 bytes not yet captured; stall
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

                    // P3: emit shared key prefix from prev_key_mem at 8 bytes/cycle
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

                    // P3: stall if value data not yet captured (8-byte check)
                    ST_PREP_EMIT_VALUE: begin
                        if (emit_rd_en_comb) begin
                            emit_remain <= value_len - emit_index;
                            state       <= ST_EMIT_VALUE_BYTES;
                        end else if (value_len - emit_index < 32'd8 &&
                                    value_base_index + emit_index + (value_len - emit_index) <= cap_wptr) begin
                            // Partial final word
                            emit_remain <= value_len - emit_index;
                            state       <= ST_EMIT_VALUE_BYTES;
                        end
                        // else: stall
                    end

                    // P3: emit value bytes from BRAM at 8 bytes/cycle
                    ST_EMIT_VALUE_BYTES: begin
                        if (output_accept) begin
                            if (emit_remain <= 32'd8) begin
                                post_emit <= 1'b1;
                                state <= ST_FETCH_SHARED;
                            end else begin
                                emit_index  <= emit_index + 32'd8;
                                emit_remain <= emit_remain - 32'd8;
                                if (!emit_rd_en_comb) begin
                                    // Next 8 bytes not yet captured; stall
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
