"""Markers, regions, tempo, time signature, metronome, count-in and recording.

Marker and region commands carry the marker's number as "id", the key the
request id would use, so the frontend sends them without awaiting a
response (sendCommand) and these ops fire them the same way.
"""
import math
import time

from reamo_client import reaper
from tour import ANY, Mismatch, Skip, approx, diff, op, play_position


# ----------------------------------------------------------------------------
# Helpers

def parse_bars(label):
    """Time of a bar.beat label as REAPER's ruler shows it."""
    return reaper(f'return reaper.parse_timestr_pos("{label}", 2)')


def bars_of(pos):
    """The bar.beat label REAPER's ruler shows for a time."""
    return reaper(f'return reaper.format_timestr_pos({pos!r}, "", 2)')


def shift_bar(label, bars):
    """The same beat `bars` bars later: "4.1.00" + 2 -> "6.1.00"."""
    bar, rest = label.split(".", 1)
    return f"{int(bar) + bars}.{rest}"


def settle(t, target, what, timeout=3.0):
    """Wait until REAPER's digest equals `target` (volatile keys aside)."""
    deadline = time.time() + timeout
    while True:
        delta = diff(target, t.digest())
        if not delta:
            return
        if time.time() > deadline:
            lines = [f"{k}: {a!r} vs {b!r}" for k, (a, b) in sorted(delta.items())][:20]
            raise Mismatch(what + ":\n    " + "\n    ".join(lines))
        t.c.drain(0.15)


def seek_back(t, start):
    """Put the edit cursor back where the op found it (undo does not restore it)."""
    if abs(t.digest()["project.cursor"] - start["project.cursor"]) > 1e-6:
        t.ok("transport/seek", position=start["project.cursor"])
        settle_cursor(t, start["project.cursor"])


def settle_cursor(t, pos, timeout=3.0):
    deadline = time.time() + timeout
    while abs(t.digest()["project.cursor"] - pos) > 1e-6:
        if time.time() > deadline:
            raise Mismatch(f"edit cursor stayed at {t.flat['project.cursor']}, not {pos}")
        t.c.drain(0.1)


def undo_back(t, steps, start, what):
    """Undo `steps` steps from the client, put the cursor back, and require
    the project to be exactly as `start` with the same undo history top: an
    op that adds a stray undo step leaves one more Ctrl+Z for the user."""
    for _ in range(steps):
        r = t.send("undo/do", awaited=True)
        if not r.get("success"):
            raise Mismatch(f"undo/do failed: {r}")
    seek_back(t, start)
    settle(t, start, f"after undoing {what}, the project did not return to how it was")
    if t.flat["undo.can_undo"] != start["undo.can_undo"]:
        raise Mismatch(f"{what} left an extra undo step: after undoing it, the next undo is "
                       f"{t.flat['undo.can_undo']!r}, not {start['undo.can_undo']!r}")


def cleanup(t, fn):
    """Run a restore step after an op body that may have failed: a failure
    in the body is the one reported, a failure here only when the body passed."""
    def run(body_failed):
        try:
            fn()
        except Exception as e:  # noqa: BLE001 the body's failure is the one to report
            if not body_failed:
                raise
            print(f"      (restore after failure also failed: {type(e).__name__}: {e})")
    return run


def new_key(t, prefix, before, timeout=3.0):
    """The marker/region key ("M7", "R4") REAPER added since `before`. The
    op's next expect() still compares against the digest before the add."""
    baseline = t.flat
    deadline = time.time() + timeout
    while True:
        t.digest()
        added = [k for k in t.d["markers"] if k.startswith(prefix) and k not in before]
        if added:
            t.flat = baseline
            return added[0]
        if time.time() > deadline:
            raise Mismatch(f"REAPER shows no new {'marker' if prefix == 'M' else 'region'}")
        t.c.drain(0.1)


def expect_gone(t, key, timeout=3.0):
    """Wait until REAPER no longer has marker/region `key`, then require
    that nothing else changed."""
    deadline = time.time() + timeout
    baseline = t.flat
    while key in t.d["markers"]:
        if time.time() > deadline:
            raise Mismatch(f"REAPER still has {'marker' if key[0] == 'M' else 'region'} {key[1:]}")
        t.c.drain(0.1)
        t.digest()
    t.flat = baseline
    t.expect({f"markers.{key}.*": ANY, f"markers.{key}.render[]": ANY})


def named(t, prefix, name):
    """(key, digest) of the marker/region named `name`, else the first one."""
    found = sorted((k, m) for k, m in t.d["markers"].items() if k.startswith(prefix))
    if not found:
        raise Skip(f"the project has no {'markers' if prefix == 'M' else 'regions'}")
    for k, m in found:
        if m["name"] == name:
            return k, m
    return found[0]


