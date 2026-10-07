@echo off
cd /d %~dp0
set RDI_DATADIR=D:\software\vivado\Vivado\2020.2\data
set PATH=D:\software\vivado\Vivado\2020.2\bin;%PATH%
copy /y %RDI_DATADIR%\xsim\xsim.ini . >nul
set IPGEN=..\project_ethernet.gen\sources_1\ip
set DUT=..\project_ethernet.srcs\sources_1\new\ethernet_tx_pack.v
xvlog -L unisims_ver glbl.v tb_ethernet_tx_pack.v %DUT% %IPGEN%\fifo_19x65536_fwft_sync\fifo_19x65536_fwft_sync_sim_netlist.v %IPGEN%\fifo_32x128_fwft_sync\fifo_32x128_fwft_sync_sim_netlist.v > xvlog2.log 2>&1
if errorlevel 1 (echo XVLOG FAILED & type xvlog2.log & exit /b 1)
xelab -L unisims_ver work.tb_ethernet_tx_pack work.glbl -s tb_sim --debug typical > elab.log 2>&1
if errorlevel 1 (echo ELAB FAILED & type elab.log & exit /b 1)
xsim tb_sim -R > sim_output.log 2>&1
echo SIM EXIT %ERRORLEVEL%
