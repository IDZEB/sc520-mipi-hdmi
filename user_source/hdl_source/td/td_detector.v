//==============================================================================
//  td_detector.v  --  streaming band-segmentation target detector
//  ---------------------------------------------------------------------------
//  Same ports, same parameters and the same 716-bit result bus as the reference
//  module, but the per-band statistics no longer live in a [NBAND][4] register
//  array.  That array alone was 16*4*60 = 3840 flip-flops and pushed the device
//  over its slice limit (P&R: 23496 > 21216).
//
//  Instead one 4-class accumulator holds the band currently being scanned.  At
//  every band boundary the accumulator is folded into a per-class segment:
//
//      band count >= P_BAND_MIN   -> segment open (first band) or extended
//      band count <  P_BAND_MIN   -> segment closed, emitted if big enough
//                                    (P_MIN_W / P_MIN_H / P_MIN_AREA)
//
//  A target spanning several bands is assembled on the fly, which is what the
//  reference did with its frame-end band scan, but the register cost no longer
//  depends on NBAND.
//
//  Frame boundary: the reference compared S_ypos against IMG_H-1, which never
//  matches when the real stream carries one line less than IMG_H (our sensor
//  emits 367 lines).  The scan then never ran and zero targets were reported.
//  The frame-start flag of the next frame is used instead.
//
//  Result bus layout (must stay in sync with td_osd_overlay.v):
//    [127:0]   32 BCD nibbles, digit slot k at [4k +: 4]
//    [131:128] total count
//    [135:132] red  [139:136] green  [143:140] blue  [147:144] yellow
//    [195:148] 8 boxes, 48 bit each: [47] valid [46:45] class
//              [44:34] x1 [33:23] y1 [22:12] x2 [11:1] y2 [0] spare
//    [715:692] 8 shape codes, 3 bit each
//    [127:0]   BCD digits of the first three boxes (box i at 32i): x1 nibbles
//              0..3 = ones..thousands, y1 nibbles 4..6 = ones..hundreds;
//              nibble 24/25 = count tens/ones
//==============================================================================

