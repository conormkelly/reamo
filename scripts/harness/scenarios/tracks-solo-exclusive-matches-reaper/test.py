"""Solo, toggle solo, solo-in-place and exclusive solo from the phone leave REAPER
in the state the UI shows (undo is covered by tracks-mute-solo-taps-are-undo-steps)."""
import time

from reamo_client import Client, reaper

SOLOS = """
local t = {}
for i = 0, reaper.CountTracks(0) - 1 do
  t[#t + 1] = math.floor(reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, i), "I_SOLO"))
end
return t
"""


def shown(c):
    return [t["solo"] for t in c.latest_event("tracks")["payload"]["tracks"] if t["idx"] > 0]


def settle(c, step):
    deadline = time.time() + 2
    while True:
        c.drain(0.15)
        want = reaper(SOLOS)
        if shown(c) == want or time.time() > deadline:
            break
    print(f"{step:>28}: REAPER {want}, clients {shown(c)}")
    assert shown(c) == want, f"{step}: clients show {shown(c)}, REAPER has {want}"
    return want


with Client() as c:
    skel = c.wait_event("trackSkeleton")["payload"]["tracks"]
    g = [t["g"] for t in skel]
    assert c.command("track/subscribe", range={"start": 0, "end": 4})["success"]
    c.drain(1.2)  # see tracks-guid-commands-right-after-connect: GUIDs resolve only after the first 1 Hz tick
    c.fire("track/setSolo", trackGuid=g[1])  # toggle, as SoloButton taps do
    c.fire("track/setSolo", trackGuid=g[2])
    s = settle(c, "solo Kick + Snare")
    assert [x != 0 for x in s] == [True, True, False, False], s

    c.fire("track/setSoloExclusive", trackGuid=g[3])  # long-press on Bass solo
    s = settle(c, "exclusive Bass")
    assert [x != 0 for x in s] == [False, False, True, False], s

    c.fire("track/setSolo", trackGuid=g[3])  # tap again: unsolo
    s = settle(c, "toggle Bass off")
    assert s == [0, 0, 0, 0], s

    c.fire("track/setSolo", trackIdx=4, solo=2)  # explicit solo-in-place value
    s = settle(c, "Keys solo in place")
    assert s[3] == 2, s

    c.fire("track/setSolo", trackIdx=4)  # toggle from 2 -> off
    s = settle(c, "toggle Keys off")
    assert s == [0, 0, 0, 0], s
