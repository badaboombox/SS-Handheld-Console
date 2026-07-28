# FMC bridge sim
RTL := ../../rtl/fmc

all: run

obj_dir/Vfmc_bridge: $(RTL)/fmc_bridge.v tb_fmc.cpp
	verilator --cc --exe --build -j 0 -Wall -Wno-UNUSEDSIGNAL -Wno-EOFNEWLINE -Wno-WIDTHEXPAND \
	  --top-module fmc_bridge -CFLAGS -O2 \
	  $(RTL)/fmc_bridge.v tb_fmc.cpp -o Vfmc_bridge

run: obj_dir/Vfmc_bridge
	cd obj_dir && ./Vfmc_bridge

clean:
	rm -rf obj_dir

.PHONY: all run clean