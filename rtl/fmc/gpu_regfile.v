// SS Handheld - GPU register file v0.1
//
// Decodes the FMC bridge's rw bus (16b registers) into the PPU's config
// ports. Frame-visible state (scrolls, priorities, affine params, blend,
// brightness, backdrop) is SHADOWED and committed at vsync (D27) so 2D
// state changes never tear mid-frame. Asset/base registers and the auto-inc
// data ports (palette / OAM / matrix, NES-style ADDR+DATA) apply immediately.
//
// Map (word addresses within the REGS window):
//   0x00 CTRL   [3:0] layer_en [4] spr_en [5] t3d_en [7:6] layer_affine
//               [8] display_en [9] t3d_key_en
//   0x01 layer_pri[7:0]
//   0x02-0x05 scroll_x l0-l3      0x06-0x09 scroll_y l0-l3
//   0x10-0x17 map_base  lo/hi l0-l3 (word addr, hi = bits 21:16)
//   0x18-0x1F tile_base lo/hi l0-l3
//   0x20 backdrop   0x21 {evb[4:0],eva[4:0],blend_en[5:0]}
//   0x22 {bright[4:0],bright_mode[1:0]}   0x23 {t3d_pri[1:0]}
//   0x24 t3d_key    0x25/0x26 t3d_base lo/hi
//   0x27/0x28 spr_tile_base lo/hi
//   0x29-0x30 affine unit0: pa,pb,pc,pd,ox_lo,ox_hi[1:0],oy_lo,oy_hi[1:0]
//   0x31-0x38 affine unit1: same
//   0x40 pal_addr  0x41 pal_data (auto-inc)
//   0x42 oam_addr  0x43 oam_data (lo/hi pairs, auto-inc per 32b word)
//   0x44 mat_addr  0x45 mat_data (auto-inc)

