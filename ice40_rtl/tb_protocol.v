//==========================================================================
//==========================================================================
// tb_protocol.v - drives top.v the way real hardware would:
//   1) shift a 32-bit word in on sdi (load = 0)
//   2) set load = 1, pulse start, wait for busy to fall
//   3) the selected result is now in sr; shift it out on sdo
//
// Run:  iverilog -o tbp tb_protocol.v top.v && vvp tbp
//==========================================================================
//==========================================================================
`timescale 1ns/1ps
module tb_protocol;
    reg clk = 0, rst_n = 0, start = 0, load = 0, sel = 0, sdi = 0;
    wire sdo, busy, busy_dup;

    top dut (.clk(clk), .rst_n(rst_n), .start(start), .load(load), .sel(sel),
             .sdi(sdi), .sdo(sdo), .busy(busy), .busy_dup(busy_dup));

    always #5 clk = ~clk;

    //======================================================================
    // run_cipher: shift in 'din', run 4 rounds, return the selected result
    //======================================================================
    task run_cipher(input [31:0] din, input use_dec, output [31:0] dout);
        integer i;
        begin
            // 1) shift in, MSB first (sr shifts toward sr[31])
            load = 0;
            for (i = 31; i >= 0; i = i - 1) begin
                sdi = din[i];
                @(posedge clk); #1;
            end
            // 2) hold sr, pulse start, wait for busy to fall
            load = 1; sel = use_dec;
            start = 1; @(posedge clk); #1; start = 0;
            while (busy) begin @(posedge clk); #1; end
            @(posedge clk); #1;          // edge where 'done' loads sr
            dout = dut.sr;
            // 3) shift the result out on sdo (sdo is sr[31] delayed 1 clk)
            load = 0; sdi = 0;
            @(posedge clk); #1;
            for (i = 31; i >= 0; i = i - 1) begin
                if (sdo !== dout[i]) $display("  sdo bit %0d wrong", i);
                @(posedge clk); #1;
            end
        end
    endtask

    reg [31:0] ct, pt2, d;
    initial begin
        repeat (3) @(posedge clk); #1;
        rst_n = 1;

        run_cipher(32'h12345678, 1'b0, ct);
        $display("encrypt(12345678) = %08X", ct);

        run_cipher(ct, 1'b1, pt2);
        $display("decrypt(%08X)  = %08X  %s", ct, pt2,
                 (pt2 == 32'h12345678) ? "ROUNDTRIP OK" : "ROUNDTRIP FAIL");

        run_cipher(32'h12345678, 1'b1, d);
        $display("decrypt(12345678) = %08X", d);
        $finish;
    end
endmodule
//==========================================================================
//==========================================================================
