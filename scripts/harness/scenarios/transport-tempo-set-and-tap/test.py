"""tempo/set accepts exactly REAPER's tempo range; tempo/tap at a steady 100 BPM sets about 100 BPM.

REAPER's own range is 1..960 BPM (SetCurrentBPM clamps there). Values
outside it must be rejected without changing the tempo; values inside must
land exactly and show in the transport event. Tapping on the phone every
0.6 s (fire-and-forget, as QuickActionsPanel does) must end near 100 BPM.
"""
import time

from reamo_client import Client, reaper


def tempo_settles(c, want):
    deadline = time.time() + 2
    while True:
        c.drain(0.1)
        got = reaper("return reaper.Master_GetTempo()")
        shown = c.latest_event("transport")["payload"]["bpm"]
        if (abs(got - want) < 1e-6 and abs(shown - want) < 0.01) or time.time() > deadline:
            return got, shown


with Client() as c:
    c.events.append(("transport", c.wait_event("transport")))  # only re-sent when it changes
    problems = []
    for bpm in (960, 2, 133.33, 1):
        # On success the handler sends no response (the UI fires it), so an
        # error response is the only reply to wait for.
        r = c.command("tempo/set", timeout=1.0, bpm=bpm) if bpm < 2 else {"success": True}
        if bpm >= 2:
            c.fire("tempo/set", bpm=bpm)
        got, shown = tempo_settles(c, bpm)
        print(f"  tempo/set {bpm}: response {r.get('error') or 'none'}; REAPER {got}, shown {shown}")
        if abs(got - bpm) > 1e-6:
            problems.append(f"tempo/set {bpm} (inside REAPER's 1..960) left REAPER at {got} ({r.get('error')})")
    reaper("reaper.SetCurrentBPM(0, 120, false)")
    tempo_settles(c, 120)
    for bpm in (0, 0.5, 961, -120):
        try:
            r = c.command("tempo/set", timeout=1.0, bpm=bpm)
        except TimeoutError:
            r = {"success": True, "error": "no response"}
        got, _ = tempo_settles(c, 120)
        print(f"  tempo/set {bpm}: response {r.get('error') or 'ok'}; REAPER {got}")
        if r["success"] or abs(got - 120) > 1e-6:
            problems.append(f"tempo/set {bpm} should be rejected and leave 120, got {r} and REAPER {got}")

    for _ in range(8):
        c.fire("tempo/tap")
        c.drain(0.6)
    got, shown = tempo_settles(c, -1)
    print(f"  after 8 taps 0.6 s apart: REAPER {got:.2f} BPM, shown {shown}")
    if not 95 <= got <= 105:
        problems.append(f"tapping at 100 BPM set {got:.2f} BPM")
    assert not problems, "\n".join(problems)
