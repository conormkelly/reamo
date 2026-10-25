"""Each mute / solo / exclusive-solo tap on the phone is its own undo step right
away: the user hears the change, presses Undo in REAPER, and exactly that tap is
reverted (not the edit before it, not several taps at once)."""
import time

from reamo_client import Client, reaper

STATE = """
local t = {}
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  t[#t + 1] = math.floor(reaper.GetMediaTrackInfo_Value(tr, "B_MUTE")) .. "/" .. math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_SOLO"))
end
return t
"""


def apply(c, cmd, **params):
    before = reaper(STATE)
    c.fire(cmd, **params)  # the UI fires these without waiting
    deadline = time.time() + 2
    while reaper(STATE) == before and time.time() < deadline:
        c.drain(0.1)
    c.drain(0.3)  # the user listens for a moment, then reaches for Undo
    return before, reaper(STATE)


with Client() as c:
    g = [t["g"] for t in c.wait_event("trackSkeleton")["payload"]["tracks"]]
    c.drain(1.2)  # GUIDs resolve after the first 1 Hz tick (tracks-guid-commands-right-after-connect)
    problems = []
    steps = [
        ("mute Kick", "track/setMute", {"trackGuid": g[1]}),
        ("solo Snare", "track/setSolo", {"trackGuid": g[2]}),
        ("solo Bass", "track/setSolo", {"trackGuid": g[3]}),
        ("exclusive Kick", "track/setSoloExclusive", {"trackGuid": g[1]}),
    ]
    for label, cmd, params in steps:
        before, after = apply(c, cmd, **params)
        undo_label = reaper("return reaper.Undo_CanUndo2(0) or ''")
        reaper("reaper.Main_OnCommand(40029, 0)")
        undone = reaper(STATE)
        print(f"{label:>15}: {before} -> {after}; Undo ({undo_label!r}) -> {undone}")
        if undone != before:
            problems.append(f"{label}: one Undo gave {undone}, want {before} (undo menu said {undo_label!r})")
        reaper("reaper.Main_OnCommand(40030, 0)")  # Redo, so the next tap builds on this one
        if reaper(STATE) != after:
            problems.append(f"{label}: Redo gave {reaper(STATE)}, want {after}")
    assert not problems, "\n".join(problems)
