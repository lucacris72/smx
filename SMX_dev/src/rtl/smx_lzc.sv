// Copyright (c) 2026 Luca Donato, Tommaso Spagnolo, Cristina Silvano
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module smx_lzc (
    input  logic [7:0] in_i,
    output logic [3:0] cnt_o, // 0..8
    output logic       empty_o
);

    always_comb begin
        empty_o = 1'b0;
        if (in_i[7])      cnt_o = 4'd0;
        else if (in_i[6]) cnt_o = 4'd1;
        else if (in_i[5]) cnt_o = 4'd2;
        else if (in_i[4]) cnt_o = 4'd3;
        else if (in_i[3]) cnt_o = 4'd4;
        else if (in_i[2]) cnt_o = 4'd5;
        else if (in_i[1]) cnt_o = 4'd6;
        else if (in_i[0]) cnt_o = 4'd7;
        else begin
            cnt_o = 4'd8;
            empty_o = 1'b1;
        end
    end

endmodule
