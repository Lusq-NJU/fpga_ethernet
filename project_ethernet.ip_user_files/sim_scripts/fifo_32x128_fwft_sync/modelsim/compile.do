vlib modelsim_lib/work
vlib modelsim_lib/msim

vlib modelsim_lib/msim/xil_defaultlib

vmap xil_defaultlib modelsim_lib/msim/xil_defaultlib

vlog -work xil_defaultlib  -incr \
"../../../../project_ethernet.gen/sources_1/ip/fifo_32x128_fwft_sync/sim/fifo_32x128_fwft_sync.v" \


vlog -work xil_defaultlib \
"glbl.v"

