// ============================================================================
// FFT2048_TB — laadt fft_test_in.hex, draait forward + inverse (roundtrip)
// en dumpt beide resultaten voor scripts/fft_check.py (numpy-vergelijking).
//
//   fft_fwd_out.txt : regel 1 = exponent, dan 2048 × "re im"
//   fft_inv_out.txt : idem (inverse van het forward-resultaat)
//
// Interne quick-check: klaar-pulsen komen, exponenten redelijk (< 16).
// ============================================================================

`timescale 1ns / 1ps

module fft2048_tb;

    reg clk = 0;  always #18.5 clk = ~clk;
    reg rst = 1;

    reg         wr_en = 0;
    reg  [10:0] wr_addr = 0;
    reg  signed [17:0] wr_re = 0, wr_im = 0;
    reg  [10:0] rd_addr = 0;
    wire signed [17:0] rd_re, rd_im;
    reg  start = 0, inv = 0;
    wire busy, done;
    wire [4:0] exp_out;

    fft2048 dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_re(wr_re), .wr_im(wr_im),
        .rd_addr(rd_addr), .rd_re(rd_re), .rd_im(rd_im),
        .start(start), .inv(inv), .busy(busy), .done(done), .exp_out(exp_out)
    );

    reg [35:0] vec [0:2047];
    reg signed [17:0] fwd_re [0:2047];
    reg signed [17:0] fwd_im [0:2047];

    integer n, fd;

    task load_from_vec;
        begin
            for (n = 0; n < 2048; n = n + 1) begin
                @(posedge clk);
                wr_en   <= 1'b1;
                wr_addr <= n[10:0];
                wr_re   <= $signed(vec[n][35:18]);
                wr_im   <= $signed(vec[n][17:0]);
            end
            @(posedge clk) wr_en <= 1'b0;
        end
    endtask

    task run_fft;
        input do_inv;
        begin
            @(posedge clk);
            inv   <= do_inv;
            start <= 1'b1;
            @(posedge clk) start <= 1'b0;
            wait (done);
            @(posedge clk);
        end
    endtask

    task dump_result;
        input [8*15:1] fname;
        input          keep;      // 1 = ook in fwd_re/im bewaren
        begin
            fd = $fopen(fname, "w");
            $fwrite(fd, "%0d\n", exp_out);
            for (n = 0; n < 2048; n = n + 1) begin
                @(posedge clk) rd_addr <= n[10:0];
                @(posedge clk);            // rd_addr → m_raddr (idle-mux)
                @(posedge clk);            // m_raddr → raddr_r
                @(posedge clk);            // raddr_r → q (NBA)
                @(negedge clk);            // q stabiel lezen, buiten de race
                $fwrite(fd, "%0d %0d\n", rd_re, rd_im);
                if (keep) begin
                    fwd_re[n] = rd_re;
                    fwd_im[n] = rd_im;
                end
            end
            $fclose(fd);
        end
    endtask

    initial begin
        $readmemh("fft_test_in.hex", vec);
        #200 rst = 0;
        @(posedge clk);

        // ---- forward ----
        load_from_vec;
        run_fft(1'b0);
        $display("FWD klaar: exp=%0d", exp_out);
        if (exp_out < 16) $display("PASS: fwd-exponent plausibel");
        else              $display("FAIL: fwd-exponent %0d", exp_out);
        dump_result("fft_fwd_out.txt", 1'b1);

        // ---- inverse van het forward-resultaat (roundtrip) ----
        for (n = 0; n < 2048; n = n + 1) begin
            @(posedge clk);
            wr_en   <= 1'b1;
            wr_addr <= n[10:0];
            wr_re   <= fwd_re[n];
            wr_im   <= fwd_im[n];
        end
        @(posedge clk) wr_en <= 1'b0;
        run_fft(1'b1);
        $display("INV klaar: exp=%0d", exp_out);
        if (exp_out < 16) $display("PASS: inv-exponent plausibel");
        else              $display("FAIL: inv-exponent %0d", exp_out);
        dump_result("fft_inv_out.txt", 1'b0);

        $display("KLAAR");
        $finish;
    end

endmodule
