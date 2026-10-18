import argparse
import math
import random
import struct
import wave
from pathlib import Path

# synthesize a tiny broadband detent instead of a pitched notification tone
rate = 48000
rng = random.Random(42)
bands = [(2000, 4000, .014), (4000, 6000, .073), (6000, 8000, .085),
         (8000, 12000, .599), (12000, 16000, .179), (16000, 22000, .037)]
partials = []
for low, high, energy in bands:
    for _ in range(48):
        partials.append((rng.uniform(low, high), rng.uniform(0, 2 * math.pi), math.sqrt(energy / 48)))

# keep the transient compact, with a rounded attack and a nearly silent tail
samples = []
for i in range(528):
    t = i / rate
    burst = math.exp(-.5 * ((t - .0023) / .00068) ** 2)
    tail = .035 * math.exp(-t / .0022)
    edge = min(1, t / .0003) * min(1, (.011 - t) / .001)
    noise = sum(weight * math.cos(2 * math.pi * frequency * t + phase) for frequency, phase, weight in partials)
    samples.append(noise * (burst + tail) * edge)
peak = max(abs(value) for value in samples)
samples = [value * .27 / peak for value in samples]
# regenerate the bundled asset or a spaced preview without requiring any external recordings
parser = argparse.ArgumentParser(description="Render Fileel's original wheel selection tick")
parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "Fileel" / "WheelTick.wav")
parser.add_argument("--preview", action="store_true")
args = parser.parse_args()
values = sum((samples + [0] * 9600 for _ in range(6)), []) if args.preview else samples
with wave.open(str(args.output), 'wb') as output:
    output.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
    output.writeframes(b''.join(struct.pack('<h', round(value * 32767)) for value in values))
