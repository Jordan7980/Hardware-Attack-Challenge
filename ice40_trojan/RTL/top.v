//==========================================================================
//==========================================================================
// top.v  -  RTL reconstructed from ice40_bitstream.bin
//
// Target  : Lattice iCE40 UltraPlus UP5K, SG48 package
// Source  : 104,090-byte bitstream -> iceunpack -> icebox_vlog netlist,
//           then each register's next-state logic was decoded by hand
//           and checked with simulation against that netlist.
//
// What the design is:
//   A small 32-bit block cipher with a serial (SPI-like) interface.
//   It computes BOTH of these at the same time, 4 rounds each:
//
//     ENCRYPT round (byte k = 0..3):
//         out[k+1] = AES_SBOX( in[k] ^ KEY[k] )         (rotate left 1 byte)
//
//     DECRYPT round (exact inverse of the encrypt round):
//         out[k]   = AES_INV_SBOX( in[k+1] ) ^ KEY[k]   (rotate right 1 byte)
//
//   KEY = 32'h8E_04_3C_B1  (byte3 .. byte0)
//
// Pin map (see top.pcf):
//   pin 36  clk      12 MHz-ish system clock (every FF + BRAM clock)
//   pin 34  rst_n    synchronous, active-low reset
//   pin 27  start    pulse high -> runs 4 rounds
//   pin 28  load     0 = shift sdi into sr every clock
//                    1 = hold sr, and load the result when busy falls
//   pin 25  sel      which result gets loaded: 0 = encrypt, 1 = decrypt
//   pin 32  sdi      serial data in  (enters sr[0])
//   pin 31  sdo      serial data out (sr[31], registered one more clock)
//   pin 38  busy     high while the cipher is running
//   pin 23  busy_dup same signal as busy (both pins driven by one net)
//==========================================================================
//==========================================================================
module top (
    input  wire clk,       // pin 36
    input  wire rst_n,     // pin 34
    input  wire start,     // pin 27
    input  wire load,      // pin 28
    input  wire sel,       // pin 25
    input  wire sdi,       // pin 32
    output reg  sdo,       // pin 31
    output wire busy,      // pin 38
    output wire busy_dup   // pin 23
);

`include "aes_sbox.vh"

    //======================================================================
    // Round keys (one byte per byte lane). In the bitstream these were
    // XOR constants folded into the BRAM address bits / LUT outputs.
    //======================================================================
    localparam [7:0] KEY0 = 8'hB1;
    localparam [7:0] KEY1 = 8'h3C;
    localparam [7:0] KEY2 = 8'h04;
    localparam [7:0] KEY3 = 8'h8E;

    //======================================================================
    // Registers
    //   sr       : 32-bit I/O shift register           (netlist "A" group)
    //   enc_q    : encrypt round state, in BRAM regs   (4x SB_RAM40_4K RDATA)
    //   dec_q    : decrypt round state                 (netlist "B" group)
    //   cnt      : 2-bit round counter                 (n840/n842, n844/n846)
    //   busy_q   : busy delayed one clock              (n972)
    //   has_run  : set by the first start after reset  (n588)
    //======================================================================
    reg  [31:0] sr      = 32'd0;
    reg  [31:0] enc_q   = 32'd0;
    reg  [31:0] dec_q   = 32'd0;
    reg  [1:0]  cnt     = 2'd0;
    reg         busy_q  = 1'b0;
    reg         has_run = 1'b0;

    initial sdo = 1'b0;

    //======================================================================
    // Control
    //   running : we are in rounds 2..4 (cnt != 0)
    //   busy    : a round happens on this clock edge
    //   done    : busy just went low -> result is ready
    //======================================================================
    wire running = (cnt != 2'd0);
    assign busy     = rst_n & (start | running);
    assign busy_dup = busy;
    wire done    = busy_q & ~busy;

    always @(posedge clk) begin
        if (!rst_n) begin
            cnt     <= 2'd0;
            busy_q  <= 1'b0;
            has_run <= 1'b0;
        end else begin
            busy_q <= busy;
            if (busy) begin
                cnt     <= cnt + 2'd1;     // 0 -> 1 -> 2 -> 3 -> 0  (4 rounds)
                has_run <= 1'b1;
            end
        end
    end

    //======================================================================
    // Encrypt path  (was 4 BRAM ROMs, so these regs have NO reset)
    //   Round 1 reads the shift register, rounds 2..4 read their own output.
    //======================================================================
    wire [31:0] enc_in = (running && has_run) ? enc_q : sr;

    always @(posedge clk) begin
        if (busy) begin
            enc_q[15:8]  <= aes_sbox(enc_in[7:0]   ^ KEY0);
            enc_q[23:16] <= aes_sbox(enc_in[15:8]  ^ KEY1);
            enc_q[31:24] <= aes_sbox(enc_in[23:16] ^ KEY2);
            enc_q[7:0]   <= aes_sbox(enc_in[31:24] ^ KEY3);
        end
    end

    //======================================================================
    // Decrypt path  (was LUT logic, synchronous reset)
    //======================================================================
    wire [31:0] dec_in = running ? dec_q : sr;

    always @(posedge clk) begin
        if (!rst_n) begin
            dec_q <= 32'd0;
        end else if (busy) begin
            dec_q[7:0]   <= aes_inv_sbox(dec_in[15:8])  ^ KEY0;
            dec_q[15:8]  <= aes_inv_sbox(dec_in[23:16]) ^ KEY1;
            dec_q[23:16] <= aes_inv_sbox(dec_in[31:24]) ^ KEY2;
            dec_q[31:24] <= aes_inv_sbox(dec_in[7:0])   ^ KEY3;
        end
    end

    //======================================================================
    // I/O shift register
    //   load = 0 : shift in sdi every clock (MSB sr[31] shifts out)
    //   load = 1 : hold, and grab the selected result when busy falls.
    //              If no start has ever happened, the encrypt result is 0.
    //======================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            sr <= 32'd0;
        end else if (!load) begin
            sr <= {sr[30:0], sdi};
        end else if (done) begin
            sr <= sel ? dec_q : (has_run ? enc_q : 32'd0);
        end
    end

    // Serial out has no reset in the original (plain DFF)
    always @(posedge clk) begin
        sdo <= sr[31];
    end

endmodule
//==========================================================================
//==========================================================================
