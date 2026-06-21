// ============================================================================
// SYNTH_TOP_TB — Testbench voor KS String Bass + MS-20 Filter
//
// Logt de KS-string output en filter output in CSV-formaat.
// Simuleert ~8 seconden om alle 4+ noten te horen.
// ============================================================================

`timescale 1ns / 1ps

module synth_top_tb();

    reg  sys_clk;
    reg  sys_rst_n;
    wire led;
    wire signed [31:0] audio_out;

    // Instantieer de Unit Under Test
    synth_top uut (
        .sys_clk   (sys_clk),
        .sys_rst_n (sys_rst_n),
        .led       (led),
        .audio_out (audio_out)
    );

    // ========================================================================
    // Klok generator (50 MHz, periode = 20 ns)
    // ========================================================================
    initial begin
        sys_clk = 0;
        forever #10 sys_clk = ~sys_clk;
    end

    // ========================================================================
    // Waveform dump (voor GTKWave / Gowin DSim)
    // ========================================================================
    initial begin
        $dumpfile("synth_sim_output.vcd");
        $dumpvars(0, synth_top_tb);
    end

    // ========================================================================
    // Test scenario — ~8 seconden audio
    // ========================================================================
    initial begin
        sys_rst_n = 0;
        #200;
        sys_rst_n = 1;

        // ~3 seconden: genoeg voor 2 noten
        #3000000000;
        $finish;
    end

    // ========================================================================
    // AUDIO DATA LOGGER — CSV: ks_string_out, filter_out
    //
    // Kolom 1: KS string output (droge klank)
    // Kolom 2: MS-20 filter output (gefilterde klank)
    // ========================================================================
    always @(posedge sys_clk) begin
        if (sys_rst_n && uut.sample_clk_tick) begin
            // Eerst alleen de KS-string output loggen ter verificatie,
            // filter output volgt zodra de x-debug is opgelost.
            $display("%d", uut.string_out);
        end
    end

endmodule