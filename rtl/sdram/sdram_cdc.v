// SS Handheld - SDRAM controller with clock-domain crossing
//
// Puts sdram_ctrl in its own clk_sdram (133 MHz) domain and presents the SAME
// host interface as sdram_ctrl on clk_gpu (66.67 MHz), so gpu_top's SDRAM mux
// / owner-lock logic is unchanged, swap the instance and add clk_sdram.
//
// This is REQUIRED: sdram_ctrl's timing params are
// 133 MHz-tuned (tRCD/tRP=3≈20 ns, REFRESH_DIV=1039≈7.8 µs). Clocked at 66 MHz
// the refresh interval stretches to ~15.7 µs and violates SDRAM retention.
//
// Crossing (two Gisselquist async FIFOs, Gray-pointer, 2-FF sync):
//   cmd FIFO  (clk_gpu -> clk_sdram): {we,burst,addr,wdata,wbe} = 60 bits
//   resp FIFO (clk_sdram -> clk_gpu): {is_wdone, rdata} = 33 bits - a unified
//     response stream (a read beat, or a write-completion marker)
// Single-outstanding (the mux holds one transaction via busy_lock), so the
// resp FIFO fully drains between transactions; depth 16 covers a burst-8.

module sdram_cdc #(
    parameter INIT_WAIT = 26600
) (
    input  wire        clk_gpu,
    input  wire        clk_sdram,
    input  wire        rst,          // async assert; synced into each domain

    // host interface (clk_gpu) - identical to sdram_ctrl
    input  wire        req,
    input  wire        we,
    input  wire        burst,
    input  wire [21:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  wbe,
    output wire        ready,
    output wire [31:0] rdata,
    output wire        rvalid,
    output wire        wdone,
    output wire        init_done,

    // SDRAM PHY (clk_sdram)
    output wire        s_cke,
    output wire        s_cs_n,
    output wire        s_ras_n,
    output wire        s_cas_n,
    output wire        s_we_n,
    output wire [1:0]  s_ba,
    output wire [11:0] s_a,
    output wire [3:0]  s_dqm,
    input  wire [31:0] s_dq_i,
    output wire [31:0] s_dq_o,
    output wire        s_dq_oe
);

    // reset synchronizers (active-low per domain) 
    reg [1:0] rstg_sync, rsts_sync;
    always @(posedge clk_gpu or posedge rst)
        if (rst) rstg_sync <= 2'b00; else rstg_sync <= {rstg_sync[0], 1'b1};
    always @(posedge clk_sdram or posedge rst)
        if (rst) rsts_sync <= 2'b00; else rsts_sync <= {rsts_sync[0], 1'b1};
    wire rstn_gpu   = rstg_sync[1];
    wire rstn_sdram = rsts_sync[1];
    wire rst_sdram  = !rstn_sdram;

    // command FIFO: clk_gpu -> clk_sdram
    wire        cmd_wfull;
    wire        cmd_rempty;
    wire [59:0] cmd_rdata_w;
    wire        cmd_pop;

    assign ready = !cmd_wfull;   // host may issue when the cmd FIFO has room

    afifo #(.LGFIFO(2), .WIDTH(60)) u_cmd (
        .i_wclk(clk_gpu),   .i_wr_reset_n(rstn_gpu),
        .i_wr(req && !cmd_wfull), .i_wr_data({we, burst, addr, wdata, wbe}),
        .o_wr_full(cmd_wfull),
        .i_rclk(clk_sdram), .i_rd_reset_n(rstn_sdram),
        .i_rd(cmd_pop), .o_rd_data(cmd_rdata_w), .o_rd_empty(cmd_rempty)
    );

    wire        c_we    = cmd_rdata_w[59];
    wire        c_burst = cmd_rdata_w[58];
    wire [21:0] c_addr  = cmd_rdata_w[57:36];
    wire [31:0] c_wdata = cmd_rdata_w[35:4];
    wire [3:0]  c_wbe   = cmd_rdata_w[3:0];

    // sdram_ctrl in the clk_sdram domain 
    wire        ctrl_ready, ctrl_rvalid, ctrl_wdone, ctrl_init;
    wire [31:0] ctrl_rdata;

    // present a command while one is queued; the controller consumes it when
    // ready, and we pop the FIFO that same cycle
    wire ctrl_req = !cmd_rempty;
    assign cmd_pop = ctrl_req && ctrl_ready;

    sdram_ctrl #(
        .INIT_WAIT(INIT_WAIT)
    ) ctrl (
        .clk(clk_sdram), .rst(rst_sdram),
        .req(ctrl_req), .we(c_we), .burst(c_burst), .addr(c_addr),
        .wdata(c_wdata), .wbe(c_wbe),
        .ready(ctrl_ready), .rdata(ctrl_rdata), .rvalid(ctrl_rvalid),
        .wdone(ctrl_wdone), .init_done(ctrl_init),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n),
        .s_cas_n(s_cas_n), .s_we_n(s_we_n),
        .s_ba(s_ba), .s_a(s_a), .s_dqm(s_dqm),
        .s_dq_i(s_dq_i), .s_dq_o(s_dq_o), .s_dq_oe(s_dq_oe)
    );

    // response FIFO: clk_sdram -> clk_gpu 
    wire        rsp_wfull;
    wire        rsp_rempty;
    wire [32:0] rsp_rdata_w;

    afifo #(.LGFIFO(4), .WIDTH(33)) u_rsp (
        .i_wclk(clk_sdram), .i_wr_reset_n(rstn_sdram),
        .i_wr((ctrl_rvalid || ctrl_wdone) && !rsp_wfull),
        .i_wr_data({ctrl_wdone, ctrl_rdata}),
        .o_wr_full(rsp_wfull),
        .i_rclk(clk_gpu),   .i_rd_reset_n(rstn_gpu),
        .i_rd(!rsp_rempty), .o_rd_data(rsp_rdata_w), .o_rd_empty(rsp_rempty)
    );

    // one response consumed per gpu cycle it is available
    assign rvalid = !rsp_rempty && !rsp_rdata_w[32];
    assign wdone  = !rsp_rempty &&  rsp_rdata_w[32];
    assign rdata  = rsp_rdata_w[31:0];

    // init_done level, synced to clk_gpu
    reg [1:0] init_sync;
    always @(posedge clk_gpu)
        init_sync <= {init_sync[0], ctrl_init};
    assign init_done = init_sync[1];

endmodule