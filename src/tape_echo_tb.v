// ============================================================================
// TAPE_ECHO_TB — zelf-checkende testbench + audio-render
//
// Programma (3 s @ 48 kHz):
//   t=0,30 s  impuls (2.0)          → echo's op 0,55 / 0,80 / 1,05 s …
//   t=1,50 s  korte 220 Hz-burst    → ritmische echo-staart (voor het oor)
//
// Instelling: delay 0,25 s, feedback 0,55, damping 0,35, wow 3 samples @0,8 Hz.
// SLEW_Q8=65536 → leeskop springt direct (deterministische check-vensters);
// de muzikale zwiep zit in de default en wordt hier niet getest.
//
// Checks:
//   1. stilte vóór de eerste echo (wet ≈ 0 in [0,32..0,53 s])
//   2. eerste echo aanwezig rond 0,55 s
//   3. tweede echo rond 0,80 s: aanwezig maar zachter (feedback-verval)
//   4. geen overflow: |wet| < 15.0 over de hele run
//
// Output: "in, wet" per tick → wav via scripts/cols2wav.py.
// Sim-truc: ce elke 20 klokken i.p.v. 562 (FSM heeft er ~11 nodig) → snel.
// ============================================================================

`timescale 1ns / 1ps

module tape_echo_tb;

    reg clk = 0;  always #18.5 clk = ~clk;    // ~27 MHz
    reg rst = 1;

    // ce elke 20 klokcycli
    reg [4:0] div = 0;
    reg ce = 0;
    always @(posedge clk) begin
        if (div == 5'd19) begin div <= 0; ce <= 1; end
        else begin div <= div + 5'd1; ce <= 0; end
    end

    reg  signed [31:0] audio_in = 0;
    wire signed [31:0] wet;

    tape_echo #(.MAX_LOG2(15), .SLEW_Q8(65536)) dut (
        .clk(clk), .rst(rst), .ce(ce),
        .audio_in(audio_in), .wet_out(wet),
        .delay_tgt(24'd3072000),              // 12000 samples = 0,25 s (Q16.8)
        .feedback (32'sd576717),              // 0.55
        .damp_a   (32'sd367002),              // 0.35
        .wow_depth(16'd768),                  // 3.0 samples (Q8.8)
        .wow_phinc(24'd280)                   // ~0,8 Hz
    );

    // ---- programma + logging per tick ----
    integer tick = 0;
    integer i;
    reg signed [31:0] burst;

    // check-administratie (Q12.20)
    integer pk_pre = 0;      // max|wet| in [0,32..0,53 s]  (moet stil zijn)
    integer pk_e1  = 0;      // max|wet| rond echo 1 [0,54..0,57 s]
    integer pk_e2  = 0;      // max|wet| rond echo 2 [0,79..0,82 s]
    integer pk_all = 0;      // max|wet| globaal
    integer aw;

    localparam integer T_IMP  = 14400;        // 0,30 s
    localparam integer FS     = 48000;

    always @(posedge clk) if (ce && !rst) begin
        // input-programma
        if (tick == T_IMP)
            audio_in <= 32'sd2097152;                       // impuls 2.0
        else if (tick >= 72000 && tick < 73200) begin       // 1,5 s: 220Hz-burst, 25 ms
            burst = ((tick / 109) & 1) ? 32'sd524288 : -32'sd524288;  // ±0.5 blok
            audio_in <= burst;
        end else
            audio_in <= 32'sd0;

        // log: droog, nat
        $display("%0d, %0d", audio_in, wet);

        // checks
        aw = (wet < 0) ? -wet : wet;
        if (aw > pk_all) pk_all = aw;
        if (tick >= 15360 && tick < 25440 && aw > pk_pre) pk_pre = aw;   // 0,32-0,53
        if (tick >= 25920 && tick < 27360 && aw > pk_e1)  pk_e1  = aw;   // 0,54-0,57
        if (tick >= 37920 && tick < 39360 && aw > pk_e2)  pk_e2  = aw;   // 0,79-0,82

        tick <= tick + 1;
        if (tick == 3*FS) begin
            $display("== TAPE ECHO CHECKS ==");
            if (pk_pre < 32'sd10486)                              // < 0.01
                $display("PASS: stil voor de eerste echo (pk=%0d)", pk_pre);
            else $display("FAIL: signaal voor de eerste echo (pk=%0d)", pk_pre);
            if (pk_e1 > 32'sd52429)                               // > 0.05
                $display("PASS: echo 1 rond 0,55s (pk=%0d)", pk_e1);
            else $display("FAIL: geen echo 1 (pk=%0d)", pk_e1);
            if (pk_e2 > 32'sd10486 && pk_e2 < pk_e1)
                $display("PASS: echo 2 zachter dan echo 1 (%0d < %0d)", pk_e2, pk_e1);
            else $display("FAIL: echo 2 fout (e2=%0d e1=%0d)", pk_e2, pk_e1);
            if (pk_all < 32'sd15728640)                           // < 15.0
                $display("PASS: geen overflow (max=%0d)", pk_all);
            else $display("FAIL: overflow-verdacht (max=%0d)", pk_all);
            $finish;
        end
    end

    initial begin
        #200 rst = 0;
    end

endmodule
