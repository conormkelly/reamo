"""Two phones: A scrolls the mixer (range), B follows two tracks by GUID. A creates,
duplicates and deletes tracks; both skeletons match REAPER, B keeps following its
tracks by GUID at their new positions, and commands on a deleted GUID fail cleanly."""
import time

from reamo_client import Client, reaper

REAPER_TRACKS = """
local t = {}
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  local _, n = reaper.GetTrackName(tr)
  t[#t + 1] = n .. "|" .. reaper.GetTrackGUID(tr)
end
return t
"""


def skeleton(c):
    ev = c.latest_event("trackSkeleton")
    return [f"{t['n']}|{t['g']}" for t in ev["payload"]["tracks"][1:]] if ev else None


def settle(step, *clients):
    deadline = time.time() + 3
    while True:
        for x in clients:
            x.drain(0.15)
        want = reaper(REAPER_TRACKS)
        if all(skeleton(x) == want for x in clients) or time.time() > deadline:
            break
    print(f"{step:>22}: {[s.split('|')[0] for s in want]}")
    for x in clients:
        assert skeleton(x) == want, f"{step}: skeleton {skeleton(x)} != REAPER {want}"
    return want


with Client() as a, Client() as b:
    skel = a.wait_event("trackSkeleton")["payload"]["tracks"]
    b.wait_event("trackSkeleton")
    a.events.append(("trackSkeleton", {"payload": {"tracks": skel}}))
    b.events.append(("trackSkeleton", {"payload": {"tracks": skel}}))
    g = {t["n"]: t["g"] for t in skel}
    a.drain(1.2)
    assert a.command("track/subscribe", range={"start": 0, "end": 7})["success"]
    assert b.command("track/subscribe", guids=[g["Bass"], g["Vox"]])["success"]

    r = a.command("track/create", name="Perc", afterTrackIdx=0)  # new first track
    assert r["success"] and r["payload"]["trackIdx"] == 1, r
    settle("create Perc at top", a, b)
    r = a.command("track/duplicate", trackIdx=4)  # Bass is now at 4
    after_dup = settle("duplicate Bass", a, b)
    assert r["success"], r
    dup_idx = r["payload"]["trackIdx"]
    assert after_dup[dup_idx - 1].startswith("Bass|") and not after_dup[dup_idx - 1].endswith(g["Bass"]), \
        f"duplicate returned trackIdx {dup_idx}, which is {after_dup[dup_idx - 1]}"
    sel = reaper("local t = reaper.GetSelectedTrack(0, 0); return t and reaper.GetTrackGUID(t)")
    print("duplicate selected in REAPER:", sel, "returned idx", dup_idx)

    r = a.command("track/delete", trackIdx=2)  # Kick
    assert r["success"], r
    now = settle("delete Kick", a, b)

    # B still follows Bass and Vox, by GUID, at their new indices.
    deadline = time.time() + 2
    while True:
        b.events.clear()
        b.drain(0.3)
        tr = [m for n, m in b.events if n == "tracks"]
        # tracks/meters carry the union of every client's subscriptions, broadcast to all,
        # so B sees A's window too; B's own tracks must be in it, at their new indices.
        got = {t["g"]: t["idx"] for t in tr[-1]["payload"]["tracks"]} if tr else {}
        want = {g[n]: now.index(f"{n}|{g[n]}") + 1 for n in ("Bass", "Vox")}
        if all(got.get(k) == v for k, v in want.items()) or time.time() > deadline:
            break
    print("B follows:", {k: got.get(k) for k in want}, f"(event carries {len(got)} tracks)")
    assert all(got.get(k) == v for k, v in want.items()), f"B's GUID tracks at {got}, want {want}"

    # A stale GUID (the deleted Kick) is refused, and nothing else changes.
    for cmd, extra in (("track/setVolume", {"volume": 0.1}), ("track/setMute", {"mute": 1}),
                       ("track/rename", {"name": "ghost"}), ("track/delete", {})):
        r = b.command(cmd, trackGuid=g["Kick"], **extra)
        assert not r["success"] and r["error"]["code"] == "NOT_FOUND", f"{cmd} on deleted GUID: {r}"
    assert reaper(REAPER_TRACKS) == now
