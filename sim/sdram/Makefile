# SDRAM controller sim
RTL := ../../rtl/sdram

SRCS := $(RTL)/sdram_tb_top.v $(RTL)/sdram_ctrl.v $(RTL)/sdram_model.v

all: run

obj_dir/Vsdram_tb_top: $(SRCS) tb_sdram.cpp
	verilator --cc --exe --build -j 0 -Wall -Wno-UNUSEDSIGNAL -Wno-EOFNEWLINE -Wno-WIDTHEXPAND \
	  --top-module sdram_tb_top -CFLAGS -O2 \
	  $(SRCS) tb_sdram.cpp -o Vsdram_tb_top

run: obj_dir/Vsdram_tb_top
	cd obj_dir && ./Vsdram_tb_top

clean:
	rm -rf obj_dir

.PHONY: all run clean