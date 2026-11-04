"""Two edits made in REAPER close together both reach a watching phone.

REAmo sends a track change to every phone at most once per 100 ms. In each
pair below the second edit comes with the first, or within 100 ms of the
frame the first one sends. It must still reach the phone, in that frame or
as soon as the limit allows, not wait for some later edit or a scroll.

- the same take, reversed and then sped up 50 ms later;
- two tracks' takes edited in one go;
- two tracks' takes edited 50 ms apart.

After each pair the phone's latest tiles for both takes must match
REAPER's own peaks. Before the edits, subscribing sends the phone one
frame: the change check meeting the tracks for the first time adds none.
"""
import time

from reamo_client import Client, reaper
import peaks_check as pk

REVERSE = "harness.reverse_take(it)"
DOUBLE_RATE = ('reaper.SetMediaItemTakeInfo_Value(reaper.GetActiveTake(it), "D_PLAYRATE", 2); '
               'reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 4)')
UP = (0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8)
DOWN = tuple(reversed(UP))

# (label, (track, edit), (track, edit), seconds between the edits,
#  {track: REAPER's peaks per half-second bin after both edits})
PAIRS = [
    ("the same take 50 ms apart", ("twice", REVERSE), ("twice", DOUBLE_RATE), 0.05,
     {"twice": pk.steps(*DOWN, per=1)}),
    ("two tracks at once", ("same tick 1", REVERSE), ("same tick 2", DOUBLE_RATE), 0,
     {"same tick 1": pk.steps(*DOWN), "same tick 2": pk.steps(*UP, per=1)}),
    ("two tracks 50 ms apart", ("50 ms 1", REVERSE), ("50 ms 2", DOUBLE_RATE), 0.05,
     {"50 ms 1": pk.steps(*DOWN), "50 ms 2": pk.steps(*UP, per=1)}),
]

# Makes the first edit, then the second `delay` seconds later from a deferred
# callback (so REAPER's timer, and REAmo's poll, run in between), and leaves
# the measured gap in an ExtState.
EDIT_PAIR = """
local function item(ti) return reaper.GetTrackMediaItem(reaper.GetTrack(0, ti), 0) end
reaper.DeleteExtState("rv1-191", "gap", false)
local t0 = reaper.time_precise()
do local it = item(%d); %s end
reaper.UpdateArrange()
local function second()
  if reaper.time_precise() - t0 < %f then reaper.defer(second) return end
  do local it = item(%d); %s end
  reaper.UpdateArrange()
  reaper.SetExtState("rv1-191", "gap", string.format("%%.3f", reaper.time_precise() - t0), false)
end
second()
"""


def edit_pair(first, second, delay):
    reaper(EDIT_PAIR % (pk.track_index(first[0]), first[1], delay, pk.track_index(second[0]), second[1]))
    deadline = time.time() + 5
    while time.time() < deadline:
        gap = reaper('return reaper.GetExtState("rv1-191", "gap")')
        if gap:
            return float(gap)
        time.sleep(0.05)
    raise AssertionError("the second edit never ran")


with Client() as c:
    c.wait_event("items")
    pk.subscribe_all(c)
    # Subscribing sends the phone its tiles once. The tracks are new to
    # REAmo's change check, but that is no change to send anyone.
    c.drain(1.0)
    assert len(c.binary) == 1, f"{len(c.binary)} peaks frames after one subscribe"
    bad, evidence = [], {}
    for label, first, second, delay, after in PAIRS:
        # A quiet second first, so the first edit's frame isn't itself held
        # back by the rate limit.
        pk.drain_until_quiet(c)
        n = len(c.binary)
        gap = edit_pair(first, second, delay)
        pk.drain_until_quiet(c)
        tiles = pk.tiles_since(c, n)
        print(f"{label}: second edit {gap * 1000:.0f} ms after the first, {len(c.binary) - n} peaks frames since")
        profiles, b = pk.compare(tiles, list(after))
        evidence[label] = profiles
        for name, want in after.items():
            got = profiles[name][1]["max"][0]
            assert pk.near(got, want), f"REAPER's peaks for {name!r} after {label}: {pk.fmt(got)}"
        bad += [f"{label}: the watching phone's " + line for line in b]
    pk.save("profiles", evidence)
    pk.screenshot_arrange("reaper-arrange")
    assert not bad, "\n".join(bad)
