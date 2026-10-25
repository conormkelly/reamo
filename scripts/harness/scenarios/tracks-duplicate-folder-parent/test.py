"""Duplicating a track returns the wire index of the copy REAPER made, for a plain
track and for a folder parent (where REAPER also copies the children)."""
from reamo_client import Client, reaper

TRACKS = """
local t = {}
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  local _, n = reaper.GetTrackName(tr)
  t[#t + 1] = {n, reaper.GetTrackGUID(tr), math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")),
               reaper.IsTrackSelected(tr)}
end
return t
"""

with Client() as c:
    c.wait_event("trackSkeleton")
    problems = []
    for label, idx, name in (("plain track Bass", 4, "Bass"), ("folder parent Drums", 1, "Drums")):
        before = reaper(TRACKS)
        r = c.command("track/duplicate", trackIdx=idx)
        after = reaper(TRACKS)
        print(f"{label}: response {r.get('payload')}")
        for n, guid, depth, sel in after:
            print(f"    {n:6} depth={depth:+d} selected={sel} {'(new)' if guid not in [b[1] for b in before] else ''}")
        assert r["success"], r
        got = after[r["payload"]["trackIdx"] - 1]
        new = [t for t in after if t[1] not in [b[1] for b in before]]
        if got[0] != name or got[1] in [b[1] for b in before]:
            problems.append(f"{label}: returned trackIdx {r['payload']['trackIdx']} is {got[0]} "
                            f"({'existing' if got[1] in [b[1] for b in before] else 'new'}), not the copy of {name}")
        if names := [t[0] for t in after]:
            pass
    assert not problems, "\n".join(problems)
