// ============================================================================
// PT8211_TX — driver voor de onboard PT8211 stereo-DAC (Tang Primer 20K Dock)
//
// Serialiseert een 16-bit mono sample naar de PT8211 (links = rechts). Volledig
// in het sys_clk-domein (geen PLL): de bit-clock wordt uit sys_clk gedeeld.
//
//   BCK  = sys_clk / DIV         (DIV=18 @27MHz → 1.5 MHz)
//   frame = 32 BCK               → 1.5MHz/32 = 46.875 kHz sample-rate
//   16-bit MSB-first, WS laag = links / hoog = rechts
//
// De bit/WS-timing volgt het officiële Sipeed-voorbeeld (pt8211_drive.v): req op
// b_cnt 0/16, data 2 BCK later, WS-omslag op b_cnt 3/19 — dat is de PT8211/LSBJ-
// uitlijning die de echte DAC verwacht. Hier ge-clock-enabled op sys_clk i.p.v.
// op een aparte 1.536 MHz PLL-klok.
//
// `sample_in` wordt één keer per frame gelatcht (zelfde waarde naar L en R), zodat
// er geen tear in een frame zit. De synth draait op z'n eigen ~48 kHz; deze DAC
// doet effectief een zero-order-hold resample (zie doc — verwaarloosbaar artefact).
// ============================================================================

`timescale 1ns / 1ps

module pt8211_tx #(
    parameter integer DIV = 18          // sys_clk / DIV = BCK (27MHz/18 = 1.5MHz)
) (
    input  wire        clk,             // sys_clk (27 MHz)
    input  wire        rst,             // active-high
    input  wire signed [15:0] sample_in,// mono 16-bit signed audio
    input  wire        en,              // 1 = versterker aan, 0 = uit (mute = echt stil)

    output reg         hp_bck,          // bit-clock naar PT8211
    output wire        hp_ws,           // word-select (L/R)
    output wire        hp_din,          // serial data
    output wire        pa_en            // versterker-enable
);

    assign pa_en = en;

    // ---- BCK-generatie: deel sys_clk door DIV (50% duty) ----
    reg [4:0] divc;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            divc   <= 5'd0;
            hp_bck <= 1'b0;
        end else begin
            divc   <= (divc == DIV-1) ? 5'd0 : divc + 5'd1;
            hp_bck <= (divc < (DIV/2)) ? 1'b0 : 1'b1;   // laag 1e helft, hoog 2e helft
        end
    end

    // één bit-stap per BCK-periode, aan het begin (BCK laag → data settelt vóór
    // de stijgende flank waarop de DAC sampelt)
    wire bit_adv = (divc == 5'd0);

    // ---- Serializer (volgt Sipeed pt8211_drive, clock-enabled op bit_adv) ----
    reg [4:0]  b_cnt;
    reg        req_r, req_r1;
    reg [15:0] idata_r, frame_smp;
    reg        ws_r, din_r;

    assign hp_ws  = ws_r;
    assign hp_din = din_r;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            b_cnt     <= 5'd0;
            req_r     <= 1'b0;
            req_r1    <= 1'b0;
            idata_r   <= 16'd0;
            frame_smp <= 16'd0;
            ws_r      <= 1'b0;
            din_r     <= 1'b0;
        end else if (bit_adv) begin
            b_cnt <= b_cnt + 5'd1;

            if (b_cnt == 5'd0)
                frame_smp <= sample_in;            // latch mono-sample 1×/frame

            req_r   <= (b_cnt == 5'd0) || (b_cnt == 5'd16);
            req_r1  <= req_r;
            idata_r <= req_r1 ? frame_smp : (idata_r << 1);  // load op req, anders shift
            din_r   <= idata_r[15];                 // MSB-first

            ws_r    <= (b_cnt == 5'd3)  ? 1'b0 :
                       (b_cnt == 5'd19) ? 1'b1 : ws_r;
        end
    end

endmodule
