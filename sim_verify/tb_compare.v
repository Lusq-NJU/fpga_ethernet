`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// 模块: tb_compare
// 功能: 同一激励下对比 ethernet_tx_pack(原版) 与 ethernet_tx_pack_ref(修正版)
// 用例: CASE1 文档举例 / CASE2 奇数长度(mty=1) / CASE3 背靠背 / CASE4 长包
//////////////////////////////////////////////////////////////////////////////////

module tb_compare;

    reg             clk         ;
    reg             rst_n       ;
    reg     [15:0]  cfg_sport   ;
    reg     [15:0]  cfg_dport   ;
    reg     [31:0]  cfg_sip     ;
    reg     [31:0]  cfg_dip     ;
    reg     [47:0]  cfg_smac    ;
    reg     [47:0]  cfg_dmac    ;
    reg     [15:0]  tx_data     ;
    reg             tx_vld      ;
    reg             tx_sop      ;
    reg             tx_eop      ;
    reg             tx_mty      ;
    reg             dout_rdy    ;

    wire            tx_rdy_a    ;
    wire    [15:0]  dout_data_a ;
    wire            dout_vld_a  ;
    wire            dout_sop_a  ;
    wire            dout_eop_a  ;
    wire            dout_mty_a  ;

    wire            tx_rdy_b    ;
    wire    [15:0]  dout_data_b ;
    wire            dout_vld_b  ;
    wire            dout_sop_b  ;
    wire            dout_eop_b  ;
    wire            dout_mty_b  ;

    // 原版
    ethernet_tx_pack u_orig (
        .clk(clk), .rst_n(rst_n),
        .cfg_sport(cfg_sport), .cfg_dport(cfg_dport),
        .cfg_sip(cfg_sip), .cfg_dip(cfg_dip),
        .cfg_smac(cfg_smac), .cfg_dmac(cfg_dmac),
        .tx_data(tx_data), .tx_vld(tx_vld), .tx_sop(tx_sop), .tx_eop(tx_eop), .tx_mty(tx_mty),
        .tx_rdy(tx_rdy_a), .dout_rdy(dout_rdy),
        .dout_data(dout_data_a), .dout_vld(dout_vld_a), .dout_sop(dout_sop_a),
        .dout_eop(dout_eop_a), .dout_mty(dout_mty_a)
    );

    // 修正版
    ethernet_tx_pack_ref u_ref (
        .clk(clk), .rst_n(rst_n),
        .cfg_sport(cfg_sport), .cfg_dport(cfg_dport),
        .cfg_sip(cfg_sip), .cfg_dip(cfg_dip),
        .cfg_smac(cfg_smac), .cfg_dmac(cfg_dmac),
        .tx_data(tx_data), .tx_vld(tx_vld), .tx_sop(tx_sop), .tx_eop(tx_eop), .tx_mty(tx_mty),
        .tx_rdy(tx_rdy_b), .dout_rdy(dout_rdy),
        .dout_data(dout_data_b), .dout_vld(dout_vld_b), .dout_sop(dout_sop_b),
        .dout_eop(dout_eop_b), .dout_mty(dout_mty_b)
    );

    // 时钟 100MHz
    initial clk = 0;
    always #5 clk = ~clk;

    //--------------------------------------------------------------
    // 输出监控
    //--------------------------------------------------------------
    integer pa, wa, pb, wb;

    always @(posedge clk) begin
        if (rst_n && dout_vld_a) begin
            $display("ORIG P%0d W%0d %04h s%b e%b m%b", pa, wa, dout_data_a, dout_sop_a, dout_eop_a, dout_mty_a);
            wa = wa + 1;
            if (dout_eop_a) begin
                $display("ORIG P%0d END n=%0d", pa, wa);
                pa = pa + 1; wa = 0;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && dout_vld_b) begin
            $display("REF  P%0d W%0d %04h s%b e%b m%b", pb, wb, dout_data_b, dout_sop_b, dout_eop_b, dout_mty_b);
            wb = wb + 1;
            if (dout_eop_b) begin
                $display("REF  P%0d END n=%0d", pb, wb);
                pb = pb + 1; wb = 0;
            end
        end
    end

    // 调试：观察 FIFO 与状态机（仅第一个包）
    always @(posedge clk) begin
        if (rst_n && ($time > 150 && $time < 800) &&
            (u_ref.r_state_c == 3 || u_ref.r_state_c == 4)) begin
            $display("DBG t=%0t st=%0d rd=%b dout=%h emp=%b mrd=%b mdl=%0d",
                     $time, u_ref.r_state_c, u_ref.w_data_rd_en, u_ref.w_data_dout,
                     u_ref.w_data_empty, u_ref.w_message_rd_en, u_ref.w_data_dout[17]);
        end
    end

    //--------------------------------------------------------------
    task tx_word(input [15:0] d, input sop, input eop, input mty);
        begin
            @(negedge clk);
            tx_data = d; tx_sop = sop; tx_eop = eop; tx_mty = mty; tx_vld = 1'b1;
        end
    endtask

    task tx_idle(input integer n);
        begin
            @(negedge clk);
            tx_vld = 1'b0; tx_sop = 1'b0; tx_eop = 1'b0; tx_mty = 1'b0; tx_data = 16'h0;
            repeat (n) @(negedge clk);
        end
    endtask

    integer i;
    //--------------------------------------------------------------
    initial begin
        rst_n     = 1'b0;
        tx_data   = 16'h0;
        tx_vld    = 1'b0;
        tx_sop    = 1'b0;
        tx_eop    = 1'b0;
        tx_mty    = 1'b0;
        dout_rdy  = 1'b1;
        pa = 0; wa = 0; pb = 0; wb = 0;

        cfg_dmac  = 48'h0102_0304_0506;
        cfg_smac  = 48'h2c02_0304_0507;
        cfg_sip   = 32'hc0a8_010a;
        cfg_dip   = 32'hc0a8_0109;
        cfg_sport = 16'h1388;
        cfg_dport = 16'h0bb8;

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (5)  @(negedge clk);

        // CASE1: 文档举例
        $display("==== CASE1 doc example ====");
        tx_word(16'h000a, 1'b1, 1'b0, 1'b0);
        tx_word(16'h0001, 1'b0, 1'b0, 1'b0);
        tx_word(16'h0014, 1'b0, 1'b1, 1'b0);
        tx_idle(60);

        // CASE2: 奇数长度 mty=1
        $display("==== CASE2 mty=1 ====");
        tx_word(16'h0011, 1'b1, 1'b0, 1'b0);
        tx_word(16'h2200, 1'b0, 1'b1, 1'b1);
        tx_idle(60);

        // CASE3: 背靠背两包
        $display("==== CASE3 back-to-back ====");
        tx_word(16'haaaa, 1'b1, 1'b1, 1'b0);
        tx_word(16'hbbbb, 1'b1, 1'b1, 1'b0);
        tx_idle(60);

        // CASE4: 长包 64 字 = 128 字节
        $display("==== CASE4 long packet ====");
        for (i = 0; i < 64; i = i + 1) begin
            if (i == 0)
                tx_word(16'h0101 + i[15:0], 1'b1, 1'b0, 1'b0);
            else if (i == 63)
                tx_word(16'h0101 + i[15:0], 1'b0, 1'b1, 1'b0);
            else
                tx_word(16'h0101 + i[15:0], 1'b0, 1'b0, 1'b0);
        end
        tx_idle(200);

        // CASE5: dout_rdy 中途暂停/恢复
        $display("==== CASE5 rdy pause ====");
        dout_rdy = 1'b1;
        tx_word(16'h1234, 1'b1, 1'b0, 1'b0);
        tx_word(16'h5678, 1'b0, 1'b1, 1'b0);
        tx_idle(1);
        repeat (8) @(negedge clk);       // 等状态机进入包头发送
        dout_rdy = 1'b0;                 // 中途拉低 rdy
        repeat (12) @(negedge clk);
        dout_rdy = 1'b1;                 // 恢复
        tx_idle(150);

        $display("==== SIM DONE ====");
        $finish;
    end

    initial begin
        #200000;
        $display("==== TIMEOUT ====");
        $finish;
    end

endmodule
