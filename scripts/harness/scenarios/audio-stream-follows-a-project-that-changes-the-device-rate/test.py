"""Opening a project that changes the device's rate: the next audio stream
reports the new rate at once, though the audio hook last saw the old one.

REAPER's dummy device follows the project's rate. A phone streams a 44.1 kHz
project, stops, and the user opens a 48 kHz one. The audio hook has been
released since, so the rate it last saw is still 44100, until it next runs.
`audio/startStream` answers before it has, so it must ask REAPER for the
device's rate rather than take the hook's.

- Preconditions: the device runs at 44100, then at 48000 once the second
  project has opened (skipped on a device that can't change rate, as JACK
  can't); the hook's last rate is still 44100 when the stream starts again.
- The first `audio/startStream`, before the hook has ever run, says 44100.
- After the switch, `audio/startStream` says 48000, and so does the project
  event the phone restarts its player on.
- As many sample frames arrive per second as the reported rate says,
  within 4 %.
"""
import time

from reamo_client import Client, open_project, reaper, skip

DIR = "/tmp/srate"


def device_rate():
    return int(reaper('return tonumber(select(2, reaper.GetAudioDeviceInfo("SRATE", ""))) or 0'))


def status(c):
    r = c.command("audio/status")
    assert r["success"], r
    return r["payload"]


problems = []
with Client() as c:
    open_project(f"{DIR}/asks-44100.RPP")
    if device_rate() != 44100:
        skip(f"the audio device runs at {device_rate()} Hz with a 44.1 kHz project: it can't change rate")
    reaper("reaper.OnPlayButton()")
    r = c.command("audio/startStream")
    assert r["success"], r
    print("first audio/startStream, before the hook has run:", r["payload"])
    if r["payload"]["sampleRate"] != 44100:
        problems.append(f"the first audio/startStream reports {r['payload']['sampleRate']} Hz, "
                        f"with the device at 44100")
    c.drain(1.0)
    assert status(c)["sampleRate"] == 44100, status(c)
    assert c.command("audio/stopStream")["success"]
    reaper("reaper.OnStopButton()")

    open_project(f"{DIR}/asks-48000.RPP")
    assert device_rate() == 48000, f"the dummy device didn't follow the 48 kHz project: {device_rate()} Hz"
    stale = status(c)["sampleRate"]
    print("hook's last rate after opening the 48 kHz project:", stale)
    assert stale == 44100, f"the hook's last rate is {stale}, so this doesn't check a stale one"

    reaper("reaper.OnPlayButton()")
    r = c.command("audio/startStream")
    assert r["success"], r
    rate = r["payload"]["sampleRate"]
    print("audio/startStream:", r["payload"])
    if rate != 48000:
        problems.append(f"audio/startStream reports {rate} Hz after the device moved to 48000")

    c.drain(0.5)
    c.binary.clear()
    t0 = time.time()
    c.drain(3.0)
    elapsed = time.time() - t0
    frames = [f for f in c.binary if f[:1] == b"\x01"]
    assert c.command("audio/stopStream")["success"]
    reaper("reaper.OnStopButton()")
    event = c.latest_event("project")
    event_rate = event and event["payload"].get("sampleRate")
    if event_rate != 48000:
        problems.append(f"the latest project event's sampleRate is {event_rate}, not 48000")

pairs = sum((len(f) - 5) // 4 for f in frames)
per_second = pairs / elapsed
print(f"{len(frames)} frames, {pairs} sample frames in {elapsed:.2f} s: {per_second:.0f} a second, reported {rate}")
assert frames, "no audio frames while the tone generator plays"
if abs(per_second - rate) > 0.04 * rate:
    problems.append(f"{per_second:.0f} sample frames arrive a second, but the stream says {rate}")

assert not problems, "\n".join(problems)
print("ok: the stream follows the device from 44100 to 48000 Hz at once")
