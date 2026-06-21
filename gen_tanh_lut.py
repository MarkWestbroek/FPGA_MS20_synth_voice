#!/usr/bin/env python3
# ============================================================================
# gen_tanh_lut.py — Genereert tanh lookup table voor de MS-20 filter BRAM
#
# Output: tanh_table.hex — 1024 entries, Q12.20 signed 32-bit hex
#
# De tabel mapt bp-waarden (Q12.20, bereik -4.0 .. +4.0) naar tanh(bp).
# Dit wordt in de Gowin BSRAM geladen voor de diode-saturatie.
#
# Gebruik: python gen_tanh_lut.py
# ============================================================================

import math

ENTRIES = 1024
BP_MIN = -4.0      # tanh(-4) ≈ -0.9993
BP_MAX = +4.0      # tanh(+4) ≈ +0.9993
Q_SCALE = 2**20    # Q12.20: 20 fractionele bits

def q12_20(x):
    """Converteer float naar Q12.20 signed 32-bit integer"""
    val = round(x * Q_SCALE)
    # Clamp naar 32-bit signed bereik
    if val > 0x7FFFFFFF:
        val = 0x7FFFFFFF
    elif val < -0x80000000:
        val = -0x80000000
    return val

def to_hex(val):
    """Converteer signed int naar 32-bit hex string"""
    if val < 0:
        val = val & 0xFFFFFFFF  # Two's complement voor negatief
    return f"{val:08X}"

print(f"Genereer tanh LUT: {ENTRIES} entries, bereik [{BP_MIN}, {BP_MAX}]")
print(f"Output: tanh_table.hex\n")

with open("tanh_table.hex", "w") as f:
    for i in range(ENTRIES):
        # i=0 → bp=BP_MIN, i=1023 → bp=BP_MAX
        bp = BP_MIN + (BP_MAX - BP_MIN) * i / (ENTRIES - 1)
        tanh_val = math.tanh(bp)
        qval = q12_20(tanh_val)
        f.write(to_hex(qval) + "\n")

# Print enkele voorbeeldwaarden
print("Voorbeeldwaarden:")
for i in [0, 128, 256, 384, 511, 512, 640, 768, 896, 1023]:
    bp = BP_MIN + (BP_MAX - BP_MIN) * i / (ENTRIES - 1)
    tanh_val = math.tanh(bp)
    qval = q12_20(tanh_val)
    print(f"  [{i:4d}] bp={bp:+7.4f}  tanh={tanh_val:+8.6f}  Q12.20=0x{to_hex(qval)}")

print(f"\n✓ tanh_table.hex gegenereerd ({ENTRIES} entries)")
print(f"  BSRAM verbruik: {ENTRIES} × 32 bit = {ENTRIES*32} bit = {ENTRIES*32/1024:.0f} Kbit (2 Gowin BSRAM blokken)")
