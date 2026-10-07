`timescale 1ns/1ps
module width_test;
    reg  [15:0] a;
    reg  [31:0] r32;
    reg  [39:0] r40;
    initial begin
        a = 16'h0001;
        r32 = {4'hA, a + 1};
        r40 = {4'hA, a + 1};
        $display("r32 = %h   (若为00000002 => 表达式32位; 若为000a0002 => 表达式16位)", r32);
        $display("r40 = %h", r40);
        // 直接用 16 位常量对照
        r32 = {4'hA, a + 16'd1};
        $display("显式16位常量: r32 = %h", r32);
        $display("bits(a+1) 应观察其宽度");
        $finish;
    end
endmodule
