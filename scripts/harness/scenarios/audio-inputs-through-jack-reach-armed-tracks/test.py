"""Audio fed into REAPER's JACK inputs reaches the tracks armed on them, input
by input, and keeps reaching them after REAPER reopens its audio device.

REAPER runs on JACK with 4 inputs (`jack-inputs`); jack_feeder feeds them.
Tracks 1-4 each record and monitor one mono input (startup.lua).

- REAPER has 4 inputs.
- Steady tones at 0.5, 0.25 and 0.125 on inputs 1-3 and silence on input 4
  show on the four tracks' meters at those levels.
- REAPER reopening its device (Audio_Quit, Audio_Init) re-registers its
  input ports, which drops their connections; the feeder reconnects and the
  meters show the tones again.
- A recording of all four inputs while the feeder changes them holds what
  was fed, sample for sample: note changes on input 1 (220 Hz at 0.5, then
  11 changes between 330 and 220 Hz, ending on 330), a pluck on input 2
  (330 Hz from 0.8, 60 dB down in 0.6 s), a swell on input 3 (440 Hz,
  rising to 0.5 over 1 s) and silence on input 4. A recording is REAPER's
  own copy of its input, before track volume and pan, so its levels are
  the fed ones.
- Each note change keeps the phase: no sample-to-sample jump on input 1
  is bigger than the sine's own steepest step. A change restarting at
  phase 0 would jump by up to the amplitude, at nearly every change.

Levels and frequencies are judged by medians or over several 50 ms windows,
not every block: a late feeder block (an xrun) leaves a gap.
"""
import os
import statistics
import time

from reamo_client import reaper, skip_unless_linux

skip_unless_linux("REAPER's inputs come from the container's JACK server")

from jack_feeder import Feeder  # noqa: E402  after the skip: Linux only

N = 4
assert int(os.environ.get("HARNESS_JACK_INPUTS", "0")) == N, "boot.sh did not start JACK with jack-inputs"

PEAKS = """
local t = {}
for i = 0, reaper.CountTracks(0) - 1 do
  t[#t + 1] = reaper.Track_GetPeakInfo(reaper.GetTrack(0, i), 0)
end
return t
"""

# Per track: its item count, the take's length and, per 50 ms window of the
# take, the peak, the frequency from positive-going zero crossings
# (interpolated, first to last in the window) and the biggest change from
# one sample to the next (the first sample of a window against the last of
# the one before).
ANALYSE = """
local out = {}
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  local r = {items = reaper.CountTrackMediaItems(tr), win = {}}
  if r.items == 1 then
    local take = reaper.GetActiveTake(reaper.GetTrackMediaItem(tr, 0))
    local acc = reaper.CreateTakeAudioAccessor(take)
    local t0, t1 = reaper.GetAudioAccessorStartTime(acc), reaper.GetAudioAccessorEndTime(acc)
    local sr, W = 48000, 2400
    local buf = reaper.new_array(W)
    r.len = t1 - t0
    local prev
    for w = 0, math.floor((t1 - t0) * sr / W) - 1 do
      buf.clear()
      reaper.GetAudioAccessorSamples(acc, sr, 1, t0 + w * W / sr, W, buf)
      local s = buf.table()
      local peak, first, last, count, step = 0, nil, nil, 0, 0
      for k = 1, W do
        local a = s[k] < 0 and -s[k] or s[k]
        if a > peak then peak = a end
        if prev then
          local d = s[k] - prev
          if d < 0 then d = -d end
          if d > step then step = d end
        end
        prev = s[k]
        if k > 1 and s[k - 1] <= 0 and s[k] > 0 then
          local x = k - 1 + s[k - 1] / (s[k - 1] - s[k])
          first = first or x
          last = x
          count = count + 1
        end
      end
      r.win[#r.win + 1] = {peak, count >= 3 and (count - 1) * sr / (last - first) or 0, step}
    end
    reaper.DestroyAudioAccessor(acc)
  end
  out[#out + 1] = r
end
return out
"""

