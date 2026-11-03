//==============================================================================
//  td_res_sync.v
//  ---------------------------------------------------------------------------
//  检测结果跨时钟域（摄像头像素时钟 -> HDMI 像素时钟）。
//
//  传输方式：结果总线 I_res 在摄像头域"每帧只改一次"，保持稳定 33ms；
//  发布时翻转 I_tog。HDMI 域用两级同步器采样翻转标志，检测到跳变后把总线
//  打拍进本地快照寄存器 S_snap（此时总线早已稳定，等效于 quasi-static 总线
//  跨域的标准做法）；再等到本域的场同步 I_vsync 才把快照推入 S_act，
//  避免同一显示帧中途换框造成撕裂。
//==============================================================================

module td_res_sync #(
    parameter integer W = 716
)(
    input  wire         I_cam_clk,
    input  wire         I_cam_rst_n,
    input  wire [W-1:0] I_res,
    input  wire         I_tog,

    input  wire         I_pix_clk,
    input  wire         I_pix_rst_n,
    input  wire         I_vsync,
    input  wire         I_update_now,   // 1=收到立即生效（仿真/回环用）
    output reg  [W-1:0] O_res,
    output reg          O_update
);

    //--------------------------------------------------------------------------
    // 摄像头域：总线保持 + 翻转标志（I_res/I_tog 由 td_detector 直接驱动）
    //--------------------------------------------------------------------------
    reg [1:0] S_tog_sync;
    reg       S_tog_seen;
    reg [W-1:0] S_snap;
    reg       S_pending;
    reg [1:0] S_vs_sync;

    always @(posedge I_pix_clk or negedge I_pix_rst_n) begin
        if (!I_pix_rst_n) begin
            S_tog_sync <= 2'b00;
            S_tog_seen <= 1'b0;
            S_snap     <= {W{1'b0}};
            S_pending  <= 1'b0;
            S_vs_sync  <= 2'b00;
            O_res      <= {W{1'b0}};
            O_update   <= 1'b0;
        end
        else begin
            S_tog_sync <= {S_tog_sync[0], I_tog};
            S_vs_sync  <= {S_vs_sync[0], I_vsync};
            O_update   <= 1'b0;

            // 检测到发布翻转：总线此刻及之后一帧内保持不变，可以安全快照
            if (S_tog_sync[1] != S_tog_seen) begin
                S_tog_seen <= S_tog_sync[1];
                S_snap     <= I_res;
                S_pending  <= 1'b1;
            end

            // 场同步上升沿或强制更新时生效
            if ((S_vs_sync[1] & ~S_vs_sync[0]) || I_update_now) begin
                if (S_pending) begin
                    O_res    <= S_snap;
                    O_update <= 1'b1;
                    S_pending <= 1'b0;
                end
            end
        end
    end

endmodule
