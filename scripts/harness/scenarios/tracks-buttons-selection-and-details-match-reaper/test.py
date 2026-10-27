"""Rec arm, monitor cycle, FX bypass, selection, unselect-all, duplicate/delete
selected, and the on-demand getFx/getSends/getHwOutputs all agree with REAPER."""
import time

from reamo_client import Client, reaper

STATE = """
local t = {}
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  local _, n = reaper.GetTrackName(tr)
  t[#t + 1] = {n = n, arm = reaper.GetMediaTrackInfo_Value(tr, "I_RECARM"),
               mon = reaper.GetMediaTrackInfo_Value(tr, "I_RECMON"),
               fx = reaper.GetMediaTrackInfo_Value(tr, "I_FXEN"), sel = reaper.IsTrackSelected(tr)}
end
return t
"""


def wait_state(c, pred, what):
    deadline = time.time() + 2
    while True:
        c.drain(0.1)
        s = reaper(STATE)
        if pred(s) or time.time() > deadline:
            break
    shown = {t["idx"]: t for t in c.latest_event("tracks")["payload"]["tracks"]}
    print(f"{what:>26}: {[(x['n'], x['arm'], x['mon'], x['fx'], x['sel']) for x in s]}")
    assert pred(s), what
    for i, x in enumerate(s, start=1):
        if i in shown:
            t = shown[i]
            assert (t["recArm"], t["recMon"], t["fxEnabled"], t["selected"]) == \
                (x["arm"] == 1, x["mon"], x["fx"] == 1, x["sel"]), f"{what}: track {i} shown {t}, REAPER {x}"
    return s


with Client() as c:
    g = [t["g"] for t in c.wait_event("trackSkeleton")["payload"]["tracks"]]
    assert c.command("track/subscribe", range={"start": 0, "end": 10})["success"]
    c.drain(1.2)
    c.fire("track/setRecArm", trackGuid=g[1])
    wait_state(c, lambda s: s[0]["arm"] == 1, "arm Vox (toggle)")
    c.fire("track/setRecMon", trackGuid=g[1])
    wait_state(c, lambda s: s[0]["mon"] == 2, "monitor cycle 1 -> 2")
    c.fire("track/setRecMon", trackGuid=g[1])
    wait_state(c, lambda s: s[0]["mon"] == 0, "monitor cycle 2 -> 0")
    c.fire("track/setFxEnabled", trackGuid=g[1])
    wait_state(c, lambda s: s[0]["fx"] == 0, "bypass FX chain")
    c.fire("track/setSelected", trackIdx=2, selected=1)
    c.fire("track/setSelected", trackIdx=3, selected=1)
    wait_state(c, lambda s: [x["sel"] for x in s] == [False, True, True], "select Verb + Spare")
    c.fire("track/unselectAll")
    wait_state(c, lambda s: not any(x["sel"] for x in s), "unselect all")
    c.fire("track/setSelected", trackIdx=3, selected=1)
    c.fire("track/duplicateSelected")
    wait_state(c, lambda s: [x["n"] for x in s] == ["Vox", "Verb", "Spare", "Spare"], "duplicate selected")
    c.fire("track/deleteSelected")
    wait_state(c, lambda s: [x["n"] for x in s] == ["Vox", "Verb", "Spare"], "delete selected")

    fx = c.command("track/getFx", trackIdx=1)["payload"]
    want_fx = reaper("""local t = reaper.GetTrack(0, 0); local o = {}
for i = 0, reaper.TrackFX_GetCount(t) - 1 do local _, n = reaper.TrackFX_GetFXName(t, i, ''); o[#o + 1] = n end return o""")
    print("getFx:", [(f["name"], f["enabled"]) for f in fx["fx"]], "REAPER:", want_fx)
    assert [f["name"] for f in fx["fx"]] == want_fx and fx["total"] == len(want_fx), fx
    page = c.command("track/getFx", trackIdx=1, offset=1, limit=1)["payload"]
    assert [f["fxIndex"] for f in page["fx"]] == [1] and page["hasMore"] is False, page
    sends = c.command("track/getSends", trackIdx=1)["payload"]
    print("getSends:", sends)
    assert sends["total"] == 1 and sends["sends"][0]["destName"] == "Verb", sends
    assert abs(sends["sends"][0]["volume"] - 0.5) < 1e-6 and sends["sends"][0]["muted"] is True, sends
    hw = c.command("track/getHwOutputs", trackIdx=0)["payload"]
    want_hw = reaper("return reaper.GetTrackNumSends(reaper.GetMasterTrack(0), 1)")
    print("getHwOutputs(master):", hw, "REAPER count", want_hw)
    assert hw["total"] == want_hw, hw
    for cmd in ("track/getFx", "track/getSends", "track/getHwOutputs"):
        r = c.command(cmd, trackIdx=99)
        assert not r["success"] and r["error"]["code"] == "NOT_FOUND", f"{cmd} on missing track: {r}"
