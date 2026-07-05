// ============================================================================
// SYNTH_TOP_SPI_TB — end-to-end test: SPI-frames → audio (2 stemmen)
//
// Stuurt MusicBrain-frames naar synth_top in SPI-mode (demo_mode=0):
// stem 0 (slots 0..3) krijgt A1, stem 1 (slots 4..7) krijgt D2 (0,3 s later).
// Rendert ~1.5 s audio (CSV via $display) en controleert dat beide stemmen
// daadwerkelijk klinken.
// ============================================================================

`timescale 1ns / 1ps

module synth_top_spi_tb();

    reg sys_clk = 0; always #10 sys_clk = ~sys_clk;   // 50 MHz
    reg sys_rst_n = 0;

    reg spi_sclk = 0, spi_mosi = 0, spi_cs_n = 1;
    wire led;
    wire signed [31:0] audio_out = uut.filter_out;   // intern filter-signaal (geen poort meer)

    synth_top #(.SYS_CLK_HZ(50_000_000), .DEMO_ONLY(0)) uut (   // tb klokt op 50 MHz
        .sys_clk(sys_clk), .sys_rst_n(sys_rst_n),
        .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(), .spi_cs_n(spi_cs_n),
        .demo_mode(1'b0),               // SPI-gedreven
        .key_mute_n(1'b1),              // niet ingedrukt
        .wah_sw(1'b1),                  // wah aan
        .wah_btn_n(1'b1),               // knop niet ingedrukt
        .led(led),
        .hp_bck(), .hp_ws(), .hp_din(), .pa_en()
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

    // peak-trackers: mix + per stem (bewijst dat béide stemmen klinken)
    reg signed [31:0] filt_peak = 0, str_peak = 0;
    reg [31:0] v0_peak = 0, v1_peak = 0;
    function signed [31:0] absval(input signed [31:0] x);
        absval = (x < 0) ? -x : x;
    endfunction
    always @(posedge sys_clk) begin
        if (uut.sample_clk_tick) begin
            if (absval(audio_out)       > filt_peak) filt_peak <= absval(audio_out);
            if (absval(uut.string_out)  > str_peak)  str_peak  <= absval(uut.string_out);
            if (absval(uut.u_engine.lastout[0]) > v0_peak)
                v0_peak <= absval(uut.u_engine.lastout[0]);
            if (absval(uut.u_engine.lastout[1]) > v1_peak)
                v1_peak <= absval(uut.u_engine.lastout[1]);
        end
    end

    // audio-render: CSV (string, filter)
    always @(posedge sys_clk)
        if (sys_rst_n && uut.sample_clk_tick)
            $display("%d,%d", uut.string_out, audio_out);

    initial begin
        sys_rst_n = 0; #200; sys_rst_n = 1; #200;

        // ---- stem 0 (slots 0..3): A1, cutoff ~1500Hz, hoge resonantie, drive
        send_cvset(8'd1, 16'h323E);   // v0 cutoff → g ≈ 0x191F0
        send_cvset(8'd2, 16'h6000);   // v0 reson  → k ≈ 0.25 (scream)
        send_cvset(8'd3, 16'h7FFF);   // v0 drive  → ≈ 3.0
        // Pitch-dCV noot 33 (A1): bin-midden = round(33.5*65536/120) = 0x4777
        send_cvset(8'd0, 16'h4777);
        send_gateset(8'd0, 1'b1);     // stem 0 aan

        // ---- stem 1 (slots 4..7): D2, mildere instellingen, 0,3 s later
        #300000000;
        send_cvset(8'd5, 16'h2000);   // v1 cutoff
        send_cvset(8'd6, 16'h3000);   // v1 reson
        send_cvset(8'd7, 16'h4000);   // v1 drive
        // Pitch-dCV noot 38 (D2): bin-midden = round(38.5*65536/120) = 0x5222
        send_cvset(8'd4, 16'h5222);
        send_gateset(8'd1, 1'b1);     // stem 1 aan

        // rest laten klinken (totaal ~1.5 s)
        #1200000000;

        $display("PEAKCHECK str_peak=%0d filt_peak=%0d v0=%0d v1=%0d",
                 str_peak, filt_peak, v0_peak, v1_peak);
        if (str_peak > 0 && filt_peak > 0 && v0_peak > 0 && v1_peak > 0)
            $display("END_OK: SPI-gedreven audio op beide stemmen");
        else
            $display("END_FAIL: geen (2-stemmige) audio");
        $finish;
    end

endmodule
