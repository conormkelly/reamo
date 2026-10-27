"""A tempo map of hundreds of markers reaches clients whole, and every edit to it does.

A live recording tempo-mapped beat by beat has a marker per beat: 400 in a
few minutes. A phone connecting to it must get all of them (it places bars
and the beat grid from the map), and must hear about every edit, including
ones that leave each marker's time alone: making a tempo change gradual, or
two markers trading tempos.
"""
import time

from reamo_client import Client, reaper

N = 400

REAPER_MAP = """
local out = {}
for i = 0, reaper.CountTempoTimeSigMarkers(0) - 1 do
  local _, pos, _, _, bpm, num, den, linear = reaper.GetTempoTimeSigMarker(0, i)
  out[#out + 1] = {pos, bpm, num, den, linear}
end
return out
"""


def shown(c):
    ev = c.latest_event("tempoMap")
    if ev is None:
        return None
    return [[m["position"], m["bpm"], m["timesigNum"], m["timesigDenom"], m["linear"]]
            for m in ev["payload"]["markers"]]


def same(got, want):
    if got is None or len(got) != len(want):
        return False
    for g, w in zip(got, want):
        if abs(g[0] - w[0]) > 1e-6 or abs(g[1] - w[1]) > 0.005 or g[2:] != [w[2] if w[2] > 0 else g[2], w[3] if w[3] > 0 else g[3], w[4]]:
            return False
    return True


def expect_reaper_map(c, step, timeout=4.0):
    deadline = time.time() + timeout  # the low tier polls the tempo map at 1 Hz
    while True:
        c.drain(0.25)
        want = reaper(REAPER_MAP)
        got = shown(c)
        if same(got, want):
            print(f"{step}: {len(got)} markers, as REAPER has")
            return
        if time.time() > deadline:
            n = None if got is None else len(got)
            raise AssertionError(f"{step}: client shows {n} markers, REAPER has {len(want)}; "
                                 f"first difference: {next(((g, w) for g, w in zip(got or [], want) if not same([g], [w])), None)}")


# A marker per beat at a drifting live tempo, as tempo detection leaves them.
reaper(f"""
for i = 0, {N - 1} do
  local bpm = 118 + 4 * math.sin(i / 17)
  reaper.SetTempoTimeSigMarker(0, -1, i * 0.5, -1, -1, bpm, 0, 0, false)
end
reaper.UpdateTimeline()
""")
assert reaper("return reaper.CountTempoTimeSigMarkers(0)") == N

# A phone connecting to the session gets the whole map in its snapshot.
with Client() as c:
    c.wait_event("tempoMap", timeout=5)
    expect_reaper_map(c, "snapshot")

    # The user makes the tempo change at marker 300 gradual.
    reaper("""
    local _, pos, mpos, beat, bpm, num, den = reaper.GetTempoTimeSigMarker(0, 300)
    reaper.SetTempoTimeSigMarker(0, 300, pos, -1, -1, bpm, num, den, true)
    reaper.UpdateTimeline()
    """)
    expect_reaper_map(c, "marker 300 made gradual")
    assert shown(c)[300][4] is True

    # Two neighbouring markers trade tempos; every marker keeps its time.
    reaper("""
    local _, p1, _, _, b1 = reaper.GetTempoTimeSigMarker(0, 350)
    local _, p2, _, _, b2 = reaper.GetTempoTimeSigMarker(0, 351)
    reaper.SetTempoTimeSigMarker(0, 350, p1, -1, -1, b2, 0, 0, false)
    reaper.SetTempoTimeSigMarker(0, 351, p2, -1, -1, b1, 0, 0, false)
    reaper.UpdateTimeline()
    """)
    expect_reaper_map(c, "markers 350 and 351 traded tempos")

assert reaper("return true")
