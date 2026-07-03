// ============================================================================
// WAH_TOGGLE_TB — regressietest voor de wah-schakelaar (E8) en de reset-knop
//
// Speelt het hardware-scenario na:
//   1. boot met wah aan   → noot 1 & 2 moeten met G_OPEN starten (sweep)
//   2. wah uit (E8)       → noot 3 moet statisch op G_FIXED staan
//   3. wah weer aan       → noot 4 moet wéér met G_OPEN starten
//   4. reset-puls (T3)    → demo herstart; eerste noot ná reset weer G_OPEN
//                           en er komt weer geluid uit de string
//   5. drukknop (T2)      → één druk flipt de wah UIT (noot start op G_FIXED),
//                           nóg een druk flipt hem weer AAN (noot start open)
// Zelf-controlerend: PASS/FAIL per stap + eindoordeel.
// ============================================================================

`timescale 1ns / 1ps

module wah_toggle_tb();

    reg sys_clk = 0; always #10 sys_clk = ~sys_clk;   // 50 MHz
    reg sys_rst_n = 0;
    reg wah_sw    = 1;                                 // start: wah aan (DIP)
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

    // Filter-g referenties (zelfde waarden als synth_top)
    localparam [31:0] G_OPEN  = 32'h000322F5;
    localparam [31:0] G_FIXED = 32'h0000D671;

    integer pass = 0, fail = 0;
    task check(input cond, input [255:0] name);
        begin
            if (cond) begin pass=pass+1; $display("  PASS: %0s", name); end
            else      begin fail=fail+1; $display("  FAIL: %0s", name); end
        end
    endtask

    // g "begint open": binnen 1 sweep-stap van G_OPEN (sample is 3 ticks na trigger)
    function g_is_open(input [31:0] g);
        g_is_open = (g <= G_OPEN) && (g >= G_OPEN - 32'h1000);
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
                $display("TRIG %0d @%0d ms  wah=%b  g=%h", trig_n, $time/1000000, wah_sw, g_smp);
                case (trig_n)
                    1: check(g_is_open(g_smp),   "noot 1 (wah aan): start open");
                    2: check(g_is_open(g_smp),   "noot 2 (wah aan): start open");
                    3: check(g_smp == G_FIXED,   "noot 3 (wah uit): statisch G_FIXED");
                    4: check(g_is_open(g_smp),   "noot 4 (wah WEER aan): start open");
                    5: check(g_is_open(g_smp),   "noot 5 (na reset-knop): start open");
                    6: check(g_smp == G_FIXED,   "noot 6 (T2 gedrukt): wah geflipt UIT");
                    7: check(g_is_open(g_smp),   "noot 7 (T2 nogmaals): wah geflipt AAN");
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

    initial begin
        // boot
        sys_rst_n = 0; #200; sys_rst_n = 1;

        // noot 1 (0..1.5s) en noot 2 (1.5..3.0s) met wah aan
        #2_000_000_000;          // t = 2.0 s (midden noot 2)
        wah_sw = 0;              // E8 uit
        $display("--- wah UIT @ %0d ms", $time/1000000);

        #1_500_000_000;          // t = 3.5 s (noot 3 is om 3.0 s gestart, wah uit)
        wah_sw = 1;              // E8 weer aan
        $display("--- wah AAN @ %0d ms", $time/1000000);

        #1_600_000_000;          // t = 5.1 s (noot 4 om 4.5 s gestart, wah aan)

        // reset-knop (T3) indrukken
        $display("--- RESET-puls @ %0d ms", $time/1000000);
        sys_rst_n = 0; #10_000; sys_rst_n = 1;
        post_reset = 1;

        #500_000_000;            // 0.5 s na reset: noot 5 + string-audio meten

        check(str_peak_post > 0, "audio (string) aanwezig na reset");

        // drukknop T2: één druk (100 ms, ruim boven de debounce) → wah UIT
        $display("--- T2 druk 1 @ %0d ms", $time/1000000);
        wah_btn_n = 0; #100_000_000; wah_btn_n = 1;
        #1_400_000_000;          // noot 6 @ ~6.6 s (1.5 s na herstart-noot 5)

        // en nóg een druk → wah weer AAN
        $display("--- T2 druk 2 @ %0d ms", $time/1000000);
        wah_btn_n = 0; #100_000_000; wah_btn_n = 1;
        #1_500_000_000;          // noot 7 @ ~8.1 s

        check(trig_n >= 7,       "7 triggers gezien");

        $display("\n==== WAH TOGGLE TEST: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("ALLE TESTS GESLAAGD");
        $finish;
    end

endmodule
