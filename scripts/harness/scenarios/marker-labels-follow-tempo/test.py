"""Marker and region bar labels follow the tempo map even when their times don't move.

In a project whose timebase is Time, a tempo change, a meter change or a new
start measure relabels every marker without moving it. Clients must get the
new labels, and they must match what REAPER itself shows.
"""
import time

from reamo_client import Client, reaper

LABELS = """
local out = {}
local i = 0
while true do
  local ok, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers(i)
  if ok == 0 then break end
  if isrgn then
    out[name] = {reaper.format_timestr_pos(pos, "", 2), reaper.format_timestr_pos(rgnend, "", 2)}
  else
    out[name] = reaper.format_timestr_pos(pos, "", 2)
  end
  i = i + 1
end
return out
"""


def shown(c):
    markers = c.latest_event("markers")["payload"]["markers"]
    regions = c.latest_event("regions")["payload"]["regions"]
    out = {m["name"]: m["positionBars"] for m in markers}
    out.update({r["name"]: [r["startBars"], r["endBars"]] for r in regions})
    times = sorted(m["position"] for m in markers) + [x for r in regions for x in (r["start"], r["end"])]
    return out, times


def expect_reaper_labels(c, step):
    deadline = time.time() + 2  # medium tier polls markers at 5 Hz
    while True:
        c.drain(0.2)
        want = reaper(LABELS)  # re-read: a fired command applies on a later tick
        got, times = shown(c)
        if got == want or time.time() > deadline:
            break
    print(f"{step:>22}: {got}")
    assert times == [4, 8, 4, 12], f"{step}: markers moved, the fixture is not time-locked: {times}"
    assert got == want, f"{step}: clients show {got}, REAPER shows {want}"


with Client() as c:
    for name in ("markers", "regions"):  # only re-sent when they change: keep the snapshots
        c.events.append((name, c.wait_event(name)))
    expect_reaper_labels(c, "120 BPM 4/4")
    assert shown(c)[0]["Verse"] == "3.1.00"

    c.fire("tempo/set", bpm=60)  # fire-and-forget, as the UI sends it
    expect_reaper_labels(c, "60 BPM (client)")
    assert shown(c)[0]["Verse"] == "2.1.00"

    # The user adds a 3/4 meter change at 2 s in REAPER.
    reaper("reaper.SetTempoTimeSigMarker(0, -1, 2, -1, -1, 60, 3, 4, false); reaper.UpdateTimeline()")
    expect_reaper_labels(c, "3/4 from 2 s (REAPER)")

    # Same markers, but this project starts at measure -5.
    reaper('reaper.Main_openProject("noprompt:/tmp/time-timebase-start-5.RPP")')
    expect_reaper_labels(c, "start measure -5")
    assert shown(c)[0]["Verse"] == "-2.1.00"
