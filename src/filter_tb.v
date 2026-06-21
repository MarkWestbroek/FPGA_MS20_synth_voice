// ============================================================================
// FILTER_TB — Standalone testbench voor ms20_filter
//
// Test het MS-20 filter met een simpele sinus-input (440 Hz).
// Geen KS, geen sequencer — puur het filter verifiëren.
// ============================================================================

`timescale 1ns / 1ps

module filter_tb();

    reg  clk;
    reg  rst;
    reg  ce;

    // Filter I/O
    reg  signed [31:0] audio_in;
    wire signed [31:0] audio_out;
    reg  signed [31:0] g;
    reg  signed [31:0] k;
    reg         mode;

    // DUT
    ms20_filter u_filter (
        .clk      (clk),
        .rst      (rst),
        .ce       (ce),
        .audio_in (audio_in),
        .audio_out(audio_out),
        .g        (g),
        .k        (k),
        .mode     (mode)
    );

    // ========================================================================
    // 50 MHz klok + 48 kHz ce (zelfde als synth_top)
    // ========================================================================
    reg [10:0] clk_div;

    initial clk = 0;
    always #10 clk = ~clk;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            clk_div <= 0;
            ce      <= 0;
        end else begin
            if (clk_div >= 11'd1041) begin
                clk_div <= 0;
                ce      <= 1;
            end else begin
                clk_div <= clk_div + 1;
                ce      <= 0;
            end
        end
    end

    // ========================================================================
    // Sinus-generator: 440 Hz, amplitude 0.5 in Q12.20
    //
    // We gebruiken een simpele accumulator + LUT-benadering.
    // 440 Hz bij 48 kHz: 48.000/440 ≈ 109 samples per periode.
    // ========================================================================
    reg  [8:0]  sin_phase;   // 0..108 (109 stappen per periode)
    reg  [8:0]  sin_lut [0:108];

    integer i;
    initial begin
        // Genereer 1 periode sinus, 109 samples, Q12.20, amplitude 0.5
        for (i = 0; i < 109; i = i + 1) begin
            sin_lut[i] = $rtoi(0.5 * $sin(2.0 * 3.141592653589793 * i / 109.0) * 1048576.0);
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sin_phase <= 0;
            audio_in  <= 0;
        end else if (ce) begin
            sin_phase <= (sin_phase >= 108) ? 0 : sin_phase + 1;
            audio_in  <= sin_lut[sin_phase];
        end
    end

    // ========================================================================
    // Filter parameters: cutoff ~800 Hz, resonance ~1.0, LP mode
    // g(800Hz) = 2*pi*800/48000 ≈ 0.10472 → Q12.20: 0x1AD00
    // ========================================================================
    initial begin
        g    = 32'h0001AD00;  // ~800 Hz
        k    = 32'h00100000;  // resonance = 1.0
        mode = 1'b0;          // LP
    end

    // ========================================================================
    // Waveform dump
    // ========================================================================
    initial begin
        $dumpfile("filter_sim.vcd");
        $dumpvars(0, filter_tb);
    end

    // ========================================================================
    // Test: reset, dan ~0.5 seconde draaien
    // ========================================================================
    initial begin
        rst = 1;
        #200;
        rst = 0;
        #500000000;
        $finish;
    end

    // ========================================================================
    // Data logger: audio_in, audio_out — Q12.20 raw
    // ========================================================================
    always @(posedge clk) begin
        if (!rst && ce) begin
            $display("in=%d out=%d lp=%d bp=%d hp=%d fb=%d",
                audio_in, audio_out, u_filter.lp, u_filter.bp,
                u_filter.hp, u_filter.feedback_scaled);
        end
    end

endmodule
