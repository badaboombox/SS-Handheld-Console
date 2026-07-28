// SS Handheld 2D PPU top (v0.6)
//
// All renderers (4 text/affine BG layers, sprite unit, 3D line fetcher) run
// CONCURRENTLY per line, contending through a fixed-priority arbiter behind
// a shared direct-mapped read cache (A3/A11). Line time = max(unit) +
// contention instead of the serial sum. Per-pixel priority resolver with
// alpha blend + brightness, 3D as a color-keyed layer (spr > 3D > BG ties).

module ppu_top #(
    parameter SCREEN_W = 480,
    parameter SCREEN_H = 272
) (
    input  wire         clk,
    input  wire         rst,

    // frame control
    input  wire         frame_start,
    output reg          frame_done,
    // paced mode: after each streamed line, wait for line_go (scanout's
    // line_req) before rendering the next. Tie pace_en=0 to free-run.
    input  wire         pace_en,
    input  wire         line_go,
    input  wire [8:0]   line_go_y,   // strict lock-step: render exactly this line
    input  wire         cache_flush, // invalidate cache (tie to asset uploads)

    // layer config, packed [layer3|layer2|layer1|layer0]
    input  wire [3:0]   layer_en,
    input  wire [7:0]   layer_pri,     // 2b per layer, 0 = front
    input  wire [39:0]  scroll_x_all,  // 10b per layer
    input  wire [35:0]  scroll_y_all,  // 9b per layer
    input  wire [127:0] map_base_all,  // 32b per layer (word addr)
    input  wire [127:0] tile_base_all, // 32b per layer (word addr)
    input  wire [15:0]  backdrop,

    // affine mode for layers 2/3, params packed x2
    input  wire [1:0]   layer_affine,
    input  wire [31:0]  aff_pa_all,
    input  wire [31:0]  aff_pb_all,
    input  wire [31:0]  aff_pc_all,
    input  wire [31:0]  aff_pd_all,
    input  wire [35:0]  aff_ox_all,
    input  wire [35:0]  aff_oy_all,

    // sprites
    input  wire         spr_en,
    input  wire [31:0]  spr_tile_base,
    input  wire         oam_wen,
    input  wire [8:0]   oam_waddr,
    input  wire [31:0]  oam_wdata,
    input  wire         mat_wen,
    input  wire [6:0]   mat_waddr,
    input  wire [15:0]  mat_wdata,

    // 3D layer (RasterIX color buffer in memory: RGB565, 2 px/word)
    input  wire         t3d_en,
    input  wire [1:0]   t3d_pri,
    input  wire [31:0]  t3d_base,
    input  wire         t3d_key_en,
    input  wire [15:0]  t3d_key,

    // blending / brightness
    input  wire [5:0]   blend_en,      // per source: {bg3,bg2,bg1,bg0,3d,spr}
    input  wire [4:0]   eva,
    input  wire [4:0]   evb,
    input  wire [1:0]   bright_mode,   // 0 none, 1 lighten, 2 darken
    input  wire [4:0]   bright,

    // palette preload (shared)
    input  wire         pal_wen,
    input  wire [7:0]   pal_waddr,
    input  wire [15:0]  pal_wdata,

    // memory read port (behavioral mem or the SDRAM controller adapter)
    output wire [31:0]  m_araddr,
    output wire         m_arvalid,
    output wire         m_burst,     // 8-word burst (8-aligned address)
    input  wire         m_arready,
    input  wire [31:0]  m_rdata,
    input  wire         m_rvalid,

    // cache stats (A3 measurement)
    output wire [31:0]  stat_hits,
    output wire [31:0]  stat_misses,

    // sim debug
    output wire [2:0]   dbg_fstate,
    output wire [7:0]   dbg_done_seen,
    output wire [7:0]   dbg_unit_en,
    output wire [3:0]   dbg_spr_state,
    output wire [1:0]   dbg_cache_state,
    output wire [4:0]   dbg_arb,   // {busy, owner}
    output wire [4:0]   dbg_arb2,
    output wire [11:0]  dbg_bg_states,
    output wire [7:0]   dbg_done_cnt,  // bg0 done pulses (wrap)
    output wire [2:0]   dbg_c,         // {c_arvalid, c_arready, c_rvalid}

    // pixel stream out
    output reg          out_valid,
    output reg  [8:0]   out_x,
    output reg  [8:0]   out_line,
    output reg  [15:0]  out_pixel
);

    reg [8:0] line_y;

    // arbitration + cache 
    // renderers (7 ports: 0-3=bg, 4-5=aff, 6=spr) -> arbiter -> CACHE -> \
    //                                     3D stream (uncached, once/frame) -> arb2 -> mem

    wire [223:0] arb_araddr;
    wire [6:0]   arb_arvalid;
    wire [6:0]   arb_arready;
    wire [6:0]   arb_rvalid;
    wire [31:0]  arb_rdata;

    wire [31:0] c_araddr;
    wire        c_arvalid;
    wire        c_arready;
    wire [31:0] c_rdata;
    wire        c_rvalid;

    wire arb_mburst_nc; // renderers issue single words; cache makes the bursts

    ppu_arbiter #(.N(7)) arb (
        .clk(clk), .rst(rst),
        .s_araddr(arb_araddr),
        .s_arvalid(arb_arvalid),
        .s_burst(7'b0),
        .s_arready(arb_arready),
        .s_rvalid(arb_rvalid),
        .s_rdata(arb_rdata),
        .m_araddr(c_araddr),
        .m_arvalid(c_arvalid),
        .m_burst(arb_mburst_nc),
        .m_arready(c_arready),
        .m_rdata(c_rdata),
        .m_rvalid(c_rvalid),
        .dbg_busy(dbg_arb[4]),
        .dbg_owner(dbg_arb[3:0])
    );

    // cache master side + 3D direct -> final 2-port arbiter to memory
    wire [31:0] cm_araddr;
    wire        cm_arvalid;
    wire        cm_burst;
    wire        cm_arready;
    wire [31:0] cm_rdata;
    wire        cm_rvalid;
    wire        t3d_burst;

    ppu_cache cache (
        .clk(clk), .rst(rst),
        .flush(cache_flush),
        .s_araddr(c_araddr),
        .s_arvalid(c_arvalid),
        .s_arready(c_arready),
        .s_rdata(c_rdata),
        .s_rvalid(c_rvalid),
        .m_araddr(cm_araddr),
        .m_arvalid(cm_arvalid),
        .m_burst(cm_burst),
        .m_arready(cm_arready),
        .m_rdata(cm_rdata),
        .m_rvalid(cm_rvalid),
        .stat_hits(stat_hits),
        .stat_misses(stat_misses),
        .dbg_state(dbg_cache_state)
    );

    wire [63:0] arb2_araddr;
    wire [1:0]  arb2_arvalid;
    wire [1:0]  arb2_arready;
    wire [1:0]  arb2_rvalid;
    wire [31:0] arb2_rdata;

    ppu_arbiter #(.N(2)) arb2 (
        .clk(clk), .rst(rst),
        .s_araddr(arb2_araddr),
        .s_arvalid(arb2_arvalid),
        .s_burst({t3d_burst, cm_burst}),
        .s_arready(arb2_arready),
        .s_rvalid(arb2_rvalid),
        .s_rdata(arb2_rdata),
        .m_araddr(m_araddr),
        .m_arvalid(m_arvalid),
        .m_burst(m_burst),
        .m_arready(m_arready),
        .m_rdata(m_rdata),
        .m_rvalid(m_rvalid),
        .dbg_busy(dbg_arb2[4]),
        .dbg_owner(dbg_arb2[3:0])
    );

    assign arb2_araddr[0*32 +: 32] = cm_araddr;
    assign arb2_arvalid[0]         = cm_arvalid;
    assign cm_arready              = arb2_arready[0];
    assign cm_rdata                = arb2_rdata;
    assign cm_rvalid               = arb2_rvalid[0];

    // 3D line fetcher (port 0)

    reg         t3d_start;
    wire        t3d_done;
    wire [31:0] t3d_araddr;
    wire        t3d_arvalid;
    wire [7:0]  t3d_lbword;
    wire [31:0] t3d_lbdata;
    wire        t3d_lbwen;

    ppu_t3d_fetch #(.LINE_W(SCREEN_W)) t3df (
        .clk(clk), .rst(rst),
        .start(t3d_start),
        .done(t3d_done),
        .line_y(line_y),
        .base(t3d_base),
        .m_araddr(t3d_araddr),
        .m_arvalid(t3d_arvalid),
        .m_burst(t3d_burst),
        .m_arready(arb2_arready[1]),
        .m_rdata(arb2_rdata),
        .m_rvalid(arb2_rvalid[1]),
        .lb_word(t3d_lbword),
        .lb_data(t3d_lbdata),
        .lb_wen(t3d_lbwen)
    );

    assign arb2_araddr[1*32 +: 32] = t3d_araddr;
    assign arb2_arvalid[1]         = t3d_arvalid;

    // text BG layers (ports 1-4) 

    reg  [3:0]  bg_start;
    wire [3:0]  bg_done;
    wire [31:0] araddr_l  [0:3];
    wire        arvalid_l [0:3];
    wire [8:0]  lbwa_l    [0:3];
    wire [15:0] lbwd_l    [0:3];
    wire        lbop_l    [0:3];
    wire        lbwe_l    [0:3];

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1)
        begin : layers
            ppu_bg_line #(
                .LINE_W(SCREEN_W)
            ) bg (
                .clk(clk),
                .rst(rst),
                .start(bg_start[gi]),
                .done(bg_done[gi]),
                .line_y(line_y),
                .scroll_x(scroll_x_all[gi*10 +: 10]),
                .scroll_y(scroll_y_all[gi*9 +: 9]),
                .map_base(map_base_all[gi*32 +: 32]),
                .tile_base(tile_base_all[gi*32 +: 32]),
                .pal_wen(pal_wen),
                .pal_waddr(pal_waddr),
                .pal_wdata(pal_wdata),
                .m_araddr(araddr_l[gi]),
                .m_arvalid(arvalid_l[gi]),
                .m_arready(arb_arready[gi]),
                .m_rdata(arb_rdata),
                .m_rvalid(arb_rvalid[gi]),
                .lb_waddr(lbwa_l[gi]),
                .lb_wdata(lbwd_l[gi]),
                .lb_wopaque(lbop_l[gi]),
                .lb_wen(lbwe_l[gi]),
                .dbg_state(dbg_bg_states[gi*3 +: 3])
            );
            assign arb_araddr[gi*32 +: 32] = araddr_l[gi];
            assign arb_arvalid[gi]         = arvalid_l[gi];
        end
    endgenerate

    // affine units for layers 2/3 (ports 5-6) 

    reg  [1:0]  aff_start;
    wire [1:0]  aff_done;
    wire [31:0] aff_araddr  [0:1];
    wire        aff_arvalid [0:1];
    wire [8:0]  aff_lbwa    [0:1];
    wire [15:0] aff_lbwd    [0:1];
    wire        aff_lbop    [0:1];
    wire        aff_lbwe    [0:1];

    genvar ga;
    generate
        for (ga = 0; ga < 2; ga = ga + 1)
        begin : afflayers
            ppu_bg_affine_line #(
                .LINE_W(SCREEN_W)
            ) aff (
                .clk(clk),
                .rst(rst),
                .start(aff_start[ga]),
                .done(aff_done[ga]),
                .line_y(line_y),
                .pa($signed(aff_pa_all[ga*16 +: 16])),
                .pb($signed(aff_pb_all[ga*16 +: 16])),
                .pc($signed(aff_pc_all[ga*16 +: 16])),
                .pd($signed(aff_pd_all[ga*16 +: 16])),
                .ox($signed(aff_ox_all[ga*18 +: 18])),
                .oy($signed(aff_oy_all[ga*18 +: 18])),
                .map_base(map_base_all[(ga+2)*32 +: 32]),
                .tile_base(tile_base_all[(ga+2)*32 +: 32]),
                .pal_wen(pal_wen),
                .pal_waddr(pal_waddr),
                .pal_wdata(pal_wdata),
                .m_araddr(aff_araddr[ga]),
                .m_arvalid(aff_arvalid[ga]),
                .m_arready(arb_arready[4+ga]),
                .m_rdata(arb_rdata),
                .m_rvalid(arb_rvalid[4+ga]),
                .lb_waddr(aff_lbwa[ga]),
                .lb_wdata(aff_lbwd[ga]),
                .lb_wopaque(aff_lbop[ga]),
                .lb_wen(aff_lbwe[ga])
            );
            assign arb_araddr[(4+ga)*32 +: 32] = aff_araddr[ga];
            assign arb_arvalid[4+ga]           = aff_arvalid[ga];
        end
    endgenerate

    // sprite unit (port 7) 

    reg         spr_start;
    wire        spr_done;
    wire [31:0] spr_araddr;
    wire        spr_arvalid;
    wire [8:0]  spr_lbwa;
    wire [15:0] spr_lbwd;
    wire [1:0]  spr_lbpri;
    wire        spr_lbwe;
    wire        spr_lbclear;

    ppu_spr_line #(
        .LINE_W(SCREEN_W)
    ) spr (
        .clk(clk),
        .rst(rst),
        .start(spr_start),
        .done(spr_done),
        .line_y(line_y),
        .tile_base(spr_tile_base),
        .oam_wen(oam_wen),
        .oam_waddr(oam_waddr),
        .oam_wdata(oam_wdata),
        .mat_wen(mat_wen),
        .mat_waddr(mat_waddr),
        .mat_wdata(mat_wdata),
        .pal_wen(pal_wen),
        .pal_waddr(pal_waddr),
        .pal_wdata(pal_wdata),
        .m_araddr(spr_araddr),
        .m_arvalid(spr_arvalid),
        .m_arready(arb_arready[6]),
        .m_rdata(arb_rdata),
        .m_rvalid(arb_rvalid[6]),
        .lb_waddr(spr_lbwa),
        .lb_wdata(spr_lbwd),
        .lb_wpri(spr_lbpri),
        .lb_wen(spr_lbwe),
        .lb_clear(spr_lbclear),
        .dbg_state(dbg_spr_state)
    );

    assign arb_araddr[6*32 +: 32] = spr_araddr;
    assign arb_arvalid[6]         = spr_arvalid;

    // line buffers 

    reg [16:0] lb0 [0:SCREEN_W-1];
    reg [16:0] lb1 [0:SCREEN_W-1];
    reg [16:0] lb2 [0:SCREEN_W-1];
    reg [16:0] lb3 [0:SCREEN_W-1];

    always @(posedge clk)
    begin
        if (lbwe_l[0]) lb0[lbwa_l[0]] <= {lbop_l[0], lbwd_l[0]};
        if (lbwe_l[1]) lb1[lbwa_l[1]] <= {lbop_l[1], lbwd_l[1]};
        if (layer_affine[0] ? aff_lbwe[0] : lbwe_l[2])
            lb2[layer_affine[0] ? aff_lbwa[0] : lbwa_l[2]]
                <= layer_affine[0] ? {aff_lbop[0], aff_lbwd[0]} : {lbop_l[2], lbwd_l[2]};
        if (layer_affine[1] ? aff_lbwe[1] : lbwe_l[3])
            lb3[layer_affine[1] ? aff_lbwa[1] : lbwa_l[3]]
                <= layer_affine[1] ? {aff_lbop[1], aff_lbwd[1]} : {lbop_l[3], lbwd_l[3]};
    end

    // sprite line buffer: {pri, RGB565} + validity bitmap
    reg [17:0]          lbs [0:SCREEN_W-1];
    reg [SCREEN_W-1:0]  lbs_valid;

    always @(posedge clk)
    begin
        if (spr_lbclear)
        begin
            lbs_valid <= {SCREEN_W{1'b0}};
        end
        else if (spr_lbwe)
        begin
            lbs[spr_lbwa]       <= {spr_lbpri, spr_lbwd};
            lbs_valid[spr_lbwa] <= 1'b1;
        end
    end

    // 3D line buffer: even/odd pixel banks so each array has exactly one
    // write port and one sync read port (clean EBR mapping)
    reg [15:0] lb3d_e [0:SCREEN_W/2-1];
    reg [15:0] lb3d_o [0:SCREEN_W/2-1];
    always @(posedge clk)
    begin
        if (t3d_lbwen)
        begin
            lb3d_e[t3d_lbword] <= t3d_lbdata[15:0];
            lb3d_o[t3d_lbword] <= t3d_lbdata[31:16];
        end
    end

    // streamout pipeline
    // stage 0: sync line-buffer reads (EBR-friendly)  ->
    // stage 1: priority resolve                       ->
    // stage 2: blend + brightness -> out_pixel

    reg [8:0]  sx;

    // stage 0/1 registers
    reg        p1_v;
    reg [8:0]  p1_sx, p1_line;
    reg [16:0] p1_bg [0:3];
    reg [15:0] p1_3d_e, p1_3d_o;
    reg [17:0] p1_spr;
    reg        p1_spr_valid;

    always @(posedge clk)
    begin
        p1_bg[0]     <= lb0[sx];
        p1_bg[1]     <= lb1[sx];
        p1_bg[2]     <= lb2[sx];
        p1_bg[3]     <= lb3[sx];
        p1_3d_e      <= lb3d_e[sx[8:1]];
        p1_3d_o      <= lb3d_o[sx[8:1]];
        p1_spr       <= lbs[sx];
        p1_spr_valid <= lbs_valid[sx] && spr_en;
        p1_sx        <= sx;
        p1_line      <= line_y;
    end

    wire [15:0] p1_3d = p1_sx[0] ? p1_3d_o : p1_3d_e;

    // candidates in tie-rank order spr > 3d > bg0..bg3 (from stage-1 regs)
    wire [5:0]  c_valid_w;
    wire [15:0] c_color_w [0:5];
    wire [1:0]  c_pri_w   [0:5];

    assign c_valid_w[0] = p1_spr_valid;
    assign c_color_w[0] = p1_spr[15:0];
    assign c_pri_w[0]   = p1_spr[17:16];
    assign c_valid_w[1] = t3d_en && !(t3d_key_en && (p1_3d == t3d_key));
    assign c_color_w[1] = p1_3d;
    assign c_pri_w[1]   = t3d_pri;

    genvar gc;
    generate
        for (gc = 0; gc < 4; gc = gc + 1)
        begin : cands
            assign c_valid_w[2+gc] = layer_en[gc] && p1_bg[gc][16];
            assign c_color_w[2+gc] = p1_bg[gc][15:0];
            assign c_pri_w[2+gc]   = layer_pri[gc*2 +: 2];
        end
    endgenerate

    // stage 1b: registered candidate set (keeps EBR clk-to-q + key compare
    // out of the resolver cone)
    reg        p1b_v;
    reg [8:0]  p1b_sx, p1b_line;
    reg [5:0]  c_valid;
    reg [15:0] c_color [0:5];
    reg [1:0]  c_pri   [0:5];
    integer ck;
    always @(posedge clk)
    begin
        p1b_v    <= p1_v;
        p1b_sx   <= p1_sx;
        p1b_line <= p1_line;
        c_valid  <= c_valid_w;
        for (ck = 0; ck < 6; ck = ck + 1)
        begin
            c_color[ck] <= c_color_w[ck];
            c_pri[ck]   <= c_pri_w[ck];
        end
    end

    reg [15:0] win_color, blw_color;
    reg [2:0]  win_src;
    reg        win_found, blw_found;
    integer p, ci;
    always @(*)
    begin
        win_color = backdrop;
        blw_color = backdrop;
        win_src   = 3'd7;
        win_found = 1'b0;
        blw_found = 1'b0;
        for (p = 0; p < 4; p = p + 1)
        begin
            for (ci = 0; ci < 6; ci = ci + 1)
            begin
                if (c_valid[ci] && (c_pri[ci] == p[1:0]))
                begin
                    if (!win_found)
                    begin
                        win_color = c_color[ci];
                        win_src   = ci[2:0];
                        win_found = 1'b1;
                    end
                    else if (!blw_found && (ci[2:0] != win_src))
                    begin
                        blw_color = c_color[ci];
                        blw_found = 1'b1;
                    end
                end
            end
        end
    end

    // stage 2 registers
    reg        p2_v;
    reg [8:0]  p2_sx, p2_line;
    reg [15:0] p2_win, p2_blw;
    reg        p2_blend;

    always @(posedge clk)
    begin
        p2_v     <= p1b_v;
        p2_sx    <= p1b_sx;
        p2_line  <= p1b_line;
        p2_win   <= win_color;
        p2_blw   <= blw_color;
        p2_blend <= win_found && blend_en[win_src[2:0]];
    end

    wire do_blend = p2_blend;

    function [15:0] blend565;
        input [15:0] a;
        input [15:0] b;
        input [4:0]  ka;
        input [4:0]  kb;
        reg [9:0] r, g, bl;
        begin
            r  = (a[15:11] * ka + b[15:11] * kb) >> 4;
            g  = (a[10:5]  * ka + b[10:5]  * kb) >> 4;
            bl = (a[4:0]   * ka + b[4:0]   * kb) >> 4;
            blend565 = { (r  > 10'd31) ? 5'd31 : r[4:0],
                         (g  > 10'd63) ? 6'd63 : g[5:0],
                         (bl > 10'd31) ? 5'd31 : bl[4:0] };
        end
    endfunction

    // stage 3: blend result registered before brightness
    reg        p3_v;
    reg [8:0]  p3_sx, p3_line;
    reg [15:0] p3_color;

    always @(posedge clk)
    begin
        p3_v     <= p2_v;
        p3_sx    <= p2_sx;
        p3_line  <= p2_line;
        p3_color <= do_blend ? blend565(p2_win, p2_blw, eva, evb) : p2_win;
    end

    function [15:0] bright565;
        input [15:0] a;
        input [1:0]  mode;
        input [4:0]  k;
        reg [9:0] r, g, bl;
        begin
            if (mode == 2'd1)
            begin
                r  = a[15:11] + (((5'd31 - a[15:11]) * k) >> 4);
                g  = a[10:5]  + (((6'd63 - a[10:5])  * k) >> 4);
                bl = a[4:0]   + (((5'd31 - a[4:0])   * k) >> 4);
            end
            else if (mode == 2'd2)
            begin
                r  = a[15:11] - ((a[15:11] * k) >> 4);
                g  = a[10:5]  - ((a[10:5]  * k) >> 4);
                bl = a[4:0]   - ((a[4:0]   * k) >> 4);
            end
            else
            begin
                r  = {5'd0, a[15:11]};
                g  = {4'd0, a[10:5]};
                bl = {5'd0, a[4:0]};
            end
            bright565 = {r[4:0], g[5:0], bl[4:0]};
        end
    endfunction

    wire [15:0] resolved = bright565(p3_color, bright_mode, bright);

    // frame sequencer: start everything, wait all, stream 

    // unit enables/dones: {spr, aff3, aff2, bg3, bg2, bg1, bg0, t3d}
    wire [7:0] unit_en = {
        spr_en,
        layer_en[3] && layer_affine[1],
        layer_en[2] && layer_affine[0],
        layer_en[3] && !layer_affine[1],
        layer_en[2] && !layer_affine[0],
        layer_en[1],
        layer_en[0],
        t3d_en
    };
    wire [7:0] unit_done_now = {
        spr_done, aff_done[1], aff_done[0],
        bg_done[3], bg_done[2], bg_done[1], bg_done[0],
        t3d_done
    };
    reg [7:0] done_seen;
    reg [2:0] drain;

    assign dbg_fstate    = fstate;
    assign dbg_c = {c_arvalid, c_arready, c_rvalid};
    reg [7:0] done_cnt_r;
    always @(posedge clk) if (bg_done[0]) done_cnt_r <= done_cnt_r + 8'd1;
    assign dbg_done_cnt = done_cnt_r;
    assign dbg_done_seen = done_seen;
    assign dbg_unit_en   = unit_en;

    localparam F_IDLE   = 3'd0;
    localparam F_RUN    = 3'd1;
    localparam F_STREAM = 3'd2;
    localparam F_DONE   = 3'd3;
    localparam F_WAITGO = 3'd4;

    reg [2:0] fstate;
    reg       go_pend;   // latest-wins line request from the scanout
    reg [8:0] go_y;

    always @(posedge clk)
    begin
        bg_start   <= 4'b0;
        aff_start  <= 2'b0;
        spr_start  <= 1'b0;
        t3d_start  <= 1'b0;
        p1_v       <= 1'b0;
        frame_done <= 1'b0;

        // pipeline tail drives the stream outputs every cycle
        out_valid <= p3_v;
        out_x     <= p3_sx;
        out_line  <= p3_line;
        out_pixel <= resolved;

        if (rst)
        begin
            fstate  <= F_IDLE;
            line_y  <= 9'd0;
            go_pend <= 1'b0;
        end
        else
        begin
            // latest-wins: if the renderer ever falls behind, it skips
            // straight to the newest requested line (one stale display line,
            // then resynced -- drift is structurally impossible)
            if (line_go)
            begin
                go_pend <= 1'b1;
                go_y    <= line_go_y;
            end

            case (fstate)
                F_IDLE:
                begin
                    if (frame_start)
                    begin
                        line_y <= 9'd0;
                        done_seen <= 8'd0;
                        bg_start  <= {layer_en[3] && !layer_affine[1],
                                      layer_en[2] && !layer_affine[0],
                                      layer_en[1], layer_en[0]};
                        aff_start <= {layer_en[3] && layer_affine[1],
                                      layer_en[2] && layer_affine[0]};
                        spr_start <= spr_en;
                        t3d_start <= t3d_en;
                        fstate    <= F_RUN;
                    end
                end

                F_RUN:
                begin
                    done_seen <= done_seen | unit_done_now;
                    if (((done_seen | unit_done_now) & unit_en) == unit_en)
                    begin
                        sx     <= 9'd0;
                        drain  <= 2'd0;
                        fstate <= F_STREAM;
                    end
                end

                F_STREAM:
                begin
                    if (sx != SCREEN_W[8:0])
                    begin
                        p1_v <= 1'b1;          // issue stage-0 read for sx
                        sx   <= sx + 9'd1;
                    end
                    else if (drain != 3'd4)
                    begin
                        drain <= drain + 3'd1; // let the pipeline empty
                    end
                    else if (pace_en)
                    begin
                        if (line_y == SCREEN_H[8:0] - 9'd1)
                        begin
                            frame_done <= 1'b1; // pulse; loop continues paced
                        end
                        fstate <= F_WAITGO;
                    end
                    else if (line_y == SCREEN_H[8:0] - 9'd1)
                    begin
                        fstate <= F_DONE;
                    end
                    else
                    begin
                        line_y    <= line_y + 9'd1;
                        done_seen <= 8'd0;
                        bg_start  <= {layer_en[3] && !layer_affine[1],
                                      layer_en[2] && !layer_affine[0],
                                      layer_en[1], layer_en[0]};
                        aff_start <= {layer_en[3] && layer_affine[1],
                                      layer_en[2] && layer_affine[0]};
                        spr_start <= spr_en;
                        t3d_start <= t3d_en;
                        fstate    <= F_RUN;
                    end
                end

                F_WAITGO:
                begin
                    if (go_pend)
                    begin
                        go_pend   <= 1'b0;
                        line_y    <= go_y;
                        done_seen <= 8'd0;
                        bg_start  <= {layer_en[3] && !layer_affine[1],
                                      layer_en[2] && !layer_affine[0],
                                      layer_en[1], layer_en[0]};
                        aff_start <= {layer_en[3] && layer_affine[1],
                                      layer_en[2] && layer_affine[0]};
                        spr_start <= spr_en;
                        t3d_start <= t3d_en;
                        fstate    <= F_RUN;
                    end
                end

                F_DONE:
                begin
                    frame_done <= 1'b1;
                    fstate     <= F_IDLE;
                end

                default: fstate <= F_IDLE;
            endcase
        end
    end

endmodule