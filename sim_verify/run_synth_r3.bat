@echo off
cd /d %~dp0
set PATH=D:\software\vivado\Vivado\2020.2\bin;%PATH%
vivado -mode batch -source synth_r3.tcl
