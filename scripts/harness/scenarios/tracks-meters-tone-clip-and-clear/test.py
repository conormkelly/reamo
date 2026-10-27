"""Meters during playback follow REAPER's own peaks, a track over 0 dB shows clip,
and once the user pulls the fader down, meter/clearClip clears it -- in REAPER and
on the phone. (REAPER keeps running track FX when stopped, so the tone never stops.)"""
import time

from reamo_client import Client, oracle, reaper

PEAKS = """
local t = {}
for i = 0, 2 do
  local tr = reaper.GetTrack(0, i)
  t[#t + 1] = {reaper.Track_GetPeakInfo(tr, 0), reaper.Track_GetPeakHoldDB(tr, 0, false)}
end
return t
"""

assert oracle().get("fx") == "1", f"tone generator not loaded: {oracle()}"

with Client() as c:
    g = [t["g"] for t in c.wait_event("trackSkeleton")["payload"]["tracks"]]
    assert c.command("track/subscribe", range={"start": 0, "end": 3})["success"]
    c.drain(1.2)
    reaper("reaper.OnPlayButton()")
    deadline = time.time() + 4
    while time.time() < deadline:
        c.drain(0.2)
        m = c.latest_event("meters")["m"]
        if m[g[1]]["c"] and m[g[2]]["l"] > 0:
            break
    peaks = reaper(PEAKS)
    print("REAPER peak/hold:", peaks)
    print("meters:", {k[:6]: v for k, v in m.items()})
    assert m[g[1]]["l"] > 1.0 and m[g[1]]["c"] is True, f"loud track: {m[g[1]]}"
    assert 0.05 < m[g[2]]["l"] < 0.2 and m[g[2]]["c"] is False, f"-20 dB track: {m[g[2]]}"
    assert m[g[3]]["l"] == 0 and m[g[3]]["c"] is False, f"silent track: {m[g[3]]}"
    assert m["master"]["l"] > 0, f"master: {m['master']}"

    reaper("reaper.OnStopButton()")
    c.fire("track/setVolume", trackGuid=g[1], volume=0.25)  # fader down: tone now peaks at 0.5
    deadline = time.time() + 2
    while time.time() < deadline:
        c.drain(0.2)
        if abs(c.latest_event("meters")["m"][g[1]]["l"] - 0.5) < 0.01:
            break
    print("fader down:", c.latest_event("meters")["m"][g[1]])
    assert c.latest_event("meters")["m"][g[1]]["c"] is True, "clip should hold until cleared"
    c.fire("meter/clearClip", trackGuid=g[1])  # tap on the clip LED
    deadline = time.time() + 2
    while time.time() < deadline:
        c.drain(0.2)
        if c.latest_event("meters")["m"][g[1]]["c"] is False:
            break
    hold = reaper("return reaper.Track_GetPeakHoldDB(reaper.GetTrack(0, 0), 0, false)")
    print("after clearClip: meter", c.latest_event("meters")["m"][g[1]], "REAPER hold", hold)
    assert c.latest_event("meters")["m"][g[1]]["c"] is False, "clip still shown after clearClip"
    assert hold <= 0, f"REAPER peak hold still {hold}"
