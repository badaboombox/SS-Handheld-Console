// SS Handheld - GPU SoC top v0.2 (sim)
//
// The whole FPGA design stitched: FMC bridge -> register file (vsync-latched)
// -> PPU (scanout-paced) + RasterIX 3D core (cmd stream via FMC STREAM
// window, memory via axi_sdram_bridge, color buffer -> SDRAM -> PPU 3D
// layer on swap_fb) -> SDRAM (controller + sim model, 3-client mux with
// owner lock) -> double-banked line buffer -> DPI scanout -> panel pins.
//
// Clocking note: split clocks - GPU domain `clk` (66.67) + SDRAM domain
// `clk_sdram` (133.33, own domain inside sdram_cdc), CDC verified pixel-exact.
// PERFORMANCE FINDING (2026-07-04): the worst-case golden scene render is
// ~5400 clk/line (comb sweep: CE_DIV 7/8/10 = 70/52/9.6% differ, 14 = 0%), so
// it fits ~CE_DIV=11-12 ≈ 37-40 fps - NOT the 60 fps target (CE_DIV=7, 3675
// clk). Standalone v0.6 PPU was 2360 clk (60 fps+); SoC integration (real
// SDRAM miss latency + single-outstanding CDC + RasterIX contention) more than
// doubled it. Memory-stall-bound, not compute-bound → 60 fps needs miss-hiding
// (multi-outstanding SDRAM / prefetch), not a faster clock. CE_DIV=14 here for
// a pixel-exact regression; see Bringup_Log "60 fps gap".

