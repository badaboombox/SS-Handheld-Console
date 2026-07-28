// Synthesis-only wrapper: a shift register feeds every ppu_top input and
// every output XOR-reduces to one pin, so nextpnr sees a handful of pins
// while all internal logic stays live. NOT part of the real design (the FMC
// register file plays this role on the board).

module ppu_synth_wrap (
    input  wire clk,
    input  wire rst,
    input  wire sin,
    input  wire m_arready,
    input  wire [31:0] m_rdata,
    input  wire m_rvalid,
    output wire sout
);

    reg [767:0] sh;
    always @(posedge clk) sh <= {sh[766:0], sin};

    // running offsets
    localparam O_FSTART   = 0;                    // 1
    localparam O_LAYEN    = O_FSTART + 1;         // 4
    localparam O_LAYPRI   = O_LAYEN + 4;          // 8
    localparam O_SX       = O_LAYPRI + 8;         // 40
    localparam O_SY       = O_SX + 40;            // 36
    localparam O_MAP      = O_SY + 36;            // 128
    localparam O_TILE     = O_MAP + 128;          // 128
    localparam O_BACK     = O_TILE + 128;         // 16
    localparam O_LAFF     = O_BACK + 16;          // 2
    localparam O_PA       = O_LAFF + 2;           // 32
    localparam O_PB       = O_PA + 32;            // 32
    localparam O_PC       = O_PB + 32;            // 32
    localparam O_PD       = O_PC + 32;            // 32
    localparam O_OX       = O_PD + 32;            // 36
    localparam O_OY       = O_OX + 36;            // 36
    localparam O_SPREN    = O_OY + 36;            // 1
    localparam O_SPRTB    = O_SPREN + 1;          // 32
    localparam O_OAMWE    = O_SPRTB + 32;         // 1
    localparam O_OAMWA    = O_OAMWE + 1;          // 8
    localparam O_OAMWD    = O_OAMWA + 8;          // 32
    localparam O_MATWE    = O_OAMWD + 32;         // 1
    localparam O_MATWA    = O_MATWE + 1;          // 7
    localparam O_MATWD    = O_MATWA + 7;          // 16
    localparam O_T3DEN    = O_MATWD + 16;         // 1
    localparam O_T3DPRI   = O_T3DEN + 1;          // 2
    localparam O_T3DBASE  = O_T3DPRI + 2;         // 32
    localparam O_T3DKEYEN = O_T3DBASE + 32;       // 1
    localparam O_T3DKEY   = O_T3DKEYEN + 1;       // 16
    localparam O_BLEND    = O_T3DKEY + 16;        // 6
    localparam O_EVA      = O_BLEND + 6;          // 5
    localparam O_EVB      = O_EVA + 5;            // 5
    localparam O_BMODE    = O_EVB + 5;            // 2
    localparam O_BRIGHT   = O_BMODE + 2;          // 5
    localparam O_PALWE    = O_BRIGHT + 5;         // 1
    localparam O_PALWA    = O_PALWE + 1;          // 8
    localparam O_PALWD    = O_PALWA + 8;          // 16

    wire        frame_done;
    wire [31:0] m_araddr;
    wire        m_arvalid;
    wire        m_burst;
    wire [31:0] stat_hits, stat_misses;
    wire        out_valid;
    wire [8:0]  out_x, out_line;
    wire [15:0] out_pixel;

    ppu_top ppu (
        .clk(clk), .rst(rst),
        .frame_start(sh[O_FSTART]),
        .frame_done(frame_done),
        .pace_en(sh[760]),
        .line_go(sh[761]),
        .line_go_y(sh[758:750]),
        .cache_flush(sh[762]),
        .layer_en(sh[O_LAYEN +: 4]),
        .layer_pri(sh[O_LAYPRI +: 8]),
        .scroll_x_all(sh[O_SX +: 40]),
        .scroll_y_all(sh[O_SY +: 36]),
        .map_base_all(sh[O_MAP +: 128]),
        .tile_base_all(sh[O_TILE +: 128]),
        .backdrop(sh[O_BACK +: 16]),
        .layer_affine(sh[O_LAFF +: 2]),
        .aff_pa_all(sh[O_PA +: 32]),
        .aff_pb_all(sh[O_PB +: 32]),
        .aff_pc_all(sh[O_PC +: 32]),
        .aff_pd_all(sh[O_PD +: 32]),
        .aff_ox_all(sh[O_OX +: 36]),
        .aff_oy_all(sh[O_OY +: 36]),
        .spr_en(sh[O_SPREN]),
        .spr_tile_base(sh[O_SPRTB +: 32]),
        .oam_wen(sh[O_OAMWE]),
        .oam_waddr({1'b0, sh[O_OAMWA +: 8]}),   // OAM depth 256; test wrap drives low 128
        .oam_wdata(sh[O_OAMWD +: 32]),
        .mat_wen(sh[O_MATWE]),
        .mat_waddr(sh[O_MATWA +: 7]),
        .mat_wdata(sh[O_MATWD +: 16]),
        .t3d_en(sh[O_T3DEN]),
        .t3d_pri(sh[O_T3DPRI +: 2]),
        .t3d_base(sh[O_T3DBASE +: 32]),
        .t3d_key_en(sh[O_T3DKEYEN]),
        .t3d_key(sh[O_T3DKEY +: 16]),
        .blend_en(sh[O_BLEND +: 6]),
        .eva(sh[O_EVA +: 5]),
        .evb(sh[O_EVB +: 5]),
        .bright_mode(sh[O_BMODE +: 2]),
        .bright(sh[O_BRIGHT +: 5]),
        .pal_wen(sh[O_PALWE]),
        .pal_waddr(sh[O_PALWA +: 8]),
        .pal_wdata(sh[O_PALWD +: 16]),
        .m_araddr(m_araddr),
        .m_arvalid(m_arvalid),
        .m_burst(m_burst),
        .m_arready(m_arready),
        .m_rdata(m_rdata),
        .m_rvalid(m_rvalid),
        .stat_hits(stat_hits),
        .stat_misses(stat_misses),
        .dbg_fstate(), .dbg_done_seen(), .dbg_unit_en(),
        .dbg_spr_state(), .dbg_cache_state(), .dbg_arb(), .dbg_arb2(),
        .dbg_bg_states(), .dbg_done_cnt(), .dbg_c(),
        .out_valid(out_valid),
        .out_x(out_x),
        .out_line(out_line),
        .out_pixel(out_pixel)
    );

    assign sout = frame_done ^ (^m_araddr) ^ m_arvalid ^ m_burst
                ^ (^stat_hits) ^ (^stat_misses)
                ^ out_valid ^ (^out_x) ^ (^out_line) ^ (^out_pixel);

endmodule