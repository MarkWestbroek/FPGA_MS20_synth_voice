// ============================================================================
// SPI_FRAME_TB — verifieert spi_slave + spi_frame (MusicBrain frame v1)
//
// Bouwt echte frames (incl. CRC-16/CCITT-FALSE) en stuurt ze als SPI mode-0
// master. Controleert CvSet/GateSet-decodering, trigger-puls, CRC-rejectie, en
// dat een Ping een Pong-frame op MISO oplevert. Zelf-controlerend.
// ============================================================================

`timescale 1ns / 1ps

module spi_frame_tb();

    reg clk = 0;  always #10 clk = ~clk;        // 50 MHz
    reg rst = 1;

    reg sclk = 0, mosi = 0, cs_n = 1;
    wire miso;

    wire [7:0] rx_byte; wire rx_valid, cs_active;
    wire [7:0] tx_byte; wire tx_load;

    wire signed [15:0] pitch_cv, cutoff_cv, reson_cv, drive_cv;
    wire gate, trigger, pong_req, frame_ok;

    spi_slave u_slave (
        .clk(clk), .rst(rst), .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n),
        .rx_byte(rx_byte), .rx_valid(rx_valid), .cs_active(cs_active),
        .tx_byte(tx_byte), .tx_load(tx_load)
    );

    spi_frame u_frame (
        .clk(clk), .rst(rst),
        .rx_byte(rx_byte), .rx_valid(rx_valid), .cs_active(cs_active),
        .pitch_cv(pitch_cv), .cutoff_cv(cutoff_cv), .reson_cv(reson_cv),
        .drive_cv(drive_cv), .gate(gate), .trigger(trigger),
        .pong_req(pong_req), .frame_ok(frame_ok),
        .tx_byte(tx_byte), .tx_load(tx_load)
    );

    localparam HALF = 100;        // 5 MHz SCLK
    integer pass = 0, fail = 0;
    reg [15:0] tb_crc;

    reg trig_seen = 0, ok_seen = 0, pong_seen = 0;
    always @(posedge clk) begin
        if (trigger)  trig_seen <= 1;
        if (frame_ok) ok_seen   <= 1;
        if (pong_req) pong_seen <= 1;
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

    // mode-0 master: schrijf byte op MOSI én lees byte van MISO (full-duplex)
    task xfer(input [7:0] tx, output [7:0] rx);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                mosi = tx[i];
                #HALF; sclk = 1;
                #(HALF/2); rx[i] = miso;   // midden van de hoge fase samplen
                #(HALF/2); sclk = 0;
            end
        end
    endtask

    task send_byte(input [7:0] b);
        reg [7:0] dummy;
        begin xfer(b, dummy); end
    endtask

    task txc(input [7:0] b);
        begin send_byte(b); tb_crc = crc16_upd(tb_crc, b); end
    endtask

    task send_cvset(input [7:0] slot, input [15:0] value, input corrupt);
        begin
            cs_n = 0; #HALF;
            tb_crc = 16'hFFFF;
            txc(8'hA5); txc(8'h01); txc(8'h10); txc(8'h04);
            txc(8'h00); txc(slot); txc(value[15:8]); txc(value[7:0]);
            if (corrupt) tb_crc = tb_crc ^ 16'h00FF;
            send_byte(tb_crc[15:8]); send_byte(tb_crc[7:0]);
            #HALF; cs_n = 1; #(HALF*4);
        end
    endtask

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

    reg [7:0] r0,r1,r2,r3,r4,r5;
    initial begin
        #100; rst = 0; #100;

        send_cvset(8'd1, 16'h1234, 1'b0);
        check(cutoff_cv == 16'sh1234, "CvSet cutoff == 0x1234");
        check(ok_seen,                "CvSet frame_ok gepulst");

        send_cvset(8'd0, -16'sd256, 1'b0);
        check(pitch_cv == -16'sd256, "CvSet pitch == -256");

        send_cvset(8'd2, 16'h0040, 1'b0);
        check(reson_cv == 16'sh0040, "CvSet reson == 0x0040");

        trig_seen = 0;
        send_gateset(8'd0, 1'b1);
        check(gate == 1'b1,  "GateSet gate == 1");
        check(trig_seen,     "GateSet trigger gepulst");

        send_gateset(8'd0, 1'b0);
        check(gate == 1'b0,  "GateSet gate == 0");

        ok_seen = 0;
        send_cvset(8'd1, 16'h7FFF, 1'b1);
        check(cutoff_cv == 16'sh1234, "Foute CRC: cutoff ongewijzigd");
        check(!ok_seen,               "Foute CRC: geen frame_ok");

        // Ping -> Pong op MISO. Eerst de Ping, dan een read-transactie van 6 bytes.
        pong_seen = 0;
        send_ping;
        check(pong_seen, "Ping gedecodeerd (pong_req)");
        cs_n = 0; #HALF;
        xfer(8'h00, r0); xfer(8'h00, r1); xfer(8'h00, r2);
        xfer(8'h00, r3); xfer(8'h00, r4); xfer(8'h00, r5);
        #HALF; cs_n = 1; #(HALF*4);
        $display("  MISO bytes: %02X %02X %02X %02X %02X %02X (verwacht A5 01 01 00 D6 F2)",
                 r0, r1, r2, r3, r4, r5);
        check(r0==8'hA5 && r1==8'h01 && r2==8'h01 && r3==8'h00 && r4==8'hD6 && r5==8'hF2,
              "Ping naar Pong-frame op MISO");

        $display("\n==== SPI FRAME TEST: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("ALLE TESTS GESLAAGD");
        $finish;
    end

endmodule
