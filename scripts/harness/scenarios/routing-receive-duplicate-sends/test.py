"""receive/* commands change the receive the UI addressed when one source sends twice.

ReceivesTab sends (trackIdx, recvIdx) with the index from the routing event's
receives list. With two receives from the same source track, editing the
second receive must change the second one in REAPER, not the first.
"""
import time
from reamo_client import Client, oracle, reaper

STATE = """
local t = reaper.GetTrack(0, 1)
local out = {}
for i = 0, reaper.GetTrackNumSends(t, -1) - 1 do
  out[#out + 1] = {reaper.GetTrackSendInfo_Value(t, -1, i, 'D_VOL'), reaper.GetTrackSendInfo_Value(t, -1, i, 'D_PAN'),
                   reaper.GetTrackSendInfo_Value(t, -1, i, 'B_MUTE'), reaper.GetTrackSendInfo_Value(t, -1, i, 'I_SENDMODE')}
end
return out
"""

assert oracle()["receives"] == "2"
with Client() as c:
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][2]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    assert c.command("routing/subscribe", trackGuid=g)["success"]
    ev = c.wait_event("routing_state")["payload"]
    print("UI sees receives:", [(r["receiveIndex"], r["srcName"], r["mode"]) for r in ev["receives"]])
    before = reaper(STATE)
    problems = []
    for cmd, params, field, want in [
        ("receive/setVolume", {"volume": 0.25}, 0, 0.25),
        ("receive/setPan", {"pan": 0.75}, 1, 0.75),
        ("receive/setMute", {"muted": 1}, 2, 1.0),
        ("receive/setMode", {"mode": 1}, 3, 1.0),
    ]:
        c.fire(cmd, trackIdx=2, recvIdx=1, **params)
        deadline = time.time() + 2
        while True:
            c.drain(0.1)
            now = reaper(STATE)
            if now[1][field] == want or now[0][field] != before[0][field] or time.time() > deadline:
                break
        print(f"{cmd:18s} recvIdx=1: receive0={now[0]} receive1={now[1]}")
        if now[1][field] != want or now[0][field] != before[0][field]:
            problems.append(f"{cmd} on receive 1 changed receive 0 {before[0][field]} -> {now[0][field]}, "
                            f"receive 1 is {now[1][field]} (want {want})")
    # REAPER's own mapping: the second receive is the source's second send.
    reaper("reaper.SetTrackSendInfo_Value(reaper.GetTrack(0, 0), 0, 1, 'D_VOL', 0.125)")
    print("after REAPER sets Vocals send 1 to 0.125:", reaper(STATE))
    assert not problems, "\n".join(problems)
