# DPI scanout sim
RTL := ../../rtl/scanout

all: run

obj_dir/Vdpi_scanout: $(RTL)/dpi_scanout.v tb_scanout.cpp
	verilator --cc --exe --build -j 0 -Wall -Wno-UNUSEDSIGNAL -Wno-EOFNEWLINE -Wno-WIDTHEXPAND \
	  --top-module dpi_scanout -CFLAGS -O2 \
	  $(RTL)/dpi_scanout.v tb_scanout.cpp -o Vdpi_scanout

run: obj_dir/Vdpi_scanout
	cd obj_dir && ./Vdpi_scanout

clean:
	rm -rf obj_dir

.PHONY: all run clean