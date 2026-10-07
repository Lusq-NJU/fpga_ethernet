`timescale 1ns / 1ps

module ethernet_tx_pack(
        input                       clk         ,
        input                       rst_n       ,
        input           [15:0]      cfg_sport   ,
        input           [15:0]      cfg_dport   ,
        input           [31:0]      cfg_sip     ,
        input           [31:0]      cfg_dip     ,
        input           [47:0]      cfg_smac    ,
        input           [47:0]      cfg_dmac    ,
        input           [15:0]      tx_data     ,
        input                       tx_vld      ,
        input                       tx_sop      ,
        input                       tx_eop      ,
        input                       tx_mty      ,
        output  reg                 tx_rdy      ,
        input                       dout_rdy    ,
        output  reg     [15:0]      dout_data   ,
        output  reg                 dout_vld    ,
        output  reg                 dout_sop    ,
        output  reg                 dout_eop    ,
        output  reg                 dout_mty    
    );

    /**
    * 包文长度统计
    **/
    reg         [15:0]      r_cnt1              ;
    wire                    w_add_cnt1;
    wire                    w_end_cnt1;

    assign w_add_cnt1 = tx_vld                  ;
    assign w_end_cnt1 = w_add_cnt1 && tx_eop    ;

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_cnt1 <= 0;
        else if(w_add_cnt1)begin
            if(w_end_cnt1)
                r_cnt1 <= 0;
            else
                r_cnt1 <= r_cnt1+1; 
        end
    end

    /**
    * 包文内容校验和
    **/
    reg         [15:0]      r_check_res         ;
    reg         [16:0]      r_check_res_tmp     ;

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_check_res <= 0;
        else if(tx_vld)
            r_check_res <= r_check_res_tmp;
    end

    always @(*) begin
        if(tx_vld && tx_sop)
            r_check_res_tmp = tx_data;
        else if(tx_vld)begin
            if(tx_eop && tx_mty)
                r_check_res_tmp = r_check_res+{tx_data[15:8], 8'd0};
            else
                r_check_res_tmp = r_check_res+tx_data;
            r_check_res_tmp = r_check_res_tmp+r_check_res_tmp[16];
        end 
        else
            r_check_res_tmp = r_check_res;
    end

    /**
    * pack模块准备状态
    **/
    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            tx_rdy <= 1;
        else if(tx_vld && tx_eop)
            tx_rdy <= 1;
        else if(tx_vld && tx_sop)
            tx_rdy <= 0;
    end

    /**
    * 状态机定义
    **/
    parameter IDLE = 0;
    parameter MAC  = 1;
    parameter IP   = 2;
    parameter UDP  = 3;
    parameter DATA = 4;

    reg         [2:0]       r_state_c           ;
    reg         [2:0]       r_state_n           ;

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_state_c <= IDLE;
        else
            r_state_c <= r_state_n; 
    end

    /**
    * tx数据存储
    **/
    wire        [18:0]      w_data_din          ;
    wire        [18:0]      w_data_dout         ;
    wire                    w_data_wr_en        ;
    wire                    w_data_rd_en        ;
    wire                    w_data_empty        ;

    assign w_data_din   = {tx_sop, tx_eop, tx_mty, tx_data}                 ;
    assign w_data_wr_en = tx_vld                                            ;
    assign w_data_rd_en = w_data_empty==0 && r_state_c==DATA && dout_rdy    ;

    fifo_19x65536_fwft_sync u_tx_data_fifo (
        .clk                (clk                    ),              // input wire clk
        .srst               (~rst_n                 ),              // input wire srst
        .din                (w_data_din             ),              // input wire [18 : 0] din
        .wr_en              (w_data_wr_en           ),              // input wire wr_en
        .rd_en              (w_data_rd_en           ),              // input wire rd_en
        .dout               (w_data_dout            ),              // output wire [18 : 0] dout
        .empty              (w_data_empty           )               // output wire empty
    );

    wire        [31:0]      w_message_din       ;
    wire        [31:0]      w_message_dout      ;
    wire                    w_message_wr_en     ;
    wire                    w_message_rd_en     ;
    wire                    w_message_empty     ;

    wire        [15:0]      w_data_len          ;

    assign w_data_len      = (r_cnt1+1)*2-tx_mty                                    ;
    assign w_message_din   = {w_data_len, r_check_res_tmp[15:0]}                          ;
    assign w_message_wr_en = tx_vld && tx_eop                                       ;
    assign w_message_rd_en = w_data_rd_en && w_data_dout[17] && w_message_empty==0  ;

    fifo_32x128_fwft_sync u_tx_message_fifo (
        .clk                (clk                    ),              // input wire clk
        .srst               (~rst_n                 ),              // input wire srst
        .din                (w_message_din          ),              // input wire [31 : 0] din
        .wr_en              (w_message_wr_en        ),              // input wire wr_en
        .rd_en              (w_message_rd_en        ),              // input wire rd_en
        .dout               (w_message_dout         ),              // output wire [31 : 0] dout
        .empty              (w_message_empty        )               // output wire empty
    );

    /**
    * ip头标识，发送一次包文+1；
    **/
    reg         [15:0]      r_cnt_id            ;

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_cnt_id <= 0;
        else if(w_message_rd_en)
            r_cnt_id <= r_cnt_id+1;
    end

    /**
    * MAC头以及计数器
    **/

    wire        [111:0]     w_mac_head          ;

    assign w_mac_head    = {cfg_dmac, cfg_smac, 16'h0800}   ;

    reg         [7:0]       r_cnt_mac           ;
    wire                    w_add_cnt_mac       ;
    wire                    w_end_cnt_mac       ;

    assign w_add_cnt_mac = r_state_c==MAC && dout_rdy       ;
    assign w_end_cnt_mac = w_add_cnt_mac && r_cnt_mac==7-1  ;

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_cnt_mac <= 0;
        else if(w_add_cnt_mac)begin
            if(w_end_cnt_mac)
                r_cnt_mac <= 0;
            else
                r_cnt_mac <= r_cnt_mac+1;
        end
    end

    /**
    * 长度计算
    * 注: message FIFO 中锁存的是"数据字节数"，
    *     IP总长 = IP首部20 + UDP长度，而 UDP长度 = UDP首部8 + 数据字节数
    **/
    wire        [15:0]      w_udp_len           ;
    wire        [15:0]      w_ip_total_len      ;

    assign w_udp_len      = 16'd8  + w_message_dout[31:16];
    assign w_ip_total_len = 16'd20 + w_udp_len;

    /**
    * ip头以及计数器
    **/

    wire        [159:0]     w_ip_head           ;
    wire        [159:0]     w_ip_head_tmp       ;

    wire        [15:0]      w_ip_head_check     ;

    assign w_ip_head_tmp = {4'd4, 4'd5, 8'd0, w_ip_total_len, r_cnt_id, 3'd0, 13'd0, 8'd255, 8'd17, 16'd0, cfg_sip, cfg_dip};
    assign w_ip_head = {4'd4, 4'd5, 8'd0, w_ip_total_len, r_cnt_id, 3'd0, 13'd0, 8'd255, 8'd17, ~w_ip_head_check, cfg_sip, cfg_dip};

    // IP首部校验和采用"逐拍累加"实现（见文件末尾），不再使用组合加法树

    reg         [7:0]       r_cnt_ip            ;
    wire                    w_add_cnt_ip        ;
    wire                    w_end_cnt_ip        ;

    assign w_add_cnt_ip = r_state_c==IP && dout_rdy         ;
    assign w_end_cnt_ip = w_add_cnt_ip && r_cnt_ip==10-1    ;

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_cnt_ip <= 0;
        else if(w_add_cnt_ip)begin
            if(w_end_cnt_ip)
                r_cnt_ip <= 0;
            else
                r_cnt_ip <= r_cnt_ip+1;
        end
    end

    /**
    * udp头以及计数器
    **/
    wire        [159:0]     w_udp_head_tmp      ;
    wire        [63:0]      w_udp_head          ;

    wire        [15:0]      w_udp_head_check    ;

    assign w_udp_head_tmp = {cfg_sip, cfg_dip, 8'd0, 8'd17, w_udp_len, cfg_sport, cfg_dport, w_udp_len, w_message_dout[15:0]};
    assign w_udp_head = {cfg_sport, cfg_dport, w_udp_len, ~w_udp_head_check};

    // UDP校验和同样采用"逐拍累加"实现（见文件末尾）

    reg         [2:0]       r_cnt_udp           ;
    wire                    w_add_cnt_udp       ;
    wire                    w_end_cnt_udp       ;

    assign w_add_cnt_udp = r_state_c==UDP && dout_rdy       ;
    assign w_end_cnt_udp = w_add_cnt_udp && r_cnt_udp==4-1  ;

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_cnt_udp <= 0;
        else if(w_add_cnt_udp)begin
            if(w_end_cnt_udp)
                r_cnt_udp <= 0;
            else
                r_cnt_udp <= r_cnt_udp+1;
        end
    end

    /**
    * ============ 校验和：逐拍累加实现（时序优化） ============
    * 校验和的输入(w_ip_head_tmp/w_udp_head_tmp)在包开始发送前即已稳定，
    * 因此利用 MAC(7拍) + IP(前3拍) 的空档逐拍累加：
    *   MAC 状态 7 拍累加第 0~6 个字，IP 状态前 3 拍累加第 7~9 个字，
    *   共 10 个字 10 拍加完，每拍仅一次 20 位加法(约1~2ns)。
    * IP 校验和字段在 IP 状态第 6 拍才输出，累加早已完成，仅剩
    * 折叠(2次16位加法)+取反的短组合路径，时序余量大。
    **/
    reg         [19:0]      r_ip_sum            ;
    reg         [19:0]      r_udp_sum           ;
    reg         [4:0]       r_sum_idx           ;
    wire        [15:0]      w_ip_word           ;
    wire        [15:0]      w_udp_word          ;

    assign w_ip_word  = w_ip_head_tmp [159 - r_sum_idx*16 -: 16];
    assign w_udp_word = w_udp_head_tmp[159 - r_sum_idx*16 -: 16];

    // 累加索引：MAC 状态对应第 0~6 字，IP 状态前 3 拍对应第 7~9 字
    always @(*) begin
        if(r_state_c==MAC)
            r_sum_idx = {3'd0, r_cnt_mac};
        else
            r_sum_idx = 5'd7 + r_cnt_ip[3:0];
    end

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)begin
            r_ip_sum <= 0;
            r_udp_sum <= 0;
        end
        else if(r_state_c==IDLE)begin          // 包开始前清零
            r_ip_sum <= 0;
            r_udp_sum <= 0;
        end
        else if(r_state_c==MAC || (r_state_c==IP && r_cnt_ip<3))begin
            r_ip_sum  <= r_ip_sum  + {4'd0, w_ip_word };
            r_udp_sum <= r_udp_sum + {4'd0, w_udp_word};
        end
    end

    // 进位回卷(折叠) + 取反前的和
    wire        [16:0]      w_ip_sum_f1         ;
    wire        [15:0]      w_ip_sum_f2         ;
    wire        [16:0]      w_udp_sum_f1        ;
    wire        [15:0]      w_udp_sum_f2        ;

    assign w_ip_sum_f1 = r_ip_sum[15:0] + r_ip_sum[19:16];
    assign w_ip_sum_f2 = w_ip_sum_f1[15:0] + w_ip_sum_f1[16];
    assign w_ip_head_check = w_ip_sum_f2;               // w_ip_head 中 ~ 后输出

    assign w_udp_sum_f1 = r_udp_sum[15:0] + r_udp_sum[19:16];
    assign w_udp_sum_f2 = w_udp_sum_f1[15:0] + w_udp_sum_f1[16];
    // RFC768: 校验和为0时发送全1。此处预先映射, 保证 ~w_udp_head_check 输出 0xFFFF
    assign w_udp_head_check = (w_udp_sum_f2 == 16'hffff) ? 16'h0000 : w_udp_sum_f2;

    /**
    * 状态机状态切换
    **/

    wire                    w_idle2mac_start    ;
    wire                    w_mac2ip_start      ;
    wire                    w_ip2udp_start      ;
    wire                    w_udp2data_start    ;
    wire                    w_data2idle_start   ;

    assign w_idle2mac_start = r_state_c==IDLE && dout_rdy && w_message_empty==0;
    assign w_mac2ip_start = r_state_c==MAC && w_end_cnt_mac;
    assign w_ip2udp_start = r_state_c==IP && w_end_cnt_ip;
    assign w_udp2data_start = r_state_c==UDP && w_end_cnt_udp;
    assign w_data2idle_start = r_state_c==DATA && w_message_rd_en;

    always @(*) begin
        case (r_state_c)
            IDLE : begin
                if(w_idle2mac_start)
                    r_state_n = MAC;
                else
                    r_state_n = r_state_c; 
            end 
            MAC : begin
                if(w_mac2ip_start)
                    r_state_n = IP;
                else
                    r_state_n = r_state_c; 
            end
            IP : begin
                if(w_ip2udp_start)
                    r_state_n = UDP;
                else
                    r_state_n = r_state_c;
            end
            UDP : begin
                if(w_udp2data_start)
                    r_state_n = DATA;
                else
                    r_state_n = r_state_c;
            end
            DATA : begin
                if(w_data2idle_start)
                    r_state_n = IDLE;
                else
                    r_state_n = r_state_c;
            end
            default: r_state_n = IDLE;
        endcase
    end

    /**
    * 输出实现
    **/
    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)begin
            dout_data <= 0;
            dout_vld <= 0;
            dout_sop <= 0;
            dout_eop <= 0;
            dout_mty <= 0;
        end
        else if(r_state_c==MAC)begin
            dout_data <= w_mac_head[111-r_cnt_mac*16 -: 16];
            dout_vld <= w_add_cnt_mac;
            dout_sop <= r_cnt_mac==0;
            dout_eop <= 0;
            dout_mty <= 0;
        end
        else if(r_state_c==IP)begin
            dout_data <= w_ip_head[159-r_cnt_ip*16 -: 16];
            dout_vld <= w_add_cnt_ip;
            dout_sop <= 0;
            dout_eop <= 0;
            dout_mty <= 0;
        end
        else if(r_state_c==UDP)begin
            dout_data <= w_udp_head[63-r_cnt_udp*16 -: 16];
            dout_vld <= w_add_cnt_udp;
            dout_sop <= 0;
            dout_eop <= 0;
            dout_mty <= 0;
        end
        else if(r_state_c==DATA)begin
            dout_data <= w_data_dout[15:0];
            dout_vld <= w_data_rd_en;
            dout_sop <= 0;
            dout_eop <= w_data_dout[17];
            dout_mty <= w_data_dout[16];
        end
        else if(r_state_c==IDLE)begin
            dout_data <= 0;
            dout_vld <= 0;
            dout_sop <= 0;
            dout_eop <= 0;
            dout_mty <= 0;
        end
    end

endmodule
