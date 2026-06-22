// ============================================================================
// SYNTH_TOP_SPI_TB — end-to-end test: SPI-frames → audio
//
// Stuurt MusicBrain-frames (cutoff/reson/drive-CV + pitch-CV + GateSet) naar
// synth_top in SPI-mode (demo_mode=0), rendert ~1.5 s audio (CSV via $display)
// en controleert dat er daadwerkelijk geluid uit het filter komt.
// ============================================================================

`timescale 1ns / 1ps

module synth_top_spi_tb();

    reg sys_clk = 0; always #10 sys_clk = ~sys_clk;   // 50 MHz
    reg sys_rst_n = 0;

    reg spi_sclk = 0, spi_mosi = 0, spi_cs_n = 1;
    wire led;
    wire signed [31:0] audio_out;

    synth_top uut (
        .sys_clk(sys_clk), .sys_rst_n(sys_rst_n),
        .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(), .spi_cs_n(spi_cs_n),
        .demo_mode(1'b0),               // SPI-gedreven
        .led(led), .audio_out(audio_out)
    );

    localparam HALF = 100;              // 5 MHz SCLK
    reg [15:0] tb_crc;

    function [15:0] crc16_upd(input [15:0] crc_in, input [7:0] data);
        integer i; reg [15:0] c;
        begin
            c = crc_in ^ {data, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc16_upd = c;
        end
    endfunction

    task send_byte(input [7:0] b);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                spi_mosi = b[i]; #HALF; spi_sclk = 1; #HALF; spi_sclk = 0;
            end
        end
    endtask

    task txc(input [7:0] b);
        begin send_byte(b); tb_crc = crc16_upd(tb_crc, b); end
    endtask

    task send_cvset(input [7:0] slot, input [15:0] value);
        begin
            spi_cs_n = 0; #HALF;
            tb_crc = 16'hFFFF;
            txc(8'hA5); txc(8'h01); txc(8'h10); txc(8'h04);
            txc(8'h00); txc(slot); txc(value[15:8]); txc(value[7:0]);
            send_byte(tb_crc[15:8]); send_byte(tb_crc[7:0]);
            #HALF; spi_cs_n = 1; #(HALF*4);
        end
    endtask

    task send_gateset(input [7:0] slot, input on);
        begin
            spi_cs_n = 0; #HALF;
            tb_crc = 16'hFFFF;
            txc(8'hA5); txc(8'h01); txc(8'h20); txc(8'h03);
            txc(8'h00); txc(slot); txc({7'd0, on});
            send_byte(tb_crc[15:8]); send_byte(tb_crc[7:0]);
            #HALF; spi_cs_n = 1; #(HALF*4);
        end
    endtask

    // peak-tracker om te bewijzen dat er geluid is
    reg signed [31:0] filt_peak = 0, str_peak = 0;
    function signed [31:0] absval(input signed [31:0] x);
        absval = (x < 0) ? -x : x;
    endfunction
    always @(posedge sys_clk) begin
        if (uut.sample_clk_tick) begin
            if (absval(audio_out)       > filt_peak) filt_peak <= absval(audio_out);
            if (absval(uut.string_out)  > str_peak)  str_peak  <= absval(uut.string_out);
        end
    end

    // audio-render: CSV (string, filter)
    always @(posedge sys_clk)
        if (sys_rst_n && uut.sample_clk_tick)
            $display("%d,%d", uut.string_out, audio_out);

    initial begin
        sys_rst_n = 0; #200; sys_rst_n = 1; #200;

        // Filterparameters via CV: cutoff ~1500Hz, hoge resonantie, flinke drive
        send_cvset(8'd1, 16'h323E);   // cutoff → g ≈ 0x191F0
        send_cvset(8'd2, 16'h6000);   // reson  → k ≈ 0.25 (scream)
        send_cvset(8'd3, 16'h7FFF);   // drive  → ≈ 3.0

        // Pitch-dCV voor noot 33 (A1): bin-midden = round(33.5*65536/120) = 18295 (0x4777)
        // (0..10V, 1 V/oct, 0V = MIDI 0; note = code*120>>16 = 33)
        send_cvset(8'd0, 16'h4777);

        // Noot aan
        send_gateset(8'd0, 1'b1);

        // ~1.5 s laten klinken
        #1500000000;

        $display("PEAKCHECK str_peak=%0d filt_peak=%0d", str_peak, filt_peak);
        if (str_peak > 0 && filt_peak > 0)
            $display("END_OK: SPI-gedreven audio aanwezig");
        else
            $display("END_FAIL: geen audio");
        $finish;
    end

endmodule
