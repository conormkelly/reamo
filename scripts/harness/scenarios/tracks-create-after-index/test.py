"""track/create (as CreateTrackModal sends it) puts the new track where asked,
returns its wire index, and rejects out-of-range positions without creating one."""
from reamo_client import Client, reaper

NAMES = """
local t = {}
for i = 0, reaper.CountTracks(0) - 1 do local _, n = reaper.GetTrackName(reaper.GetTrack(0, i)); t[#t + 1] = n end
return t
"""

with Client() as c:
    c.wait_event("trackSkeleton")
    problems = []
    for label, params, want_idx, want in (
        ("append (no position)", {"name": "C"}, 3, ["A", "B", "C"]),
        ("after master = top", {"name": "Top", "afterTrackIdx": 0}, 1, ["Top", "A", "B", "C"]),
        ("after track 2", {"name": "Mid", "afterTrackIdx": 2}, 3, ["Top", "A", "Mid", "B", "C"]),
        ("after last", {"name": "End", "afterTrackIdx": 5}, 6, ["Top", "A", "Mid", "B", "C", "End"]),
    ):
        r = c.command("track/create", **params)
        names = reaper(NAMES)
        print(f"{label:>22}: {r.get('payload')} -> {names}")
        if not r["success"] or r["payload"]["trackIdx"] != want_idx or names != want:
            problems.append(f"{label}: response {r}, tracks {names}, want idx {want_idx} {want}")
        elif names[want_idx - 1] != params["name"]:
            problems.append(f"{label}: trackIdx {want_idx} is {names[want_idx - 1]}")
    count = len(reaper(NAMES))
    for bad in (-1, count + 1, 10_000):
        r = c.command("track/create", name="X", afterTrackIdx=bad)
        print(f"afterTrackIdx {bad}: success={r['success']} {r.get('error')}")
        if r["success"]:
            problems.append(f"afterTrackIdx {bad} accepted")
    if len(reaper(NAMES)) != count:
        problems.append(f"rejected creates still added tracks: {reaper(NAMES)}")
    assert not problems, "\n".join(problems)
