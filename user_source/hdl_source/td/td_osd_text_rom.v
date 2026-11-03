//==============================================================================
//  td_osd_text_rom.v   —— 由 tools/gen_osd_rom.py 自动生成，请勿手工修改
//
//  信息面板字符表：7 行 x 24 列。
//  代码约定：0x00-0x7F 直接是 ASCII；0x80+n 为十进制数字槽 n；
//            0xB0-0xB5 为形状名称字符；0xB6 为主目标类别字母。
//==============================================================================

module td_osd_text_rom (
    input  wire [2:0] I_row,
    input  wire [4:0] I_col,
    output reg  [7:0] O_char
);

    always @(*) begin
        case ({I_row, I_col})
            // ---------- 第 0 行 ----------
            8'h00: O_char = 8'h54;   // 'T'
            8'h01: O_char = 8'h41;   // 'A'
            8'h02: O_char = 8'h52;   // 'R'
            8'h03: O_char = 8'h47;   // 'G'
            8'h04: O_char = 8'h45;   // 'E'
            8'h05: O_char = 8'h54;   // 'T'
            8'h07: O_char = 8'h43;   // 'C'
            8'h08: O_char = 8'h4E;   // 'N'
            8'h09: O_char = 8'h54;   // 'T'
            8'h0A: O_char = 8'h3A;   // ':'
            8'h0D: O_char = 8'h97;   // 数字槽 23
            8'h0E: O_char = 8'h96;   // 数字槽 22
            // ---------- 第 1 行 ----------
            8'h20: O_char = 8'h52;   // 'R'
            8'h21: O_char = 8'h3A;   // ':'
            8'h22: O_char = 8'h99;   // 数字槽 25
            8'h23: O_char = 8'h98;   // 数字槽 24
            8'h25: O_char = 8'h47;   // 'G'
            8'h26: O_char = 8'h3A;   // ':'
            8'h27: O_char = 8'h9B;   // 数字槽 27
            8'h28: O_char = 8'h9A;   // 数字槽 26
            8'h2A: O_char = 8'h42;   // 'B'
            8'h2B: O_char = 8'h3A;   // ':'
            8'h2C: O_char = 8'h9D;   // 数字槽 29
            8'h2D: O_char = 8'h9C;   // 数字槽 28
            8'h2F: O_char = 8'h59;   // 'Y'
            8'h30: O_char = 8'h3A;   // ':'
            8'h31: O_char = 8'h9F;   // 数字槽 31
            8'h32: O_char = 8'h9E;   // 数字槽 30
            // ---------- 第 2 行 ----------
            8'h40: O_char = 8'h54;   // 'T'
            8'h41: O_char = 8'h31;   // '1'
            8'h43: O_char = 8'hB6;   // 动态码 0xB6
            8'h45: O_char = 8'hB0;   // 动态码 0xB0
            8'h46: O_char = 8'hB1;   // 动态码 0xB1
            8'h47: O_char = 8'hB2;   // 动态码 0xB2
            8'h48: O_char = 8'hB3;   // 动态码 0xB3
            8'h49: O_char = 8'hB4;   // 动态码 0xB4
            8'h4A: O_char = 8'hB5;   // 动态码 0xB5
            // ---------- 第 3 行 ----------
            8'h60: O_char = 8'h58;   // 'X'
            8'h61: O_char = 8'h3A;   // ':'
            8'h62: O_char = 8'h89;   // 数字槽 9
            8'h63: O_char = 8'h88;   // 数字槽 8
            8'h64: O_char = 8'h87;   // 数字槽 7
            8'h65: O_char = 8'h86;   // 数字槽 6
            8'h67: O_char = 8'h59;   // 'Y'
            8'h68: O_char = 8'h3A;   // ':'
            8'h69: O_char = 8'h8D;   // 数字槽 13
            8'h6A: O_char = 8'h8C;   // 数字槽 12
            8'h6B: O_char = 8'h8B;   // 数字槽 11
            8'h6C: O_char = 8'h8A;   // 数字槽 10
            // ---------- 第 4 行 ----------
            8'h80: O_char = 8'h57;   // 'W'
            8'h81: O_char = 8'h3A;   // ':'
            8'h82: O_char = 8'h91;   // 数字槽 17
            8'h83: O_char = 8'h90;   // 数字槽 16
            8'h84: O_char = 8'h8F;   // 数字槽 15
            8'h85: O_char = 8'h8E;   // 数字槽 14
            8'h87: O_char = 8'h48;   // 'H'
            8'h88: O_char = 8'h3A;   // ':'
            8'h89: O_char = 8'h95;   // 数字槽 21
            8'h8A: O_char = 8'h94;   // 数字槽 20
            8'h8B: O_char = 8'h93;   // 数字槽 19
            8'h8C: O_char = 8'h92;   // 数字槽 18
            // ---------- 第 5 行 ----------
            8'hA0: O_char = 8'h41;   // 'A'
            8'hA1: O_char = 8'h52;   // 'R'
            8'hA2: O_char = 8'h45;   // 'E'
            8'hA3: O_char = 8'h41;   // 'A'
            8'hA4: O_char = 8'h3A;   // ':'
            8'hA5: O_char = 8'h85;   // 数字槽 5
            8'hA6: O_char = 8'h84;   // 数字槽 4
            8'hA7: O_char = 8'h83;   // 数字槽 3
            8'hA8: O_char = 8'h82;   // 数字槽 2
            8'hA9: O_char = 8'h81;   // 数字槽 1
            8'hAA: O_char = 8'h80;   // 数字槽 0
            // ---------- 第 6 行 ----------
            8'hC0: O_char = 8'h43;   // 'C'
            8'hC1: O_char = 8'h4F;   // 'O'
            8'hC2: O_char = 8'h4C;   // 'L'
            8'hC3: O_char = 8'h4F;   // 'O'
            8'hC4: O_char = 8'h52;   // 'R'
            8'hC6: O_char = 8'h53;   // 'S'
            8'hC7: O_char = 8'h48;   // 'H'
            8'hC8: O_char = 8'h41;   // 'A'
            8'hC9: O_char = 8'h50;   // 'P'
            8'hCA: O_char = 8'h45;   // 'E'
            8'hCC: O_char = 8'h31;   // '1'
            8'hCD: O_char = 8'h32;   // '2'
            8'hCE: O_char = 8'h38;   // '8'
            8'hCF: O_char = 8'h30;   // '0'
            8'hD0: O_char = 8'h58;   // 'X'
            8'hD1: O_char = 8'h37;   // '7'
            8'hD2: O_char = 8'h32;   // '2'
            8'hD3: O_char = 8'h30;   // '0'
            default: O_char = 8'h20;
        endcase
    end

endmodule
