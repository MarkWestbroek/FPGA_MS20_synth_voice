// ============================================================================
// SPI_FRAME_TB — verifieert spi_slave + spi_frame (MusicBrain frame v1)
//
// Bouwt echte frames (incl. CRC-16/CCITT-FALSE) en stuurt ze als SPI mode-0
// master. Controleert CvSet/GateSet-decodering, trigger-puls, Ping→pong_req,
// en dat een frame met foute CRC stil wordt gedropt. Zelf-controlerend.
// ============================================================================

`timescale 1ns / 1ps

module spi_frame_tb();

    reg clk = 0;  always #10 clk = ~clk;        // 50 MHz
    reg rst = 1;

    reg sclk = 0, mosi = 0, cs_n = 1;

    wire [7:0] rx_byte; wire rx_valid, cs_active;

    wire signed [15:0] pitch_cv, cutoff_cv, reson_cv, drive_cv;
    wire gate, trigger, pong_req, frame_ok;

    spi_slave u_slave (
        .clk(clk), .rst(rst), .sclk(sclk), .mosi(mosi), .cs_n(cs_n),
        .rx_byte(rx_byte), .rx_valid(rx_valid), .cs_active(cs_active)
    );

    spi_frame u_frame (
        .clk(clk), .rst(rst),
        .rx_byte(rx_byte), .rx_valid(rx_valid), .cs_active(cs_active),
        .pitch_cv(pitch_cv), .cutoff_cv(cutoff_cv), .reson_cv(reson_cv),
        .drive_cv(drive_cv), .gate(gate), .trigger(trigger),
        .pong_req(pong_req), .frame_ok(frame_ok)
    );

    localparam HALF = 100;        // 5 MHz SCLK
    integer pass = 0, fail = 0;
    reg [15:0] tb_crc;

    // catch pulses
    reg trig_seen = 0, pong_seen = 0, ok_seen = 0;
    always @(posedge clk) begin
        if (trigger)  trig_seen <= 1;
        if (pong_req) pong_seen <= 1;
        if (frame_ok) ok_seen   <= 1;
    end

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
                mosi = b[i]; #HALF; sclk = 1; #HALF; sclk = 0;
            end
        end
    endtask

    // stuur een byte én vouw 'm in tb_crc
    task txc(input [7:0] b);
        begin send_byte(b); tb_crc = crc16_upd(tb_crc, b); end
    endtask

    // CvSet: opcode 0x10, payload u16 channel + i16 value
    task send_cvset(input [7:0] slot, input [15:0] value, input corrupt);
        begin
            cs_n = 0; #HALF;
            tb_crc = 16'hFFFF;
            txc(8'hA5); txc(8'h01); txc(8'h10); txc(8'h04);
            txc(8'h00); txc(slot); txc(value[15:8]); txc(value[7:0]);
            if (corrupt) tb_crc = tb_crc ^ 16'h00FF;   // CRC bewust verpesten
            send_byte(tb_crc[15:8]); send_byte(tb_crc[7:0]);
            #HALF; cs_n = 1; #(HALF*4);
        end
    endtask

    // GateSet: opcode 0x20, payload u16 channel + u8 on
    task send_gateset(input [7:0] slot, input on);
        begin
            cs_n = 0; #HALF;
            tb_crc = 16'hFFFF;
            txc(8'hA5); txc(8'h01); txc(8'h20); txc(8'h03);
            txc(8'h00); txc(slot); txc({7'd0, on});
            send_byte(tb_crc[15:8]); send_byte(tb_crc[7:0]);
            #HALF; cs_n = 1; #(HALF*4);
        end
    endtask

    // Ping: opcode 0x00, geen payload
    task send_ping;
        begin
            cs_n = 0; #HALF;
            tb_crc = 16'hFFFF;
            txc(8'hA5); txc(8'h01); txc(8'h00); txc(8'h00);
            send_byte(tb_crc[15:8]); send_byte(tb_crc[7:0]);
            #HALF; cs_n = 1; #(HALF*4);
        end
    endtask

    task check(input cond, input [255:0] name);
        begin
            if (cond) begin pass=pass+1; $display("  PASS: %0s", name); end
            else      begin fail=fail+1; $display("  FAIL: %0s", name); end
        end
    endtask

    initial begin
        #100; rst = 0; #100;

        // CvSet slot 1 (cutoff) = 0x1234
        ok_seen = 0;
        send_cvset(8'd1, 16'h1234, 1'b0);
        check(cutoff_cv == 16'sh1234, "CvSet cutoff == 0x1234");
        check(ok_seen,                "CvSet frame_ok gepulst");

        // CvSet slot 0 (pitch) = -256
        send_cvset(8'd0, -16'sd256, 1'b0);
        check(pitch_cv == -16'sd256, "CvSet pitch == -256");

        // CvSet slot 2 (reson) = 0x0040
        send_cvset(8'd2, 16'h0040, 1'b0);
        check(reson_cv == 16'sh0040, "CvSet reson == 0x0040");

        // GateSet on -> gate + trigger
        trig_seen = 0;
        send_gateset(8'd0, 1'b1);
        check(gate == 1'b1,  "GateSet gate == 1");
        check(trig_seen,     "GateSet trigger gepulst");

        // GateSet off
        send_gateset(8'd0, 1'b0);
        check(gate == 1'b0,  "GateSet gate == 0");

        // Ping -> pong_req
        pong_seen = 0;
        send_ping;
        check(pong_seen,     "Ping -> pong_req");

        // Foute CRC: cutoff mag NIET veranderen
        ok_seen = 0;
        send_cvset(8'd1, 16'h7FFF, 1'b1);    // corrupt
        check(cutoff_cv == 16'sh1234, "Foute CRC: cutoff ongewijzigd");
        check(!ok_seen,               "Foute CRC: geen frame_ok");

        $display("\n==== SPI FRAME TEST: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("ALLE TESTS GESLAAGD");
        $finish;
    end

endmodule
