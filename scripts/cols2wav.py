# ============================================================================
# cols2wav.py — generieke "kolommen → WAV"-renderer voor testbench-output
#
#   python scripts/cols2wav.py <sim_output.txt> <prefix> [naam1 naam2 ...]
#
# Pakt alle regels "int, int, ..." uit het bestand en schrijft per kolom
# wav/<prefix>_<naamN>.wav (48 kHz, mono, 16-bit; Q12.20 → genormaliseerd).
# ============================================================================
import wave, struct, os, sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

if len(sys.argv) < 3:
    print("gebruik: cols2wav.py <simfile> <prefix> [kolomnamen...]")
    sys.exit(1)

sim_file, prefix = sys.argv[1], sys.argv[2]
names = sys.argv[3:]

cols = []
with open(sim_file, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        s = line.strip()
        if not s or any(c.isalpha() for c in s.replace(",", " ")):
            continue
        parts = [p.strip() for p in s.split(",") if p.strip()]
        try:
            vals = [int(p) for p in parts]
        except ValueError:
            continue
        while len(cols) < len(vals):
            cols.append([])
        for i, v in enumerate(vals):
            cols[i].append(v)

if not cols or not cols[0]:
    print("Geen data gevonden!"); sys.exit(1)

Q = 1048576.0
os.makedirs("wav", exist_ok=True)
for i, data in enumerate(cols):
    name = names[i] if i < len(names) else f"col{i+1}"
    path = os.path.join("wav", f"{prefix}_{name}.wav")
    f = [x / Q for x in data]
    avg = sum(f) / len(f)
    c = [x - avg for x in f]
    peak = max(abs(x) for x in c) or 1.0
    s16 = [int((x / peak) * 32767) for x in c]
    with wave.open(path, "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
        w.writeframes(struct.pack(f"{len(s16)}h", *s16))
    print(f"  ok {path} - {len(s16)} samples ({len(s16)/48000:.1f}s)")
