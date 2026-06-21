# ============================================================================
# gen_tables.py — Genereert lookup-tabellen voor het MS-20 filter
#
# Output:
#   src/tanh_table.hex   — 1024 entries, Q12.20, tanh() soft-clip voor de
#                          resonantie-feedback (de MS-20 "scream").
#
# Print ook de prewarped g-constanten (tan(pi*fc/fs)) voor de cutoff-envelope,
# berekend op de INTERNE (oversampled) sample-rate.
#
# Q12.20 fixed-point: waarde * 2^20, opgeslagen als signed 32-bit.
#
# ── Adressering van tanh_table.hex (MOET matchen met tanh_lut.v) ────────────
#   Domein:  x in [-X_MAX, +X_MAX]  met X_MAX = 4.0
#   N = 1024 entries, stap = 2*X_MAX / N = 8/1024 = 1/128
#   addr = floor((x + X_MAX) * (N / (2*X_MAX)))      met clamp naar [0, N-1]
#        = floor((x + 4.0) * 128)
#   In Q12.20 (x als 32-bit signed):
#        addr = (x + 0x00400000) >>> 13      (want 4.0 = 0x00400000, *128 = <<7,
#                                             >>20 om uit Q12.20 te halen => >>13)
#   entry[addr] = round( tanh(x) * 2^20 )
# ============================================================================

import math

Q = 1 << 20            # Q12.20 schaal
N = 1024               # aantal entries
X_MAX = 4.0            # tanh-domein: [-4, +4]

# tanh_lut.v leest "tanh_table.hex" relatief t.o.v. de project-root (sim-cwd
# en Gowin-projectdir). Houd dat de enige bron.
OUT_HEX = "tanh_table.hex"


def q1220(x):
    """Float -> signed 32-bit Q12.20, als 8-hex (two's complement)."""
    v = int(round(x * Q))
    # clamp op signed 32-bit
    v = max(-(1 << 31), min((1 << 31) - 1, v))
    return v & 0xFFFFFFFF


def gen_tanh():
    lines = []
    step = (2.0 * X_MAX) / N
    for i in range(N):
        x = -X_MAX + i * step
        y = math.tanh(x)
        lines.append(f"{q1220(y):08X}")
    with open(OUT_HEX, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"  geschreven: {OUT_HEX}  ({N} entries, Q12.20, tanh op [-{X_MAX},+{X_MAX}])")


def print_g_constants(fs):
    """Chamberlin SVF cutoff-coefficient g = 2*sin(pi*fc/fs) in Q12.20.

    Dit is de exacte Chamberlin-coefficient (de oude code gebruikte de
    small-angle benadering 2*pi*fc/fs). Voor de cutoff-envelope in synth_top.
    """
    print(f"\n  Chamberlin g-constanten  (g = 2*sin(pi*fc/fs), fs = {fs} Hz):")
    for fc in (200, 400, 800, 1500, 3000, 5000):
        g = 2.0 * math.sin(math.pi * fc / fs)
        print(f"    fc={fc:5d} Hz  ->  g = {g:.6f}  ->  Q12.20 = 0x{q1220(g):08X}")


if __name__ == "__main__":
    print("Tabellen genereren...")
    gen_tanh()
    # Filter draait intern op 2x oversampling => 96 kHz.
    print_g_constants(96000)
    print("\nKlaar!")
