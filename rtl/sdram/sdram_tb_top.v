// TB top: controller + model wired together (verilator-friendly split dq).

module sdram_tb_top (
    input  wire        clk,
    input  wire        rst,

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
    output wire        init_done
);

    wire        s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]  s_ba;
    wire [11:0] s_a;
    wire [3:0]  s_dqm;
    wire [31:0] dq_c2m;   // controller -> model
    wire [31:0] dq_m2c;   // model -> controller
    wire        dq_oe;

    sdram_ctrl #(
        .INIT_WAIT(64) // shortened for sim
    ) ctrl (
        .clk(clk), .rst(rst),
        .req(req), .we(we), .burst(burst), .addr(addr), .wdata(wdata), .wbe(wbe),
        .ready(ready), .rdata(rdata), .rvalid(rvalid), .wdone(wdone),
        .init_done(init_done),
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