"""trackFx/add with a position inserts a new FX at that slot.

WebSocketCommands.trackFx.add(trackGuid, fxName, position?) documents
position as the insertion index (-1 / omitted = end). Adding a second copy of
an FX that is already on the chain, at the start, must give a new FX at index 0.
"""
import time
from reamo_client import Client, reaper

NAMES = """
local t = reaper.GetTrack(0, 0)
local out = {}
for i = 0, reaper.TrackFX_GetCount(t) - 1 do
  local _, n = reaper.TrackFX_GetFXName(t, i, '')
  out[#out + 1] = n
end
return out
"""


def wait_guid_cache(c, guid):
    t0 = time.time()
    while c.command("trackFx/delete", trackGuid=guid, fxIndex=9999)["error"]["code"] == "NOT_FOUND":
        assert time.time() - t0 < 5, "track GUID never became resolvable"
        time.sleep(0.05)


with Client() as c:
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    wait_guid_cache(c, g)
    problems = []
    for pos, fx in [(0, "JS:loser/4BandEQ"), (1, "JS:utility/volume"), (0, "JS:delay/delay")]:
        before = reaper(NAMES)
        r = c.command("trackFx/add", trackGuid=g, fxName=fx, position=pos)
        after = reaper(NAMES)
        print(f"add {fx} at {pos}: {r.get('payload') or r.get('error')}  chain {len(before)} -> {len(after)}")
        if not r["success"] or len(after) != len(before) + 1 or r["payload"]["fxIndex"] != pos:
            problems.append(f"add {fx} at position {pos}: response {r.get('payload') or r.get('error')}, "
                            f"chain went from {before} to {after}")
    assert not problems, "\n".join(problems)