TONES = [(220.0, 0.5), (330.0, 0.25), (440.0, 0.125)]
CHANGES = 11


def near(got, want, rel):
    return abs(got - want) <= rel * want


def median_peaks(samples=8):
    got = []
    for _ in range(samples):
        time.sleep(0.1)
        got.append(reaper(PEAKS))
    return [statistics.median(s[i] for s in got) for i in range(N)]


def check_meters(peaks, when):
    """At unity volume and centre pan, REAPER meters a monitored mono input
    at the level fed."""
    print(f"meters ({when}):", [round(p, 4) for p in peaks])
    problems = [f"track {i + 1} meter {peaks[i]:.4f}, fed {amp}"
                for i, (_, amp) in enumerate(TONES) if not near(peaks[i], amp, 0.02)]
    if peaks[3] != 0:
        problems.append(f"track 4's input is silent, its meter shows {peaks[3]}")
    assert not problems, f"{when}: " + "; ".join(problems)


n_in = reaper("return reaper.GetNumAudioInputs()")
print(f"REAPER {reaper('return reaper.GetAppVersion()')}: {n_in} audio inputs")
assert n_in == N, f"REAPER has {n_in} audio inputs, not the {N} of linux_audio_nch_in"

with Feeder() as f:
    for ch, (freq, amp) in enumerate(TONES):
        f.tone(ch, freq, amp)
    f.silence(3)
    s = f.wait_connected()
    time.sleep(0.5)
    check_meters(median_peaks(), "fed")

    reaper("reaper.Audio_Quit(); reaper.Audio_Init()")
    s = f.wait_connected(connects=s["connects"] + N)
    print("reconnected:", s)
    time.sleep(0.5)
    check_meters(median_peaks(), "after REAPER reopened its device")

    # The recording: input 1 changes note, 2 is plucked, 3 swells, 4 stays silent.
    f.silence(1)
    f.silence(2)
    time.sleep(0.3)
    before = f.stats()
    reaper("reaper.SetEditCurPos(0, false, false); reaper.Main_OnCommand(1013, 0)")  # Transport: Record
    deadline = time.time() + 3
    while reaper("return reaper.GetPlayState()") & 4 == 0:
        assert time.time() < deadline, "REAPER did not start recording"
        time.sleep(0.02)
    time.sleep(0.3)
    f.pluck(1, 330.0, 0.8, decay=0.6)
    f.swell(2, 440.0, 0.5, seconds=1.0)
    time.sleep(0.3)
    for k in range(CHANGES):
        f.tone(0, 330.0 if k % 2 == 0 else 220.0, 0.5)
        time.sleep(0.08)
    time.sleep(0.9)
    reaper("reaper.OnStopButton()")
    after = f.stats()
    span = after["wallSeconds"] - before["wallSeconds"]
    print(f"feeder over the recording: {100 * (after['cpuSeconds'] - before['cpuSeconds']) / span:.1f} % "
          f"of a core, {after['callbacks'] - before['callbacks']} blocks, "
          f"{after['xruns'] - before['xruns']} xruns, callback mean {after['callbackMeanUs']} us, "
          f"max {after['callbackMaxUs']} us")

takes = reaper(ANALYSE, timeout=20)
for i, t in enumerate(takes):
    print(f"track {i + 1}: {t['items']} item(s), {t.get('len', 0):.2f} s")
    print("   peaks:", " ".join(f"{p:.3f}" for p, _, _ in t["win"]))
    print("   Hz:   ", " ".join(f"{hz:.0f}" for _, hz, _ in t["win"]))
assert all(t["items"] == 1 for t in takes), "each armed track should hold one recorded item"
problems = []