def edges(t):
    """Every position REAPER's marker navigation stops at: markers, both
    edges of every region, and the edges of the time selection and the
    loop range when they are set."""
    out = set()
    for k, m in t.d["markers"].items():
        out.add(m["pos"])
        if k.startswith("R"):
            out.add(m["end"])
    for key in ("timesel", "loop"):
        rng = t.d["project"].get(key)
        if isinstance(rng, list) and rng[1] > rng[0]:  # the digest's loop may read "timesel"
            out.update(rng)
    return sorted(out)


def expect_failure(t, command, code, **params):
    """A request the handler must refuse, changing nothing."""
    r = t.send(command, awaited=True, **params)
    if r.get("success") or (r.get("error") or {}).get("code") != code:
        raise Mismatch(f"{command} {params}: want error {code}, got {r}")
    t.expect({})


def lua_list(exprs):
    """Evaluate Lua expressions in REAPER in one call; returns a list."""
    if not exprs:
        return []
    vals = reaper("return {" + ", ".join(exprs) + "}")
    return list(vals) if isinstance(vals, (list, tuple)) else [vals]


def beat_positions(t):
    """Quarter-note position of every item start and end and every marker
    and region edge, taken before a tempo change."""
    qn = {}
    for g, it in t.d["items"].items():
        qn[f"items.{g}.pos"] = it["pos"]
        qn[f"items.{g}.end"] = it["pos"] + it["len"]
    for k, m in t.d["markers"].items():
        qn[f"markers.{k}.pos"] = m["pos"]
        if k.startswith("R"):
            qn[f"markers.{k}.end"] = m["end"]
    keys = sorted(qn)
    return dict(zip(keys, lua_list([f"reaper.TimeMap2_timeToQN(0, {qn[k]!r})" for k in keys])))


def tempo_change_expectations(start, qn):
    """Every digest change a tempo change may make, from REAPER's tempo map
    after it. Each item and marker either keeps its time (time timebase) or
    its beat (beat timebase), and an item's length either its time or its
    beats ("beats (position, length, rate)"). Which applies is a per-item
    and per-project preference, so both are REAPER's own answer; anything
    else is a misplaced edit. Ruler labels follow; clients must show them as
    REAPER does (tour_mirror checks that)."""
    keys = sorted(qn)
    now = dict(zip(keys, lua_list([f"reaper.TimeMap2_QNToTime(0, {qn[k]!r})" for k in keys])))

    def either(was, beat):
        return lambda got: abs(got - was) <= 1e-4 or abs(got - beat) <= 1e-4

    changes = {"markers.*.bars": ANY, "markers.*.end_bars": ANY}
    for k in keys:
        if k.startswith("items.") and k.endswith(".end"):
            g = k[len("items."):-len(".end")]
            # From where its start beat lands to where its end beat lands.
            changes[f"items.{g}.len"] = either(start[f"items.{g}.len"], now[k] - now[f"items.{g}.pos"])
        else:
            changes[k] = either(start[k], now[k])
    return changes


def has_tempo_map(flat):
    return "tempo[]" not in flat


def cursor_at_zero(t):
    """Park the edit cursor at the project start, the one place a tempo
    change cannot move it (REAPER keeps the cursor on its beat, also when
    undoing), and return the digest there."""
    if t.flat["project.cursor"] != 0:
        t.ok("transport/seek", position=0.0)
        t.expect({"project.cursor": 0, **t.meter(0.0)})
    return t.digest()


# ----------------------------------------------------------------------------
# Markers

@op("marker: drop one at the play position, then delete it", "marker/add", "marker/delete")
def _(t):
    start = t.flat
    t.ok("transport/play")
    restore = cleanup(t, lambda: (t.send("transport/stop"), seek_back(t, start)))
    try:
        t.expect({"project.play": 1, "project.cursor": ANY, **t.meter()})
        # The phone shows the play position it last heard; the user drops
        # the marker where the playhead is.
        t.c.drain(1.0)
        _, at = play_position(t.c)
        before = set(t.d["markers"])
        t.ok("marker/add", position=at, name="Gtr solo – “hero” ✨")
        key = new_key(t, "M", before)
        t.expect({"project.play": 1, "project.cursor": ANY, **t.meter(),
                  f"markers.{key}.pos": approx(at, 1e-6), f"markers.{key}.name": "Gtr solo – “hero” ✨",
                  f"markers.{key}.color": 0, f"markers.{key}.bars": bars_of(at), f"markers.{key}.guid": ANY})
        t.ok("transport/stop")
        # Where stopping leaves the edit cursor is a REAPER preference.
        t.expect({"project.play": 0, "project.cursor": ANY, **t.meter(), f"markers.{key}.*": ANY})
    except BaseException:
        restore(True)
        raise
    seek_back(t, start)
    t.check_undo()
    added = t.flat
    t.c.fire("marker/delete", id=int(key[1:]))
    expect_gone(t, key)
    t.undo_redo(added, t.flat)
    settle(t, start, "after deleting the dropped marker, the project is not as it was")


