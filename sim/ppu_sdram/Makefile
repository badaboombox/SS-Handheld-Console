# PPU + SDRAM integration sim
PPU   := ../../rtl/ppu
SDRAM := ../../rtl/sdram

SRCS := $(PPU)/ppu_sdram_top.v $(PPU)/ppu_top.v $(PPU)/ppu_bg_line.v \
        $(PPU)/ppu_spr_line.v $(PPU)/ppu_bg_affine_line.v \
        $(PPU)/ppu_arbiter.v $(PPU)/ppu_cache.v $(PPU)/ppu_t3d_fetch.v \
        $(SDRAM)/sdram_ctrl.v $(SDRAM)/sdram_model.v

all: run

obj_dir/Vppu_sdram_top: $(SRCS) tb_ppu_sdram.cpp
	verilator --cc --exe --build -j 0 -Wall -Wno-UNUSEDSIGNAL -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY \
	  --top-module ppu_sdram_top -CFLAGS -O2 \
	  $(SRCS) tb_ppu_sdram.cpp -o Vppu_sdram_top

run: obj_dir/Vppu_sdram_top
	cd obj_dir && ./Vppu_sdram_top

clean:
	rm -rf obj_dir

.PHONY: all run clean