module td_detector #(
    parameter integer IMG_W      = 1280,
    parameter integer IMG_H      = 720,
    parameter integer BAND_H     = 80,
    parameter integer NBAND      = 9,     // kept for compatibility, no cost
    parameter [7:0]   P_VMIN     = 8'd48,
    parameter [7:0]   P_CD       = 8'd32,
    parameter [7:0]   P_YD       = 8'd40,
    parameter [7:0]   P_YRG      = 8'd24,
    parameter [7:0]   P_YMIN     = 8'd96,
    parameter [17:0]  P_BAND_MIN = 18'd160,
    parameter [10:0]  P_MIN_W    = 11'd24,
    parameter [10:0]  P_MIN_H    = 11'd24,
    parameter [19:0]  P_MIN_AREA = 20'd600,
    // a target cannot be larger than three quarters of the frame: a diffuse
    // colour cast covers everything and would otherwise pass every other gate
    parameter [10:0]  P_MAX_W    = (IMG_W * 3) / 4,
    parameter [10:0]  P_MAX_H    = (IMG_H * 3) / 4,
    // brightness class: R+2G+B must exceed the band mean by P_BGDEV per channel
    parameter [9:0]   P_BGDEV    = 10'd24
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    input  wire         I_tuser,
    input  wire         I_tlast,
    input  wire         I_tvalid,
    input  wire [95:0]  I_tdata,
    output reg  [715:0] O_res,
    output reg          O_res_tog,
    output wire [9:0]   O_cur_y,
    output wire [3:0]   O_cur_band,
    output wire         O_busy
);

    localparam integer TD_BOX_OFF    = 148;
    localparam integer TD_BOX_STRIDE = 48;
    localparam integer TD_SHAPE_OFF  = 692;
    localparam integer TD_SHAPE_STR  = 3;

    localparam [2:0] SH_UNK    = 3'd0;
    localparam [2:0] SH_SQUARE = 3'd1;
    localparam [2:0] SH_CIRCLE = 3'd2;
    localparam [2:0] SH_TRI    = 3'd3;
    localparam [2:0] SH_RECTH  = 3'd4;
    localparam [2:0] SH_RECTV  = 3'd5;

    localparam integer BPL = IMG_W / 4;
    localparam [8:0]   LP_LAST_BEAT = BPL - 1;
    localparam [10:0]  LP_BANDH     = BAND_H;

    //--------------------------------------------------------------------------
    //  frame geometry
    //--------------------------------------------------------------------------
    reg [8:0]  S_xb;
    reg [9:0]  S_ypos;
    reg [3:0]  S_yband;
    reg [10:0] S_yband_thr;

    reg        S_frame_ready;
    reg        S_pend;
    reg        S_final;

    // The monitor tap carries no frame-start beat, so the frame is delimited
    // by the idle gap of the stream (verified on hardware).
    localparam [15:0] LP_GAP_MIN = 16'd3000;
    reg  [15:0] S_gap;
    reg         S_tv_d;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_gap  <= 16'd0;
            S_tv_d <= 1'b0;
        end
        else begin
            S_tv_d <= I_tvalid;
            if (!I_tvalid) S_gap <= (S_gap == 16'hFFFF) ? S_gap : S_gap + 16'd1;
            else           S_gap <= 16'd0;
        end
    end
    wire S_gap_start = I_tvalid && !S_tv_d && (S_gap >= LP_GAP_MIN);
    wire S_frame_end = S_gap_start || (I_tvalid && I_tuser && S_frame_ready);

    wire [8:0]  W_xb    = I_tuser ? 9'd0  : S_xb;
    wire [9:0]  W_y     = I_tuser ? 10'd0 : S_ypos;
    wire [3:0]  W_yband = I_tuser ? 4'd0  : S_yband;
    wire [10:0] W_x0    = {W_xb, 2'b00};
    wire [10:0] W_x1    = W_x0 + 11'd1;
    wire [10:0] W_x2    = W_x0 + 11'd2;
    wire [10:0] W_x3    = W_x0 + 11'd3;

    assign O_cur_y    = S_ypos;
    assign O_cur_band = W_yband;

    //--------------------------------------------------------------------------
    //  colour classification, four pixels per beat
    //--------------------------------------------------------------------------
    wire [2:0] W_cls0, W_cls1, W_cls2, W_cls3;

    td_color_class #(.P_VMIN(P_VMIN), .P_CD(P_CD), .P_YD(P_YD),
                     .P_YRG(P_YRG), .P_YMIN(P_YMIN)) u_cls0 (
        .I_r(I_tdata[95:88]), .I_g(I_tdata[87:80]), .I_b(I_tdata[79:72]),
        .O_cls(W_cls0), .O_hit()
    );
    td_color_class #(.P_VMIN(P_VMIN), .P_CD(P_CD), .P_YD(P_YD),
                     .P_YRG(P_YRG), .P_YMIN(P_YMIN)) u_cls1 (
        .I_r(I_tdata[71:64]), .I_g(I_tdata[63:56]), .I_b(I_tdata[55:48]),
        .O_cls(W_cls1), .O_hit()
    );
    td_color_class #(.P_VMIN(P_VMIN), .P_CD(P_CD), .P_YD(P_YD),
                     .P_YRG(P_YRG), .P_YMIN(P_YMIN)) u_cls2 (
        .I_r(I_tdata[47:40]), .I_g(I_tdata[39:32]), .I_b(I_tdata[31:24]),
        .O_cls(W_cls2), .O_hit()
    );
    td_color_class #(.P_VMIN(P_VMIN), .P_CD(P_CD), .P_YD(P_YD),
                     .P_YRG(P_YRG), .P_YMIN(P_YMIN)) u_cls3 (
        .I_r(I_tdata[23:16]), .I_g(I_tdata[15:8]), .I_b(I_tdata[7:0]),
        .O_cls(W_cls3), .O_hit()
    );

    wire S_r0 = (W_cls0 == 3'd1), S_r1 = (W_cls1 == 3'd1),
         S_r2 = (W_cls2 == 3'd1), S_r3 = (W_cls3 == 3'd1);
    wire S_g0 = (W_cls0 == 3'd2), S_g1 = (W_cls1 == 3'd2),
         S_g2 = (W_cls2 == 3'd2), S_g3 = (W_cls3 == 3'd2);
    wire S_b0 = (W_cls0 == 3'd3), S_b1 = (W_cls1 == 3'd3),
         S_b2 = (W_cls2 == 3'd3), S_b3 = (W_cls3 == 3'd3);
    wire S_y0 = (W_cls0 == 3'd4), S_y1 = (W_cls1 == 3'd4),
         S_y2 = (W_cls2 == 3'd4), S_y3 = (W_cls3 == 3'd4);

    wire [2:0] W_n_r = {2'b0, S_r0} + {2'b0, S_r1} + {2'b0, S_r2} + {2'b0, S_r3};
    wire [2:0] W_n_g = {2'b0, S_g0} + {2'b0, S_g1} + {2'b0, S_g2} + {2'b0, S_g3};
    wire [2:0] W_n_b = {2'b0, S_b0} + {2'b0, S_b1} + {2'b0, S_b2} + {2'b0, S_b3};
    wire [2:0] W_n_y = {2'b0, S_y0} + {2'b0, S_y1} + {2'b0, S_y2} + {2'b0, S_y3};

    wire [10:0] W_mn_r = S_r0 ? W_x0 : S_r1 ? W_x1 : S_r2 ? W_x2 : W_x3;
    wire [10:0] W_mx_r = S_r3 ? W_x3 : S_r2 ? W_x2 : S_r1 ? W_x1 : W_x0;
    wire [10:0] W_mn_g = S_g0 ? W_x0 : S_g1 ? W_x1 : S_g2 ? W_x2 : W_x3;
    wire [10:0] W_mx_g = S_g3 ? W_x3 : S_g2 ? W_x2 : S_g1 ? W_x1 : W_x0;
    wire [10:0] W_mn_b = S_b0 ? W_x0 : S_b1 ? W_x1 : S_b2 ? W_x2 : W_x3;
    wire [10:0] W_mx_b = S_b3 ? W_x3 : S_b2 ? W_x2 : S_b1 ? W_x1 : W_x0;
    wire [10:0] W_mn_y = S_y0 ? W_x0 : S_y1 ? W_x1 : S_y2 ? W_x2 : W_x3;
    wire [10:0] W_mx_y = S_y3 ? W_x3 : S_y2 ? W_x2 : S_y1 ? W_x1 : W_x0;

    //--------------------------------------------------------------------------
    //  current band accumulator, 4 classes
    //--------------------------------------------------------------------------
    reg [15:0] A_cnt [0:4];
    reg [10:0] A_mnx [0:4];
    reg [10:0] A_mxx [0:4];
    reg [9:0]  A_mny [0:4];
    reg [9:0]  A_mxy [0:4];

    //--------------------------------------------------------------------------
    //  open segment per class
    //--------------------------------------------------------------------------
    reg        G_open [0:4];
    reg [10:0] G_mnx  [0:4];
    reg [10:0] G_mxx  [0:4];
    reg [9:0]  G_mny  [0:4];
    reg [9:0]  G_mxy  [0:4];
    reg [19:0] G_area [0:4];

    //--------------------------------------------------------------------------
    //  target list, two boxes per class
    //--------------------------------------------------------------------------
    reg        B_val   [0:7];
    reg [1:0]  B_cls   [0:7];
    reg        B_brt   [0:7];
    reg [10:0] B_x1    [0:7];
    reg [10:0] B_y1    [0:7];
    reg [10:0] B_x2    [0:7];
    reg [10:0] B_y2    [0:7];
    reg [2:0]  B_shape [0:7];

    reg [2:0]  S_nbox [0:4];
    reg [3:0]  S_nbox_all;
    reg [3:0]  S_cnt_cls [0:4];
    reg [3:0]  S_cnt_total;

    wire [10:0] W_b0_w = B_x2[0] - B_x1[0] + 11'd1;
    wire [10:0] W_b0_h = {1'b0, B_y2[0]} - {1'b0, B_y1[0]} + 11'd1;

    //--------------------------------------------------------------------------
    //  frame-end state machine
    //--------------------------------------------------------------------------
    localparam [2:0] F_IDLE  = 3'd0,
                     F_FLUSH = 3'd1,
                     F_CE    = 3'd2,
                     F_BCD   = 3'd3,
                     F_BCDW  = 3'd4,
                     F_PUB   = 3'd5;

    reg [2:0] S_st;
    reg [2:0] S_fc;
    reg [3:0] S_sel;
    reg [3:0] S_dig [0:31];
    reg       S_bcd_start;
    reg [19:0] S_bcd_val;
    wire      S_bcd_done;
    wire [23:0] S_bcd;

    td_bin2bcd u_bin2bcd (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_start(S_bcd_start), .I_value(S_bcd_val),
        .O_busy(), .O_done(S_bcd_done), .O_bcd(S_bcd)
    );

    assign O_busy = (S_st != F_IDLE);

    //--------------------------------------------------------------------------
    //  shape classification of the segment being closed
    //  fill ratio: area/(w*h) compared against 0.88 (square) and 0.55 (circle),
    //  all scaled by 100 so no divider is needed.
    //--------------------------------------------------------------------------
    function [2:0] F_shape;
        input [10:0] w;
        input [9:0]  h;
        input [19:0] a;
        reg [21:0] wh;
        reg [27:0] q100, p88, p55;
        reg [12:0] w4, h4, w3, h3;
        begin
            wh   = w * {1'b0, h};
            q100 = ({8'd0, a} << 6) + ({8'd0, a} << 5) + ({8'd0, a} << 2);
            p88  = (wh << 6) + (wh << 4) + (wh << 3);
            p55  = (wh << 6) - (wh << 3) - wh;
            w4   = {2'd0, w} << 2;
            h4   = {3'd0, h} << 2;
            w3   = {2'd0, w} + {1'b0, w} + w;
            h3   = {3'd0, h} + {2'd0, h} + h;
            if ((w4 >= h3) && (h4 >= w3))
                F_shape = (q100 > p88) ? SH_SQUARE :
                          (q100 > p55) ? SH_CIRCLE : SH_TRI;
            else
                F_shape = (w > {1'b0, h}) ? SH_RECTH : SH_RECTV;
        end
    endfunction

    //  decision for the class currently being closed
    wire [10:0] W_cw   = G_mxx[S_fc] - G_mnx[S_fc] + 11'd1;
    wire [9:0]  W_ch   = G_mxy[S_fc] - G_mny[S_fc] + 10'd1;
    //--------------------------------------------------------------------------
    //  band background luma.  R+2G+B of every pixel is summed over the band and
    //  the previous band's mean becomes the reference: a pixel that is clearly
    //  brighter than its own band is a target regardless of its colour, which is
    //  the only way to catch a grey or white object.
    //--------------------------------------------------------------------------
    reg [25:0] S_lsum;
    reg [11:0] S_lbg;
    wire [11:0] W_bgthr = S_lbg + {P_BGDEV, 2'b00};

    wire [11:0] P_l0 = {2'b00, I_tdata[95:88]} + {1'b0, I_tdata[87:80], 1'b0} + {2'b00, I_tdata[79:72]};
    wire [11:0] P_l1 = {2'b00, I_tdata[71:64]} + {1'b0, I_tdata[63:56], 1'b0} + {2'b00, I_tdata[55:48]};
    wire [11:0] P_l2 = {2'b00, I_tdata[47:40]} + {1'b0, I_tdata[39:32], 1'b0} + {2'b00, I_tdata[31:24]};
    wire [11:0] P_l3 = {2'b00, I_tdata[23:16]} + {1'b0, I_tdata[15:8], 1'b0} + {2'b00, I_tdata[7:0]};

    wire S_br0 = (P_l0 > W_bgthr);
    wire S_br1 = (P_l1 > W_bgthr);
    wire S_br2 = (P_l2 > W_bgthr);
    wire S_br3 = (P_l3 > W_bgthr);

    // bright but not already a colour class
    wire S_bn0 = S_br0 && (W_cls0 == 3'd0);
    wire S_bn1 = S_br1 && (W_cls1 == 3'd0);
    wire S_bn2 = S_br2 && (W_cls2 == 3'd0);
    wire S_bn3 = S_br3 && (W_cls3 == 3'd0);
    wire [2:0] W_n_br = {2'b0, S_bn0} + {2'b0, S_bn1} + {2'b0, S_bn2} + {2'b0, S_bn3};
    wire [10:0] W_mn_br = S_bn0 ? W_x0 : S_bn1 ? W_x1 : S_bn2 ? W_x2 : W_x3;
    wire [10:0] W_mx_br = S_bn3 ? W_x3 : S_bn2 ? W_x2 : S_bn1 ? W_x1 : W_x0;

    wire [3:0]  W_cidx = S_nbox_all;
    wire [2:0]  W_csh  = F_shape(W_cw, W_ch, G_area[S_fc]);
    // fill-ratio guard: a real target covers at least a quarter of its bounding
    // box (triangle 50 %, circle 78 %, square 100 %).  A diffuse colour cast -
    // the classic false positive - has a huge box and almost no pixels in it,
    // so this one compare is what lets the colour test be much more sensitive.
    wire [21:0] W_cwh    = W_cw * {1'b0, W_ch};
    wire [21:0] W_carea4 = {2'b0, G_area[S_fc]} << 2;
    // bands are folded one after another; if this band's bright pixels sit
    // somewhere else in x, the running segment must be closed instead of
    // unioning the two bounding boxes (which used to blow the box up until the
    // size gate rejected everything)
    wire [11:0] W_bmx0 = {1'b0, A_mnx[S_fc]};
    wire [11:0] W_bmx1 = {1'b0, A_mxx[S_fc]};
    wire        W_ovl  = (W_bmx0 <= ({1'b0, G_mxx[S_fc]} + 12'd48)) &&
                         ((W_bmx1 + 12'd48) >= {1'b0, G_mnx[S_fc]});

    // ---- band solidity ---------------------------------------------------
    // A band of a diffuse colour cast has a wide bounding box and almost no
    // pixels in it; a real object fills its box.  count >= 3*(w+h) tells them
    // apart without a multiplier.
    wire [10:0] W_bw   = (A_mxx[S_fc] >= A_mnx[S_fc]) ?
                         (A_mxx[S_fc] - A_mnx[S_fc] + 11'd1) : 11'd0;
    wire [10:0] W_bh   = (A_mxy[S_fc] >= A_mny[S_fc]) ?
                         ({1'b0, A_mxy[S_fc]} - {1'b0, A_mny[S_fc]} + 11'd1) : 11'd0;
    wire [11:0] W_bper = W_bw + W_bh;
    wire [13:0] W_b3   = W_bper + {1'b0, W_bper, 1'b0};
    wire        W_bsolid = ({4'd0, A_cnt[S_fc]} >= {2'd0, W_b3});

    wire        W_cok  = G_open[S_fc] &&
                         (W_cw >= P_MIN_W) &&
                         ({1'b0, W_ch} >= P_MIN_H) &&
                         (W_cw <= P_MAX_W) && ({1'b0, W_ch} <= P_MAX_H) &&
                         (G_area[S_fc] >= P_MIN_AREA) &&
                         (W_carea4 >= W_cwh) &&
                         (S_nbox[S_fc] < 3'd2) && (S_nbox_all < 4'd8);

    //--------------------------------------------------------------------------
    //  published bus
    //--------------------------------------------------------------------------
    reg [715:0] W_res_next;
    integer pi;
    always @(*) begin
        W_res_next = 716'd0;
        for (pi = 0; pi < 32; pi = pi + 1)
            W_res_next[4*pi +: 4] = S_dig[pi];
        W_res_next[131:128] = S_cnt_total;
        W_res_next[135:132] = S_cnt_cls[0];
        W_res_next[139:136] = S_cnt_cls[1];
        W_res_next[143:140] = S_cnt_cls[2];
        W_res_next[147:144] = S_cnt_cls[3];
        for (pi = 0; pi < 8; pi = pi + 1) begin
            W_res_next[TD_BOX_OFF + TD_BOX_STRIDE*pi +: TD_BOX_STRIDE] =
                {B_val[pi], B_cls[pi], B_x1[pi], B_y1[pi], B_x2[pi], B_y2[pi], B_brt[pi]};
            W_res_next[TD_SHAPE_OFF + TD_SHAPE_STR*pi +: TD_SHAPE_STR] = B_shape[pi];
        end
    end

    integer k, j;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_xb          <= 9'd0;
            S_ypos        <= 10'd0;
            S_yband       <= 4'd0;
            S_yband_thr   <= LP_BANDH;
            S_frame_ready <= 1'b0;
            S_pend        <= 1'b0;
            S_final       <= 1'b0;
            S_st          <= F_IDLE;
            S_fc          <= 2'd0;
            S_sel         <= 4'd0;
            S_bcd_start   <= 1'b0;
            S_bcd_val     <= 20'd0;
            S_lsum        <= 26'd0;
            S_lbg         <= 12'd0;
            S_cnt_total   <= 4'd0;
            S_nbox_all    <= 4'd0;
            O_res         <= 716'd0;
            O_res_tog     <= 1'b0;
            for (k = 0; k < 5; k = k + 1) begin
                A_cnt[k] <= 16'd0;
                A_mnx[k] <= 11'h7FF;
                A_mxx[k] <= 11'd0;
                A_mny[k] <= 10'h3FF;
                A_mxy[k] <= 10'd0;
                G_open[k]  <= 1'b0;
                G_mnx[k]   <= 11'h7FF;
                G_mxx[k]   <= 11'd0;
                G_mny[k]   <= 10'h3FF;
                G_mxy[k]   <= 10'd0;
                G_area[k]  <= 20'd0;
                S_nbox[k]  <= 3'd0;
                S_cnt_cls[k] <= 4'd0;
            end
            for (k = 0; k < 8; k = k + 1) begin
                B_val[k]   <= 1'b0;
                B_cls[k]   <= 2'd0;
                B_brt[k]   <= 1'b0;
                B_x1[k]    <= 11'd0;
                B_y1[k]    <= 11'd0;
                B_x2[k]    <= 11'd0;
                B_y2[k]    <= 11'd0;
                B_shape[k] <= SH_UNK;
            end
            for (k = 0; k < 32; k = k + 1)
                S_dig[k] <= 4'd0;
        end
        else begin
            //------------------------------------------------------------------
            //  coordinates, band boundaries and band accumulation
            //------------------------------------------------------------------
            if (I_tvalid) begin
                if (I_tuser) begin
                    S_frame_ready <= 1'b1;
                    S_xb        <= 9'd1;
                    S_ypos      <= 10'd0;
                    S_yband     <= 4'd0;
                    S_yband_thr <= LP_BANDH;
                end
                else if (S_xb == LP_LAST_BEAT) begin
                    S_xb <= 9'd0;
                    if (S_ypos == IMG_H - 1) begin
                        S_ypos      <= 10'd0;
                        S_yband     <= 4'd0;
                        S_yband_thr <= LP_BANDH;
                    end
                    else begin
                        S_ypos <= S_ypos + 10'd1;
                        if ((S_ypos + 10'd1) == S_yband_thr) begin
                            S_yband     <= S_yband + 4'd1;
                            S_yband_thr <= S_yband_thr + LP_BANDH;
                            S_pend      <= 1'b1;
                            S_lbg       <= S_lsum[25:15];
                        end
                    end
                end
                else begin
                    S_xb <= S_xb + 9'd1;
                end

                // band luma sum runs unconditionally so the background of the
                // next band is ready even while the FSM is folding
                if (I_tuser)
                    S_lsum <= {14'd0, P_l0 + P_l1 + P_l2 + P_l3};
                else if (S_pend)
                    S_lsum <= {14'd0, P_l0 + P_l1 + P_l2 + P_l3};
                else
                    S_lsum <= S_lsum + {14'd0, P_l0 + P_l1 + P_l2 + P_l3};

                if ((S_st == F_IDLE) && !S_pend && !S_frame_end) begin
                    if (W_n_br != 3'd0) begin
                        A_cnt[4] <= A_cnt[4] + {13'd0, W_n_br};
                        if (W_mn_br < A_mnx[4]) A_mnx[4] <= W_mn_br;
                        if (W_mx_br > A_mxx[4]) A_mxx[4] <= W_mx_br;
                        if (W_y     < A_mny[4]) A_mny[4] <= W_y;
                        if (W_y     > A_mxy[4]) A_mxy[4] <= W_y;
                    end
                    if (W_n_r != 3'd0) begin
                        A_cnt[0] <= A_cnt[0] + {13'd0, W_n_r};
                        if (W_mn_r < A_mnx[0]) A_mnx[0] <= W_mn_r;
                        if (W_mx_r > A_mxx[0]) A_mxx[0] <= W_mx_r;
                        if (W_y    < A_mny[0]) A_mny[0] <= W_y;
                        if (W_y    > A_mxy[0]) A_mxy[0] <= W_y;
                    end
                    if (W_n_g != 3'd0) begin
                        A_cnt[1] <= A_cnt[1] + {13'd0, W_n_g};
                        if (W_mn_g < A_mnx[1]) A_mnx[1] <= W_mn_g;
                        if (W_mx_g > A_mxx[1]) A_mxx[1] <= W_mx_g;
                        if (W_y    < A_mny[1]) A_mny[1] <= W_y;
                        if (W_y    > A_mxy[1]) A_mxy[1] <= W_y;
                    end
                    if (W_n_b != 3'd0) begin
                        A_cnt[2] <= A_cnt[2] + {13'd0, W_n_b};
                        if (W_mn_b < A_mnx[2]) A_mnx[2] <= W_mn_b;
                        if (W_mx_b > A_mxx[2]) A_mxx[2] <= W_mx_b;
                        if (W_y    < A_mny[2]) A_mny[2] <= W_y;
                        if (W_y    > A_mxy[2]) A_mxy[2] <= W_y;
                    end
                    if (W_n_y != 3'd0) begin
                        A_cnt[3] <= A_cnt[3] + {13'd0, W_n_y};
                        if (W_mn_y < A_mnx[3]) A_mnx[3] <= W_mn_y;
                        if (W_mx_y > A_mxx[3]) A_mxx[3] <= W_mx_y;
                        if (W_y    < A_mny[3]) A_mny[3] <= W_y;
                        if (W_y    > A_mxy[3]) A_mxy[3] <= W_y;
                    end
                end
            end

            //------------------------------------------------------------------
            //  frame-end request
            //------------------------------------------------------------------
            if (S_frame_end && (S_st == F_IDLE) && !S_final) begin
                S_final <= 1'b1;
                S_pend  <= 1'b1;
            end

            //------------------------------------------------------------------
            //  state machine
            //------------------------------------------------------------------
            if (S_st != F_BCD) S_bcd_start <= 1'b0;

            case (S_st)
            F_IDLE: begin
                if (S_pend) begin
                    S_fc <= 2'd0;
                    S_st <= F_FLUSH;
                end
            end

            F_FLUSH: begin
                if ((A_cnt[S_fc] >= P_BAND_MIN) && W_bsolid) begin
                    if (!G_open[S_fc]) begin
                        G_open[S_fc] <= 1'b1;
                        G_mnx[S_fc]  <= A_mnx[S_fc];
                        G_mxx[S_fc]  <= A_mxx[S_fc];
                        G_mny[S_fc]  <= A_mny[S_fc];
                        G_mxy[S_fc]  <= A_mxy[S_fc];
                        G_area[S_fc] <= {4'd0, A_cnt[S_fc]};
                    end
                    else if (W_ovl) begin
                        if (A_mnx[S_fc] < G_mnx[S_fc]) G_mnx[S_fc] <= A_mnx[S_fc];
                        if (A_mxx[S_fc] > G_mxx[S_fc]) G_mxx[S_fc] <= A_mxx[S_fc];
                        if (A_mny[S_fc] < G_mny[S_fc]) G_mny[S_fc] <= A_mny[S_fc];
                        if (A_mxy[S_fc] > G_mxy[S_fc]) G_mxy[S_fc] <= A_mxy[S_fc];
                        G_area[S_fc] <= G_area[S_fc] + {4'd0, A_cnt[S_fc]};
                    end
                    else begin
                        // disjoint in x: emit the finished segment, start a new
                        // one from this band
                        if (W_cok) begin
                            B_val[W_cidx]   <= 1'b1;
                            B_cls[W_cidx]   <= (S_fc == 3'd4) ? 2'd0 : S_fc[1:0];
                            B_brt[W_cidx]   <= (S_fc == 3'd4);
                            B_x1[W_cidx]    <= G_mnx[S_fc];
                            B_x2[W_cidx]    <= G_mxx[S_fc];
                            B_y1[W_cidx]    <= G_mny[S_fc];
                            B_y2[W_cidx]    <= G_mxy[S_fc];
                            B_shape[W_cidx] <= W_csh;
                            S_nbox[S_fc]    <= S_nbox[S_fc] + 3'd1;
                            S_nbox_all      <= S_nbox_all + 4'd1;
                            S_cnt_cls[S_fc] <= S_cnt_cls[S_fc] + 4'd1;
                            S_cnt_total     <= S_cnt_total + 4'd1;
                        end
                        G_mnx[S_fc]  <= A_mnx[S_fc];
                        G_mxx[S_fc]  <= A_mxx[S_fc];
                        G_mny[S_fc]  <= A_mny[S_fc];
                        G_mxy[S_fc]  <= A_mxy[S_fc];
                        G_area[S_fc] <= {4'd0, A_cnt[S_fc]};
                    end
                end

                if (S_fc == 3'd4) begin
                    S_fc   <= 2'd0;
                    S_pend <= 1'b0;
                    for (k = 0; k < 5; k = k + 1) begin
                        A_cnt[k] <= 16'd0;
                        A_mnx[k] <= 11'h7FF;
                        A_mxx[k] <= 11'd0;
                        A_mny[k] <= 10'h3FF;
                        A_mxy[k] <= 10'd0;
                    end
                    S_st <= S_final ? F_CE : F_IDLE;
                end
                else begin
                    S_fc <= S_fc + 3'd1;
                end
            end

            F_CE: begin
                if (G_open[S_fc]) begin
                    if (W_cok) begin
                        B_val[W_cidx]   <= 1'b1;
                        B_cls[W_cidx]   <= (S_fc == 3'd4) ? 2'd0 : S_fc[1:0];
                        B_brt[W_cidx]   <= (S_fc == 3'd4);
                        B_x1[W_cidx]    <= G_mnx[S_fc];
                        B_x2[W_cidx]    <= G_mxx[S_fc];
                        B_y1[W_cidx]    <= G_mny[S_fc];
                        B_y2[W_cidx]    <= G_mxy[S_fc];
                        B_shape[W_cidx] <= W_csh;
                        S_nbox[S_fc]    <= S_nbox[S_fc] + 3'd1;
                        S_nbox_all      <= S_nbox_all + 4'd1;
                        S_cnt_cls[S_fc] <= S_cnt_cls[S_fc] + 4'd1;
                        S_cnt_total     <= S_cnt_total + 4'd1;
                    end
                    G_open[S_fc] <= 1'b0;
                    G_mnx[S_fc]  <= 11'h7FF;
                    G_mxx[S_fc]  <= 11'd0;
                    G_mny[S_fc]  <= 10'h3FF;
                    G_mxy[S_fc]  <= 10'd0;
                    G_area[S_fc] <= 20'd0;
                end
                if (S_fc == 3'd4) begin
                    S_fc  <= 2'd0;
                    S_sel <= 4'd0;
                    S_st  <= F_BCD;
                end
                else begin
                    S_fc <= S_fc + 3'd1;
                end
            end

            F_BCD: begin
                S_bcd_start <= 1'b1;
                S_st        <= F_BCDW;
            end

            F_BCDW: begin
                if (S_bcd_done) begin
                    case (S_sel)
                    4'd0: for (j = 0; j < 4; j = j + 1) S_dig[0+j]  <= S_bcd[4*j +: 4];
                    4'd1: for (j = 0; j < 3; j = j + 1) S_dig[4+j]  <= S_bcd[4*j +: 4];
                    4'd2: for (j = 0; j < 4; j = j + 1) S_dig[8+j]  <= S_bcd[4*j +: 4];
                    4'd3: for (j = 0; j < 3; j = j + 1) S_dig[12+j] <= S_bcd[4*j +: 4];
                    4'd4: for (j = 0; j < 4; j = j + 1) S_dig[16+j] <= S_bcd[4*j +: 4];
                    4'd5: for (j = 0; j < 3; j = j + 1) S_dig[20+j] <= S_bcd[4*j +: 4];
                    default: for (j = 0; j < 2; j = j + 1) S_dig[24+j] <= S_bcd[4*j +: 4];
                    endcase

                    if (S_sel == 4'd6) begin
                        S_sel <= 4'd0;
                        S_st  <= F_PUB;
                    end
                    else begin
                        S_sel <= S_sel + 4'd1;
                        S_st  <= F_BCD;
                    end
                end
            end

            F_PUB: begin
                O_res       <= W_res_next;
                O_res_tog   <= ~O_res_tog;
                S_final     <= 1'b0;
                S_cnt_total <= 4'd0;
                S_nbox_all  <= 4'd0;
                for (k = 0; k < 5; k = k + 1) begin
                    S_nbox[k]    <= 3'd0;
                    S_cnt_cls[k] <= 4'd0;
                end
                for (k = 0; k < 8; k = k + 1) begin
                    B_val[k]   <= 1'b0;
                    B_shape[k] <= SH_UNK;
                end
                S_st <= F_IDLE;
            end

            default: S_st <= F_IDLE;
            endcase

            //------------------------------------------------------------------
            //  BCD input selection (primary target = box 0)
            //------------------------------------------------------------------
            case (S_sel)
            4'd0:    S_bcd_val <= {9'd0,  B_x1[0]};
            4'd1:    S_bcd_val <= {9'd0,  B_y1[0]};
            4'd2:    S_bcd_val <= {9'd0,  B_x1[1]};
            4'd3:    S_bcd_val <= {9'd0,  B_y1[1]};
            4'd4:    S_bcd_val <= {9'd0,  B_x1[2]};
            4'd5:    S_bcd_val <= {9'd0,  B_y1[2]};
            4'd6:    S_bcd_val <= {16'd0, S_cnt_total};
            default: S_bcd_val <= 20'd0;
            endcase
        end
    end

endmodule