@op("marker: rename with unicode, quotes and a backslash", "marker/update")
def _(t):
    start = t.flat
    key, m = named(t, "M", "Fill")
    name = 'Fill → "big" \\ drums ✨ 夜'
    # The marker editor sends the name with the colour, 0 for the default.
    t.c.fire("marker/update", id=int(key[1:]), name=name, color=m["color"])
    t.expect({f"markers.{key}.name": name})
    t.check_undo()
    undo_back(t, 1, start, "a marker rename")


@op("marker: drag to another beat on the ruler", "marker/update")
def _(t):
    start = t.flat
    key, m = named(t, "M", "Drop")
    target = m["bars"].split(".")[0] + ".3.00"  # beat 3 of its bar
    pos = parse_bars(target)
    # The timeline drag sends only the new position.
    t.c.fire("marker/update", id=int(key[1:]), position=pos)
    t.expect({f"markers.{key}.pos": approx(pos, 1e-6), f"markers.{key}.bars": target})
    t.check_undo()
    undo_back(t, 1, start, "a marker drag")


@op("marker: recolour, then reset to the default colour", "marker/update")
def _(t):
    start = t.flat
    key, m = named(t, "M", "Vox in")
    mid = int(key[1:])
    steps = 0
    restore = cleanup(t, lambda: undo_back(t, steps, start, "a marker recolour and reset"))
    try:
        t.c.fire("marker/update", id=mid, name=m["name"], color=0x1000000 | 0x22AA66)
        steps += 1
        t.expect({f"markers.{key}.color": 0x1000000 | 0x22AA66})
        # Picking the default colour in the marker editor sends colour 0.
        # The marker keeps its identity: REAPER's GUID for it is what
        # scripts and other extensions hold on to.
        t.digest()
        t.c.fire("marker/update", id=mid, name=m["name"], color=0)
        steps += 1
        t.expect({f"markers.{key}.color": lambda c: not int(c) & 0x1000000})
    except BaseException:
        restore(True)
        raise
    restore(False)


@op("marker: go to one, then next and previous", "marker/goto", "marker/next", "marker/prev")
def _(t):
    start = t.flat
    key, m = named(t, "M", "Vox in")
    t.c.fire("marker/goto", id=int(key[1:]))
    t.expect({"project.cursor": approx(m["pos"], 1e-6), **t.meter(m["pos"])})
    # REAPER's navigation stops at every edge() and, past the last one, at
    # the project end (before the first, at the project start).
    stops = edges(t)
    here = m["pos"]
    t.digest()
    t.ok("marker/next")
    later = [p for p in stops if p > here + 1e-6]
    want = later[0] if later else reaper("return reaper.GetProjectLength(0)")
    t.expect({"project.cursor": approx(want, 1e-6), **t.meter(want)})
    for _ in range(2):
        here = t.flat["project.cursor"]
        t.digest()
        t.ok("marker/prev")
        earlier = [p for p in stops if p < here - 1e-6]
        want = earlier[-1] if earlier else 0.0
        t.expect({"project.cursor": approx(want, 1e-6), **t.meter(want)})
    seek_back(t, start)


# ----------------------------------------------------------------------------
# Regions

@op("region: recolour, then reset; routing and identity survive", "region/update")
def _(t):
    start = t.flat
    key, r = named(t, "R", "Chorus")
    rid = int(key[1:])
    # The user routes the chorus to the master and a stem in REAPER's region
    # render matrix (one undo step), then edits it from the phone.
    reaper(f"""reaper.Undo_BeginBlock2(0)
reaper.SetRegionRenderMatrix(0, {rid}, reaper.GetMasterTrack(0), 1)
if reaper.CountTracks(0) > 0 then reaper.SetRegionRenderMatrix(0, {rid}, reaper.GetTrack(0, 0), 1) end
reaper.Undo_EndBlock2(0, "Region render matrix", -1)""")
    t.expect({f"markers.{key}.render.*": ANY, f"markers.{key}.render[]": ANY})
    routed = t.flat
    steps = 1
    restore = cleanup(t, lambda: undo_back(t, steps, start, "a region recolour and reset"))
    try:
        if not t.d["markers"][key]["render"]:
            raise Mismatch(f"REAPER kept no render-matrix routing for region {rid}")
        t.c.fire("region/update", id=rid, color=0x1000000 | 0xCC3366)
        steps += 1
        t.expect({f"markers.{key}.color": 0x1000000 | 0xCC3366})
        t.undo_redo(routed, t.flat)
        # Holding the swatch resets the colour (colour 0). Bounds, name,
        # number, render routing and REAPER's GUID for the region all stay.
        t.digest()
        coloured = t.flat
        t.c.fire("region/update", id=rid, color=0)
        steps += 1
        t.expect({f"markers.{key}.color": lambda c: not int(c) & 0x1000000})
        t.undo_redo(coloured, t.flat)
    except BaseException:
        restore(True)
        raise
    restore(False)


