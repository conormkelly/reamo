"""Two people have the Notes view open (phone + tablet). One saves an edit:
the other must be told the notes changed (projectNotesChanged), exactly as
it is told when someone edits the notes in REAPER itself.
"""
import json
import time
import types

import reamo_client
from reamo_client import Client, reaper

# Browser-shaped JSON: compact, raw UTF-8 (JSON.stringify does not \\u-escape).
reamo_client.json = types.SimpleNamespace(
    dumps=lambda o: json.dumps(o, separators=(",", ":"), ensure_ascii=False), loads=json.loads, load=json.load)


def wait_changed(c, what, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        c.drain(0.2)
        ev = c.latest_event("projectNotesChanged")
        if ev:
            return ev["payload"]["hash"]
    raise AssertionError(f"{what}: no projectNotesChanged within {timeout} s (notes are polled at 1 Hz)")


with Client() as phone, Client() as tablet:
    for c in (phone, tablet):
        r = c.command("projectNotes/subscribe")
        assert r["success"], r
    phone.drain(1.5); tablet.drain(1.5)
    phone.events.clear(); tablet.events.clear()

    # Control: an edit made in REAPER reaches both.
    reaper('reaper.GetSetProjectNotes(0, true, "Edited in REAPER")')
    wait_changed(phone, "REAPER edit -> phone")
    wait_changed(tablet, "REAPER edit -> tablet")
    phone.events.clear(); tablet.events.clear()

    # The phone saves an edit; the tablet must hear about it.
    r = phone.command("projectNotes/set", notes="Edited on the phone")
    assert r["success"], r
    assert reaper("return select(1, reaper.GetSetProjectNotes(0, false, ''))") == "Edited on the phone"
    h = wait_changed(tablet, "phone edit -> tablet")
    assert h == r["payload"]["hash"], (h, r["payload"]["hash"])
print("an edit from one client reaches the other")
