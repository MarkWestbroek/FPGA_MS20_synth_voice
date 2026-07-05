// ============================================================================
// WAVETABLE_TB — verifieert de wavetable-exciter (stap 2 POLY_PLAN)
//
// Demo-mode: even stemmen = KS, oneven = wavetable (1,5 saw / 3,7 square)
// met gate ~2 s per aanslag. Checks:
//   - KS-stemmen (0,2) én WT-stemmen (1,3) klinken in het venster 2,0–2,9 s
//   - de amp-envelope sluit: stem 1 (gate uit op 2,5 s) is stil op 3,0 s
//   - de mix blijft binnen bereik
// ============================================================================

`timescale 1ns / 1ps

module wavetable_tb();

    reg sys_clk = 0; always #10 sys_clk = ~sys_clk;   // 50 MHz
    reg sys_rst_n = 0;
    wire led;

    synth_top #(.SYS_CLK_HZ(50_000_000), .DEMO_ONLY(1)) uut (
        .sys_clk(sys_clk), .sys_rst_n(sys_rst_n),
        .spi_sclk(1'b0), .spi_mosi(1'b0), .spi_miso(), .spi_cs_n(1'b1),
        .demo_mode(1'b1),
        .key_mute_n(1'b1),
        .wah_sw(1'b1),
        .wah_btn_n(1'b1),
        .led(led),
        .hp_bck(), .hp_ws(), .hp_din(), .pa_en()
    );

    integer pass = 0, fail = 0;
    task check(input cond, input [255:0] name);
        begin
            if (cond) begin pass=pass+1; $display("  PASS: %0s", name); end
            else      begin fail=fail+1; $display("  FAIL: %0s", name); end
        end
    endtask

    function [31:0] absv(input signed [31:0] x);
        absv = (x < 0) ? -x : x;
    endfunction

    // piek per stem in het meetvenster [2.0s, 2.9s] + mix-piek over alles
    reg [31:0] wpeak [0:3];
    reg [31:0] mix_peak = 0;
    reg        win = 0;
    integer i;
    initial for (i = 0; i < 4; i = i + 1) wpeak[i] = 0;

    always @(posedge sys_clk) begin
        if (sys_rst_n && uut.sample_clk_tick) begin
            if (win)
                for (i = 0; i < 4; i = i + 1)
                    if (absv(uut.u_engine.lastout[i]) > wpeak[i])
                        wpeak[i] <= absv(uut.u_engine.lastout[i]);
            if (absv(uut.filter_out) > mix_peak)
                mix_peak <= absv(uut.filter_out);
        end
    end

    initial begin
        sys_rst_n = 0; #200; sys_rst_n = 1;

        #2_000_000_000;  win = 1;    // meetvenster aan @2.0s
        #900_000_000;    win = 0;    // uit @2.9s

        for (i = 0; i < 4; i = i + 1)
            $display("  stem %0d (%0s): venster-piek=%0d", i,
                     (i[0]) ? "WT" : "KS", wpeak[i]);

        check(wpeak[0] > 32'h1000, "stem 0 (KS) klinkt");
        check(wpeak[1] > 32'h1000, "stem 1 (WT saw) klinkt");
        check(wpeak[2] > 32'h1000, "stem 2 (KS) klinkt");
        check(wpeak[3] > 32'h1000, "stem 3 (WT square) klinkt");

        // stem 1: gate ging uit op 2,5 s → amp-release (~85 ms) → stil op 3,0 s
        #100_000_000;                 // t = 3.0s
        $display("  stem 1 @3.0s: amp=%0d |out|=%0d",
                 uut.u_engine.amp[1], absv(uut.u_engine.lastout[1]));
        check(uut.u_engine.amp[1] == 17'd0,                  "stem 1: amp-release klaar (amp=0)");
        check(absv(uut.u_engine.lastout[1]) < 32'h800,       "stem 1: vrijwel stil na release");

        check(mix_peak > 32'h10000,    "mix heeft serieus signaal");
        check(mix_peak < 32'h01000000, "mix blijft onder ±16.0 (geen wrap)");

        $display("\n==== WAVETABLE TEST: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("ALLE TESTS GESLAAGD");
        $finish;
    end

endmodule
