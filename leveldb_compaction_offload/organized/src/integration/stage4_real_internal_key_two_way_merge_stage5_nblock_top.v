`timescale 1ns / 1ps

module stage4_real_internal_key_two_way_merge_stage5_nblock_top #(
    parameter integer AXI_ADDR_WIDTH              = 64,
    parameter integer AXI_DATA_WIDTH              = 512,
    parameter integer AXI_ID_WIDTH                = 1,
    parameter integer MAX_BURST_LEN               = 16,
    parameter integer STAGE4_MAX_BLOCK_BYTES      = 4096,
    parameter integer STAGE4_MAX_KEY_BYTES        = 264,
    parameter integer MERGE_MAX_USER_KEY_BYTES    = 256,
    parameter integer MERGE_MAX_KEY_BYTES         = 264,
    parameter integer MERGE_MAX_VALUE_BYTES       = 1024,
    parameter integer MERGE_MAX_RECORD_BYTES      = 2048,
    parameter integer MERGE_MAX_RECORDS           = 256,
    parameter integer MERGE_MAX_OUTPUT_BYTES      = 73728,
    parameter integer STAGE5_MAX_RECORDS          = 256,
    parameter integer STAGE5_MAX_PAYLOAD_BYTES    = 4096,
    parameter integer STAGE5_MAX_BLOCK_BYTES      = 4096,
    parameter integer STAGE5_MAX_KEY_BYTES        = 256,
    parameter integer STAGE5_MAX_VALUE_BYTES      = 1024,
    parameter integer STAGE5_RESTART_INTERVAL     = 16,
    parameter integer MAX_BLOCK_PAIRS             = 8
) (
    input  wire                                      clk,
    input  wire                                      rstn,
    input  wire                                      clear,
    input  wire                                      start,
    input  wire [31:0]                               block_pair_count,
    input  wire [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] src0_base_addr_vec,
    input  wire [MAX_BLOCK_PAIRS*32-1:0]             src0_byte_count_vec,
    input  wire [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] src1_base_addr_vec,
    input  wire [MAX_BLOCK_PAIRS*32-1:0]             src1_byte_count_vec,
    input  wire [MAX_BLOCK_PAIRS*AXI_ADDR_WIDTH-1:0] dst_base_addr_vec,
    input  wire [AXI_ADDR_WIDTH-1:0]                 mid_base_addr,
    output reg                                       busy,
    output reg                                       done,
    output reg                                       error,
    output reg  [31:0]                               active_block_index,
    output reg  [31:0]                               blocks_completed,
    output wire [MAX_BLOCK_PAIRS*32-1:0]             dst_output_block_bytes_vec,
    output reg  [31:0]                               total_source0_decoded_entry_count,
    output reg  [31:0]                               total_source1_decoded_entry_count,
    output reg  [31:0]                               total_source0_bytes_read,
    output reg  [31:0]                               total_source1_bytes_read,
    output reg  [31:0]                               total_merge_output_byte_count,
    output reg  [31:0]                               total_merge_decoded_record_count,
    output reg  [31:0]                               total_merge_merged_record_count,
    output reg  [31:0]                               total_merge_dropped_superseded_count,
    output reg  [31:0]                               total_stage5_input_record_count,
    output reg  [31:0]                               total_stage5_encoded_entry_count,
    output reg  [31:0]                               total_stage5_output_block_bytes,
    output reg  [31:0]                               total_stage5_bytes_written,

    output wire [AXI_ADDR_WIDTH-1:0]                 m_axi_src0_araddr,
    output wire [7:0]                                m_axi_src0_arlen,
    output wire [2:0]                                m_axi_src0_arsize,
    output wire [1:0]                                m_axi_src0_arburst,
    output wire                                      m_axi_src0_arvalid,
    input  wire                                      m_axi_src0_arready,
    input  wire [AXI_DATA_WIDTH-1:0]                 m_axi_src0_rdata,
    input  wire [1:0]                                m_axi_src0_rresp,
    input  wire                                      m_axi_src0_rlast,
    input  wire                                      m_axi_src0_rvalid,
    output wire                                      m_axi_src0_rready,

    output wire [AXI_ADDR_WIDTH-1:0]                 m_axi_src1_araddr,
    output wire [7:0]                                m_axi_src1_arlen,
    output wire [2:0]                                m_axi_src1_arsize,
    output wire [1:0]                                m_axi_src1_arburst,
    output wire                                      m_axi_src1_arvalid,
    input  wire                                      m_axi_src1_arready,
    input  wire [AXI_DATA_WIDTH-1:0]                 m_axi_src1_rdata,
    input  wire [1:0]                                m_axi_src1_rresp,
    input  wire                                      m_axi_src1_rlast,
    input  wire                                      m_axi_src1_rvalid,
    output wire                                      m_axi_src1_rready,

    output wire [AXI_ADDR_WIDTH-1:0]                 m_axi_chain_araddr,
    output wire [7:0]                                m_axi_chain_arlen,
    output wire [2:0]                                m_axi_chain_arsize,
    output wire [1:0]                                m_axi_chain_arburst,
    output wire                                      m_axi_chain_arvalid,
    input  wire                                      m_axi_chain_arready,
    input  wire [AXI_DATA_WIDTH-1:0]                 m_axi_chain_rdata,
    input  wire [1:0]                                m_axi_chain_rresp,
    input  wire                                      m_axi_chain_rlast,
    input  wire                                      m_axi_chain_rvalid,
    output wire                                      m_axi_chain_rready,
    output wire [AXI_ADDR_WIDTH-1:0]                 m_axi_chain_awaddr,
    output wire [7:0]                                m_axi_chain_awlen,
    output wire [2:0]                                m_axi_chain_awsize,
    output wire [1:0]                                m_axi_chain_awburst,
    output wire                                      m_axi_chain_awvalid,
    input  wire                                      m_axi_chain_awready,
    output wire [AXI_DATA_WIDTH-1:0]                 m_axi_chain_wdata,
    output wire [(AXI_DATA_WIDTH/8)-1:0]             m_axi_chain_wstrb,
    output wire                                      m_axi_chain_wlast,
    output wire                                      m_axi_chain_wvalid,
    input  wire                                      m_axi_chain_wready,
    input  wire [1:0]                                m_axi_chain_bresp,
    input  wire                                      m_axi_chain_bvalid,
    output wire                                      m_axi_chain_bready
);

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_CLEAR = 3'd1;
    localparam [2:0] ST_START = 3'd2;
    localparam [2:0] ST_WAIT  = 3'd3;

    reg [2:0] state;
    reg       inner_clear_r;
    reg       inner_start_r;
    reg       inner_done_d;
    reg [31:0] block_pair_count_r;
    reg        seed_prev_user_key_valid_r;
    reg [15:0] seed_prev_user_key_len_r;
    reg [(MERGE_MAX_USER_KEY_BYTES*8)-1:0] seed_prev_user_key_r;
    reg [31:0] dst_output_block_bytes_mem [0:MAX_BLOCK_PAIRS-1];

    wire [AXI_ADDR_WIDTH-1:0] current_src0_base_addr = src0_base_addr_vec[(active_block_index*AXI_ADDR_WIDTH) +: AXI_ADDR_WIDTH];
    wire [31:0]               current_src0_byte_count = src0_byte_count_vec[(active_block_index*32) +: 32];
    wire [AXI_ADDR_WIDTH-1:0] current_src1_base_addr = src1_base_addr_vec[(active_block_index*AXI_ADDR_WIDTH) +: AXI_ADDR_WIDTH];
    wire [31:0]               current_src1_byte_count = src1_byte_count_vec[(active_block_index*32) +: 32];
    wire [AXI_ADDR_WIDTH-1:0] current_dst_base_addr = dst_base_addr_vec[(active_block_index*AXI_ADDR_WIDTH) +: AXI_ADDR_WIDTH];

    wire        inner_busy;
    wire        inner_done;
    wire        inner_error;
    wire [31:0] inner_source0_decoded_entry_count;
    wire [31:0] inner_source0_bytes_read;
    wire [31:0] inner_source1_decoded_entry_count;
    wire [31:0] inner_source1_bytes_read;
    wire [31:0] inner_merge_output_byte_count;
    wire [31:0] inner_merge_decoded_record_count;
    wire [31:0] inner_merge_merged_record_count;
    wire [31:0] inner_merge_dropped_superseded_count;
    wire [31:0] inner_stage5_input_record_count;
    wire [31:0] inner_stage5_encoded_entry_count;
    wire [31:0] inner_stage5_output_block_bytes;
    wire [31:0] inner_stage5_bytes_written;
    wire        inner_final_prev_user_key_valid;
    wire [15:0] inner_final_prev_user_key_len;
    wire [(MERGE_MAX_USER_KEY_BYTES*8)-1:0] inner_final_prev_user_key;

    genvar gi;
    generate
        for (gi = 0; gi < MAX_BLOCK_PAIRS; gi = gi + 1) begin : g_dst_output_block_bytes_vec
            assign dst_output_block_bytes_vec[(gi*32) +: 32] = dst_output_block_bytes_mem[gi];
        end
    endgenerate

    stage4_real_internal_key_two_way_merge_stage5_chain_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN),
        .STAGE4_MAX_BLOCK_BYTES(STAGE4_MAX_BLOCK_BYTES),
        .STAGE4_MAX_KEY_BYTES(STAGE4_MAX_KEY_BYTES),
        .MERGE_MAX_USER_KEY_BYTES(MERGE_MAX_USER_KEY_BYTES),
        .MERGE_MAX_KEY_BYTES(MERGE_MAX_KEY_BYTES),
        .MERGE_MAX_VALUE_BYTES(MERGE_MAX_VALUE_BYTES),
        .MERGE_MAX_RECORD_BYTES(MERGE_MAX_RECORD_BYTES),
        .MERGE_MAX_RECORDS(MERGE_MAX_RECORDS),
        .MERGE_MAX_OUTPUT_BYTES(MERGE_MAX_OUTPUT_BYTES),
        .STAGE5_MAX_RECORDS(STAGE5_MAX_RECORDS),
        .STAGE5_MAX_PAYLOAD_BYTES(STAGE5_MAX_PAYLOAD_BYTES),
        .STAGE5_MAX_BLOCK_BYTES(STAGE5_MAX_BLOCK_BYTES),
        .STAGE5_MAX_KEY_BYTES(STAGE5_MAX_KEY_BYTES),
        .STAGE5_MAX_VALUE_BYTES(STAGE5_MAX_VALUE_BYTES),
        .STAGE5_RESTART_INTERVAL(STAGE5_RESTART_INTERVAL)
    ) u_single_block_chain (
        .clk(clk),
        .rstn(rstn),
        .clear(inner_clear_r),
        .start(inner_start_r),
        .seed_prev_user_key_valid(seed_prev_user_key_valid_r),
        .seed_prev_user_key_len(seed_prev_user_key_len_r),
        .seed_prev_user_key(seed_prev_user_key_r),
        .src0_base_addr(current_src0_base_addr),
        .src0_byte_count(current_src0_byte_count),
        .src1_base_addr(current_src1_base_addr),
        .src1_byte_count(current_src1_byte_count),
        .mid_base_addr(mid_base_addr),
        .dst_base_addr(current_dst_base_addr),
        .busy(inner_busy),
        .done(inner_done),
        .error(inner_error),
        .source0_decoded_entry_count(inner_source0_decoded_entry_count),
        .source0_restart_count(),
        .source0_restart_entry_count(),
        .source0_shared_key_bytes_total(),
        .source0_unshared_key_bytes_total(),
        .source0_value_bytes_total(),
        .source0_last_key_len(),
        .source0_last_value_len(),
        .source0_last_shared_bytes(),
        .source0_last_non_shared_bytes(),
        .source0_restart_array_offset(),
        .source0_bytes_read(inner_source0_bytes_read),
        .source0_beats_read(),
        .source1_decoded_entry_count(inner_source1_decoded_entry_count),
        .source1_restart_count(),
        .source1_restart_entry_count(),
        .source1_shared_key_bytes_total(),
        .source1_unshared_key_bytes_total(),
        .source1_value_bytes_total(),
        .source1_last_key_len(),
        .source1_last_value_len(),
        .source1_last_shared_bytes(),
        .source1_last_non_shared_bytes(),
        .source1_restart_array_offset(),
        .source1_bytes_read(inner_source1_bytes_read),
        .source1_beats_read(),
        .merge_bytes_written(),
        .merge_beats_written(),
        .merge_output_byte_count(inner_merge_output_byte_count),
        .merge_decoded_record_count(inner_merge_decoded_record_count),
        .merge_merged_record_count(inner_merge_merged_record_count),
        .merge_dropped_superseded_count(inner_merge_dropped_superseded_count),
        .merge_value_record_count(),
        .merge_delete_record_count(),
        .merge_user_key_bytes_total(),
        .merge_value_bytes_total(),
        .merge_last_user_key_len(),
        .merge_last_sequence(),
        .merge_last_value_type(),
        .merge_last_record_keep(),
        .stage5_bytes_read(),
        .stage5_beats_read(),
        .stage5_bytes_written(inner_stage5_bytes_written),
        .stage5_beats_written(),
        .stage5_input_record_count(inner_stage5_input_record_count),
        .stage5_encoded_entry_count(inner_stage5_encoded_entry_count),
        .stage5_restart_count(),
        .stage5_shared_key_bytes_total(),
        .stage5_unshared_key_bytes_total(),
        .stage5_value_bytes_total(),
        .stage5_last_key_len(),
        .stage5_last_value_len(),
        .stage5_last_shared_bytes(),
        .stage5_last_non_shared_bytes(),
        .stage5_output_block_bytes(inner_stage5_output_block_bytes),
        .final_prev_user_key_valid(inner_final_prev_user_key_valid),
        .final_prev_user_key_len(inner_final_prev_user_key_len),
        .final_prev_user_key(inner_final_prev_user_key),
        .m_axi_src0_araddr(m_axi_src0_araddr),
        .m_axi_src0_arlen(m_axi_src0_arlen),
        .m_axi_src0_arsize(m_axi_src0_arsize),
        .m_axi_src0_arburst(m_axi_src0_arburst),
        .m_axi_src0_arvalid(m_axi_src0_arvalid),
        .m_axi_src0_arready(m_axi_src0_arready),
        .m_axi_src0_rdata(m_axi_src0_rdata),
        .m_axi_src0_rresp(m_axi_src0_rresp),
        .m_axi_src0_rlast(m_axi_src0_rlast),
        .m_axi_src0_rvalid(m_axi_src0_rvalid),
        .m_axi_src0_rready(m_axi_src0_rready),
        .m_axi_src1_araddr(m_axi_src1_araddr),
        .m_axi_src1_arlen(m_axi_src1_arlen),
        .m_axi_src1_arsize(m_axi_src1_arsize),
        .m_axi_src1_arburst(m_axi_src1_arburst),
        .m_axi_src1_arvalid(m_axi_src1_arvalid),
        .m_axi_src1_arready(m_axi_src1_arready),
        .m_axi_src1_rdata(m_axi_src1_rdata),
        .m_axi_src1_rresp(m_axi_src1_rresp),
        .m_axi_src1_rlast(m_axi_src1_rlast),
        .m_axi_src1_rvalid(m_axi_src1_rvalid),
        .m_axi_src1_rready(m_axi_src1_rready),
        .m_axi_chain_araddr(m_axi_chain_araddr),
        .m_axi_chain_arlen(m_axi_chain_arlen),
        .m_axi_chain_arsize(m_axi_chain_arsize),
        .m_axi_chain_arburst(m_axi_chain_arburst),
        .m_axi_chain_arvalid(m_axi_chain_arvalid),
        .m_axi_chain_arready(m_axi_chain_arready),
        .m_axi_chain_rdata(m_axi_chain_rdata),
        .m_axi_chain_rresp(m_axi_chain_rresp),
        .m_axi_chain_rlast(m_axi_chain_rlast),
        .m_axi_chain_rvalid(m_axi_chain_rvalid),
        .m_axi_chain_rready(m_axi_chain_rready),
        .m_axi_chain_awaddr(m_axi_chain_awaddr),
        .m_axi_chain_awlen(m_axi_chain_awlen),
        .m_axi_chain_awsize(m_axi_chain_awsize),
        .m_axi_chain_awburst(m_axi_chain_awburst),
        .m_axi_chain_awvalid(m_axi_chain_awvalid),
        .m_axi_chain_awready(m_axi_chain_awready),
        .m_axi_chain_wdata(m_axi_chain_wdata),
        .m_axi_chain_wstrb(m_axi_chain_wstrb),
        .m_axi_chain_wlast(m_axi_chain_wlast),
        .m_axi_chain_wvalid(m_axi_chain_wvalid),
        .m_axi_chain_wready(m_axi_chain_wready),
        .m_axi_chain_bresp(m_axi_chain_bresp),
        .m_axi_chain_bvalid(m_axi_chain_bvalid),
        .m_axi_chain_bready(m_axi_chain_bready)
    );

    integer i;
    always @(posedge clk) begin
        if (!rstn) begin
            state                                 <= ST_IDLE;
            inner_clear_r                         <= 1'b0;
            inner_start_r                         <= 1'b0;
            inner_done_d                          <= 1'b0;
            block_pair_count_r                    <= 32'd0;
            seed_prev_user_key_valid_r            <= 1'b0;
            seed_prev_user_key_len_r              <= 16'd0;
            seed_prev_user_key_r                  <= {(MERGE_MAX_USER_KEY_BYTES*8){1'b0}};
            busy                                  <= 1'b0;
            done                                  <= 1'b0;
            error                                 <= 1'b0;
            active_block_index                    <= 32'd0;
            blocks_completed                      <= 32'd0;
            total_source0_decoded_entry_count     <= 32'd0;
            total_source1_decoded_entry_count     <= 32'd0;
            total_source0_bytes_read              <= 32'd0;
            total_source1_bytes_read              <= 32'd0;
            total_merge_output_byte_count         <= 32'd0;
            total_merge_decoded_record_count      <= 32'd0;
            total_merge_merged_record_count       <= 32'd0;
            total_merge_dropped_superseded_count  <= 32'd0;
            total_stage5_input_record_count       <= 32'd0;
            total_stage5_encoded_entry_count      <= 32'd0;
            total_stage5_output_block_bytes       <= 32'd0;
            total_stage5_bytes_written            <= 32'd0;
            for (i = 0; i < MAX_BLOCK_PAIRS; i = i + 1) begin
                dst_output_block_bytes_mem[i] <= 32'd0;
            end
        end else if (clear) begin
            state                                 <= ST_IDLE;
            inner_clear_r                         <= 1'b0;
            inner_start_r                         <= 1'b0;
            inner_done_d                          <= 1'b0;
            block_pair_count_r                    <= 32'd0;
            seed_prev_user_key_valid_r            <= 1'b0;
            seed_prev_user_key_len_r              <= 16'd0;
            seed_prev_user_key_r                  <= {(MERGE_MAX_USER_KEY_BYTES*8){1'b0}};
            busy                                  <= 1'b0;
            done                                  <= 1'b0;
            error                                 <= 1'b0;
            active_block_index                    <= 32'd0;
            blocks_completed                      <= 32'd0;
            total_source0_decoded_entry_count     <= 32'd0;
            total_source1_decoded_entry_count     <= 32'd0;
            total_source0_bytes_read              <= 32'd0;
            total_source1_bytes_read              <= 32'd0;
            total_merge_output_byte_count         <= 32'd0;
            total_merge_decoded_record_count      <= 32'd0;
            total_merge_merged_record_count       <= 32'd0;
            total_merge_dropped_superseded_count  <= 32'd0;
            total_stage5_input_record_count       <= 32'd0;
            total_stage5_encoded_entry_count      <= 32'd0;
            total_stage5_output_block_bytes       <= 32'd0;
            total_stage5_bytes_written            <= 32'd0;
            for (i = 0; i < MAX_BLOCK_PAIRS; i = i + 1) begin
                dst_output_block_bytes_mem[i] <= 32'd0;
            end
        end else begin
            inner_clear_r <= 1'b0;
            inner_start_r <= 1'b0;
            inner_done_d  <= inner_done;
            done          <= 1'b0;
            error         <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start && !busy) begin
                        if ((block_pair_count == 32'd0) || (block_pair_count > MAX_BLOCK_PAIRS)) begin
                            error <= 1'b1;
                        end else begin
                            state                                <= ST_CLEAR;
                            busy                                 <= 1'b1;
                            block_pair_count_r                   <= block_pair_count;
                            active_block_index                   <= 32'd0;
                            blocks_completed                     <= 32'd0;
                            total_source0_decoded_entry_count    <= 32'd0;
                            total_source1_decoded_entry_count    <= 32'd0;
                            total_source0_bytes_read             <= 32'd0;
                            total_source1_bytes_read             <= 32'd0;
                            total_merge_output_byte_count        <= 32'd0;
                            total_merge_decoded_record_count     <= 32'd0;
                            total_merge_merged_record_count      <= 32'd0;
                            total_merge_dropped_superseded_count <= 32'd0;
                            total_stage5_input_record_count      <= 32'd0;
                            total_stage5_encoded_entry_count     <= 32'd0;
                            total_stage5_output_block_bytes      <= 32'd0;
                            total_stage5_bytes_written           <= 32'd0;
                            seed_prev_user_key_valid_r           <= 1'b0;
                            seed_prev_user_key_len_r             <= 16'd0;
                            seed_prev_user_key_r                 <= {(MERGE_MAX_USER_KEY_BYTES*8){1'b0}};
                            for (i = 0; i < MAX_BLOCK_PAIRS; i = i + 1) begin
                                dst_output_block_bytes_mem[i] <= 32'd0;
                            end
                        end
                    end
                end

                ST_CLEAR: begin
                    inner_clear_r <= 1'b1;
                    state         <= ST_START;
                end

                ST_START: begin
                    inner_start_r <= 1'b1;
                    state         <= ST_WAIT;
                end

                ST_WAIT: begin
                    if (inner_error) begin
                        busy  <= 1'b0;
                        error <= 1'b1;
                        state <= ST_IDLE;
                    end else if (inner_done && !inner_done_d) begin
                        dst_output_block_bytes_mem[active_block_index] <= inner_stage5_output_block_bytes;
                        blocks_completed                     <= blocks_completed + 32'd1;
                        total_source0_decoded_entry_count    <= total_source0_decoded_entry_count + inner_source0_decoded_entry_count;
                        total_source1_decoded_entry_count    <= total_source1_decoded_entry_count + inner_source1_decoded_entry_count;
                        total_source0_bytes_read             <= total_source0_bytes_read + inner_source0_bytes_read;
                        total_source1_bytes_read             <= total_source1_bytes_read + inner_source1_bytes_read;
                        total_merge_output_byte_count        <= total_merge_output_byte_count + inner_merge_output_byte_count;
                        total_merge_decoded_record_count     <= total_merge_decoded_record_count + inner_merge_decoded_record_count;
                        total_merge_merged_record_count      <= total_merge_merged_record_count + inner_merge_merged_record_count;
                        total_merge_dropped_superseded_count <= total_merge_dropped_superseded_count + inner_merge_dropped_superseded_count;
                        total_stage5_input_record_count      <= total_stage5_input_record_count + inner_stage5_input_record_count;
                        total_stage5_encoded_entry_count     <= total_stage5_encoded_entry_count + inner_stage5_encoded_entry_count;
                        total_stage5_output_block_bytes      <= total_stage5_output_block_bytes + inner_stage5_output_block_bytes;
                        total_stage5_bytes_written           <= total_stage5_bytes_written + inner_stage5_bytes_written;
                        seed_prev_user_key_valid_r           <= inner_final_prev_user_key_valid;
                        seed_prev_user_key_len_r             <= inner_final_prev_user_key_len;
                        seed_prev_user_key_r                 <= inner_final_prev_user_key;

                        if ((active_block_index + 32'd1) >= block_pair_count_r) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            active_block_index <= active_block_index + 32'd1;
                            state              <= ST_CLEAR;
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
endmodule
