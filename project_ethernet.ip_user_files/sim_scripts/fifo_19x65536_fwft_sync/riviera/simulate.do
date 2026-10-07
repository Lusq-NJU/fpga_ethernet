onbreak {quit -force}
onerror {quit -force}

asim +access +r +m+fifo_19x65536_fwft_sync -L xpm -L fifo_generator_v13_2_5 -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.fifo_19x65536_fwft_sync xil_defaultlib.glbl

do {wave.do}

view wave
view structure

do {fifo_19x65536_fwft_sync.udo}

run -all

endsim

quit -force
