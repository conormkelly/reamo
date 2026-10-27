"""timesig/set changes the meter the user hears and sees, also in a project with a tempo map.

The quick-actions panel sends timesig/set and closes its dialog on success.
In a song whose tempo map already has markers (4/4 from 0 s, 6/8 from 8 s),
setting 3/4 with the cursor at the top must change the meter REAPER
uses there (TimeMap_GetTimeSigAtTime) and the transport event must show
it; if the command can't do that, it must say so instead of succeeding.
"""
import time

from reamo_client import Client, reaper

LABEL_2 = 'return reaper.format_timestr_pos(2, "", 2)'
METER_AT_0 = "local num, den, bpm = reaper.TimeMap_GetTimeSigAtTime(0, 0); return {num, den, bpm}"

with Client() as c:
    c.drain(0.5)
    assert reaper("return reaper.CountTempoTimeSigMarkers(0)") == 2
    print("  before:", reaper(METER_AT_0), c.latest_event("transport")["payload"]["timeSignature"])
    r = c.command("timesig/set", numerator=3, denominator=4)
    print("  timesig/set 3/4 ->", r)
    deadline = time.time() + 2
    while True:
        c.drain(0.2)
        meter = reaper(METER_AT_0)
        shown = c.latest_event("transport")["payload"]["timeSignature"]
        if meter[:2] == [3, 4] or time.time() > deadline:
            break
    print(f"  after: REAPER at 0 s {meter}, transport shows {shown}, "
          f"project default {reaper('return reaper.GetProjectTimeSignature2(0)')}, label at 2 s {reaper(LABEL_2)}")
    problems = []
    if not r["success"]:
        problems.append(f"timesig/set 3/4 failed: {r}")
    if meter[:2] != [3, 4]:
        problems.append(f"timesig/set 3/4 succeeded, but REAPER's meter at the cursor is still {meter[0]}/{meter[1]}")
    if [shown["numerator"], shown["denominator"]] != [3, 4]:
        problems.append(f"transport shows {shown['numerator']}/{shown['denominator']} after timesig/set 3/4")

    # The user is in the 6/8 section (cursor at 10 s) and taps 6/8 again: the
    # tempo map must not change under them.
    MARKERS = ("local o = {} for i = 0, reaper.CountTempoTimeSigMarkers(0) - 1 do "
               "local _, t, _, _, bpm, n, d = reaper.GetTempoTimeSigMarker(0, i) o[#o + 1] = {t, bpm, n, d} end return o")
    reaper("reaper.SetEditCurPos(10, false, false)")
    before = reaper(MARKERS)
    r = c.command("timesig/set", numerator=6, denominator=8)
    c.drain(0.5)
    after = reaper(MARKERS)
    bpm10 = reaper("local _, _, bpm = reaper.TimeMap_GetTimeSigAtTime(0, 10); return bpm")
    print(f"  timesig/set 6/8 at 10 s -> {r.get('error') or 'ok'}; tempo markers {before} -> {after}; tempo at 10 s {bpm10}")
    if after != before:
        problems.append(f"timesig/set 6/8 inside the 6/8 section rewrote the tempo map: {before} -> {after} (tempo at 10 s now {bpm10})")
    assert not problems, "\n".join(problems)
