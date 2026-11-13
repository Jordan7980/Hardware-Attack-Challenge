# CSAW 2026 AI Hardware Attack Challenge — Qualifier Technical Brief

**Target:** Lattice iCE40 UltraPlus (UP5K, SG48) cryptographic accelerator on the Hackster board

**Deliverable:** AI-generated hardware Trojan (magic-plaintext trigger / key-exfiltration payload) in recovered RTL, with exploit testbench.

---

## 1. Reverse Engineering & Understanding the Bitstream

Starting from the provided `ice40_bitstream.bin` (104,090 bytes), we recovered RTL as follows:

1. **Bitstream → ASCII map.** Unpacked the binary with the Project IceStorm tools from the Yosys OSS CAD Suite:
   `iceunpack ice40_bitstream.bin top.asc`.
2. **ASCII map → structural netlist.** Generated a Verilog netlist of the placed primitives
   (LUT4s, DFFs, `SB_RAM40_4K` block RAMs) with `icebox_vlog top.asc > netlist.v`.
3. **Primitive decoding (by hand, sim-checked).** Each register's next-state logic was decoded
   manually and verified by simulating the readable RTL **against** the `icebox_vlog` netlist for
   identical stimulus until outputs matched cycle-for-cycle. Key mappings we recovered:
   - the 32-bit I/O **shift register** (netlist "A" group),
   - two **round-state registers** — the encrypt path living in 4× `SB_RAM40_4K` outputs, the
     decrypt path in LUT logic ("B" group),
   - a **2-bit round counter** and a one-cycle-delayed `busy` register.
4. **S-box identification.** The four identical BRAM ROM contents were dumped and recognized as the
   standard AES (Rijndael) forward S-box; the LUT-built inverse table matched AES `inv_sbox`.
   (See `aes_sbox.vh`.)
5. **Key extraction.** The per-lane XOR constants folded into the BRAM address/LUT output logic were
   recovered as `KEY = 0x8E043CB1` (byte3..byte0 = `8E 04 3C B1`).

**Validation against the official test vector.** Our recovered `top.v` reproduces the vector baked
into the provided `spi_ice40_crypto_ip_test.py`:

```
encrypt(0x59C359C3) = 0x9CD84392   ✓ (matches provided MicroPython expectation)
decrypt(0x9CD84392) = 0x59C359C3   ✓ (exact inverse)
```

This confirms the recovered RTL is behaviorally identical to the shipped bitstream, so a bitstream
regenerated from the RTL will match the authentic device.

---

## 2. Proposed Explanation of the Encryption System

The IP is a **32-bit block cipher** with a **4-round** substitution–permutation structure and a
**single fixed 32-bit key reused every round** (no key schedule). Both an encrypt and a decrypt core
run in parallel; `ENC_DEC`/`sel` selects which result is loaded back for readout.

Treat the 32-bit word as four bytes, lane `k = 0..3` (lane 0 = LSB). With key bytes
`KEY = {8E, 04, 3C, B1}` (KEY3..KEY0):

**Encrypt round** (forward AES S-box, then rotate the byte lanes left by one):
```
out[(k+1) mod 4] = AES_SBOX( in[k] XOR KEY[k] )
```
Applied 4 times; `x0 = plaintext`, `ciphertext = x4`.

**Decrypt round** (exact inverse — rotate right, inverse S-box, then XOR key):
```
out[k] = AES_INV_SBOX( in[(k+1) mod 4] ) XOR KEY[k]
```
Applied 4 times; `y0 = ciphertext`, `plaintext = y4`.

**Hardware realization.**
- **Unified clock domain:** there is no internal oscillator — the SPI clock drives every flip-flop
  and the round logic. One round executes per clock edge.
- **FSM / timing:** `busy` is combinational, asserts the moment `start` is seen, and falls after 4
  rounds. On the falling edge of `busy` the selected result is parallel-loaded into the shared
  32-bit MSB-first shift register for readback on `sdo`/MISO.
- **Interface:** input is shifted in LSB-into-`sr[0]` while `load=0`; `start` runs the rounds;
  after `busy` falls, 32 clocks shift the result out.

---

## 3. Trojan Design

My Trojan lives entirely inside `top_trojan.v`, a drop-in replacement for the golden `top.v` with an
**identical module name, pinout, and timing**. All added logic sits between the three `TROJAN`
banner blocks; deleting them restores the golden design.

### 3.1 Trigger
A single hidden 32-bit constant, `MAGIC_PLAINTEXT = 0xA53C9F17`. At the start of an operation the
input word still sitting in the shift register is compared against this constant and the match is
latched into `troj_armed` for the duration of the 4 rounds.

