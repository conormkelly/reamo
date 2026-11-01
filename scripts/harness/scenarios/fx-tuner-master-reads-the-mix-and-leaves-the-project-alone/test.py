"""The master tuner reads the master mix from REAmo's audio hook, with the
native analyser, and leaves the project alone.

Items on a track play A3 (220 Hz) through the master for 2 s in every 3:
each note starting after silence is the "pluck" (an onset) the analyser
needs before it shows a note. Across open/close cycles, two phones on the master
and audio streaming running beside it:
- the tuner reads A3 within 2 cents, and its events carry the analyser's
  clarity and settling, stable, multiple and starting flags (starting
  while a new note's name is held back, its first ~0.1 s);
- a tone already sounding when the tuner opens shows no note until it is
  plucked again (accepted with the analyser: it needs an onset);
- REAPER's monitoring FX chain gets no plugin, and the project gets no
  undo point, no state change and no dirty flag;
- the tuner and the stream share the one audio hook: each keeps working
  when the other stops, and the hook goes when both have.

Against the master tuner on the monitoring-chain JSFX (before the
analyser), these fail: the plugin on the monitoring chain after open (the
only project-state check that tells the two apart), the subscribe payload
(threshold -60, an fxGuid), the missing clarity and flags, no stable
reading, a ringing note showing without a pluck, and every hook check.
These pass on both, and guard against regressions only: the A3 readings
and cents, silence between notes, the stream's frames, and the undo
history, state change count and dirty flag, which the monitoring chain
never touched either.
"""
import time

from reamo_client import Client, reaper

PERIOD, NOTE_LEN = 3.0, 2.0  # startup.lua's notes
PROJECT = """
local master = reaper.GetMasterTrack(0)
return {reaper.Undo_CanUndo2(0) or "", reaper.GetProjectStateChangeCount(0),
        reaper.IsProjectDirty(0), reaper.TrackFX_GetRecCount(master)}
"""

problems = []


def phase():
    """Where the audio being processed now is in the 3 s note-and-gap
    cycle: GetPlayPosition2, what the hook taps, not GetPlayPosition, what
    is heard, which trails it by the device's output latency."""
    return reaper("return reaper.GetPlayPosition2()") % PERIOD


def wait_phase(c, lo, hi):
    """Drain until the playhead is between lo and hi seconds into a cycle."""
    deadline = time.time() + 2 * PERIOD
    while not (lo <= phase() < hi):
        if time.time() > deadline:
            raise AssertionError("the transport isn't playing the notes")
        c.drain(0.05)


def project():
    undo, scc, dirty, monitoring_fx = reaper(PROJECT)
    return {"undo": undo, "state changes": scc, "dirty": dirty, "monitoring FX": monitoring_fx}


def status(c):
    r = c.command("audio/status")
    assert r["success"], r
    return r["payload"]


def hook_users(c):
    """Who holds the audio hook; {} from a REAmo that doesn't say."""
    return status(c).get("hookUsers", {})


def readings(c, seconds):
    """Every master tuner event's payload over the next `seconds`."""
    mark = len(c.events)
    c.drain(seconds)
    return [m["payload"] for name, m in c.events[mark:] if name == "tuner" and m["payload"]["trackGuid"] == "master"]


def shows_a3(c, what, want_cents=0.0):
    """Wait for the next note's start and read it to its end; returns the readings."""
    wait_phase(c, PERIOD - 0.75, PERIOD - 0.45)
    seen = readings(c, 0.45 + NOTE_LEN - 0.2)
    notes = [p for p in seen if p["freq"] > 0]
    if not notes:
        problems.append(f"{what}: no note from the pluck; last events {seen[-3:]}")
        return seen
    last = notes[-1]
    if not (last["note"] == 57 and last["noteName"] == "A" and last["octave"] == 3
            and abs(last["freq"] - 220.0) < 0.3 and abs(last["cents"] - want_cents) < 2):
        problems.append(f"{what}: read {last}, not A3 at 220 Hz, {want_cents} cents")
    return seen


def subscribe_master(c, what):
    r = c.command("tuner/subscribe", trackGuid="master")
    if not r["success"]:
        problems.append(f"{what}: tuner/subscribe on the master failed: {r}")
        return None
    return r["payload"]


reaper("reaper.Main_SaveProject(0, false)")
before = project()
print("project before:", before)
assert before["dirty"] == 0 and before["monitoring FX"] == 0, before

