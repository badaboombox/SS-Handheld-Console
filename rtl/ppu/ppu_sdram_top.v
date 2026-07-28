// SS Handheld - PPU + SDRAM integration top (sim)
//
// The full graphics memory path: PPU (concurrent renderers -> arbiter ->
// burst cache / 3D stream) -> ar/req adapter -> sdram_ctrl -> sdram_model.
// A TB write port preloads assets through the real controller before the
// frame starts. All PPU config ports are passed straight through.

module ppu_sdram_top #(
    parameter SCREEN_W = 480,
    parameter SCREEN_H = 272
) (
    input  wire         clk,
    input  wire         rst,

    // TB asset preload (only while PPU idle)
    input  wire         tb_wen,
    input  wire [21:0]  tb_waddr,
    input  wire [31:0]  tb_wdata,
    output wire         tb_wready,

    // frame control
    input  wire         frame_start,
    output wire         frame_done,
    output wire         init_done,

    // PPU config (pass-through)
    input  wire [3:0]   layer_en,
    input  wire [7:0]   layer_pri,
    input  wire [39:0]  scroll_x_all,
    input  wire [35:0]  scroll_y_all,
    input  wire [127:0] map_base_all,
    input  wire [127:0] tile_base_all,
    input  wire [15:0]  backdrop,
    input  wire [1:0]   layer_affine,
    input  wire [31:0]  aff_pa_all,
    input  wire [31:0]  aff_pb_all,
    input  wire [31:0]  aff_pc_all,
    input  wire [31:0]  aff_pd_all,
    input  wire [35:0]  aff_ox_all,
    input  wire [35:0]  aff_oy_all,
    input  wire         spr_en,
    input  wire [31:0]  spr_tile_base,
    input  wire         oam_wen,
    input  wire [8:0]   oam_waddr,
    input  wire [31:0]  oam_wdata,
    input  wire         mat_wen,
    input  wire [6:0]   mat_waddr,
    input  wire [15:0]  mat_wdata,
    input  wire         t3d_en,
    input  wire [1:0]   t3d_pri,
    input  wire [31:0]  t3d_base,
    input  wire         t3d_key_en,
    input  wire [15:0]  t3d_key,
    input  wire [5:0]   blend_en,
    input  wire [4:0]   eva,
    input  wire [4:0]   evb,
    input  wire [1:0]   bright_mode,
    input  wire [4:0]   bright,
    input  wire         pal_wen,
    input  wire [7:0]   pal_waddr,
    input  wire [15:0]  pal_wdata,

    output wire [31:0]  stat_hits,
    output wire [31:0]  stat_misses,

    output wire         out_valid,
    output wire [8:0]   out_x,
    output wire [8:0]   out_line,
    output wire [15:0]  out_pixel
);

    // PPU

    wire [31:0] p_araddr;
    wire        p_arvalid;
    wire        p_burst;
    wire        p_arready;
    wire [31:0] p_rdata;
    wire        p_rvalid;

    ppu_top #(
        .SCREEN_W(SCREEN_W),
        .SCREEN_H(SCREEN_H)
    ) ppu (
        .clk(clk), .rst(rst),
        .frame_start(frame_start), .frame_done(frame_done),
        .pace_en(1'b0), .line_go(1'b0), .line_go_y(9'd0), .cache_flush(frame_start),
        .layer_en(layer_en), .layer_pri(layer_pri),
        .scroll_x_all(scroll_x_all), .scroll_y_all(scroll_y_all),
        .map_base_all(map_base_all), .tile_base_all(tile_base_all),
        .backdrop(backdrop),
        .layer_affine(layer_affine),
        .aff_pa_all(aff_pa_all), .aff_pb_all(aff_pb_all),
        .aff_pc_all(aff_pc_all), .aff_pd_all(aff_pd_all),
        .aff_ox_all(aff_ox_all), .aff_oy_all(aff_oy_all),
        .spr_en(spr_en), .spr_tile_base(spr_tile_base),
        .oam_wen(oam_wen), .oam_waddr(oam_waddr), .oam_wdata(oam_wdata),
        .mat_wen(mat_wen), .mat_waddr(mat_waddr), .mat_wdata(mat_wdata),
        .t3d_en(t3d_en), .t3d_pri(t3d_pri), .t3d_base(t3d_base),
        .t3d_key_en(t3d_key_en), .t3d_key(t3d_key),
        .blend_en(blend_en), .eva(eva), .evb(evb),
        .bright_mode(bright_mode), .bright(bright),
        .pal_wen(pal_wen), .pal_waddr(pal_waddr), .pal_wdata(pal_wdata),
        .m_araddr(p_araddr), .m_arvalid(p_arvalid), .m_burst(p_burst),
        .m_arready(p_arready), .m_rdata(p_rdata), .m_rvalid(p_rvalid),
        .stat_hits(stat_hits), .stat_misses(stat_misses),
        .dbg_fstate(), .dbg_done_seen(), .dbg_unit_en(),
        .dbg_spr_state(), .dbg_cache_state(), .dbg_arb(), .dbg_arb2(),
        .dbg_bg_states(), .dbg_done_cnt(), .dbg_c(),
        .out_valid(out_valid), .out_x(out_x),
        .out_line(out_line), .out_pixel(out_pixel)
    );

    // ar-handshake -> req/ready adapter + TB write mux

    wire        c_ready;
    wire [31:0] c_rdata;
    wire        c_rvalid;
    wire        c_wdone;

    // PPU read request: fire req for one cycle when controller ready
    assign p_arready = c_ready && !tb_wen && p_arvalid;
    assign tb_wready = c_ready && init_done;

    wire        req   = (tb_wen || p_arvalid) && c_ready;
    wire        we    = tb_wen;
    wire        burst = !tb_wen && p_burst;
    wire [21:0] addr  = tb_wen ? tb_waddr : p_araddr[21:0];

    assign p_rdata  = c_rdata;
    assign p_rvalid = c_rvalid;

    // SDRAM controller + model 

    wire        s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]  s_ba;
    wire [11:0] s_a;
    wire [3:0]  s_dqm;
    wire [31:0] dq_c2m;
    wire [31:0] dq_m2c;
    wire        dq_oe;

    sdram_ctrl #(
        .INIT_WAIT(64)
    ) ctrl (
        .clk(clk), .rst(rst),
        .req(req), .we(we), .burst(burst), .addr(addr),
        .wdata(tb_wdata), .wbe(4'hF),
        .ready(c_ready), .rdata(c_rdata), .rvalid(c_rvalid),
        .wdone(c_wdone), .init_done(init_done),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n),
        .s_cas_n(s_cas_n), .s_we_n(s_we_n),
        .s_ba(s_ba), .s_a(s_a), .s_dqm(s_dqm),
        .s_dq_i(dq_m2c), .s_dq_o(dq_c2m), .s_dq_oe(dq_oe)
    );

    sdram_model model (
        .clk(clk),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n),
        .s_cas_n(s_cas_n), .s_we_n(s_we_n),
        .s_ba(s_ba), .s_a(s_a), .s_dqm(s_dqm),
        .s_dq_i(dq_c2m), .s_dq_o(dq_m2c), .s_dq_oe(dq_oe)
    );

endmodule