//==============================================================================
//  td_tag_font.v   —— 由 tools/gen_osd_rom.py 自动生成，请勿手工修改
//
//  检测框类别标签用的 4 个 16x16 点阵字母：R/G/B/Y
//  （点阵数据取自工程自带的 osd_char_lib.v，保证与面板字体风格一致）
//==============================================================================

module td_tag_font (
    input  wire [1:0]  I_cls,
    input  wire [3:0]  I_row,
    output reg  [15:0] O_bits
);

    always @(*) begin
        case ({I_cls, I_row})
            // ---------- R ----------
            6'd0: O_bits = 16'h0000;
            6'd1: O_bits = 16'h0000;
            6'd2: O_bits = 16'h3e00;
            6'd3: O_bits = 16'h3300;
            6'd4: O_bits = 16'h3300;
            6'd5: O_bits = 16'h3300;
            6'd6: O_bits = 16'h3c00;
            6'd7: O_bits = 16'h3600;
            6'd8: O_bits = 16'h3600;
            6'd9: O_bits = 16'h3200;
            6'd10: O_bits = 16'h0000;
            6'd11: O_bits = 16'h0000;
            6'd12: O_bits = 16'h0000;
            6'd13: O_bits = 16'h0000;
            6'd14: O_bits = 16'h0000;
            6'd15: O_bits = 16'h0000;
            // ---------- G ----------
            6'd16: O_bits = 16'h0000;
            6'd17: O_bits = 16'h0000;
            6'd18: O_bits = 16'h1c00;
            6'd19: O_bits = 16'h3200;
            6'd20: O_bits = 16'h6000;
            6'd21: O_bits = 16'h6000;
            6'd22: O_bits = 16'h6e00;
            6'd23: O_bits = 16'h6600;
            6'd24: O_bits = 16'h3600;
            6'd25: O_bits = 16'h1e00;
            6'd26: O_bits = 16'h0000;
            6'd27: O_bits = 16'h0000;
            6'd28: O_bits = 16'h0000;
            6'd29: O_bits = 16'h0000;
            6'd30: O_bits = 16'h0000;
            6'd31: O_bits = 16'h0000;
            // ---------- B ----------
            6'd32: O_bits = 16'h0000;
            6'd33: O_bits = 16'h0000;
            6'd34: O_bits = 16'h3e00;
            6'd35: O_bits = 16'h3300;
            6'd36: O_bits = 16'h3300;
            6'd37: O_bits = 16'h3e00;
            6'd38: O_bits = 16'h3300;
            6'd39: O_bits = 16'h3300;
            6'd40: O_bits = 16'h3300;
            6'd41: O_bits = 16'h3e00;
            6'd42: O_bits = 16'h0000;
            6'd43: O_bits = 16'h0000;
            6'd44: O_bits = 16'h0000;
            6'd45: O_bits = 16'h0000;
            6'd46: O_bits = 16'h0000;
            6'd47: O_bits = 16'h0000;
            // ---------- Y ----------
            6'd48: O_bits = 16'h0000;
            6'd49: O_bits = 16'h0000;
            6'd50: O_bits = 16'h3180;
            6'd51: O_bits = 16'h1300;
            6'd52: O_bits = 16'h1b00;
            6'd53: O_bits = 16'h1e00;
            6'd54: O_bits = 16'h0c00;
            6'd55: O_bits = 16'h0c00;
            6'd56: O_bits = 16'h0c00;
            6'd57: O_bits = 16'h0c00;
            6'd58: O_bits = 16'h0000;
            6'd59: O_bits = 16'h0000;
            6'd60: O_bits = 16'h0000;
            6'd61: O_bits = 16'h0000;
            6'd62: O_bits = 16'h0000;
            6'd63: O_bits = 16'h0000;
            default: O_bits = 16'h0000;
        endcase
    end

endmodule
