# Chat Transcript — iCE40 Bitstream Reverse-Engineering & Trojan

Session: reconstructing RTL from an iCE40 bitstream, rebuilding/comparing the
bitstream, and adding a hardware trojan for a hardware-attack challenge.

---

## 1. User: "Create an RTL based off of this bitstream"
Attached: `ice40_bitstream.bin` (104,090 bytes)

**Claude:**
- Identified it as a Lattice iCE40 **UP5K** bitstream (sync word `7E AA 99 7E`,
  size matches UP5K).
- Installed Project IceStorm + Yosys + nextpnr. Ran `iceunpack` then
  `icebox_vlog` to recover a gate-level netlist (1404 LUTs, 71 FFs, 4 BRAMs).
- Confirmed DSP/IPCON tiles were just defaults (nothing hidden there).
- Decoded the BRAM ROM: it is the **AES forward S-box**.
- Grouped the 71 flip-flops by what feeds them and recovered the architecture:
  - 32-bit I/O shift register (`sr`)
  - 32-bit encrypt state (`enc_q`, in the 4 BRAMs)
  - 32-bit decrypt state (`dec_q`, in LUT logic = **AES inverse S-box**)
  - 2-bit round counter, busy/has_run control flags
- Recovered the hidden key `0x8E043CB1` from the folded XOR constants.

**Result:** the design is a **32-bit, 4-round block cipher** with a serial
(SPI-like) interface that computes encrypt and decrypt in parallel:
```
ENCRYPT round:  out[k+1] = AES_SBOX( in[k] ^ KEY[k] )       (rotate left)
DECRYPT round:  out[k]   = AES_INV_SBOX( in[k+1] ) ^ KEY[k] (rotate right)
KEY = 0x8E043CB1
```

Pin map:
| Pin | Signal | Function |
|----|--------|----------|
| 36 | clk      | clock |
| 34 | rst_n    | active-low sync reset |
| 27 | start    | pulse -> run 4 rounds |
| 28 | load     | 0 = shift in, 1 = hold / capture result |
| 25 | sel      | 0 = encrypt result, 1 = decrypt result |
| 32 | sdi      | serial data in |
| 31 | sdo      | serial data out |
| 38 | busy     | high while running |
| 23 | busy_dup | duplicate of busy |

**Verification:** wrote `top.v` and simulated it lock-step against the netlist
decoded from the bitstream — **0 mismatches over ~850,000 random cycles**.
Mutation tests (flipping a key bit/byte) were caught immediately.
Synthesis/P&R: 1164 LCs, 4 BRAMs, ~41 MHz.

Deliverables in `/home/user/ice40_rtl/`: `top.v`, `aes_sbox.vh`, `top.pcf`,
`cipher_model.cpp`, `tb_protocol.v`, `tb_equiv.v`, `bitstream_netlist.v`,
`design.asc`.

---

## 2. User: "Generate the bitstream from top.v and compare it"

**Claude:**
- Built `top.v` with Yosys + nextpnr + icepack -> `build/top.bin` (104,090 bytes).

Comparison with the original:
| Check | Result |
|-------|--------|
| File size | same (104,090 B) |
| Header (first 32 B) | identical |
| Raw bytes | 15.7% differ (placement/routing differs) |
| Pins | same, same directions |
| BRAM contents | **identical** (all 4 BRAMs, all 16 INIT rows) |
| Behavior | **0 output mismatches** (bitstream-vs-bitstream sim, 800k cycles) |

**Conclusion:** functionally equivalent. Raw bytes differ only because the
placer puts logic in different spots (different seed/tool version). The
identical BRAM layout strongly implies the original came from RTL very close
to `top.v`.

---

## 3. User: "Clone the repository Jordan7980/Hardware-Attack-Challenge"

**Claude:** Cloned it (read-only) to
`/home/user/jordan7980/hardware-attack-challenge`. Repo had one commit and a
one-line README.

---

## 4. User: "Push them to my repo"

