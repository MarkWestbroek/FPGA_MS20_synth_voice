// ============================================================================
// PT8211_TX_TB — verifieert dat pt8211_tx een 16-bit sample MSB-first uitschuift.
// Sampelt hp_din op de stijgende BCK-flank (zoals de echte DAC) en zoekt het
// gevoede 16-bit patroon terug in de bitstroom. Zelf-controlerend.
// ============================================================================

`timescale 1ns / 1ps

module pt8211_tx_tb();

    reg clk = 0; always #10 clk = ~clk;     // 50 MHz (sim)
    reg rst = 1;
    reg signed [15:0] sample = 16'h0000;

    wire hp_bck, hp_ws, hp_din, pa_en;

    pt8211_tx dut (
        .clk(clk), .rst(rst), .sample_in(sample), .en(1'b1),
        .hp_bck(hp_bck), .hp_ws(hp_ws), .hp_din(hp_din), .pa_en(pa_en)
    );

    localparam [15:0] A = 16'hA53C;
    localparam [15:0] B = 16'h1234;

    reg [15:0] win = 16'd0;
    reg seenA = 1'b0, seenB = 1'b0;

    // DAC sampelt DIN op stijgende BCK; reconstrueer 16-bit venster
    always @(posedge hp_bck) begin
        win <= {win[14:0], hp_din};
        if ({win[14:0], hp_din} == A) seenA <= 1'b1;
        if ({win[14:0], hp_din} == B) seenB <= 1'b1;
    end

    integer pass = 0, fail = 0;
    task chk(input c, input [255:0] n);
        begin
            if (c) begin pass=pass+1; $display("  PASS: %0s", n); end
            else   begin fail=fail+1; $display("  FAIL: %0s", n); end
        end
    endtask

    initial begin
        #100; rst = 0;
        sample = A; #200000;                 // enkele frames met A
        chk(seenA, "sample A MSB-first in DIN-stream");
        chk(pa_en, "pa_en hoog (versterker aan)");
        seenB = 0; sample = B; #200000;      // wissel naar B
        chk(seenB, "sample B na wijziging zichtbaar");
        $display("\n==== PT8211 TEST: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("ALLE TESTS GESLAAGD");
        $finish;
    end

endmodule
