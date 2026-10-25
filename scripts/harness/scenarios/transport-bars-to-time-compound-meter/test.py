"""tempo/barsToTime converts a bar.beat.ticks label to REAPER's own time in every meter.

The UI awaits this to place regions typed as bar.beat.ticks (AddRegionModal,
RegionInfoBar). In a 6/8 or 7/8 bar the beat is an eighth note, so
"1.4.00" is three eighths into bar 1. REAPER's parse_timestr_pos (mode 2)
is the oracle; timeToBeats -> barsToTime must also round-trip.
"""
from reamo_client import Client, reaper

# (bar, beat, ticks) as displayed. Fixture: start measure -5, 4/4 @120 from
# 0 s (bars -4..-1), 6/8 @90 from 8 s (bars 0..5), 7/8 @140 from 20 s (6..).
CASES = [(-4, 1, 0), (-3, 3, 50), (0, 1, 0), (1, 4, 0), (3, 2, 0), (4, 6, 50), (6, 1, 0), (7, 5, 0), (8, 7, 25)]

with Client() as c:
    c.wait_event("transport")
    # How REAPER's own conversion reads tpos when a measure is given.
    probe = reaper("return reaper.TimeMap2_beatsToTime(0, 3, 5)")  # measure index 5 = bar 1 (6/8 @90, at 10 s)
    print(f"  TimeMap2_beatsToTime(tpos=3, measure 5) = {probe:.4f}s (11.0 = tpos in eighths, 12.0 = in quarter notes)")
    problems = []
    for bar, beat, ticks in CASES:
        lbl = f"{bar}.{beat}.{ticks:02d}"
        want = reaper(f'return reaper.parse_timestr_pos("{lbl}", 2)')
        r = c.command("tempo/barsToTime", bar=bar, beat=beat, ticks=ticks)
        assert r["success"], r
        got = r["payload"]["time"]
        back = c.command("tempo/timeToBeats", time=want)["payload"]["bars"]
        print(f"  {lbl:>8}: barsToTime {got:9.4f}s  REAPER {want:9.4f}s  timeToBeats(REAPER) -> {back}")
        if abs(got - want) > 1e-6:
            problems.append(f"barsToTime {lbl} = {got:.4f}s, REAPER places it at {want:.4f}s")
        if back != lbl:
            problems.append(f"timeToBeats({want:.4f}) = {back}, REAPER reads {lbl}")
    assert not problems, "\n".join(problems)
