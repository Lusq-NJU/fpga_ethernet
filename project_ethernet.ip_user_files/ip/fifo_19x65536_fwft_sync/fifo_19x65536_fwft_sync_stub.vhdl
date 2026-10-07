-- Copyright 1986-2020 Xilinx, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2020.2 (win64) Build 3064766 Wed Nov 18 09:12:45 MST 2020
-- Date        : Wed Oct  7 15:40:03 2026
-- Host        : null running 64-bit major release  (build 9200)
-- Command     : write_vhdl -force -mode synth_stub
--               d:/coding/verilog/xc7k70t/project_ethernet/project_ethernet.gen/sources_1/ip/fifo_19x65536_fwft_sync/fifo_19x65536_fwft_sync_stub.vhdl
-- Design      : fifo_19x65536_fwft_sync
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xc7k70tfbg676-2
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity fifo_19x65536_fwft_sync is
  Port ( 
    clk : in STD_LOGIC;
    srst : in STD_LOGIC;
    din : in STD_LOGIC_VECTOR ( 18 downto 0 );
    wr_en : in STD_LOGIC;
    rd_en : in STD_LOGIC;
    dout : out STD_LOGIC_VECTOR ( 18 downto 0 );
    full : out STD_LOGIC;
    empty : out STD_LOGIC
  );

end fifo_19x65536_fwft_sync;

architecture stub of fifo_19x65536_fwft_sync is
attribute syn_black_box : boolean;
attribute black_box_pad_pin : string;
attribute syn_black_box of stub : architecture is true;
attribute black_box_pad_pin of stub : architecture is "clk,srst,din[18:0],wr_en,rd_en,dout[18:0],full,empty";
attribute x_core_info : string;
attribute x_core_info of stub : architecture is "fifo_generator_v13_2_5,Vivado 2020.2";
begin
end;