# Input 1: 220 Hz at 0.5 for the first 0.6 s, then note changes, ending on
# 330 Hz at 0.5 for the last 0.9 s.
w = takes[0]["win"]
early, late = w[2:9], w[-9:-1]
for name, part, freq in (("before", early, 220.0), ("after", late, 330.0)):
    hz = statistics.median(x[1] for x in part)
    pk = statistics.median(x[0] for x in part)
    if not near(hz, freq, 0.005) or not near(pk, 0.5, 0.02):
        problems.append(f"input 1 {name} the note changes: {hz:.1f} Hz at {pk:.3f}, fed {freq} Hz at 0.5")
# A 330 Hz sine at 0.5 moves at most 0.5 * 2 pi * 330 / 48000 = 0.022 a
# sample, plus up to half that where the new note's table position is
# rounded. A gap from an xrun can jump too, hence a few windows' grace.
STEADIEST = 0.05
jumps = [(k, round(x[2], 3)) for k, x in enumerate(w) if x[2] > STEADIEST]
print(f"input 1: windows jumping more than {STEADIEST} a sample: {jumps}")
if len(jumps) > 3:
    problems.append(f"input 1: {len(jumps)} windows jump more than {STEADIEST} from one sample to the "
                    f"next across {CHANGES} note changes: a note change lost its phase ({jumps})")

# Input 2: the pluck. Starts at 0.8 and falls 60 dB in 0.6 s: 5 dB (x0.562)
# per 50 ms window, whatever the onset's place in its window; silent from
# 0.7 s after it.
w = takes[1]["win"]
onset = next((k for k, x in enumerate(w) if x[0] > 0.05), None)
if onset is None or onset + 16 > len(w):
    problems.append(f"input 2: no pluck, or too late to see it decay (onset window {onset})")
else:
    top = max(x[0] for x in w[onset:onset + 2])
    hz = statistics.median(x[1] for x in w[onset:onset + 4])
    fall = statistics.median(b[0] / a[0] for a, b in zip(w[onset + 1:onset + 10], w[onset + 2:onset + 11]))
    tail = max(x[0] for x in w[onset + 14:onset + 16])
    if not near(top, 0.8, 0.02):
        problems.append(f"input 2: pluck starts at {top:.3f}, fed 0.8")
    if not near(hz, 330.0, 0.005):
        problems.append(f"input 2: pluck at {hz:.1f} Hz, fed 330")
    if not near(fall, 10 ** -0.25, 0.03):
        problems.append(f"input 2: the pluck falls x{fall:.3f} per 50 ms, not x0.562 (60 dB in 0.6 s)")
    if tail > 0.002:
        problems.append(f"input 2: 0.7 s after the pluck the peak is still {tail:.4f}")

# Input 3: the swell. Rises from silence to 0.5 over 1 s, 0.025 per 50 ms
# window, then holds 440 Hz at 0.5.
w = takes[2]["win"]
start = next((k for k, x in enumerate(w) if x[0] > 0.01), None)
if start is None or start + 24 > len(w):
    problems.append(f"input 3: no swell, or too late to see it end (start window {start})")
else:
    rise = statistics.median(b[0] - a[0] for a, b in zip(w[start + 1:start + 18], w[start + 2:start + 19]))
    held = w[start + 22:-1]
    hz = statistics.median(x[1] for x in held)
    pk = statistics.median(x[0] for x in held)
    if not near(rise, 0.025, 0.03):
        problems.append(f"input 3: the swell rises {rise:.4f} per 50 ms, not 0.025 (0.5 in 1 s)")
    if not near(hz, 440.0, 0.005) or not near(pk, 0.5, 0.02):
        problems.append(f"input 3: after the swell {hz:.1f} Hz at {pk:.3f}, fed 440 Hz at 0.5")

# Input 4: silence.
loudest = max(x[0] for x in takes[3]["win"])
if loudest > 0:
    problems.append(f"input 4 was fed silence, its recording peaks at {loudest}")

assert not problems, "\n".join(problems)
print("ok: 4 inputs, each reaching its track, through a device reopen, and recorded as fed")
