//==========================================================================
//==========================================================================
// tb_trojan.v  -  demonstrates the magic-plaintext / key-exfil trojan
//
//   Drives top_trojan.v through the real serial protocol and checks:
//     (A) a NORMAL input still produces the correct ciphertext
//         (same value the golden design gives: encrypt(12345678)=F74E3BB2)
//     (B) the MAGIC input makes the device shift out the KEY (8E043CB1)
//         instead of the ciphertext  -> key recovered.
//
//   Run: iverilog -o tbt tb_trojan.v top_trojan.v && vvp tbt
//==========================================================================
//==========================================================================
`timescale 1ns/1ps
module tb_trojan;
    reg clk = 0, rst_n = 0, start = 0, load = 0, sel = 0, sdi = 0;
    wire sdo, busy, busy_dup;

    top dut (.clk(clk), .rst_n(rst_n), .start(start), .load(load), .sel(sel),
             .sdi(sdi), .sdo(sdo), .busy(busy), .busy_dup(busy_dup));

    always #5 clk = ~clk;

    localparam [31:0] MAGIC = 32'hA53C_9F17;   // the hidden trigger
    localparam [31:0] KEY   = 32'h8E04_3CB1;   // the secret we expect leaked

    //======================================================================
    // run_cipher: shift in 'din', run 4 rounds, shift the result back out
    //======================================================================
    task run_cipher(input [31:0] din, input use_dec, output [31:0] dout);
        integer i;
        begin
            load = 0;
            for (i = 31; i >= 0; i = i - 1) begin
                sdi = din[i]; @(posedge clk); #1;
            end
            load = 1; sel = use_dec;
            start = 1; @(posedge clk); #1; start = 0;
            while (busy) begin @(posedge clk); #1; end
            @(posedge clk); #1;               // 'done' edge loads sr
            load = 0; sdi = 0; dout = 0;
            @(posedge clk); #1;               // sdo = sr[31] delayed one clk
            for (i = 31; i >= 0; i = i - 1) begin
                dout[i] = sdo; @(posedge clk); #1;
            end
        end
    endtask

    reg [31:0] r;  integer fails = 0;
    initial begin
        repeat (3) @(posedge clk); #1;
        rst_n = 1;

        // (A) normal operation - trojan must be invisible
        run_cipher(32'h12345678, 1'b0, r);
        $display("normal : encrypt(12345678) = %08X  (expect F74E3BB2)  %s",
                 r, (r==32'hF74E3BB2) ? "OK" : "FAIL");
        if (r !== 32'hF74E3BB2) fails = fails + 1;

        run_cipher(32'hDEADBEEF, 1'b0, r);
        $display("normal : encrypt(DEADBEEF) = %08X  (not the key)      %s",
                 r, (r!==KEY) ? "OK" : "LEAKED!");
        if (r === KEY) fails = fails + 1;

        // (B) the magic input - payload fires, key falls out
        run_cipher(MAGIC, 1'b0, r);
        $display("TROJAN : encrypt(%08X) = %08X  (expect KEY %08X)  %s",
                 MAGIC, r, KEY, (r===KEY) ? "KEY LEAKED" : "no trigger");
        if (r !== KEY) fails = fails + 1;

        // magic also leaks in decrypt mode
        run_cipher(MAGIC, 1'b1, r);
        $display("TROJAN : decrypt(%08X) = %08X  (expect KEY %08X)  %s",
                 MAGIC, r, KEY, (r===KEY) ? "KEY LEAKED" : "no trigger");
        if (r !== KEY) fails = fails + 1;

        $display(fails==0 ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED");
        $finish;
    end
endmodule
//==========================================================================
//==========================================================================
