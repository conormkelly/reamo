"""An edit undone moments later reaches phones too, so they never keep showing it.

The user deletes a region and immediately undoes (and redoes) it from the
phone, or adds a tempo marker in REAPER and hits Ctrl+Z within a second.
The phone must end up showing exactly what REAPER has: the region list
and the tempo map. An edit and its undo landing between two regular polls
is the case that matters.
"""
import time

from reamo_client import Client, reaper


def wait_shown(c, step, event, count, shown, timeout=3.0):
    deadline = time.time() + timeout
    while True:
        c.drain(0.2)
        want = reaper(count)
        ev = c.latest_event(event)
        got = shown(ev) if ev else None
        if got == want:
            return
        if time.time() > deadline:
            raise AssertionError(f"{step}: phone shows {got}, REAPER has {want}")


REGIONS = "local _, _, r = reaper.CountProjectMarkers(0); return r"
TEMPO = "return reaper.CountTempoTimeSigMarkers(0)"


def region_count(ev):
    return len(ev["payload"]["regions"])


def tempo_count(ev):
    return len(ev["payload"]["markers"])


with Client() as c:
    c.wait_event("trackSkeleton")
    c.drain(1.0)

    for attempt in range(4):
        c.fire("region/add", start=2.0 + attempt * 10, end=4.0 + attempt * 10, name=f"Take {attempt + 1}", color=0)
        wait_shown(c, f"region {attempt + 1} added", "regions", REGIONS, region_count)
        rid = max(r["id"] for r in c.latest_event("regions")["payload"]["regions"])
        c.fire("region/delete", id=rid)  # as RegionInfoBar sends it: "id" is the region number
        wait_shown(c, f"region {attempt + 1} deleted", "regions", REGIONS, region_count)
        c.command("undo/do")
        time.sleep(0.03 * (attempt + 1))
        c.command("redo/do")
        wait_shown(c, f"region {attempt + 1} delete undone and redone", "regions", REGIONS, region_count)
    print("regions: the phone follows a delete undone and redone back to back")

    for attempt in range(4):
        reaper(f"""
        reaper.Undo_BeginBlock2(0)
        reaper.SetTempoTimeSigMarker(0, -1, {attempt * 4}, -1, -1, 100, 0, 0, false)
        reaper.Undo_EndBlock2(0, "Insert tempo/time signature marker", -1)
        reaper.UpdateTimeline()
        """)
        wait_shown(c, f"tempo marker {attempt + 1} added", "tempoMap", TEMPO, tempo_count)
        c.command("undo/do")
        wait_shown(c, f"tempo marker {attempt + 1} undone", "tempoMap", TEMPO, tempo_count)
    print("tempo map: the phone follows a tempo marker undone within a second")

assert reaper("return true")