@op("region: move the chorus two bars later with the region editor's batch", "region/batch")
def _(t):
    start = t.flat
    key, r = named(t, "R", "Chorus")
    new_bars, new_end_bars = shift_bar(r["bars"], 2), shift_bar(r["end_bars"], 2)
    s, e = parse_bars(new_bars), parse_bars(new_end_bars)
    resp = t.send("region/batch", awaited=True, ops=[{"op": "update", "id": int(key[1:]), "start": s, "end": e}])
    if not resp.get("success") or resp.get("payload", {}).get("applied") != 1:
        raise Mismatch(f"region/batch: {resp}")
    t.expect({f"markers.{key}.pos": approx(s, 1e-6), f"markers.{key}.end": approx(e, 1e-6),
              f"markers.{key}.bars": new_bars, f"markers.{key}.end_bars": new_end_bars})
    t.check_undo()
    undo_back(t, 1, start, "a region batch edit")


@op("region: add at bars the user typed, go to it, delete it",
    "tempo/barsToTime", "region/add", "region/goto", "region/delete")
def _(t):
    start = t.flat
    # After the last region (or at bar 1): the add-region dialog converts
    # the bars the user typed with barsToTime, then adds the region.
    ends = [m["end"] for k, m in t.d["markers"].items() if k.startswith("R")]
    first_bar = int(bars_of(max(ends)).split(".")[0]) if ends else 1
    times = []
    for bar in (first_bar, first_bar + 2):
        r = t.send("tempo/barsToTime", awaited=True, bar=bar, beat=1, ticks=0)
        want = parse_bars(f"{bar}.1.00")
        if not r.get("success") or abs(r["payload"]["time"] - want) > 1e-6:
            raise Mismatch(f"tempo/barsToTime bar={bar}: {r}, REAPER puts {bar}.1.00 at {want}")
        times.append(r["payload"]["time"])
    before = set(t.d["markers"])
    name, color = 'Outro "fade" – ñ', 0x1000000 | 0x22AA66
    t.ok("region/add", start=times[0], end=times[1], name=name, color=color)
    key = new_key(t, "R", before)
    t.expect({f"markers.{key}.*": ANY, f"markers.{key}.pos": approx(times[0], 1e-6),
              f"markers.{key}.end": approx(times[1], 1e-6), f"markers.{key}.name": name,
              f"markers.{key}.color": color, f"markers.{key}.bars": f"{first_bar}.1.00",
              f"markers.{key}.end_bars": f"{first_bar + 2}.1.00"})
    t.check_undo()
    t.digest()
    t.c.fire("region/goto", id=int(key[1:]))
    t.expect({"project.cursor": approx(times[0], 1e-6), **t.meter(times[0])})
    added = t.flat
    t.c.fire("region/delete", id=int(key[1:]))
    expect_gone(t, key)
    t.undo_redo(added, t.flat)
    seek_back(t, start)
    settle(t, start, "after deleting the added region, the project is not as it was")


# ----------------------------------------------------------------------------
# Tempo and time signature

@op("tempo: conversions at the bars the user sees",
    "tempo/barsToTime", "tempo/timeToBeats", "tempo/getBarDuration", "tempo/snap")
