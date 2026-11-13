`timescale 1ns/1ps
module tb;
  reg clk=0, rst_n=0, start=0, load=0, sel=0, sdi=0;
  wire sdo_d, busy_d, busy2_d, sdo_r, busy_r, busy2_r;
  top  dut(.clk(clk),.rst_n(rst_n),.start(start),.load(load),.sel(sel),.sdi(sdi),.sdo(sdo_d),.busy(busy_d),.busy_dup(busy2_d));
  chip u_ref(.io_9_31_1(clk),.io_13_31_1(rst_n),.io_18_31_1(start),.io_17_31_0(load),.io_19_31_1(sel),.io_16_31_0(sdi),
           .io_16_31_1(sdo_r),.io_8_31_1(busy_r),.io_19_31_0(busy2_r));
  integer cyc, errs=0, loads=0, seed, mode;
  always #5 clk=~clk;
  initial begin
    if(!$value$plusargs("seed=%d",seed)) seed=1;
    for(cyc=0;cyc<`NCYC;cyc=cyc+1) begin
      @(negedge clk);
      mode = $random(seed);
      rst_n = ($random(seed)%200)!=0 || cyc<3 ? (cyc>=2) : 0;
      start = ($random(seed)%9)==0;
      load  = ((cyc/37)%3)!=0 ? 1 : (($random(seed)%7)==0);
      sel   = $random(seed);
      sdi   = $random(seed);
      #1;
      if (busy_d!==busy_r || busy2_d!==busy2_r) begin errs=errs+1; if(errs<10) $display("BUSY mismatch cyc %0d",cyc); end
      @(posedge clk); #1;
      if (sdo_d!==sdo_r) begin errs=errs+1; if(errs<10) $display("SDO mismatch cyc %0d",cyc); end
      if ((dut.sr[0] !== u_ref.n628) || (dut.sr[1] !== u_ref.n390) || (dut.sr[2] !== u_ref.n619) || (dut.sr[3] !== u_ref.n384) || (dut.sr[4] !== u_ref.n610) || (dut.sr[5] !== u_ref.n607) || (dut.sr[6] !== u_ref.n609) || (dut.sr[7] !== u_ref.n601) || (dut.sr[8] !== u_ref.n587) || (dut.sr[9] !== u_ref.n578) || (dut.sr[10] !== u_ref.n579) || (dut.sr[11] !== u_ref.n577) || (dut.sr[12] !== u_ref.n698) || (dut.sr[13] !== u_ref.n781) || (dut.sr[14] !== u_ref.n776) || (dut.sr[15] !== u_ref.n897) || (dut.sr[16] !== u_ref.n898) || (dut.sr[17] !== u_ref.n1015) || (dut.sr[18] !== u_ref.n1024) || (dut.sr[19] !== u_ref.n998) || (dut.sr[20] !== u_ref.n1034) || (dut.sr[21] !== u_ref.n907) || (dut.sr[22] !== u_ref.n1039) || (dut.sr[23] !== u_ref.n1038) || (dut.sr[24] !== u_ref.n910) || (dut.sr[25] !== u_ref.n921) || (dut.sr[26] !== u_ref.n915) || (dut.sr[27] !== u_ref.n810) || (dut.sr[28] !== u_ref.n814) || (dut.sr[29] !== u_ref.n798) || (dut.sr[30] !== u_ref.n917) || (dut.sr[31] !== u_ref.n800)) begin errs=errs+1; if(errs<10) $display("SR mismatch cyc %0d dut=%h",cyc,dut.sr); end
      if (load && dut.done) loads=loads+1;
    end
    $display("seed %0d: %0d cycles, %0d result-loads, %0d mismatches", seed, `NCYC, loads, errs);
    $finish;
  end
endmodule
