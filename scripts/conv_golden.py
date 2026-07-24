# ============================================================================
# conv_golden.py — golden model voor de convolution reverb (Fase D+)
#
# Simuleert de gepartitioneerde overlap-save-architectuur uit
# doc/CONV_REVERB_DESIGN.md, inclusief de fixed-point-kwantisatie die de
# RTL straks krijgt (18-bit spectra, block-floating-point FFT benaderd via
# per-blok normalisatie, 48-bit accumulator). Vergelijkt tegen float-numpy.
#
#   python scripts/conv_golden.py [pad/naar/ir.wav]
#
# Zonder argument: synthetische IR (exponentieel uitstervende ruis, 2 s).
# Rapporteert SNR van het gekwantiseerde pad t.o.v. float en schrijft
# wav/conv_golden_wet.wav ter beluistering.
# ============================================================================
import sys, os, wave, struct
import numpy as np

B = 1024                  # bloklengte
N = 2 * B                 # FFT-lengte
SPEC_BITS = 18            # spectrum-kwantisatie (re/im)
FS = 48000

def read_wav_mono(path):
    with wave.open(path, "rb") as w:
        n, ch, sw = w.getnframes(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(n)
        if sw == 2:
            x = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
        elif sw == 4:
            x = np.frombuffer(raw, dtype="<i4").astype(np.float64) / 2**31
        else:
            raise SystemExit(f"sample-width {sw} niet ondersteund")
        if ch > 1:
            x = x.reshape(-1, ch).mean(axis=1)
        return x

def write_wav(path, x):
    x = x / (np.max(np.abs(x)) or 1.0)
    s16 = (x * 32767).astype("<i2")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(FS)
        w.writeframes(s16.tobytes())

def quant_spec(X, bits=SPEC_BITS):
    """Kwantiseer een complex spectrum naar 'bits' per component met een
    gedeelde blok-exponent (block-floating-point zoals de RTL)."""
    m = np.max(np.abs(np.concatenate([X.real, X.imag]))) or 1.0
    exp = np.ceil(np.log2(m))
    scale = 2.0 ** (bits - 1) / 2.0 ** exp
    q = (np.round(X.real * scale) + 1j * np.round(X.imag * scale))
    return q, 1.0 / scale

def partitioned_overlap_save(x, h, quantized=True):
    """FDL uniform gepartitioneerde overlap-save; optioneel gekwantiseerd."""
    P = int(np.ceil(len(h) / B))
    h_pad = np.zeros(P * B); h_pad[:len(h)] = h
    # IR-spectra (eenmalig, zoals de IR-upload straks doet)
    H = []
    for p in range(P):
        Hp = np.fft.rfft(np.concatenate([h_pad[p*B:(p+1)*B], np.zeros(B)]))
        if quantized:
            Hq, Hs = quant_spec(Hp)
            H.append((Hq, Hs))
        else:
            H.append((Hp, 1.0))

    nblk = int(np.ceil(len(x) / B)) + P
    x_pad = np.zeros(nblk * B); x_pad[:len(x)] = x
    fdl = [None] * P                       # jongste eerst
    out = np.zeros(nblk * B)
    prev = np.zeros(B)
    for b in range(nblk):
        blk = x_pad[b*B:(b+1)*B]
        X = np.fft.rfft(np.concatenate([prev, blk]))   # overlap-save venster
        prev = blk
        if quantized:
            Xq, Xs = quant_spec(X)
            fdl = [(Xq, Xs)] + fdl[:-1]
        else:
            fdl = [(X, 1.0)] + fdl[:-1]
        acc = np.zeros(B + 1, dtype=complex)
        for p in range(P):
            if fdl[p] is None: continue
            (Xp, Xs), (Hp, Hs) = fdl[p], H[p]
            # 48-bit accumulator: producten zijn (18b×18b)=36b, 94 sommaties
            # → past zonder verdere kwantisatie; alleen de schalen komen terug
            acc += (Xp * Hp) * (Xs * Hs)
        y = np.fft.irfft(acc)[B:]          # tweede helft is geldig
        out[b*B:(b+1)*B] = y
    return out

def main():
    if len(sys.argv) > 1:
        h = read_wav_mono(sys.argv[1])
        print(f"IR: {sys.argv[1]} ({len(h)/FS:.2f} s, {len(h)} samples)")
    else:
        rng = np.random.default_rng(20260724)
        t = np.arange(int(2.0 * FS))
        h = rng.standard_normal(len(t)) * np.exp(-3.0 * t / FS)
        h[:64] = 0; h[0] = 0.0            # kleine predelay
        h *= 0.25 / np.max(np.abs(h))
        print(f"IR: synthetisch, 2,0 s exponentieel uitstervende ruis")

    # testsignaal: impuls + korte A1-burst
    x = np.zeros(int(3.5 * FS))
    x[4800] = 1.0
    n0 = int(1.5 * FS)
    tt = np.arange(int(0.4 * FS))
    x[n0:n0+len(tt)] = 0.5 * np.sign(np.sin(2*np.pi*55*tt/FS)) * (1 - tt/len(tt))

    ref = np.convolve(x, h)[:len(x)]                       # float-referentie
    got_f = partitioned_overlap_save(x, h, quantized=False)[:len(x)]
    got_q = partitioned_overlap_save(x, h, quantized=True)[:len(x)]

    err_f = ref - got_f
    err_q = ref - got_q
    snr_f = 10*np.log10(np.sum(ref**2) / (np.sum(err_f**2) or 1e-30))
    snr_q = 10*np.log10(np.sum(ref**2) / (np.sum(err_q**2) or 1e-30))
    P = int(np.ceil(len(h) / B))
    print(f"partities: {P}  blok: {B}  FFT: {N}")
    print(f"algoritme-check  (float)      : SNR {snr_f:6.1f} dB  (moet ~machineprecisie zijn)")
    print(f"gekwantiseerd 18b (RTL-model) : SNR {snr_q:6.1f} dB  (doel: > 80 dB)")
    ok = snr_f > 120 and snr_q > 80
    print("PASS" if ok else "FAIL")

    write_wav("wav/conv_golden_wet.wav", got_q)
    print("  ok wav/conv_golden_wet.wav")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
