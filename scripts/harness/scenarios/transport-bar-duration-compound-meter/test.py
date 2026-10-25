"""tempo/getBarDuration reports the length REAPER gives the bar at that time, in every meter.

Fixture: 4/4 @120 from 0 s, 6/8 @90 from 8 s, 7/8 @140 from 20 s. REAPER's
TimeMap_GetMeasureInfo is the oracle for each bar's start and end.
"""
from reamo_client import Client, reaper

MEASURE_AT = """
local t = %r
local _, measure = reaper.TimeMap2_timeToBeats(0, t)
local start = reaper.TimeMap_GetMeasureInfo(0, measure)
local nxt = reaper.TimeMap_GetMeasureInfo(0, measure + 1)
local _, _, _, num, denom, bpm = reaper.TimeMap_GetMeasureInfo(0, measure)
return {nxt - start, num, denom, bpm}
"""

with Client() as c:
    c.wait_event("transport")
    problems = []
    for t in (1.0, 9.0, 21.0):
        dur, num, denom, bpm = reaper(MEASURE_AT % t)
        r = c.command("tempo/getBarDuration", time=t)
        assert r["success"], r
        p = r["payload"]
        print(f"  t={t:5}: REAPER bar {dur:.4f}s ({num}/{denom} @{bpm:g}); client {p}")
        if abs(p["duration"] - dur) > 1e-6:
            problems.append(f"t={t}: getBarDuration {p['duration']:.4f}s, REAPER's bar is {dur:.4f}s ({num}/{denom} @{bpm:g})")
        if (p["timesigNum"], p["timesigDenom"]) != (num, denom):
            problems.append(f"t={t}: meter {p['timesigNum']}/{p['timesigDenom']}, REAPER {num}/{denom}")
    assert not problems, "\n".join(problems)
