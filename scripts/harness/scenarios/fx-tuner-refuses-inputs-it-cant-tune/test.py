"""The tuner refuses a track whose record input it can't read, with a code
and a message for the phone, and says so when a tuned track's input
changes to one, resuming when it can tune again.

REAPER runs on JACK with 2 inputs. tuner/subscribe on each track refuses:
- record input None: INPUT_NONE;
- MIDI: INPUT_MIDI;
- mono input 5, and the stereo pair 2/3, on a 2-input device:
  INPUT_NOT_ON_DEVICE;
- ReaRoute/loopback (512) and multichannel (2048): INPUT_NOT_SUPPORTED, if
  REAPER keeps those values on this device (they are read back first).
Each refusal has a message, opens no input tap and adds no FX.

A phone refused on "No input" still follows it: a reference it sends
then (as a page sends its saved A4) holds once the track is given input 1.

Then Guitar (input 2) is tuned and its record input changed in REAPER
while it is: to None, the phone's events say cantTune with INPUT_NONE;
to input 5, INPUT_NOT_ON_DEVICE; back to input 2, listening, and a pluck
reads A3. The phone was never unsubscribed.
"""
import time

from reamo_client import Client, reaper, skip_unless_linux

skip_unless_linux("REAPER's inputs come from the container's JACK server")

from jack_feeder import Feeder  # noqa: E402  after the skip: Linux only
from tuner_phone import Phone, check_note, watch  # noqa: E402

EXPECTED = {
    "No input": (-1, "INPUT_NONE"),
    "MIDI": (4096 | (63 << 5), "INPUT_MIDI"),
    "Input 5": (4, "INPUT_NOT_ON_DEVICE"),
    "Stereo 2/3": (1024 + 1, "INPUT_NOT_ON_DEVICE"),
    "ReaRoute": (512, "INPUT_NOT_SUPPORTED"),
    "Multichannel": (2048, "INPUT_NOT_SUPPORTED"),
}

FX = """
local n = 0
for i = 0, reaper.CountTracks(0) - 1 do
  local t = reaper.GetTrack(0, i)
  n = n + reaper.TrackFX_GetCount(t) + reaper.TrackFX_GetRecCount(t)
end
return n
"""


def set_input(idx, value):
    reaper(f"reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, {idx}), 'I_RECINPUT', {value})")


problems = []
with Client() as c, Feeder() as f:
    f.wait_connected()
    tracks = c.wait_event("trackSkeleton")["payload"]["tracks"][1:]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    for i, t in enumerate(tracks):
        if t["n"] not in EXPECTED:
            continue
        set_to, code = EXPECTED[t["n"]]
        kept = reaper(f"return reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, {i}), 'I_RECINPUT')")
        if kept != set_to:
            print(f"{t['n']}: REAPER keeps I_RECINPUT {kept}, not {set_to}: not checked here")
            continue
        r = c.command("tuner/subscribe", trackGuid=t["g"])
        err = r.get("error") or {}
        print(f"{t['n']} (I_RECINPUT {kept}): {err.get('code')}: {err.get('message')}")
        if r["success"] or err.get("code") != code:
            problems.append(f"{t['n']}: want {code}, got {r}")
        elif not err.get("message"):
            problems.append(f"{t['n']}: {code} has no message")
        status = c.command("audio/status")["payload"]
        if status["inputTaps"] != 0:
            problems.append(f"{t['n']}: an input tap opened for a refused track")
    if reaper(FX) != 0:
        problems.append("a refused subscribe added an FX")

    # A phone refused for the track's input still follows it, and a setting
    # it sends then (as a page sends its saved A4) holds once the user gives
    # the track an input.
    none_idx = next(i for i, t in enumerate(tracks) if t["n"] == "No input")
    follower = Phone(c, "No input's phone")
    r = follower.subscribe(tracks[none_idx]["g"])
    assert not r["success"] and r["error"]["code"] == "INPUT_NONE", r
    r = c.command("tuner/setParam", trackGuid=tracks[none_idx]["g"], param="reference", value=442.0)
    if not r["success"]:
        problems.append(f"setParam on a refused, followed track: {r}")
    follower.wait_state("cantTune", code="INPUT_NONE")
    set_input(none_idx, 0)
    p = follower.wait_state("listening")
    print("No input given input 1:", p["state"], p["referenceHz"])
    if p["referenceHz"] != 442.0:
        problems.append(f"the 442 Hz sent while refused didn't hold once the input was set: {p['referenceHz']}")
    set_input(none_idx, -1)

    gtr_idx = next(i for i, t in enumerate(tracks) if t["n"] == "Guitar")
    phone = Phone(c, "Guitar's phone")
    assert phone.subscribe(tracks[gtr_idx]["g"])["success"]
    phone.wait_state("listening")
    for value, code in ((-1, "INPUT_NONE"), (4, "INPUT_NOT_ON_DEVICE")):
        set_input(gtr_idx, value)
        p = phone.wait_state("cantTune", code=code)
        print(f"Guitar's input set to {value}: {p['state']} {p['code']}: {p['message']}")
        if p["freq"] != 0 or not p["message"]:
            problems.append(f"cantTune {code}: {p}")
    set_input(gtr_idx, 1)
    phone.wait_state("listening")
    f.silence(1)
    time.sleep(0.5)
    phone.mark()
    freq = f.pluck(1, 220.0, 0.8, decay=4.0)
    watch([phone], 1.5)
    check_note(phone, freq, problems)
    if c.events and any(n == "tunerError" for n, _ in c.events):
        problems.append(f"the phone was sent a tunerError: {c.events}")

assert not problems, "\n".join(problems)
print("ok: each untunable input is refused with its reason, and a tuned track follows its input")
