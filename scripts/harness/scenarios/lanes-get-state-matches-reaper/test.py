"""lanes/getState reports what REAPER has, before and after lanes/setLanePlays.

Lane names a user typed in REAPER may hold quotes, backslashes or a tab; the
response must still be valid JSON and carry them exactly.
"""
import time
from reamo_client import Client, reaper, skip_before_lanes

STATE = """
local t = reaper.GetTrack(0, 0)
local n = reaper.GetMediaTrackInfo_Value(t, "I_NUMFIXEDLANES")
local lanes = {}
for i = 0, n - 1 do
  local _, nm = reaper.GetSetMediaTrackInfo_String(t, "P_LANENAME:" .. i, "", false)
  lanes[#lanes + 1] = {i, reaper.GetMediaTrackInfo_Value(t, "C_LANEPLAYS:" .. i), nm}
end
return {n, reaper.GetMediaTrackInfo_Value(t, "I_FREEMODE"), lanes}
"""


def shown(c, g):
    deadline = time.time() + 3
    while True:
        try:
            r = c.command("lanes/getState", trackGuid=g)
        except ValueError as e:  # json.loads on the response frame
            raise AssertionError(f"lanes/getState response is not valid JSON: {e}")
        if r["success"] or time.time() > deadline:
            break
        time.sleep(0.1)
    assert r["success"], r
    p = r["payload"]
    return [p["numLanes"], p["freeMode"], [[l["lane"], l["plays"], l["name"]] for l in p["lanes"]]]


with Client() as c:
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    skip_before_lanes(c, "lanes/getState", trackGuid=g)
    want, got = reaper(STATE), shown(c, g)
    print("REAPER:", want)
    print("shown: ", got)
    assert got == want, (got, want)
    r = c.command("lanes/setLanePlays", trackGuid=g, laneIndex=1, plays=1)
    assert r["success"], r
    want, got = reaper(STATE), shown(c, g)
    print("after setLanePlays(1, exclusive):", want)
    assert got == want, (got, want)
    r = c.command("lanes/setLanePlays", trackGuid=g, laneIndex=7, plays=1)
    print("lane out of range:", r)
    assert not r["success"], r