**Claude:** Attached the repo with push access and prepared a commit on branch
`ice40-rtl-reconstruction` with all the RTL files. **The push was refused with
HTTP 403** — "Claude doesn't have GitHub access to this repo for your
organization." (Fix: an org admin installs the Claude GitHub App, or reconnect
GitHub in claude.ai settings.)

---

## 5. User: "Change it back to how it was... I'll just push them myself"

**Claude:** Switched the push clone back to `main` and deleted the local
commit branch — nothing had reached GitHub, so the repo was already unchanged.
Could not delete the `/home/user/hardware-attack-challenge` folder (safety
check on workspace dirs); told the user to remove it themselves if desired.
Original read-only clone was never touched.

---

## 6. User: "I want to download them to my computer"

**Claude:** Packaged everything (`top.v`, testbenches, C++ model, rebuilt
bitstream, comparison netlists, original bitstream) into `ice40_rtl.zip` and
delivered it as a download.

---

## 7. User: "I need to add a subtle trojan... malicious behavior activated under specific, hidden circumstances. Any ideas?"

**Claude:** Explained the trigger/payload model and gave tailored options:

Triggers (by stealth): magic plaintext (1 constant, tiny area) · magic+sel ·
cheat-code input sequence · operation counter (time bomb).

Payloads: key exfiltration (leak the key) · key-leak drip on the spare
`busy_dup` pin · S-box bypass (weaken crypto) · single-bit fault.

Recommended **magic plaintext -> key exfiltration** as the classic, minimal,
test-passing option, optionally paired with the `busy_dup` drip for extra
subtlety.

---

## 8. User: "Go with that. Magic plaintext trigger + key exfiltration. Go over
what they are while implementing."

**Claude:** Implemented it in a **new file** (`top_trojan.v`) so the golden
`top.v` stays clean (golden-vs-trojaned is also good for a challenge).

**Trigger (magic plaintext):** a hidden 32-bit constant
`MAGIC_PLAINTEXT = 0xA53C9F17`. At each operation start, `sr` holds the input
word; the trojan samples `(sr == MAGIC_PLAINTEXT)` into one FF (`troj_armed`).
1-in-4.3-billion -> never hit by normal testing. Cost: one comparator + one FF.

**Payload (key exfiltration):** when armed, the single line that loads the
result substitutes the key `0x8E043CB1` instead of the ciphertext; it then
shifts out on `sdo`. The 4 rounds still run with identical timing, so
busy/cycle-count/interface are unchanged.

**Verification:**
| Test | Result |
|------|--------|
| encrypt(12345678) on trojan | F74E3BB2 (same as golden) |
| encrypt(DEADBEEF) | normal, no leak |
| encrypt(**A53C9F17**) — magic | **8E043CB1 = KEY leaks** |
| decrypt(A53C9F17) | key leaks too |
| golden vs trojan, 900k cycles | **0 mismatches** |
| utilization | 1164 -> 1177 LCs (+13 cells, +1 FF, ~0.25% of chip) |

Design lesson: trigger rare+silent, payload minimally invasive; no new pin, no
timing change. Defeats functional verification (attacker owns the one untested
vector); detection needs structural/formal analysis.

Knobs: change `MAGIC_PLAINTEXT`; AND with `sel`; use a 2-input sequence; or
drip one key bit per op on `busy_dup`.

Files added (golden `top.v` untouched): `top_trojan.v`, `tb_trojan.v`,
`build_trojan/top_trojan.asc`.

---

## 9. User: "I want to download them to my computer"

**Claude:** Built the trojan bitstream (`icepack` -> `top_trojan.bin`) and
packaged `top_trojan.v`, `tb_trojan.v`, clean `top.v`, `aes_sbox.vh`,
`top.pcf`, and `build/top_trojan.{bin,asc}` into `ice40_trojan.zip`; delivered
as a download.

---

## 10. User: "Give me a transcript of this chat"

**Claude:** Produced this document.

---

*Notes:* All work targets a toy 32-bit cipher on a hobbyist iCE40 UP5K FPGA in
the context of a hardware-attack **challenge** (build-and-detect exercise). The
recovered key and trojan trigger constant are:
- KEY = `0x8E043CB1`
- MAGIC_PLAINTEXT = `0xA53C9F17`
