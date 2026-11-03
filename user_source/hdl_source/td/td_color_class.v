//==============================================================================
//  td_color_class.v  --  per pixel colour class
//  ---------------------------------------------------------------------------
//  Output:
//      0 = NONE     1 = RED     2 = GREEN     3 = BLUE     4 = YELLOW
//
//  The dominance test is now RELATIVE instead of a fixed difference: a channel
//  must lead both others by at least 1/P_SATN of its own value, i.e.
//
//        (max - other) * P_SATN >= max          (P_SATN = 6 -> ~16.7 %)
//
//  A fixed threshold such as "red must lead by 32 codes" is brightness
//  dependent: it rejects pale or dim objects while a dim grey wall passes as
//  soon as its tint differs by 32.  The relative form accepts pastel and dim
//  colours and is independent of exposure; the false positives this admits are
//  removed later by the fill-ratio gate in td_detector, which is what actually
//  separates a compact object from a diffuse colour cast.
//
//  P_CD is kept in the port list for compatibility but no longer used.
//==============================================================================

module td_color_class #(
    parameter [7:0]   P_VMIN = 8'd24,   // brightness floor on max(R,G,B)
    parameter [7:0]   P_CD   = 8'd40,   // absolute floor: |max-other| >= P_CD
    parameter [7:0]   P_YD   = 8'd32,   // yellow: min(R,G) - B >= P_YD
    parameter [7:0]   P_YRG  = 8'd40,   // yellow: |R-G| <= P_YRG
    parameter [7:0]   P_YMIN = 8'd64,   // yellow: min(R,G) >= P_YMIN
    parameter integer P_SATN = 8        // dominance divisor: 1/8 = 12.5 %
)(
    input  wire [7:0] I_r,
    input  wire [7:0] I_g,
    input  wire [7:0] I_b,
    output wire [2:0] O_cls,
    output wire       O_hit
);

    wire [7:0] S_max_rg = (I_r >= I_g) ? I_r : I_g;
    wire [7:0] S_max    = (S_max_rg >= I_b) ? S_max_rg : I_b;

    wire [8:0] S_r = {1'b0, I_r};
    wire [8:0] S_g = {1'b0, I_g};
    wire [8:0] S_b = {1'b0, I_b};

    // a leads b by at least 1/P_SATN of a
    function dom;
        input [8:0] a;
        input [8:0] b;
        begin
            // the absolute floor matters in the shadows: a dark grey pixel with
            // a tiny tint (40/45/55) has a huge *ratio* but no real colour, and
            // without the floor a whole dark frame classifies as saturated
            dom = (a >= b) && ((a - b) >= {1'b0, P_CD}) &&
                  (((a - b) * P_SATN) >= a);
        end
    endfunction

    wire S_bright = (S_max >= P_VMIN);

    wire S_is_red   = dom(S_r, S_g) && dom(S_r, S_b);
    wire S_is_green = dom(S_g, S_r) && dom(S_g, S_b);
    wire S_is_blue  = dom(S_b, S_r) && dom(S_b, S_g);

    wire [8:0] S_rg_min = (S_r <= S_g) ? S_r : S_g;
    wire [8:0] S_rg_abs = (S_r >= S_g) ? (S_r - S_g) : (S_g - S_r);
    wire S_is_yellow = (S_rg_min >= {1'b0, P_YMIN}) &&
                       ((S_b + {1'b0, P_YD}) <= S_rg_min) &&
                       (S_rg_abs <= {1'b0, P_YRG});

    assign O_hit = S_bright;
    assign O_cls = (!S_bright)   ? 3'd0 :
                   (S_is_yellow) ? 3'd4 :
                   (S_is_red)    ? 3'd1 :
                   (S_is_green)  ? 3'd2 :
                   (S_is_blue)   ? 3'd3 : 3'd0;

endmodule
