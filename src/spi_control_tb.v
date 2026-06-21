// ============================================================================
// SPI_CONTROL_TB — verifieert spi_slave + spi_control
//
// Drijft een SPI mode-0 master (5 MHz) tegen de slave (50 MHz sys_clk) en
// controleert dat 4-byte pakketten correct naar parameters decoderen.
// Zelf-controlerend: print PASS/FAIL en een eindtotaal.
// ============================================================================

`timescale 1ns / 1ps

module spi_control_tb();

    reg clk = 0;
    reg rst = 1;
    always #10 clk = ~clk;        // 50 MHz

    // SPI-lijnen
    reg sclk = 0;
    reg mosi = 0;
    reg cs_n = 1;

    // slave -> control
    wire [7:0] rx_byte;
    wire       rx_valid;
    wire       cs_active;

    // gedecodeerde parameters
    wire [10:0] note_period;
    wire        trigger;
    wire        gate;
    wire signed [31:0] cf_g, cf_k, cf_drive;
    wire        mode;

    spi_slave u_slave (
        .clk(clk), .rst(rst),
        .sclk(sclk), .mosi(mosi), .cs_n(cs_n),
        .rx_byte(rx_byte), .rx_valid(rx_valid), .cs_active(cs_active)
    );

    spi_control u_ctrl (
        .clk(clk), .rst(rst),
        .rx_byte(rx_byte), .rx_valid(rx_valid), .cs_active(cs_active),
        .note_period(note_period), .trigger(trigger), .gate(gate),
        .cf_g(cf_g), .cf_k(cf_k), .cf_drive(cf_drive), .mode(mode)
    );

    localparam HALF = 100;        // halve SCLK-periode (5 MHz)

    integer pass = 0, fail = 0;

    // catch trigger-puls
    reg trig_seen = 0;
    always @(posedge clk) if (trigger) trig_seen <= 1;

    task send_byte(input [7:0] b);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                mosi = b[i];
                #HALF;  sclk = 1;   // stijgende flank -> sample
                #HALF;  sclk = 0;
            end
        end
    endtask

    task send_packet(input [7:0] cmd, input [7:0] voice,
                     input [7:0] hi,  input [7:0] lo);
        begin
            cs_n = 0;  #HALF;
            send_byte(cmd);
            send_byte(voice);
            send_byte(hi);
            send_byte(lo);
            #HALF;  cs_n = 1;  #(HALF*4);   // frame klaar + settle
        end
    endtask

    task check(input cond, input [255:0] name);
        begin
            if (cond) begin pass = pass + 1; $display("  PASS: %0s", name); end
            else      begin fail = fail + 1; $display("  FAIL: %0s", name); end
        end
    endtask

    initial begin
        #100; rst = 0; #100;

        // NOTE_ON, period = 0x123 (291)
        trig_seen = 0;
        send_packet(8'h90, 8'h00, 8'h01, 8'h23);
        check(note_period == 11'h123, "NOTE_ON period == 0x123");
        check(gate == 1'b1,           "NOTE_ON gate == 1");
        check(trig_seen == 1'b1,      "NOTE_ON trigger gepulst");

        // CUTOFF, param16 = 0x0800 -> g = 0x0800<<2 = 0x2000
        send_packet(8'hB0, 8'h00, 8'h08, 8'h00);
        check(cf_g == 32'h00002000, "CUTOFF g == 0x2000");

        // RESON, param16 = 0x0200 -> k = 0x0200<<7 = 0x10000
        send_packet(8'hB1, 8'h00, 8'h02, 8'h00);
        check(cf_k == 32'h00010000, "RESON k == 0x10000");

        // DRIVE, param16 = 0x0040 -> drive = 0x0040<<8 = 0x4000
        send_packet(8'hB2, 8'h00, 8'h00, 8'h40);
        check(cf_drive == 32'h00004000, "DRIVE drive == 0x4000");

        // MODE = 1 (HP)
        send_packet(8'hB3, 8'h00, 8'h00, 8'h01);
        check(mode == 1'b1, "MODE == 1 (HP)");

        // NOTE_OFF -> gate 0
        send_packet(8'h80, 8'h00, 8'h00, 8'h00);
        check(gate == 1'b0, "NOTE_OFF gate == 0");

        $display("\n==== SPI TEST: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("ALLE TESTS GESLAAGD");
        $finish;
    end

endmodule