def _(t):
    problems = []
    # Bars as displayed, from the first the ruler shows (-4 in the band
    # session, 1 by default): its downbeat, a beat with ticks in the next
    # bar, the last beat four bars on, and bar 1.
    first = int(bars_of(0.0).split(".")[0])
    for bar, beat, ticks in ((first, 1, 0), (first + 1, 2, 50), (first + 4, 4, 0), (1, 1, 0)):
        r = t.send("tempo/barsToTime", awaited=True, bar=bar, beat=beat, ticks=ticks)
        want = parse_bars(f"{bar}.{beat}.{ticks:02d}")
        if not r.get("success") or abs(r["payload"]["time"] - want) > 1e-6:
            problems.append(f"barsToTime {bar}.{beat}.{ticks:02d}: {r.get('payload') or r}, REAPER {want}")
    for at in (0.0, 4.8, 13.3, 23.99):
        r = t.send("tempo/timeToBeats", awaited=True, time=at)
        bars = bars_of(at)
        full = reaper(f"local _, _, _, full = reaper.TimeMap2_timeToBeats(0, {at!r}); return full")
        p = r.get("payload") or {}
        if not r.get("success") or p.get("bars") != bars or abs(p.get("beats", -1) - full) > 1e-4:
            problems.append(f"timeToBeats {at}: {p or r}, REAPER {bars} / {full} beats")
        r = t.send("tempo/getBarDuration", awaited=True, time=at)
        num, den, bpm, dur = reaper(f"""local num, den, bpm = reaper.TimeMap_GetTimeSigAtTime(0, {at!r})
local _, measure = reaper.TimeMap2_timeToBeats(0, {at!r})
local _, qn0, qn1 = reaper.TimeMap_GetMeasureInfo(0, measure)
return num, den, bpm, reaper.TimeMap2_QNToTime(0, qn1) - reaper.TimeMap2_QNToTime(0, qn0)""")
        p = r.get("payload") or {}
        if (not r.get("success") or abs(p.get("duration", -1) - dur) > 1e-6 or p.get("timesigNum") != num
                or p.get("timesigDenom") != den or abs(p.get("bpm", -1) - bpm) > 0.01):
            problems.append(f"getBarDuration {at}: {p or r}, REAPER {num}/{den} at {bpm} BPM, bar {dur} s")
        if den == 4:  # a beat is a quarter note: REAPER's QN grid is the oracle
            for sub in (1, 4):
                r = t.send("tempo/snap", awaited=True, time=at, subdivision=sub)
                qn = reaper(f"return reaper.TimeMap2_timeToQN(0, {at!r})")
                snapped_qn = math.floor(qn * sub + 0.5) / sub
                want = reaper(f"return reaper.TimeMap2_QNToTime(0, {snapped_qn!r})")
                p = r.get("payload") or {}
                if (not r.get("success") or abs(p.get("snappedTime", -1) - want) > 1e-6
                        or abs(p.get("snappedBeats", -1) - snapped_qn) > 1e-6):
                    problems.append(f"snap {at} /{sub}: {p or r}, REAPER grid {want} ({snapped_qn} QN)")
    if problems:
        raise Mismatch("tempo conversions disagree with REAPER:\n    " + "\n    ".join(problems))
    t.expect({})


@op("tempo/set from the BPM field", "tempo/set")
def _(t):
    start = t.flat
    old = t.d["project"]["bpm"]
    new = 124 if round(old) != 124 else 96
    at_zero = cursor_at_zero(t)
    qn = beat_positions(t)
    # The BPM field sends a whole number in REAPER's 1-960 range.
    t.ok("tempo/set", bpm=new)
    deadline = time.time() + 3
    while abs(t.digest()["project.bpm"] - new) > 1e-6 and time.time() < deadline:
        t.c.drain(0.1)
    changes = tempo_change_expectations(start, qn)
    changes["project.bpm"] = approx(new, 1e-6)
    if has_tempo_map(start):
        changes["tempo.*"] = ANY  # with a tempo map, REAPER edits the marker at the cursor
    t.expect(changes)
    t.undo_redo(at_zero, t.flat)
    undo_back(t, 1, start, "a tempo change")
    expect_failure(t, "tempo/set", "INVALID_BPM", bpm=0.5)
    expect_failure(t, "tempo/set", "INVALID_BPM", bpm=961)


TEMPO_BEATS = """local out = {}
for i = 0, reaper.CountTempoTimeSigMarkers(0) - 1 do
  local _, _, measure, beat = reaper.GetTempoTimeSigMarker(0, i)
  out[#out + 1] = {measure, beat}
end
return out"""


