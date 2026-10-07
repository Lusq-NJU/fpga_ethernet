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

    // 包文长度统计信号
    reg         [15:0]      r_cnt_data_len      ;
    wire                    w_add_cnt_data_len  ;
    wire                    w_end_cnt_data_len  ;

    // 包文内容校验和
    reg         [15:0]      r_check_res         ;
    reg         [16:0]      r_check_res_tmp     ;

    // 状态机定义
    parameter IDLE = 0;
    parameter MAC  = 1;
    parameter IP   = 2;
    parameter UDP  = 3;
    parameter DATA = 4;

    reg         [2:0]       r_state_c           ;
    reg         [2:0]       r_state_n           ;

    // tx数据存储
    wire        [18:0]      w_data_din          ;
    wire        [18:0]      w_data_dout         ;
    wire                    w_data_wr_en        ;
    wire                    w_data_rd_en        ;
    wire                    w_data_empty        ;

    wire        [31:0]      w_message_din       ;
    wire        [31:0]      w_message_dout      ;
    wire                    w_message_wr_en     ;
    wire                    w_message_rd_en     ;
    wire                    w_message_empty     ;

    wire        [15:0]      w_data_len          ;

    // ip头标识，发送一次包文+1；
    reg         [15:0]      r_cnt_id            ;

    // MAC头以及计数器
    reg         [7:0]       r_cnt_mac           ;
    wire        [111:0]     w_mac_head          ;
    wire                    w_add_cnt_mac       ;
    wire                    w_end_cnt_mac       ;

    // ip头以及计数器
    reg         [19:0]      r_ip_head_sum       ;  
    wire        [159:0]     w_ip_head           ;
    wire        [159:0]     w_ip_head_tmp       ;
    wire        [16:0]      w_ip_head_check_f0  ;
    wire        [15:0]      w_ip_head_check_f1  ;

    reg         [3:0]       r_cnt_ip_chk        ;
    reg                     r_flag_cnt_ip_chk   ;
    wire                    w_add_cnt_ip_chk    ;
    wire                    w_end_cnt_ip_chk    ;

    reg         [3:0]       r_cnt_ip            ;
    wire                    w_add_cnt_ip        ;
    wire                    w_end_cnt_ip        ;

    // udp头以及计数器
    wire        [159:0]     w_udp_head_tmp      ;
    wire        [63:0]      w_udp_head          ;

    wire        [16:0]      w_udp_head_check_f0 ;
    wire        [15:0]      w_udp_head_check_f1 ;
    reg         [19:0]      r_udp_head_sum      ;

    reg         [3:0]       r_cnt_udp_head_chk  ;
    reg                     r_flag_cnt_udp_chk  ;
    wire                    w_add_cnt_udp_chk   ;
    wire                    w_end_cnt_udp_chk   ;

    reg         [2:0]       r_cnt_udp           ;
    wire                    w_add_cnt_udp       ;
    wire                    w_end_cnt_udp       ;

    // 状态机状态切换
    wire                    w_idle2mac_start    ;
    wire                    w_mac2ip_start      ;
    wire                    w_ip2udp_start      ;
    wire                    w_udp2data_start    ;
    wire                    w_data2idle_start   ;

    /**
    * 包文长度统计
    **/
    assign w_add_cnt_data_len = tx_vld                  ;
    assign w_end_cnt_data_len = w_add_cnt_data_len && tx_eop    ;

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_cnt_data_len <= 0;
        else if(w_add_cnt_data_len)begin
            if(w_end_cnt_data_len)
                r_cnt_data_len <= 0;
            else
                r_cnt_data_len <= r_cnt_data_len+1; 
        end
    end

    /**
    * 包文内容校验和
    **/
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
    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_state_c <= IDLE;
        else
            r_state_c <= r_state_n; 
    end

    /**
    * tx数据存储
    **/
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

    assign w_data_len      = (r_cnt_data_len+1)*2-tx_mty                                    ;
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
    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_cnt_id <= 0;
        else if(w_message_rd_en)
            r_cnt_id <= r_cnt_id+1;
    end

    /**
    * MAC头以及计数器
    **/
    assign w_mac_head    = {cfg_dmac, cfg_smac, 16'h0800}   ;
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
    * ip头以及计数器
    **/
    assign w_ip_head_tmp = {4'd4, 4'd5, 8'd0, 16'd20+w_message_dout[31:16], r_cnt_id, 3'd0, 13'd0, 8'd255, 8'd17, 16'd0, cfg_sip, cfg_dip};
    assign w_ip_head = {4'd4, 4'd5, 8'd0, 16'd20+w_message_dout[31:16], r_cnt_id, 3'd0, 13'd0, 8'd255, 8'd17, ~w_ip_head_check_f1, cfg_sip, cfg_dip};

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_ip_head_sum <= 0;
        else if(w_data2idle_start)
            r_ip_head_sum <= 0;
        else if(w_add_cnt_ip_chk)
            r_ip_head_sum <= r_ip_head_sum+w_ip_head_tmp[159-r_cnt_ip_chk*16 -: 16];
    end

    assign w_ip_head_check_f0 = r_ip_head_sum[15:0]+r_ip_head_sum[19:16];
    assign w_ip_head_check_f1 = w_ip_head_check_f0[15:0]+w_ip_head_check_f0[16];

    assign w_add_cnt_ip_chk = r_flag_cnt_ip_chk;
    assign w_end_cnt_ip_chk = w_add_cnt_ip_chk && r_cnt_ip_chk==10-1;

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_cnt_ip_chk <= 0;
        else if(w_add_cnt_ip_chk)begin
            if(w_end_cnt_ip_chk)
                r_cnt_ip_chk <= 0;
            else
                r_cnt_ip_chk <= r_cnt_ip_chk+1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_flag_cnt_ip_chk <= 0;
        else if(w_end_cnt_ip_chk)
            r_flag_cnt_ip_chk <= 0;
        else if(w_idle2mac_start)
            r_flag_cnt_ip_chk <= 1;
    end

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
    assign w_udp_head_tmp = {cfg_sip, cfg_dip, 8'd0, 8'd17, 16'd8+w_message_dout[31:16], cfg_sport, cfg_dport, 16'd8+w_message_dout[31:16], w_message_dout[15:0]};
    assign w_udp_head = {cfg_sport, cfg_dport, 16'd8+w_message_dout[31:16], ~w_udp_head_check_f1};

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_udp_head_sum <= 0;
        else if(w_data2idle_start)
            r_udp_head_sum <= 0;
        else if(w_add_cnt_udp_chk)
            r_udp_head_sum <= r_udp_head_sum+w_udp_head_tmp[159-16*r_cnt_udp_head_chk -: 16];
    end

    assign w_udp_head_check_f0 = r_udp_head_sum[15:0]+r_udp_head_sum[19:16];
    assign w_udp_head_check_f1 = w_udp_head_check_f0[15:0]+w_udp_head_check_f0[16];

    assign w_add_cnt_udp_chk = r_flag_cnt_udp_chk;
    assign w_end_cnt_udp_chk = w_add_cnt_udp_chk && r_cnt_udp_head_chk==10-1;

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_flag_cnt_udp_chk <= 0;
        else if(w_end_cnt_udp_chk)
            r_flag_cnt_udp_chk <= 0;
        else if(w_idle2mac_start)
            r_flag_cnt_udp_chk <= r_flag_cnt_udp_chk+1;
    end

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0)
            r_cnt_udp_head_chk <= 0;
        else if(w_add_cnt_udp_chk)begin
            if(w_end_cnt_udp_chk)
                r_cnt_udp_head_chk <= 0;
            else
                r_cnt_udp_head_chk <= r_cnt_udp_head_chk+1;
        end
    end

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
    * 状态机状态切换
    **/
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