module gpu_regfile (
    input  wire        clk,
    input  wire        rst,

    // from fmc_bridge
    input  wire        rw_wen,
    input  wire [7:0]  rw_addr,
    input  wire [15:0] rw_wdata,

    // commit point
    input  wire        vsync,

    // PPU config out
    output reg  [3:0]   layer_en,
    output reg          spr_en,
    output reg          t3d_en,
    output reg  [1:0]   layer_affine,
    output reg          display_en,
    output reg          t3d_key_en,
    output reg  [7:0]   layer_pri,
    output reg  [39:0]  scroll_x_all,
    output reg  [35:0]  scroll_y_all,
    output reg  [127:0] map_base_all,
    output reg  [127:0] tile_base_all,
    output reg  [15:0]  backdrop,
    output reg  [5:0]   blend_en,
    output reg  [4:0]   eva,
    output reg  [4:0]   evb,
    output reg  [1:0]   bright_mode,
    output reg  [4:0]   bright,
    output reg  [1:0]   t3d_pri,
    output reg  [15:0]  t3d_key,
    output reg  [31:0]  t3d_base,
    output reg  [31:0]  spr_tile_base,
    output reg  [31:0]  aff_pa_all,
    output reg  [31:0]  aff_pb_all,
    output reg  [31:0]  aff_pc_all,
    output reg  [31:0]  aff_pd_all,
    output reg  [35:0]  aff_ox_all,
    output reg  [35:0]  aff_oy_all,

    // auto-inc write ports
    output reg          pal_wen,
    output reg  [7:0]   pal_waddr,
    output reg  [15:0]  pal_wdata,
    output reg          oam_wen,
    output reg  [8:0]   oam_waddr,
    output reg  [31:0]  oam_wdata,
    output reg          mat_wen,
    output reg  [6:0]   mat_waddr,
    output reg  [15:0]  mat_wdata
);

    // shadows (committed at vsync, or immediately while display off)

    reg [3:0]   sh_layer_en;
    reg         sh_spr_en, sh_t3d_en, sh_t3d_key_en;
    reg [1:0]   sh_layer_affine;
    reg [7:0]   sh_layer_pri;
    reg [39:0]  sh_scroll_x;
    reg [35:0]  sh_scroll_y;
    reg [15:0]  sh_backdrop;
    reg [5:0]   sh_blend_en;
    reg [4:0]   sh_eva, sh_evb, sh_bright;
    reg [1:0]   sh_bright_mode, sh_t3d_pri;
    reg [31:0]  sh_pa, sh_pb, sh_pc, sh_pd;
    reg [35:0]  sh_ox, sh_oy;

    wire commit = vsync || !display_en;

    // auto-inc address counters + pair state
    reg [7:0]  pal_a;
    reg [8:0]  oam_a;      // 32b word address (0..511 = 256 entries x 2 words)
    reg [6:0]  mat_a;
    reg [15:0] oam_lo;
    reg        oam_have;

    always @(posedge clk)
    begin
        pal_wen <= 1'b0;
        oam_wen <= 1'b0;
        mat_wen <= 1'b0;

        if (rst)
        begin
            display_en      <= 1'b0;
            sh_layer_en     <= 4'b0;
            sh_spr_en       <= 1'b0;
            sh_t3d_en       <= 1'b0;
            sh_t3d_key_en   <= 1'b0;
            sh_layer_affine <= 2'b0;
            oam_have        <= 1'b0;
        end
        else
        begin
            // CPU writes 
            if (rw_wen)
            begin
                casez (rw_addr)
                    8'h00:
                    begin
                        sh_layer_en     <= rw_wdata[3:0];
                        sh_spr_en       <= rw_wdata[4];
                        sh_t3d_en       <= rw_wdata[5];
                        sh_layer_affine <= rw_wdata[7:6];
                        display_en      <= rw_wdata[8];
                        sh_t3d_key_en   <= rw_wdata[9];
                    end
                    8'h01: sh_layer_pri <= rw_wdata[7:0];
                    8'h02, 8'h03, 8'h04, 8'h05:
                        sh_scroll_x[((rw_addr - 8'h02) & 8'h03)*10 +: 10] <= rw_wdata[9:0];
                    8'h06, 8'h07, 8'h08, 8'h09:
                        sh_scroll_y[((rw_addr - 8'h06) & 8'h03)*9 +: 9] <= rw_wdata[8:0];
                    8'b0001_0???: // 0x10-0x17 map_base lo/hi
                    begin
                        if (rw_addr[0])
                            map_base_all[(rw_addr[2:1])*32 + 16 +: 16] <= rw_wdata;
                        else
                            map_base_all[(rw_addr[2:1])*32 +: 16] <= rw_wdata;
                    end
                    8'b0001_1???: // 0x18-0x1F tile_base lo/hi
                    begin
                        if (rw_addr[0])
                            tile_base_all[(rw_addr[2:1])*32 + 16 +: 16] <= rw_wdata;
                        else
                            tile_base_all[(rw_addr[2:1])*32 +: 16] <= rw_wdata;
                    end
                    8'h20: sh_backdrop <= rw_wdata;
                    8'h21: {sh_evb, sh_eva, sh_blend_en} <= rw_wdata;
                    8'h22: {sh_bright, sh_bright_mode} <= rw_wdata[6:0];
                    8'h23: sh_t3d_pri <= rw_wdata[1:0];
                    8'h24: t3d_key <= rw_wdata;
                    8'h25: t3d_base[15:0]  <= rw_wdata;
                    8'h26: t3d_base[31:16] <= rw_wdata;
                    8'h27: spr_tile_base[15:0]  <= rw_wdata;
                    8'h28: spr_tile_base[31:16] <= rw_wdata;
                    // affine unit 0: 0x29-0x30
                    8'h29: sh_pa[15:0]  <= rw_wdata;
                    8'h2A: sh_pb[15:0]  <= rw_wdata;
                    8'h2B: sh_pc[15:0]  <= rw_wdata;
                    8'h2C: sh_pd[15:0]  <= rw_wdata;
                    8'h2D: sh_ox[15:0]  <= rw_wdata;
                    8'h2E: sh_ox[17:16] <= rw_wdata[1:0];
                    8'h2F: sh_oy[15:0]  <= rw_wdata;
                    8'h30: sh_oy[17:16] <= rw_wdata[1:0];
                    // affine unit 1: 0x31-0x38
                    8'h31: sh_pa[31:16] <= rw_wdata;
                    8'h32: sh_pb[31:16] <= rw_wdata;
                    8'h33: sh_pc[31:16] <= rw_wdata;
                    8'h34: sh_pd[31:16] <= rw_wdata;
                    8'h35: sh_ox[33:18] <= rw_wdata;
                    8'h36: sh_ox[35:34] <= rw_wdata[1:0];
                    8'h37: sh_oy[33:18] <= rw_wdata;
                    8'h38: sh_oy[35:34] <= rw_wdata[1:0];
                    // data ports
                    8'h40: pal_a <= rw_wdata[7:0];
                    8'h41:
                    begin
                        pal_wen   <= 1'b1;
                        pal_waddr <= pal_a;
                        pal_wdata <= rw_wdata;
                        pal_a     <= pal_a + 8'd1;
                    end
                    8'h42: begin oam_a <= rw_wdata[8:0]; oam_have <= 1'b0; end
                    8'h43:
                    begin
                        if (!oam_have)
                        begin
                            oam_lo   <= rw_wdata;
                            oam_have <= 1'b1;
                        end
                        else
                        begin
                            oam_wen   <= 1'b1;
                            oam_waddr <= oam_a;
                            oam_wdata <= {rw_wdata, oam_lo};
                            oam_a     <= oam_a + 9'd1;
                            oam_have  <= 1'b0;
                        end
                    end
                    8'h44: mat_a <= rw_wdata[6:0];
                    8'h45:
                    begin
                        mat_wen   <= 1'b1;
                        mat_waddr <= mat_a;
                        mat_wdata <= rw_wdata;
                        mat_a     <= mat_a + 7'd1;
                    end
                    default: ;
                endcase
            end

            // vsync commit (D27) 
            if (commit)
            begin
                layer_en     <= sh_layer_en;
                spr_en       <= sh_spr_en;
                t3d_en       <= sh_t3d_en;
                t3d_key_en   <= sh_t3d_key_en;
                layer_affine <= sh_layer_affine;
                layer_pri    <= sh_layer_pri;
                scroll_x_all <= sh_scroll_x;
                scroll_y_all <= sh_scroll_y;
                backdrop     <= sh_backdrop;
                blend_en     <= sh_blend_en;
                eva          <= sh_eva;
                evb          <= sh_evb;
                bright_mode  <= sh_bright_mode;
                bright       <= sh_bright;
                t3d_pri      <= sh_t3d_pri;
                aff_pa_all   <= sh_pa;
                aff_pb_all   <= sh_pb;
                aff_pc_all   <= sh_pc;
                aff_pd_all   <= sh_pd;
                aff_ox_all   <= sh_ox;
                aff_oy_all   <= sh_oy;
            end
        end
    end

endmodule