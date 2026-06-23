// ============================================================================
// I2S_TX — standaard I2S (Philips) transmitter, master
//
// Werkt voor een externe I2S-DAC (bijv. PCM5102) én voor een Teensy 4.1 als
// I2S-slave receiver. Mono: hetzelfde sample naar links en rechts.
//
//   BCLK = sys_clk / DIV          (DIV=18 @27MHz → 1.5 MHz)
//   frame = 32 BCLK               → 1.5MHz/32 = 46.875 kHz sample-rate
//   16-bit, MSB-first, I2S 1-BCLK delay; WS laag = links, hoog = rechts
//
// Standaard-I2S timing: WS wisselt bij het begin van elk kanaal; de MSB volgt
// één BCLK later (data is geregistreerd → automatische 1-cycle delay). De DAC/
// receiver sampelt SD op de stijgende BCLK-flank; SD/WS worden hier ververst aan
// het begin van de BCLK-periode (BCLK laag) → stabiel vóór de stijgende flank.
//
// PCM5102: geen externe MCLK nodig (interne PLL; SCK-pin volgens module-config,
// meestal naar GND). Sluit BCK/LRCK/DIN aan op bclk/lrck/sdata.
// ============================================================================

`timescale 1ns / 1ps

module i2s_tx #(
    parameter integer DIV = 18          // sys_clk / DIV = BCLK (27MHz/18 = 1.5MHz)
) (
    input  wire        clk,             // sys_clk (27 MHz)
    input  wire        rst,             // active-high
    input  wire signed [15:0] sample_in,// mono 16-bit signed audio

    output reg         bclk,            // bit-clock
    output reg         lrck,            // word-select (0=links, 1=rechts)
    output reg         sdata            // serial data (MSB-first, I2S)
);

    // ---- BCLK-generatie: deel sys_clk door DIV (50% duty) ----
    reg [4:0] divc;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            divc <= 5'd0;
            bclk <= 1'b0;
        end else begin
            divc <= (divc == DIV-1) ? 5'd0 : divc + 5'd1;
            bclk <= (divc < (DIV/2)) ? 1'b0 : 1'b1;   // laag 1e helft, hoog 2e helft
        end
    end

    wire bit_adv = (divc == 5'd0);      // begin BCLK-periode (BCLK laag)

    // ---- Serializer: 32 BCLK/frame, 16 per kanaal, I2S 1-BCLK delay ----
    reg [4:0]  cnt;                     // 0..31 (BCLK binnen frame)
    reg [15:0] sh;                      // shift-register, MSB op [15]

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cnt   <= 5'd0;
            sh    <= 16'd0;
            lrck  <= 1'b0;
            sdata <= 1'b0;
        end else if (bit_adv) begin
            // sdata geregistreerd → MSB verschijnt 1 BCLK ná de WS-wissel (I2S)
            sdata <= sh[15];
            lrck  <= (cnt >= 5'd16);                  // 0..15 links, 16..31 rechts
            if (cnt == 5'd0 || cnt == 5'd16)
                sh <= sample_in;                      // laad sample bij kanaalstart (mono: L=R)
            else
                sh <= {sh[14:0], 1'b0};               // shift MSB-first
            cnt <= (cnt == 5'd31) ? 5'd0 : cnt + 5'd1;
        end
    end

endmodule