- Cost: **one 32-bit comparator + one flip-flop.**
- Because the trigger is an arbitrary full-width value (not a structured pattern), the odds of
  accidental activation are **1 in 2^32**, so normal traffic never trips it.

### 3.2 Payload
When armed, the word loaded for readback is replaced by the secret key
`troj_payload = {KEY3,KEY2,KEY1,KEY0} = 0x8E043CB1` instead of the cipher result. The rounds still
execute with unchanged cycle count and `busy` behavior, so the device leaks the **entire key in a
single transaction** while looking like a normal encrypt/decrypt op. This is **precise key
exfiltration**, and it fires in both encrypt and decrypt modes.

### 3.3 Stealth properties
- **Behavioral invisibility:** for every non-magic input the output is bit-identical to the golden
  model (proven in the testbench, including a near-miss input `0xDEADBEEF`).
- **Timing invariance:** no change to `busy` duration, round count, or SPI sequence.
- **Negligible footprint:** one comparator, one FF, and one extra select term on the existing
  readback mux — no new control states, no new I/O.
- **No magic in the datapath:** the constant only feeds a comparator, so it does not appear as a
  value on any functional bus.

> Honest tradeoff to note for judges: a side-by-side *netlist* diff of golden vs. trojaned would
> reveal the added 32-bit comparator. The Trojan is invisible behaviorally and in timing/resource
> terms, which is the threat model here (black-box device), but it is not hidden from full netlist
> equivalence checking.

### 3.4 Exploit procedure (hardware-reproducible)
Once a bitstream is generated from `top_trojan.v`, recover the key on real hardware as follows:

1. Reset the core (`rst_n` low ≥1 clock, then high).
2. With `load=0`, shift in the 32-bit magic word `0xA53C9F17`, MSB first, over MOSI/`sdi`.
3. Set `load=1`, choose any mode (`sel`/`ENC_DEC` = 0 or 1), pulse `start` high for one clock.
4. Wait for `busy` to fall (4 rounds).
5. With `load=0`, clock 32 times and capture `sdo`/MISO.
6. The 32 bits read back are the key: **`0x8E043CB1`**. (A control run with any other plaintext
   returns the normal ciphertext, confirming stealth.)

This maps directly onto the provided `spi_ice40_crypto_ip_test.py` sequence — swap the plaintext for
the magic word and read the result.

---

## 4. AI Methodology  ⚠️ TEAM MUST COMPLETE — THIS IS THE HIGHEST-SCORED SECTION (35 pts)

> This section is judged primarily on *creative AI usage* and is cross-checked against your submitted
> chat logs in `ai/`. Fill it in with what you actually did. Do not overstate — the logs must back it
> up. Below is the structure to cover; replace each prompt with your real details.

- **Model(s) used:** [e.g. Claude Opus 4.8 — give exact model/version].
- **Interface / method of interaction:** [website UI / API / Claude Code / agentic harness — be specific].
- **Supporting framework:** [any scripting, prompt-chaining, RAG over the netlist/docs, automated
  insert-and-simulate loop, AST/text manipulation of the RTL, etc. If you used a one-command
  generate→insert→simulate pipeline, describe it here — the rubric rewards automation and advanced
  techniques over copy-paste.]
- **Pipeline, step by step:**
  1. How AI was used to *analyze* the recovered netlist / understand the cipher.
  2. How AI *generated* the Trojan logic (prompts, iterations, how insertion was done).
  3. How AI *generated/validated* the exploit testbench.
- **Division of labor:** confirm that all Trojan/exploit HDL was AI-written (challenge requirement),
  with humans limited to tooling, simulation, and this write-up.
- **Reference to logs:** point to the transcript files under `ai/`.

---

## 5. Reproducing Our Results

```
# Golden vs. trojaned behavioral check
iverilog -o tbt tb_trojan.v top_trojan.v && vvp tbt
# Expected:
#   normal : encrypt(12345678) = F74E3BB2  OK
#   normal : encrypt(DEADBEEF) = <ciphertext, not the key>  OK
#   TROJAN : encrypt(A53C9F17) = 8E043CB1  KEY LEAKED
#   TROJAN : decrypt(A53C9F17) = 8E043CB1  KEY LEAKED
#   ALL CHECKS PASSED
```

**Files:** `top.v` (golden recovered RTL), `top_trojan.v` (trojaned), `aes_sbox.vh` (S-box tables),
`tb_trojan.v` (exploit testbench), `top.pcf` (recovered pin constraints).
