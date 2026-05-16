`timescale 1ns / 1ps

// byte_skip_adapter_w64
//
// P9: 64-bit wide byte skip adapter.
// Discards the first skip_bytes bytes from a 64-bit AXI-Stream (with 8-bit
// tkeep), then passes remaining bytes through unchanged.
//
// Unlike the 8-bit version, the skip boundary may fall in the middle of a
// 64-bit beat. In that case, the first output beat has a partial tkeep
// (only the bytes after the skip are valid).
//
// Pipeline-friendly: 1-cycle registered output stage to break combinational
// paths from input to output.
//
module byte_skip_adapter_w64 #(
    parameter integer SKIP_WIDTH = 6   // supports up to 63 bytes skip
) (
    input  wire                   clk,
    input  wire                   rstn,
    input  wire                   clear,
    input  wire                   start,
    input  wire [SKIP_WIDTH-1:0]  skip_bytes,
    // Input: 64-bit stream with 8-bit tkeep
    input  wire [63:0]            s_axis_tdata,
    input  wire [7:0]             s_axis_tkeep,
    input  wire                   s_axis_tlast,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    // Output: 64-bit stream with 8-bit tkeep (first beat may be partial)
    output wire [63:0]            m_axis_tdata,
    output wire [7:0]             m_axis_tkeep,
    output wire                   m_axis_tlast,
    output wire                   m_axis_tvalid,
    input  wire                   m_axis_tready
);

    // --- State ---
    reg [SKIP_WIDTH-1:0] skip_remain;  // bytes remaining to skip
    reg                  skipping;     // currently in skip phase

    // Count valid bytes in current beat
    wire [3:0] in_byte_count = {3'b0, s_axis_tkeep[0]} + {3'b0, s_axis_tkeep[1]}
                             + {3'b0, s_axis_tkeep[2]} + {3'b0, s_axis_tkeep[3]}
                             + {3'b0, s_axis_tkeep[4]} + {3'b0, s_axis_tkeep[5]}
                             + {3'b0, s_axis_tkeep[6]} + {3'b0, s_axis_tkeep[7]};

    // During skip phase: how many bytes of this beat to skip
    wire [3:0] bytes_to_skip = (skip_remain >= {{(SKIP_WIDTH-4){1'b0}}, in_byte_count}) ?
                               in_byte_count : skip_remain[3:0];

    // After partial skip: remaining valid bytes in this beat
    wire [3:0] pass_bytes = in_byte_count - bytes_to_skip;
    wire       partial_pass = skipping && (pass_bytes != 4'd0);

    // Combinational barrel shift: move valid bytes down by bytes_to_skip positions
    wire [63:0] shifted_data_c;
    wire [7:0]  shifted_keep_c;

    // Byte-level right shift by bytes_to_skip (extracting high bytes)
    assign shifted_data_c = (bytes_to_skip == 4'd0) ? s_axis_tdata :
                            (bytes_to_skip == 4'd1) ? {8'd0,  s_axis_tdata[63:8]} :
                            (bytes_to_skip == 4'd2) ? {16'd0, s_axis_tdata[63:16]} :
                            (bytes_to_skip == 4'd3) ? {24'd0, s_axis_tdata[63:24]} :
                            (bytes_to_skip == 4'd4) ? {32'd0, s_axis_tdata[63:32]} :
                            (bytes_to_skip == 4'd5) ? {40'd0, s_axis_tdata[63:40]} :
                            (bytes_to_skip == 4'd6) ? {48'd0, s_axis_tdata[63:48]} :
                            (bytes_to_skip == 4'd7) ? {56'd0, s_axis_tdata[63:56]} :
                                                      64'd0;

    // Generate tkeep for pass_bytes valid bytes (LSB-justified)
    assign shifted_keep_c = (pass_bytes >= 4'd8) ? 8'hFF :
                            (pass_bytes == 4'd7) ? 8'h7F :
                            (pass_bytes == 4'd6) ? 8'h3F :
                            (pass_bytes == 4'd5) ? 8'h1F :
                            (pass_bytes == 4'd4) ? 8'h0F :
                            (pass_bytes == 4'd3) ? 8'h07 :
                            (pass_bytes == 4'd2) ? 8'h03 :
                            (pass_bytes == 4'd1) ? 8'h01 :
                                                   8'h00;

    // Output assignment: bypass shift for non-skip phase
    wire pass_through = !skipping;

    // Direct output (no pipeline reg needed since input is already from AXI read engine)
    assign m_axis_tdata  = pass_through ? s_axis_tdata  : shifted_data_c;
    assign m_axis_tkeep  = pass_through ? s_axis_tkeep  : shifted_keep_c;
    assign m_axis_tlast  = s_axis_tlast;
    assign m_axis_tvalid = s_axis_tvalid && (pass_through || partial_pass);
    assign s_axis_tready = skipping ? (partial_pass ? m_axis_tready : 1'b1) :
                                      m_axis_tready;

    // State machine
    always @(posedge clk) begin
        if (!rstn) begin
            skip_remain <= {SKIP_WIDTH{1'b0}};
            skipping    <= 1'b0;
        end else if (clear) begin
            skip_remain <= {SKIP_WIDTH{1'b0}};
            skipping    <= 1'b0;
        end else begin
            if (start) begin
                skip_remain <= skip_bytes;
                skipping    <= (skip_bytes != {SKIP_WIDTH{1'b0}});
            end else if (skipping && s_axis_tvalid && s_axis_tready) begin
                if ({2'b0, skip_remain} <= {2'b0, in_byte_count}) begin
                    // This beat completes the skip
                    skipping    <= 1'b0;
                    skip_remain <= {SKIP_WIDTH{1'b0}};
                end else begin
                    // Entire beat is skipped
                    skip_remain <= skip_remain - {{(SKIP_WIDTH-4){1'b0}}, in_byte_count};
                end
            end
        end
    end

endmodule
