// cmpct_assembler.v — SUPERSEDED by cmpct_assembler_v2.v (memory write-port interface)
// This file is intentionally empty. The module is defined in cmpct_assembler_v2.v.
// To compile, include cmpct_assembler_v2.v instead of this file.
`ifdef NEVER_DEFINE_THIS
`timescale 1ns / 1ps
// cmpct_assembler: writes index block, metaindex block, and footer.
// Index block entry: shared=0, unshared=key_len, value_len=bh_enc_len, key, bh.
// Metaindex: empty block + 5-byte trailer (13 bytes total).
// Footer: 48 bytes (metaindex_bh, index_bh zero-padded to 40B, magic 8B).
module cmpct_assembler #(
    parameter integer AXI_ADDR_WIDTH  = 64,
    parameter integer AXI_DATA_WIDTH  = 512,
    parameter integer AXI_ID_WIDTH    = 1,
    parameter integer MAX_BURST_LEN   = 16,
    parameter integer MAX_BLOCK_PAIRS = 8,
    parameter integer MAX_KEY_BYTES   = 256
) (
    input  wire                                          clk,
    input  wire                                          rstn,
    input  wire                                          clear,
    input  wire                                          start,
    input  wire [AXI_ADDR_WIDTH-1:0]                    dst_base_addr,
    input  wire [31:0]                                   data_end_offset,
    input  wire [31:0]                                   num_blocks,
    input  wire [MAX_BLOCK_PAIRS*64-1:0]                 block_offset_vec,
    input  wire [MAX_BLOCK_PAIRS*32-1:0]                 block_size_vec,
    input  wire [MAX_BLOCK_PAIRS*16-1:0]                 last_key_len_vec,
    input  wire [MAX_BLOCK_PAIRS*(MAX_KEY_BYTES*8)-1:0]  last_key_bytes_vec,
    output reg                                           busy,
    output reg                                           done,
    output reg                                           error,
    output reg  [31:0]                                   total_bytes,
    // AXI write master (write-only)
    output wire [AXI_ADDR_WIDTH-1:0]                    m_axi_awaddr,
    output wire [7:0]                                    m_axi_awlen,
    output wire [2:0]                                    m_axi_awsize,
    output wire [1:0]                                    m_axi_awburst,
    output wire                                          m_axi_awvalid,
    input  wire                                          m_axi_awready,
    output wire [AXI_DATA_WIDTH-1:0]                     m_axi_wdata,
    output wire [(AXI_DATA_WIDTH/8)-1:0]                 m_axi_wstrb,
    output wire                                          m_axi_wlast,
    output wire                                          m_axi_wvalid,
    input  wire                                          m_axi_wready,
    input  wire [1:0]                                    m_axi_bresp,
    input  wire                                          m_axi_bvalid,
    output wire                                          m_axi_bready
);

    localparam AXI_KEEP_WIDTH = AXI_DATA_WIDTH / 8;
    localparam BUF_AW         = 7;   // footer byte-position counter (max 48)

    // -----------------------------------------------------------------------
    // State encoding
    // -----------------------------------------------------------------------
    localparam [4:0]
        ST_IDLE        = 5'd0,
        ST_IDX_INIT    = 5'd1,
        ST_ENT_SHARED  = 5'd2,
        ST_ENT_USHLEN  = 5'd3,
        ST_ENT_VALLEN  = 5'd4,
        ST_ENT_KEY     = 5'd5,
        ST_ENT_BHOFF   = 5'd6,
        ST_ENT_BHSZ    = 5'd7,
        ST_ENT_NEXT    = 5'd8,
        ST_IDX_REST    = 5'd9,
        ST_IDX_TRAIL   = 5'd10,
        ST_SEND        = 5'd11,
        ST_WR_WAIT     = 5'd12,
        ST_META_INIT   = 5'd13,
        ST_META_BODY   = 5'd14,
        ST_FOOT_INIT   = 5'd15,
        ST_FOOT_OFF0   = 5'd16,
        ST_FOOT_SZ0    = 5'd17,
        ST_FOOT_OFF1   = 5'd18,
        ST_FOOT_SZ1    = 5'd19,
        ST_FOOT_PAD    = 5'd20,
        ST_FOOT_MAGIC  = 5'd21,
        ST_DONE        = 5'd22,
        ST_COMPUTE_IDX = 5'd23;

    // -----------------------------------------------------------------------
    // CRC32c step (Castagnoli, reversed poly 0x82F63B78)
    // -----------------------------------------------------------------------
    function [31:0] crc32c_step;
        input [31:0] crc;
        input [7:0]  b;
        integer      k;
        reg   [31:0] c;
        begin
            c = crc ^ {24'h0, b};
            for (k = 0; k < 8; k = k + 1)
                c = c[0] ? ((c >> 1) ^ 32'h82F63B78) : (c >> 1);
            crc32c_step = c;
        end
    endfunction

    // -----------------------------------------------------------------------
    // Varint32 helpers
    // -----------------------------------------------------------------------
    function [2:0] vlen32;
        input [31:0] v;
        begin
            if      (v <  32'd128)       vlen32 = 3'd1;
            else if (v <  32'd16384)     vlen32 = 3'd2;
            else if (v <  32'd2097152)   vlen32 = 3'd3;
            else if (v <  32'd268435456) vlen32 = 3'd4;
            else                          vlen32 = 3'd5;
        end
    endfunction

    // Index block entry byte-count: 1(shared) + vl_kl + vl_bh + kl + vl_off + vl_sz
    function [31:0] entry_bytes_for;
        input [63:0] off;
        input [31:0] sz;
        input [15:0] kl;
        reg   [2:0]  vl_off, vl_sz;
        reg   [31:0] vl_bh_sum;
        begin
            vl_off    = vlen32(off[31:0]);
            vl_sz     = vlen32(sz - 32'd5);
            vl_bh_sum = {29'b0, vl_off} + {29'b0, vl_sz};
            entry_bytes_for = 32'd1
                + {29'b0, vlen32({16'b0, kl})}
                + {29'b0, vlen32(vl_bh_sum)}
                + {16'b0, kl}
                + {29'b0, vl_off}
                + {29'b0, vl_sz};
        end
    endfunction

    function [7:0] vbyte32;
        input [31:0] v;
        input [2:0]  idx;
        reg   [31:0] t;
        begin
            case (idx)
                3'd0: t = v;
                3'd1: t = v >> 7;
                3'd2: t = v >> 14;
                3'd3: t = v >> 21;
                3'd4: t = v >> 28;
                default: t = 32'd0;
            endcase
            vbyte32 = t[6:0] | (((t >> 7) != 32'd0) ? 8'h80 : 8'h00);
        end
    endfunction

    // -----------------------------------------------------------------------
    // Index-block size accumulator (driven by ST_COMPUTE_IDX)
    // -----------------------------------------------------------------------
    reg  [31:0] idx_accum_r;

    // Key-slice cache: MAX_BLOCK_PAIRS-way mux latched in ST_ENT_SHARED
    reg [MAX_KEY_BYTES*8-1:0] cur_key_cache_r;

    // Pre-fetched key byte for CRC pipeline (breaks MUX→CRC critical path)
    reg [7:0] key_byte_r;

    // Footer byte-position counter
    reg [BUF_AW-1:0]  build_ptr;

    // -----------------------------------------------------------------------
    // CRC state + masked-CRC wires
    // -----------------------------------------------------------------------
    reg  [31:0] crc_r;
    wire [31:0] crc_final  = crc_r ^ 32'hFFFFFFFF;
    wire [31:0] crc_rot    = {crc_final[14:0], crc_final[31:15]};
    wire [31:0] crc_masked = crc_rot + 32'ha282ead8;

    // -----------------------------------------------------------------------
    // FSM registers
    // -----------------------------------------------------------------------
    reg [4:0]              state;
    reg [4:0]              return_state;
    reg [31:0]             wr_offset;

    reg [31:0]             idx_offset_r;
    reg [31:0]             idx_size_r;
    reg [31:0]             meta_offset_r;
    reg [31:0]             meta_size_r;

    reg [31:0]             blk_idx;
    reg [15:0]             cur_key_len;
    reg [31:0]             cur_blk_offset;
    reg [31:0]             cur_blk_size;
    reg [15:0]             key_bptr;

    reg [31:0]             vi_val;
    reg [2:0]              vi_len;
    reg [2:0]              vi_ptr;

    reg [7:0]              sub;

    // -----------------------------------------------------------------------
    // AXI write engine control
    // -----------------------------------------------------------------------
    reg                       wr_start_r;
    reg [AXI_ADDR_WIDTH-1:0]  wr_addr_r;
    reg [31:0]                wr_len_r;
    wire                      wr_done_w;
    wire                      wr_err_w;

    // -----------------------------------------------------------------------
    // Byte stream -> stream_pack_adapter -> axi_write_engine
    // -----------------------------------------------------------------------
    reg  [7:0] byte_tdata;
    reg        byte_tvalid;
    reg        byte_tlast;
    wire       byte_tready;

    wire [AXI_DATA_WIDTH-1:0]   beat_tdata;
    wire [AXI_KEEP_WIDTH-1:0]   beat_tkeep;
    wire                        beat_tlast;
    wire                        beat_tvalid;
    wire                        beat_tready;

    stream_pack_adapter #(
        .IN_DATA_WIDTH (8),
        .IN_KEEP_WIDTH (1),
        .OUT_DATA_WIDTH(AXI_DATA_WIDTH),
        .OUT_KEEP_WIDTH(AXI_KEEP_WIDTH)
    ) u_pack (
        .clk          (clk),
        .rstn         (rstn),
        .clear        (clear),
        .s_axis_tdata (byte_tdata),
        .s_axis_tkeep (1'b1),
        .s_axis_tlast (byte_tlast),
        .s_axis_tvalid(byte_tvalid),
        .s_axis_tready(byte_tready),
        .m_axis_tdata (beat_tdata),
        .m_axis_tkeep (beat_tkeep),
        .m_axis_tlast (beat_tlast),
        .m_axis_tvalid(beat_tvalid),
        .m_axis_tready(beat_tready)
    );

    wire [AXI_ID_WIDTH-1:0] wr_awid_nc;

    axi_write_engine #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH  (AXI_ID_WIDTH),
        .MAX_BURST_LEN (MAX_BURST_LEN)
    ) u_wr (
        .clk          (clk),
        .rstn         (rstn),
        .clear        (clear),
        .start        (wr_start_r),
        .base_addr    (wr_addr_r),
        .byte_count   (wr_len_r),
        .busy         (),
        .done         (wr_done_w),
        .error        (wr_err_w),
        .bytes_written(),
        .beats_written(),
        .s_axis_tdata (beat_tdata),
        .s_axis_tkeep (beat_tkeep),
        .s_axis_tlast (beat_tlast),
        .s_axis_tvalid(beat_tvalid),
        .s_axis_tready(beat_tready),
        .m_axi_awaddr (m_axi_awaddr),
        .m_axi_awlen  (m_axi_awlen),
        .m_axi_awsize (m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awid   (wr_awid_nc),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata  (m_axi_wdata),
        .m_axi_wstrb  (m_axi_wstrb),
        .m_axi_wlast  (m_axi_wlast),
        .m_axi_wvalid (m_axi_wvalid),
        .m_axi_wready (m_axi_wready),
        .m_axi_bresp  (m_axi_bresp),
        .m_axi_bid    ({AXI_ID_WIDTH{1'b0}}),
        .m_axi_bvalid (m_axi_bvalid),
        .m_axi_bready (m_axi_bready)
    );

    // -----------------------------------------------------------------------
    // Per-cycle current-block extraction (variable part-select on RHS OK)
    // -----------------------------------------------------------------------
    wire [63:0] cbk_offset_w = block_offset_vec[(blk_idx*64) +: 64];
    wire [31:0] cbk_size_w   = block_size_vec  [(blk_idx*32) +: 32];
    wire [15:0] cbk_keylen_w = last_key_len_vec[(blk_idx*16) +: 16];

    // -----------------------------------------------------------------------
    // Main FSM -- single always block, no multi-driver
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rstn || clear) begin
            state       <= ST_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            error       <= 1'b0;
            total_bytes <= 32'd0;
            wr_start_r  <= 1'b0;
            byte_tvalid <= 1'b0;
            byte_tlast  <= 1'b0;
            byte_tdata  <= 8'h00;
        end else begin
            wr_start_r <= 1'b0;

            case (state)

            // -------------------------------------------------------------------
            ST_IDLE: begin
                if (start) begin
                    busy       <= 1'b1;
                    done       <= 1'b0;
                    error      <= 1'b0;
                    wr_offset  <= data_end_offset;
                    blk_idx    <= 32'd0;
                    idx_accum_r <= 32'd13; // restart(8) + trailer(5)
                    state      <= ST_COMPUTE_IDX;
                end
            end

            // -------------------------------------------------------------------
            // Sequential index-block size accumulation (1 block/cycle)
            ST_COMPUTE_IDX: begin
                if (blk_idx < num_blocks) begin
                    idx_accum_r <= idx_accum_r
                                   + entry_bytes_for(cbk_offset_w, cbk_size_w, cbk_keylen_w);
                    blk_idx     <= blk_idx + 32'd1;
                end else begin
                    state <= ST_IDX_INIT;
                end
            end

            // -------------------------------------------------------------------
            // Index block init: start AXI write immediately with pre-computed length
            ST_IDX_INIT: begin
                crc_r        <= 32'hFFFFFFFF;
                blk_idx      <= 32'd0;
                idx_offset_r <= wr_offset;
                idx_size_r   <= idx_accum_r - 32'd5;
                wr_start_r   <= 1'b1;
                wr_addr_r    <= dst_base_addr
                                + {{(AXI_ADDR_WIDTH-32){1'b0}}, wr_offset};
                wr_len_r     <= idx_accum_r;
                return_state <= ST_META_INIT;
                state        <= ST_ENT_SHARED;
            end

            // -------------------------------------------------------------------
            // Emit shared_len=0; latch block info + key cache
            ST_ENT_SHARED: begin
                if (!byte_tvalid || byte_tready) begin
                    byte_tdata  <= 8'h00;
                    byte_tvalid <= 1'b1;
                    byte_tlast  <= 1'b0;
                    crc_r          <= crc32c_step(crc_r, 8'h00);
                    cur_key_len    <= cbk_keylen_w;
                    cur_blk_offset <= cbk_offset_w[31:0];
                    cur_blk_size   <= cbk_size_w;
                    vi_val         <= {16'h0000, cbk_keylen_w};
                    vi_len         <= vlen32({16'h0000, cbk_keylen_w});
                    vi_ptr         <= 3'd0;
                    case (blk_idx[2:0])
                        3'd0: cur_key_cache_r <= last_key_bytes_vec[0*MAX_KEY_BYTES*8 +: MAX_KEY_BYTES*8];
                        3'd1: cur_key_cache_r <= last_key_bytes_vec[1*MAX_KEY_BYTES*8 +: MAX_KEY_BYTES*8];
                        3'd2: cur_key_cache_r <= last_key_bytes_vec[2*MAX_KEY_BYTES*8 +: MAX_KEY_BYTES*8];
                        3'd3: cur_key_cache_r <= last_key_bytes_vec[3*MAX_KEY_BYTES*8 +: MAX_KEY_BYTES*8];
                        3'd4: cur_key_cache_r <= last_key_bytes_vec[4*MAX_KEY_BYTES*8 +: MAX_KEY_BYTES*8];
                        3'd5: cur_key_cache_r <= last_key_bytes_vec[5*MAX_KEY_BYTES*8 +: MAX_KEY_BYTES*8];
                        3'd6: cur_key_cache_r <= last_key_bytes_vec[6*MAX_KEY_BYTES*8 +: MAX_KEY_BYTES*8];
                        default: cur_key_cache_r <= last_key_bytes_vec[7*MAX_KEY_BYTES*8 +: MAX_KEY_BYTES*8];
                    endcase
                    state <= ST_ENT_USHLEN;
                end
            end

            // -------------------------------------------------------------------
            // Emit varint(key_len) bytes
            ST_ENT_USHLEN: begin
                if (!byte_tvalid || byte_tready) begin
                    byte_tdata  <= vbyte32(vi_val, vi_ptr);
                    byte_tvalid <= 1'b1;
                    byte_tlast  <= 1'b0;
                    crc_r  <= crc32c_step(crc_r, vbyte32(vi_val, vi_ptr));
                    vi_ptr <= vi_ptr + 3'd1;
                    if (vi_ptr + 3'd1 == vi_len) begin
                        vi_val <= {{29{1'b0}}, vlen32(cur_blk_offset)}
                                + {{29{1'b0}}, vlen32(cur_blk_size - 32'd5)};
                        vi_len <= vlen32(
                                      {{29{1'b0}}, vlen32(cur_blk_offset)}
                                    + {{29{1'b0}}, vlen32(cur_blk_size - 32'd5)});
                        vi_ptr <= 3'd0;
                        state  <= ST_ENT_VALLEN;
                    end
                end
            end

            // -------------------------------------------------------------------
            // Emit varint(bh_enc_sz) bytes
            ST_ENT_VALLEN: begin
                if (!byte_tvalid || byte_tready) begin
                    byte_tdata  <= vbyte32(vi_val, vi_ptr);
                    byte_tvalid <= 1'b1;
                    byte_tlast  <= 1'b0;
                    crc_r  <= crc32c_step(crc_r, vbyte32(vi_val, vi_ptr));
                    vi_ptr <= vi_ptr + 3'd1;
                    if (vi_ptr + 3'd1 == vi_len) begin
                        key_bptr   <= 16'd0;
                        key_byte_r <= cur_key_cache_r[7:0]; // pre-fetch byte 0
                        state      <= ST_ENT_KEY;
                    end
                end
            end

            // -------------------------------------------------------------------
            // Emit key bytes from cached slice (2048-bit mux vs 16384-bit original)
            ST_ENT_KEY: begin
                if (!byte_tvalid || byte_tready) begin
                    byte_tdata  <= key_byte_r; // use pre-fetched byte
                    byte_tvalid <= 1'b1;
                    byte_tlast  <= 1'b0;
                    crc_r    <= crc32c_step(crc_r, key_byte_r); // CRC from register
                    key_bptr <= key_bptr + 16'd1;
                    // pre-fetch next key byte (MUX path goes to register, not CRC)
                    key_byte_r <= cur_key_cache_r[{(key_bptr[7:0] + 8'd1), 3'b000} +: 8];
                    if (key_bptr + 16'd1 == cur_key_len) begin
                        vi_val <= cur_blk_offset;
                        vi_len <= vlen32(cur_blk_offset);
                        vi_ptr <= 3'd0;
                        state  <= ST_ENT_BHOFF;
                    end
                end
            end

            // -------------------------------------------------------------------
            // Emit varint(block_offset)
            ST_ENT_BHOFF: begin
                if (!byte_tvalid || byte_tready) begin
                    byte_tdata  <= vbyte32(vi_val, vi_ptr);
                    byte_tvalid <= 1'b1;
                    byte_tlast  <= 1'b0;
                    crc_r  <= crc32c_step(crc_r, vbyte32(vi_val, vi_ptr));
                    vi_ptr <= vi_ptr + 3'd1;
                    if (vi_ptr + 3'd1 == vi_len) begin
                        vi_val <= cur_blk_size - 32'd5;
                        vi_len <= vlen32(cur_blk_size - 32'd5);
                        vi_ptr <= 3'd0;
                        state  <= ST_ENT_BHSZ;
                    end
                end
            end

            // -------------------------------------------------------------------
            // Emit varint(block_content_size)
            ST_ENT_BHSZ: begin
                if (!byte_tvalid || byte_tready) begin
                    byte_tdata  <= vbyte32(vi_val, vi_ptr);
                    byte_tvalid <= 1'b1;
                    byte_tlast  <= 1'b0;
                    crc_r  <= crc32c_step(crc_r, vbyte32(vi_val, vi_ptr));
                    vi_ptr <= vi_ptr + 3'd1;
                    if (vi_ptr + 3'd1 == vi_len)
                        state <= ST_ENT_NEXT;
                end
            end

            // -------------------------------------------------------------------
            // Advance block iterator or fall through to restart array
            ST_ENT_NEXT: begin
                if (byte_tvalid && byte_tready) begin
                    byte_tvalid <= 1'b0;
                    byte_tlast  <= 1'b0;
                end
                blk_idx <= blk_idx + 32'd1;
                if (blk_idx + 32'd1 >= num_blocks) begin
                    sub   <= 8'd0;
                    state <= ST_IDX_REST;
                end else
                    state <= ST_ENT_SHARED;
            end

            // -------------------------------------------------------------------
            // Restart array: restart[0]=0 (4B LE), count=1 (4B LE)
            ST_IDX_REST: begin
                if (!byte_tvalid || byte_tready) begin
                    byte_tdata  <= (sub == 8'd4) ? 8'h01 : 8'h00;
                    byte_tvalid <= 1'b1;
                    byte_tlast  <= 1'b0;
                    crc_r <= crc32c_step(crc_r,
                                 (sub == 8'd4) ? 8'h01 : 8'h00);
                    if (sub == 8'd7) begin
                        sub   <= 8'd0;
                        state <= ST_IDX_TRAIL;
                    end else
                        sub <= sub + 8'd1;
                end
            end

            // -------------------------------------------------------------------
            // 5-byte trailer: type=0 + 4 masked-CRC bytes; last byte sets tlast
            ST_IDX_TRAIL: begin
                if (!byte_tvalid || byte_tready) begin
                    case (sub)
                        8'd0: begin
                            byte_tdata <= 8'h00;
                            byte_tlast <= 1'b0;
                            crc_r      <= crc32c_step(crc_r, 8'h00);
                        end
                        8'd1: begin byte_tdata <= crc_masked[7:0];   byte_tlast <= 1'b0; end
                        8'd2: begin byte_tdata <= crc_masked[15:8];  byte_tlast <= 1'b0; end
                        8'd3: begin byte_tdata <= crc_masked[23:16]; byte_tlast <= 1'b0; end
                        default: begin byte_tdata <= crc_masked[31:24]; byte_tlast <= 1'b1; end
                    endcase
                    byte_tvalid <= 1'b1;
                    if (sub == 8'd4) begin
                        sub   <= 8'd0;
                        state <= ST_WR_WAIT;
                    end else
                        sub <= sub + 8'd1;
                end
            end

            // -------------------------------------------------------------------
            // Wait for AXI write engine done; clear lingering stream; advance offset
            ST_WR_WAIT: begin
                if (byte_tvalid && byte_tready) begin
                    byte_tvalid <= 1'b0;
                    byte_tlast  <= 1'b0;
                end
                if (wr_err_w) begin
                    busy  <= 1'b0;
                    error <= 1'b1;
                    state <= ST_IDLE;
                end else if (wr_done_w) begin
                    // Footer (return_state==ST_DONE) must not be padded
                    if (return_state == ST_DONE) begin
                        wr_offset <= wr_offset + wr_len_r;
                    end else begin
                        wr_offset <= (wr_offset + wr_len_r + 32'd63) & ~32'd63;
                    end
                    state <= return_state;
                end
            end

            // -------------------------------------------------------------------
            // Metaindex init: start AXI write immediately, fixed 13 bytes
            ST_META_INIT: begin
                crc_r         <= 32'hFFFFFFFF;
                meta_offset_r <= wr_offset;
                meta_size_r   <= 32'd8;
                sub           <= 8'd0;
                wr_start_r    <= 1'b1;
                wr_addr_r     <= dst_base_addr
                                 + {{(AXI_ADDR_WIDTH-32){1'b0}}, wr_offset};
                wr_len_r      <= 32'd13;
                return_state  <= ST_FOOT_INIT;
                state         <= ST_META_BODY;
            end

            // -------------------------------------------------------------------
            // Stream 13-byte empty metaindex directly (8B content + 5B trailer)
            ST_META_BODY: begin
                if (!byte_tvalid || byte_tready) begin
                    case (sub)
                        8'd4:  begin byte_tdata <= 8'h01; crc_r <= crc32c_step(crc_r, 8'h01); byte_tlast <= 1'b0; end
                        8'd8:  begin byte_tdata <= 8'h00; crc_r <= crc32c_step(crc_r, 8'h00); byte_tlast <= 1'b0; end
                        8'd9:  begin byte_tdata <= crc_masked[7:0];   byte_tlast <= 1'b0; end
                        8'd10: begin byte_tdata <= crc_masked[15:8];  byte_tlast <= 1'b0; end
                        8'd11: begin byte_tdata <= crc_masked[23:16]; byte_tlast <= 1'b0; end
                        8'd12: begin byte_tdata <= crc_masked[31:24]; byte_tlast <= 1'b1; end
                        default: begin byte_tdata <= 8'h00; crc_r <= crc32c_step(crc_r, 8'h00); byte_tlast <= 1'b0; end
                    endcase
                    byte_tvalid <= 1'b1;
                    if (sub == 8'd12) begin
                        sub   <= 8'd0;
                        state <= ST_WR_WAIT;
                    end else
                        sub <= sub + 8'd1;
                end
            end

            // -------------------------------------------------------------------
            // Footer init: start AXI write immediately, fixed 48 bytes
            ST_FOOT_INIT: begin
                build_ptr    <= {BUF_AW{1'b0}};
                vi_val       <= meta_offset_r;
                vi_len       <= vlen32(meta_offset_r);
                vi_ptr       <= 3'd0;
                wr_start_r   <= 1'b1;
                wr_addr_r    <= dst_base_addr
                               + {{(AXI_ADDR_WIDTH-32){1'b0}}, wr_offset};
                wr_len_r     <= 32'd48;
                return_state <= ST_DONE;
                state        <= ST_FOOT_OFF0;
            end

            // -------------------------------------------------------------------
            ST_FOOT_OFF0: begin
                if (!byte_tvalid || byte_tready) begin
                    byte_tdata  <= vbyte32(vi_val, vi_ptr);
                    byte_tvalid <= 1'b1;
                    byte_tlast  <= 1'b0;
                    build_ptr <= build_ptr + {{(BUF_AW-1){1'b0}}, 1'b1};
                    vi_ptr    <= vi_ptr + 3'd1;
                    if (vi_ptr + 3'd1 == vi_len) begin
                        vi_val <= meta_size_r;
                        vi_len <= vlen32(meta_size_r);
                        vi_ptr <= 3'd0;
                        state  <= ST_FOOT_SZ0;
                    end
                end
            end

            // -------------------------------------------------------------------
            ST_FOOT_SZ0: begin
                if (!byte_tvalid || byte_tready) begin
                    byte_tdata  <= vbyte32(vi_val, vi_ptr);
                    byte_tvalid <= 1'b1;
                    byte_tlast  <= 1'b0;
                    build_ptr <= build_ptr + {{(BUF_AW-1){1'b0}}, 1'b1};
                    vi_ptr    <= vi_ptr + 3'd1;
                    if (vi_ptr + 3'd1 == vi_len) begin
                        vi_val <= idx_offset_r;
                        vi_len <= vlen32(idx_offset_r);
                        vi_ptr <= 3'd0;
                        state  <= ST_FOOT_OFF1;
                    end
                end
            end

            // -------------------------------------------------------------------
            ST_FOOT_OFF1: begin
                if (!byte_tvalid || byte_tready) begin
                    byte_tdata  <= vbyte32(vi_val, vi_ptr);
                    byte_tvalid <= 1'b1;
                    byte_tlast  <= 1'b0;
                    build_ptr <= build_ptr + {{(BUF_AW-1){1'b0}}, 1'b1};
                    vi_ptr    <= vi_ptr + 3'd1;
                    if (vi_ptr + 3'd1 == vi_len) begin
                        vi_val <= idx_size_r;
                        vi_len <= vlen32(idx_size_r);
                        vi_ptr <= 3'd0;
                        state  <= ST_FOOT_SZ1;
                    end
                end
            end

            // -------------------------------------------------------------------
            ST_FOOT_SZ1: begin
                if (!byte_tvalid || byte_tready) begin
                    byte_tdata  <= vbyte32(vi_val, vi_ptr);
                    byte_tvalid <= 1'b1;
                    byte_tlast  <= 1'b0;
                    build_ptr <= build_ptr + {{(BUF_AW-1){1'b0}}, 1'b1};
                    vi_ptr    <= vi_ptr + 3'd1;
                    if (vi_ptr + 3'd1 == vi_len)
                        state <= ST_FOOT_PAD;
                end
            end

            // -------------------------------------------------------------------
            // Zero-pad combined BH region to 40 bytes (direct stream)
            ST_FOOT_PAD: begin
                if (build_ptr >= 7'd40) begin
                    state <= ST_FOOT_MAGIC;
                end else if (!byte_tvalid || byte_tready) begin
                    byte_tdata  <= 8'h00;
                    byte_tvalid <= 1'b1;
                    byte_tlast  <= 1'b0;
                    build_ptr <= build_ptr + {{(BUF_AW-1){1'b0}}, 1'b1};
                    if (build_ptr == 7'd39)
                        state <= ST_FOOT_MAGIC;
                end
            end

            // -------------------------------------------------------------------
            // 8 magic bytes (positions 40-47); tlast on final byte
            // LevelDB table magic = 0xdb4775248b80fb57 (little-endian)
            ST_FOOT_MAGIC: begin
                if (!byte_tvalid || byte_tready) begin
                    case (build_ptr[2:0])
                        3'd0: byte_tdata <= 8'h57;
                        3'd1: byte_tdata <= 8'hFB;
                        3'd2: byte_tdata <= 8'h80;
                        3'd3: byte_tdata <= 8'h8B;
                        3'd4: byte_tdata <= 8'h24;
                        3'd5: byte_tdata <= 8'h75;
                        3'd6: byte_tdata <= 8'h47;
                        default: byte_tdata <= 8'hDB;
                    endcase
                    byte_tvalid <= 1'b1;
                    byte_tlast  <= (build_ptr[2:0] == 3'd7);
                    build_ptr   <= build_ptr + {{(BUF_AW-1){1'b0}}, 1'b1};
                    if (build_ptr[2:0] == 3'd7)
                        state <= ST_WR_WAIT;
                end
            end

            // -------------------------------------------------------------------
            ST_DONE: begin
                total_bytes <= wr_offset - data_end_offset;
                busy        <= 1'b0;
                done        <= 1'b1;
                state       <= ST_IDLE;
            end

            default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
`endif
