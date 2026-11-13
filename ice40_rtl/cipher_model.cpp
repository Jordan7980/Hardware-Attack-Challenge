//==========================================================================
//==========================================================================
// cipher_model.cpp - C++ reference model of the cipher recovered from
//                    ice40_bitstream.bin (see top.v)
//
// Build:  g++ -O2 -o cipher_model cipher_model.cpp
// Usage:  ./cipher_model <hex32>      -> prints encrypt / decrypt of value
//==========================================================================
//==========================================================================
#include <cstdint>
#include <cstdio>
#include <cstdlib>

//==========================================================================
// Build the AES S-box from its math definition (GF(2^8) inverse + affine)
// instead of pasting 256 numbers.
//==========================================================================
static uint8_t SBOX[256];
static uint8_t INV_SBOX[256];

static uint8_t gf_mul(uint8_t a, uint8_t b)
{
    uint8_t r = 0;
    while (b) {
        if (b & 1) r ^= a;
        a = (uint8_t)((a << 1) ^ ((a & 0x80) ? 0x1B : 0x00));
        b >>= 1;
    }
    return r;
}

static void build_sbox()
{
    for (int x = 0; x < 256; x++) {
        uint8_t inv = 0;
        for (int y = 1; y < 256 && x != 0; y++) {
            if (gf_mul((uint8_t)x, (uint8_t)y) == 1) { inv = (uint8_t)y; break; }
        }
        uint8_t s = inv;
        for (int i = 1; i <= 4; i++) s ^= (uint8_t)((inv << i) | (inv >> (8 - i)));
        SBOX[x] = s ^ 0x63;
    }
    for (int x = 0; x < 256; x++) INV_SBOX[SBOX[x]] = (uint8_t)x;
}

//==========================================================================
// Hard-coded key found in the bitstream (byte0..byte3)
//==========================================================================
static const uint8_t KEY[4] = { 0xB1, 0x3C, 0x04, 0x8E };

static uint8_t get_byte(uint32_t w, int k)            { return (uint8_t)(w >> (8 * k)); }
static uint32_t put_byte(uint32_t w, int k, uint8_t b) { return (w & ~(0xFFu << (8 * k))) | ((uint32_t)b << (8 * k)); }

//==========================================================================
// One encrypt round: out[k+1] = SBOX(in[k] ^ KEY[k])
//==========================================================================
static uint32_t enc_round(uint32_t in)
{
    uint32_t out = 0;
    for (int k = 0; k < 4; k++) {
        out = put_byte(out, (k + 1) % 4, SBOX[get_byte(in, k) ^ KEY[k]]);
    }
    return out;
}

//==========================================================================
// One decrypt round: out[k] = INV_SBOX(in[k+1]) ^ KEY[k]
//==========================================================================
static uint32_t dec_round(uint32_t in)
{
    uint32_t out = 0;
    for (int k = 0; k < 4; k++) {
        out = put_byte(out, k, INV_SBOX[get_byte(in, (k + 1) % 4)] ^ KEY[k]);
    }
    return out;
}

// The hardware always runs 4 rounds per start pulse
static uint32_t encrypt(uint32_t x) { for (int r = 0; r < 4; r++) x = enc_round(x); return x; }
static uint32_t decrypt(uint32_t x) { for (int r = 0; r < 4; r++) x = dec_round(x); return x; }

int main(int argc, char **argv)
{
    build_sbox();

    uint32_t pt = (argc > 1) ? (uint32_t)strtoul(argv[1], nullptr, 16) : 0x12345678u;
    uint32_t ct = encrypt(pt);

    printf("input    = %08X\n", pt);
    printf("encrypt  = %08X\n", ct);
    printf("decrypt  = %08X\n", decrypt(pt));
    printf("roundtrip decrypt(encrypt(input)) = %08X  %s\n",
           decrypt(ct), decrypt(ct) == pt ? "OK" : "FAIL");
    return 0;
}
//==========================================================================
//==========================================================================