@op("tempo/tap four times", "tempo/tap")
def _(t):
    start = t.flat
    old = t.d["project"]["bpm"]
    at_zero = cursor_at_zero(t)
    qn = beat_positions(t)
    # Where each tempo marker sits in measures and beats; REAPER keeps them
    # there when the tempo before them changes.
    beats = list(reaper(TEMPO_BEATS)) if has_tempo_map(start) else []
    edited = reaper("return reaper.FindTempoTimeSigMarker(0, 0)") if beats else -1
    for _ in range(5):  # four intervals of 0.5 s: 120 BPM
        t.c.fire("tempo/tap")
        time.sleep(0.5)
    deadline = time.time() + 3
    while abs(t.digest()["project.bpm"] - old) < 1e-6 and time.time() < deadline:
        t.c.drain(0.1)
    bpm = t.d["project"]["bpm"]
    recorded = t.d["undo"]["can_undo"] != at_zero["undo.can_undo"]

    def put_back():
        # Ctrl+Z when REAPER recorded the tap; otherwise the tempo the user
        # had, set in REAPER (without a tempo map, the project tempo).
        t.digest()
        if t.d["undo"]["can_undo"] != at_zero["undo.can_undo"]:
            undo_back(t, 1, start, "tap tempo")
        else:
            reaper(f"reaper.SetCurrentBPM(0, {old!r}, false)")
            seek_back(t, start)
            settle(t, start, "after restoring the tempo, the project is not as it was")

    restore = cleanup(t, put_back)
    try:
        # Taps reach REAPER on the extension's timer, so the intervals REAPER
        # measures jitter by a tick.
        if not 100 <= bpm <= 145:
            raise Mismatch(f"four taps 0.5 s apart set {bpm} BPM; REAPER should hear about 120")
        changes = tempo_change_expectations(start, qn)
        changes["project.bpm"] = approx(bpm, 1e-6)
        if beats:
            # With a tempo map, the tap sets the tempo of the marker in force
            # at the cursor; the markers after it stay on their beats.
            changes[f"tempo.{edited}.bpm"] = approx(bpm, 1e-6)
            later = list(range(edited + 1, len(beats)))
            now = lua_list([f"reaper.TimeMap2_beatsToTime(0, {beats[k][1]!r}, {beats[k][0]})" for k in later])
            for k, pos in zip(later, now):
                changes[f"tempo.{k}.pos"] = approx(pos, 1e-5)
        t.expect(changes)
        if recorded:
            t.undo_redo(at_zero, t.flat)
    except BaseException:
        restore(True)
        raise
    restore(False)


def setup_tempo_marker(t, label):
    """A tempo/meter marker at a displayed bar with the tempo already there,
    as the user inserts one in REAPER (one undo step). Returns its index."""
    return reaper(f"""reaper.Undo_BeginBlock2(0)
local p = reaper.parse_timestr_pos("{label}", 2)
local _, _, bpm = reaper.TimeMap_GetTimeSigAtTime(0, p)
reaper.SetTempoTimeSigMarker(0, -1, p, -1, -1, bpm, 0, 0, false)
reaper.Undo_EndBlock2(0, "Insert tempo/time signature marker", -1)
return reaper.FindTempoTimeSigMarker(0, p + 1e-9)""")


def steady_bar(t, last=64):
    """The first displayed bar from 1 on where the user can drop a tempo
    marker without reshaping the tempo map: not on a tempo marker and not
    inside a linear ramp. A constant-tempo marker inside a ramp ends the
    ramp there, so REAPER retimes every beat after it."""
    markers = t.d["tempo"]
    for bar in range(1, last + 1):
        at = parse_bars(f"{bar}.1.00")
        if any(abs(m["pos"] - at) < 1e-6 for m in markers):
            continue
        before = [m for m in markers if m["pos"] < at]
        after = [m for m in markers if m["pos"] > at]
        if before and before[-1]["linear"] and after:
            continue
        return bar
    raise Skip(f"every bar up to {last} is on a tempo marker or inside a tempo ramp")


def check_seven_eight(t, bar):
    """The conversions a phone uses, in 7/8 from `bar` on."""
    problems = []
    r = t.send("tempo/barsToTime", awaited=True, bar=bar + 1, beat=6, ticks=0)
    want = parse_bars(f"{bar + 1}.6.00")
    if abs((r.get("payload") or {}).get("time", -1) - want) > 1e-6:
        problems.append(f"barsToTime {bar + 1}.6.00 in 7/8: {r}, REAPER {want}")
    at = parse_bars(f"{bar + 1}.1.00")
    r = t.send("tempo/getBarDuration", awaited=True, time=at)
    dur = parse_bars(f"{bar + 2}.1.00") - at
    p = r.get("payload") or {}
    if abs(p.get("duration", -1) - dur) > 1e-6 or (p.get("timesigNum"), p.get("timesigDenom")) != (7, 8):
        problems.append(f"getBarDuration in 7/8: {p or r}, REAPER bar {dur} s")
    at = parse_bars(f"{bar + 1}.5.00")
    r = t.send("tempo/timeToBeats", awaited=True, time=at)
    if (r.get("payload") or {}).get("bars") != bars_of(at):
        problems.append(f"timeToBeats in 7/8: {r}, REAPER {bars_of(at)}")
    if problems:
        raise Mismatch("7/8 conversions disagree with REAPER:\n    " + "\n    ".join(problems))


