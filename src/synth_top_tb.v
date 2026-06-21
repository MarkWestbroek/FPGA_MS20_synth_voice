`timescale 1ns / 1ps

module synth_top_tb();

    reg sys_clk;
    reg sys_rst_n;
    wire led;

    // Instantieer de Unit Under Test
    synth_top uut (
        .sys_clk(sys_clk),
        .sys_rst_n(sys_rst_n),
        .led(led)
    );

    // Klok generator (50 MHz)
    initial begin
        sys_clk = 0;
        forever #10 sys_clk = ~sys_clk;
    end

    // Waveform dump instellingen
    initial begin
        $dumpfile("synth_sim_output.vcd");
        $dumpvars(0, synth_top_tb);
    end

 // Test scenario in src/synth_top_tb.v
    initial begin
        sys_rst_n = 0;
        #200;
        sys_rst_n = 1;

        #500000000; // 500 milliseconden = 0.5 seconde echte audio (~24.000 samples)
        $finish;
    end

   // --- AUDIO DATA LOGGER ---
    // Schrijf ALLEEN een regel als de audio-klok tikt!
    always @(posedge sys_clk) begin
        if (sys_rst_n && uut.sample_clk_tick) begin
            $display("%d", uut.audio_signal);
        end
    end

endmodule