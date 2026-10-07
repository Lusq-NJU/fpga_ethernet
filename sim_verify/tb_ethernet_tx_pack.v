`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// 模块: tb_ethernet_tx_pack
// 功能: 依据《千兆网接口 tx_pack 功能文档》验证 ethernet_tx_pack 模块
//       用例1: 文档第4页举例 —— 输入 0x000a,0x0001,0x0014
//       用例2: 奇数长度包(mty=1)
//       用例3: 背靠背连续两包
//////////////////////////////////////////////////////////////////////////////////

module tb_ethernet_tx_pack;

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
    wire            tx_rdy      ;
    reg             dout_rdy    ;
    wire    [15:0]  dout_data   ;
    wire            dout_vld    ;
    wire            dout_sop    ;
    wire            dout_eop    ;
    wire            dout_mty    ;

    ethernet_tx_pack u_dut (
        .clk        (clk        ),
        .rst_n      (rst_n      ),
        .cfg_sport  (cfg_sport  ),
        .cfg_dport  (cfg_dport  ),
        .cfg_sip    (cfg_sip    ),
        .cfg_dip    (cfg_dip    ),
        .cfg_smac   (cfg_smac   ),
        .cfg_dmac   (cfg_dmac   ),
        .tx_data    (tx_data    ),
        .tx_vld     (tx_vld     ),
        .tx_sop     (tx_sop     ),
        .tx_eop     (tx_eop     ),
        .tx_mty     (tx_mty     ),
        .tx_rdy     (tx_rdy     ),
        .dout_rdy   (dout_rdy   ),
        .dout_data  (dout_data  ),
        .dout_vld   (dout_vld   ),
        .dout_sop   (dout_sop   ),
        .dout_eop   (dout_eop   ),
        .dout_mty   (dout_mty   )
    );

    // 时钟 100MHz
    initial clk = 0;
    always #5 clk = ~clk;

    //--------------------------------------------------------------
    // 输出监控：打印每一拍输出
    //--------------------------------------------------------------
    integer pkt_idx;
    integer wrd_idx;

    always @(posedge clk) begin
        if (rst_n && dout_vld) begin
            $display("PKT%0d WORD%0d = %04h  sop=%b eop=%b mty=%b",
                     pkt_idx, wrd_idx, dout_data, dout_sop, dout_eop, dout_mty);
            wrd_idx = wrd_idx + 1;
            if (dout_eop) begin
                $display("PKT%0d END, total %0d words", pkt_idx, wrd_idx);
                pkt_idx = pkt_idx + 1;
                wrd_idx = 0;
            end
        end
    end

    //--------------------------------------------------------------
    // 发送一拍数据（在 negedge 更新，posedge 被 DUT 采样）
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

    //--------------------------------------------------------------
    // 激励
    //--------------------------------------------------------------
    initial begin
        rst_n     = 1'b0;
        tx_data   = 16'h0;
        tx_vld    = 1'b0;
        tx_sop    = 1'b0;
        tx_eop    = 1'b0;
        tx_mty    = 1'b0;
        dout_rdy  = 1'b1;
        pkt_idx   = 0;
        wrd_idx   = 0;

        // 配置（与文档举例一致）
        cfg_dmac  = 48'h0102_0304_0506;
        cfg_smac  = 48'h2c02_0304_0507;
        cfg_sip   = 32'hc0a8_010a;
        cfg_dip   = 32'hc0a8_0109;
        cfg_sport = 16'h1388;
        cfg_dport = 16'h0bb8;

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (5)  @(negedge clk);

        //==========================================================
        // 用例1: 文档举例, 3 拍数据 0x000a,0x0001,0x0014
        // 期望: MAC 0102 0304 0506 2c02 0304 0507 0800
        //       IP  4500 0022 0000 4000 ff11 f866 c0a8 010a c0a8 0109
        //       UDP 1388 0bb8 000e 5d0f
        //       DAT 000a 0001 0014
        //==========================================================
        $display("---- CASE1: doc example ----");
        tx_word(16'h000a, 1'b1, 1'b0, 1'b0);
        tx_word(16'h0001, 1'b0, 1'b0, 1'b0);
        tx_word(16'h0014, 1'b0, 1'b1, 1'b0);
        tx_idle(1);
        tx_idle(60);

        //==========================================================
        // 用例2: 奇数长度, 2 拍数据, mty=1 (最后一拍 1 字节有效)
        // 数据: 0x0011, 0x2233(mty=1 只发 0x22)
        // 期望: IP ID=1, IP 总长 = 20+8+3 = 31 = 0x001f
        //       UDP 长度 = 0x000b
        //==========================================================
        $display("---- CASE2: odd length (mty=1) ----");
        tx_word(16'h0011, 1'b1, 1'b0, 1'b0);
        tx_word(16'h2200, 1'b0, 1'b1, 1'b1);
        tx_idle(1);
        tx_idle(60);

        //==========================================================
        // 用例3: 背靠背包, 两包各 1 拍
        //==========================================================
        $display("---- CASE3: back-to-back ----");
        tx_word(16'haaaa, 1'b1, 1'b1, 1'b0);
        tx_word(16'hbbbb, 1'b1, 1'b1, 1'b0);
        tx_idle(1);
        tx_idle(80);

        $display("---- SIM DONE ----");
        $finish;
    end

    // 超时保护
    initial begin
        #100000;
        $display("---- TIMEOUT ----");
        $finish;
    end

endmodule