@op("timesig: 7/8 from a bar with a tempo marker", "timesig/set")
def _(t):
    start = t.flat
    bar = steady_bar(t)
    idx = setup_tempo_marker(t, f"{bar}.1.00")
    t.expect({"tempo.*": ANY, "tempo[]": ANY, "tracks.master.envs.Tempo map": ANY})
    marked_markers = t.d["markers"]
    steps = 1
    restore = cleanup(t, lambda: undo_back(t, steps, start, "a 7/8 meter change"))
    try:
        # The user stands on the bar (as displayed) and sets the meter.
        t.ok("transport/seekBeats", bar=bar, beat=1)
        here = parse_bars(f"{bar}.1.00")
        t.expect({"project.cursor": approx(here, 1e-6), **t.meter(here)})
        at_bar = t.flat
        qn = beat_positions(t)
        beats = list(reaper(TEMPO_BEATS))
        t.ok("timesig/set", numerator=7, denominator=8)
        steps += 1
        changes = {f"tempo.{idx}.num": 7, f"tempo.{idx}.den": 8, "project.timesig.0": 7, "project.timesig.1": 8}
        # The ruler from the marker on counts 7/8 bars.
        for k, m in marked_markers.items():
            if m["pos"] > here + 1e-6:
                changes[f"markers.{k}.bars"] = ANY
            if k.startswith("R") and m["end"] > here + 1e-6:
                changes[f"markers.{k}.end_bars"] = ANY
        # Later tempo markers stay on their bars, so with shorter bars before
        # them they come earlier; items and markers keep their time or their
        # beat in the tempo map that results, as their timebase says.
        later = list(range(idx + 1, len(beats)))
        if later:
            changes.update(tempo_change_expectations(at_bar, qn))
            now = lua_list([f"reaper.TimeMap2_beatsToTime(0, {beats[k][1]!r}, {beats[k][0]})" for k in later])
            for k, pos in zip(later, now):
                changes[f"tempo.{k}.pos"] = approx(pos, 1e-5)
        t.expect(changes)
        check_seven_eight(t, bar)
        t.undo_redo(at_bar, t.flat)
    except BaseException:
        restore(True)
        raise
    restore(False)


@op("timesig: 7/8 for a project without a tempo map", "timesig/set")
def _(t):
    start = t.flat
    if has_tempo_map(start):
        raise Skip("the project has a tempo map; timesig/set edits the marker at the cursor there")
    t.ok("transport/seekBeats", bar=1, beat=1)
    here = parse_bars("1.1.00")
    t.expect({"project.cursor": approx(here, 1e-6), **t.meter(here)})
    at_bar = t.flat
    t.ok("timesig/set", numerator=7, denominator=8)
    t.expect({"project.timesig.0": 7, "project.timesig.1": 8,
              "markers.*.bars": ANY, "markers.*.end_bars": ANY})
    t.undo_redo(at_bar, t.flat)
    undo_back(t, 1, start, "a project meter change")


# ----------------------------------------------------------------------------
# Recording

@op("transport/record 1.5 s on an armed track, then record and stopAndDelete",
    "transport/record", "transport/stopAndDelete")
