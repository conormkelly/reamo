"""send/setVolume and send/setPan change the send the UI addressed, with hardware outputs present.

SendsTab sends (trackIdx, sendIdx) where sendIdx is the index in the routing
event's sends list (REAPER category 0). On a track that also has a hardware
output, moving the second send's fader must change that send and nothing else.
"""
import time
from reamo_client import Client, oracle, reaper

STATE = """
local t = reaper.GetTrack(0, 0)
local function g(cat, i, k) return reaper.GetTrackSendInfo_Value(t, cat, i, k) end
return {hw = {g(1, 0, 'D_VOL'), g(1, 0, 'D_PAN')}, s0 = {g(0, 0, 'D_VOL'), g(0, 0, 'D_PAN')},
        s1 = {g(0, 1, 'D_VOL'), g(0, 1, 'D_PAN')}}
"""

o = oracle()
assert (o["hw"], o["s0"], o["s1"]) == ("0", "0", "1"), o
with Client() as c:
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    assert c.command("routing/subscribe", trackGuid=g)["success"]
    ev = c.wait_event("routing_state")["payload"]
    print("UI sees sends:", [(s["sendIndex"], s["destName"]) for s in ev["sends"]], "hw:", len(ev["hwOutputs"]))
    assert [s["destName"] for s in ev["sends"]] == ["Reverb", "Delay"], ev
    before = reaper(STATE)
    c.fire("send/setVolume", trackIdx=1, sendIdx=1, volume=0.5)   # Delay send fader
    c.fire("send/setPan", trackIdx=1, sendIdx=1, pan=-0.5)
    deadline = time.time() + 2
    while True:
        c.drain(0.1)
        after = reaper(STATE)
        if after != before or time.time() > deadline:
            break
    c.drain(0.3)
    after = reaper(STATE)
    print("before:", before)
    print("after: ", after)
    assert after["s1"] == [0.5, -0.5], f"the Delay send should be 0.5 / -0.5: {after}"
    assert after["s0"] == before["s0"], f"the Reverb send changed: {before['s0']} -> {after['s0']}"
    assert after["hw"] == before["hw"], f"the hardware output changed: {before['hw']} -> {after['hw']}"
