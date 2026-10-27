"""The tuner reports the pitch of the signal on the track.

tuner/subscribe inserts REAmo's PitchDetect JSFX at the top of the track's
input FX. A tone generator placed before it (standing in for a guitar on the
input) plays 220 Hz; the tuner events must converge on 220 Hz = A3.
"""
import time
from reamo_client import Client, reaper

TONE_HZ = 220.0

with Client() as c:
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    r = c.command("tuner/subscribe", trackGuid=g)
    assert r["success"], r
    print("subscribe:", r["payload"])
    names = reaper("""
        local t = reaper.GetTrack(0, 0)
        local out = {}
        for i = 0, reaper.TrackFX_GetRecCount(t) - 1 do
          local _, n = reaper.TrackFX_GetFXName(t, 0x1000000 + i, '')
          out[#out + 1] = n
        end
        return out
    """)
    print("input FX:", names)
    assert names == ["JS: REAmo Pitch Detector"] or names == "JS: REAmo Pitch Detector", names
    pnames = reaper("""
        local t = reaper.GetTrack(0, 0)
        local out = {}
        for i = 0, reaper.TrackFX_GetNumParams(t, 0x1000000) - 1 do
          local _, n = reaper.TrackFX_GetParamName(t, 0x1000000, i, '')
          out[#out + 1] = n
        end
        return out
    """)
    print("tuner params:", pnames)
    assert pnames[4].startswith("Reference") and pnames[6].startswith("Silence"), pnames
    # Tone before the tuner, at 220 Hz.
    info = reaper(f"""
        local t = reaper.GetTrack(0, 0)
        local i = reaper.TrackFX_AddByName(t, "JS:synthesis/tonegenerator", true, -1)
        reaper.TrackFX_CopyToTrack(t, 0x1000000 + i, t, 0x1000000, true)
        local out = {{}}
        for p = 0, reaper.TrackFX_GetNumParams(t, 0x1000000) - 1 do
          local _, n = reaper.TrackFX_GetParamName(t, 0x1000000, p, '')
          out[#out + 1] = n
          if n:lower():find("freq") then reaper.TrackFX_SetParam(t, 0x1000000, p, {TONE_HZ}) end
        end
        return out
    """)
    print("tone generator params:", info)
    deadline = time.time() + 6
    last = None
    while time.time() < deadline:
        c.drain(0.2)
        ev = c.latest_event("tuner")
        if ev:
            last = ev["payload"]
            if abs(last["freq"] - TONE_HZ) < 1.0 and last["noteName"] == "A" and last["octave"] == 3:
                break
    print("tuner shows:", last)
    assert last, "no tuner events"
    assert abs(last["freq"] - TONE_HZ) < 1.0 and last["note"] == 57 and last["noteName"] == "A" \
        and last["octave"] == 3 and abs(last["cents"]) < 5, last