def _(t):
    start = t.flat
    # A track outside fixed lanes and folders with nothing recorded where the
    # take lands (the first 2.4 s), so REAPER's recording modes leave the
    # existing items alone.
    g, tr = t.track_for("Guitar", lambda g, tr: tr["freemode"] != 2 and tr["depth"] <= 0 and not any(
        it["track"] == g and it["pos"] < 2.4 for it in t.d["items"].values()), role="free to record the first 2.4 s on")
    # REAPER's dummy audio device has no inputs, so the track records its
    # own output, a setting the user makes in REAPER's record menu.
    old_mode = reaper(f"""local tr
for i = 0, reaper.CountTracks(0) - 1 do
  local x = reaper.GetTrack(0, i)
  if reaper.GetTrackGUID(x) == "{g}" then tr = x end
end
local m = reaper.GetMediaTrackInfo_Value(tr, "I_RECMODE")
reaper.SetMediaTrackInfo_Value(tr, "I_RECMODE", 1)
return m""")
    armed = [gg for gg, tt in t.tracks() if tt["arm"]]

    def restore_all():
        t.ok("track/setRecArm", trackGuid=g, arm=tr["arm"])
        reaper(f"""for i = 0, reaper.CountTracks(0) - 1 do
  local x = reaper.GetTrack(0, i)
  if reaper.GetTrackGUID(x) == "{g}" then reaper.SetMediaTrackInfo_Value(x, "I_RECMODE", {old_mode}) end
end""")
        seek_back(t, start)
        settle(t, start, "after recording and undoing it, the project is not as it was")

    restore = cleanup(t, restore_all)
    try:
        if not tr["arm"]:
            t.ok("track/setRecArm", trackGuid=g, arm=1)
            t.expect({f"tracks.{g}.arm": 1})
            armed.append(g)
        t.ok("transport/seek", position=0.0)
        t.expect({"project.cursor": ANY, **t.meter()})
        before = t.flat
        before_items = set(t.d["items"])
        t.ok("transport/record")
        t.expect({"project.play": 5, "project.cursor": ANY, **t.meter(), "items.*": ANY, "tracks.*": ANY})
        t.c.drain(1.5)
        t.ok("transport/stop")
        deadline = time.time() + 3
        while t.digest()["project.play"] != 0 and time.time() < deadline:
            t.c.drain(0.1)
        t.ok("transport/seek", position=0.0)
        settle_cursor(t, 0.0)
        new = [ig for ig in t.d["items"] if ig not in before_items]
        on = {t.d["items"][ig]["track"] for ig in new}
        if g not in on or not on <= set(armed):
            names = [t.d["tracks"][x]["name"] for x in on]
            raise Mismatch(f"recording made items on {names}; armed: {[t.d['tracks'][x]['name'] for x in armed]}")
        t.flat = before
        # REAPER selects the takes it records and unselects every other item.
        changes = {f"items.{ig}.sel": 0 for ig in before_items if before[f"items.{ig}.sel"]}
        for ig in new:
            changes[f"items.{ig}.*"] = ANY
            changes[f"items.{ig}.pos"] = approx(0.0, 0.05)
            changes[f"items.{ig}.len"] = lambda v: 1.2 < v < 2.5
            changes[f"items.{ig}.takes.0.src"] = "WAVE"
        # Existing items on a recorded track move up one place per new item
        # that starts before them.
        for ig, it in t.d["items"].items():
            if ig in new or it["track"] not in on:
                continue
            ahead = sum(1 for n in new if t.d["items"][n]["track"] == it["track"]
                        and t.d["items"][n]["pos"] < it["pos"])
            if ahead:
                changes[f"items.{ig}.idx"] = before[f"items.{ig}.idx"] + ahead
        t.expect(changes)
        t.undo_redo(before, t.flat)
        r = t.send("undo/do", awaited=True)
        if not r.get("success"):
            raise Mismatch(f"undo/do of the recording failed: {r}")
        settle(t, before, "after undoing the recording, the project is not as it was")

        # Record again and throw the take away.
        t.ok("transport/record")
        t.expect({"project.play": 5, "project.cursor": ANY, **t.meter(), "items.*": ANY, "tracks.*": ANY})
        t.c.drain(1.0)
        t.ok("transport/stopAndDelete")
        deadline = time.time() + 3
        while t.digest()["project.play"] != 0 and time.time() < deadline:
            t.c.drain(0.1)
        t.ok("transport/seek", position=0.0)
        settle_cursor(t, 0.0)
        settle(t, before, "stopAndDelete should leave the project as it was before recording")
        if t.flat["undo.can_undo"] != before["undo.can_undo"]:
            raise Mismatch(f"stopAndDelete left an undo step {t.flat['undo.can_undo']!r}")
    except BaseException:
        restore(True)
        raise
    restore(False)


# ----------------------------------------------------------------------------
# Metronome and count-in

@op("metronome: toggle, read and set the volume", "metronome/toggle", "metronome/getVolume",
    "metronome/setVolume")
def _(t):
    start = t.flat
    flags = int(start["project.metro_flags"])
    on = start["project.metronome"]
    t.ok("metronome/toggle")
    t.expect({"project.metronome": 0 if on else 1, "project.metro_flags": str(flags ^ 1)})
    t.digest()
    t.ok("metronome/toggle")
    t.expect({"project.metronome": on, "project.metro_flags": str(flags)})

    vol = float(start["project.metro_vol"])
    r = t.send("metronome/getVolume", awaited=True)
    p = r.get("payload") or {}
    want_db = 20 * math.log10(vol) if vol > 0 else None
    if abs(p.get("volume", -1) - vol) > 1e-6 or (want_db is not None and abs(p.get("volumeDb", 0) - want_db) > 0.01):
        raise Mismatch(f"metronome/getVolume: {r}; REAPER's metronome volume is {vol}")
    t.ok("metronome/setVolume", volumeDb=-6.0)
    t.expect({"project.metro_vol": lambda s: abs(float(s) - 10 ** (-6 / 20)) < 1e-6})
    t.digest()
    t.ok("metronome/setVolume", volume=vol)
    t.expect({"project.metro_vol": lambda s: abs(float(s) - vol) < 1e-9})
    settle(t, start, "after setting the metronome volume back, the project is not as it was")


@op("countIn: toggle before playback and before recording", "countIn/togglePlayback",
    "countIn/toggleRecord")
def _(t):
    flags = int(t.flat["project.metro_flags"])
    for command, bit in (("countIn/togglePlayback", 8), ("countIn/toggleRecord", 16)):
        t.ok(command)
        t.expect({"project.metro_flags": str(flags ^ bit)})
        t.digest()
        t.ok(command)
        t.expect({"project.metro_flags": str(flags)})
        t.digest()
