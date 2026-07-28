# PPU v0.1 Verilator sim
RTL := ../../rtl/ppu

all: run

SRCS := $(RTL)/ppu_top.v $(RTL)/ppu_bg_line.v $(RTL)/ppu_spr_line.v \
        $(RTL)/ppu_bg_affine_line.v $(RTL)/ppu_arbiter.v $(RTL)/ppu_cache.v \
        $(RTL)/ppu_t3d_fetch.v

obj_dir/Vppu_top: $(SRCS) tb_ppu.cpp
	verilator --cc --exe --build -j 0 -Wall -Wno-UNUSEDSIGNAL -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY \
	  --top-module ppu_top -CFLAGS -O2 \
	  $(SRCS) tb_ppu.cpp -o Vppu_top

run: obj_dir/Vppu_top
	cd obj_dir && ./Vppu_top

clean:
	rm -rf obj_dir ppu_frame.ppm

.PHONY: all run clean