with Client() as a:
    a.wait_event("trackSkeleton")
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    reaper("reaper.OnPlayButton()")

    # Open: nothing lands in the monitoring chain, and the analyser's
    # defaults come back.
    p = subscribe_master(a, "first open")
    print("subscribe:", p)
    now = project()
    if now["monitoring FX"] != 0:
        problems.append(f"opening the master tuner put {now['monitoring FX']} plugin(s) on REAPER's monitoring FX chain")
    if p and (p["trackGuid"], p["reference"], p["threshold"], p["fxGuid"]) != ("master", 440.0, -90.0, ""):
        problems.append(f"subscribe payload {p}: want reference 440, threshold -90 (the analyser's), no fxGuid")
    if not hook_users(a).get("tuner"):
        problems.append(f"the master tuner doesn't hold the audio hook: {status(a)}")

    seen = shows_a3(a, "first pluck")
    print("first pluck, last reading:", [r for r in seen if r["freq"] > 0][-1:])
    for key in ("clarity", "conf", "settling", "stable", "multiple", "starting"):
        if seen and key not in seen[-1]:
            problems.append(f"tuner event has no {key}: {seen[-1]}")
    # The name is held back for about 0.1 s after the pluck: 2-4 readings at 30 Hz.
    if not any(r.get("starting") and r["freq"] == 0 for r in seen):
        problems.append(f"no reading said starting as the note began: {seen[:6]}")
    if not any(r.get("stable") for r in seen):
        problems.append(f"a steady 2 s note never read stable: {seen[-2:]}")
    if seen and "clarity" in seen[-1] and abs(seen[-1]["clarity"] - seen[-1]["conf"]) > 1e-9:
        problems.append(f"conf and clarity differ: {seen[-1]}")

    # Silence between notes: no note.
    # (Events go out only on a change, so the latest one is what shows.)
    wait_phase(a, NOTE_LEN + 0.6, PERIOD - 0.1)
    quiet = a.latest_event("tuner")["payload"]
    if quiet["freq"] != 0:
        problems.append(f"between notes the tuner still reads {quiet}")

    # Settings reach the analyser and come back in the events.
    assert a.command("tuner/setParam", trackGuid="master", param="reference", value=442)["success"]
    assert a.command("tuner/setParam", trackGuid="master", param="threshold", value=-50)["success"]
    # A3 with A4 = 442 is 221 Hz; 220 Hz is 1200 log2(220 / 221) = -7.85 cents from it.
    after = shows_a3(a, "pluck with A4 = 442", want_cents=-7.85)
    if not after or (after[-1]["referenceHz"], after[-1]["thresholdDb"]) != (442.0, -50):
        problems.append(f"setParam reference 442, threshold -50: events show {after[-1:]}")

    # A note already sounding when the tuner opens shows nothing until the next pluck.
    assert a.command("tuner/unsubscribe")["success"]
    wait_phase(a, 0.3, 0.6)
    subscribe_master(a, "reopen over a ringing note")
    ringing = [r for r in readings(a, NOTE_LEN - 0.7) if r["freq"] > 0]
    if ringing:
        problems.append(f"a note sounding when the tuner opened showed without a pluck: {ringing[0]}")
    shows_a3(a, "pluck after reopening")

    # Two phones on the master share it; the second keeps reading when the first leaves.
    with Client() as b:
        b.wait_event("trackSkeleton")
        pb = subscribe_master(b, "second phone")
        if pb and (pb["reference"], pb["threshold"]) != (440.0, -90.0):
            problems.append(f"the second phone sees settings {pb}, not the defaults the first one's reopen restored")
        shows_a3(b, "second phone, both open")
        assert a.command("tuner/unsubscribe")["success"]
        if not hook_users(b).get("tuner"):
            problems.append("the first phone leaving took the hook from the second")
        shows_a3(b, "second phone, alone")

        # Streaming beside the tuner.
        r = b.command("audio/startStream")
        assert r["success"], r
        st = status(b)
        print("tuner + stream:", st["hookRegistered"], st.get("hookUsers"))
        if st.get("hookUsers") != {"stream": True, "tuner": True}:
            problems.append(f"with tuner and stream both on, hook users are {st.get('hookUsers')}")
        frames = len(b.binary)
        shows_a3(b, "tuner beside the stream")
        if len(b.binary) == frames:
            problems.append("the stream sent no frames while the tuner ran")
        assert b.command("audio/stopStream")["success"]
        shows_a3(b, "tuner after the stream stopped")
        if not status(b)["hookRegistered"]:
            problems.append("stopping the stream unregistered the hook the tuner holds")

        # And the stream keeps going when the tuner closes.
        assert b.command("audio/startStream")["success"]
        assert b.command("tuner/unsubscribe")["success"]
        # Counted while a note sounds: the stream sends no silent frames,
        # and the 1 s gap between notes would hold none.
        wait_phase(b, 0.2, 0.5)
        frames = len(b.binary)
        b.drain(1.0)
        if len(b.binary) == frames:
            problems.append("the stream stopped when the tuner closed")
        if hook_users(b) != {"stream": True, "tuner": False}:
            problems.append(f"after the tuner closed: {hook_users(b)}")
        assert b.command("audio/stopStream")["success"]
        if status(b)["hookRegistered"]:
            problems.append(f"the hook stayed registered with nobody holding it: {status(b)}")

    # Open/close cycles.
    for i in range(5):
        subscribe_master(a, f"cycle {i}")
        a.drain(0.2)
        assert a.command("tuner/unsubscribe")["success"]
    reaper("reaper.OnStopButton()")
    a.drain(0.3)

after = project()
print("project after:", after)
for key in before:
    if after[key] != before[key]:
        problems.append(f"{key}: {before[key]!r} before the tuner, {after[key]!r} after")

assert not problems, "\n".join(problems)
print("ok: the master tuner read A3 from the hook, beside the stream, and left the project alone")
