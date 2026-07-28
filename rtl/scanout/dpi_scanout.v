// SS Handheld - DPI/RGB panel scanout timing generator v0.1
//
// Drives a controller-less 480x272 RGB TFT: PCLK (clock-enable divided from
// the GPU clock: 66 MHz / 7 = 9.43 MHz -> ~62.7 Hz frame rate with the
// 525 x 286 totals below), HSYNC/VSYNC (active low), DE, RGB888 (expanded
// from RGB565). Reads the display line from a line buffer supplied by the
// SoC top (double-banked against the PPU renderer), pulses line_req to pace
// rendering and vsync_irq for the CPU frame loop (D24).

module dpi_scanout #(
    parameter H_ACTIVE = 480,
    parameter H_FP     = 2,
    parameter H_SW     = 41,
    parameter H_BP     = 2,    // H total 525
    parameter V_ACTIVE = 272,
    parameter V_FP     = 2,
    parameter V_SW     = 10,
    parameter V_BP     = 2,    // V total 286
    parameter CE_DIV   = 7
) (
    input  wire        clk,
    input  wire        rst,

    // display line buffer read port (RGB565; SoC double-banks it)
    output wire [8:0]  lb_raddr,
    input  wire [15:0] lb_rdata,

    // pacing
    output reg         line_req,     // pulse at start of each line's blanking
    output reg  [8:0]  line_req_y,   // which line to render next
    output reg         vsync_irq,    // pulse at start of vertical blanking
    output wire [8:0]  active_y,     // current display line (bank select)

    // panel
    output reg         pclk,
    output reg         hsync,
    output reg         vsync,
    output reg         de,
    output reg  [23:0] rgb
);

    localparam H_TOTAL = H_ACTIVE + H_FP + H_SW + H_BP;
    localparam V_TOTAL = V_ACTIVE + V_FP + V_SW + V_BP;

    reg [4:0] cediv;
    wire      ce = (cediv == CE_DIV[4:0] - 5'd1);

    reg [9:0] hc;   // 0 .. H_TOTAL-1
    reg [8:0] vc;   // 0 .. V_TOTAL-1

    assign active_y = vc;

    wire h_active = (hc < H_ACTIVE[9:0]);
    wire v_active = (vc < V_ACTIVE[8:0]);

    // fetch one pixel ahead of DE
    assign lb_raddr = h_active ? hc[8:0] : 9'd0;

    always @(posedge clk)
    begin
        line_req  <= 1'b0;
        vsync_irq <= 1'b0;

        if (rst)
        begin
            cediv <= 5'd0;
            hc    <= 10'd0;
            vc    <= 9'd0;
            pclk  <= 1'b0;
            hsync <= 1'b1;
            vsync <= 1'b1;
            de    <= 1'b0;
        end
        else
        begin
            // pixel clock: high for the second half of each CE_DIV window
            cediv <= ce ? 5'd0 : cediv + 5'd1;
            pclk  <= (cediv >= (CE_DIV[4:0] / 2));

            if (ce)
            begin
                // counters
                if (hc == H_TOTAL[9:0] - 10'd1)
                begin
                    hc <= 10'd0;
                    if (vc == V_TOTAL[8:0] - 9'd1)
                        vc <= 9'd0;
                    else
                        vc <= vc + 9'd1;
                end
                else
                begin
                    hc <= hc + 10'd1;
                end

                // syncs (active low), registered off the counters
                hsync <= !((hc >= H_ACTIVE[9:0] + H_FP[9:0])
                        && (hc <  H_ACTIVE[9:0] + H_FP[9:0] + H_SW[9:0]));
                vsync <= !((vc >= V_ACTIVE[8:0] + V_FP[8:0])
                        && (vc <  V_ACTIVE[8:0] + V_FP[8:0] + V_SW[8:0]));

                de  <= h_active && v_active;
                rgb <= { lb_rdata[15:11], lb_rdata[15:13],   // R5 -> R8
                         lb_rdata[10:5],  lb_rdata[10:9],    // G6 -> G8
                         lb_rdata[4:0],   lb_rdata[4:2] };   // B5 -> B8

                // pacing pulses at the START of each displayed line: request
                // line vc+1 while vc scans out -> the renderer gets a full
                // line period and writes the opposite bank. (Firing at blank
                // start only left ~blank-time margin: combing artifact.)
                if (hc == 10'd0)
                begin
                    if (vc < V_ACTIVE[8:0] - 9'd1)
                    begin
                        line_req   <= 1'b1;      // render next line
                        line_req_y <= vc[8:0] + 9'd1;
                    end
                    else if (vc == V_TOTAL[8:0] - 9'd1)
                    begin
                        line_req   <= 1'b1;      // pre-render line 0
                        line_req_y <= 9'd0;
                    end
                end
                if ((hc == H_ACTIVE[9:0]) && (vc == V_ACTIVE[8:0] - 9'd1))
                begin
                    vsync_irq <= 1'b1;           // entering vertical blanking
                end
            end
        end
    end

endmodule