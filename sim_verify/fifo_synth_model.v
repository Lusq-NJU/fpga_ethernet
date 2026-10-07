// fifo_synth_model.v — 仅用于时序评估的可综合 FIFO 替身（非仿真用）
// 与 IP 端口一致，内部为简单的 FWFT 行为，取代 xsim netlist 以便综合。
`timescale 1ns / 1ps

module fifo_19x65536_fwft_sync (
    input               clk     ,
    input               srst    ,
    input       [18:0]  din     ,
    input               wr_en   ,
    input               rd_en   ,
    output      [18:0]  dout    ,
    output              empty
);
    reg  [18:0] mem [0:15];
    reg  [4:0]  wr_ptr, rd_ptr;
    wire [4:0]  cnt = wr_ptr - rd_ptr;

    assign empty = (cnt == 0);
    assign dout  = mem[rd_ptr[3:0]];

    always @(posedge clk) begin
        if (srst) begin
            wr_ptr <= 0; rd_ptr <= 0;
        end
        else begin
            if (wr_en) begin
                mem[wr_ptr[3:0]] <= din;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (rd_en && !empty)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end
endmodule

module fifo_32x128_fwft_sync (
    input               clk     ,
    input               srst    ,
    input       [31:0]  din     ,
    input               wr_en   ,
    input               rd_en   ,
    output      [31:0]  dout    ,
    output              empty
);
    reg  [31:0] mem [0:15];
    reg  [4:0]  wr_ptr, rd_ptr;
    wire [4:0]  cnt = wr_ptr - rd_ptr;

    assign empty = (cnt == 0);
    assign dout  = mem[rd_ptr[3:0]];

    always @(posedge clk) begin
        if (srst) begin
            wr_ptr <= 0; rd_ptr <= 0;
        end
        else begin
            if (wr_en) begin
                mem[wr_ptr[3:0]] <= din;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (rd_en && !empty)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end
endmodule
