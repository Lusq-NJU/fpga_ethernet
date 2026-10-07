`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// 模块: ethernet_tx_pack_ref
// 说明: ethernet_tx_pack 的参考修正版，用于对比验证。
//       相对原版的修改点（已在注释中标注 [FIX-n]）：
//       [FIX-1] 拼接表达式中所有 unsized 常量改为显式位宽常量，
//               避免 32 位表达式撑宽拼接导致高位被截断
//       [FIX-2] w_message_din 位宽由 33 位(16+17)修正为 32 位(16+16)
//       [FIX-3] 实现 IP 首部校验和（10 个 16 位字求和 -> 折叠 -> 取反）
//       [FIX-4] 实现 UDP 校验和（伪首部+UDP首部+数据校验和 -> 折叠 -> 取反）
//       [FIX-5] 数据校验和：折叠处理二次进位；奇数长度(mty=1)补零
//       [FIX-6] IP 标识 r_cnt_id 递增时机改为整包发送完毕，使首包 ID=0
//       [FIX-7] 补 w_udp2data_start 赋值（原版缺失，状态机卡在 UDP）
//       [FIX-8] UDP 状态拍数 8-1 改为 4-1（UDP 首部 8 字节 = 4 拍）
//       [FIX-9] 发送阶段长度取自 message FIFO 锁存值，避免用发送时的
//               r_cnt1/tx_mty 重算（此时已被清零）
//////////////////////////////////////////////////////////////////////////////////

module ethernet_tx_pack_ref(
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
    * ip头标识，整包发送完毕后+1
    **/
    reg         [15:0]      r_cnt_id            ;

    /**
    * 包文长度统计
    **/
    reg         [15:0]      r_cnt1              ;
    wire                    w_add_cnt1          ;
    wire                    w_end_cnt1          ;

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
    * 长度计算
    **/
    // 接收阶段统计的字节数（仅用于写入 message FIFO）
    wire        [15:0]      w_data_bytes        ;

    assign w_data_bytes   = (r_cnt1 + 16'd1) * 16'd2 - {15'd0, tx_mty};   // [FIX-1]

    /**
    * 数据校验和（逐拍累加，1的补码和）
    **/
    reg         [15:0]      r_check_res         ;
    reg         [15:0]      r_check_res_tmp     ;

    wire        [15:0]      w_check_word        ;
    wire        [16:0]      w_chk_sum           ;
    wire        [16:0]      w_chk_fold1         ;
    wire        [15:0]      w_chk_fold2         ;

    // [FIX-5] 奇数长度时最后一个无效字节补 0 参与计算
    assign w_check_word = (tx_eop && tx_mty) ? {tx_data[15:8], 8'h00} : tx_data;
    assign w_chk_sum    = {1'b0, r_check_res} + {1'b0, w_check_word};
    assign w_chk_fold1  = w_chk_sum[15:0] + w_chk_sum[16];      // 进位回卷
    assign w_chk_fold2  = w_chk_fold1[15:0] + w_chk_fold1[16];  // 二次进位回卷

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_check_res <= 0;
        else if(tx_vld)
            r_check_res <= r_check_res_tmp;
    end

    always @(*) begin
        if(tx_vld && tx_sop)
            r_check_res_tmp = w_check_word;
        else if(tx_vld)
            r_check_res_tmp = w_chk_fold2;
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

    assign w_data_din   = {tx_sop, tx_eop, tx_mty, tx_data}     ;
    assign w_data_wr_en = tx_vld                                ;
    assign w_data_rd_en = w_data_empty==0 && r_state_c==DATA    ;

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

    assign w_message_din   = {w_data_bytes, r_check_res_tmp}                       ; // [FIX-2] 16+16=32位
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
    * 发送阶段使用的长度（取自 message FIFO 锁存值）
    * [FIX-9] 发送时 r_cnt1/tx_mty 已不再是该包接收时的值，
    *         长度必须使用接收阶段写入 FIFO 的数据
    **/
    wire        [15:0]      w_udp_len           ;
    wire        [15:0]      w_ip_total_len      ;

    assign w_udp_len      = 16'd8  + w_message_dout[31:16] ;   // 首部+数据
    assign w_ip_total_len = 16'd20 + w_udp_len             ;   // IP首部+UDP部分

    /**
    * MAC头以及计数器
    **/
    wire        [111:0]     w_mac_head          ;

    assign w_mac_head    = {cfg_dmac, cfg_smac, 16'h0800}   ;

    reg         [7:0]       r_cnt_mac           ;
    wire                    w_add_cnt_mac       ;
    wire                    w_end_cnt_mac       ;

    assign w_add_cnt_mac = r_state_c==MAC                   ;
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
    * IP首部校验和  [FIX-3]
    * 10个16位字相加 -> 进位回卷 -> 取反
    **/
    wire        [19:0]      w_ip_sum            ;
    wire        [16:0]      w_ip_sum_f1         ;
    wire        [15:0]      w_ip_sum_f2         ;
    wire        [15:0]      w_ip_check          ;

    assign w_ip_sum    = {4'd0, 16'h4500}                   // 版本4+首部长度5+区分服务
                       + {4'd0, w_ip_total_len}             // 总长度
                       + {4'd0, r_cnt_id}                   // 标识
                       + {4'd0, 16'h0000}                   // 标志+片偏移
                       + {4'd0, 16'hff11}                   // TTL=255 + 协议=17
                       + {4'd0, 16'h0000}                   // 首部校验和字段占位0
                       + {4'd0, cfg_sip[31:16]}
                       + {4'd0, cfg_sip[15:0]}
                       + {4'd0, cfg_dip[31:16]}
                       + {4'd0, cfg_dip[15:0]};

    assign w_ip_sum_f1 = w_ip_sum[15:0] + w_ip_sum[19:16]   ;   // 进位回卷
    assign w_ip_sum_f2 = w_ip_sum_f1[15:0] + w_ip_sum_f1[16] ;  // 二次进位回卷
    assign w_ip_check  = ~w_ip_sum_f2                       ;   // 取反即得校验和

    /**
    * IP头以及计数器
    **/
    wire        [159:0]     w_ip_head           ;

    assign w_ip_head = {4'd4, 4'd5, 8'd0, w_ip_total_len, r_cnt_id, 3'd0, 13'd0,
                        8'd255, 8'd17, w_ip_check, cfg_sip, cfg_dip};   // [FIX-1] 160位

    reg         [7:0]       r_cnt_ip            ;
    wire                    w_add_cnt_ip        ;
    wire                    w_end_cnt_ip        ;

    assign w_add_cnt_ip = r_state_c==IP                     ;
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
    * UDP校验和  [FIX-4]
    * 伪首部(6字) + UDP首部前3字 + 数据校验和(1字) -> 进位回卷 -> 取反
    **/
    wire        [19:0]      w_udp_sum           ;
    wire        [16:0]      w_udp_sum_f1        ;
    wire        [15:0]      w_udp_sum_f2        ;
    wire        [15:0]      w_udp_check_r       ;
    wire        [15:0]      w_udp_check         ;

    assign w_udp_sum   = {4'd0, cfg_sip[31:16]}             // 伪首部:源IP
                       + {4'd0, cfg_sip[15:0]}
                       + {4'd0, cfg_dip[31:16]}             // 伪首部:目的IP
                       + {4'd0, cfg_dip[15:0]}
                       + {4'd0, 16'h0011}                   // 伪首部:0 + 协议17
                       + {4'd0, w_udp_len}                  // 伪首部:UDP长度
                       + {4'd0, cfg_sport}                  // UDP首部:源端口
                       + {4'd0, cfg_dport}                  // UDP首部:目的端口
                       + {4'd0, w_udp_len}                  // UDP首部:长度
                       + {4'd0, w_message_dout[15:0]};      // 数据部分校验和

    assign w_udp_sum_f1  = w_udp_sum[15:0] + w_udp_sum[19:16]  ;
    assign w_udp_sum_f2  = w_udp_sum_f1[15:0] + w_udp_sum_f1[16];
    assign w_udp_check_r = ~w_udp_sum_f2                       ;
    // RFC768: 校验和计算结果为0时，发送全1
    assign w_udp_check   = (w_udp_check_r == 16'h0000) ? 16'hffff : w_udp_check_r;

    /**
    * UDP头以及计数器
    **/
    wire        [63:0]      w_udp_head          ;

    assign w_udp_head = {cfg_sport, cfg_dport, w_udp_len, w_udp_check};  // [FIX-1] 64位

    reg         [2:0]       r_cnt_udp           ;
    wire                    w_add_cnt_udp       ;
    wire                    w_end_cnt_udp       ;

    assign w_add_cnt_udp = r_state_c==UDP                   ;
    // UDP首部8字节 = 4个16位字 = 4拍 [FIX-8]（原为8-1，多发了4拍）
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
    * 状态机状态切换
    **/
    wire                    w_idle2mac_start    ;
    wire                    w_mac2ip_start      ;
    wire                    w_ip2udp_start      ;
    wire                    w_udp2data_start    ;
    wire                    w_data2idle_start   ;

    assign w_idle2mac_start = r_state_c==IDLE && dout_rdy && w_message_empty==0;
    assign w_mac2ip_start   = r_state_c==MAC && w_end_cnt_mac;
    assign w_ip2udp_start   = r_state_c==IP && w_end_cnt_ip;

    assign w_data2idle_start = r_state_c==DATA && w_message_rd_en;

    // [FIX-6] 整包发送完毕后再+1，保证首个包文标识为0
    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_cnt_id <= 0;
        else if(w_data2idle_start)
            r_cnt_id <= r_cnt_id+1;
    end

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

    // [FIX-7] 原版缺失此赋值，状态机永远无法从 UDP 进入 DATA
    assign w_udp2data_start = r_state_c==UDP && w_end_cnt_udp;

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
        else
            dout_vld <= 0;
    end

endmodule
