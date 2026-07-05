// ============================================================================
// WAH_TOGGLE_TB — regressietest wah-niveaus (T2), DIP (E9) en reset — polyfoon
//
// De demo is nu een arpeggiator: elke 0,5 s triggert de volgende stem. De
// wah-envelope loopt per stem in voice_engine (fg[v]); dit bench volgt elke
// trigger en checkt 3 ticks later het envelope-startpunt van díe stem.
//
// Scenario (boot = niveau 2, medium):
//   trig 1..2  (lvl 2)  → open op L2-startpunt
//   DIP uit    → trig 3 → statisch G_FIXED
//   DIP aan    → trig 4 → weer open L2
//   T2 ×1      → trig 5 → open L3 (dik)
//   T2 ×2      → trig 6 → statisch (niveau 0 = uit)
//   T2 ×3      → trig 7 → open L1 (licht)
//   T2 ×4      → trig 8 → open L2 (cyclus rond)
//   reset-puls → trig 9 → open L2 (default) + audio aanwezig
// ============================================================================

`timescale 1ns / 1ps

module wah_toggle_tb();

    reg sys_clk = 0; always #10 sys_clk = ~sys_clk;   // 50 MHz
    reg sys_rst_n = 0;
    reg wah_sw    = 1;
    reg wah_btn_n = 1;

    wire led;

    synth_top #(.SYS_CLK_HZ(50_000_000), .DEMO_ONLY(1)) uut (
        .sys_clk(sys_clk), .sys_rst_n(sys_rst_n),
        .spi_sclk(1'b0), .spi_mosi(1'b0), .spi_miso(), .spi_cs_n(1'b1),
        .demo_mode(1'b1),
        .key_mute_n(1'b1),
        .wah_sw(wah_sw),
        .wah_btn_n(wah_btn_n),
        .led(led),
        .hp_bck(), .hp_ws(), .hp_din(), .pa_en()
    );

    localparam [31:0] G_OPEN_L1 = 32'h000191F6;
    localparam [31:0] G_OPEN_L2 = 32'h000322F5;
    localparam [31:0] G_OPEN_L3 = 32'h00042D45;
    localparam [31:0] G_FIXED   = 32'h0000D671;

    integer pass = 0, fail = 0;
    task check(input cond, input [255:0] name);
        begin
            if (cond) begin pass=pass+1; $display("  PASS: %0s", name); end
            else      begin fail=fail+1; $display("  FAIL: %0s", name); end
        end
    endtask

    function g_near(input [31:0] g, input [31:0] open_g);
        g_near = (g <= open_g) && (g >= open_g - 32'h1000);
    endfunction

    function [2:0] enc8(input [7:0] b);
        casez (b)
            8'bzzzzzzz1: enc8 = 3'd0;
            8'bzzzzzz10: enc8 = 3'd1;
            8'bzzzzz100: enc8 = 3'd2;
            8'bzzzz1000: enc8 = 3'd3;
            8'bzzz10000: enc8 = 3'd4;
            8'bzz100000: enc8 = 3'd5;
            8'bz1000000: enc8 = 3'd6;
            default:     enc8 = 3'd7;
        endcase
    endfunction

    // ---- trigger-monitor: 3 ticks na een trigger fg[stem] van de engine lezen
    reg [1:0]  tp = 2'b00;
    reg [2:0]  tv = 3'd0;      // stem van de laatste trigger
    integer    trig_n = 0;
    reg [31:0] g_smp;

    always @(posedge sys_clk) begin
        if (uut.sample_clk_tick) begin
            tp <= {tp[0], |uut.trig_demo};
            if (|uut.trig_demo) tv <= enc8(uut.trig_demo);
            if (tp[1]) begin
                trig_n = trig_n + 1;
                g_smp  = uut.u_engine.fg[tv];
                $display("TRIG %0d @%0d ms  stem=%0d lvl=%0d  g=%h",
                         trig_n, $time/1000000, tv, uut.eff_level, g_smp);
                case (trig_n)
                    1:  check(g_near(g_smp, G_OPEN_L2), "trig 1 (boot, medium): open L2");
                    2:  check(g_near(g_smp, G_OPEN_L2), "trig 2 (medium): open L2");
                    3:  check(g_near(g_smp, G_OPEN_L2), "trig 3 (nog medium): open L2");
                    4:  check(g_smp == G_FIXED,         "trig 4 (DIP uit): G_FIXED");
                    5:  check(g_near(g_smp, G_OPEN_L2), "trig 5 (DIP aan): open L2");
                    6:  check(g_near(g_smp, G_OPEN_L3), "trig 6 (T2 x1, DIK): open L3");
                    7:  check(g_smp == G_FIXED,         "trig 7 (T2 x2, UIT): G_FIXED");
                    8:  check(g_near(g_smp, G_OPEN_L1), "trig 8 (T2 x3, LICHT): open L1");
                    9:  check(g_near(g_smp, G_OPEN_L2), "trig 9 (T2 x4): cyclus rond");
                    10: check(g_near(g_smp, G_OPEN_L2), "trig 10 (na reset): open L2");
                    default: ;
                endcase
            end
        end
    end

    // ---- geluid na reset ----
    reg [31:0] str_peak_post = 0;
    reg        post_reset = 0;
    wire signed [31:0] s_abs = (uut.string_out < 0) ? -uut.string_out : uut.string_out;
    always @(posedge sys_clk)
        if (post_reset && sys_rst_n && uut.sample_clk_tick && s_abs > str_peak_post)
            str_peak_post <= s_abs;

    task press_t2;
        begin
            $display("--- T2 druk @ %0d ms", $time/1000000);
            wah_btn_n = 0; #100_000_000; wah_btn_n = 1;
        end
    endtask

    initial begin
        sys_rst_n = 0; #200; sys_rst_n = 1;

        // trig 1 @0 en trig 2 @0.5s op niveau 2
        #1_250_000_000;          // t=1.25s
        wah_sw = 0;  $display("--- DIP UIT @ %0d ms", $time/1000000);
        #500_000_000;            // trig 3 @1.5s (uit); t=1.75s
        wah_sw = 1;  $display("--- DIP AAN @ %0d ms", $time/1000000);
        #500_000_000;            // trig 4 @2.0s; t=2.25s
        press_t2;                // → niveau 3
        #400_000_000;            // trig 5 @2.5s; t=2.75s
        press_t2;                // → niveau 0
        #400_000_000;            // trig 6 @3.0s; t=3.25s
        press_t2;                // → niveau 1
        #400_000_000;            // trig 7 @3.5s; t=3.75s
        press_t2;                // → niveau 2
        #400_000_000;            // trig 8 @4.0s; t=4.25s

        $display("--- RESET-puls @ %0d ms", $time/1000000);
        sys_rst_n = 0; #10_000; sys_rst_n = 1;
        post_reset = 1;
        #550_000_000;            // trig 9 direct na reset; audio meten

        check(str_peak_post > 0, "audio (string-mix) aanwezig na reset");
        check(trig_n >= 10,      "10 triggers gezien");

        $display("\n==== WAH TOGGLE TEST: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("ALLE TESTS GESLAAGD");
        $finish;
    end

endmodule
