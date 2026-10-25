"""Transport, navigation, repeat and time selection."""
from reamo_client import reaper
from tour import ANY, Mismatch, approx, op, play_position


def parse_bars(bars):
    """Time REAPER gives a displayed bar.beat label (what the user sees)."""
    return reaper(f'return reaper.parse_timestr_pos("{bars}", 2)')


def first_bar():
    """The bar the ruler shows at the project start (-4 when a project
    starts at measure -5, 1 by default)."""
    return int(reaper('return reaper.format_timestr_pos(0, "", 2)').split(".")[0])


@op("transport/seek", "transport/seek")
def _(t):
    t.ok("transport/seek", position=7.25)
    t.expect({"project.cursor": approx(7.25), **t.meter(7.25)})


@op("transport/seekBeats", "transport/seekBeats")
def _(t):
    # The user types the bar they see on the ruler.
    want = parse_bars("3.2.00")
    t.ok("transport/seekBeats", bar=3, beat=2)
    t.expect({"project.cursor": approx(want), **t.meter(want)})


@op("transport/goStart+goEnd", "transport/goStart", "transport/goEnd")
def _(t):
    t.ok("transport/goEnd")
    # REAPER's End key: the end of the last item, or the project start when
    # there is none. GetProjectLength would also count regions, which run
    # past the last item in the band session's arrangement.
    end = max((it["pos"] + it["len"] for it in t.d["items"].values()), default=0.0)
    t.expect({"project.cursor": approx(end), **t.meter(end)})
    t.digest()
    t.ok("transport/goStart")
    t.expect({"project.cursor": approx(0), **t.meter(0.0)})


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
    start = t.flat
    try:
        _time_selection(t)
    except BaseException:
        try:
            _restore_time_selection(t, start)
        except Exception as e:  # noqa: BLE001 the op's own failure is the one to report
            print(f"      (restore after failure also failed: {type(e).__name__}: {e})")
        raise
    _restore_time_selection(t, start)


def _restore_time_selection(t, start):
    """Give the user back their own time selection and cursor: REAPER's undo
    restores the time selection kept in its undo history, so a stray one
    would show up in a later op's undo."""
    t.digest()
    sel = (start["project.timesel.0"], start["project.timesel.1"])
    if (t.flat["project.timesel.0"], t.flat["project.timesel.1"]) != sel:
        if sel[1] > sel[0]:
            t.ok("timeSelection/set", start=sel[0], end=sel[1])
        else:
            t.ok("timeSelection/clear")
    if t.flat["project.cursor"] != start["project.cursor"]:
        t.ok("transport/seek", position=start["project.cursor"])
    t._wait_equal(start, "the time selection and cursor were not restored")


def _time_selection(t):
    t.ok("timeSelection/set", start=2.4, end=9.6)
    t.expect({"project.timesel.0": approx(2.4), "project.timesel.1": approx(9.6)})
    t.digest()
    # Bars as the user sees them on the ruler, from the second bar it shows.
    bar = first_bar()
    a, b = parse_bars(f"{bar + 1}.1.00"), parse_bars(f"{bar + 3}.3.00")
    t.ok("timeSelection/setByBars", startBar=bar + 1, endBar=bar + 3, startBeat=1, endBeat=3)
    t.expect({"project.timesel.0": approx(a), "project.timesel.1": approx(b)})
    t.digest()
    # A bar before the first one the ruler shows is before the project
    # start: refused, and the time selection stays.
    r = t.send("timeSelection/setByBars", awaited=True, startBar=bar - 1, endBar=bar + 1, startBeat=1, endBeat=1)
    if r.get("success") or (r.get("error") or {}).get("code") != "INVALID_BAR":
        raise Mismatch(f"timeSelection/setByBars from bar {bar - 1}, before the project start: {r}")
    t.expect({})
    t.ok("transport/seek", position=1.0)
    t.ok("timeSelection/setStartAtCursor")
    t.expect({"project.cursor": approx(1.0), "project.timesel.0": approx(1.0), **t.meter(1.0)})
    t.digest()
    t.ok("transport/seek", position=5.0)
    t.ok("timeSelection/setEndAtCursor")
    t.expect({"project.cursor": approx(5.0), "project.timesel.1": approx(5.0), **t.meter(5.0)})
    t.digest()
    t.ok("timeSelection/goEnd")
    t.expect({})
    t.ok("timeSelection/goStart")
    t.expect({"project.cursor": approx(1.0), **t.meter(1.0)})
    t.digest()
    t.ok("timeSelection/goEnd")
    t.expect({"project.cursor": approx(5.0), **t.meter(5.0)})
    t.digest()
    t.ok("timeSelection/clear")
    t.expect({"project.timesel.*": approx(0)})


@op("transport: play, pause, playPause, stop", "transport/play", "transport/pause",
    "transport/playPause", "transport/stop")
def _(t):
    start = t.flat
    t.ok("transport/seek", position=0)
    t.ok("transport/play")
    t.expect({"project.play": 1, "project.cursor": ANY, **t.meter()})
    # While playing, the position reaches clients in tt ticks (or, while the
    # tempo ramps, in full transport events) and advances with REAPER's play
    # position.
    t.c.drain(1.0)
    event, at = play_position(t.c)
    playing_at = reaper("return reaper.GetPlayPosition()")
    if not 0.2 < at <= playing_at + 0.05:
        raise Mismatch(f"{event} while playing shows {at}; REAPER plays at {playing_at:.3f}")
    t.digest()
    # Whether pausing or stopping moves the edit cursor is a REAPER
    # preference. These commands run REAPER's own transport actions, so the
    # cursor goes where the user's own buttons would put it; converge() then
    # checks that clients show it there.
    t.ok("transport/pause")
    t.expect({"project.play": 2, "project.cursor": ANY, **t.meter()})
    t.digest()
    t.ok("transport/playPause")
    t.expect({"project.play": 1, "project.cursor": ANY, **t.meter()})
    t.digest()
    t.ok("transport/stop")
    t.expect({"project.play": 0, "project.cursor": ANY, **t.meter()})
    t.digest()
    if t.flat["project.cursor"] != start["project.cursor"]:
        t.ok("transport/seek", position=start["project.cursor"])
    t._wait_equal(start, "the edit cursor did not return to where the op found it")
