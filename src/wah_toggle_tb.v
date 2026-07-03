// ============================================================================
// WAH_TOGGLE_TB — regressietest voor de wah-niveaus (T2), DIP (E9) en reset
//
// Scenario (boot = niveau 2, medium):
//   1. boot                → noot 1 & 2 starten open op het MEDIUM-startpunt
//   2. DIP (E9) uit        → noot 3 statisch op G_FIXED (master-uit)
//   3. DIP weer aan        → noot 4 weer open (niveau 2 onthouden)
//   4. reset-puls (T3)     → demo herstart; noot 5 weer open (niveau 2 default)
//   5. T2 druk 1 → niveau 3 (dik)    → noot 6 start op het DIK-startpunt
//      T2 druk 2 → niveau 0 (uit)    → noot 7 statisch G_FIXED
//      T2 druk 3 → niveau 1 (licht)  → noot 8 start op het LICHT-startpunt
//      T2 druk 4 → niveau 2 (medium) → noot 9 weer medium (cyclus rond)
// Zelf-controlerend: PASS/FAIL per stap + eindoordeel.
// ============================================================================

`timescale 1ns / 1ps

module wah_toggle_tb();

    reg sys_clk = 0; always #10 sys_clk = ~sys_clk;   // 50 MHz
    reg sys_rst_n = 0;
    reg wah_sw    = 1;                                 // DIP: master aan
    reg wah_btn_n = 1;                                 // drukknop idle (pull-up)

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

    // Startpunten per niveau (zelfde waarden als synth_top)
    localparam [31:0] G_OPEN_L1 = 32'h000191F6;   // licht  ~1500 Hz
    localparam [31:0] G_OPEN_L2 = 32'h000322F5;   // medium ~3000 Hz
    localparam [31:0] G_OPEN_L3 = 32'h00042D45;   // dik    ~4000 Hz
    localparam [31:0] G_FIXED   = 32'h0000D671;   // uit    ~800 Hz

    integer pass = 0, fail = 0;
    task check(input cond, input [255:0] name);
        begin
            if (cond) begin pass=pass+1; $display("  PASS: %0s", name); end
            else      begin fail=fail+1; $display("  FAIL: %0s", name); end
        end
    endtask

    // g "start open op niveau X": binnen 1-2 sweep-stappen van het startpunt
    // (sample is 3 ticks na de trigger, dus 1 stap is er al af)
    function g_near(input [31:0] g, input [31:0] open_g);
        g_near = (g <= open_g) && (g >= open_g - 32'h1000);
    endfunction

    // ---- trigger-monitor: sample filter_g 3 ticks na elke trigger_pulse ----
    reg  [1:0]  tp = 2'b00;
    integer     trig_n = 0;
    reg  [31:0] g_smp;

    always @(posedge sys_clk) begin
        if (uut.sample_clk_tick) begin
            tp <= {tp[0], uut.trigger_pulse};
            if (tp[1]) begin
                trig_n = trig_n + 1;
                g_smp  = uut.filter_g;
                $display("TRIG %0d @%0d ms  lvl=%0d  g=%h", trig_n, $time/1000000,
                         uut.eff_level, g_smp);
                case (trig_n)
                    1: check(g_near(g_smp, G_OPEN_L2), "noot 1 (boot, medium): start open L2");
                    2: check(g_near(g_smp, G_OPEN_L2), "noot 2 (medium): start open L2");
                    3: check(g_smp == G_FIXED,         "noot 3 (DIP uit): statisch G_FIXED");
                    4: check(g_near(g_smp, G_OPEN_L2), "noot 4 (DIP weer aan): open L2");
                    5: check(g_near(g_smp, G_OPEN_L2), "noot 5 (na reset): open L2 (default)");
                    6: check(g_near(g_smp, G_OPEN_L3), "noot 6 (T2 x1, DIK): open L3");
                    7: check(g_smp == G_FIXED,         "noot 7 (T2 x2, UIT): statisch G_FIXED");
                    8: check(g_near(g_smp, G_OPEN_L1), "noot 8 (T2 x3, LICHT): open L1");
                    9: check(g_near(g_smp, G_OPEN_L2), "noot 9 (T2 x4, MEDIUM): cyclus rond");
                    default: ;
                endcase
            end
        end
    end

    // ---- geluid na reset: piek van de string na de reset-puls ----
    reg [31:0] str_peak_post = 0;
    reg        post_reset = 0;
    wire signed [31:0] s_abs = (uut.string_out < 0) ? -uut.string_out : uut.string_out;
    always @(posedge sys_clk)
        if (post_reset && sys_rst_n && uut.sample_clk_tick && s_abs > str_peak_post)
            str_peak_post <= s_abs;

    // drukknop T2: 100 ms ingedrukt (ruim boven de ~21 ms debounce @50 MHz)
    task press_t2;
        begin
            $display("--- T2 druk @ %0d ms", $time/1000000);
            wah_btn_n = 0; #100_000_000; wah_btn_n = 1;
        end
    endtask

    initial begin
        // boot
        sys_rst_n = 0; #200; sys_rst_n = 1;

        // noot 1 (0..1.5s) en noot 2 (1.5..3.0s) op niveau 2
        #2_000_000_000;          // t = 2.0 s (midden noot 2)
        wah_sw = 0;              // DIP uit
        $display("--- DIP UIT @ %0d ms", $time/1000000);

        #1_500_000_000;          // t = 3.5 s (noot 3 om 3.0 s gestart, master-uit)
        wah_sw = 1;              // DIP weer aan
        $display("--- DIP AAN @ %0d ms", $time/1000000);

        #1_600_000_000;          // t = 5.1 s (noot 4 om 4.5 s gestart)

        // reset-knop (T3)
        $display("--- RESET-puls @ %0d ms", $time/1000000);
        sys_rst_n = 0; #10_000; sys_rst_n = 1;
        post_reset = 1;

        #500_000_000;            // t = 5.6 s: noot 5 (om 5.1 s) gecheckt

        press_t2;                // niveau 2 → 3
        #1_400_000_000;          // t = 7.1 s (noot 6 om 6.6 s: dik)
        press_t2;                // niveau 3 → 0
        #1_400_000_000;          // t = 8.6 s (noot 7 om 8.1 s: uit)
        press_t2;                // niveau 0 → 1
        #1_400_000_000;          // t = 10.1 s (noot 8 om 9.6 s: licht)
        press_t2;                // niveau 1 → 2
        #1_500_000_000;          // t = 11.7 s (noot 9 om 11.1 s: medium)

        check(str_peak_post > 0, "audio (string) aanwezig na reset");
        check(trig_n >= 9,       "9 triggers gezien");

        $display("\n==== WAH TOGGLE TEST: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("ALLE TESTS GESLAAGD");
        $finish;
    end

endmodule