module gpu_top #(
    parameter CE_DIV = 14,
    // RasterIX core sizing. CHIP-CORRECT defaults = the A1-validated
    // synthesizable config: TMU=1, MAX_TEXTURE_SIZE=128. TMU=2/256 does NOT
    // fit the LFE5U-85 (485 EBR / 220 DSP vs 208/156 - see Bringup_Log). The
    // sim overrides these to match its prebuilt reference core when needed.
    parameter RIX_TMU_COUNT   = 1,
    parameter RIX_MAX_TEX     = 128,
    // 1 = instantiate the behavioral SDRAM model internally (Verilator sim);
    // 0 = drive the SDRAM PHY pins (real chip / synthesis).
    parameter SIM_SDRAM       = 1
) (
    input  wire        clk,          // GPU domain (~66.67 MHz)
    input  wire        clk_sdram,    // SDRAM domain (~133.33 MHz)
    input  wire        rst,

    // FMC (CPU)
    input  wire        fmc_ne,
    input  wire        fmc_nwe,
    input  wire        fmc_noe,
    input  wire [9:0]  fmc_a,
    input  wire [15:0] fmc_d_i,
    output wire [15:0] fmc_d_o,
    output wire        fmc_d_oe,
    output wire        fmc_nwait,   // cmd FIFO nearly full (pad handles polarity)
    output wire        cpu_irq,     // vblank

    // panel
    output wire        pclk,
    output wire        hsync,
    output wire        vsync,
    output wire        de,
    output wire [23:0] rgb,

    // SDRAM PHY (external chip on the board; sim connects the model when
    // SIM_SDRAM=1). dq is split i/o/oe here - the true board top wraps it
    // in a tristate pad.
    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [1:0]  sdram_ba,
    output wire [11:0] sdram_a,
    output wire [3:0]  sdram_dqm,
    output wire [31:0] sdram_dq_o,
    output wire        sdram_dq_oe,
    input  wire [31:0] sdram_dq_i,

    // sim debug taps
    output wire [8:0]  dbg_ppu_line,
    output wire        dbg_ppu_outv,
    output wire        dbg_frame_done,
    output wire [2:0]  dbg_fstate,
    output wire [7:0]  dbg_done_seen,
    output wire [7:0]  dbg_unit_en,
    output wire [3:0]  dbg_spr_state,
    output wire [1:0]  dbg_cache_state,
    output wire [4:0]  dbg_arb,
    output wire [4:0]  dbg_arb2,
    output wire [11:0] dbg_bg_states,
    output wire [7:0]  dbg_done_cnt,
    output wire [2:0]  dbg_c,
    output wire [7:0]  dbg_swap_cnt,
    output wire        dbg_cmd_tready,
    output wire [15:0] dbg_axi
);

    // FMC bridge 

    wire        rw_wen;
    wire [7:0]  rw_addr;
    wire [15:0] rw_wdata;
    wire        up_wen;
    wire [21:0] up_addr;
    wire [31:0] up_wdata;
    wire [31:0] cmd_tdata;
    wire        cmd_tvalid;
    wire        cmd_tready;
    wire        sd_init_done;
    wire        scan_vsync_irq;

    fmc_bridge bridge (
        .clk(clk), .rst(rst),
        .fmc_ne(fmc_ne), .fmc_nwe(fmc_nwe), .fmc_noe(fmc_noe),
        .fmc_a(fmc_a), .fmc_d_i(fmc_d_i), .fmc_d_o(fmc_d_o), .fmc_d_oe(fmc_d_oe),
        .rw_wen(rw_wen), .rw_addr(rw_addr), .rw_wdata(rw_wdata),
        .cmd_tdata(cmd_tdata), .cmd_tvalid(cmd_tvalid), .cmd_tready(cmd_tready),
        .up_wen(up_wen), .up_addr(up_addr), .up_wdata(up_wdata),
        .status_flags({13'b0, rix_swapped_flag, scan_vsync_irq, sd_init_done}),
        .fmc_wait(fmc_nwait)
    );

    // register file

    wire [3:0]   layer_en;
    wire         spr_en, t3d_en, t3d_key_en, display_en;
    wire [1:0]   layer_affine;
    wire [7:0]   layer_pri;
    wire [39:0]  scroll_x_all;
    wire [35:0]  scroll_y_all;
    wire [127:0] map_base_all, tile_base_all;
    wire [15:0]  backdrop, t3d_key;
    wire [5:0]   blend_en;
    wire [4:0]   eva, evb, bright;
    wire [1:0]   bright_mode, t3d_pri;
    wire [31:0]  t3d_base, spr_tile_base;
    wire [31:0]  aff_pa_all, aff_pb_all, aff_pc_all, aff_pd_all;
    wire [35:0]  aff_ox_all, aff_oy_all;
    wire         pal_wen, oam_wen, mat_wen;
    wire [7:0]   pal_waddr;
    wire [8:0]   oam_waddr;
    wire [15:0]  pal_wdata, mat_wdata;
    wire [31:0]  oam_wdata;
    wire [6:0]   mat_waddr;

    gpu_regfile regs (
        .clk(clk), .rst(rst),
        .rw_wen(rw_wen), .rw_addr(rw_addr), .rw_wdata(rw_wdata),
        .vsync(scan_vsync_irq),
        .layer_en(layer_en), .spr_en(spr_en), .t3d_en(t3d_en),
        .layer_affine(layer_affine), .display_en(display_en),
        .t3d_key_en(t3d_key_en), .layer_pri(layer_pri),
        .scroll_x_all(scroll_x_all), .scroll_y_all(scroll_y_all),
        .map_base_all(map_base_all), .tile_base_all(tile_base_all),
        .backdrop(backdrop), .blend_en(blend_en), .eva(eva), .evb(evb),
        .bright_mode(bright_mode), .bright(bright),
        .t3d_pri(t3d_pri), .t3d_key(t3d_key), .t3d_base(t3d_base),
        .spr_tile_base(spr_tile_base),
        .aff_pa_all(aff_pa_all), .aff_pb_all(aff_pb_all),
        .aff_pc_all(aff_pc_all), .aff_pd_all(aff_pd_all),
        .aff_ox_all(aff_ox_all), .aff_oy_all(aff_oy_all),
        .pal_wen(pal_wen), .pal_waddr(pal_waddr), .pal_wdata(pal_wdata),
        .oam_wen(oam_wen), .oam_waddr(oam_waddr), .oam_wdata(oam_wdata),
        .mat_wen(mat_wen), .mat_waddr(mat_waddr), .mat_wdata(mat_wdata)
    );

    // PPU (scanout-paced) 

    wire        scan_line_req;
    wire [8:0]  scan_line_req_y;
    wire [8:0]  scan_active_y;
    reg         frame_start;
    wire        frame_done;
    wire [31:0] p_araddr;
    wire        p_arvalid, p_burst;
    reg         p_arready;
    wire [31:0] p_rdata;
    wire        p_rvalid;
    wire        out_valid;
    wire [8:0]  out_x, out_line;
    wire [15:0] out_pixel;
    wire [31:0] stat_hits, stat_misses;

    always @(posedge clk) frame_start <= display_en && scan_vsync_irq;

    ppu_top ppu (
        .clk(clk), .rst(rst),
        .frame_start(frame_start), .frame_done(frame_done),
        .pace_en(1'b1), .line_go(scan_line_req), .line_go_y(scan_line_req_y), .cache_flush(up_wen),
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
        .t3d_en(t3d_en), .t3d_pri(t3d_pri), .t3d_base(t3d_base_eff),
        .t3d_key_en(t3d_key_en), .t3d_key(t3d_key),
        .blend_en(blend_en), .eva(eva), .evb(evb),
        .bright_mode(bright_mode), .bright(bright),
        .pal_wen(pal_wen), .pal_waddr(pal_waddr), .pal_wdata(pal_wdata),
        .m_araddr(p_araddr), .m_arvalid(p_arvalid), .m_burst(p_burst),
        .m_arready(p_arready), .m_rdata(p_rdata), .m_rvalid(p_rvalid),
        .stat_hits(stat_hits), .stat_misses(stat_misses),
        .dbg_fstate(dbg_fstate), .dbg_done_seen(dbg_done_seen),
        .dbg_unit_en(dbg_unit_en),
        .dbg_spr_state(dbg_spr_state), .dbg_cache_state(dbg_cache_state),
        .dbg_arb(dbg_arb), .dbg_arb2(dbg_arb2),
        .dbg_bg_states(dbg_bg_states), .dbg_done_cnt(dbg_done_cnt), .dbg_c(dbg_c),
        .out_valid(out_valid), .out_x(out_x),
        .out_line(out_line), .out_pixel(out_pixel)
    );

    // SDRAM (PPU reads + CPU uploads + RasterIX AXI muxed) 

    wire        c_ready;
    wire [31:0] c_rdata;
    wire        c_rvalid;
    wire        c_wdone;

    // RasterIX-side client (from axi_sdram_bridge)
    wire        b_req, b_we, b_burst;
    wire [21:0] b_addr;
    wire [31:0] b_wdata;
    wire [3:0]  b_wbe;

    // pending-transaction adapter: requests are LEVEL-held until the
    // controller consumes them (a pulse can be missed if a refresh wins
    // the same cycle - that hang cost a debug session; keep it level)
    reg         pend_rd, pend_wr;
    reg         burst_r;
    reg  [21:0] rd_addr_r;
    reg  [21:0] wr_addr_r;
    reg  [31:0] wdata_r;

    // owner lock: the controller's ready can reassert before the last rvalid
    // beat / wdone, so data return must be routed to the transaction's owner
    // and no new request may issue until the previous one fully completes
    reg         busy_lock;
    reg         own_b;      // 1 = RasterIX bridge owns the in-flight txn
    reg         lock_wr;
    reg  [3:0]  own_beats;

    wire a_want  = pend_rd || pend_wr;
    wire sel_b   = !a_want && b_req;          // PPU/upload beat RasterIX
    wire issue   = (a_want || b_req) && c_ready && !busy_lock;
    wire req_now = a_want && c_ready && !busy_lock;   // A-side consume
    wire we_now  = sel_b ? b_we : (!pend_rd && pend_wr);

    always @(posedge clk)
    begin
        p_arready <= 1'b0;

        if (rst)
        begin
            pend_rd   <= 1'b0;
            pend_wr   <= 1'b0;
            busy_lock <= 1'b0;
        end
        else
        begin
            if (up_wen)
            begin
                pend_wr   <= 1'b1;
                wr_addr_r <= up_addr;
                wdata_r   <= up_wdata;
            end

            if (p_arvalid && !pend_rd && !p_arready)
            begin
                pend_rd   <= 1'b1;
                burst_r   <= p_burst;
                rd_addr_r <= p_araddr[21:0];
                p_arready <= 1'b1;
            end

            if (req_now)
            begin
                if (we_now)
                    pend_wr <= 1'b0;
                else
                    pend_rd <= 1'b0;
            end

            if (issue)
            begin
                busy_lock <= 1'b1;
                own_b     <= sel_b;
                lock_wr   <= we_now;
                own_beats <= we_now ? 4'd0 : (burst_w ? 4'd8 : 4'd1);
            end
            else if (busy_lock)
            begin
                if (lock_wr && c_wdone)
                    busy_lock <= 1'b0;
                if (!lock_wr && c_rvalid)
                begin
                    own_beats <= own_beats - 4'd1;
                    if (own_beats == 4'd1)
                        busy_lock <= 1'b0;
                end
            end
        end
    end

    wire        req_r   = issue;
    wire        we_r    = we_now;
    wire        burst_w = sel_b ? b_burst : (we_now ? 1'b0 : burst_r);
    wire [21:0] addr_r  = sel_b ? b_addr  : (we_now ? wr_addr_r : rd_addr_r);
    wire [31:0] wdata_m = sel_b ? b_wdata : wdata_r;
    wire [3:0]  wbe_m   = sel_b ? b_wbe   : 4'hF;

    wire b_ready  = c_ready && sel_b && !busy_lock;
    wire b_rvalid = c_rvalid && busy_lock && own_b;
    wire b_wdone  = c_wdone  && busy_lock && own_b;

    assign p_rdata  = c_rdata;
    assign p_rvalid = c_rvalid && busy_lock && !own_b;

    wire [31:0] dq_c2m;          // controller -> chip (write data)
    wire [31:0] dq_m2c;          // chip -> controller (read data)
    wire        dq_oe;

    // controller reads either the internal sim model or the external pin
    wire [31:0] cdc_dq_i = SIM_SDRAM ? dq_m2c : sdram_dq_i;

    // sdram_ctrl now lives in its own clk_sdram (133) domain inside sdram_cdc;
    // it presents the identical host interface on clk, so the mux above is
    // unchanged. INIT_WAIT shrunk for sim (real bitstream overrides via param).
    sdram_cdc #(
        .INIT_WAIT(64)
    ) cdc (
        .clk_gpu(clk), .clk_sdram(clk_sdram), .rst(rst),
        .req(req_r), .we(we_r), .burst(burst_w), .addr(addr_r),
        .wdata(wdata_m), .wbe(wbe_m),
        .ready(c_ready), .rdata(c_rdata), .rvalid(c_rvalid),
        .wdone(c_wdone), .init_done(sd_init_done),
        .s_cke(sdram_cke), .s_cs_n(sdram_cs_n), .s_ras_n(sdram_ras_n),
        .s_cas_n(sdram_cas_n), .s_we_n(sdram_we_n),
        .s_ba(sdram_ba), .s_a(sdram_a), .s_dqm(sdram_dqm),
        .s_dq_i(cdc_dq_i), .s_dq_o(dq_c2m), .s_dq_oe(dq_oe)
    );

    assign sdram_dq_o  = dq_c2m;
    assign sdram_dq_oe = dq_oe;

    generate
    if (SIM_SDRAM)
    begin : g_sim_sdram
        sdram_model model (
            .clk(clk_sdram),
            .s_cke(sdram_cke), .s_cs_n(sdram_cs_n), .s_ras_n(sdram_ras_n),
            .s_cas_n(sdram_cas_n), .s_we_n(sdram_we_n),
            .s_ba(sdram_ba), .s_a(sdram_a), .s_dqm(sdram_dqm),
            .s_dq_i(dq_c2m), .s_dq_o(dq_m2c), .s_dq_oe(dq_oe)
        );
    end
    endgenerate

    // RasterIX 3D core 
    //
    // s_cmd_axis <- FMC STREAM FIFO (tlast tied 0: the protocol is length-
    // framed, FrameStreamingCore never reads tlast). Memory port -> our SDRAM
    // through axi_sdram_bridge. Color buffer strips land in SDRAM at fb_addr;
    // on swap_fb the front-buffer address is latched for the PPU's 3D layer
    // (sticky: until the first swap, the regfile's t3d_base drives the layer,
    // which keeps the 2D-only golden test and the SDRAM_UP path intact).

    wire        rix_swap, rix_swap_vs;
    wire [31:0] rix_fb_addr;
    wire [19:0] rix_fb_size;
    reg         rix_swapped;
    reg         swap_pend;
    reg         swap_d;
    reg         use_rix_fb;
    reg  [31:0] t3d_front;
    reg  [7:0]  swap_cnt;
    reg         rix_swapped_flag;   // sticky-ish status bit for CPU polling

    wire [31:0] t3d_base_eff = use_rix_fb ? t3d_front : t3d_base;

    // fb_swapped is an idle-HIGH level: the core treats 0 as "swap still in
    // progress" (it even gates its command parser on it) and takes the 0->1
    // edge as the acknowledge. Pulsing it low-idle deadlocks the parser.
    always @(posedge clk)
    begin
        if (rst)
        begin
            swap_pend        <= 1'b0;
            swap_d           <= 1'b0;
            use_rix_fb       <= 1'b0;
            swap_cnt         <= 8'd0;
            rix_swapped      <= 1'b1;
            rix_swapped_flag <= 1'b0;
        end
        else
        begin
            swap_d <= rix_swap;
            if (rix_swap && !swap_d)
            begin
                swap_pend   <= 1'b1;
                rix_swapped <= 1'b0;
            end

            // honor the core's vsync request: hold the swap until vblank so
            // the scanout never straddles two 3D frames
            if (swap_pend && (!rix_swap_vs || scan_vsync_irq))
            begin
                t3d_front        <= {8'b0, rix_fb_addr[25:2]};  // byte -> word
                use_rix_fb       <= 1'b1;
                rix_swapped      <= 1'b1;
                swap_pend        <= 1'b0;
                swap_cnt         <= swap_cnt + 8'd1;
                rix_swapped_flag <= 1'b1;
            end
        end
    end

    wire        x_awvalid, x_awready, x_wlast, x_wvalid, x_wready;
    wire        x_bvalid, x_bready, x_arvalid, x_arready;
    wire        x_rlast, x_rvalid, x_rready;
    wire [7:0]  x_awid, x_bid, x_arid, x_rid;
    wire [31:0] x_awaddr, x_araddr, x_wdata, x_rdata;
    wire [7:0]  x_awlen, x_arlen;
    wire [3:0]  x_wstrb;

    RasterIX #(
        .VARIANT("if"),
        .FRAMEBUFFER_SIZE_IN_PIXEL_LG(15),
        .FRAMEBUFFER_SUB_PIXEL_WIDTH(6),
        .SUB_PIXEL_CALC_PRECISION(8),
        .ENABLE_STENCIL_BUFFER(1),
        .ENABLE_DEPTH_BUFFER(1),
        .TMU_COUNT(RIX_TMU_COUNT),
        .ENABLE_MIPMAPPING(1),
        .ENABLE_TEXTURE_FILTERING(1),
        .TEXTURE_PAGE_SIZE(4096),
        .ENABLE_FOG(1),
        .MAX_TEXTURE_SIZE(RIX_MAX_TEX),
        .ADDR_WIDTH(32),
        .ID_WIDTH(8),
        .DATA_WIDTH(32),
        .ENABLE_MEMORY_COALESCING(1),
        .RASTERIZER_ENABLE_FLOAT_INTERPOLATION(0)
    ) rix (
        .aclk(clk),
        .resetn(!rst),

        .s_cmd_axis_tvalid(cmd_tvalid),
        .s_cmd_axis_tready(cmd_tready),
        .s_cmd_axis_tlast(1'b0),
        .s_cmd_axis_tdata(cmd_tdata),

        .m_cmd_resp_axis_tvalid(),      // board-phase: readback via STATUS
        .m_cmd_resp_axis_tready(1'b1),
        .m_cmd_resp_axis_tlast(),
        .m_cmd_resp_axis_tdata(),

        .swap_fb(rix_swap),
        .swap_fb_enable_vsync(rix_swap_vs),
        .fb_addr(rix_fb_addr),
        .fb_size(rix_fb_size),
        .fb_swapped(rix_swapped),

        .m_axi_awid(x_awid), .m_axi_awaddr(x_awaddr), .m_axi_awlen(x_awlen),
        .m_axi_awsize(), .m_axi_awburst(), .m_axi_awlock(),
        .m_axi_awcache(), .m_axi_awprot(),
        .m_axi_awvalid(x_awvalid), .m_axi_awready(x_awready),
        .m_axi_wdata(x_wdata), .m_axi_wstrb(x_wstrb), .m_axi_wlast(x_wlast),
        .m_axi_wvalid(x_wvalid), .m_axi_wready(x_wready),
        .m_axi_bid(x_bid), .m_axi_bresp(2'b00),
        .m_axi_bvalid(x_bvalid), .m_axi_bready(x_bready),
        .m_axi_arid(x_arid), .m_axi_araddr(x_araddr), .m_axi_arlen(x_arlen),
        .m_axi_arsize(), .m_axi_arburst(), .m_axi_arlock(),
        .m_axi_arcache(), .m_axi_arprot(),
        .m_axi_arvalid(x_arvalid), .m_axi_arready(x_arready),
        .m_axi_rid(x_rid), .m_axi_rdata(x_rdata), .m_axi_rresp(2'b00),
        .m_axi_rlast(x_rlast), .m_axi_rvalid(x_rvalid), .m_axi_rready(x_rready)
    );

    axi_sdram_bridge axi_br (
        .clk(clk), .rst(rst),
        .s_awid(x_awid), .s_awaddr(x_awaddr), .s_awlen(x_awlen),
        .s_awvalid(x_awvalid), .s_awready(x_awready),
        .s_wdata(x_wdata), .s_wstrb(x_wstrb), .s_wlast(x_wlast),
        .s_wvalid(x_wvalid), .s_wready(x_wready),
        .s_bid(x_bid), .s_bresp(), .s_bvalid(x_bvalid), .s_bready(x_bready),
        .s_arid(x_arid), .s_araddr(x_araddr), .s_arlen(x_arlen),
        .s_arvalid(x_arvalid), .s_arready(x_arready),
        .s_rid(x_rid), .s_rdata(x_rdata), .s_rresp(), .s_rlast(x_rlast),
        .s_rvalid(x_rvalid), .s_rready(x_rready),
        .m_req(b_req), .m_we(b_we), .m_burst(b_burst),
        .m_addr(b_addr), .m_wdata(b_wdata), .m_wbe(b_wbe),
        .m_ready(b_ready), .m_rdata(c_rdata), .m_rvalid(b_rvalid),
        .m_wdone(b_wdone),
        .dbg_state(dbg_axi_state)
    );

    wire [2:0] dbg_axi_state;
    assign dbg_axi = { cmd_tvalid, cmd_tready, b_req, busy_lock, own_b,
                       x_awvalid, x_wvalid, x_bvalid, x_arvalid, x_rvalid,
                       rix_swap, swap_pend, 1'b0, dbg_axi_state };

    // double-banked line buffer + scanout 

    reg [15:0] lbank0 [0:479];
    reg [15:0] lbank1 [0:479];

    always @(posedge clk)
    begin
        if (out_valid)
        begin
            if (out_line[0])
                lbank1[out_x] <= out_pixel;
            else
                lbank0[out_x] <= out_pixel;
        end
    end

    wire [8:0]  so_raddr;
    wire [15:0] so_rdata = scan_active_y[0] ? lbank1[so_raddr] : lbank0[so_raddr];

    dpi_scanout #(
        .CE_DIV(CE_DIV)
    ) scan (
        .clk(clk), .rst(rst),
        .lb_raddr(so_raddr),
        .lb_rdata(so_rdata),
        .line_req(scan_line_req),
        .line_req_y(scan_line_req_y),
        .vsync_irq(scan_vsync_irq),
        .active_y(scan_active_y),
        .pclk(pclk), .hsync(hsync), .vsync(vsync), .de(de), .rgb(rgb)
    );

    assign cpu_irq = scan_vsync_irq;

    assign dbg_ppu_line   = out_line;
    assign dbg_ppu_outv   = out_valid;
    assign dbg_frame_done = frame_done;
    assign dbg_swap_cnt   = swap_cnt;
    assign dbg_cmd_tready = cmd_tready;

endmodule