// ============================================================================
// SYNTH_TOP_ARTY — bord-wrapper voor de Digilent Arty S7-50 (XC7S50-CSGA324)
//
// Dunne schil om het vendor-neutrale synth_top:
//   * MMCM: 100 MHz (R2) → exact 27 MHz (×13,5 / ÷2 / ÷25, VCO 675 MHz)
//     → Fase A draait 1:1 op dezelfde klok als de Tang Primer 20K.
//   * Reset: BTN0 (active-high op Arty) + MMCM-lock → sys_rst_n.
//   * Audio: PCM5102A-breakout (GY-PCM5102) op Pmod JA via i2s_tx (DAC_I2S=1).
//     SCK van de module krijgt een constante 0 van de FPGA → interne PLL.
//   * SPI-slave (Cortex/Teensy): Pmod JB.
//   * SW0=demo_mode, SW1=mute, SW2=wah aan/uit, BTN1=wah-niveau.
//
// Fase B: MMCM naar 96 MHz (×12 / ÷1 / ÷12,5) → 2000 cycli/sample, exact
// 48 kHz; SYS_CLK_HZ hieronder mee wijzigen. Zie doc/ARTY_S7_PLAN.md.
// ============================================================================

`timescale 1ns / 1ps

module synth_top_arty (
    input  wire       clk100,      // 100 MHz onboard oscillator (R2, SSTL135!)

    input  wire [2:0] sw,          // SW0 demo, SW1 mute, SW2 wah (SW3 niet: DDR-bank)
    input  wire [1:0] btn,         // BTN0 reset, BTN1 wah-niveau (active-high)
    output wire [1:0] led,         // LED0 synth-status, LED1 MMCM-lock

    // Pmod JA — PCM5102A DAC-breakout (I2S)
    output wire       ja_bck,      // JA pin 1 → BCK
    output wire       ja_lrck,     // JA pin 2 → LCK/LRCK
    output wire       ja_din,      // JA pin 3 → DIN
    output wire       ja_sck,      // JA pin 4 → SCK (constant 0 = interne PLL)

    // Pmod JB — SPI-slave van de brain (Teensy 4.1 = master)
    input  wire       jb_sclk,     // JB pin 1
    input  wire       jb_mosi,     // JB pin 2
    output wire       jb_miso,     // JB pin 3
    input  wire       jb_cs_n      // JB pin 4
);

    // ========================================================================
    // MMCM: 100 MHz → 27 MHz exact
    // ========================================================================
    wire clk_fb, clk27_unbuf, clk27, mmcm_locked;

    MMCME2_BASE #(
        .CLKIN1_PERIOD   (10.000),   // 100 MHz
        .DIVCLK_DIVIDE   (2),
        .CLKFBOUT_MULT_F (13.500),   // VCO = 100/2*13,5 = 675 MHz (600..1200 ok)
        .CLKOUT0_DIVIDE_F(25.000)    // 675/25 = 27,000 MHz
    ) u_mmcm (
        .CLKIN1   (clk100),
        .CLKFBIN  (clk_fb),
        .CLKFBOUT (clk_fb),
        .CLKOUT0  (clk27_unbuf),
        .LOCKED   (mmcm_locked),
        .RST      (1'b0),
        .PWRDWN   (1'b0),
        .CLKOUT0B (), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3  (), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBOUTB()
    );

    BUFG u_bufg27 (.I(clk27_unbuf), .O(clk27));

    // Reset: knop ingedrukt óf MMCM nog niet stabiel → reset actief.
    wire sys_rst_n = mmcm_locked & ~btn[0];

    // ========================================================================
    // De eigenlijke synth — identiek aan de Tang-versie (27 MHz, 48 kHz)
    // ========================================================================
    synth_top #(
        .SYS_CLK_HZ (27_000_000),
        .SAMPLE_HZ  (48_000),
        .DEMO_ONLY  (0),             // SW0 kiest: 1=demo-arpeggiator, 0=SPI-CV's
        .DAC_I2S    (1),             // PCM5102A wil standaard I2S, geen PT8211-LSBJ
        .FX_ECHO    (1),             // band-echo 0,33s (ruimte zat op de S7-50)
        .FX_REVERB  (1)              // FDN-galm RT ~1,8s
    ) u_synth (
        .sys_clk    (clk27),
        .sys_rst_n  (sys_rst_n),

        .spi_sclk   (jb_sclk),
        .spi_mosi   (jb_mosi),
        .spi_miso   (jb_miso),
        .spi_cs_n   (jb_cs_n),

        .demo_mode  (sw[0]),
        .key_mute_n (~sw[1]),        // SW1 omhoog = mute (synth wil active-low)
        .wah_sw     (sw[2]),
        .wah_btn_n  (~btn[1]),       // Arty-knop is active-high

        .led        (led[0]),

        .hp_bck     (ja_bck),
        .hp_ws      (ja_lrck),
        .hp_din     (ja_din),
        .pa_en      ()               // PCM5102 heeft geen versterker-enable
    );

    assign ja_sck  = 1'b0;           // SCK laag → PCM5102 klokt intern op BCK
    assign led[1]  = mmcm_locked;

endmodule
