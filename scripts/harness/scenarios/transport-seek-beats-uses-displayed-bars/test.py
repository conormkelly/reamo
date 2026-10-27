"""transport/seekBeats lands on the bar.beat the user reads on REAPER's ruler.

The project starts at measure -5 and has a 6/8 section from 8 s and 7/8
from 20 s. Seeking to "bar B, beat N" must put the edit cursor where REAPER
itself places that label (parse_timestr_pos mode 2), as tempo/barsToTime
already does: in a 6/8 bar, beat 4 is the fourth eighth note.
"""
import time

from reamo_client import Client, reaper

CASES = [  # (bar, beat) as displayed, every section of the fixture
    (-4, None), (-2, None), (-2, 3), (1, None), (1, 4), (3, 2), (7, 5),
]

with Client() as c:
    c.wait_event("transport")
    problems = []
    for bar, beat in CASES:
        lbl = f"{bar}.{beat or 1}.00"
        want = reaper(f'return reaper.parse_timestr_pos("{lbl}", 2)')
        # Control: the conversion the UI awaits already honours the offset.
        bt = c.command("tempo/barsToTime", bar=bar, beat=beat or 1)["payload"]["time"]
        params = {"bar": bar} if beat is None else {"bar": bar, "beat": beat}
        c.fire("transport/seekBeats", **params)
        deadline = time.time() + 2
        while True:
            c.drain(0.1)
            got = reaper("return reaper.GetCursorPosition()")
            if abs(got - want) < 1e-6 or time.time() > deadline:
                break
        shown = reaper(f'return reaper.format_timestr_pos({got!r}, "", 2)')
        print(f"  seekBeats {params}: cursor {got:8.4f}s ({shown}), REAPER's {lbl} = {want:8.4f}s, barsToTime = {bt:8.4f}s")
        if abs(got - want) > 1e-6:
            problems.append(f"seekBeats {params} -> {got:.4f}s ({shown}), want {want:.4f}s ({lbl})")
    assert not problems, "\n".join(problems)
