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

   // --- COËFFICIËNTEN IN Q12.20 FORMAAT ---
    // a1 staat nu op ~1.99998 (dit dwingt de frequentie naar de sub-regio)
    // a2 staat op ~-0.9995 (zorgt voor een lange, organische decay)
    wire signed [31:0] a1 = 32'h001FFFF0; 
    wire signed [31:0] a2 = 32'hFFEFFF00; 
    wire signed [31:0] b0 = 32'h00040000; // Input gain voor de aanzet
          
    // --- TEST SIGNAAL GENERATOR (Aangepast naar Q12.20) ---
    reg [7:0] pulse_counter;
    reg signed [31:0] f_in;

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            pulse_counter <= 0;
            f_in <= 32'h0;
        end else if (sample_clk_tick) begin 
            if (pulse_counter < 8'hFF) begin
                pulse_counter <= pulse_counter + 1;
            end
            
            if (pulse_counter == 8'd5) begin
                f_in <= 32'h00100000; // 1.0 in Q12.20
            end else begin
                f_in <= 32'h0;
            end
        end
    end

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