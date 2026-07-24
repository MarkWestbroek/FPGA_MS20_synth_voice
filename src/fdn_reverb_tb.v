// ============================================================================
// FDN_REVERB_TB — zelf-checkende testbench + audio-render
//
// Programma (3 s @ 48 kHz): impuls (2.0) op t=0,20 s → galmstaart.
// Instelling: g=2,4 (RT ~1,5-2 s), damp 0,5.
//
// Checks (venster-energie = som|wet|/N over 0,2 s-vensters):
//   1. galm aanwezig kort na de impuls    (E1: 0,25–0,45 s)
//   2. staart nog hoorbaar rond 1,2 s     (E2: 1,10–1,30 s > 0)
//   3. verval: E1 > E2 > E3 (2,10–2,30 s) — monotoon uitsterven
//   4. dichtheid: in 0,5–0,7 s is > 80% van de samples ≠ 0 (diffusie,
//      geen losse flutter-tikken)
//   5. geen overflow: |wet| < 15.0
//
// Output: "in, wet" per tick → wav via scripts/cols2wav.py.
// Sim-truc: ce elke 40 klokken (FSM heeft er ~30 nodig) i.p.v. 562.
// ============================================================================

`timescale 1ns / 1ps

module fdn_reverb_tb;

    reg clk = 0;  always #18.5 clk = ~clk;
    reg rst = 1;

    reg [5:0] div = 0;
    reg ce = 0;
    always @(posedge clk) begin
        if (div == 6'd39) begin div <= 0; ce <= 1; end
        else begin div <= div + 6'd1; ce <= 0; end
    end

    reg  signed [31:0] audio_in = 0;
    wire signed [31:0] wet;

    fdn_reverb dut (
        .clk(clk), .rst(rst), .ce(ce),
        .audio_in(audio_in), .wet_out(wet),
        .g      (32'sd2726297),               // 2.6  (lus ≈ 0,92/pass)
        .damp_a (32'sd734003)                 // 0.7  (helderder, minder verlies)
    );

    integer tick = 0;
    integer aw;
    // venster-accumulatoren (|wet| >>> 8 zodat de som in 32 bit past)
    integer e1 = 0, e2 = 0, e3 = 0;
    integer nz = 0;                           // niet-nul samples in dichtheidsvenster
    integer pk_all = 0;

    localparam integer FS = 48000;

    always @(posedge clk) if (ce && !rst) begin
        audio_in <= (tick == 9600) ? 32'sd2097152 : 32'sd0;   // impuls 2.0 @0,2s

        $display("%0d, %0d", audio_in, wet);

        aw = (wet < 0) ? -wet : wet;
        if (aw > pk_all) pk_all = aw;
        if (tick >= 12000 && tick <  21600) e1 = e1 + (aw >>> 8);
        if (tick >= 52800 && tick <  62400) e2 = e2 + (aw >>> 8);
        if (tick >= 100800 && tick < 110400) e3 = e3 + (aw >>> 8);
        if (tick >= 24000 && tick < 33600 && aw != 0) nz = nz + 1;

        tick <= tick + 1;
        if (tick == 3*FS) begin
            $display("== FDN REVERB CHECKS ==");
            if (e1 > 32'sd9600)
                $display("PASS: galm na impuls (E1=%0d)", e1);
            else $display("FAIL: geen galm (E1=%0d)", e1);
            if (e2 > 0)
                $display("PASS: staart rond 1,2s (E2=%0d)", e2);
            else $display("FAIL: staart dood op 1,2s (E2=%0d)", e2);
            if (e1 > e2 && e2 > e3)
                $display("PASS: monotoon verval (%0d > %0d > %0d)", e1, e2, e3);
            else $display("FAIL: verval niet monotoon (%0d, %0d, %0d)", e1, e2, e3);
            if (nz > 7680)                                    // >80% van 9600
                $display("PASS: dichte staart (%0d/9600 samples actief)", nz);
            else $display("FAIL: dunne staart (%0d/9600)", nz);
            if (pk_all < 32'sd15728640)
                $display("PASS: geen overflow (max=%0d)", pk_all);
            else $display("FAIL: overflow-verdacht (max=%0d)", pk_all);
            $finish;
        end
    end

    initial begin
        #200 rst = 0;
    end

endmodule
