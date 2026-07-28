// SS Handheld 2D PPU - hit-under-miss memory server (v3)
//
// Replaces the single-outstanding 7-port arbiter + blocking cache. Same
// direct-mapped 64-line x 8-word cache and burst-8 fills, but NON-BLOCKING:
// while one line fill is in flight, the other renderers keep getting cache
// hits served (hit-under-miss). This hides the SDRAM miss latency (which the
// split-clock CDC made ~15-20 clk) behind the 86% hits instead of stalling all
// 7 ports on every miss, the SoC render was ~5400 clk/line (single-outstanding
// stalls) vs the 2360 clk compute floor; overlapping the misses recovers most
// of that toward the 60 fps line budget (3675 clk @ CE_DIV=7).
//
// One fill outstanding (hit-under-miss, miss-under-miss stalls the 2nd misser).
// Single shared response bus -> at most one rvalid/cycle; the fill's hot word
// is buffered 1-deep and drains on a free cycle (pick is gated while it waits).
// Hits keep the current 1-cycle latency; per-port routing tolerates the
// out-of-order returns (each unit has one outstanding word request).

module ppu_mem #(
    parameter N = 7
) (
    input  wire            clk,
    input  wire            rst,
    input  wire            flush,

    // requesters (single-word reads from the renderers)
    input  wire [N*32-1:0] s_araddr,
    input  wire [N-1:0]    s_arvalid,
    output wire [N-1:0]    s_arready,
    output reg  [N-1:0]    s_rvalid,
    output reg  [31:0]     s_rdata,

    // memory side (8-word burst fills) -> arb2 -> SDRAM
    output reg  [31:0]     m_araddr,
    output reg             m_arvalid,
    output wire            m_burst,
    input  wire            m_arready,
    input  wire [31:0]     m_rdata,
    input  wire            m_rvalid,

    output reg  [31:0]     stat_hits,
    output reg  [31:0]     stat_misses,
    output wire [1:0]      dbg_state
);
    // 64 lines: the 7-port parallel hit lookup (needed for hit-under-miss) is
    // a wide combinational mux, which caused 256 lines to tank Fmax to 52 MHz (P&R), 64
    // keeps ~74. Miss-hiding comes from hit-under-miss + (future) multiple
    // outstanding fills, not from a giant cache.
    localparam LINES = 64, IDXW = 6, OFFW = 3, TAGW = 32 - IDXW - OFFW;
    localparam PW = $clog2(N);

    reg [31:0]      data [0:LINES*8-1];
    reg [TAGW-1:0]  tag  [0:LINES-1];
    reg [LINES-1:0] valid;
    assign m_burst = 1'b1;

    // ---- per-port decode + hit ----
    wire [IDXW-1:0] pidx [0:N-1];
    wire [TAGW-1:0] ptag [0:N-1];
    wire [OFFW-1:0] poff [0:N-1];
    wire [N-1:0]    phit;
    genvar g;
    generate for (g = 0; g < N; g = g + 1)
    begin : dec
        assign poff[g] = s_araddr[g*32 +: OFFW];
        assign pidx[g] = s_araddr[g*32 + OFFW +: IDXW];
        assign ptag[g] = s_araddr[g*32 + OFFW + IDXW +: TAGW];
        assign phit[g] = valid[pidx[g]] && (tag[pidx[g]] == ptag[g]);
    end endgenerate

    // fill slot (one outstanding)
    localparam F_IDLE = 2'd0, F_MISS = 2'd1, F_FILL = 2'd2;
    reg [1:0]      fstate;
    reg            fill_busy;      // slot reserved (from accept until line valid)
    reg [IDXW-1:0] fill_idx;
    reg [TAGW-1:0] fill_tag;
    reg [OFFW-1:0] fill_off, want_off;
    reg [PW-1:0]   fill_port;
    assign dbg_state = fstate;

    // fill hot-word buffer (1 deep)
    reg          fh_pend;
    reg [PW-1:0] fh_port;
    reg [31:0]   fh_data;

    // ---- pick: highest priority (port 0) among serveable ----
    // serveable = valid request that hits, OR misses while the fill slot is free
    integer i;
    reg [PW-1:0] pick;
    reg          pick_v, pick_hit;
    always @(*)
    begin
        pick = {PW{1'b0}}; pick_v = 1'b0; pick_hit = 1'b0;
        for (i = N - 1; i >= 0; i = i - 1)
            if (s_arvalid[i] && (phit[i] || !fill_busy))
            begin
                pick = i[PW-1:0]; pick_v = 1'b1; pick_hit = phit[i];
            end
    end

    // gate accepts while a hot word waits for the bus, so it gets a free cycle
    wire accept = pick_v && !fh_pend;
    assign s_arready = accept ? ({{N-1{1'b0}}, 1'b1} << pick) : {N{1'b0}};

    // ---- pipeline stage 1 (registered accept) ----
    reg           p1_v, p1_hit;
    reg [PW-1:0]  p1_port;
    reg [IDXW-1:0] p1_idx;
    reg [OFFW-1:0] p1_off;
    reg [TAGW-1:0] p1_tag;
    reg [31:0]    p1_addr;

    always @(posedge clk)
    begin
        s_rvalid <= {N{1'b0}};

        if (rst)
        begin
            fstate      <= F_IDLE;
            fill_busy   <= 1'b0;
            fh_pend     <= 1'b0;
            p1_v        <= 1'b0;
            m_arvalid   <= 1'b0;
            valid       <= {LINES{1'b0}};
            stat_hits   <= 32'd0;
            stat_misses <= 32'd0;
        end
        else
        begin
            if (flush)                       // parallel with the FSM (deadlock fix)
                valid <= {LINES{1'b0}};

            // register the accepted request; reserve the slot on a miss
            p1_v <= accept;
            if (accept)
            begin
                p1_port <= pick;
                p1_hit  <= pick_hit;
                p1_idx  <= pidx[pick];
                p1_off  <= poff[pick];
                p1_tag  <= ptag[pick];
                p1_addr <= s_araddr[pick*32 +: 32];
                if (!pick_hit)
                    fill_busy <= 1'b1;
            end

            // response bus: a pipelined hit wins; else drain the fill hot word
            if (p1_v && p1_hit)
            begin
                s_rvalid[p1_port] <= 1'b1;
                s_rdata           <= data[{p1_idx, p1_off}];
                stat_hits         <= stat_hits + 32'd1;
            end
            else if (fh_pend)
            begin
                s_rvalid[fh_port] <= 1'b1;
                s_rdata           <= fh_data;
                fh_pend           <= 1'b0;
            end

            // a miss reached stage 1 -> launch the burst fill.
            // Invalidate the line NOW: hit-under-miss means other ports could
            // otherwise hit this direct-mapped index while the fill overwrites
            // it beat-by-beat (a different tag) and read corrupted data. With
            // valid[idx]=0 any access to it misses and stalls until the fill
            // completes (the blocking cache does this).
            if (p1_v && !p1_hit)
            begin
                valid[p1_idx] <= 1'b0;
                m_araddr    <= {p1_addr[31:OFFW], {OFFW{1'b0}}};
                m_arvalid   <= 1'b1;
                fill_idx    <= p1_idx;
                fill_tag    <= p1_tag;
                fill_off    <= {OFFW{1'b0}};
                want_off    <= p1_off;
                fill_port   <= p1_port;
                stat_misses <= stat_misses + 32'd1;
                fstate      <= F_MISS;
            end

            // fill FSM
            case (fstate)
                F_MISS:
                    if (m_arvalid && m_arready)
                    begin
                        m_arvalid <= 1'b0;
                        fstate    <= F_FILL;
                    end
                F_FILL:
                    if (m_rvalid)
                    begin
                        data[{fill_idx, fill_off}] <= m_rdata;
                        if (fill_off == want_off)      // hot word -> buffer it
                        begin
                            fh_pend <= 1'b1;
                            fh_port <= fill_port;
                            fh_data <= m_rdata;
                        end
                        if (fill_off == {OFFW{1'b1}})  // last beat -> line valid
                        begin
                            tag[fill_idx]   <= fill_tag;
                            valid[fill_idx] <= 1'b1;
                            fill_busy       <= 1'b0;
                            fstate          <= F_IDLE;
                        end
                        fill_off <= fill_off + {{OFFW-1{1'b0}}, 1'b1};
                    end
                default: ;
            endcase
        end
    end

endmodule