"""Two phones tuning one track share its tuner and its settings, which
stays open until the last one leaves.

Phone A and phone B open the tuner on Bass: one input tap. A sets the
reference to 442 Hz; both are told it. Out-of-range values are held to the
tuner's range (A4 400-480 Hz, threshold -90 to -30 dB), in what a third
phone opening Bass is told; an unknown parameter and a track nobody tunes
are refused. A switches to Guitar: two taps. B's connection drops: one
(Guitar's). A unsubscribes: none, and the hook is let go. No track ever
has an FX.
"""
import time
from reamo_client import Client, reaper, skip_unless_linux

skip_unless_linux("REAPER's inputs come from the container's JACK server")

FX = """
local n = 0
for i = 0, reaper.CountTracks(0) - 1 do
  local t = reaper.GetTrack(0, i)
  n = n + reaper.TrackFX_GetCount(t) + reaper.TrackFX_GetRecCount(t)
end
return n
"""


def status(c):
    s = c.command("audio/status")["payload"]
    return s["inputTaps"], s["hookUsers"]["inputs"]


def tuner_ref(c, want):
    deadline = time.time() + 2
    while True:
        c.drain(0.1)
        ev = c.latest_event("tuner")
        if (ev and abs(ev["payload"]["referenceHz"] - want) < 0.05) or time.time() > deadline:
            return ev and ev["payload"]["referenceHz"]


with Client() as a:
    skel = a.wait_event("trackSkeleton")["payload"]["tracks"]
    bass, gtr = skel[1]["g"], skel[2]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    b = Client()
    ra = a.command("tuner/subscribe", trackGuid=bass)
    rb = b.command("tuner/subscribe", trackGuid=bass)
    assert ra["success"] and rb["success"], (ra, rb)
    assert status(a) == (1, True), status(a)

    r = a.command("tuner/setParam", trackGuid=bass, param="reference", value=442.0)
    assert r["success"], r
    assert tuner_ref(a, 442.0) == 442.0 and tuner_ref(b, 442.0) == 442.0

    for param, value in [("reference", 300.0), ("threshold", 20.0), ("bogus", 1.0)]:
        r = a.command("tuner/setParam", trackGuid=bass, param=param, value=value)
        print(f"setParam {param}={value}: {r.get('error') or 'ok'}")
    # Out-of-range values are held to the tuner's range, in what another
    # phone opening the tuner is told.
    with Client() as c:
        rc = c.command("tuner/subscribe", trackGuid=bass)
        assert rc["success"], rc
        held = (rc["payload"]["reference"], rc["payload"]["threshold"])
        print("a third phone opening Bass is told:", held)
        assert held == (400.0, -30.0), f"setParam 300 Hz / 20 dB should be held to 400 / -30, got {held}"
        assert status(a) == (1, True), status(a)
        r = a.command("tuner/setParam", trackGuid=gtr, param="reference", value=441.0)
    assert not r["success"], f"setParam on a track with no tuner succeeded: {r}"

    assert a.command("tuner/subscribe", trackGuid=gtr)["success"]  # A switches track
    print("A on Guitar:", status(a))
    assert status(a) == (2, True), status(a)
    b.close()  # B's phone goes to sleep
    deadline = time.time() + 3
    while status(a) != (1, True) and time.time() < deadline:
        a.drain(0.2)
    print("after B disconnects:", status(a))
    assert status(a) == (1, True), status(a)
    assert a.command("tuner/unsubscribe")["success"]
    assert status(a) == (0, False), status(a)
    assert reaper(FX) == 0, "a track has an FX"
