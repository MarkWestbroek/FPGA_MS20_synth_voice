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

    // Test scenario
    initial begin
        sys_rst_n = 0;
        #200; // 200 ns resetfase
        sys_rst_n = 1;

        #2000000; // We simuleren nu 2 milliseconden (2.000.000 ns)
        $finish;
    end

    // --- AUDIO DATA LOGGER ---
    // Sla de waarden op in de console zodra de reset hoog is (actief)
    always @(posedge sys_clk) begin
        if (sys_rst_n) begin
            // We printen de signed decimal waarde van het audiosignaal
            $display("%d", uut.audio_signal);
        end
    end

endmodule