"""Toggle buttons on the phone track REAPER's own toggle state, both ways.

A user toggles repeat / metronome in REAPER: every subscribed client gets an
actionToggleState change with REAPER's value. A client toggles it: REAPER
changes. Unsubscribing one client must not silence another that still holds
the same action. Unknown names fail cleanly.
"""
import time

from reamo_client import Client, reaper

REPEAT = 1068     # Transport: Toggle repeat
METRONOME = 40364  # Options: Toggle metronome


def state(cmd):
    return reaper(f"return reaper.GetToggleCommandState({cmd})")


def toggle_changes(c):
    out = {}
    for name, msg in c.events:
        if name == "actionToggleState":
            for ch in msg["payload"]["changes"]:
                out[(ch["s"], ch["c"])] = ch["v"]
    return out


def wait_change(c, cmd, want, what):
    deadline = time.time() + 3
    while time.time() < deadline:
        c.drain(0.2)
        if toggle_changes(c).get((0, cmd)) == want:
            return
    raise AssertionError(f"{what}: client never saw {cmd} -> {want}; saw {toggle_changes(c)}")


with Client() as a, Client() as b:
    a.wait_event("transport"); b.wait_event("transport")
    keys = [{"c": REPEAT, "s": 0}, {"c": METRONOME, "s": 0}]
    ra = a.command("actionToggleState/subscribe", actions=keys)
    rb = b.command("actionToggleState/subscribe", actions=[{"c": REPEAT, "s": 0}])
    assert ra["success"] and rb["success"], (ra, rb)
    initial = {(s["s"], s["c"]): s["v"] for s in ra["payload"]["states"]}
    assert initial == {(0, REPEAT): state(REPEAT), (0, METRONOME): state(METRONOME)}, initial

    # The user toggles repeat in REAPER.
    before = state(REPEAT)
    reaper(f"reaper.Main_OnCommand({REPEAT}, 0)")
    assert state(REPEAT) == 1 - before
    wait_change(a, REPEAT, 1 - before, "REAPER toggle -> client a")
    wait_change(b, REPEAT, 1 - before, "REAPER toggle -> client b")

    # A client toggles the metronome: REAPER follows, the change is broadcast.
    m_before = state(METRONOME)
    r = a.command("action/execute", commandId=METRONOME)
    assert r["success"], r
    deadline = time.time() + 2
    while state(METRONOME) == m_before and time.time() < deadline:
        time.sleep(0.05)
    assert state(METRONOME) == 1 - m_before, "action/execute did not toggle the metronome"
    wait_change(a, METRONOME, 1 - m_before, "client toggle -> client a")
    r = a.command("action/getToggleState", commandId=METRONOME)
    assert r["success"] and r["payload"]["state"] == 1 - m_before, r

    # a unsubscribes from repeat; b still holds it and must keep getting changes.
    assert a.command("actionToggleState/unsubscribe", actions=[{"c": REPEAT, "s": 0}])["success"]
    a.events.clear(); b.events.clear()
    before = state(REPEAT)
    reaper(f"reaper.Main_OnCommand({REPEAT}, 0)")
    wait_change(b, REPEAT, 1 - before, "after a unsubscribed, b")
    # (Changes are broadcast to every client, subscribed or not, so a seeing
    # this one too is by design of pollToggleSubscriptions, not asserted here.)

    # Unknown named actions: a clean error, not a hang.
    r = a.command("action/executeByName", name="_REAMO_NO_SUCH_ACTION")
    assert not r["success"] and r["error"]["code"] == "NOT_FOUND", r
    r = a.command("action/getToggleState", name="_REAMO_NO_SUCH_ACTION")
    assert not r["success"] and r["error"]["code"] == "NOT_FOUND", r
    r = a.command("actionToggleState/subscribe", namedActions=[{"n": "_REAMO_NO_SUCH_ACTION", "s": 0}])
    assert not r["success"], f"subscribing only to unknown names should fail: {r}"

    # (action/getActions is pinned by protocol-large-response-arrives-intact.)
print("toggle state follows REAPER both ways")
