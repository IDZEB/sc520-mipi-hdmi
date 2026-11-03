module edge_detect_96 #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    parameter EDGE_TH    = 11'd80
)(
    input               I_clk,
    input               I_rst_n,
    input               I_tlast,
    input               I_tuser,
    input      [95:0]   I_tdata,
    input               I_tvalid,
    input               I_tready,
    output reg          O_tlast,
    output reg          O_tuser,
    output reg [95:0]   O_tdata,
    output reg          O_tvalid,
    output              O_tready
);

assign O_tready = I_tready;

wire [23:0] pix0 = I_tdata[95:72];
wire [23:0] pix1 = I_tdata[71:48];
wire [23:0] pix2 = I_tdata[47:24];
wire [23:0] pix3 = I_tdata[23:0];

// Low-cost luminance approximation: R/4 + G/2 + B/4.  Its maximum is
// 253, so it cannot overflow an 8-bit result and requires no divider.
wire [7:0] gray0 = {2'b0,pix0[23:18]} + {1'b0,pix0[15:9]} + {2'b0,pix0[7:2]};
wire [7:0] gray1 = {2'b0,pix1[23:18]} + {1'b0,pix1[15:9]} + {2'b0,pix1[7:2]};
wire [7:0] gray2 = {2'b0,pix2[23:18]} + {1'b0,pix2[15:9]} + {2'b0,pix2[7:2]};
wire [7:0] gray3 = {2'b0,pix3[23:18]} + {1'b0,pix3[15:9]} + {2'b0,pix3[7:2]};

localparam IMG_WIDTH_GRP = (IMG_WIDTH >> 2);

// Use two grayscale samples per 4-pixel input beat.  Each sample represents
// a neighbouring pair of pixels, providing 640 horizontal edge samples while
// keeping the two line buffers small enough for this device.
wire [8:0] pair_sum0 = {1'b0,gray0} + {1'b0,gray1};
wire [8:0] pair_sum1 = {1'b0,gray2} + {1'b0,gray3};
wire [7:0] pair0 = pair_sum0[8:1];
wire [7:0] pair1 = pair_sum1[8:1];

(* ram_style = "block" *) reg [15:0] line1_mem [0:IMG_WIDTH_GRP-1];
(* ram_style = "block" *) reg [15:0] line2_mem [0:IMG_WIDTH_GRP-1];

reg [10:0] x_grp;
reg [10:0] y_pos;

wire [15:0] top_word = line2_mem[x_grp];
wire [15:0] mid_word = line1_mem[x_grp];
wire [15:0] bot_word = {pair0,pair1};

wire [7:0] top0 = top_word[15:8];
wire [7:0] top1 = top_word[7:0];
wire [7:0] mid0 = mid_word[15:8];
wire [7:0] mid1 = mid_word[7:0];

reg [7:0] top_prev2, top_prev1;
reg [7:0] mid_prev2, mid_prev1;
reg [7:0] bot_prev2, bot_prev1;

function [13:0] sobel_mag;
    input [7:0] a00, a01, a02;
    input [7:0] a10, a11, a12;
    input [7:0] a20, a21, a22;
    reg signed [12:0] gx_f;
    reg signed [12:0] gy_f;
    reg [12:0] abs_gx_f;
    reg [12:0] abs_gy_f;
    begin
        gx_f = -$signed({1'b0,a00}) + $signed({1'b0,a02})
             - ($signed({1'b0,a10}) <<< 1) + ($signed({1'b0,a12}) <<< 1)
             - $signed({1'b0,a20}) + $signed({1'b0,a22});
        gy_f =  $signed({1'b0,a00}) + ($signed({1'b0,a01}) <<< 1) + $signed({1'b0,a02})
             - $signed({1'b0,a20}) - ($signed({1'b0,a21}) <<< 1) - $signed({1'b0,a22});
        abs_gx_f = gx_f[12] ? (~gx_f + 1'b1) : gx_f;
        abs_gy_f = gy_f[12] ? (~gy_f + 1'b1) : gy_f;
        sobel_mag = abs_gx_f + abs_gy_f;
    end
endfunction

// Two Sobel windows are evaluated per input beat. Each result is duplicated
// to its corresponding pair of output pixels.
wire [13:0] mag0 = sobel_mag(top_prev2,top_prev1,top0,
                             mid_prev2,mid_prev1,mid0,
                             bot_prev2,bot_prev1,pair0);
wire [13:0] mag1 = sobel_mag(top_prev1,top0,top1,
                             mid_prev1,mid0,mid1,
                             bot_prev1,pair0,pair1);

wire window_valid = (y_pos >= 11'd2) && (x_grp != 11'd0) && !I_tuser;
wire edge0 = window_valid && (mag0 >= EDGE_TH);
wire edge1 = window_valid && (mag1 >= EDGE_TH);

wire [23:0] out0 = edge0 ? 24'hffffff : 24'h000000;
wire [23:0] out1 = edge1 ? 24'hffffff : 24'h000000;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        O_tlast  <= 1'b0;
        O_tuser  <= 1'b0;
        O_tdata  <= 96'd0;
        O_tvalid <= 1'b0;
        x_grp    <= 11'd0;
        y_pos    <= 11'd0;
        top_prev2 <= 8'd0; top_prev1 <= 8'd0;
        mid_prev2 <= 8'd0; mid_prev1 <= 8'd0;
        bot_prev2 <= 8'd0; bot_prev1 <= 8'd0;
        // Do not clear line memories here.  A reset loop turns the 10-Kbit
        // buffers into slice registers on this device.  The first two rows
        // are masked by window_valid and naturally initialize both buffers.
    end else begin
        O_tlast  <= I_tlast;
        O_tuser  <= I_tuser;
        O_tvalid <= I_tvalid;

        if(I_tvalid) begin
            O_tdata <= {out0,out0,out1,out1};

            line2_mem[x_grp] <= mid_word;
            line1_mem[x_grp] <= bot_word;

            top_prev2 <= top0; top_prev1 <= top1;
            mid_prev2 <= mid0; mid_prev1 <= mid1;
            bot_prev2 <= pair0; bot_prev1 <= pair1;

            if(I_tuser) begin
                x_grp <= 11'd1;
                y_pos <= 11'd0;
            end else if(x_grp == IMG_WIDTH_GRP - 1) begin
                x_grp <= 11'd0;
                if(y_pos == IMG_HEIGHT - 1)
                    y_pos <= 11'd0;
                else
                    y_pos <= y_pos + 1'b1;
                top_prev2 <= 8'd0; top_prev1 <= 8'd0;
                mid_prev2 <= 8'd0; mid_prev1 <= 8'd0;
                bot_prev2 <= 8'd0; bot_prev1 <= 8'd0;
            end else begin
                x_grp <= x_grp + 1'b1;
            end
        end else begin
            O_tdata <= 96'd0;
        end
    end
end

endmodule

// ===========================================================================
//  edge_detect_hys_96 -- the vendor edge_detect_96 plus a hysteresis threshold.
//
//  Everything that decides how much noise reaches the gradient is kept exactly
//  as the vendor wrote it:
//      * grayscale  R/4 + G/2 + B/4
//      * the two pixels of every pair are averaged before the Sobel  (this is
//        the vendor's cheap noise filter and it is what keeps the picture from
//        breaking apart at 16x analog gain)
//      * |gx| + |gy| single Sobel per pair, same threshold scale
//      * both results are duplicated back to their pixel pair, so the lines are
//        two pixels thick like the vendor image
//
//  The one difference: a second, lower threshold marks weak edges, and a weak
//  edge survives when its left or upper neighbour is a strong edge.  That
//  fills the small gaps that a single global threshold leaves behind without
//  making the detector any more sensitive to noise.
// ===========================================================================
module edge_detect_hys_96 #(
    parameter integer IMG_WIDTH  = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter [10:0]  EDGE_TH    = 11'd80,     // vendor strong threshold
    parameter [10:0]  EDGE_TH_LO = 11'd40,     // weak threshold (hysteresis)
    parameter [10:0]  EDGE_TH_INK = 11'd400    // stricter threshold for the cartoon ink
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    input  wire        I_tready,
    output reg         O_tlast,
    output reg         O_tuser,
    output reg  [95:0] O_tdata,
    output reg         O_tvalid,
    output reg  [95:0] O_ink_tdata,   // binary edge map at EDGE_TH_INK
    output             O_tready
);
    assign O_tready = I_tready;

    wire [23:0] pix0 = I_tdata[95:72];
    wire [23:0] pix1 = I_tdata[71:48];
    wire [23:0] pix2 = I_tdata[47:24];
    wire [23:0] pix3 = I_tdata[23: 0];

    wire [7:0] gray0 = {2'b0,pix0[23:18]} + {1'b0,pix0[15:9]} + {2'b0,pix0[7:2]};
    wire [7:0] gray1 = {2'b0,pix1[23:18]} + {1'b0,pix1[15:9]} + {2'b0,pix1[7:2]};
    wire [7:0] gray2 = {2'b0,pix2[23:18]} + {1'b0,pix2[15:9]} + {2'b0,pix2[7:2]};
    wire [7:0] gray3 = {2'b0,pix3[23:18]} + {1'b0,pix3[15:9]} + {2'b0,pix3[7:2]};

    localparam integer IMG_WIDTH_GRP = (IMG_WIDTH >> 2);

    wire [8:0] pair_sum0 = {1'b0,gray0} + {1'b0,gray1};
    wire [8:0] pair_sum1 = {1'b0,gray2} + {1'b0,gray3};
    wire [7:0] pair0 = pair_sum0[8:1];
    wire [7:0] pair1 = pair_sum1[8:1];
    wire [15:0] bot_word = {pair0,pair1};

    (* ram_style = "block" *) reg [15:0] line1_mem [0:IMG_WIDTH_GRP-1];
    (* ram_style = "block" *) reg [15:0] line2_mem [0:IMG_WIDTH_GRP-1];
    (* ram_style = "block" *) reg [1:0]  str_mem   [0:IMG_WIDTH_GRP-1];

    reg [10:0] x_grp;
    reg [10:0] y_pos;

    // ------------------------------------------------------------------
    //  one pipeline stage on the line-buffer reads
    //
    //  The detector used to do everything in a single cycle:
    //      x_grp -> line RAM read -> Sobel -> threshold -> flag RAM write
    //  which the timing report measured at 13 logic levels and 10.451 ns
    //  against a 9.66 ns budget (103.52 MHz), so that path never closed.
    //  The RAM words are registered here and every arithmetic stage below
    //  works on those registers, which makes the branch a plain
    //  register-to-register Sobel.  The price is one beat of extra latency:
    //  the maps now come out two beats behind the colour instead of one.
    // ------------------------------------------------------------------
    reg [15:0] top_w_q, mid_w_q, bot_w_q;
    reg [1:0]  st_q;
    reg        wv_q;
    reg [10:0] xw_grp;              // write address, one beat behind x_grp

    wire [15:0] top_word = line2_mem[x_grp];
    wire [15:0] mid_word = line1_mem[x_grp];
    wire [1:0]  up_word  = str_mem[x_grp];

    wire window_valid = (y_pos >= 11'd2) && (x_grp != 11'd0) && !I_tuser;

    wire [7:0] top0 = top_w_q[15:8];
    wire [7:0] top1 = top_w_q[7:0];
    wire [7:0] mid0 = mid_w_q[15:8];
    wire [7:0] mid1 = mid_w_q[7:0];
    wire [7:0] bot0 = bot_w_q[15:8];
    wire [7:0] bot1 = bot_w_q[7:0];

    reg [7:0] top_prev2, top_prev1;
    reg [7:0] mid_prev2, mid_prev1;
    reg [7:0] bot_prev2, bot_prev1;

    // same Sobel as the vendor
    function [13:0] sobel_mag;
        input [7:0] a00, a01, a02;
        input [7:0] a10, a11, a12;
        input [7:0] a20, a21, a22;
        reg signed [12:0] gx_f, gy_f;
        reg [12:0] abs_gx_f, abs_gy_f;
        begin
            gx_f = -$signed({1'b0,a00}) + $signed({1'b0,a02})
                 - ($signed({1'b0,a10}) <<< 1) + ($signed({1'b0,a12}) <<< 1)
                 - $signed({1'b0,a20}) + $signed({1'b0,a22});
            gy_f =  $signed({1'b0,a00}) + ($signed({1'b0,a01}) <<< 1) + $signed({1'b0,a02})
                 - $signed({1'b0,a20}) - ($signed({1'b0,a21}) <<< 1) - $signed({1'b0,a22});
            abs_gx_f = gx_f[12] ? (~gx_f + 1'b1) : gx_f;
            abs_gy_f = gy_f[12] ? (~gy_f + 1'b1) : gy_f;
            sobel_mag = abs_gx_f + abs_gy_f;
        end
    endfunction

    wire [13:0] mag0 = sobel_mag(top_prev2,top_prev1,top0,
                                 mid_prev2,mid_prev1,mid0,
                                 bot_prev2,bot_prev1,bot0);
    wire [13:0] mag1 = sobel_mag(top_prev1,top0,top1,
                                 mid_prev1,mid0,mid1,
                                 bot_prev1,bot0,bot1);

    wire s0 = wv_q && (mag0 >= EDGE_TH);
    wire s1 = wv_q && (mag1 >= EDGE_TH);
    wire w0 = wv_q && (mag0 >= EDGE_TH_LO);
    wire w1 = wv_q && (mag1 >= EDGE_TH_LO);

    // hysteresis: the left neighbour inside the beat, and the same pair on the
    // previous line
    reg       left_s;          // strong flag of the previous beat's second pair

    // second, stricter binary map used only by the cartoon ink
    wire ink0 = wv_q && (mag0 >= EDGE_TH_INK);
    wire ink1 = wv_q && (mag1 >= EDGE_TH_INK);
    wire [23:0] ink_o0 = ink0 ? 24'hffffff : 24'd0;
    wire [23:0] ink_o1 = ink1 ? 24'hffffff : 24'd0;

    wire k0 = s0 || (w0 && (left_s || st_q[1]));
    wire k1 = s1 || (w1 && (s0     || st_q[0]));

    wire [23:0] out0 = k0 ? 24'hffffff : 24'h000000;
    wire [23:0] out1 = k1 ? 24'hffffff : 24'h000000;

    reg t1_last, t1_user, t1_valid;

    // the pipeline stage itself: registers only, no logic.
    // These six registers are assigned in THIS block only, so their reset has
    // to live here too - writing them from the other always block as well makes
    // them multiply driven and the synthesiser rejects the design.
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            top_w_q <= 16'd0;
            mid_w_q <= 16'd0;
            bot_w_q <= 16'd0;
            st_q    <= 2'd0;
            wv_q    <= 1'b0;
            xw_grp  <= 11'd0;
        end else begin
            top_w_q <= top_word;
            mid_w_q <= mid_word;
            bot_w_q <= bot_word;
            st_q    <= up_word;
            wv_q    <= window_valid;
            xw_grp  <= x_grp;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            O_tlast  <= 1'b0;
            O_tuser  <= 1'b0;
            O_tdata  <= 96'd0;
            O_tvalid <= 1'b0;
            O_ink_tdata <= 96'd0;
            t1_last  <= 1'b0;
            t1_user  <= 1'b0;
            t1_valid <= 1'b0;
            x_grp    <= 11'd0;
            y_pos    <= 11'd0;
            top_prev2 <= 8'd0; top_prev1 <= 8'd0;
            mid_prev2 <= 8'd0; mid_prev1 <= 8'd0;
            bot_prev2 <= 8'd0; bot_prev1 <= 8'd0;
            left_s    <= 1'b0;

        end else begin
            O_tlast  <= t1_last;
            O_tuser  <= t1_user;
            O_tvalid <= t1_valid;

            t1_last  <= I_tlast;
            t1_user  <= I_tuser;
            t1_valid <= I_tvalid;

            if(t1_valid) begin
                O_tdata     <= {out0,out0,out1,out1};
                O_ink_tdata <= {ink_o0,ink_o0,ink_o1,ink_o1};
            end else begin
                O_tdata     <= 96'd0;
                O_ink_tdata <= 96'd0;
            end

            // these always describe the beat that was just clocked into the
            // pipeline stage, so they are updated outside the valid gate
            top_prev2 <= top0; top_prev1 <= top1;
            mid_prev2 <= mid0; mid_prev1 <= mid1;
            bot_prev2 <= bot0; bot_prev1 <= bot1;
            left_s    <= s1;

            // the line buffers are written with the registered words at the
            // delayed address, so neither memory sits in a read-modify path
            if(t1_valid) begin
                line2_mem[xw_grp] <= mid_w_q;
                line1_mem[xw_grp] <= bot_w_q;
                str_mem[xw_grp]   <= {s0, s1};
            end

            if(I_tvalid) begin
                if(I_tuser) begin
                    x_grp <= 11'd1;
                    y_pos <= 11'd0;
                    left_s <= 1'b0;

                end else if(x_grp == IMG_WIDTH_GRP - 1) begin
                    // the neighbour registers are deliberately NOT cleared here.
                    // With the pipeline stage they still describe the beat
                    // before the last one of this line, and the only beat that
                    // would see stale values (x=0) is already masked by
                    // window_valid.  Clearing them here made the map of the
                    // last pixel of every line wrong.
                    x_grp <= 11'd0;
                    if(y_pos == IMG_HEIGHT - 1)
                        y_pos <= 11'd0;
                    else
                        y_pos <= y_pos + 1'b1;
                end else begin
                    x_grp <= x_grp + 1'b1;
                end
            end
        end
    end

endmodule

