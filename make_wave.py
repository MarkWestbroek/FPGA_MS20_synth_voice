# ============================================================================
# make_wave.py — Converteert DSim simulatie-output naar WAV-bestanden
#
# Ondersteunt: 1 kolom (KS string), 2 kolommen (CSV), 3 kolommen (CSV)
# Genereert: ks_string_output.wav + ms20_filter_output.wav (indien beschikbaar)
# ============================================================================

import wave, struct, os

SIM_FILE = "simulation_output.txt"
col1_data = []
col2_data = []

if not os.path.exists(SIM_FILE):
    print(f"Fout: {SIM_FILE} bestaat niet! Draai eerst de DSim-simulatie.")
    exit()

print(f"Bestand '{SIM_FILE}' lezen...")

for encoding in ["utf-16", "utf-8-sig", "utf-8"]:
    try:
        with open(SIM_FILE, "r", encoding=encoding, errors="ignore") as f:
            lines = f.readlines()
        if not lines: continue

        for line in lines:
            s = line.strip()
            if not s: continue
            test = s.replace('-','').replace(',','').replace(' ','')
            if any(c.isalpha() for c in test): continue

            parts = [p.strip() for p in s.split(",")]
            try:
                if len(parts) == 1:
                    col1_data.append(int(parts[0]))
                elif len(parts) == 2:
                    col1_data.append(int(parts[0]))
                    col2_data.append(int(parts[1]))
                elif len(parts) >= 3:
                    col1_data.append(int(parts[1]))
                    col2_data.append(int(parts[2]))
            except ValueError: continue

        if col1_data:
            print(f"  {encoding}: {len(col1_data)} kolom-1, {len(col2_data)} kolom-2 samples")
            break
    except UnicodeDecodeError:
        print(f"  {encoding}: decodeerfout...")

if not col1_data:
    print("Fout: Geen audiodata!"); exit()

Q = 1048576.0

def to_wav(data, name, desc):
    if not data: return
    f = [float(x)/Q for x in data]
    avg = sum(f)/len(f); c = [x-avg for x in f]
    peak = max(abs(x) for x in c) or 1.0
    s16 = [int((x/peak)*32767) for x in c]
    with wave.open(name,"w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
        w.writeframes(struct.pack(f"{len(s16)}h",*s16))
    print(f"  ✓ {name} — {len(s16)} samples ({len(s16)/48000:.1f}s) — {desc}")

to_wav(col1_data, "ks_string_output.wav", "Karplus-Strong droge klank")
to_wav(col2_data, "ms20_filter_output.wav", "MS-20 gefilterd")

print("\nKlaar!")
# 4. Schrijf WAV-bestanden
# ---------------------------------------------------------------------------
SAMPLE_RATE = 48000

def write_wav(filename, samples):
    """Schrijf 16-bit mono WAV."""
    with wave.open(filename, "w") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
print("\nKlaar!")