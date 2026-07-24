# ============================================================================
# gen_fft_tables.py — tabellen voor fft2048.v
#
#   python scripts/gen_fft_tables.py
#
# Schrijft (repo-root, naast de andere hex-bestanden):
#   fft_twiddle.hex  — 1024 × 36 bit: {cos[17:0], sin[17:0]}, Q1.17
#                      (W_2048^k voor k=0..1023; de FFT negeert sin-teken
#                      zelf voor forward/inverse)
#   fft_test_in.hex  — 2048 × 36 bit: {re[17:0], im[17:0]} testvector
#                      (vaste seed; fft_check.py leest dezelfde file)
# ============================================================================
import math, random

AMP17 = (1 << 17) - 1          # 1.0 in Q1.17

def to18(x):
    return x & 0x3FFFF

with open("fft_twiddle.hex", "w") as f:
    for k in range(1024):
        ang = 2.0 * math.pi * k / 2048.0
        c = round(math.cos(ang) * AMP17)
        s = round(math.sin(ang) * AMP17)
        f.write(f"{(to18(c) << 18) | to18(s):09x}\n")
print("  ok fft_twiddle.hex (1024 entries)")

rng = random.Random(20260724)
with open("fft_test_in.hex", "w") as f:
    for n in range(2048):
        re = rng.randint(-30000, 30000)
        im = rng.randint(-30000, 30000)
        f.write(f"{(to18(re) << 18) | to18(im):09x}\n")
print("  ok fft_test_in.hex (2048 entries)")
