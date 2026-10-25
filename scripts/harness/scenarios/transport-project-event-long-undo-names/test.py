"""The project event (undo/redo, repeat, metronome, dirty) still reaches clients when
undo descriptions and the project path are long.

A saved project in a deep folder, plus undo/redo descriptions of the length
REAmo itself writes ("REAmo: FX bypass toggle: Track N <name>: <fx name>",
each capped at 255 bytes), must not stop the project event. Then a change
made in REAPER (metronome on) must still reach a connected client, and a
newly connected client must still get the project snapshot.
"""
import json
import time

from reamo_client import Client, reaper

TRACK = 'Lead Vocal Double "Harmony" (Bridge, take 3)'
FX = "VST3: FabFilter Pro-Q 3 (FabFilter) [Mid/Side, Linear Phase] \u2014 preset \"Vocal Air & Presence\""
UNDO_A = f"REAmo: FX bypass toggle: Track 1 {TRACK}: {FX}"[:255]
UNDO_B = f"REAmo: FX enable toggle: Track 1 {TRACK}: {FX} (Sidechain)"[:255]


def wait_project(c, pred, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        c.drain(0.2)
        ev = c.latest_event("project")
        if ev and pred(ev["payload"]):
            return ev["payload"]
    return None


DIR = "/tmp/Music/REAPER Projects/2026 Album Sessions/07 - Midnight Train to Somewhere (Alt Version)"
PATH = DIR + "/07 - Midnight Train to Somewhere (Alt Version) - final mix v3.RPP"
reaper(f"""
os.execute('mkdir -p "{DIR}"')
local f = io.open({json.dumps(PATH)}, "w")
f:write('<REAPER_PROJECT 0.1 "7.0" 0\\n  TEMPO 120 4 4 0\\n>\\n')
f:close()
reaper.Main_openProject({json.dumps("noprompt:" + PATH)})
harness.track({json.dumps(TRACK)})
""")

with Client() as c:
    p = wait_project(c, lambda p: p["projectPath"] == PATH)
    assert p, "no project event with the saved path"
    print(f"  path ({len(p['projectPath'])} bytes): {p['projectPath']}")

    # Three edits in REAPER, each with a long undo description, then undo one
    # so both canUndo and canRedo are long.
    for i, desc in enumerate((UNDO_A, UNDO_B, UNDO_A)):
        reaper(f"reaper.Undo_BeginBlock2(0); reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, 0), 'B_MUTE', {(i + 1) % 2}); "
               f"reaper.Undo_EndBlock2(0, {json.dumps(desc, ensure_ascii=False)}, -1)")
    r = c.command("undo/do")
    assert r["success"], r
    want_undo = reaper("return reaper.Undo_CanUndo2(0)")
    want_redo = reaper("return reaper.Undo_CanRedo2(0)")
    print(f"  REAPER canUndo={want_undo!r}\n         canRedo={want_redo!r}")
    assert want_undo and want_redo and len(want_undo) > 100 and len(want_redo) > 100
    problems = []
    p = wait_project(c, lambda p: p["canUndo"] == want_undo and p["canRedo"] == want_redo)
    if p:
        size = len(json.dumps(c.latest_event("project"), separators=(",", ":"), ensure_ascii=False).encode())
        print(f"  project event: {size} bytes")
    else:
        last = c.latest_event("project")["payload"]
        problems.append(f"after undo/do the project event still shows canUndo={last['canUndo']!r}, canRedo={last['canRedo']!r}")

    # A change made in REAPER must still propagate.
    reaper("reaper.Main_OnCommand(40364, 0)")  # Options: Toggle metronome
    assert reaper("return reaper.GetToggleCommandState(40364)") == 1
    if not wait_project(c, lambda p: p["metronome"]["enabled"]):
        problems.append("metronome turned on in REAPER, but no project event arrived")

with Client() as late:
    late.wait_event("transport")
    p = wait_project(late, lambda p: True, timeout=1.5)
    if not p:
        problems.append("a newly connected client got no project event at all")
    elif not (p["metronome"]["enabled"] and p["canUndo"] == want_undo and p["canRedo"] == want_redo):
        problems.append(f"a newly connected client got a stale project snapshot: {p}")

assert not problems, "\n".join(problems)
