`timescale 1ns / 1ps

module synth_top (
    input wire sys_clk,      // Vaste 50MHz klok uit de testbench
    input wire sys_rst_n,    // Active-low reset
    output reg led           // Status LED
);

    wire rst = !sys_rst_n;

    // --- KLOKVERDELER NAAR AUDIO SAMPLERATE (~48 kHz) ---
    // 50.000.000 Hz / 1042 = ~48.013 Hz
    reg [10:0] clk_divider;
    reg sample_clk_tick;

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            clk_divider <= 0;
            sample_clk_tick <= 0;
        end else begin
            if (clk_divider >= 11'd1041) begin
                clk_divider <= 0;
                sample_clk_tick <= 1; // Eén kloktik hoog elke 48kHz
            end else begin
                clk_divider <= clk_divider + 1;
                sample_clk_tick <= 0;
            end
        end
    end

   // --- TEST SIGNAAL GENERATOR (EXCITER) VOOR AUDIO-TEMPO ---
    reg [7:0] pulse_counter;
    reg signed [31:0] f_in;

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            pulse_counter <= 0;
            f_in <= 32'h0;
        end else if (sample_clk_tick) begin 
            // We tellen en updaten f_in UITSLUITEND op de audio-tick!
            if (pulse_counter < 8'hFF) begin
                pulse_counter <= pulse_counter + 1;
            end
            
            if (pulse_counter == 8'd5) begin
                f_in <= 32'h00010000; // 1.0 in Q16.16 (blijft nu 1 hele audiocyclus staan!)
            end else begin
                f_in <= 32'h0;
            end
        end
        // Het destructieve 'else' blok buiten de tick is nu weg!
    end

    // --- COËFFICIËNTEN VOOR ECHTE 55 Hz BAS (op 48kHz sampling) ---
    wire signed [31:0] a1 = 32'h0001FFF5; // Prachtig dicht bij 2.0 voor diepe bas
    wire signed [31:0] a2 = 32'hFFFF0040; // Heel dicht bij -1.0 voor lange sustain
    wire signed [31:0] b0 = 32'h00000100; 

    wire signed [31:0] audio_signal;

   // --- INSTANTIATIE VAN RESONATOR ---
    // We draaien op de stabiele sys_clk en sturen de tick mee als clock enable
    mass_spring_resonator u_resonator (
        .clk(sys_clk), 
        .rst(rst),
        .ce(sample_clk_tick), // <--- We geven de audio-tick mee als enable!
        .f_in(f_in),
        .a1(a1),
        .a2(a2),
        .b0(b0),
        .x_out(audio_signal)
    );

    always @(posedge sys_clk) begin
        led <= audio_signal[31];
    end

endmodule