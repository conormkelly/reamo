"""Two phones tuning one track share one tuner JSFX, which goes when the last one leaves.

Phone A and phone B open the tuner on Bass: one PitchDetect in the input FX.
A sets the reference to 442 Hz; both see it, and a change made in the plugin
window in REAPER reaches both. A switches to Guitar, B disconnects: no tuner
is left on Bass; A unsubscribes: none left on Guitar. The project's normal FX
chains are never touched.
"""
import time
from reamo_client import Client, reaper

REC = """
local out = {}
for i = 0, 1 do
  local t = reaper.GetTrack(0, i)
  out[#out + 1] = reaper.TrackFX_GetRecCount(t) .. '/' .. reaper.TrackFX_GetCount(t)
end
return out
"""


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
    assert ra["payload"]["fxGuid"] == rb["payload"]["fxGuid"], (ra, rb)
    assert reaper(REC) == ["1/0", "0/0"], reaper(REC)

    r = a.command("tuner/setParam", trackGuid=bass, param="reference", value=442.0)
    assert r["success"], r
    got = reaper("return (reaper.TrackFX_GetParam(reaper.GetTrack(0, 0), 0x1000000, 4))")
    assert abs(got - 442.0) < 0.05, got
    assert tuner_ref(a, 442.0) == 442.0 and tuner_ref(b, 442.0) == 442.0
    reaper("reaper.TrackFX_SetParam(reaper.GetTrack(0, 0), 0x1000000, 4, 435)")  # in the plugin window
    print("after REAPER set 435:", tuner_ref(a, 435.0), tuner_ref(b, 435.0))
    assert tuner_ref(a, 435.0) == 435.0 and tuner_ref(b, 435.0) == 435.0

    for param, value in [("reference", 300.0), ("threshold", 20.0), ("bogus", 1.0)]:
        r = a.command("tuner/setParam", trackGuid=bass, param=param, value=value)
        print(f"setParam {param}={value}: {r.get('error') or 'ok'}",
              reaper("local t = reaper.GetTrack(0, 0); return (reaper.TrackFX_GetParam(t, 0x1000000, 4)), "
                     "(reaper.TrackFX_GetParam(t, 0x1000000, 6))"))
    # Out-of-range values are held to the tuner's range, in the JSFX and in
    # what another phone opening the tuner is told.
    with Client() as c:
        rc = c.command("tuner/subscribe", trackGuid=bass)
        assert rc["success"], rc
        held = (rc["payload"]["reference"], rc["payload"]["threshold"])
        print("a third phone opening Bass is told:", held)
        assert held == (400.0, -30.0), f"setParam 300 Hz / 20 dB should be held to 400 / -30, got {held}"
        r = a.command("tuner/setParam", trackGuid=gtr, param="reference", value=441.0)
    assert not r["success"], f"setParam on a track with no tuner succeeded: {r}"

    assert a.command("tuner/subscribe", trackGuid=gtr)["success"]  # A switches track
    print("A on Guitar:", reaper(REC))
    assert reaper(REC) == ["1/0", "1/0"], reaper(REC)
    b.close()  # B's phone goes to sleep
    deadline = time.time() + 3
    while reaper(REC) != ["0/0", "1/0"] and time.time() < deadline:
        a.drain(0.2)
    print("after B disconnects:", reaper(REC))
    assert reaper(REC) == ["0/0", "1/0"], reaper(REC)
    assert a.command("tuner/unsubscribe")["success"]
    assert reaper(REC) == ["0/0", "0/0"], reaper(REC)
