import wave
import struct
import os

# 1. Lees de getallen uit het tekstbestand met de juiste UTF-16 codering
raw_data = []

if not os.path.exists("simulation_output.txt"):
    print("Fout: simulation_output.txt bestaat niet!")
    exit()

print("Bestand scannen (UTF-16 modus)...")

with open("simulation_output.txt", "r", encoding="utf-16", errors="ignore") as f:
    for line in f:
        cleaned = line.strip()
        if not cleaned:
            continue
        if cleaned.lstrip('-').isdigit():
            raw_data.append(int(cleaned))

print(f"Aantal gevonden audiopunten: {len(raw_data)}")

if not raw_data:
    print("Fout: Nog steeds geen getallen gevonden. Probeer de UTF-8 variant...")
    with open("simulation_output.txt", "r", encoding="utf-8-sig", errors="ignore") as f:
        for line in f:
            cleaned = line.strip()
            if cleaned.lstrip('-').isdigit():
                raw_data.append(int(cleaned))
    print(f"Als herpoging met UTF-8-sig: {len(raw_data)} punten.")

if not raw_data:
    exit()

# 2. Converteer van Q12.20 naar normale amplitudes
# Omdat we nu 20 bits achter de komma hebben, delen we door 2^20 = 1048576.0
audio_floats = [float(x) / 1048576.0 for x in raw_data]

# Verwijder eventuele DC-offset (het gemiddelde) zodat de golfvorm mooi rond de 0 centreert
avg = sum(audio_floats) / len(audio_floats)
audio_floats = [x - avg for x in audio_floats]

# Normaliseer naar het volledige 16-bit bereik
max_val = max(abs(x) for x in audio_floats)
if max_val == 0:
    max_val = 1

scaled_data = []
for x in audio_floats:
    normalized = x / max_val
    int16_val = int(normalized * 32767)
    scaled_data.append(int16_val)

# 3. Schrijf weg als 16-bit WAV (48 kHz)
sample_rate = 48000
num_channels = 1  # Mono
sample_width = 2   # 16-bit

with wave.open("mass_spring_output.wav", "w") as wav_file:
    wav_file.setnchannels(num_channels)
    wav_file.setsampwidth(sample_width)
    wav_file.setframerate(sample_rate)
    
    binary_data = struct.pack(f"{len(scaled_data)}h", *scaled_data)
    wav_file.writeframes(binary_data)

print("\nGefeliciteerd! mass_spring_output.wav is succesvol aangemaakt voor Q12.20!")