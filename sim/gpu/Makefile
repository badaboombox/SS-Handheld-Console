# GPU SoC top sim (full front-door system test, incl. RasterIX 3D core)
PPU   := ../../rtl/ppu
SDRAM := ../../rtl/sdram
FMC   := ../../rtl/fmc
SCAN  := ../../rtl/scanout
RIX   := ../../external/RasterIX/rtl

SRCS := ../../rtl/gpu_top.v \
        $(FMC)/fmc_bridge.v $(FMC)/gpu_regfile.v \
        $(PPU)/ppu_top.v $(PPU)/ppu_bg_line.v $(PPU)/ppu_spr_line.v \
        $(PPU)/ppu_bg_affine_line.v $(PPU)/ppu_arbiter.v $(PPU)/ppu_cache.v \
        $(PPU)/ppu_t3d_fetch.v \
        $(SDRAM)/sdram_ctrl.v $(SDRAM)/sdram_model.v \
        $(SDRAM)/sdram_cdc.v $(SDRAM)/axi_sdram_bridge.v \
        $(SCAN)/dpi_scanout.v

# RasterIX + deps resolved by module name (-y); UNITTEST selects the generic
# RAM model (no xpm). -Wno-fatal: the external code trips warnings we do not
# police; our own files stay warning-clean by hand.
RIXFLAGS := -y $(RIX)/RasterIX -y $(RIX)/Float/rtl/float \
            -y $(RIX)/3rdParty -y $(RIX)/3rdParty/verilog-axi -y $(RIX)/3rdParty/verilog-axis \
            +incdir+$(RIX)/RasterIX +incdir+$(RIX)/3rdParty/verilog-axi +incdir+$(RIX)/3rdParty/verilog-axis \
            -DUNITTEST -Wno-fatal

all: run

obj_dir/Vgpu_top: $(SRCS) tb_gpu.cpp
	verilator --cc --exe --build -j 0 -Wall -Wno-UNUSEDSIGNAL -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY \
	  $(RIXFLAGS) \
	  --top-module gpu_top -CFLAGS -O2 \
	  $(SRCS) tb_gpu.cpp -o Vgpu_top

run: obj_dir/Vgpu_top
	cd obj_dir && ./Vgpu_top

clean:
	rm -rf obj_dir

.PHONY: all run clean