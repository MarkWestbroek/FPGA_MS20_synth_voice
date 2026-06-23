// ============================================================================
// I2S_TX_TB — verifieert dat i2s_tx een 16-bit sample MSB-first uitschuift.
// Sampelt sdata op de stijgende BCLK-flank (zoals de DAC) en zoekt het gevoede
// 16-bit patroon terug in de bitstroom (alignment-agnostisch). Zelf-controlerend.
// ============================================================================

`timescale 1ns / 1ps

module i2s_tx_tb();

    reg clk = 0; always #10 clk = ~clk;     // 50 MHz (sim)
    reg rst = 1;
    reg signed [15:0] sample = 16'h0000;

    wire bclk, lrck, sdata;

    i2s_tx dut (
        .clk(clk), .rst(rst), .sample_in(sample),
        .bclk(bclk), .lrck(lrck), .sdata(sdata)
    );

    localparam [15:0] A = 16'hA53C;
    localparam [15:0] B = 16'h1234;

    reg [15:0] win = 16'd0;
    reg seenA = 1'b0, seenB = 1'b0;

    always @(posedge bclk) begin
        win <= {win[14:0], sdata};
        if ({win[14:0], sdata} == A) seenA <= 1'b1;
        if ({win[14:0], sdata} == B) seenB <= 1'b1;
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
        sample = A; #200000;
        chk(seenA, "sample A MSB-first in SD-stream");
        seenB = 0; sample = B; #200000;
        chk(seenB, "sample B na wijziging zichtbaar");
        $display("\n==== I2S TEST: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("ALLE TESTS GESLAAGD");
        $finish;
    end

endmodule
