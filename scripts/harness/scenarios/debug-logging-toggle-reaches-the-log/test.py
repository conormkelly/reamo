"""Extensions > REAmo > Debug Logging writes debug detail to the log until it's turned off.

A release logs at info. A user reproducing a problem turns debug on from
the menu, and per-command detail (logged at debug) must then reach
reamo.log; turned off, it must stop again. The menu's checkmark follows.
"""
from reamo_client import Client, reaper

READ_LOG = "local f = io.open(reaper.GetResourcePath() .. '/Logs/reamo.log'); local s = f:read('a'); f:close(); return s"
TOGGLE = 'reaper.Main_OnCommand(reaper.NamedCommandLookup("_REAMO_DEBUG_LOGGING"), 0)'
STATE = 'return reaper.GetToggleCommandState(reaper.NamedCommandLookup("_REAMO_DEBUG_LOGGING"))'


def debug_lines(log):
    return sum(1 for line in log.splitlines() if "] DEBUG " in line)


with Client(timeout=10) as c:
    c.wait_event("trackSkeleton")
    base = reaper(READ_LOG)
    level = "debug" if "log level debug" in base.splitlines()[0] else "info"
    print(f"session level: {level}")

    assert reaper(STATE) == (1 if level == "debug" else 0), reaper(STATE)
    reaper(TOGGLE)
    assert reaper(STATE) == 1, reaper(STATE)
    c.command("marker/add", position=1.0)  # logs "Added marker" at debug
    c.drain(0.5)
    on = reaper(READ_LOG)
    assert "Log level debug until REAPER restarts" in on, on[-2000:]
    assert debug_lines(on) > debug_lines(base), "no debug detail after turning debug on"

    reaper(TOGGLE)
    assert reaper(STATE) == 0, reaper(STATE)
    off = reaper(READ_LOG)
    assert "Log level info until REAPER restarts" in off or level != "info", off[-2000:]
    c.command("marker/add", position=2.0)
    c.drain(0.5)
    after = reaper(READ_LOG)
    if level == "info":
        assert debug_lines(after) == debug_lines(off), "debug detail kept coming after turning it off"
