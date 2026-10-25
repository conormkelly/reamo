"""Transport, navigation, repeat and time selection."""
from reamo_client import reaper
from tour import ANY, Mismatch, approx, op


def parse_bars(bars):
    """Time REAPER gives a displayed bar.beat label (what the user sees)."""
    return reaper(f'return reaper.parse_timestr_pos("{bars}", 2)')


@op("transport/seek", "transport/seek")
def _(t):
    t.ok("transport/seek", position=7.25)
    t.expect({"project.cursor": approx(7.25)})


@op("transport/seekBeats", "transport/seekBeats")
def _(t):
    # The user types the bar they see on the ruler.
    want = parse_bars("3.2.00")
    t.ok("transport/seekBeats", bar=3, beat=2)
    t.expect({"project.cursor": approx(want)})


@op("transport/goStart+goEnd", "transport/goStart", "transport/goEnd")
def _(t):
    t.ok("transport/goEnd")
    # REAPER's End key: the end of the last item. GetProjectLength would also
    # count regions, which run past the last item in this arrangement.
    end = max(it["pos"] + it["len"] for it in t.d["items"].values())
    t.expect({"project.cursor": approx(end)})
    t.digest()
    t.ok("transport/goStart")
    t.expect({"project.cursor": approx(0)})


@op("repeat/set+toggle", "repeat/set", "repeat/toggle")
def _(t):
    start = t.d["project"]["repeat"]
    t.ok("repeat/set", enabled=1)
    t.expect({"project.repeat": 1} if not start else {})
    t.digest()
    t.ok("repeat/toggle")
    t.expect({"project.repeat": 0})


@op("timeSelection: set, by bars, at cursor, go to edges, clear",
    "timeSelection/set", "timeSelection/setByBars", "timeSelection/setStartAtCursor",
    "timeSelection/setEndAtCursor", "timeSelection/goStart", "timeSelection/goEnd",
    "timeSelection/clear")
def _(t):
    t.ok("timeSelection/set", start=2.4, end=9.6)
    t.expect({"project.timesel.0": approx(2.4), "project.timesel.1": approx(9.6)})
    t.digest()
    # Bars as the user sees them on the ruler (a project may start at measure -5).
    a, b = parse_bars("-3.1.00"), parse_bars("-1.3.00")
    t.ok("timeSelection/setByBars", startBar=-3, endBar=-1, startBeat=1, endBeat=3)
    t.expect({"project.timesel.0": approx(a), "project.timesel.1": approx(b)})
    t.digest()
    t.ok("transport/seek", position=1.0)
    t.ok("timeSelection/setStartAtCursor")
    t.expect({"project.cursor": approx(1.0), "project.timesel.0": approx(1.0)})
    t.digest()
    t.ok("transport/seek", position=5.0)
    t.ok("timeSelection/setEndAtCursor")
    t.expect({"project.cursor": approx(5.0), "project.timesel.1": approx(5.0)})
    t.digest()
    t.ok("timeSelection/goEnd")
    t.expect({})
    t.ok("timeSelection/goStart")
    t.expect({"project.cursor": approx(1.0)})
    t.digest()
    t.ok("timeSelection/goEnd")
    t.expect({"project.cursor": approx(5.0)})
    t.digest()
    t.ok("timeSelection/clear")
    t.expect({"project.timesel.*": approx(0)})


@op("transport: play, pause, playPause, stop", "transport/play", "transport/pause",
    "transport/playPause", "transport/stop")
def _(t):
    t.ok("transport/seek", position=0)
    t.ok("transport/play")
    t.expect({"project.play": 1, "project.cursor": ANY})
    # While playing, the position reaches clients in tt ticks (the transport
    # event is sent on changes only) and advances with REAPER's play position.
    t.c.drain(1.0)
    tick = t.c.latest_event("tt")["payload"]
    playing_at = reaper("return reaper.GetPlayPosition()")
    if not 0.2 < tick["p"] <= playing_at + 0.05:
        raise Mismatch(f"tt while playing: {tick}; REAPER plays at {playing_at:.3f}")
    t.digest()
    # Whether pausing or stopping moves the edit cursor is a REAPER
    # preference. These commands run REAPER's own transport actions, so the
    # cursor goes where the user's own buttons would put it; converge() then
    # checks that clients show it there.
    t.ok("transport/pause")
    t.expect({"project.play": 2, "project.cursor": ANY})
    t.digest()
    t.ok("transport/playPause")
    t.expect({"project.play": 1, "project.cursor": ANY})
    t.digest()
    t.ok("transport/stop")
    t.expect({"project.play": 0, "project.cursor": ANY})


