`timescale 1ns/1ps
module tb;
  reg clk=0, rst_n=0, start=0, load=0, sel=0, sdi=0;
  wire o_sdo,o_b1,o_b2, n_sdo,n_b1,n_b2;
  chip     orig(.io_9_31_1(clk),.io_13_31_1(rst_n),.io_18_31_1(start),.io_17_31_0(load),.io_19_31_1(sel),.io_16_31_0(sdi),
                .io_16_31_1(o_sdo),.io_8_31_1(o_b1),.io_19_31_0(o_b2));
  chip_new rebuilt(.io_9_31_1(clk),.io_13_31_1(rst_n),.io_18_31_1(start),.io_17_31_0(load),.io_19_31_1(sel),.io_16_31_0(sdi),
                .io_16_31_1(n_sdo),.io_8_31_1(n_b1),.io_19_31_0(n_b2));
  integer cyc, errs=0, seed, ones=0;
  always #5 clk=~clk;
  initial begin
    if(!$value$plusargs("seed=%d",seed)) seed=1;
    for(cyc=0;cyc<`NCYC;cyc=cyc+1) begin
      @(negedge clk);
      rst_n = (cyc<2) ? 0 : (($random(seed)%200)!=0);
      start = ($random(seed)%9)==0;
      load  = ((cyc/37)%3)!=0 ? 1 : (($random(seed)%7)==0);
      sel   = $random(seed);  sdi = $random(seed);
      #1;
      if ({o_b1,o_b2}!=={n_b1,n_b2}) begin errs=errs+1; if(errs<10) $display("busy mismatch @%0d",cyc); end
      @(posedge clk); #1;
      if (o_sdo!==n_sdo) begin errs=errs+1; if(errs<10) $display("sdo mismatch @%0d",cyc); end
      ones = ones + o_sdo;
    end
    $display("seed %0d: %0d cycles, sdo high %0d times, %0d output mismatches", seed, `NCYC, ones, errs);
    $finish;
  end
endmodule
