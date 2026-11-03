module isp_top (
        input  wire [2:0] I_video_mode,   // 0=EDGE 1=ENH 2=RAW 3=VIV 4=VIV+
    input 			axi4s_video_aclk,
    input 			I_rst_n			,
    input 			I_tlast			,
    input 			I_tuser			,
    input [39:0] 	I_tdata			,
    input 			I_tvalid		,
    input [9:0] 	I_tdest			,
    input 			O_tready		,
    output [127:0] 	O_tdata			,
    output 			O_tlast			,
    output 			O_tuser			,
    output 			O_tvalid		,
    output 			I_tready,
    // ---- extension 2: read-only monitor port (taken from the AWB output) ----
    output wire [95:0] O_mon_tdata,
    output wire        O_mon_tuser,
    output wire        O_mon_tlast,
    output wire        O_mon_tvalid,
    output wire [7:0]  O_ae_mean,    // mean green level of the last frame
    output wire        O_ae_done,    // one-clock pulse at the frame boundary
    output wire     O_uart_txd,     // thumb UART out -> onboard FT2232 ch-B -> COM3
    input  wire     I_uart_rxd,      // live-tuning UART in <- FT2232 ch-B TXD (J1)
    // ---- Ethernet video transmit ----
    input  wire       I_eth_clk_125,
    input  wire       I_eth_clk_125_90,
    input  wire       I_eth_rst,
    output wire [3:0] O_eth_txd,
    output wire       O_eth_tx_ctl,
    output wire       O_eth_txc,
    output wire       O_eth_phy_rst
);
 
wire         m_aixs_tvalid;  //synthesis keep 
  wire [127:0] m_aixs_tdata;  //synthesis keep 
  wire         m_aixs_tuser;  //synthesis keep 
  wire         m_aixs_tlast;  //synthesis keep 
  wire         m_aixs_tready;  //synthesis keep 
  
  wire [ 95:0] m_aixs_tdata_96;  //synthesis keep 


  wire         awb_O_tlast;  //synthesis keep 
  wire         awb_O_tuser;  //synthesis keep 
  wire [ 95:0] awb_O_tdata;  //synthesis keep 
  wire         awb_O_tvalid;  //synthesis keep 
  wire         awb_O_tready;  //synthesis keep 

  wire         awb_O_tuser_128;  //synthesis keep 
  wire         awb_O_tvalid_128;  //synthesis keep 
  wire [127:0] awb_O_tdata_128;  //synthesis keep 

  // ---- edge detection stage (ported from lab_ex2_edge) ----
  wire         edge_O_tlast;   //synthesis keep
  wire         edge_O_tuser;   //synthesis keep
  wire [ 95:0] edge_O_tdata;   //synthesis keep
  wire         edge_O_tvalid;  //synthesis keep
  wire         edge_O_tready;  //synthesis keep

  // ---- À©Õ¹1: µÍÕÕ¶ÈÔöÇ¿ (Gamma 0.7 + highlight roll-off) ----
  wire         gam_O_tlast;    //synthesis keep
  wire         gam_O_tuser;    //synthesis keep
  wire [ 95:0] gam_O_tdata;    //synthesis keep
  wire         gam_O_tvalid;   //synthesis keep


  // ---- VIV mode: vivid / realistic colour ----
  wire         viv_O_tlast;    //synthesis keep
  wire         viv_O_tuser;    //synthesis keep
  wire [ 95:0] viv_O_tdata;    //synthesis keep
  wire         viv_O_tvalid;   //synthesis keep
  // ---- Êä³öÄ£Ê½Ñ¡ÔñºóµÄÊı¾İ ----
  // ---- white balance trim stage (fixes the red-deficient AWB output) ----
  wire         wb_O_tlast;     //synthesis keep
  wire         wb_O_tuser;     //synthesis keep
  wire [ 95:0] wb_O_tdata;     //synthesis keep
  wire         wb_O_tvalid;    //synthesis keep

  wire [ 95:0] pack_tdata;     //synthesis keep
  wire         pack_tlast;     //synthesis keep
  wire         pack_tuser;     //synthesis keep
  wire         pack_tvalid;    //synthesis keep

  // ---- Ä£Ê½ĞÅºÅ¿çÊ±ÖÓÓòÍ¬²½£¨°´¼üÔÚ 24MHz Óò£¬±¾Ä£¿éÔÚ CSI Ê±ÖÓÓò£©----
  reg  [2:0] S_mode_sync1;
  reg  [2:0] S_mode_sync2;

  always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
      if(!I_rst_n) begin
          S_mode_sync1 <= 3'd0;
          S_mode_sync2 <= 3'd0;
      end else begin
          S_mode_sync1 <= I_video_mode;
          S_mode_sync2 <= S_mode_sync1;
      end
  end

  assign awb_O_tready  = edge_O_tready;
  assign edge_O_tready = O_tready;

  assign O_tdata  = awb_O_tdata_128;
  assign O_tlast  = awb_O_tlast    ;
  assign O_tuser  = awb_O_tuser_128    ;
  assign O_tvalid = awb_O_tvalid_128   ;
  
  //assign m_aixs_tready = O_tready;
  //assign O_tdata  = m_aixs_tdata;
  //assign O_tlast  = m_aixs_tlast    ;
  //assign O_tuser  = m_aixs_tuser    ;
  //assign O_tvalid = m_aixs_tvalid   ;
 
 
// ===================== black level (OB) removal ============================
// The vendor demosaic subtracts no black level at all, so the RAW10 pedestal
// (typically 64 codes) plus the per-channel dark-current offsets run straight
// into the colour pipeline.  That is exactly what shows up as a colour cast
// that is constant from the shadows to the highlights.
//
// One value per Bayer phase, BGGR order: on an even row the even columns are B
// and the odd columns G; on an odd row the even columns are G and the odd ones
// R.  All zero means pass-through, and synthesis then drops the logic.
// Fill them in from a black frame (lens covered): OB = the measured mean.
localparam [9:0] OB_B  = 10'd0;
localparam [9:0] OB_G0 = 10'd0;   // green on a B row
localparam [9:0] OB_G1 = 10'd0;   // green on an R row
localparam [9:0] OB_R  = 10'd0;

reg S_row_odd;
always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
    if (!I_rst_n)                     S_row_odd <= 1'b0;
    else if (I_tvalid && I_tlast)     S_row_odd <= ~S_row_odd;
end

function [9:0] f_ob;
    input [9:0] v;
    input [9:0] ob;
    begin
        f_ob = (v > ob) ? (v - ob) : 10'd0;
    end
endfunction

wire [9:0] S_ob_even = S_row_odd ? OB_G1 : OB_B;    // even x of this row
wire [9:0] S_ob_odd  = S_row_odd ? OB_R  : OB_G0;   // odd  x of this row

wire [39:0] S_raw_ob = {
    f_ob(I_tdata[39:30], S_ob_even), f_ob(I_tdata[29:20], S_ob_odd),
    f_ob(I_tdata[19:10], S_ob_even), f_ob(I_tdata[ 9: 0], S_ob_odd)
};
demosaic #(
    .IMG_HEIGHT          (720 ),  // å›¾åƒé«˜åº¦
    .IMG_WIDTH           (1280),  // å›¾åƒå®½åº¦
    .data_complete_delay (50  ),
    .BAYER_MODE          ("BGGR")
)
u_demosaic
(
    .I_clk   			(axi4s_video_aclk)	,   // æ—¶é’Ÿä¿¡å·
    .I_rst_n 			(I_rst_n)	,   // å¤ä½ä¿¡å·ï¼Œä½æœ‰æ•ˆ
    .axi4s_video_tdata (S_raw_ob)	,  // AXI4-Streamè§†é?‘æ•°æ?
    .axi4s_video_tdest 	(I_tdest)	,
    .axi4s_video_tlast 	(I_tlast)	,  // è¡Œç»“æŸä¿¡å?
    .axi4s_video_tvalid	(I_tvalid)	,  // æ•°æ®æœ‰æ•ˆä¿¡å·
    .axi4s_video_tuser 	(I_tuser)	,  // å¸§å¼€å§‹ä¿¡å?
    .axi4s_video_tready	(I_tready)	,  // ä»æ¨¡å—å‡†å¤‡å¥½æ¥å—æ•°æ®
    .O_tlast  			(m_aixs_tlast)	,  // è¾“å‡ºè¡Œç»“æŸä¿¡å?
    .O_tuser  			(m_aixs_tuser)	,  // è¾“å‡ºå¸§å¼€å§‹ä¿¡å?
    .O_tdata  			(m_aixs_tdata)	,  // è¾“å‡ºæ•°æ®
    .O_tvalid 			(m_aixs_tvalid)	,  // è¾“å‡ºæ•°æ®æœ‰æ•ˆä¿¡å·
    .O_tready   		(m_aixs_tready)	   // è¾“å‡ºæ•°æ®å‡†å?‡å¥½ä¿¡å??
);
 
data128_96 u_data128_96 (
    .I_tdata(m_aixs_tdata),
    .O_tdata(m_aixs_tdata_96)
);

awb #(
    .IMG_HEIGHT(720 ),
    .IMG_WIDTH (1280)
) u_awb (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_tlast (m_aixs_tlast),
    .I_tuser (m_aixs_tuser),
    .I_tdata (m_aixs_tdata_96),
    .I_tvalid(m_aixs_tvalid),
    .I_tready(m_aixs_tready),
    .O_tlast (awb_O_tlast ),
    .O_tuser (awb_O_tuser ),
    .O_tdata (awb_O_tdata ),
    .O_tvalid(awb_O_tvalid),
    .O_tready(awb_O_tready)
);

// ==================== À©Õ¹ÒªÇó1£ºµÍÕÕ¶ÈÔöÇ¿£¨Gamma 0.7 + highlight roll-off£©====================
// °Ñ awb Êä³öµÄ 96bit RGB ÌáÁÁ°µ²¿£¨gamma = x^0.7£©£¬ÔÙËÍÈ¥×ö±ßÔµ¼ì²â¡£
// Ğ§¹û£º°µ¹â³¡¾°ÏÂ¶¯Ì¬·¶Î§±»À­¿ª£¬±ßÔµ¼ì²âÄÜÌáÈ¡µ½¸ü¶àÂÖÀªÏ¸½Ú¡£
axis_gamma_rgb96 u_axis_gamma_rgb96 (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_tlast (wb_O_tlast  ),
    .I_tuser (wb_O_tuser  ),
    .I_tdata (wb_O_tdata  ),
    .I_tvalid(wb_O_tvalid ),
    .O_tlast (gam_O_tlast ),
    .O_tuser (gam_O_tuser ),
    .O_tdata (gam_O_tdata ),
    .O_tvalid(gam_O_tvalid)
);


// ==================== auto white balance (before the mode split) ====================
// Gray-world AWB: the block measures R/G/B itself and trims the R and B gains,
// so the picture is neutral under any lighting without a hand-tuned constant.
// EDG / ENH / RAW / VIV all benefit.
awb_gray_rgb96 u_awb_gray_rgb96 (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_tlast (awb_O_tlast ),
    .I_tuser (awb_O_tuser ),
    .I_tdata (awb_O_tdata ),
    .I_tvalid(awb_O_tvalid),
    .I_gain_r(cfg_gain_r  ),
    .I_gain_b(cfg_gain_b  ),
    .I_gain_g(cfg_gain_g  ),
    .I_off_r (cfg_off_r   ),
    .I_off_b (cfg_off_b   ),
    .O_tlast (wb_O_tlast  ),
    .O_tuser (wb_O_tuser  ),
    .O_tdata (wb_O_tdata  ),
    .O_tvalid(wb_O_tvalid )
);

