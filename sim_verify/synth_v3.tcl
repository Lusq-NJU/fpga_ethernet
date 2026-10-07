# synth.tcl — 综合 ethernet_tx_pack 以评估校验和组合逻辑的时序
# 用法: vivado -mode batch -source synth.tcl

read_verilog {
    ethernet_tx_pack_v3.v
    fifo_synth_model.v
}

synth_design -top ethernet_tx_pack -part xc7k70tfbg676-2 -mode out_of_context

create_clock -period 10.000 -name clk [get_ports clk]
set_clock_uncertainty 0.5 [get_clocks clk]

report_timing_summary -file timing_summary_v3.rpt
report_timing -max_paths 25 -file timing_paths_v3.rpt

# 单独观察校验和相关的路径
puts "================ 校验和相关路径 ================"
report_timing -from [get_cells -hier -filter {NAME =~ *ip_sum* || NAME =~ *udp_sum* || NAME =~ *u_tx_message_fifo*}] \
              -max_paths 10 -file timing_checksum_v3.rpt
puts "================ SYNTH DONE ================"
