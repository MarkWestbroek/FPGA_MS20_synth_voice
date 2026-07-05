// ============================================================================
// POLY_TB — bewijst 8-stemmige polyfonie van voice_engine (demo-arpeggiator)
//
// Laat de arpeggiator 4,2 s lopen (alle 8 stemmen getriggerd op t=0..3,5 s)
// en checkt aan het einde:
//   - dat er ≥5 stemmen TEGELIJK hoorbaar zijn (per-stem |lastout| > drempel)
//   - dat elke stem op enig moment geklonken heeft
//   - dat de mix binnen de saturatiegrenzen blijft (geen wrap/overflow)
// Zelf-controlerend.
// ============================================================================

`timescale 1ns / 1ps

module poly_tb();

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

    // per-stem piek (ooit geklonken) + mix-piek
    reg [31:0] vpeak [0:7];
    reg [31:0] mix_peak = 0;
    integer i;
    initial for (i = 0; i < 8; i = i + 1) vpeak[i] = 0;

    always @(posedge sys_clk) begin
        if (sys_rst_n && uut.sample_clk_tick) begin
            for (i = 0; i < 8; i = i + 1)
                if (absv(uut.u_engine.lastout[i]) > vpeak[i])
                    vpeak[i] <= absv(uut.u_engine.lastout[i]);
            if (absv(uut.filter_out) > mix_peak)
                mix_peak <= absv(uut.filter_out);
        end
    end

    integer n_now, n_ever;
    initial begin
        sys_rst_n = 0; #200; sys_rst_n = 1;

        #4_200_000_000;   // 4,2 s: stemmen 0..7 getriggerd op 0, 0.5, ... 3.5 s

        // hoeveel stemmen klinken er NU tegelijk? (drempel ~0.00006 = -84 dBFS)
        n_now = 0; n_ever = 0;
        for (i = 0; i < 8; i = i + 1) begin
            if (absv(uut.u_engine.lastout[i]) > 32'h40) n_now = n_now + 1;
            if (vpeak[i] > 32'h1000)                    n_ever = n_ever + 1;
            $display("  stem %0d: |nu|=%0d piek=%0d", i,
                     absv(uut.u_engine.lastout[i]), vpeak[i]);
        end
        $display("  tegelijk hoorbaar: %0d stemmen; ooit geklonken: %0d; mix-piek=%0d",
                 n_now, n_ever, mix_peak);

        check(n_now  >= 5,               "≥5 stemmen klinken tegelijk (polyfonie)");
        check(n_ever == 8,               "alle 8 stemmen hebben geklonken");
        check(mix_peak > 32'h10000,      "mix heeft serieus signaal (> 0.0625)");
        check(mix_peak < 32'h01000000,   "mix blijft onder ±16.0 (geen wrap)");

        $display("\n==== POLY TEST: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("ALLE TESTS GESLAAGD");
        $finish;
    end

endmodule
