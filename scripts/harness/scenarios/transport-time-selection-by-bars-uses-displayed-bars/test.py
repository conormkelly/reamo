"""timeSelection/setByBars selects the bars the user reads on REAPER's ruler.

Same fixture as transport-seek-beats-uses-displayed-bars: start measure -5,
6/8 from 8 s, 7/8 from 20 s. The selection must span REAPER's own positions
for the requested labels (parse_timestr_pos mode 2).
"""
import time

from reamo_client import Client, reaper

CASES = [  # (startBar, endBar, startBeat, endBeat) as displayed
    (-4, -2, None, None),
    (-1, 2, None, None),
    (1, 2, 4, 1),
    (6, 8, 3, 5),
]

with Client() as c:
    c.wait_event("transport")
    problems = []
    for sb, eb, sbeat, ebeat in CASES:
        ls, le = f"{sb}.{sbeat or 1}.00", f"{eb}.{ebeat or 1}.00"
        want = (reaper(f'return reaper.parse_timestr_pos("{ls}", 2)'),
                reaper(f'return reaper.parse_timestr_pos("{le}", 2)'))
        params = {"startBar": sb, "endBar": eb}
        if sbeat is not None:
            params.update(startBeat=sbeat, endBeat=ebeat)
        c.fire("timeSelection/setByBars", **params)
        deadline = time.time() + 2
        while True:
            c.drain(0.1)
            got = reaper("local s, e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false); return {s, e}")
            if all(abs(g - w) < 1e-6 for g, w in zip(got, want)) or time.time() > deadline:
                break
        ev = c.latest_event("transport")["payload"]["timeSelection"]
        print(f"  setByBars {params}: REAPER selection {got[0]:.4f}-{got[1]:.4f}, want {want[0]:.4f}-{want[1]:.4f} ({ls}-{le}); event {ev}")
        if not all(abs(g - w) < 1e-6 for g, w in zip(got, want)):
            problems.append(f"setByBars {params} selected {got[0]:.4f}-{got[1]:.4f}s, want {ls}-{le} = {want[0]:.4f}-{want[1]:.4f}s")
        elif abs(ev["start"] - got[0]) > 1e-3 or abs(ev["end"] - got[1]) > 1e-3:
            problems.append(f"setByBars {params}: transport event shows {ev}, REAPER {got}")
    assert not problems, "\n".join(problems)
