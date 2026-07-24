# FPGA voice

An eight-voice physical-modeling instrument in an FPGA (Sipeed Tang Primer
20K, Gowin GW2A-18), attached to Cortex as an SPI-slave instrument. The
brain does MIDI-in and voice allocation and sends per-voice pitch CV, gate
and filter CV over the frame bus; the FPGA turns them into sound and plays
it out of the dock's stereo DAC.

## Voice architecture

Each of the eight voices is a Karplus-Strong string — a delay line with a
damped feedback loop — excited by a morphing wavetable instead of plain
noise. The exciter tables blend under CV control, which shifts the pluck
from soft mallet to glassy attack. All eight voices are time-multiplexed
through one shared datapath at 48 kHz, in Q12.20 fixed point.

## MS-20-style filter

The filter is a Chamberlin state-variable core with the MS-20's character
bolted on: a tanh lookup table saturates the resonance feedback the way the
original's diode clipper does, a drive parameter pushes the input into that
same curve, and the core runs at 2x oversampling to keep aliasing down.
Cutoff, resonance and drive are all per-voice CV targets. A four-level wah
mode sweeps the filter for expression work.

## Cortex integration

The module speaks the standard frame protocol (framed SPI with CRC-16,
CvSet/GateSet opcodes) as a type-1 pitch module: pitch arrives as plain
1 V/oct-style CV code, not as MIDI notes, so the FPGA is interchangeable
with an analog oscillator bank from the allocator's point of view. Slots
are grouped in blocks of eight per parameter — pitch, gate, cutoff,
resonance, drive, exciter morph — one slot per voice.

## Hardware

Runs on the Sipeed Tang Primer 20K (27 MHz clock, GW2A-LV18 with 828 Kb
block RAM and 48 multipliers) sitting on its dock, which provides the
PT8211 stereo DAC and 3.5 mm jack. The design uses 13% of the logic and
half the multipliers; the wavetables fill 81% of the block RAM, which is
the resource that decides what fits.

## Next

A port to a Spartan-7 board (Arty S7-50) is in progress for the bigger
version: 16+ voices, an FDN reverb and a DDR3-backed tape echo, with the
Tang Primer staying on as the compact voice card.
