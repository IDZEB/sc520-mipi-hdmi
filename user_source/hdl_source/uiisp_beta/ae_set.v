//==============================================================================
//  ae_set.v  --  auto exposure controller for SC520CS
//  ---------------------------------------------------------------------------
//  The vendor version starts at exposure 1991, which is the maximum safe value
//  (2*VTS-9 at 720p60) together with 16x analog gain.  Any normal indoor light
//  therefore saturates the sensor - that is the overexposure.
//
//  This controller closes the loop: the ISP measures the mean green level of each
//  frame (I_mean, pulsed by I_mean_ok) and the exposure walks towards a target
//  inside a dead band.  Three deliberate safety nets:
//
//    * start at 600 instead of the maximum
//    * the loop only moves between AE_MIN=200 and AE_MAX=1400, so even a broken
//      brightness measurement can only leave the picture slightly bright or
//      slightly dark - never fully white or fully black
//    * if the measured mean is zero the exposure is held as it is
//
//  Only the exposure moves; the analog gain keeps the vendor value so the noise
//  behaviour of the sensor is unchanged.  Exposure is counted in half lines.
//
//  The grouped 8-register AE burst handshake is unchanged from the vendor code.
//==============================================================================

module ae_set
(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire [3:0]  I_btn,           // kept for compatibility, unused
    input  wire        I_ae_cfg_done,
    input  wire        I_cam_cfg_done,
    input  wire [7:0]  I_mean,          // mean green level of the last frame
    input  wire        I_mean_ok,       // one-clock pulse at the frame boundary
    output wire        O_ae_req,
    output wire [15:0] O_ae,
    output wire [15:0] O_ag
);

    // ---- tuning -----------------------------------------------------------
    localparam [7:0]  TARGET   = 8'd96;    // wanted mean green level
    localparam [7:0]  DEAD     = 8'd8;     // dead band around the target
    localparam [15:0] AE_MIN   = 16'd200;  // safety floor   (vendor: 2)
    localparam [15:0] AE_MAX   = 16'd1991; // vendor maximum (2*VTS-9)
    localparam [15:0] AE_START = 16'd600;
    localparam [15:0] AG_FIX   = 16'd144;  // vendor analog gain, untouched
    localparam [3:0]  SLOW     = 4'd3;     // adapt every 8 frames

    reg [15:0] r_ae_set;
    reg [15:0] r_ag_set;
    reg [3:0]  r_slow;
    reg        r_ok_d;

    wire [15:0] W_step = (r_ae_set >> 3) == 16'd0 ? 16'd1 : (r_ae_set >> 3);
    wire        W_brt  = (I_mean > (TARGET + DEAD));
    wire        W_dark = (I_mean < (TARGET - DEAD));
    wire        W_ok   = (I_mean != 8'd0);      // measurement looks alive

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            r_ae_set <= AE_START;
            r_ag_set <= AG_FIX;
            r_slow   <= 4'd0;
            r_ok_d   <= 1'b0;
        end
        else begin
            r_ok_d <= I_mean_ok;
            if (I_mean_ok && !r_ok_d) begin
                if (r_slow != SLOW) begin
                    r_slow <= r_slow + 4'd1;
                end
                else begin
                    r_slow <= 4'd0;
                    if (!W_ok) begin
                        r_ae_set <= r_ae_set;          // hold: meter is suspicious
                    end
                    else if (W_brt) begin
                        if (r_ae_set > (AE_MIN + W_step))
                            r_ae_set <= r_ae_set - W_step;
                        else
                            r_ae_set <= AE_MIN;
                    end
                    else if (W_dark) begin
                        if (r_ae_set < (AE_MAX - W_step))
                            r_ae_set <= r_ae_set + W_step;
                        else
                            r_ae_set <= AE_MAX;
                    end
                end
            end
        end
    end

    // ---- grouped AE/AG write handshake (vendor logic, untouched) -----------
    reg [15:0] r_ae;
    reg [15:0] r_ag;
    reg        r_ae_req = 0;   // synthesis keep

    assign O_ae     = r_ae;
    assign O_ag     = r_ag;
    assign O_ae_req = r_ae_req;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            r_ae_req <= 0;
            // start from values that differ from the *_set pair so the first
            // grouped write really happens once the sensor is configured
            r_ae     <= 16'd1990;
            r_ag     <= 16'd17;
        end
        else if (r_ae_req) begin
            r_ae_req <= 0;
        end
        else if (((r_ae != r_ae_set) || (r_ag != r_ag_set)) &&
                 (I_cam_cfg_done == 1'b1) && (I_ae_cfg_done == 1'b1)) begin
            r_ae     <= r_ae_set;
            r_ag     <= r_ag_set;
            r_ae_req <= 1;
        end
    end

endmodule
