"""Someone edits the notes in REAPER and, within the same second, a second
phone opens the Notes view (subscribes). The phone that was already watching
must still be told the notes changed.

Notes are polled at 1 Hz, so a subscribe that lands between the edit and
the next poll is the case pinned here (it nearly always does: the
subscribe follows the edit by a few milliseconds).
"""
import time

from reamo_client import Client, reaper

with Client() as watcher, Client() as newcomer:
    assert watcher.command("projectNotes/subscribe")["success"]
    watcher.drain(1.5)
    watcher.events.clear()
    reaper('reaper.GetSetProjectNotes(0, true, "Changed in REAPER")')
    t = time.time()
    r = newcomer.command("projectNotes/subscribe")
    assert r["success"] and r["payload"]["notes"] == "Changed in REAPER", r
    print(f"newcomer subscribed {1000 * (time.time() - t):.0f} ms after the edit")
    deadline = time.time() + 3
    while time.time() < deadline and not watcher.latest_event("projectNotesChanged"):
        watcher.drain(0.2)
    assert watcher.latest_event("projectNotesChanged"), \
        "the watching phone was never told about the REAPER edit"
