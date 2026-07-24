# ============================================================================
# fft_check.py — vergelijkt de fft2048-dumps met numpy
#
#   1. draai de testbench (schrijft fft_fwd_out.txt / fft_inv_out.txt)
#   2. python scripts/fft_check.py
#
# Checks:
#   * forward vs numpy.fft.fft  : SNR > 75 dB
#   * roundtrip (inv(fwd)/2048) : SNR > 70 dB t.o.v. de input
# ============================================================================
import sys
import numpy as np

def read_vec_hex(path):
    xs = []
    for line in open(path):
        v = int(line.strip(), 16)
        re = v >> 18; im = v & 0x3FFFF
        if re >= 1 << 17: re -= 1 << 18
        if im >= 1 << 17: im -= 1 << 18
        xs.append(complex(re, im))
    return np.array(xs)

def read_dump(path):
    lines = open(path).read().split()
    exp = int(lines[0])
    vals = np.array([int(v) for v in lines[1:]], dtype=np.float64)
    return exp, vals[0::2] + 1j * vals[1::2]

def snr(ref, got):
    err = ref - got
    return 10 * np.log10(np.sum(np.abs(ref) ** 2) /
                         (np.sum(np.abs(err) ** 2) or 1e-30))

x = read_vec_hex("fft_test_in.hex")

exp_f, F = read_dump("fft_fwd_out.txt")
got_fwd = F * (2.0 ** exp_f)
ref_fwd = np.fft.fft(x)
s1 = snr(ref_fwd, got_fwd)
print(f"forward : exp={exp_f:2d}  SNR vs numpy = {s1:6.1f} dB  (doel > 75)")

exp_i, I = read_dump("fft_inv_out.txt")
# inverse is ongenormaliseerd: /2048; exponenten van beide passes tellen op
got_rt = I * (2.0 ** (exp_f + exp_i)) / 2048.0
s2 = snr(x, got_rt)
print(f"roundtrip: exp={exp_i:2d}  SNR vs input = {s2:6.1f} dB  (doel > 70)")

ok = s1 > 75 and s2 > 70
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
