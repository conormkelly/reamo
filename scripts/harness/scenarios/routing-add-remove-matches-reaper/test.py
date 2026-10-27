"""Adding and removing sends, receives and hardware outputs matches REAPER, and both routing views follow.

Phone A has the Vocals routing open, phone B the Reverb's. A adds a send to the
Reverb, B adds a receive from Click, A adds a hardware output and points it at
the right channel (mono), sets modes, then everything is removed again. After
each step both routing_state events must match REAPER's own counts and values.
"""
import time
from reamo_client import Client, reaper

STATE = """
local function info(t)
  local o = {sends = {}, receives = {}, hw = {}}
  for i = 0, reaper.GetTrackNumSends(t, 0) - 1 do
    local _, n = reaper.GetTrackName(reaper.GetTrackSendInfo_Value(t, 0, i, 'P_DESTTRACK'))
    o.sends[#o.sends + 1] = n .. ':' .. math.floor(reaper.GetTrackSendInfo_Value(t, 0, i, 'I_SENDMODE'))
  end
  for i = 0, reaper.GetTrackNumSends(t, -1) - 1 do
    local _, n = reaper.GetTrackName(reaper.GetTrackSendInfo_Value(t, -1, i, 'P_SRCTRACK'))
    o.receives[#o.receives + 1] = n .. ':' .. math.floor(reaper.GetTrackSendInfo_Value(t, -1, i, 'I_SENDMODE'))
  end
  for i = 0, reaper.GetTrackNumSends(t, 1) - 1 do
    o.hw[#o.hw + 1] = math.floor(reaper.GetTrackSendInfo_Value(t, 1, i, 'I_DSTCHAN')) .. ':' ..
                      math.floor(reaper.GetTrackSendInfo_Value(t, 1, i, 'I_SENDMODE'))
  end
  return o
end
return {vox = info(reaper.GetTrack(0, 0)), rev = info(reaper.GetTrack(0, 1))}
"""


def shown(ev):
    p = ev["payload"]
    return {"sends": [f"{s['destName']}:{s['mode']}" for s in p["sends"]],
            "receives": [f"{r['srcName']}:{r['mode']}" for r in p["receives"]],
            "hw": [f"{h['destChannel']}:{h['mode']}" for h in p["hwOutputs"]]}


def norm(d):
    return {k: list(v) if v else [] for k, v in d.items()}


def check(step, a, b):
    deadline = time.time() + 2
    while True:
        a.drain(0.1); b.drain(0.1)
        want = reaper(STATE)
        want = {"vox": norm(want["vox"]), "rev": norm(want["rev"])}
        got = {"vox": shown(a.latest_event("routing_state")), "rev": shown(b.latest_event("routing_state"))}
        if got == want or time.time() > deadline:
            break
    print(f"{step:28s} vox={got['vox']} rev={got['rev']}")
    assert got == want, f"{step}: clients show {got}, REAPER {want}"
    return want


with Client() as a, Client() as b:
    skel = a.wait_event("trackSkeleton")["payload"]["tracks"]
    vox, rev, click = (t["g"] for t in skel[1:4])
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    assert a.command("routing/subscribe", trackGuid=vox)["success"]
    assert b.command("routing/subscribe", trackGuid=rev)["success"]
    for cl in (a, b):  # keep the first event: routing is only re-sent when it changes
        cl.events.append(("routing_state", cl.wait_event("routing_state")))
    check("start", a, b)

    r = a.command("send/add", trackGuid=vox, destTrackGuid=rev)
    assert r["success"] and r["payload"]["sendIndex"] == 0, r
    check("send Vocals->Reverb", a, b)
    r = b.command("receive/add", trackGuid=rev, srcTrackGuid=click)
    assert r["success"], r
    check("receive Click->Reverb", a, b)
    r = a.command("send/add", trackGuid=vox, destTrackGuid=vox)
    assert not r["success"], f"send to itself accepted: {r}"
    r = a.command("hw/add", trackGuid=vox)
    assert r["success"] and r["payload"]["hwIdx"] == 0, r
    check("hw output", a, b)
    outs = a.command("hw/listOutputs")["payload"]["outputs"]
    mono_r = next(o["destChan"] for o in outs if not o["stereo"] and o["name"].endswith("R"))
    a.fire("hw/setDestChannel", trackIdx=1, hwIdx=0, destChannel=mono_r)
    check(f"hw -> mono R ({mono_r})", a, b)
    for mode in (1, 3, 0):
        a.fire("send/setMode", trackIdx=1, sendIdx=0, mode=mode)
        a.fire("hw/setMode", trackIdx=1, hwIdx=0, mode=mode)
        b.fire("receive/setMode", trackIdx=2, recvIdx=1, mode=mode)
        check(f"modes -> {mode}", a, b)
    for cmd, params in [("send/setMode", {"trackIdx": 1, "sendIdx": 0, "mode": 2}),
                        ("hw/setMode", {"trackIdx": 1, "hwIdx": 0, "mode": -1})]:
        r = a.command(cmd, **params)
        assert not r["success"], f"{cmd} accepted mode {params['mode']}: {r}"

    r = a.command("send/remove", trackGuid=vox, sendIdx=0)
    assert r["success"], r
    check("remove send", a, b)
    r = b.command("receive/remove", trackGuid=rev, recvIdx=0)
    assert r["success"], r
    check("remove receive", a, b)
    r = a.command("hw/remove", trackGuid=vox, hwIdx=0)
    assert r["success"], r
    final = check("remove hw", a, b)
    assert final == {"vox": {"sends": [], "receives": [], "hw": []},
                     "rev": {"sends": [], "receives": [], "hw": []}}, final
    for cmd, params in [("send/remove", {"trackGuid": vox, "sendIdx": 0}),
                        ("receive/remove", {"trackGuid": rev, "recvIdx": 5}),
                        ("hw/remove", {"trackGuid": vox, "hwIdx": 0})]:
        r = a.command(cmd, **params)
        assert not r["success"], f"{cmd} of a routing that does not exist succeeded: {r}"
