// ============================================================================
// SYNTH_TOP_FX_TB — smoke-test + render van de FX-build (echo + reverb aan)
//
// Draait de demo-arpeggiator 4 s door de effectsectie en logt dac_sample
// (wat je op de jack zou horen). Checks:
//   1. serieus signaal aanwezig (RMS-proxy)
//   2. FX-pad leeft: fx_out ≠ filter_out op enig moment na 1 s
//      (echo/galm-staarten wijken af van droog)
//   3. default-build-regressie zit in de bestaande tb's (FX=0 → g_no_fx)
//
// Output: "dry16, wet16" per tick → wav via scripts/cols2wav.py.
// ============================================================================

`timescale 1ns / 1ps

module synth_top_fx_tb;

    reg clk = 0;  always #18.5 clk = ~clk;    // 27 MHz
    reg rst_n = 0;

    wire bck, ws, din, pa;

    synth_top #(.SYS_CLK_HZ(27_000_000), .SAMPLE_HZ(48_000),
                .DEMO_ONLY(1), .DAC_I2S(1),
                .FX_ECHO(1), .FX_REVERB(1)) dut (
        .sys_clk(clk), .sys_rst_n(rst_n),
        .spi_sclk(1'b0), .spi_mosi(1'b0), .spi_miso(), .spi_cs_n(1'b1),
        .demo_mode(1'b1), .key_mute_n(1'b1), .wah_sw(1'b0), .wah_btn_n(1'b1),
        .led(), .hp_bck(bck), .hp_ws(ws), .hp_din(din), .pa_en(pa)
    );

    // droge referentie naast de FX-mix (zelfde schaling als dac_scaled)
    wire signed [31:0] dry_scaled = dut.filter_out >>> 3;
    wire signed [15:0] dry16 =
        (dry_scaled >  32'sd32767) ?  16'sd32767 :
        (dry_scaled < -32'sd32768) ? -16'sd32768 : dry_scaled[15:0];

    integer tick = 0;
    integer aw, adiff;
    integer energy = 0;
    integer diff_seen = 0;

    always @(posedge clk) if (dut.sample_clk_tick && rst_n) begin
        $display("%0d, %0d", dry16, dut.dac_sample);

        aw = (dut.dac_sample < 0) ? -dut.dac_sample : dut.dac_sample;
        energy = energy + (aw >>> 4);
        adiff = dut.dac_sample - dry16;
        if (adiff < 0) adiff = -adiff;
        if (tick > 48000 && adiff > 500) diff_seen = diff_seen + 1;

        tick <= tick + 1;
        if (tick == 192000) begin
            $display("== SYNTH+FX CHECKS ==");
            if (energy > 32'sd1000000)
                $display("PASS: audio aanwezig (E=%0d)", energy);
            else $display("FAIL: (bijna) stil (E=%0d)", energy);
            if (diff_seen > 4800)
                $display("PASS: FX-pad wijkt af van droog (%0d ticks)", diff_seen);
            else $display("FAIL: FX-pad lijkt dood (%0d ticks)", diff_seen);
            $finish;
        end
    end

    initial begin
        #200 rst_n = 1;
    end

endmodule
