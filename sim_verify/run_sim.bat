@echo off
cd /d %~dp0
set RDI_DATADIR=D:\software\vivado\Vivado\2020.2\data
copy /y %RDI_DATADIR%\xsim\xsim.ini . >nul
set PATH=D:\software\vivado\Vivado\2020.2\bin;%PATH%
set IPGEN=..\project_ethernet.gen\sources_1\ip
set DUT=..\project_ethernet.srcs\sources_1\new\ethernet_tx_pack.v
xvlog -L unisims_ver tb_ethernet_tx_pack.v %DUT% %IPGEN%\fifo_19x65536_fwft_sync\fifo_19x65536_fwft_sync_sim_netlist.v %IPGEN%\fifo_32x128_fwft_sync\fifo_32x128_fwft_sync_sim_netlist.v %*
