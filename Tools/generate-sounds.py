#!/usr/bin/env python3
"""Generates Yap's default sound cues from scratch: soft wooden taps.

Each cue is a short sequence of taps, a sine with a quick attack, an
exponential decay, a slight downward glide and a touch of second harmonic.
Start rises (a quiet pickup, then the main tap), stop falls, and the
hands-free lock is two taps stepping down.

    python3 Tools/generate-sounds.py

Writes Sources/Resources/DefaultSounds/yap-{start,stop,lock}.wav. Standard
library only.
"""

import math
import struct
import wave
from pathlib import Path

RATE = 44_100
PEAK = 0.16  # about -16 dBFS: present, never loud
OUT = Path(__file__).resolve().parent.parent / "Sources" / "Resources" / "DefaultSounds"


def tap(freq, at, gain=1.0, decay=0.028, glide=0.05):
    """One tap starting `at` seconds in."""
    return (freq, at, gain, decay, glide)


def render(taps, length):
    samples = [0.0] * int(RATE * length)
    for freq, at, gain, decay, glide in taps:
        start = int(RATE * at)
        phase = 0.0
        for n in range(start, len(samples)):
            t = (n - start) / RATE
            attack = min(1.0, t / 0.002)
            envelope = attack * math.exp(-t / decay)
            if envelope < 1e-4 and t > 0.01:
                break
            # The pitch sags a little as the tap rings out, like struck wood.
            f = freq * (1 - glide * (1 - math.exp(-t / 0.03)))
            phase += 2 * math.pi * f / RATE
            tone = math.sin(phase) + 0.18 * math.sin(2 * phase)
            samples[n] += gain * envelope * tone

    # Fade the tail so the file ends on silence, then normalize.
    fade = int(RATE * 0.02)
    for i in range(fade):
        samples[-1 - i] *= i / fade
    top = max(abs(s) for s in samples) or 1.0
    return [s / top * PEAK for s in samples]


def write(name, samples):
    OUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT / name), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        for s in samples:
            v = struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767))
            frames += v + v
        w.writeframes(bytes(frames))


CUES = {
    # A quiet low pickup, then the main tap a fifth-ish above.
    "yap-start.wav": ([tap(330, 0.0, gain=0.22, decay=0.007), tap(494, 0.022, decay=0.013)], 0.19),
    # The mirror image: a quiet high pickup, then the main tap below.
    "yap-stop.wav": ([tap(494, 0.0, gain=0.18, decay=0.006), tap(330, 0.035, decay=0.016)], 0.22),
    # Two taps stepping down, softer: "locked in".
    "yap-lock.wav": ([tap(466, 0.0, gain=0.85, decay=0.009), tap(277, 0.058, gain=0.75, decay=0.012)], 0.17),
}

if __name__ == "__main__":
    for name, (taps, length) in CUES.items():
        write(name, render(taps, length))
        print(f"wrote {OUT / name}")
