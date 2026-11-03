"""The audio stream is labelled with the rate its samples are captured at,
the device's, when the project asks for a rate the device doesn't run at.

REAPER runs on JACK at 48 kHz with one fed input (`jack-inputs`), and opens
a project set to 44.1 kHz (Project Settings, "Project sample rate"). JACK
can't change rate, so REAPER keeps running at 48 kHz, and so does its audio
hook. The phone builds its player at the rate `audio/startStream` reports
and replays frames at it; told 44100 for 48 kHz samples, it plays them
about 1.5 semitones flat and 8 % slow, and falls further behind the longer
it listens.

- Preconditions: the project asks for 44100, the device runs at 48000, and
  the audio hook sees 48000.
- `audio/startStream` and the project event's `sampleRate` (which the
  phone restarts its player on) say 48000.
- Measured from the stream: as many sample frames arrive per second as the
  reported rate says, within 4 %; and a 1 kHz tone fed to input 1 decodes,
  at the reported rate, at the fed frequency within 0.5 %.
"""
import math
import struct
import time

from reamo_client import Client, open_project, reaper, skip_unless_linux

skip_unless_linux("REAPER's inputs come from the container's JACK server")

from jack_feeder import Feeder  # noqa: E402  after the skip: Linux only

PROJECT = "/tmp/srate/asks-44100.RPP"
DEVICE_RATE = 48000  # boot.sh starts jackd at -r 48000
TONE_HZ = 1000.0


def rates():
    r = reaper('return {tonumber(select(2, reaper.GetAudioDeviceInfo("SRATE", ""))) or 0, '
               'reaper.GetSetProjectInfo(0, "PROJECT_SRATE_USE", 0, false), '
               'reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)}')
    return {"device": int(r[0]), "project_use": int(r[1]), "project": int(r[2])}


def stream_measure(frames, rate):
    """Sample frames in all, and the tone's frequency on the left channel as
    decoded at `rate`: positive-going zero crossings, interpolated, counted
    within each frame so a dropped frame between two can't skew it."""
    pairs = 0
    cycles = 0
    span = 0.0
    for f in frames:
        pcm = struct.unpack(f"<{(len(f) - 5) // 2}h", f[5:])
        left = pcm[0::2]
        pairs += len(left)
        crossings = [k - 1 + left[k - 1] / (left[k - 1] - left[k])
                     for k in range(1, len(left)) if left[k - 1] <= 0 < left[k]]
        if len(crossings) >= 3:
            cycles += len(crossings) - 1
            span += crossings[-1] - crossings[0]
    return pairs, (cycles / span * rate if span else 0.0)


problems = []
with Client() as c, Feeder() as feeder:
    open_project(PROJECT)
    got = rates()
    print("after opening the project:", got)
    assert got["project_use"] == 1 and got["project"] == 44100, \
        f"the project doesn't ask for 44100 Hz, so this checks nothing: {got}"
    assert got["device"] == DEVICE_RATE, \
        f"JACK should keep REAPER at {DEVICE_RATE} Hz whatever the project asks: {got}"

    feeder.wait_connected()
    fed = feeder.tone(0, TONE_HZ, 0.5)
    time.sleep(0.5)

    r = c.command("audio/startStream")
    assert r["success"], r
    rate = r["payload"]["sampleRate"]
    print("audio/startStream:", r["payload"])
    if rate != DEVICE_RATE:
        problems.append(f"audio/startStream reports {rate} Hz; the device, and so the stream, runs at {DEVICE_RATE}")

    c.drain(0.5)
    hook_rate = c.command("audio/status")["payload"]["sampleRate"]
    if hook_rate != DEVICE_RATE:
        problems.append(f"the audio hook sees {hook_rate} Hz, not the device's {DEVICE_RATE}")
    # Every project event since connecting, the ones after the project
    # opened included (one goes out whenever sampleRate changes).
    event_rates = [m["payload"].get("sampleRate") for name, m in c.events if name == "project"]
    print("project events' sampleRate:", event_rates)
    if not event_rates or any(r != DEVICE_RATE for r in event_rates):
        problems.append(f"project events' sampleRate {event_rates}, not the device's {DEVICE_RATE}")

    c.binary.clear()
    t0 = time.time()
    c.drain(4.0)
    elapsed = time.time() - t0
    frames = [f for f in c.binary if f[:1] == b"\x01"]
    assert c.command("audio/stopStream")["success"]

pairs, hz = stream_measure(frames, rate)
per_second = pairs / elapsed
print(f"{len(frames)} frames, {pairs} sample frames in {elapsed:.2f} s: {per_second:.0f} a second, "
      f"reported {rate}")
print(f"the {fed:.2f} Hz tone decodes at {hz:.2f} Hz at the reported rate "
      f"({1200 * math.log2(hz / fed) if hz else float('nan'):+.1f} cents)")
assert frames, "no audio frames while input 1 is fed a tone and monitored"
if abs(per_second - rate) > 0.04 * rate:
    problems.append(f"{per_second:.0f} sample frames arrive a second, but the stream says {rate}: "
                    f"a phone falls behind or runs dry")
if abs(hz - fed) > 0.005 * fed:
    problems.append(f"a {fed:.2f} Hz tone plays at {hz:.2f} Hz at the reported rate")

assert not problems, "\n".join(problems)
print(f"ok: the stream says {rate} Hz, the rate its samples arrive at, with the project asking for 44100")