// ==================== VIV mode: ENH + vivid colour ====================
// VIV sits ON TOP OF the ENH output: it takes the already low-light-lifted,
// highlight-rolled-off gamma frame and pushes chroma away from luma (x1.375).
// So VIV = ENH's brightness/tone + stronger colour.
wire S_viv_hi = (S_mode_sync2 == 3'd4);   // mode 4 = VIV+
axis_vivid_rgb96 u_axis_vivid_rgb96 (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_tlast (gam_O_tlast ),   // VIV is built ON TOP OF the ENH (gamma) output
    .I_tuser (gam_O_tuser ),
    .I_tdata (gam_O_tdata ),
    .I_tvalid(gam_O_tvalid),
    .I_hi    (S_viv_hi     ),   // 1 = VIV+ (mode 4), stronger chroma
    .O_tlast (viv_O_tlast ),
    .O_tuser (viv_O_tuser ),
    .O_tdata (viv_O_tdata ),
    .O_tvalid(viv_O_tvalid)
);
// ==================== »ù´¡ÒªÇó2£º±ßÔµ¼ì²â ====================
// ÊäÈë¸ÄÎª"ÔöÇ¿ºó"µÄ»­Ãæ£¬°µ¹âÏÂ±ßÔµ¸üÍêÕû¡£
// ---------------------------------------------------------------------------
// Edge detection: vendor module + hysteresis threshold (ported from ex2).
// Front end unchanged (pair averaging, |gx|+|gy|, two pixel thick lines),
// only a second lower threshold lets a weak edge survive when attached to a
// strong one.
// ---------------------------------------------------------------------------
edge_detect_hys_96 #(
    .IMG_WIDTH (1280),
    .IMG_HEIGHT(720),
    .EDGE_TH   (11'd110),     // strong threshold (vendor used 80)
    .EDGE_TH_LO(11'd40),      // weak threshold (hysteresis)
    .EDGE_TH_INK(11'd320)     // stricter threshold for the cartoon ink
) u_edge_detect_96 (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_tlast (gam_O_tlast ),
    .I_tuser (gam_O_tuser ),
    .I_tdata (gam_O_tdata ),
    .I_tvalid(gam_O_tvalid),
    .I_tready(awb_O_tready),
    .O_tlast (edge_O_tlast),
    .O_tuser (edge_O_tuser),
    .O_tdata (edge_O_tdata),
    .O_tvalid(edge_O_tvalid),
    .O_ink_tdata(ink_tdata),
    .O_tready(edge_O_tready)
);

// ---- mode mux output, then the sharpen stage ----
wire [95:0] mix_tdata;
wire        mix_tlast;
wire        mix_tuser;
wire        mix_tvalid;

// noise reduction runs BEFORE sharpening: you must remove the noise first,
// otherwise the sharpener amplifies it.
wire [95:0] nr_tdata;
wire        nr_tlast;
wire        nr_tuser;
wire        nr_tvalid;

// Horizontal unsharp mask on the muxed picture.  There is no sharpening
// anywhere else in the pipeline, which is why the picture looked soft: the
// bilinear demosaic and a 720p sensor give you exactly what the lens does.
axis_nr_rgb96 #(.NB(320)) u_axis_nr_rgb96 (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_tlast (mix_tlast ),
    .I_tuser (mix_tuser ),
    .I_tvalid(mix_tvalid),
    .I_tdata (mix_tdata ),
    .I_str   (cfg_nr     ),
    .O_tlast (nr_tlast  ),
    .O_tuser (nr_tuser  ),
    .O_tvalid(nr_tvalid ),
    .O_tdata (nr_tdata  )
);

axis_sharpen_rgb96 u_axis_sharpen_rgb96 (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_tlast (nr_tlast  ),
    .I_tuser (nr_tuser  ),
    .I_tvalid(nr_tvalid ),
    .I_tdata (nr_tdata  ),
    .I_sh    (cfg_sharp  ),
    .O_tlast (pack_tlast ),
    .O_tuser (pack_tuser ),
    .O_tvalid(pack_tvalid),
    .O_tdata (pack_tdata )
);

// ==================== Êä³öÄ£Ê½Ñ¡Ôñ ====================
//  VIDEO_MODE = 0 : ±ßÔµ¼ì²â£¨»ù´¡ÒªÇó 2£©
//  VIDEO_MODE = 1 : µÍÕÕ¶ÈÔöÇ¿²ÊÍ¼£¨À©Õ¹ÒªÇó 1£©
//  VIDEO_MODE = 2 : Ô­Ê¼²ÊÍ¼£¨¶ÔÕÕÓÃ£©
//  VIDEO_MODE = 3 : ÏÊÑŞĞ´Êµ£¨= ENH µÄ gamma+¸ß¹â¹ö½µ£¬ÔÙµş±¥ºÍ¶È x1.375£©
// ---- cartoon mode (extension 1): colour image + black edge outlines ----
// The official effect picture keeps all 256 levels (its colour count is even
// higher than the input), so QUANT_LSB = 0 here; set it to 2 for a slight
// posterise.
wire [95:0] ink_tdata;    // binary edge map at EDGE_TH_INK (cartoon only)
wire [95:0] cart_tdata;
wire        cart_tlast, cart_tuser, cart_tvalid;

axis_cartoon_rgb96 #(.QUANT_LSB(0), .DZ_T1(8'd12), .DZ_T2(8'd48)) u_axis_cartoon (
    .I_clk       (axi4s_video_aclk),
    .I_rst_n     (I_rst_n         ),
    .I_col_tdata (gam_O_tdata     ),
    .I_edge_tdata(ink_tdata      ),
    .I_tlast     (gam_O_tlast     ),
    .I_tuser     (gam_O_tuser     ),
    .I_tvalid    (gam_O_tvalid    ),
    .O_tdata     (cart_tdata      ),
    .O_tlast     (cart_tlast      ),
    .O_tuser     (cart_tuser      ),
    .O_tvalid    (cart_tvalid     )
);

assign mix_tdata   = (S_mode_sync2 == 2'd0) ? edge_O_tdata  :
                     (S_mode_sync2 == 2'd1) ? gam_O_tdata   :
                     (S_mode_sync2 == 2'd3) ? cart_tdata    : wb_O_tdata;
assign mix_tlast   = (S_mode_sync2 == 2'd0) ? edge_O_tlast  :
                     (S_mode_sync2 == 2'd1) ? gam_O_tlast   :
                     (S_mode_sync2 == 2'd3) ? cart_tlast    : wb_O_tlast;
assign mix_tuser   = (S_mode_sync2 == 2'd0) ? edge_O_tuser  :
                     (S_mode_sync2 == 2'd1) ? gam_O_tuser   :
                     (S_mode_sync2 == 2'd3) ? cart_tuser    : wb_O_tuser;
assign mix_tvalid  = (S_mode_sync2 == 2'd0) ? edge_O_tvalid :
                     (S_mode_sync2 == 2'd1) ? gam_O_tvalid  :
                     (S_mode_sync2 == 2'd3) ? cart_tvalid   : wb_O_tvalid;

data_96bit_to_128bit u_data_96bit_to_128bit(
        .I_clk              ( axi4s_video_aclk  ),
        .I_rst_n            ( I_rst_n           ),
	
        .I_96b_frame_start  ( pack_tuser       ),
        .I_96b_valid        ( pack_tvalid      ),
        .I_96b_data         ( pack_tdata       ),
	
        .O_128b_frame_start ( awb_O_tuser_128  	),
        .O_128b_valid       ( awb_O_tvalid_128 	),
        .O_128b_data        ( awb_O_tdata_128  	)
    );

// ==================== UART thumbnail (so the assistant can see the picture) ====================
// Downsamples the displayed frame to 320x90 and streams it out over UART to the
// onboard FT2232 channel B (COM3 on the PC). Pin H1 = net FPGA_TXD.
// Set THUMB_EN to 0 to remove it.
localparam THUMB_EN = 1;

// ==================== live tuning over UART (J1 / FPGA_RXD) ====================
// The JTAG and the serial port share one FT2232: channel A is JTAG, channel B
// carries H1 (FPGA_TXD, thumbnail out) and J1 (FPGA_RXD, commands in).
// Sending A5 5A <cmd> <hi> <lo> from the PC changes these registers live, so
// white balance and sharpness can be tuned without rebuilding the bitstream.
//   cmd 01 -> R gain (11 bit, default 304 = 1.1875x)
//   cmd 02 -> B gain (11 bit, default 256 = 1.0000x)
//   cmd 03 -> sharpen strength (0=off 1=1/2 2=1/4 3=1/8)
//   cmd 04 -> noise reduction  (0=off 1=light 2=medium 3=strong)
wire [10:0] cfg_gain_r;
wire [10:0] cfg_gain_b;
wire [10:0] cfg_gain_g;
wire [7:0]  cfg_off_r;
wire [7:0]  cfg_off_b;
wire [1:0]  cfg_sharp;
wire [1:0]  cfg_nr;

uart_cfg_rx #(.DIV(112)) u_uart_cfg_rx (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_rxd   (I_uart_rxd),
    .O_gain_r(cfg_gain_r),
    .O_gain_b(cfg_gain_b),
    .O_gain_g(cfg_gain_g  ),
    .O_off_r (cfg_off_r   ),
    .O_off_b (cfg_off_b   ),
    .O_sharp (cfg_sharp ),
    .O_nr    (cfg_nr    ),
    .O_win_y (cfg_win_y )
);
wire thumb_txd;
wire [11:0] cfg_win_y;
uart_thumb_tx #(.CLK_HZ(103520000), .BAUD(921600), .COLS(320), .ROWS(90)) u_uart_thumb_tx (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_tvalid(pack_tvalid),
    .I_tlast (pack_tlast ),
    .I_tuser (pack_tuser ),
    .I_tdata (pack_tdata),
    .I_win_y (cfg_win_y ),
    .O_txd   (thumb_txd)
);
assign O_uart_txd = THUMB_EN ? thumb_txd : 1'b1;
// ---- extension 2: monitor tap, pure wiring, no handshake ----
// tap the FINAL stream, not the AWB output: gamma and the vivid/sharpen stages
// change brightness and saturation a lot, so detecting on the pre-gamma signal
// meant the detector never saw what the monitor shows (a pale object on screen
// can be an almost grey blob at the AWB tap).
assign O_mon_tdata  = pack_tdata;
assign O_mon_tuser  = pack_tuser;
assign O_mon_tlast  = pack_tlast;
assign O_mon_tvalid = pack_tvalid;

// ---------------- auto exposure meter ----------------
// Mean of the green channel over one frame of the FINAL stream, i.e. the
// picture the monitor shows.  Only one pixel per beat is sampled, and the
// divisor is a shift, so the measurement costs one accumulator.
reg  [24:0] S_ae_sum;
// The divisor was 113360 in the belief that 117440 beats are accumulated per
// frame.  On the board the loop settled with a true mean of 180 while it
// believed it was at the 96 target, i.e. it only ever accumulated about half
// of the beats.  Shifting one bit less doubles the reported value, so the
// loop now drives the real mean to ~90 instead of leaving it at 180.
wire [8:0]  W_ae_norm = S_ae_sum[24:16] + S_ae_sum[24:19] + S_ae_sum[24:21];  // /56700
reg  [7:0]  S_ae_mean_r;
reg  [7:0]  S_ae_hold;   // widens the frame strobe: 255 cycles of the video
                         // clock is ~2.5 us, about 60 periods of the 24 MHz
                         // auto-exposure clock, so the strobe cannot be missed
always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_ae_sum    <= 25'd0;
        S_ae_mean_r <= 8'd0;
        S_ae_hold   <= 8'd0;
    end
    else begin
        if (pack_tvalid && pack_tuser) begin
            S_ae_mean_r <= (W_ae_norm > 8'd255) ? 8'd255 : W_ae_norm;
            S_ae_sum    <= 25'd0;
            S_ae_hold   <= 8'd255;
        end
        else begin
            if (S_ae_hold != 8'd0) S_ae_hold <= S_ae_hold - 8'd1;
            if (pack_tvalid)       S_ae_sum  <= S_ae_sum + pack_tdata[87:80];
        end
    end
end
assign O_ae_mean = S_ae_mean_r;
// held high for ~2.5 us on purpose: a one-cycle pulse is usually missed by the
// 24 MHz auto-exposure clock, which made the loop update at random
assign O_ae_done = (S_ae_hold != 8'd0);


// ---------------- Ethernet video transmit ----------------
wire [7:0] eth_gmii_txd;
wire       eth_gmii_tx_en;
wire       eth_frame_done;

udp_video_tx #(
    .DEC      (1),
    .WIDTH    (1280),
    .SEG_PX   (320),
    .LINES    (720),
    // 640 instead of 1023: a line is only sent when the FIFO is below 640
    // beats, which leaves room for one whole line (320 beats).  Without this
    // the FIFO could fill up mid-line and individual beats were dropped, so the
    // received picture was torn (measured: self-correlation 0.95 at +320 px).
    // Dropping whole lines instead keeps every received segment aligned.
    .DEC_DROP (640),
    .MAC_DEST (48'hFFFFFFFFFFFF),
    .MAC_SRC  (48'h0123456789AB),
    .IP_SRC   ({8'd192, 8'd168, 8'd137, 8'd2}),
    .IP_DST   ({8'd192, 8'd168, 8'd137, 8'd1}),
    .UDP_SPORT(16'd6002),
    .UDP_DPORT(16'd6001)
) u_udp_video_tx (
    .vclk         (axi4s_video_aclk),
    .vrst         (~I_rst_n),
    .s_tvalid     (pack_tvalid),
    .s_tlast      (pack_tlast),
    .s_tuser      (pack_tuser),
    .s_tdata      (pack_tdata),
    .s_tready     (),
    .clk          (I_eth_clk_125),
    .rst          (I_eth_rst),
    .o_txd        (eth_gmii_txd),
    .o_tx_en      (eth_gmii_tx_en),
    .o_frame_done (eth_frame_done)
);

rgmii_tx_phy u_rgmii_tx_phy (
    .clk         (I_eth_clk_125),
    .clk90       (I_eth_clk_125_90),
    .rst         (I_eth_rst),
    .gmii_txd    (eth_gmii_txd),
    .gmii_tx_en  (eth_gmii_tx_en),
    .rgmii_txd   (O_eth_txd),
    .rgmii_tx_ctl(O_eth_tx_ctl),
    .rgmii_txc   (O_eth_txc)
);

// PHY reset: hold low for ~8 ms after configuration, then release.
// (Tying it high meant the PHY never saw a reset pulse.)
reg [19:0] phy_rst_cnt = 20'd0;
always @(posedge I_eth_clk_125)
    if (phy_rst_cnt != 20'hFFFFF) phy_rst_cnt <= phy_rst_cnt + 20'd1;
assign O_eth_phy_rst = (phy_rst_cnt == 20'hFFFFF);


//data96_128 u_data96_128 (
//    .I_tdata(awb_O_tdata),
//    .O_tdata(awb_O_tdata_128)
//);
	
endmodule


// Four-pixel RGB888 gamma stage.  The 16-segment curve approximates
// y = 255 * (x / 255)^0.7 for x <= 176, then a highlight roll-off that maps
// 255 down to 238 instead of 255.  Shadows and mid-tones keep the full
// x^0.7 lift (16->37, 64->97, 128->157), but the top of the range is
// compressed so saturated highlights are held as light grey with a visible
// gradient instead of turning into a flat white blob.  One pipeline cycle.
module axis_gamma_rgb96 (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    output reg         O_tlast,
    output reg         O_tuser,
    output reg  [95:0] O_tdata,
    output reg         O_tvalid
);

    function [7:0] gamma07;
        input [7:0] value;
        reg [7:0] base;
        reg [7:0] delta;
        reg [11:0] interpolation;
        begin
            case (value[7:4])
                4'h0: begin base = 8'd0;   delta = 8'd37; end
                4'h1: begin base = 8'd37;  delta = 8'd23; end
                4'h2: begin base = 8'd60;  delta = 8'd19; end
                4'h3: begin base = 8'd79;  delta = 8'd18; end
                4'h4: begin base = 8'd97;  delta = 8'd16; end
                4'h5: begin base = 8'd113; delta = 8'd16; end
                4'h6: begin base = 8'd129; delta = 8'd14; end
                4'h7: begin base = 8'd143; delta = 8'd14; end
                4'h8: begin base = 8'd157; delta = 8'd14; end
                4'h9: begin base = 8'd171; delta = 8'd13; end
                4'ha: begin base = 8'd184; delta = 8'd13; end
                4'hb: begin base = 8'd197; delta = 8'd8;  end
                4'hc: begin base = 8'd205; delta = 8'd9;  end
                4'hd: begin base = 8'd214; delta = 8'd8;  end
                4'he: begin base = 8'd222; delta = 8'd8;  end
                default: begin base = 8'd230; delta = 8'd8; end
            endcase

            interpolation = delta * value[3:0] + 8;
            // no white special case: the top segment now rolls off to 238
            gamma07 = base + (interpolation >> 4);
        end
    endfunction

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_tlast  <= 1'b0;
            O_tuser  <= 1'b0;
            O_tdata  <= 96'd0;
            O_tvalid <= 1'b0;
        end else begin
            O_tlast  <= I_tlast;
            O_tuser  <= I_tuser;
            O_tvalid <= I_tvalid;
            if (I_tvalid) begin
                O_tdata <= {
                    gamma07(I_tdata[95:88]), gamma07(I_tdata[87:80]), gamma07(I_tdata[79:72]),
                    gamma07(I_tdata[71:64]), gamma07(I_tdata[63:56]), gamma07(I_tdata[55:48]),
                    gamma07(I_tdata[47:40]), gamma07(I_tdata[39:32]), gamma07(I_tdata[31:24]),
                    gamma07(I_tdata[23:16]), gamma07(I_tdata[15:8]),  gamma07(I_tdata[7:0])
                };
            end else begin
                O_tdata <= 96'd0;
            end
        end
    end

endmodule


// Centre crop for the ISP's four-pixel-wide RGB888 stream.  Frame start is
// intentionally forwarded at the original frame boundary so video_in can
// reset its asynchronous FIFO before the first selected row arrives.
module axis_crop_rgb96 #(
    parameter integer IN_WIDTH   = 1792,
    parameter integer IN_HEIGHT  = 1080,
    parameter integer OUT_WIDTH  = 1600,
    parameter integer OUT_HEIGHT = 900,
    parameter integer X_START    = 96,
    parameter integer Y_START    = 90
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    output wire        O_tlast,
    output wire        O_tuser,
    output wire [95:0] O_tdata,
    output wire        O_tvalid
);

    localparam integer X_START_BEAT = X_START / 4;
    localparam integer OUT_BEATS    = OUT_WIDTH / 4;
    localparam integer X_END_BEAT   = X_START_BEAT + OUT_BEATS;

    reg [9:0]  S_hcnt;
    reg [10:0] S_vcnt;

    wire [9:0]  S_current_h = I_tuser ? 10'd0 : S_hcnt;
    wire [10:0] S_current_v = I_tuser ? 11'd0 : S_vcnt;
    wire S_inside = (S_current_h >= X_START_BEAT) &&
                    (S_current_h < X_END_BEAT) &&
                    (S_current_v >= Y_START) &&
                    (S_current_v < (Y_START + OUT_HEIGHT));

    assign O_tdata  = I_tdata;
    assign O_tvalid = I_tvalid && S_inside;
    assign O_tlast  = O_tvalid && (S_current_h == (X_END_BEAT - 1));
    assign O_tuser  = I_tuser;

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_hcnt <= 10'd0;
            S_vcnt <= 11'd0;
        end
        else if(I_tuser) begin
            S_hcnt <= (I_tvalid && !I_tlast) ? 10'd1 : 10'd0;
            S_vcnt <= (I_tvalid && I_tlast) ? 11'd1 : 11'd0;
        end
        else if(I_tvalid) begin
            if(I_tlast) begin
                S_hcnt <= 10'd0;
                S_vcnt <= (S_vcnt == IN_HEIGHT - 1) ? 11'd0 : S_vcnt + 1'b1;
            end
            else begin
                S_hcnt <= S_hcnt + 1'b1;
            end
        end
    end

endmodule

module axis_vivid_rgb96 (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    output reg         O_tlast,
    output reg         O_tuser,
    input  wire        I_hi,      // 1 = VIV+ extra saturation
    output reg  [95:0] O_tdata,
    output reg         O_tvalid
);

    // ------------------------------------------------------------------
    //  VIV = ENH + "camera look"
    //
    //  The input is the ENH frame (gamma 0.7 + highlight roll-off, and the
    //  auto white balance already applied upstream by awb_gray_rgb96).
    //
    //  Stage 1 : BT.601 integer luma, one per pixel
    //      Y = (77*R + 150*G + 29*B + 128) >> 8
    //
    //  Stage 2 : mid-tone lift + saturation
    //      Yb = Y + Y/4, capped at 246          (brighter, white point kept)
    //      C' = clamp( Yb + 1.375*(C - Y) )     1.375 = 1 + 1/4 + 1/8
    //
    //  Neutral pixels are untouched by construction: C == Y gives d == 0,
    //  so grey / white / black just get the lift and stay neutral.
    //
    //  Only stage 1 has multipliers (the luma), stage 2 is shifts and adds,
    //  so the 103 MHz MIPI byte clock path stays short.
    //
    //  TUNING
    //      too dark          -> f_lift : use  c + (c >> 1)   (x1.50)
    //      too bright / flat -> f_lift : use  c + (c >> 3)   (x1.125)
    //      highlights blown  -> f_lift : lower the 246 cap
    //      colour too strong -> f_sat  : drop the (d >>> 3) term (x1.25)
    //      colour too weak   -> f_sat  : use  d + (d >> 1)   (x1.50)
    // ------------------------------------------------------------------

    function [7:0] f_luma;
        input [7:0] r;
        input [7:0] g;
        input [7:0] b;
        reg   [16:0] s;
        begin
            s = (r * 16'd77) + (g * 16'd150) + (b * 16'd29) + 17'd128;
            f_luma = s[15:8];
        end
    endfunction

    //  The old lift was  c + c/4  clamped at 246.  Because the clamp is a hard
    //  ceiling, every input above 176 came out as exactly 246 - measured on a
    //  real frame that was 30% of all pixels sitting on a single gray level, and
    //  the resulting 246 luma then pushed R past 255 (16.3% of R pixels at 255
    //  against 1.0% of G), which is exactly what "bright areas go red" was.
    //  The closed-loop AE sets overall brightness now, so this stage only has to
    //  add colour: LIFT_SEL = 0 keeps yb == y and leaves highlights alone.
    parameter  [1:0] LIFT_SEL = 2'd0;   // 0 = no lift (default), 1 = old x1.25
    function [7:0] f_lift;
        input [7:0] c;
        reg   [8:0] t;
        begin
            t = {1'b0, c} + {2'b0, c[7:2]};
            if (LIFT_SEL == 2'd0)
                f_lift = c;
            else
                f_lift = (t > 9'd246) ? 8'd246 : t[7:0];
        end
    endfunction
    function [7:0] f_sat;
        input [7:0] c;
        input [7:0] y;
        input [7:0] yb;
        // I_hi is a module input, used directly below
        reg signed [ 9:0] d;
        reg signed [11:0] p;
        reg signed [12:0] o;
        begin
            d = $signed({1'b0, c}) - $signed({1'b0, y});
            if (I_hi) p = d + d + (d >>> 2);   // VIV+ (mode 4): x2.25
            else     p = d + (d >>> 1) + (d >>> 2);   // VIV (mode 3): x1.75
            o = $signed({1'b0, yb}) + p;
            if (o > 13'sd255)
                f_sat = 8'd255;
            else if (o < 13'sd0)
                f_sat = 8'd0;
            else
                f_sat = o[7:0];
        end
    endfunction

    wire [31:0] wy = { f_luma(I_tdata[95:88], I_tdata[87:80], I_tdata[79:72]),
                       f_luma(I_tdata[71:64], I_tdata[63:56], I_tdata[55:48]),
                       f_luma(I_tdata[47:40], I_tdata[39:32], I_tdata[31:24]),
                       f_luma(I_tdata[23:16], I_tdata[15: 8], I_tdata[ 7: 0]) };

    reg  [95:0] s1_pix;
    reg  [31:0] s1_y;
    reg         s1_tlast;
    reg         s1_tuser;
    reg         s1_tvalid;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            s1_pix    <= 96'd0;
            s1_y      <= 32'd0;
            s1_tlast  <= 1'b0;
            s1_tuser  <= 1'b0;
            s1_tvalid <= 1'b0;
        end else begin
            s1_pix    <= I_tdata;
            s1_y      <= wy;
            s1_tlast  <= I_tlast;
            s1_tuser  <= I_tuser;
            s1_tvalid <= I_tvalid;
        end
    end

    wire [7:0] yb0 = f_lift(s1_y[31:24]);
    wire [7:0] yb1 = f_lift(s1_y[23:16]);
    wire [7:0] yb2 = f_lift(s1_y[15: 8]);
    wire [7:0] yb3 = f_lift(s1_y[ 7: 0]);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_tlast  <= 1'b0;
            O_tuser  <= 1'b0;
            O_tdata  <= 96'd0;
            O_tvalid <= 1'b0;
        end else begin
            O_tlast  <= s1_tlast;
            O_tuser  <= s1_tuser;
            O_tvalid <= s1_tvalid;
            if (s1_tvalid) begin
                O_tdata <= {
                    f_sat(s1_pix[95:88], s1_y[31:24], yb0),
                    f_sat(s1_pix[87:80], s1_y[31:24], yb0),
                    f_sat(s1_pix[79:72], s1_y[31:24], yb0),
                    f_sat(s1_pix[71:64], s1_y[23:16], yb1),
                    f_sat(s1_pix[63:56], s1_y[23:16], yb1),
                    f_sat(s1_pix[55:48], s1_y[23:16], yb1),
                    f_sat(s1_pix[47:40], s1_y[15: 8], yb2),
                    f_sat(s1_pix[39:32], s1_y[15: 8], yb2),
                    f_sat(s1_pix[31:24], s1_y[15: 8], yb2),
                    f_sat(s1_pix[23:16], s1_y[ 7: 0], yb3),
                    f_sat(s1_pix[15: 8], s1_y[ 7: 0], yb3),
                    f_sat(s1_pix[ 7: 0], s1_y[ 7: 0], yb3)
                };
            end else begin
                O_tdata <= 96'd0;
            end
        end
    end

endmodule

// ###########################################################################
//  awb_gray_rgb96 -- °×Æ½ºâ¼¶¡£µ±Ç°ÓÃ¡¾¹Ì¶¨ÔöÒæ R x1.1875¡¿£¬×Ô¶¯Ä£Ê½Áô×Åµ«¹Ø±Õ
//
//  ±³¾°: awb.v ×Ô¼ºµÄÔöÒæ»ù±¾Ã»ÔÚ¹¤×÷£¨Ã¿Ö¡¸´Î»³É 1.0£¬divider µÄ done ²»´¥·¢£©£¬
//      ºìÍ¨µÀÖ»Ê£Ô¼ 0.56£¬»­ÃæÆ«Çà£¬ËùÒÔ±ØĞëÔÚ±¾¼¶²¹Ò»¸ö R ÔöÒæ¡£
//
//  ×ö·¨£¨»ÒÊÀ½ç + ÂıËÙ·´À¡£¬²»ÓÃ³ı·¨£©:
//      1) Ã¿Ö¡²»Í£µØÀÛ¼Ó R¡¢G¡¢B£¨Ö»È¡ 4 ¸öÏñËØÀïµÄµÚ 1 ¸ö£¬¹»ÓÃÇÒÊ¡Âß¼­£©
//         Ö»Í³¼Æ"Î´±»½Ø¶¥¡¢Ò²²»Ì«°µ"µÄÏñËØ£¬±ÜÃâ¸ß¹âºÍÔëÉùÎóµ¼
//      2) ÀÛ¼Óµ½ WIN_PIX ¸öÏñËØ¾Í°ÑÀÛ¼ÓÆ÷ÇåÁã£¬×öÒ»´ÎÅĞ¶¨:
//             sum_r Ã÷ÏÔĞ¡ÓÚ sum_g  ->  R ÔöÒæ +1 ²½
//             sum_r Ã÷ÏÔ´óÓÚ sum_g  ->  R ÔöÒæ -1 ²½
//             ÔÚ +-1.5% ËÀÇøÄÚ   ->  ²»¶¯£¨·ÀÖ¹À´»Ø¶¶£©
//         B Í¨µÀÍ¬Àí
//      3) ÔöÒæ¸ñÊ½ Q8£¨1.0 = 256£©£¬·¶Î§ÏŞÖÆÔÚ 0.5 ~ 3.0 ±¶
//
//      È«³ÌÃ»ÓĞ³ı·¨Æ÷£¬Ö»ÓĞ¼Ó·¨¡¢ÒÆÎ»ºÍ±È½Ï£»Ó¦ÓÃÔöÒæÊÇ 8x11 ³Ë·¨¡£
//
//  ÎÈ¶¨ĞÔ:
//      ËÀÇø + ÔöÒæÉÏÏÂÏŞ + Ã¿´°¿ÚÖ»¶¯ 1 ²½£¬ÊÕÁ²Âıµ«²»»áÕñµ´¡£
//      ´Ó 1.0 µ½ 1.75 ´óÔ¼ 190 ¸ö´°¿Ú£¬Ò»¸ö´°¿Ú 16384 ÏñËØ£¬
//      1280x720 Ò»Ö¡Ô¼ 92 ÍòÏñËØ -> Ã¿Ö¡ 56 ¸ö´°¿Ú -> Ô¼ 3~4 Ö¡ÊÕÁ²£¨¼¸Ê®ºÁÃë£©¡£
//
//  ÎªÊ²Ã´Ä¬ÈÏÊÇ¹Ì¶¨ÔöÒæ¶ø²»ÊÇ×Ô¶¯:
//      »ÒÊÀ½ç·¨¼ÙÉè»­ÃæÆ½¾ùÊÇÖĞ¼ä»Ò¡£Êµ²â³¡¾°ÀïÓĞ´óÃæ»ıÀ¶É«ÎïÌå
//      £¨À¶´°Á± / À¶ÊÕÄÉÏä£©£¬×Ô¶¯Ëã·¨»áÎóÅĞ³É¡°À¶Ì«¶à¡±£¬Ò»Â·¼Óºìµ½ 1.77£¬
//      »­Ãæ·´¶ø·¢ºì¡£ÈË¹¤Ä¿ÊÓÈ·ÈÏ R x1.1875 ¸ü×¼£¬¹ÊÒÔ´ËÎª×¼¡£
//      ÁíÍâÊÖ»ú·­ÅÄÏÔÊ¾Æ÷±¾ÉíÓĞÉ«²î£¬²»ÄÜÓÃÀ´·´ÍÆ×¼È·ÔöÒæ¡£
//
//  ÏëÈÃ°å×Ó×Ô¼ºÑ§£¨»»´¿»Ò³¡¾°²ÅºÃÓÃ£©:
//      °Ñ AWB_ADAPTIVE ¸Ä³É 1¡£
// ###########################################################################
module awb_gray_rgb96 (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    input  wire [10:0] I_gain_r,   // UART ÔÚÏß¿ÉĞ´£¬0 = ÓÃ¹Ì¶¨Ä¬ÈÏÖµ
    input  wire [10:0] I_gain_b,
    input  wire [10:0] I_gain_g,   // green trim, lets R be corrected without clipping
    input  wire [7:0]  I_off_r,    // additive red lift
    input  wire [7:0]  I_off_b,    // additive blue cut
    output reg         O_tlast,
    output reg         O_tuser,
    output reg  [95:0] O_tdata,
    output reg         O_tvalid
);

    //  adaptive loop is always on now; FIX_* are only the starting point
    localparam [10:0] FIX_R        = 11'd247;    // red gain   Q8 (0.96x), the ENH-stage value
    localparam [10:0] FIX_B        = 11'd310;    // blue gain  Q8 (1.21x), the ENH-stage value
    localparam [10:0] FIX_G        = 11'd256;    // green gain Q8 (1.00x, reference)
    localparam [7:0]  FIX_OFF_R    = 8'd0;      // red lift
    localparam [7:0]  FIX_OFF_B    = 8'd0;      // blue cut

    localparam [10:0] G_MIN        = 11'd192;    // 0.75x (adaptive range)
    localparam [10:0] G_MAX        = 11'd448;    // 1.75x (adaptive range)
    localparam [15:0] WIN_PIX      = 16'd16384;  // Ò»¸öÍ³¼Æ´°¿ÚµÄÏñËØÊı

    // ---- ÔöÒæ¼Ä´æÆ÷£¨Q8£©------------------------------------------------
    reg [10:0] gain_r;
    reg [10:0] gain_b;
    reg [10:0] gain_g;
    reg [7:0]  off_r;
    reg [7:0]  off_b;

    // ---- ÀÛ¼ÓÆ÷ ---------------------------------------------------------
    // FIXED GAINS.  The adaptive statistics that lived here never converged on
    // the board: it sat still for 12 seconds while the picture needed a 14%
    // correction.  It also pushed the design from 95% to 97% of the slice
    // budget, which is where the DDR -> HDMI readback started losing the red
    // channel (screen measured R 25 against G 225 while the pre-DDR capture was
    // neutral).  A loop that does not converge is worse than no loop, so the
    // gains are fixed and were tuned on the board: R=263 gives R-G +2.2 and
    // B-G -1.9 against a room whose white ceiling measures R-G -2.0 / B-G -3.0.
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            gain_r <= FIX_R;
            gain_b <= FIX_B;
            gain_g <= FIX_G;
            off_r  <= FIX_OFF_R;
            off_b  <= FIX_OFF_B;
        end else begin
            gain_r <= (I_gain_r == 11'd0) ? FIX_R : I_gain_r;
            gain_b <= (I_gain_b == 11'd0) ? FIX_B : I_gain_b;
            gain_g <= (I_gain_g == 11'd0) ? FIX_G : I_gain_g;
            if (I_off_r != 8'd0) off_r <= I_off_r;
            if (I_off_b != 8'd0) off_b <= I_off_b;
        end
    end

    // ---- ???? -------------------------------------------------------
    // Per-channel additive trim, applied BEFORE the gain.
    parameter  [8:0] OFF_R_ADD = 9'd0;       // spare hooks, kept at 0
    parameter  [8:0] OFF_B_SUB = 9'd0;
    function [7:0] f_apply;
        input [7:0]  c;
        input [10:0] g;
        input [7:0]  add;       // amount added   (0 = none)
        input [7:0]  sub;       // amount removed (0 = none)
        reg   [8:0]  v;
        reg   [19:0] p;
        begin
            v = {1'b0, c} + add;
            if (v > 9'd255) v = 9'd255;
            if (v > sub) v = v - sub; else v = 9'd0;
            p = v * g;
            p = p >> 8;
            f_apply = (p > 20'd255) ? 8'd255 : p[7:0];
        end
    endfunction

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_tlast  <= 1'b0;
            O_tuser  <= 1'b0;
            O_tdata  <= 96'd0;
            O_tvalid <= 1'b0;
        end else begin
            O_tlast  <= I_tlast;
            O_tuser  <= I_tuser;
            O_tvalid <= I_tvalid;
            if (I_tvalid) begin
                O_tdata <= {
                    f_apply(I_tdata[95:88], gain_r, off_r, 8'd0), f_apply(I_tdata[87:80], gain_g, 8'd0, 8'd0), f_apply(I_tdata[79:72], gain_b, 8'd0, off_b),
                    f_apply(I_tdata[71:64], gain_r, off_r, 8'd0), f_apply(I_tdata[63:56], gain_g, 8'd0, 8'd0), f_apply(I_tdata[55:48], gain_b, 8'd0, off_b),
                    f_apply(I_tdata[47:40], gain_r, off_r, 8'd0), f_apply(I_tdata[39:32], gain_g, 8'd0, 8'd0), f_apply(I_tdata[31:24], gain_b, 8'd0, off_b),
                    f_apply(I_tdata[23:16], gain_r, off_r, 8'd0), f_apply(I_tdata[15: 8], gain_g, 8'd0, 8'd0), f_apply(I_tdata[ 7: 0], gain_b, 8'd0, off_b)
                };
            end else begin
                O_tdata <= 96'd0;
            end
        end
    end

endmodule


// ###########################################################################
//  axis_sharpen_rgb96 -- horizontal unsharp mask, 4 pixels per beat
//
//  Èñ»¯¹«Ê½£¨unsharp mask£©£º
//      avg = (left + right) / 2
//      out = c + (c - avg) >> SHARP_SH        I_sh=1 -> Ç¿¶È 0.5
//  ½á¹ûÇ¯Î»µ½ 0..255¡£
//
//  ÎªÊ²Ã´Ö»×öË®Æ½·½Ïò£ºÊúÖ±·½ÏòÈñ»¯ĞèÒªÁ½¸öÕûĞĞ»º´æ£¨1280x24bit x2£©£¬
//  »á¶àÕ¼ 6~8 ¸ö ERAM ¶øÇÒÒªÔÚ 103.5 MHz ÉÏÖØĞÂ×öÁ÷Ë®Ïß£¬·çÏÕ´ó¡£
//  Ë®Æ½ 3 ³éÍ·Ö»ĞèÒª¼Ä´æÆ÷£¬²»ĞèÒªĞĞ»º´æ£¬ÊÇ"¼¸ºõÃâ·Ñ"µÄÇåÎú¶ÈÌáÉı¡£
//  ÊúÖ±·½ÏòµÄ±ßÔµÈÔÈ»±£³ÖÔ­Ñù£¬ÊÓ¾õÉÏ»­Ãæ»áÃ÷ÏÔ¸ü"Êµ"¡£
//
//  ÊµÏÖÒªµã£º
//   * Ò»ÅÄ 96bit = 4 ¸öÏñËØ£¬ËùÒÔ left/right ÁÚ¾ÓÔÚÅÄÄÚ¾ÍÓĞ£»
//     ¿çÅÄµÄÁÚ¾ÓÓÃ 2 ¼¶¼Ä´æÆ÷Á´¸ø³ö prev / next Á½ÅÄ¡£
//     È¡ÏÖÔÚµÄ beat µÄ 4 ¸öÏñËØ¼ÓÉÏ prev µÄµÚ 3 ¸öÏñËØ¡¢next µÄµÚ 0 ¸öÏñËØ£¬
//     ¾ÍÄÜ°ÑÊ×Î²Á½¸öÏñËØµÄÈı³éÍ·²¹Æë¡£
//   * ĞĞÊ×/ĞĞÎ²²»ÌØÊâ´¦Àí£º×óÁÚ¾ÓÈ¡ÉÏÒ»ĞĞ×îºóÒ»¸öÏñËØ¡¢ÓÒÁÚ¾ÓÈ¡ÏÂÒ»ĞĞµÚÒ»¸ö£¬
//     Ã¿ĞĞ×î¶à 1 ¸öÏñËØµÄ±ß½çÎó²î£¬¿´²»³öÀ´£¬µ«Ê¡µôÁËĞĞ¼ÆÊıÆ÷¡£
//   * ÑÓ³Ù 2 ÅÄ£¬tlast/tuser/tvalid ÓÃÍ¬ÑùµÄ 2 ¼¶ÑÓ³Ù¶ÔÆë¡£
// ###########################################################################
module axis_sharpen_rgb96 (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire        I_tvalid,
    input  wire [95:0] I_tdata,
    input  wire [1:0]  I_sh,      // 0=Èñ»¯¹Ø 1=1/2 2=1/4 3=1/8 (UART ÔÚÏß¿ÉĞ´)
    output reg         O_tlast,
    output reg         O_tuser,
    output reg         O_tvalid,
    output reg  [95:0] O_tdata
);

    // p = previous beat, c = current beat, n = next beat
    reg [95:0] b0, b1, b2;
    reg        t1, t2, u1, u2, v1, v2;

    wire [23:0] n0 = b0[95:72];
    wire [23:0] c0 = b1[95:72];
    wire [23:0] c1 = b1[71:48];
    wire [23:0] c2 = b1[47:24];
    wire [23:0] c3 = b1[23: 0];
    wire [23:0] p3 = b2[23: 0];

    function [7:0] shrp;
        input [7:0] lv;
        input [7:0] cv;
        input [7:0] rv;
        reg  [8:0] avg;
        reg signed [11:0] t;
        reg signed [11:0] d;
        begin
            avg = ({1'b0, lv} + {1'b0, rv}) >> 1;
            d   = $signed({1'b0, cv}) - $signed({1'b0, avg});
            case (I_sh)
            // gain 0 / 0.5 / 1.0 / 1.5
            2'd0:    t = $signed({1'b0, cv});
            2'd1:    t = $signed({1'b0, cv}) + (d >>> 1);
            2'd2:    t = $signed({1'b0, cv}) + d;
            default: t = $signed({1'b0, cv}) + d + (d >>> 1);
            endcase
            if (t < 12'sd0)          shrp = 8'd0;
            else if (t > 12'sd255)   shrp = 8'd255;
            else                     shrp = t[7:0];
        end
    endfunction

    wire [23:0] o0 = { shrp(p3[23:16], c0[23:16], c1[23:16]),
                       shrp(p3[15: 8], c0[15: 8], c1[15: 8]),
                       shrp(p3[ 7: 0], c0[ 7: 0], c1[ 7: 0]) };
    wire [23:0] o1 = { shrp(c0[23:16], c1[23:16], c2[23:16]),
                       shrp(c0[15: 8], c1[15: 8], c2[15: 8]),
                       shrp(c0[ 7: 0], c1[ 7: 0], c2[ 7: 0]) };
    wire [23:0] o2 = { shrp(c1[23:16], c2[23:16], c3[23:16]),
                       shrp(c1[15: 8], c2[15: 8], c3[15: 8]),
                       shrp(c1[ 7: 0], c2[ 7: 0], c3[ 7: 0]) };
    wire [23:0] o3 = { shrp(c2[23:16], c3[23:16], n0[23:16]),
                       shrp(c2[15: 8], c3[15: 8], n0[15: 8]),
                       shrp(c2[ 7: 0], c3[ 7: 0], n0[ 7: 0]) };

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            b0 <= 96'd0; b1 <= 96'd0; b2 <= 96'd0;
            t1 <= 1'b0; t2 <= 1'b0;
            u1 <= 1'b0; u2 <= 1'b0;
            v1 <= 1'b0; v2 <= 1'b0;
            O_tlast <= 1'b0; O_tuser <= 1'b0; O_tvalid <= 1'b0; O_tdata <= 96'd0;
        end else begin
            b0 <= I_tdata;
            b1 <= b0;
            b2 <= b1;

            t1 <= I_tlast;  t2 <= t1;
            u1 <= I_tuser;  u2 <= u1;
            v1 <= I_tvalid; v2 <= v1;

            O_tdata  <= {o0, o1, o2, o3};
            O_tlast  <= t2;
            O_tuser  <= u2;
            O_tvalid <= v2;
        end
    end

endmodule
// ###########################################################################
//  uart_thumb_tx -- send a thumbnail of the live picture to the PC over UART
//
//  Ä¿µÄ£ºÈÃÖúÊÖÄÜ"¿´¼û"Êµ¼Ê»­Ãæ£¬ÓÃÀ´ÅĞ¶ÏÇåÎú¶È / ÁÁ¶È / °×Æ½ºâ£¬
//        ²»ÓÃÔÙ¿¿ÊÖ»ú·­ÅÄÏÔÊ¾Æ÷£¨·­ÅÄ±¾ÉíÓĞÉ«²î¡¢Ò²»á°ÑÈñ¶ÈÅÄºı£©¡£
//
//  Ó²¼şÍ¨Â·£¨Ô­ÀíÍ¼ P01_FPGA_2£¬BANK21£¬3V3£©£º
//        IO_BE2P_21  ÇòºÅ H1  ÍøÂç FPGA_TXD  -> FT2232 B Í¨µÀ RXD -> COM3
//        IO_BE2N_21  ÇòºÅ J1  ÍøÂç FPGA_RXD  <- FT2232 B Í¨µÀ TXD
//        ±¾Ä£¿éÖ»ÓÃ H1 ·¢ËÍ£¬J1 ²»ÓÃ¡£
//
//  ---- Ö¡¸ñÊ½£¨921600 8N1£©----
//        Ã¿¸öÏñËØĞĞ·¢Ò»¸ö 3 ×Ö½ÚĞĞÍ· A5 5A <ĞĞºÅ>£¬½ô¸ú 960 ×Ö½Ú£¨320 ÏñËØ R,G,B£©
//        Ò»Ö¡ = 90 ĞĞ x (3 + 960) = 86670 ×Ö½Ú
//        ÎªÊ²Ã´ÒªÖğĞĞÖ¡Í·£ºÖ®Ç°ÕûÖ¡Ö»ÓĞÒ»¸öÖ¡Í·£¬Ò»µ©ÖĞ¼ä¶ªÁË/¶àÁË¼¸¸ö×Ö½Ú£¬
//        ºóÃæÕûÖ¡È«²¿´íÎ»£¬»­Ãæ¾ÍÊÇÒ»ÌõÌõ²ÊÉ«Ôëµã¡£ÖğĞĞÍ·µÄ»°£¬
//        ¼´Ê¹Ä³ĞĞ»µÁË£¬PC Ò²ÄÜ´ÓÏÂÒ»ĞĞÖØĞÂ¶ÔÆë£¬×î¶à»µÒ»ĞĞ¡£
//
//  ---- ´ø¿í ----
//        921600 bd ÊÇÕâ¿é°åÊµ²âÎ¨Ò»"Áã¶ª×Ö½Ú"µÄËÙÂÊ¡£
//        1.5 M / 2.4 M ¶¼»á¶ª×Ö½Ú£¨FTDI µÄÕûÊı·ÖÆµ + Windows ´®¿ÚÂ·¾¶£©£¬
//        ËùÒÔÄş¿ÉÂı£º86670 x 10 / 924286 = 938 ms/Ö¡£¬Ô¼ 1 fps¡£
//        ¿´¾²Ì¬»­Ãæ¹»ÓÃ£¬»»À´ÍêÈ«¿ÉĞÅµÄÊı¾İ¡£
//
//  ---- ²ÉÑù ----
//        x Ã¿ÅÄ +4£¨96bit = 4 ÏñËØ£©£¬y Ã¿ĞĞ +1¡£
//        COLS=320£ºÒ»ĞĞ 1280/4 = 320 ÅÄ£¬Ã¿ÅÄ = 1 ¸öÊä³öÏñËØ£¬
//                  Ã¿¸öÊä³öÏñËØ = 4 ¸öÕæÊµÏñËØµÄË®Æ½Æ½¾ù£¨Ñ¹Ôëµã£©¡£
//        ROWS=90 £ºy È¡ 0,8,16,... ¹² 90 ĞĞ£¨y[2:0]==0£©£¬ÊúÖ±µã²ÉÑù¡£
//
//  ---- ERAM ----
//        28800 x 24bit£¬Õ¼ 40 ¸ö ERAM20K£¨ÕûÆ¬ 108 ¸ö£©¡£
//
//  ---- ²È¹ıµÄ¿Ó ----
//   1) ·¢ËÍÒª½Ó½ü 1 s£¬ºá¿ç¼¸Ê®Ö¡¡£Ö»ÓÃ !sending ÃÅ¿Ø²ÉÑù»áÈÃ widx ²»ÇåÁã£¬
//      ²ÉÑùµãÔ½½ç²¢ºÍÉÏÒ»Ö¡»ìÔÚÒ»Æğ -> ºá´øÂÒÂë¡£ÏÖÔÚ tuser Ê±Ö»ÓĞ !sending
//      ²ÅÖÃ cap_on£¬·¢ËÍÆô¶¯Á¢¿ÌÇå cap_on¡£
//   2) ¼Ó widx < NPIX ±£»¤£»±ØĞë full=1£¨ÕûÖ¡²ÉÂú£©²ÅÔÊĞí·¢ËÍ¡£
//   3) mem Òì²½¶Á²»ĞĞ£¨»á±»×ÛºÏ³É¿é RAM£©£¬¸Ä³É raddr/rdata ´òÒ»ÅÄ¼Ä´æ¶Á¡£
//   4) ²ÉÑù²»ÄÜ¼Ó !I_tlast£ºÒ»ĞĞµÚ 320 ÅÄ¾ÍÊÇĞĞÄ©ÄÇÒ»ÅÄ£¬¼ÓÁËÃ¿ĞĞÉÙÒ»¸ö¡£
//
//  ²»ÏëÓÃÊ±°Ñ isp_top ÀïµÄ THUMB_EN ¸Ä³É 0¡£
// ###########################################################################
module uart_thumb_tx #(
    parameter integer CLK_HZ = 103520000,
    parameter integer BAUD   = 921600,      // CLK_HZ/BAUD = 112
    parameter integer COLS   = 320,
    parameter integer ROWS   = 90
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tvalid,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata,       // 4 pixels, RGB888 each
    input  wire [11:0] I_win_y,
    output wire        O_txd
);

    localparam integer DIV   = CLK_HZ / BAUD;   // 112
    localparam integer NPIX  = COLS * ROWS;     // 28800
    localparam [14:0]  NPIXV = NPIX;
    localparam [8:0]   COLSM1 = COLS - 1;       // 319

    localparam [2:0] S_CAP = 3'd0, S_ROW = 3'd1, S_LOAD = 3'd2, S_SEND = 3'd3, S_CK = 3'd4;

    // ---------------- capture buffer ----------------
    reg [23:0] mem [0:32767];
    reg [14:0] widx;
    reg [11:0] x;
    reg [11:0] y;
    reg        cap_on;
    reg        full;

    reg [2:0]  st;
    reg        sending;
    reg [15:0] cksum;       // 16 Î»ĞĞĞ£ÑéºÍ£¬ÈÃ PC ¶ËÄÜ×Ô¼ºÑéÖ¤Êı¾İÍêÕûĞÔ
    reg [1:0]  ckcnt;
    reg        fin;         // ±¾Ö¡×îºóÒ»¸öÏñËØÒÑ·¢³ö£¬Ğ£ÑéºÍÖ®ºó½áÊø
    reg [6:0]  rowcnt;      // 0..89
    reg [8:0]  colcnt;      // 0..319
    reg [1:0]  hcnt;        // row header byte 0..2
    reg [14:0] ridx;
    reg [14:0] raddr;
    reg [23:0] rdata;
    reg [1:0]  bsel;
    reg [7:0]  d;
    reg        byte_valid;

    reg        busy;
    reg [3:0]  bitn;
    reg [15:0] bcnt;
    reg [9:0]  sh;

    // ---------------- 4-pixel horizontal average ----------------
    wire [9:0] sR = I_tdata[23:16] + I_tdata[47:40] + I_tdata[71:64] + I_tdata[95:88];
    wire [9:0] sG = I_tdata[15: 8] + I_tdata[39:32] + I_tdata[63:56] + I_tdata[87:80];
    wire [9:0] sB = I_tdata[ 7: 0] + I_tdata[31:24] + I_tdata[55:48] + I_tdata[79:72];

    // ---------------- registered read of the capture buffer -------------
    // The capture buffer must never be read and written in the same cycle.
    // When it is, TD maps the array onto a RAM whose write side wins and the
    // data read back is garbage -- that is what produced the colour speckle in
    // the thumbnail.  Gating the read while capturing makes write and read
    // mutually exclusive, so a single-port RAM is enough and correct.
    always @(posedge I_clk) if (st != S_CAP) rdata <= mem[raddr];

    wire [7:0] cur_byte = (bsel == 2'd0) ? rdata[23:16] :
                          (bsel == 2'd1) ? rdata[15: 8] : rdata[7:0];

    // row header A5 5A <row index>
    wire [7:0] hdr_byte = (hcnt == 2'd0) ? 8'hA5 :
                          (hcnt == 2'd1) ? 8'h5A : {1'b0, rowcnt};

    wire [11:0] win_y = I_win_y;
    wire [11:0] wye   = I_win_y + ROWS[11:0];
    // 90 consecutive lines starting at win_y (the old code took every 8th line)
    wire samp  = cap_on && I_tvalid && (y >= win_y) && (y < wye) && (widx < NPIXV);
    wire start = byte_valid && !busy;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            x <= 12'd0; y <= 12'd0; widx <= 15'd0; cap_on <= 1'b0; full <= 1'b0;
            st <= S_CAP; sending <= 1'b0; rowcnt <= 7'd0; colcnt <= 9'd0;
            hcnt <= 2'd0; ridx <= 15'd0; raddr <= 15'd0; bsel <= 2'd0;
            d <= 8'd0; byte_valid <= 1'b0;
        end else begin
            case (st)
            // ------------------------------------------------ ²É¼¯
            S_CAP: begin
                if (I_tuser) begin
                    x <= 12'd0;
                    y <= 12'd0;
                    if (!sending) begin
                        widx   <= 15'd0;
                        cap_on <= 1'b1;
                        full   <= 1'b0;
                    end else begin
                        cap_on <= 1'b0;
                    end
                end else if (I_tvalid) begin
                    if (I_tlast) begin
                        x <= 12'd0;
                        y <= y + 12'd1;
                    end else begin
                        x <= x + 12'd4;
                    end
                    if (samp) begin
                        mem[widx] <= I_tdata[23:0];   // pixel 0 raw, no averaging
                        widx      <= widx + 15'd1;
                        if (widx == (NPIXV - 15'd1)) full <= 1'b1;
                    end
                end

                if (I_tvalid && I_tlast && cap_on && full) begin
                    cap_on     <= 1'b0;
                    full       <= 1'b0;
                    sending    <= 1'b1;
                    rowcnt     <= 7'd0;
                    colcnt     <= 9'd0;
                    hcnt       <= 2'd0;
                    ridx       <= 15'd0;
                    raddr      <= 15'd0;
                    bsel       <= 2'd0;
                    byte_valid <= 1'b0;
                    fin        <= 1'b0;
                    st         <= S_ROW;
                end
            end
            // ------------------------------------------------ ĞĞÍ· A5 5A <row>
            S_ROW: begin
                if (!byte_valid && !busy) begin
                    d          <= hdr_byte;
                    byte_valid <= 1'b1;
                end else if (start) begin
                    byte_valid <= 1'b0;
                    if (hcnt == 2'd2) begin
                        hcnt  <= 2'd0;
                        cksum <= 16'd0;
                        st    <= S_LOAD;
                    end else begin
                        hcnt <= hcnt + 2'd1;
                    end
                end
            end
            // ---------------------------- row checksum: 2 bytes, high then low
            S_CK: begin
                if (!byte_valid && !busy) begin
                    d          <= (ckcnt == 2'd0) ? cksum[15:8] : cksum[7:0];
                    byte_valid <= 1'b1;
                end else if (start) begin
                    byte_valid <= 1'b0;
                    if (ckcnt == 2'd1) begin
                        ckcnt <= 2'd0;
                        if (fin) begin
                            fin     <= 1'b0;
                            sending <= 1'b0;
                            st      <= S_CAP;
                        end else begin
                            st <= S_ROW;
                        end
                    end else begin
                        ckcnt <= ckcnt + 2'd1;
                    end
                end
            end
            // ------------------------------------------------ ´òÒ»ÅÄÈ¡ÏñËØ
            S_LOAD: begin
                st <= S_SEND;
            end
            // ------------------------------------------------ Öğ×Ö½ÚËÍ
            S_SEND: begin
                if (!byte_valid && !busy) begin
                    d          <= cur_byte;
                    byte_valid <= 1'b1;
                end else if (start) begin
                    byte_valid <= 1'b0;
                    if (bsel == 2'd2) begin
                        bsel  <= 2'd0;
                        cksum <= cksum + {8'd0, rdata[23:16]} + {8'd0, rdata[15:8]} + {8'd0, rdata[7:0]};
                        if (ridx >= (NPIXV - 15'd1)) begin
                            // still emit this row's checksum, then stop the frame
                            ckcnt <= 2'd0;
                            fin   <= 1'b1;
                            st    <= S_CK;
                        end else begin
                            ridx  <= ridx + 15'd1;
                            raddr <= ridx + 15'd1;
                            if (colcnt == COLSM1) begin
                                colcnt <= 9'd0;
                                rowcnt <= rowcnt + 7'd1;
                                ckcnt  <= 2'd0;
                                st     <= S_CK;
                            end else begin
                                colcnt <= colcnt + 9'd1;
                                st     <= S_LOAD;
                            end
                        end
                    end else begin
                        bsel <= bsel + 2'd1;
                    end
                end
            end
            default: st <= S_CAP;
            endcase
        end
    end

    // ------------------------------------------------ UART 8N1 ·¢ËÍ
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            busy <= 1'b0; bitn <= 4'd0; bcnt <= 16'd0; sh <= 10'h3FF;
        end else if (!busy) begin
            if (start) begin
                sh   <= {1'b1, d, 1'b0};
                busy <= 1'b1;
                bitn <= 4'd0;
                bcnt <= 16'd0;
            end
        end else begin
            if (bcnt >= (DIV - 1)) begin
                bcnt <= 16'd0;
                if (bitn == 4'd9) begin
                    busy <= 1'b0;
                end else begin
                    sh   <= {1'b1, sh[9:1]};
                    bitn <= bitn + 4'd1;
                end
            end else begin
                bcnt <= bcnt + 16'd1;
            end
        end
    end

    assign O_txd = busy ? sh[0] : 1'b1;

endmodule

// ###########################################################################
//  uart_cfg_rx -- live tuning of the ISP over the same FT2232 link
//
//  ÎªÊ²Ã´ĞèÒªËü£¨ÕâÊÇ"ÈÆ¹ı±àÒë"µÄ¹Ø¼ü£©£º
//        °åÉÏµÄ JTAG ºÍ´®¿ÚÊÇÍ¬Ò»¿Å FT2232£ºA Í¨µÀ×ö JTAG£¬B Í¨µÀµÄ TX/RX
//        ·Ö±ğ½Óµ½ FPGA µÄ H1(FPGA_TXD) ºÍ J1(FPGA_RXD)¡£Ö®Ç°Ö»ÓÃÁË·¢ËÍ·½Ïò£¬
//        ½ÓÊÕ·½Ïò J1 Ò»Ö±¿Õ×Å¡£¼ÓÉÏÕâ¸ö½ÓÊÕÆ÷£¬°×Æ½ºâÔöÒæºÍÈñ»¯Ç¿¶È¾ÍÄÜ
//        ´Ó PC Ö±½ÓĞ´£¬²»ÓÃÔÙ¸Ä RTL ÖØ±à 8 ·ÖÖÓ¡£
//
//  Ğ­Òé£¨Óë 921600 8N1 Ò»ÖÂ£¬DIV = 103520000/921600 = 112£©£º
//        Ã¿ 5 ×Ö½ÚÒ»Ö¡£¬ÎŞĞ£Ñé£º
//              A5 5A <cmd> <hi> <lo>
//        cmd = 01 -> R ÔöÒæ (11bit, hi[2:0]:lo)    Ä¬ÈÏ 304 = 1.1875x
//        cmd = 02 -> B ÔöÒæ (11bit)                Ä¬ÈÏ 256 = 1.0000x
//        cmd = 03 -> Èñ»¯Ç¿¶È (lo[1:0])            0=¹Ø 1=1/2 2=1/4 3=1/8
//        cmd = ÆäËü -> ºöÂÔ
//
//  ½ÓÊÕÊµÏÖÒªµã£º
//        * Òì²½ÊäÈëÏÈ´òÁ½ÅÄÍ¬²½£¬ÔÙ´òµÚÈıÅÄÓÃÓÚ±ßÑØ¼ì²â£¬±ÜÃâÑÇÎÈÌ¬¡£
//        * ¼ì²âµ½ÏÂ½µÑØºóµÈ DIV/2 ¸öÖÜÆÚÔÙ²ÉÆğÊ¼Î»£¨²ÉÔÚ±ÈÌØÖĞÑë£©£¬
//          Ö®ºóÃ¿ DIV ¸öÖÜÆÚ²ÉÒ»Î»£¬¿¹²¨ÌØÂÊÆ«²îµÄÄÜÁ¦×îÇ¿¡£
//        * ²Éµ½ÆğÊ¼Î»²»ÊÇµÍµçÆ½¾Íµ±³ÉÃ«´Ì¶ªÆú£¬ÖØĞÂµÈÏÂ½µÑØ¡£
// ###########################################################################
module uart_cfg_rx #(
    parameter integer DIV = 112
)(
    input  wire       I_clk,
    input  wire       I_rst_n,
    input  wire       I_rxd,
    output reg [10:0] O_gain_r,
    output reg [10:0] O_gain_b,
    output reg [10:0] O_gain_g,
    output reg [7:0]  O_off_r,
    output reg [7:0]  O_off_b,
    output reg [1:0]  O_sharp,
    output reg [1:0]  O_nr,
    output reg [11:0] O_win_y
);

    localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    // ---- 2-FF synchroniser + edge history ----
    reg s1, s2, s3;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            s1 <= 1'b1; s2 <= 1'b1; s3 <= 1'b1;
        end else begin
            s1 <= I_rxd;
            s2 <= s1;
            s3 <= s2;
        end
    end

    reg [1:0]  state;
    reg [15:0] cnt;
    reg [2:0]  bitn;
    reg [7:0]  db;
    reg        rx_done;
    reg [7:0]  rxbyte;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            state   <= S_IDLE;
            cnt     <= 16'd0;
            bitn    <= 3'd0;
            db      <= 8'd0;
            rx_done <= 1'b0;
            rxbyte  <= 8'd0;
        end else begin
            rx_done <= 1'b0;
            case (state)
            S_IDLE: begin
                if (s2 == 1'b0 && s3 == 1'b1) begin
                    state <= S_START;
                    cnt   <= 16'd0;
                end
            end
            S_START: begin
                if (cnt >= (DIV/2)) begin
                    cnt <= 16'd0;
                    if (s2 == 1'b0) begin
                        state <= S_DATA;
                        bitn  <= 3'd0;
                    end else begin
                        state <= S_IDLE;      // glitch, not a real start bit
                    end
                end else begin
                    cnt <= cnt + 16'd1;
                end
            end
            S_DATA: begin
                if (cnt >= (DIV - 1)) begin
                    cnt <= 16'd0;
                    db  <= {s2, db[7:1]};
                    if (bitn == 3'd7) state <= S_STOP;
                    else              bitn  <= bitn + 3'd1;
                end else begin
                    cnt <= cnt + 16'd1;
                end
            end
            S_STOP: begin
                if (cnt >= (DIV - 1)) begin
                    cnt     <= 16'd0;
                    state   <= S_IDLE;
                    rxbyte  <= db;
                    rx_done <= 1'b1;
                end else begin
                    cnt <= cnt + 16'd1;
                end
            end
            default: state <= S_IDLE;
            endcase
        end
    end

    // ---- frame parser: A5 5A cmd hi lo ----
    // rx_done must be delayed by one clock: it is asserted in the same edge that
    // writes rxbyte, so a parser using it directly would read the previous byte.
    reg rx_done_d;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) rx_done_d <= 1'b0;
        else          rx_done_d <= rx_done;
    end

    reg [2:0] fidx;
    reg [7:0] cmd, dhi, dlo;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            fidx     <= 3'd0;
            cmd      <= 8'd0;
            dhi      <= 8'd0;
            dlo      <= 8'd0;
            O_gain_r <= 11'd304;
            O_gain_b <= 11'd256;
            O_gain_g <= 11'd256;
            O_off_r  <= 8'd0;
            O_off_b  <= 8'd0;
            O_sharp  <= 2'd2;
            O_nr     <= 2'd0;
            O_win_y  <= 12'd300;
        end else if (rx_done_d) begin
            case (fidx)
            3'd0: fidx <= (rxbyte == 8'hA5) ? 3'd1 : 3'd0;
            3'd1: fidx <= (rxbyte == 8'h5A) ? 3'd2 : 3'd0;
            3'd2: begin cmd <= rxbyte; fidx <= 3'd3; end
            3'd3: begin dhi <= rxbyte; fidx <= 3'd4; end
            default: begin
                dlo  <= rxbyte;
                fidx <= 3'd0;
                case (cmd)
                8'h01: O_gain_r <= {dhi[2:0], rxbyte};
                8'h02: O_gain_b <= {dhi[2:0], rxbyte};
                8'h08: O_gain_g <= {dhi[2:0], rxbyte};
                8'h05: O_off_r  <= {dhi[2:0], rxbyte};
                8'h07: O_off_b  <= {dhi[2:0], rxbyte};
                8'h03: O_sharp  <= rxbyte[1:0];
                8'h04: O_nr     <= rxbyte[1:0];
                8'h06: O_win_y  <= {dhi[3:0], rxbyte};
                default: ;
                endcase
            end
            endcase
        end
    end

endmodule

// ###########################################################################
//  axis_nr_rgb96 -- spatial luma noise reduction for the live picture
//
//  ÎªÊ²Ã´ĞèÒªËü£º
//        Êµ²â»­ÃæÔëµã³É·Ö£¨3x3 ÁÚÓòÆ½¾ù²î£©£ºÁÁ¶È Y = 4.85£¬É«¶È Cb/Cr =
//        0.45/0.33¡£Ôëµã¼¸ºõ 100% ÊÇÁÁ¶ÈÔëµã£¬É«¶ÈµÍÍ¨ÄÇÀàÊ¡ÊÂ°ì·¨ÎŞĞ§¡£
//        ´«¸ĞÆ÷²à 0x3e09=0x0f ÊÇ 16 ±¶Ä£ÄâÔöÒæ£»Ä£ÄâÔöÒæ¶ÔĞÅºÅºÍÔëÉùµÈ±È
//        ·Å´ó£¬½µµÍËü²»»á¸ÄÉÆĞÅÔë±È£¨·´¶øÈÃ ADC Á¿»¯ÔëÉùÕ¼±È±ä´ó£©£¬
//        ËùÒÔÖ»ÄÜ¿¿¿Õ¼äÂË²¨¡£
//
//  Ëã·¨£¨Òò¹û 2D ¼ÓÈ¨Æ½¾ù + ±ßÔµ±£³Ö£©£º
//        h   = (left + 2*centre + right) / 4
//        out = (p2 + p1 + centre + h) / 4     when |centre - h| < TH
//        out = centre                         otherwise   (edge: untouched)
//        p1/p2 ÊÇÉÏÁ½ĞĞ£¬È«ÊÇ¹ıÈ¥µÄĞĞ -> ²»ĞèÒªĞĞÑÓ³Ù£¬720 ĞĞ / tuser / tlast
//        µÄÖ¡½á¹¹ÍêÈ«²»±ä£¬²»»áÒıÈëĞÂµÄ´íÎ»¡£
//        Æ½Ì¹ÇøÔëÉù·½²î 0.21£¬Ô¼ 2.2 ±¶ÒÖÖÆ¡£
//
//  ĞĞ»º´æ°²È«£º
//        ¶ÁµØÖ· = xq-1£¬Ğ´µØÖ· = xq-2£¬Á½ÕßÓÀÔ¶²»Í¬£¬²»´æÔÚÍ¬Ö·¶ÁĞ´Òş»¼
//        £¨ÕâÕıÊÇÖ®Ç°ËõÂÔÍ¼»º´æ³öÎÊÌâµÄµØ·½£¬ÕâÀï³¹µ×±Ü¿ª£©¡£
//
//  Ç¿¶È I_str£º0=Ö±Í¨ 1=Çá(TH=6) 2=ÖĞ(TH=10) 3=Ç¿(TH=16)
// ###########################################################################
module axis_nr_rgb96 #(
    parameter integer NB = 320
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire        I_tvalid,
    input  wire [95:0] I_tdata,
    input  wire [1:0]  I_str,
    output reg         O_tlast,
    output reg         O_tuser,
    output reg         O_tvalid,
    output reg  [95:0] O_tdata
);

    // ---------------- stage 1: horizontal ----------------
    reg [95:0] prev = 96'd0;
    reg        pv   = 1'b0;
    reg        pl   = 1'b0;
    reg        pu   = 1'b0;

    always @(posedge I_clk) begin
        prev <= I_tdata;
        pv   <= I_tvalid;
        pl   <= I_tlast;
        pu   <= I_tuser;
    end

    wire [23:0] a0 = prev[23: 0], a1 = prev[47:24], a2 = prev[71:48], a3 = prev[95:72];
    wire [23:0] n0 = I_tdata[23: 0];

    wire [23:0] l0 = a0, l1 = a0, l2 = a1, l3 = a2;
    wire [23:0] r0 = a1, r1 = a2, r2 = a3, r3 = n0;

    function [7:0] nrf;
        input [7:0] lv, cv, rv;
        input [1:0] str;
        reg [9:0]  hs;
        reg [7:0]  hv;
        reg [8:0]  d;
        reg [9:0]  th;
        begin
            hs = {2'b00, lv} + {1'b0, cv, 1'b0} + {2'b00, rv};
            hv = hs[9:2];
            d  = (cv > hv) ? ({1'b0, cv} - {1'b0, hv}) : ({1'b0, hv} - {1'b0, cv});
            // horizontal smoothing is deliberately weak: it must not destroy
            // the horizontal detail that the sharpener is meant to enhance.
            case (str)
            2'd0:    th = 10'd2;
            2'd1:    th = 10'd3;
            2'd2:    th = 10'd4;
            default: th = 10'd5;
            endcase
            nrf = (d < th) ? hv : cv;
        end
    endfunction

    wire [23:0] o0 = { nrf(l0[23:16], a0[23:16], r0[23:16], I_str),
                       nrf(l0[15: 8], a0[15: 8], r0[15: 8], I_str),
                       nrf(l0[ 7: 0], a0[ 7: 0], r0[ 7: 0], I_str) };
    wire [23:0] o1 = { nrf(l1[23:16], a1[23:16], r1[23:16], I_str),
                       nrf(l1[15: 8], a1[15: 8], r1[15: 8], I_str),
                       nrf(l1[ 7: 0], a1[ 7: 0], r1[ 7: 0], I_str) };
    wire [23:0] o2 = { nrf(l2[23:16], a2[23:16], r2[23:16], I_str),
                       nrf(l2[15: 8], a2[15: 8], r2[15: 8], I_str),
                       nrf(l2[ 7: 0], a2[ 7: 0], r2[ 7: 0], I_str) };
    wire [23:0] o3 = { nrf(l3[23:16], a3[23:16], r3[23:16], I_str),
                       nrf(l3[15: 8], a3[15: 8], r3[15: 8], I_str),
                       nrf(l3[ 7: 0], a3[ 7: 0], r3[ 7: 0], I_str) };

    reg [95:0] hres = 96'd0;
    reg [2:0]  vs   = 3'd0;           // valid pipeline for the vertical stage
    reg        ls   = 1'b0;
    reg        us   = 1'b0;

    always @(posedge I_clk) begin
        hres <= {o3, o2, o1, o0};
        vs   <= {vs[1:0], pv};
        ls   <= pl;
        us   <= pu;
    end

    // ---------------- stage 2: vertical ----------------
    (* ram_style = "block" *) reg [95:0] lb [0:NB-1];
    reg [8:0]  bxh = 9'd0;
    reg [95:0] up  = 96'd0;
    reg [95:0] hres2 = 96'd0;

    always @(posedge I_clk) begin
        up    <= lb[bxh];                 // old contents = previous line
        hres2 <= hres;                    // align with up
        if (pv) begin
            lb[bxh] <= hres;              // store this line's filtered beat
            if (pl || I_tlast) bxh <= 9'd0;
            else               bxh <= bxh + 9'd1;
        end
    end

    function [7:0] vf;
        input [7:0] c, u;
        input [1:0] str;
        reg [8:0] d;
        reg [9:0] th;
        begin
            d = (c > u) ? ({1'b0, c} - {1'b0, u}) : ({1'b0, u} - {1'b0, c});
            case (str)
            2'd0:    th = 10'd5;
            2'd1:    th = 10'd9;
            2'd2:    th = 10'd14;
            default: th = 10'd20;
            endcase
            vf = (d < th) ? {1'b0, c[7:1]} + {1'b0, u[7:1]} + {7'd0, (c[0] & u[0])} : c;
        end
    endfunction

    wire [23:0] v0 = { vf(hres2[23:16], up[23:16], I_str),
                       vf(hres2[15: 8], up[15: 8], I_str),
                       vf(hres2[ 7: 0], up[ 7: 0], I_str) };
    wire [23:0] v1 = { vf(hres2[47:40], up[47:40], I_str),
                       vf(hres2[39:32], up[39:32], I_str),
                       vf(hres2[31:24], up[31:24], I_str) };
    wire [23:0] v2 = { vf(hres2[71:64], up[71:64], I_str),
                       vf(hres2[63:56], up[63:56], I_str),
                       vf(hres2[55:48], up[55:48], I_str) };
    wire [23:0] v3 = { vf(hres2[95:88], up[95:88], I_str),
                       vf(hres2[87:80], up[87:80], I_str),
                       vf(hres2[79:72], up[79:72], I_str) };

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_tvalid <= 1'b0;
            O_tdata  <= 96'd0;
            O_tlast  <= 1'b0;
            O_tuser  <= 1'b0;
        end else begin
            O_tvalid <= vs[2];
            O_tdata  <= {v3, v2, v1, v0};
            O_tlast  <= ls;
            O_tuser  <= us;
        end
    end

endmodule

// ===== ETH VIDEO TRANSMIT (integrated) =====
// Generated from the verified simulation sources in sc520\sim.
// Do not edit the three modules below by hand: run patch_eth_int.py instead.

//======================================================================
//  udp_frame_tx -- build complete Ethernet/IPv4/UDP frames around a byte
//  payload stream.  Pure logic, no primitives, no vendor IP: it can be
//  simulated with iverilog long before anything is compiled for the FPGA.
//
//  Frame layout produced (least significant byte first on the wire):
//
//      preamble 55 55 55 55 55 55 55 D5
//      dst MAC (6) / src MAC (6) / ethertype 0800
//      IPv4 header (20)  version=4 ihl=5 tos=0 len id=0x0000 frag=0 ttl=64
//                        proto=17(udp) hdr_cksum src_ip dst_ip
//      UDP header (8)    src port / dst port / udp length / checksum = 0
//      payload           i_len bytes supplied by the caller
//      CRC32 (4)         little endian, over everything after the preamble
//
//  Handshake: assert i_sop together with the first payload byte of a packet
//  (i_len must be stable then).  i_ready goes high when the module will take
//  a payload byte this cycle.  One packet at a time.
//======================================================================
// `timescale 1ns/1ps

module udp_frame_tx #(
    parameter [47:0] MAC_DEST  = 48'hFFFFFFFFFFFF,   // broadcast
    parameter [47:0] MAC_SRC   = 48'h0123456789AB,
    parameter [31:0] IP_SRC    = {8'd169, 8'd254, 8'd128, 8'd100},
    parameter [31:0] IP_DST    = {8'd169, 8'd254, 8'd128, 8'd254},
    parameter [15:0] UDP_SPORT = 16'd6002,
    parameter [15:0] UDP_DPORT = 16'd6001,
    parameter [15:0] IP_ID     = 16'h0000
)(
    input  wire       clk,
    input  wire       rst,
    // payload in
    input  wire       i_sop,
    input  wire [15:0] i_len,
    input  wire       i_valid,
    input  wire [7:0] i_data,
    output wire       o_ready,
    // gmii out
    output reg  [7:0] o_txd,
    output reg        o_tx_en,
    output reg        o_frame_done,     // pulses for one cycle per frame
    output wire       o_idle            // 1 while waiting for a new packet
);

    localparam [7:0]  S_IDLE   = 8'd0;
    localparam [7:0]  S_IFG    = 8'd1;
    localparam [7:0]  S_PRE    = 8'd2;
    localparam [7:0]  S_HEAD   = 8'd3;
    localparam [7:0]  S_PAY    = 8'd4;
    localparam [7:0]  S_CRC    = 8'd5;
    localparam [7:0]  S_DONE   = 8'd6;

    localparam integer HDR_N = 42;      // MAC..UDP header bytes
    localparam integer IFG_N = 12;      // inter frame gap in byte times

    reg [7:0]  st;
    reg [5:0]  hidx;                    // 0..41
    reg [3:0]  pre;                     // 0..8
    reg [15:0] pcnt;                    // payload bytes sent
    reg [15:0] plen;                    // captured payload length
    reg [3:0]  ccnt;                    // 0..3 crc bytes
    reg [3:0]  ifg;
    reg [31:0] crc;

    // ---- IPv4 total length / UDP length -----------------------------
    wire [15:0] ip_len  = 16'd20 + 16'd8 + plen;
    wire [15:0] udp_len = 16'd8 + plen;

    // ---- IPv4 header checksum over the 20 header bytes --------------
    // bytes: 45 00 LEN_HI LEN_LO 00 00 00 00 40 11 00 00 SRC(4) DST(4)
    // computed combinationally from plen / IP_SRC / IP_DST
    wire [15:0] ipw0 = {8'h45, 8'h00};
    wire [15:0] ipw1 = ip_len;
    wire [15:0] ipw2 = {8'h00, 8'h00};
    wire [15:0] ipw3 = {8'h00, 8'h00};
    wire [15:0] ipw4 = {8'h40, 8'h11};
    wire [15:0] ipw5 = {8'h00, 8'h00};
    wire [15:0] ipw6 = IP_SRC[31:16];
    wire [15:0] ipw7 = IP_SRC[15:0];
    wire [15:0] ipw8 = IP_DST[31:16];
    wire [15:0] ipw9 = IP_DST[15:0];
    wire [19:0] ip_ss = {4'd0, ipw0} + {4'd0, ipw1} + {4'd0, ipw2} + {4'd0, ipw3}
                      + {4'd0, ipw4} + {4'd0, ipw5} + {4'd0, ipw6} + {4'd0, ipw7}
                      + {4'd0, ipw8} + {4'd0, ipw9};
    wire [19:0] ip_fold = {16'd0, ip_ss[15:0]} + {16'd0, ip_ss[19:16]};
    wire [19:0] ip_fold2 = {16'd0, ip_fold[15:0]} + {16'd0, ip_fold[19:16]};
    wire [15:0] ip_cks = ~ip_fold2[15:0];

    // ---- header byte selection -------------------------------------
    reg [7:0] hb;
    always @* begin
        case (hidx)
        6'd0, 6'd1, 6'd2, 6'd3, 6'd4, 6'd5:  hb = MAC_DEST[47:0] >> (8 * (5 - hidx));
        6'd6, 6'd7, 6'd8, 6'd9, 6'd10, 6'd11: hb = MAC_SRC[47:0] >> (8 * (11 - hidx));
        6'd12: hb = 8'h08;
        6'd13: hb = 8'h00;
        // IPv4
        6'd14: hb = 8'h45;
        6'd15: hb = 8'h00;
        6'd16: hb = ip_len[15:8];
        6'd17: hb = ip_len[7:0];
        6'd18: hb = IP_ID[15:8];
        6'd19: hb = IP_ID[7:0];
        6'd20: hb = 8'h00;                 // flags/fragment = DF clear
        6'd21: hb = 8'h00;
        6'd22: hb = 8'h40;                 // ttl 64
        6'd23: hb = 8'h11;                 // udp
        6'd24: hb = ip_cks[15:8];
        6'd25: hb = ip_cks[7:0];
        6'd26: hb = IP_SRC[31:24];
        6'd27: hb = IP_SRC[23:16];
        6'd28: hb = IP_SRC[15:8];
        6'd29: hb = IP_SRC[7:0];
        6'd30: hb = IP_DST[31:24];
        6'd31: hb = IP_DST[23:16];
        6'd32: hb = IP_DST[15:8];
        6'd33: hb = IP_DST[7:0];
        // UDP
        6'd34: hb = UDP_SPORT[15:8];
        6'd35: hb = UDP_SPORT[7:0];
        6'd36: hb = UDP_DPORT[15:8];
        6'd37: hb = UDP_DPORT[7:0];
        6'd38: hb = udp_len[15:8];
        6'd39: hb = udp_len[7:0];
        6'd40: hb = 8'h00;                 // checksum not used
        6'd41: hb = 8'h00;
        default: hb = 8'h00;
        endcase
    end

    // ---- byte wide CRC32 (reflected, poly 0xEDB88320) --------------
    function [31:0] crc_byte;
        input [31:0] c;
        input [7:0]  d;
        integer k;
        reg [31:0] x;
        begin
            x = c ^ {24'd0, d};
            for (k = 0; k < 8; k = k + 1)
                x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
            crc_byte = x;
        end
    endfunction

    assign o_ready = (st == S_PAY);
    assign o_idle  = (st == S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            st         <= S_IDLE;
            o_txd      <= 8'h00;
            o_tx_en    <= 1'b0;
            o_frame_done <= 1'b0;
            hidx       <= 6'd0;
            pre        <= 4'd0;
            pcnt       <= 16'd0;
            plen       <= 16'd0;
            ccnt       <= 4'd0;
            ifg        <= 4'd0;
            crc        <= 32'hFFFFFFFF;
        end else begin
            o_frame_done <= 1'b0;
            o_tx_en      <= 1'b1;
            case (st)
            S_IDLE: begin
                o_tx_en <= 1'b0;
                if (i_sop && i_valid) begin
                    plen <= i_len;
                    crc  <= 32'hFFFFFFFF;
                    pre  <= 4'd0;
                    hidx <= 6'd0;
                    pcnt <= 16'd0;
                    st   <= S_PRE;
                end
            end
            S_PRE: begin
                o_txd <= (pre == 4'd7) ? 8'hD5 : 8'h55;
                pre   <= pre + 4'd1;
                if (pre == 4'd7) begin
                    hidx  <= 6'd0;
                    st    <= S_HEAD;
                    crc   <= 32'hFFFFFFFF;
                end
            end
            S_HEAD: begin
                o_txd <= hb;
                crc   <= crc_byte(crc, hb);
                if (hidx == HDR_N - 1) begin
                    hidx  <= 6'd0;
                    pcnt  <= 16'd0;
                    st    <= (plen == 16'd0) ? S_CRC : S_PAY;
                end else begin
                    hidx <= hidx + 6'd1;
                end
            end
            S_PAY: begin
                if (i_valid) begin
                    o_txd <= i_data;
                    crc   <= crc_byte(crc, i_data);
                    pcnt  <= pcnt + 16'd1;
                    if (pcnt == plen - 16'd1) begin
                        ccnt <= 4'd0;
                        st   <= S_CRC;
                    end
                end else begin
                    o_txd <= 8'h00;          // keep the byte clock running
                end
            end
            S_CRC: begin
                case (ccnt)
                4'd0: o_txd <= ~crc[7:0];
                4'd1: o_txd <= ~crc[15:8];
                4'd2: o_txd <= ~crc[23:16];
                default: o_txd <= ~crc[31:24];
                endcase
                if (ccnt == 4'd3) begin
                    ccnt <= 4'd0;
                    st   <= S_IFG;
                    ifg  <= 4'd0;
                end else begin
                    ccnt <= ccnt + 4'd1;
                end
            end
            S_IFG: begin
                o_tx_en <= 1'b0;
                o_txd   <= 8'h00;
                if (ifg == IFG_N - 1) begin
                    ifg          <= 4'd0;
                    o_frame_done <= 1'b1;
                    st           <= S_IDLE;
                end else begin
                    ifg <= ifg + 4'd1;
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule


//======================================================================
//  udp_video_tx -- move a 96-bit (4 x RGB888) video stream onto Ethernet.
//
//      video domain (103.52 MHz)               125 MHz domain
//      ------------------------                --------------
//      keep every DECth line
//      push 96-bit beats   --> data FIFO (96b) --> 968 byte UDP payload
//      push {frame,line,seg} --> meta FIFO (32b) --> udp_frame_tx --> GMII
//
//  One 1280 pixel line becomes SEGS packets of SEG_PX pixels.  Payload is
//  8 header bytes plus 960 pixel bytes (320 px, R,G,B per pixel):
//
//      b0,b1 frame        b2,b3 line        b4 seg      b5 SEGS
//      b6,b7 line width in pixels
//
//  The header lets the receiver rebuild the picture after a lost packet.
//  Plain RTL, verified in iverilog before anything is compiled.
//======================================================================
// `timescale 1ns/1ps

//----------------------------------------------------------------------
//  async_fifo -- gray code pointers, show-ahead read: rdata is valid when
//  !rempty; assert rack for one cycle to step to the next entry.
//----------------------------------------------------------------------
module async_fifo #(
    parameter integer W  = 96,
    parameter integer AW = 10
)(
    input  wire          wclk,
    input  wire          wrst,
    input  wire          we,
    input  wire [W-1:0]  wdata,
    output wire          wfull,
    output wire [AW:0]   wused,

    input  wire          rclk,
    input  wire          rrst,
    output wire          rempty,
    output wire [AW:0]   rused,
    output wire [W-1:0]  rdata,
    input  wire          rack
);

    localparam integer D = 1 << AW;

    reg [W-1:0] mem [0:D-1];

    reg [AW:0] wbin = 0, wgray = 0;
    reg [AW:0] rbin = 0, rgray = 0;
    reg [AW:0] wq1 = 0, wq2 = 0;
    reg [AW:0] rq1 = 0, rq2 = 0;

    function [AW:0] gray2bin;
        input [AW:0] g;
        integer i;
        begin
            gray2bin[AW] = g[AW];
            for (i = AW - 1; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i + 1] ^ g[i];
        end
    endfunction

    wire [AW:0] wbin_n  = wbin + 1'b1;
    wire [AW:0] wgray_n = (wbin_n >> 1) ^ wbin_n;
    wire [AW:0] rbin_n  = rbin + 1'b1;
    wire [AW:0] rgray_n = (rbin_n >> 1) ^ rbin_n;

    // wq2 lives in the WRITE clock domain and holds the read pointer, so it is
    // the one the write side must subtract.  rq2 lives in the READ clock
    // domain and holds the write pointer.  (Getting these two swapped makes the
    // FIFO look permanently empty while the write pointer keeps advancing --
    // exactly the bug this simulation was written to catch.)
    wire [AW:0] rd_ptr_w = gray2bin(wq2);      // read pointer, write domain
    wire [AW:0] wr_ptr_r = gray2bin(rq2);      // write pointer, read domain

    // the full test must use the read pointer as seen in the WRITE
    // domain (wq2).  Using rq2 here compared the write pointer with a
    // copy of itself sampled in the read domain - wrong flag, and a
    // read-domain register driving the write enable (204 failing paths).
    assign wfull  = (wgray_n == {~wq2[AW:AW-1], wq2[AW-2:0]});
    assign wused  = wbin - rd_ptr_w;
    assign rused  = wr_ptr_r - rbin;
    assign rempty = (wr_ptr_r == rbin);
    assign rdata  = mem[rbin[AW-1:0]];

    always @(posedge wclk) begin
        if (wrst) begin
            wbin <= 0; wgray <= 0; wq1 <= 0; wq2 <= 0;
        end else begin
            wq1 <= rgray; wq2 <= wq1;
            if (we && !wfull) begin
                mem[wbin[AW-1:0]] <= wdata;
                wbin  <= wbin_n;
                wgray <= wgray_n;
            end
        end
    end

    always @(posedge rclk) begin
        if (rrst) begin
            rbin <= 0; rgray <= 0; rq1 <= 0; rq2 <= 0;
        end else begin
            rq1 <= wgray; rq2 <= rq1;
            if (rack && !rempty) begin
                rbin  <= rbin_n;
                rgray <= rgray_n;
            end
        end
    end

endmodule


//----------------------------------------------------------------------
//  udp_video_tx
//----------------------------------------------------------------------
module udp_video_tx #(
    parameter integer DEC      = 2,          // keep every DECth line (power of 2)
    parameter integer LINES    = 720,        // lines per frame
    parameter integer WIDTH    = 1280,
    parameter integer SEG_PX   = 320,
    parameter integer DEC_DROP = 1023,       // effectively off: labels must never drift
    parameter [47:0]  MAC_DEST = 48'hFFFFFFFFFFFF,
    parameter [47:0]  MAC_SRC  = 48'h0123456789AB,
    parameter [31:0]  IP_SRC   = 32'hC0A88902,
    parameter [31:0]  IP_DST   = 32'hC0A88901,
    parameter [15:0]  UDP_SPORT= 16'd6002,
    parameter [15:0]  UDP_DPORT= 16'd6001
)(
    input  wire         vclk,
    input  wire         vrst,
    input  wire         s_tvalid,
    input  wire         s_tlast,
    input  wire         s_tuser,
    input  wire [95:0]  s_tdata,
    output wire         s_tready,

    input  wire         clk,
    input  wire         rst,
    output wire [7:0]   o_txd,
    output wire         o_tx_en,
    output wire         o_frame_done
);

    localparam integer BPS  = SEG_PX / 4;         // 80 beats per segment
    localparam integer SEGS = WIDTH / SEG_PX;     // 4 segments per line
    localparam integer HDRB = 8;
    localparam integer PL   = HDRB + BPS * 12;    // 968 payload bytes
    localparam integer DMASK = DEC - 1;

    // ---------------- FIFO wires ----------------
    wire         dwfull, dempty, drack;
    wire [10:0]  dwused, drused;
    wire [95:0]  drdata;

    wire         mwfull, mempty;
    wire [4:0]   mwused, mrused;
    wire [39:0]  mrdata;
    reg          mrack;
    reg          pop_pend = 1'b0;        // pop the label one clock after latching it

    // ---------------- video side ----------------
    reg  [15:0] y       = 16'd0;
    reg  [15:0] frame   = 16'd0;
    reg         line_ok = 1'b1;
    reg         dwr     = 1'b0;
    reg         mwr     = 1'b0;
    reg         skip_seg = 1'b0;         // this segment has no label: drop its data
    reg  [95:0] dwd     = 96'd0;
    reg  [39:0] mwd     = 40'd0;

    reg  [7:0]  in_seg  = 8'd0;         // 0 .. BPS-1
    reg  [1:0]  seg_c   = 2'd0;         // 0 .. SEGS-1
    reg  [15:0] pkt_abs = 16'd0;        // segments since tuser = true position
    reg         line_start = 1'b1;      // this beat begins a video line

    wire        seg_first = (in_seg == 8'd0);

    assign s_tready = !dwfull && !mwfull;

    // four 24-bit banks instead of one 96-bit array: 24 bits is the width
    // Tang Dynasty maps to ERAM, 96 bits got inferred as distributed RAM and
    // blew the slice budget.
    wire [23:0] rd0, rd1, rd2, rd3;
    wire        dwfull0, dwfull1, dwfull2, dwfull3;
    wire [10:0] dwused0, dwused1, dwused2, dwused3;
    wire        dempty0, dempty1, dempty2, dempty3;
    wire [10:0] drused0, drused1, drused2, drused3;

    assign dwfull  = dwfull0 | dwfull1 | dwfull2 | dwfull3;
    assign dempty  = dempty0 & dempty1 & dempty2 & dempty3;
    assign drused  = drused0;
    assign dwused  = dwused0;
    assign drdata  = {rd3, rd2, rd1, rd0};

    async_fifo #(.W(24), .AW(10)) u_d0 (
        .wclk(vclk), .wrst(vrst), .we(dwr && !dwfull), .wdata(dwd[23:0]),
        .wfull(dwfull0), .wused(dwused0),
        .rclk(clk), .rrst(rst), .rempty(dempty0), .rused(drused0),
        .rdata(rd0), .rack(drack)
    );
    async_fifo #(.W(24), .AW(10)) u_d1 (
        .wclk(vclk), .wrst(vrst), .we(dwr && !dwfull), .wdata(dwd[47:24]),
        .wfull(dwfull1), .wused(dwused1),
        .rclk(clk), .rrst(rst), .rempty(dempty1), .rused(drused1),
        .rdata(rd1), .rack(drack)
    );
    async_fifo #(.W(24), .AW(10)) u_d2 (
        .wclk(vclk), .wrst(vrst), .we(dwr && !dwfull), .wdata(dwd[71:48]),
        .wfull(dwfull2), .wused(dwused2),
        .rclk(clk), .rrst(rst), .rempty(dempty2), .rused(drused2),
        .rdata(rd2), .rack(drack)
    );
    async_fifo #(.W(24), .AW(10)) u_d3 (
        .wclk(vclk), .wrst(vrst), .we(dwr && !dwfull), .wdata(dwd[95:72]),
        .wfull(dwfull3), .wused(dwused3),
        .rclk(clk), .rrst(rst), .rempty(dempty3), .rused(drused3),
        .rdata(rd3), .rack(drack)
    );

    async_fifo #(.W(40), .AW(6)) u_meta (
        .wclk(vclk), .wrst(vrst), .we(mwr && !mwfull),
        .wdata(mwd),
        .wfull(mwfull), .wused(mwused),
        .rclk(clk), .rrst(rst), .rempty(mempty), .rused(mrused),
        .rdata(mrdata), .rack(mrack)
    );

    always @(posedge vclk) begin
        if (vrst) begin
            y <= 16'd0; frame <= 16'd0; line_ok <= 1'b1;
            in_seg <= 8'd0; seg_c <= 2'd0; pkt_abs <= 16'd0; line_start <= 1'b1;
            dwr <= 1'b0; mwr <= 1'b0;
        end else begin
            dwr <= 1'b0;
            mwr <= 1'b0;
            if (s_tuser) begin
                frame      <= frame + 16'd1;
                line_ok    <= (dwused < DEC_DROP);
                pkt_abs    <= 16'd0;
                line_start <= 1'b1;
            end
            if (s_tvalid) begin
                if (seg_first) skip_seg <= mwfull;
                if (line_ok && !seg_first && !skip_seg) begin
                    dwr <= 1'b1;
                    dwd <= s_tdata;
                end
                if (line_ok && seg_first && !mwfull) begin
                    dwr <= 1'b1;
                    dwd <= s_tdata;
                    mwr <= 1'b1;
                    // +1 on the tuser beat: the frame counter is registered, so
                    // it still holds the previous frame number at that edge
                    mwd    <= {7'd0, (s_tuser ? frame + 16'd1 : frame), pkt_abs, line_start};
                    pkt_abs <= pkt_abs + 16'd1;
                end
                // line-start flag for the NEXT beat
                if (!s_tuser) line_start <= s_tlast;
                // advance the position inside the line
                if (s_tuser) begin
                    y      <= 16'd0;
                    in_seg <= 8'd0;
                    seg_c  <= 2'd0;
                end else if (s_tlast) begin
                    y       <= y + 16'd1;
                    in_seg  <= 8'd0;
                    seg_c   <= 2'd0;
                    line_ok <= (((y + 16'd1) & DMASK) == 0) && (dwused < DEC_DROP);
                end else if (in_seg == BPS - 1) begin
                    in_seg <= 8'd0;
                    seg_c  <= (seg_c == SEGS - 1) ? 2'd0 : seg_c + 2'd1;
                end else begin
                    in_seg <= in_seg + 8'd1;
                end
            end
        end
    end

    // ---------------- 125 MHz side ----------------
    localparam [1:0] T_IDLE = 2'd0, T_HDR = 2'd1, T_BODY = 2'd2, T_WAIT = 2'd3;

    reg [1:0]  tst   = T_IDLE;
    reg [15:0] bidx  = 16'd0;
    reg [15:0] wcnt  = 16'd0;
    reg [3:0]  mok   = 4'd0;             // label FIFO stable-non-empty filter
    reg [15:0] lbl_frame = 16'd1;         // derived packet labels
    reg [15:0] lbl_line  = 16'd0;
    reg [1:0]  lbl_seg   = 2'd0;
    reg [3:0]  bsel  = 4'd0;
    reg [15:0] pfrm  = 16'd0;
    reg [15:0] pbeat = 16'd0;
    reg        pls   = 1'b0;
    reg        o_sop = 1'b0;
    reg        o_val = 1'b0;
    wire       o_rdy;
    wire       frm_idle;

    reg [7:0] dbyte;
    always @* begin
        case (bsel)
        4'd0:    dbyte = drdata[23:16];
        4'd1:    dbyte = drdata[15:8];
        4'd2:    dbyte = drdata[7:0];
        4'd3:    dbyte = drdata[47:40];
        4'd4:    dbyte = drdata[39:32];
        4'd5:    dbyte = drdata[31:24];
        4'd6:    dbyte = drdata[71:64];
        4'd7:    dbyte = drdata[63:56];
        4'd8:    dbyte = drdata[55:48];
        4'd9:    dbyte = drdata[95:88];
        4'd10:   dbyte = drdata[87:80];
        default: dbyte = drdata[79:72];
        endcase
    end

    reg [7:0] hbyte;
    always @* begin
        case (bidx[2:0])
        3'd0: hbyte = pfrm[7:0];
        3'd1: hbyte = pfrm[15:8];
        3'd2: hbyte = pbeat[7:0];
        3'd3: hbyte = pbeat[15:8];
        3'd4: hbyte = {7'd0, pls};
        3'd5: hbyte = SEGS[7:0];
        3'd6: hbyte = 8'h00;
        default: hbyte = 8'h00;
        endcase
    end

    wire [7:0] cur_byte = (bidx < HDRB) ? hbyte : dbyte;

    assign drack = (tst == T_BODY) && o_rdy && (bsel == 4'd11);

    udp_frame_tx #(
        .MAC_DEST(MAC_DEST), .MAC_SRC(MAC_SRC),
        .IP_SRC(IP_SRC), .IP_DST(IP_DST),
        .UDP_SPORT(UDP_SPORT), .UDP_DPORT(UDP_DPORT)
    ) u_frm (
        .clk(clk), .rst(rst),
        .i_sop(o_sop), .i_len(PL[15:0]),
        .i_valid(o_val), .i_data(cur_byte),
        .o_ready(o_rdy),
        .o_txd(o_txd), .o_tx_en(o_tx_en), .o_frame_done(o_frame_done),
        .o_idle(frm_idle)
    );

    always @(posedge clk) begin
        if (rst) begin
            tst <= T_IDLE; bidx <= 16'd0; bsel <= 4'd0;
            o_sop <= 1'b0; o_val <= 1'b0;
            pfrm <= 16'd0; pbeat <= 16'd0; pls <= 1'b0; mrack <= 1'b0;
        end else begin
            o_sop <= 1'b0;
            mrack <= 1'b0;
            if (pop_pend) begin
                mrack    <= 1'b1;
                pop_pend <= 1'b0;
            end
            if (mempty)                 mok <= 4'd0;
            else if (mok != 4'd15)      mok <= mok + 4'd1;
            case (tst)
            T_IDLE: begin
                o_val <= 1'b0;
                if (!mempty && drused >= BPS && frm_idle) begin
                    pfrm     <= mrdata[32:17];
                    pbeat    <= mrdata[16:1];
                    pls      <= mrdata[0];
                    pop_pend <= 1'b1;
                    bidx  <= 16'd0;
                    bsel  <= 4'd0;
                    o_val <= 1'b1;
                    o_sop <= 1'b1;
                    tst   <= T_HDR;
                end
            end
            T_HDR: begin
                if (o_rdy) begin
                    bidx <= bidx + 16'd1;
                    if (bidx + 16'd1 == HDRB) begin
                        bsel <= 4'd0;
                        tst  <= T_BODY;
                    end
                end
            end
            T_BODY: begin
                if (o_rdy) begin
                    bidx <= bidx + 16'd1;
                    bsel <= (bsel == 4'd11) ? 4'd0 : bsel + 4'd1;
                    if (bidx == PL - 1) begin
                        o_val <= 1'b0;
                        tst   <= T_WAIT;
                    end
                end
            end
            T_WAIT: begin
                wcnt <= wcnt + 16'd1;
                if (!o_rdy || wcnt > 16'd200) begin
                    wcnt <= 16'd0;
                    tst  <= T_IDLE;
                end
            end
            default: tst <= T_IDLE;
            endcase
        end
    end

endmodule


//======================================================================
//  rgmii_tx_phy -- GMII bytes to RGMII DDR pins (1000BASE-T, transmit only)
//  `ifdef SIMULATION -> behavioural model, otherwise the Anlogic ODDR that
//  the vendor example uses, so one source serves both simulation and
//  synthesis.
//======================================================================
module rgmii_tx_phy (
    input  wire       clk,          // 125 MHz
    input  wire       clk90,        // 125 MHz shifted 90 degrees (drives TXC)
    input  wire       rst,
    input  wire [7:0] gmii_txd,
    input  wire       gmii_tx_en,
    output wire [3:0] rgmii_txd,
    output wire       rgmii_tx_ctl,
    output wire       rgmii_txc
);
    wire [3:0] txd_falling = gmii_txd[7:4];

`ifdef SIMULATION
    reg [3:0] r_txd = 4'd0;
    reg       r_ctl = 1'b0;
    reg       r_txc = 1'b0;
    always @(posedge clk) begin
        r_txd <= gmii_txd[3:0];
        r_ctl <= gmii_tx_en;
        r_txc <= ~r_txc;
    end
    assign rgmii_txd    = r_txd;
    assign rgmii_tx_ctl = r_ctl;
    assign rgmii_txc    = r_txc;
`else
    genvar gi;
    generate for (gi = 0; gi < 4; gi = gi + 1) begin : g_txd
        PH1P_LOGIC_HD_ODDR u_oddr_txd (
            .q   (rgmii_txd[gi]),
            .clk (clk),
            .d0  (gmii_txd[gi]),
            .d1  (txd_falling[gi]),
            .rst (rst)
        );
    end endgenerate

    PH1P_LOGIC_HD_ODDR u_oddr_ctl (
        .q   (rgmii_tx_ctl),
        .clk (clk),
        .d0  (gmii_tx_en),
        .d1  (gmii_tx_en),
        .rst (rst)
    );

    PH1P_LOGIC_HD_ODDR u_oddr_txc (
        .q   (rgmii_txc),
        .clk (clk90),
        .d0  (1'b1),
        .d1  (1'b0),
        .rst (rst)
    );
`endif
endmodule




module ph1p_phy_pll_wrapper_d2616deaaa79 #(
    parameter FBKCLK                 = "CLKC0_EXT",     
    parameter FBKCLK_INT             = "VCO_PHASE0",     
    parameter FIN                    = "100.0000",     	
    parameter REFCLK_DIV             = 1,                                   
    parameter FBCLK_DIV              = 1,               

    parameter CLKC0_ENABLE           = "DISABLE", 
    parameter PREDIV_MUXC0           = "VCO",                   
    parameter DIVOUT_MUXC0           = "DIV",	
    parameter CLKC0_DIV              = 1,  
    parameter CLKC0_CPHASE           = 0,  
    parameter CLKC0_FPHASE           = 0,
    parameter CLKC0_FPHASE_RSTSEL    = 0, 
    parameter CLKC0_DUTY50           = "ENABLE",              
    parameter CLKC0_DUTY_INT         = 1,    

    parameter CLKC1_ENABLE           = "DISABLE", 
    parameter PREDIV_MUXC1           = "VCO",                   
    parameter DIVOUT_MUXC1           = "DIV",	
    parameter CLKC1_DIV              = 1,  
    parameter CLKC1_CPHASE           = 0,  
    parameter CLKC1_FPHASE           = 0,
    parameter CLKC1_FPHASE_RSTSEL    = 0, 
    parameter CLKC1_DUTY50           = "ENABLE",              
    parameter CLKC1_DUTY_INT         = 1,    

    parameter CLKC2_ENABLE           = "DISABLE", 
    parameter PREDIV_MUXC2           = "VCO",                   
    parameter DIVOUT_MUXC2           = "DIV",	
    parameter CLKC2_DIV              = 1,  
    parameter CLKC2_CPHASE           = 0,  
    parameter CLKC2_FPHASE           = 0,
    parameter CLKC2_FPHASE_RSTSEL    = 0, 
    parameter CLKC2_DUTY50           = "ENABLE",              
    parameter CLKC2_DUTY_INT         = 1,    

    parameter CLKC3_ENABLE           = "DISABLE", 
    parameter PREDIV_MUXC3           = "VCO",                   
    parameter DIVOUT_MUXC3           = "DIV",	
    parameter CLKC3_DIV              = 1,  
    parameter CLKC3_CPHASE           = 0,  
    parameter CLKC3_FPHASE           = 0,
    parameter CLKC3_FPHASE_RSTSEL    = 0, 
    parameter CLKC3_DUTY50           = "ENABLE",              
    parameter CLKC3_DUTY_INT         = 1,    
	
    parameter CLKC4_ENABLE           = "DISABLE", 
    parameter PREDIV_MUXC4           = "VCO",                   
    parameter DIVOUT_MUXC4           = "DIV",	
    parameter CLKC4_DIV              = 1,  
    parameter CLKC4_CPHASE           = 0,  
    parameter CLKC4_FPHASE           = 0,
    parameter CLKC4_FPHASE_RSTSEL    = 0, 
    parameter CLKC4_DUTY50           = "ENABLE",              
    parameter CLKC4_DUTY_INT         = 1,    

    parameter CLKC5_ENABLE           = "DISABLE", 
    parameter PREDIV_MUXC5           = "VCO",                   
    parameter DIVOUT_MUXC5           = "DIV",	
    parameter CLKC5_DIV              = 1,  
    parameter CLKC5_CPHASE           = 0,  
    parameter CLKC5_FPHASE           = 0,
    parameter CLKC5_FPHASE_RSTSEL    = 0, 
    parameter CLKC5_DUTY50           = "ENABLE",              
    parameter CLKC5_DUTY_INT         = 1,    
	
    parameter CLKC6_ENABLE           = "DISABLE", 
    parameter PREDIV_MUXC6           = "VCO",                   
    parameter DIVOUT_MUXC6           = "DIV",	
    parameter CLKC6_DIV              = 1,  
    parameter CLKC6_CPHASE           = 0,  
    parameter CLKC6_FPHASE           = 0,
    parameter CLKC6_FPHASE_RSTSEL    = 0, 
    parameter CLKC6_DUTY50           = "ENABLE",              
    parameter CLKC6_DUTY_INT         = 1,  

    parameter WORK_MODE              = "USER",          

    parameter PD_DIG                 = "ENABLE",        
    parameter PLL_USR_RST            = "ENABLE",        
    parameter PLL_FEED_TYPE          = "INTERNAL",      
    parameter PLL_FASTLOOP           = "DISABLE",     

// loop     parameter
    parameter LPF_RES                = 3,               
    parameter LPF_CAP                = 3,               
    parameter ICP_CUR                = 1,               
//frac-N
    parameter FRAC_ENABLE            = "DISABLE",       
    parameter SDM_FRAC               = 0,                              

//fine phase shift
    parameter PHASE_PATH_SEL         = 0,               
    parameter DYN_PHASE_PATH_SEL     = "DISABLE",       
    parameter DYN_FPHASE_EN          = "DISABLE",       

//ssc
    parameter SSC_ENABLE             = "DISABLE",             
    parameter SSC_RST                = "ENABLE",        
    parameter SSC_MODE               = "CENTER",        
    parameter SSC_FREQ_DIV           = 0,                              
    parameter SSC_RNGE               = 242,                            

// lock detector
    parameter REFCLK_DET_BYP         = "DISABLE",       
//channel 0 frac div related
    parameter CLKC0_FRAC_EN          = "DISABLE",             
    parameter CLKC0_FRAC             = 0,               
    parameter PI_OUT_SEL             = "NORMAL",        
    parameter PI_FRAC_EN             = "DISABLE",       
    parameter CLKC0_PI_SHIFT_EN      = "DISABLE",       

    parameter FEEDBK_MODE            = "NORMAL",        
    parameter DYN_CPHASE_EN          = "DISABLE"       
) (
//Global clocks
    input           refclk,                          
    input           fbclk, 
//output clocks
	input			clk0_en,
	output			clk0_out,
	output			clkb0_out,

	input			clk1_en,
	output			clk1_out,
	output			clkb1_out,

	input			clk2_en,
	output			clk2_out,
	output			clkb2_out,

	input			clk3_en,
	output			clk3_out,
	output			clkb3_out,

	input			clk4_en,
	output			clk4_out,
	output			clkb4_out,

	input			clk5_en,
	output			clk5_out,
	output			clkb5_out,

	input			clk6_en,
	output			clk6_out,
	output			clkb6_out,
//PLL  lock detector
    output          lock,           
//PLL and output path reset 
    input           reset,       
    input   [1:0]   clkc_rst,          
    input           refclk_rst,     
    input           wakeup,         
       
//PLL dynamic coarse phase shift
    input           cps_step,       
//PLL power done
    input           pllpd,          
//PLL   dynami fine phase shift
    input           psclk,          
    input   [2:0]   psclksel,       
    input           psstep,         
    input           psdown,         
    output          psdone,         
//Ports of drp
    input           drp_clk,        
    input           drp_rstn,       
    input           drp_sel,        
    input           drp_rd,         
    input           drp_wr,         
    input  [7:0]    drp_addr,                      
    input  [7:0]    drp_wdata,                     
    output          drp_err,        
    output          drp_rdy,        
    output [7:0]    drp_rdata,                       
//Ports of ssc
    input           ssc_reset                     
);

	PH1P_PHY_PLL_V2 #(
    .FBKCLK                 (FBKCLK),
    .FBKCLK_INT             (FBKCLK_INT),
    .FIN                    (FIN),
//loop     parameter
    .REFCLK_DIV             (REFCLK_DIV),
    .FBCLK_DIV              (FBCLK_DIV),
//fine phase shift
    .CLKC0_FPHASE           (CLKC0_FPHASE),
    .CLKC1_FPHASE           (CLKC1_FPHASE),
    .CLKC2_FPHASE           (CLKC2_FPHASE),
    .CLKC3_FPHASE           (CLKC3_FPHASE),
    .CLKC4_FPHASE           (CLKC4_FPHASE),
    .CLKC5_FPHASE           (CLKC5_FPHASE),
    .CLKC6_FPHASE           (CLKC6_FPHASE),
//coarse phase shift
    .PREDIV_MUXC0           (PREDIV_MUXC0),
    .PREDIV_MUXC1           (PREDIV_MUXC1),
    .PREDIV_MUXC2           (PREDIV_MUXC2),
    .PREDIV_MUXC3           (PREDIV_MUXC3),
    .PREDIV_MUXC4           (PREDIV_MUXC4),
    .PREDIV_MUXC5           (PREDIV_MUXC5),
    .PREDIV_MUXC6           (PREDIV_MUXC6),

    .CLKC0_CPHASE           (CLKC0_CPHASE),
    .CLKC1_CPHASE           (CLKC1_CPHASE),
    .CLKC2_CPHASE           (CLKC2_CPHASE),
    .CLKC3_CPHASE           (CLKC3_CPHASE),
    .CLKC4_CPHASE           (CLKC4_CPHASE),
    .CLKC5_CPHASE           (CLKC5_CPHASE),
    .CLKC6_CPHASE           (CLKC6_CPHASE),
//output divider
    .CLKC0_DIV              (CLKC0_DIV),
    .CLKC1_DIV              (CLKC1_DIV),
    .CLKC2_DIV              (CLKC2_DIV),
    .CLKC3_DIV              (CLKC3_DIV),
    .CLKC4_DIV              (CLKC4_DIV),
    .CLKC5_DIV              (CLKC5_DIV),
    .CLKC6_DIV              (CLKC6_DIV),
// duty
    .CLKC0_DUTY_INT         (CLKC0_DUTY_INT),
    .CLKC1_DUTY_INT         (CLKC1_DUTY_INT),
    .CLKC2_DUTY_INT         (CLKC2_DUTY_INT),
    .CLKC3_DUTY_INT         (CLKC3_DUTY_INT),
    .CLKC4_DUTY_INT         (CLKC4_DUTY_INT),
    .CLKC5_DUTY_INT         (CLKC5_DUTY_INT),
    .CLKC6_DUTY_INT         (CLKC6_DUTY_INT),
// clk output
    .DIVOUT_MUXC0           (DIVOUT_MUXC0),
    .DIVOUT_MUXC1           (DIVOUT_MUXC1),
    .DIVOUT_MUXC2           (DIVOUT_MUXC2),
    .DIVOUT_MUXC3           (DIVOUT_MUXC3),
    .DIVOUT_MUXC4           (DIVOUT_MUXC4),
    .DIVOUT_MUXC5           (DIVOUT_MUXC5),
    .DIVOUT_MUXC6           (DIVOUT_MUXC6),

    .CLKC0_ENABLE           (CLKC0_ENABLE),
    .CLKC1_ENABLE           (CLKC1_ENABLE),
    .CLKC2_ENABLE           (CLKC2_ENABLE),
    .CLKC3_ENABLE           (CLKC3_ENABLE),
    .CLKC4_ENABLE           (CLKC4_ENABLE),
    .CLKC5_ENABLE           (CLKC5_ENABLE),
    .CLKC6_ENABLE           (CLKC6_ENABLE),

    .WORK_MODE              (WORK_MODE),

    .PD_DIG                 (PD_DIG),
    .PLL_USR_RST            (PLL_USR_RST),
    .PLL_FEED_TYPE          (PLL_FEED_TYPE),
    .PLL_FASTLOOP           (PLL_FASTLOOP),

// loop     parameter
    .LPF_RES                (LPF_RES),
    .LPF_CAP                (LPF_CAP),
    .ICP_CUR                (ICP_CUR),
//frac-N
    .FRAC_ENABLE            (FRAC_ENABLE),
    .SDM_FRAC               (SDM_FRAC),

//fine phase shift
    .PHASE_PATH_SEL         (PHASE_PATH_SEL),
    .DYN_PHASE_PATH_SEL     (DYN_PHASE_PATH_SEL),
    .DYN_FPHASE_EN          (DYN_FPHASE_EN),

    .CLKC0_FPHASE_RSTSEL    (CLKC0_FPHASE_RSTSEL),
    .CLKC1_FPHASE_RSTSEL    (CLKC1_FPHASE_RSTSEL),
    .CLKC2_FPHASE_RSTSEL    (CLKC2_FPHASE_RSTSEL),
    .CLKC3_FPHASE_RSTSEL    (CLKC3_FPHASE_RSTSEL),
    .CLKC4_FPHASE_RSTSEL    (CLKC4_FPHASE_RSTSEL),
    .CLKC5_FPHASE_RSTSEL    (CLKC5_FPHASE_RSTSEL),
    .CLKC6_FPHASE_RSTSEL    (CLKC6_FPHASE_RSTSEL),

    .CLKC0_DUTY50           (CLKC0_DUTY50),
    .CLKC1_DUTY50           (CLKC1_DUTY50),
    .CLKC2_DUTY50           (CLKC2_DUTY50),
    .CLKC3_DUTY50           (CLKC3_DUTY50),
    .CLKC4_DUTY50           (CLKC4_DUTY50),
    .CLKC5_DUTY50           (CLKC5_DUTY50),
    .CLKC6_DUTY50           (CLKC6_DUTY50),
//ssc
    .SSC_ENABLE             (SSC_ENABLE),
    .SSC_RST                (SSC_RST),
    .SSC_MODE               (SSC_MODE),
    .SSC_FREQ_DIV           (SSC_FREQ_DIV),
    .SSC_RNGE               (SSC_RNGE),

// lock detector
    .REFCLK_DET_BYP         (REFCLK_DET_BYP),
//channel 0 frac div related
    .CLKC0_FRAC_EN          (CLKC0_FRAC_EN),
    .CLKC0_FRAC             (CLKC0_FRAC),
    .PI_OUT_SEL             (PI_OUT_SEL),
    .PI_FRAC_EN             (PI_FRAC_EN),
    .CLKC0_PI_SHIFT_EN      (CLKC0_PI_SHIFT_EN),

    .FEEDBK_MODE            (FEEDBK_MODE),
    .DYN_CPHASE_EN          (DYN_CPHASE_EN)
	) u_PH1P_PHY_PLL (
		.refclk			( refclk		),
		.refclk_rst		( refclk_rst	),
		.fbclk			( fbclk			),
		.clkc			({clk6_out,clk5_out,clk4_out,clk3_out,clk2_out,clk1_out,clk0_out}),
		.clkcb			({clkb6_out,clkb5_out,clkb4_out,clkb3_out,clkb2_out,clkb1_out,clkb0_out}),
		.lock			( lock			),
		.pllreset		( reset  		),
		.clkc_rst		( clkc_rst		),
		.clkc_en		({clk6_en,clk5_en,clk4_en,clk3_en,clk2_en,clk1_en,clk0_en}),
		.wakeup			( wakeup		),
		.cps_step		( cps_step		),
		.pllpd			( pllpd			),
		.drp_clk		( drp_clk		),
		.drp_rstn		( drp_rstn		),
		.drp_sel		( drp_sel		),
		.drp_rd			( drp_rd		),
		.drp_wr			( drp_wr		),
		.drp_addr		( drp_addr		),
		.drp_wdata		( drp_wdata		),
		.drp_err		( drp_err		),
		.drp_rdy		( drp_rdy		),
		.drp_rdata		( drp_rdata		),
		.psdone			( psdone		),
		.psclk			( psclk			),
		.psdown			( psdown		),
		.psstep			( psstep		),
		.psclksel		( psclksel		),
		.ssc_reset		( ssc_reset		),
        .scan_clk       ( 1'b1          ),
        .scan_enable    ( 1'b1          ),
        .scan_mode      ( 1'b0          ),
        .scan_resetn    ( 1'b1          )
	);

endmodule




//======================================================================
//  pll_eth -- 50 MHz in, 125 MHz and 125 MHz shifted 90 degrees out.
//  Verbatim copy of the vendor generated wrapper from the
//  33_ethernet_udp_led example (VCO 875 MHz, C0 = /7, C1 = /7 + 90 deg),
//  only the module name changed.
//======================================================================
module pll_eth
(
  input                         refclk,
  input                         reset,
  output                        clk_125,
  output                        clk_125_90,
  output                        lock
);
  wire clk0_buf;

  PH1P_LOGIC_BUFG bufg_feedback (
    .i(clk0_buf),
    .o(clk_125)
  );

  ph1p_phy_pll_wrapper_d2616deaaa79
  #(
      .FBKCLK("CLKC0_EXT"),
      .FBKCLK_INT("CLKC0_EXT"),
      .FIN("50.000000000"),
      .REFCLK_DIV(2),
      .FBCLK_DIV(5),
      .CLKC0_ENABLE("ENABLE"),
      .CLKC0_DIV(7),
      .CLKC0_CPHASE(6),
      .CLKC0_FPHASE(0),
      .CLKC0_FPHASE_RSTSEL(0),
      .CLKC0_DUTY50("ENABLE"),
      .CLKC0_DUTY_INT(4),
      .CLKC1_ENABLE("ENABLE"),
      .CLKC1_DIV(7),
      .CLKC1_CPHASE(0),
      .CLKC1_FPHASE(6),
      .CLKC1_FPHASE_RSTSEL(1),
      .CLKC1_DUTY50("ENABLE"),
      .CLKC1_DUTY_INT(4),
      .CLKC2_ENABLE("DISABLE"),
      .CLKC3_ENABLE("DISABLE"),
      .CLKC4_ENABLE("DISABLE"),
      .CLKC5_ENABLE("DISABLE"),
      .CLKC6_ENABLE("DISABLE"),
      .PLL_USR_RST("ENABLE"),
      .PLL_FEED_TYPE("EXTERNAL"),
      .PLL_FASTLOOP("ENABLE"),
      .LPF_RES(0),
      .LPF_CAP(13),
      .ICP_CUR(29),
      .PHASE_PATH_SEL(0),
      .DYN_PHASE_PATH_SEL("DISABLE"),
      .DYN_FPHASE_EN("DISABLE"),
      .PI_OUT_SEL("NORMAL"),
      .PI_FRAC_EN("DISABLE"),
      .CLKC0_PI_SHIFT_EN("DISABLE"),
      .FEEDBK_MODE("NORMAL"),
      .DYN_CPHASE_EN("DISABLE")
  ) u_pll
  (
      .clk1_en(1'b1),
      .clk1_out(clk_125_90),
      .clkb1_out(),
      .clk2_en(1'b0),
      .clk2_out(),
      .clkb2_out(),
      .clk3_en(1'b0),
      .clk3_out(),
      .clkb3_out(),
      .clk4_en(1'b0),
      .clk4_out(),
      .clkb4_out(),
      .clk5_en(1'b0),
      .clk5_out(),
      .clkb5_out(),
      .clk6_en(1'b0),
      .clk6_out(),
      .clkb6_out(),
      .refclk(refclk),
      .drp_clk(1'b0),
      .drp_rstn(1'b1),
      .drp_sel(1'b0),
      .drp_rd(1'b0),
      .drp_wr(1'b0),
      .drp_addr(8'b00000000),
      .drp_wdata(8'b00000000),
      .drp_err(),
      .drp_rdy(),
      .drp_rdata(),
      .psclk(1'b0),
      .psclksel(3'b000),
      .psstep(1'b0),
      .psdown(1'b0),
      .cps_step(1'b0),
      .psdone(),
      .ssc_reset(1'b0),
      .clkc_rst(2'b00),
      .pllpd(1'b0),
      .fbclk(clk_125),
      .wakeup(1'b1),
      .refclk_rst(1'b0),
      .clk0_en(1'b1),
      .clkb0_out(),
      .clk0_out(clk0_buf),
      .lock(lock),
      .reset(reset)
  );
endmodule

// ===========================================================================
//  axis_cartoon_rgb96 -- æ‰©å±•è¦æ±‚1 çš„å¡é€šåŒ–ï¼šå½©è‰²å›¾ + é»‘è‰²è½®å»“çº¿
//
//  Follows the reference chain "è¾¹ç¼˜æ£€æµ‹ -> åŒºåŸŸå¡«å……/é¢œè‰²é‡åŒ–":
//     * the colour image is posterised (the two LSBs are dropped), which is the
//       "é¢œè‰²é‡åŒ–" step and is free in hardware,
//     * every pixel that the edge detector marked as an edge is painted black,
//       which draws the outline the reference picture shows.
//
//  The colour stream is delayed by one cycle so it lines up with the edge map
//  (edge_detect_* registers its result once).
// ===========================================================================
module axis_cartoon_rgb96 #(
    parameter integer QUANT_LSB = 2,      // 0 = off, 2 = keep 6 bits per channel
    parameter [7:0]   DZ_T1   = 8'd12,   // dead zone: at or below this nothing changes
    parameter [7:0]   DZ_T2   = 8'd48    // above this the stronger gain is used
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [95:0] I_col_tdata,      // colour image (same tap as the detector)
    input  wire [95:0] I_edge_tdata,     // edge map, one cycle behind the colour
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire        I_tvalid,
    output reg  [95:0] O_tdata,
    output reg         O_tlast,
    output reg         O_tuser,
    output reg         O_tvalid
);

    // ------------------------------------------------------------------
    //  adaptive dead zone
    //
    //  A fixed threshold cannot work on a live picture: a pale wall sits at a
    //  few levels of chroma and a real colour at tens of levels, and both move
    //  with the exposure and the noise.  A fixed 12 blocked 90% of a live frame,
    //  which is why the colour looked unchanged.  The threshold now follows the
    //  previous frame's own mean chroma: 1.35x mean, clamped to 10..64.
    // ------------------------------------------------------------------
    reg  [ 7:0] dz_t1 = 8'd16;

    // posterise: drop the low bits
    function [7:0] quant;
        input [7:0] c;
        begin
            quant = (QUANT_LSB == 0) ? c : ((c >> QUANT_LSB) << QUANT_LSB);
        end
    endfunction

    // ------------------------------------------------------------------
    //  dead-zone chroma amplification - the "vivid" half of the cartoon mode
    //
    //  The reference is the green channel and green is never modified:
    //      d  = c - G                    (R and B only)
    //      m  = max(|dR|, |dB|)
    //      m <= DZ_T1   ->  c' = c                  (bit exact)
    //      m <= DZ_T2   ->  c' = G + 1.75*d         (d + d/2 + d/4)
    //      else         ->  c' = G + 2.00*d         (d + d)
    //
    //  A pixel that is already close to neutral (a wall, paper, the pink
    //  shading in the corners) is therefore passed through unchanged, bit for
    //  bit, and only pixels that really carry colour get more of it.  R and B
    //  use the same gain, so the hue of a pixel is preserved and no colour
    //  that was not in the picture can appear.  Compares, adds and shifts
    //  only - there is no multiplier in this path.
    // ------------------------------------------------------------------
    function [7:0] f_absd;
        input [7:0] c;
        input [7:0] g;
        reg signed [9:0] d;
        begin
            d = $signed({1'b0,c}) - $signed({1'b0,g});
            f_absd = d[9] ? (8'd0 - d[7:0]) : d[7:0];
        end
    endfunction

    // max(|R-G|,|B-G|) of one pixel
    function [7:0] f_m;
        input [23:0] c;
        reg [7:0] a, b;
        begin
            a = f_absd(c[23:16], c[15:8]);
            b = f_absd(c[ 7: 0], c[15:8]);
            f_m = (a > b) ? a : b;
        end
    endfunction

    function [7:0] f_amp;
        input [7:0] c;
        input [7:0] g;
        input [7:0] m;
        reg signed [ 9:0] d;
        reg signed [11:0] p;
        reg signed [12:0] o;
        begin
            d = $signed({1'b0,c}) - $signed({1'b0,g});
            if (m <= dz_t1)
                p = d;                              // x1.00, bit exact
            else if (m <= DZ_T2)
                p = d + d + (d >>> 2);               // x2.25
            else
                p = d + d + (d >>> 1);               // x2.50
            o = $signed({1'b0,g}) + p;
            if (o > 13'sd255)
                f_amp = 8'd255;
            else if (o < 13'sd0)
                f_amp = 8'd0;
            else
                f_amp = o[7:0];
        end
    endfunction

    function [23:0] amp_px;
        input [23:0] c;
        reg [7:0] m;
        begin
            m = f_m(c);
            amp_px = { f_amp(c[23:16], c[15:8], m),
                        c[15:8],
                       f_amp(c[ 7: 0], c[15:8], m) };
        end
    endfunction

    // black where the edge map is set, colour otherwise
    function [23:0] cartoon_px;
        input [23:0] c;
        input [23:0] e;
        begin
            if (e[23:16] != 8'd0 || e[15:8] != 8'd0 || e[7:0] != 8'd0)
                cartoon_px = 24'd0;
            else
                cartoon_px = {quant(c[23:16]), quant(c[15:8]), quant(c[7:0])};
        end
    endfunction
    // ------------------------------------------------------------------
    //  two register stages between the colour input and the output
    //
    //  The detector has one pipeline stage of its own now, so the edge map
    //  arrives two beats behind the colour instead of one.  col_d1 holds the
    //  colour one beat, amp_d holds the amplified colour two beats, which is
    //  exactly the pixel I_edge_tdata describes.  Putting amp_px between those
    //  two registers also splits the dead-zone arithmetic into two short paths
    //  instead of one long one (the same 103.52 MHz clock that the detector
    //  just failed on).
    // ------------------------------------------------------------------
    reg [95:0] col_d1;
    reg [95:0] amp_d;
    reg        v_d1, l_d1, u_d1;
    reg        v_d2, l_d2, u_d2;

    wire [95:0] amp_w = { amp_px(col_d1[95:72]),
                          amp_px(col_d1[71:48]),
                          amp_px(col_d1[47:24]),
                          amp_px(col_d1[23: 0]) };

    // frame statistic for the dead zone, one register deep so the adder tree
    // does not sit on the same path as the gain
    wire [9:0]  m_beat  = {2'b0, f_m(col_d1[95:72])} + {2'b0, f_m(col_d1[71:48])}
                        + {2'b0, f_m(col_d1[47:24])} + {2'b0, f_m(col_d1[23: 0])};
    reg  [9:0]  m_beat_q;
    reg  [31:0] m_sum;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            col_d1   <= 96'd0;
            amp_d    <= 96'd0;
            m_beat_q <= 10'd0;
            v_d1     <= 1'b0;
            l_d1     <= 1'b0;
            u_d1     <= 1'b0;
            v_d2     <= 1'b0;
            l_d2     <= 1'b0;
            u_d2     <= 1'b0;
            O_tdata  <= 96'd0;
            O_tlast  <= 1'b0;
            O_tuser  <= 1'b0;
            O_tvalid <= 1'b0;
        end else begin
            col_d1 <= I_col_tdata;
            v_d1   <= I_tvalid;
            l_d1   <= I_tlast;
            u_d1   <= I_tuser;

            amp_d  <= amp_w;
            m_beat_q <= m_beat;
            v_d2   <= v_d1;
            l_d2   <= l_d1;
            u_d2   <= u_d1;

            O_tlast  <= l_d2;
            O_tuser  <= u_d2;
            O_tvalid <= v_d2;
            if (v_d2)
                O_tdata <= {
                    cartoon_px(amp_d[95:72], I_edge_tdata[95:72]),
                    cartoon_px(amp_d[71:48], I_edge_tdata[71:48]),
                    cartoon_px(amp_d[47:24], I_edge_tdata[47:24]),
                    cartoon_px(amp_d[23: 0], I_edge_tdata[23: 0])
                };
            else
                O_tdata <= 96'd0;
        end
    end

    // ------------------------------------------------------------------
    //  dz_t1 follows the picture.  A 1280x367 frame is 469760 pixels, so
    //     mean = sum >> 19  (the shift is 0.89 x the true mean)
    //  and 1.35 x mean is (sum>>19) + (sum>>20).  The result is clamped so a
    //  black frame cannot amplify noise and a colourful one keeps protection.
    // ------------------------------------------------------------------
    wire [31:0] dz_new = (m_sum >> 19) + (m_sum >> 20);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            m_sum <= 32'd0;
            dz_t1 <= 8'd16;
        end else if (I_tuser) begin
            m_sum <= 32'd0;
            if (dz_new < 32'd10)
                dz_t1 <= 8'd10;
            else if (dz_new > 32'd64)
                dz_t1 <= 8'd64;
            else
                dz_t1 <= dz_new[7:0];
        end else if (v_d1) begin
            m_sum <= m_sum + m_beat_q;
        end
    end

endmodule
