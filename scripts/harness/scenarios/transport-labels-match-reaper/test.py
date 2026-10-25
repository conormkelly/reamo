"""The transport event's bar.beat label is REAPER's own, stopped and during playback.

In a project with a start measure of -5 and meter changes (4/4, 6/8, 7/8 at
140 BPM), every cursor position the user seeks to, and every playback tick
('tt' bbt) under REAPER's dummy audio device, must read as REAPER's ruler
does (format_timestr_pos mode 2).
"""
import time

from reamo_client import Client, reaper


def label(t):
    return reaper(f'return reaper.format_timestr_pos({t!r}, "", 2)')


with Client() as c:
    c.wait_event("transport")
    assert reaper("return reaper.CountTempoTimeSigMarkers(0)") == 3

    # Stopped: seek to positions in each section, including a hair before bar lines.
    problems = []
    for pos in (0.0, 0.25, 1.999999, 3.5, 7.9999999, 8.0, 9.3, 12.5, 19.99, 20.0, 23.7):
        c.fire("transport/seek", position=pos)
        deadline = time.time() + 2
        got = None
        while time.time() < deadline:
            c.drain(0.1)
            ev = c.latest_event("transport")["payload"]
            if abs(ev["cursorPosition"] - pos) < 0.002:
                got = ev["positionBeats"]
                break
        want = label(reaper("return reaper.GetCursorPosition()"))
        print(f"  seek {pos:>10}: client {got!s:>9}  REAPER {want}")
        if got != want:
            problems.append(f"seek {pos}: client shows {got}, REAPER shows {want}")

    # Playing: run across the 4/4 -> 6/8 boundary at 8 s.
    c.fire("transport/seek", position=6.5)
    c.drain(0.3)
    c.events.clear()
    c.fire("transport/play")
    c.drain(2.5)
    c.fire("transport/stop")
    ticks = [m["payload"] for n, m in c.events if n == "tt"]
    print(f"  playback ticks: {len(ticks)}, {ticks[0]['bbt'] if ticks else None} .. {ticks[-1]['bbt'] if ticks else None}")
    assert len(ticks) > 20, f"expected ~30 Hz ticks during playback, got {len(ticks)}"
    bad = 0
    for tk in ticks:
        p = tk["p"]  # truncated to ms; the label was computed from the exact position
        if tk["bbt"] not in (label(p), label(p + 0.001)):
            bad += 1
            if bad <= 5:
                problems.append(f"playing p={p}: client bbt {tk['bbt']}, REAPER {label(p)}..{label(p + 0.001)}")
    if bad > 5:
        problems.append(f"... {bad} playback ticks disagree in total")
    assert not problems, "\n".join(problems)
