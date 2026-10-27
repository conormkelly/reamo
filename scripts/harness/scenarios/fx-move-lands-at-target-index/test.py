"""trackFx/move puts the FX at the index the UI asked for, and says so.

The UI drags an FX from one slot to another and sends trackFx/move with the
FX's GUID and the destination index; the response's newIndex is where it
claims the FX now is. Both must match where REAPER actually put it, moving
both down and up the chain, and a second client's trackFxChain must follow.
"""
import time
from reamo_client import Client, reaper

CHAIN = """
local t = reaper.GetTrack(0, 0)
local out = {}
for i = 0, reaper.TrackFX_GetCount(t) - 1 do out[#out + 1] = reaper.TrackFX_GetFXGUID(t, i) end
return out
"""


def wait_guid_cache(c, guid):
    t0 = time.time()
    while c.command("trackFx/delete", trackGuid=guid, fxIndex=9999)["error"]["code"] == "NOT_FOUND":
        assert time.time() - t0 < 5, "track GUID never became resolvable"
        time.sleep(0.05)


def chain_event_guids(c, want):
    deadline = time.time() + 2
    while True:
        c.drain(0.1)
        ev = c.latest_event("trackFxChain")
        got = [f["fxGuid"] for f in ev["payload"]["fx"]] if ev else None
        if got == want or time.time() > deadline:
            return got


with Client() as a, Client() as b:
    g = a.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    wait_guid_cache(a, g)
    assert b.command("trackFx/subscribe", trackGuid=g)["success"]
    order = reaper(CHAIN)
    problems = []
    # (from, to): down by one, down to the end, up to the start, up by one, no-op
    for src, dst in [(0, 1), (0, 3), (3, 0), (2, 1), (1, 1)]:
        guid = order[src]
        want = order[:src] + order[src + 1:]
        want.insert(dst, guid)
        r = a.command("trackFx/move", trackGuid=g, fxGuid=guid, toIndex=dst)
        assert r["success"], r
        got = reaper(CHAIN)
        actual = got.index(guid)
        line = f"move {src}->{dst}: newIndex={r['payload']['newIndex']} REAPER puts it at {actual}"
        print(line)
        if got != want or r["payload"]["newIndex"] != actual:
            problems.append(line)
        seen = chain_event_guids(b, got)
        if seen != got:
            problems.append(f"move {src}->{dst}: second client's chain {seen} != REAPER {got}")
        order = got
    assert not problems, "\n".join(problems)
