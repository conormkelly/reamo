"""Known gap (RV1-39): nudging an item from the phone leaves the automation under it behind.

With "Options: Move envelope points with media items" on, REAPER's nudge
takes the track's envelope points under the item along: a volume point at
1.5 s, inside a1 (1 to 2 s), ends up at 3.0 s when a1 moves to 2.5 s. A
point outside the item (8.5 s) stays.

The phone's nudge buttons send item/moveByGuid with the item's start plus
the nudge, which sets the item's position, so the point stays at 1.5 s and
the automation no longer lines up with the audio. With the option off REAPER leaves the points too, and REAmo matches.

When REAmo moves the points, the known-gap assertion fails: make it assert a
match with REAPER instead.
"""
from reamo_client import Client, reaper
import item_moves as im

FROM, TO = 1.0, 2.5  # a1's start, and where the nudge takes it
ENV_MOVE = 40070  # Options: Move envelope points with media items
POINTS = """
local env = reaper.GetTrackEnvelopeByName(reaper.GetMediaItem_Track(MOVE_ITEMS.a1), "Volume")
local out = {}
for i = 0, reaper.CountEnvelopePoints(env) - 1 do
  local _, t = reaper.GetEnvelopePoint(env, i)
  out[#out + 1] = t
end
return out
"""


def setup(env_move):
    im.setup(grouping=0, lua=f"""
    if reaper.GetToggleCommandState({ENV_MOVE}) ~= {env_move} then reaper.Main_OnCommand({ENV_MOVE}, 0) end
    local A = reaper.GetMediaItem_Track(MOVE_ITEMS.a1)
    local env = reaper.GetTrackEnvelopeByName(A, "Volume")
    if not env then
      reaper.SetOnlyTrackSelected(A)
      reaper.Main_OnCommand(40406, 0) -- Track: Toggle track volume envelope visible
      env = reaper.GetTrackEnvelopeByName(A, "Volume")
    end
    reaper.DeleteEnvelopePointRange(env, -1, 100)
    reaper.InsertEnvelopePoint(env, 1.5, 0.5, 0, 0, false, true)
    reaper.InsertEnvelopePoint(env, 8.5, 0.5, 0, 0, false, true)
    reaper.Envelope_SortPoints(env)
    """)


def has(points, t):
    return any(abs(p - t) < 1e-9 for p in points)


with Client() as c:
    c.wait_event("items")

    # Option off: neither moves the points.
    setup(0)
    im.reaper_move("a1", TO - FROM)
    want = reaper(POINTS)
    assert has(want, 1.5) and has(want, 8.5) and not has(want, 3.0), f"REAPER, option off: points at {want}"
    setup(0)
    r, _ = im.reamo_move(c, "a1", TO)
    assert r["success"], r
    got = reaper(POINTS)
    assert got == want, f"option off: REAPER's points {want}, REAmo's {got}"

    # Option on: REAPER moves the point under a1 by a1's move.
    setup(1)
    im.reaper_move("a1", TO - FROM)
    want = reaper(POINTS)
    print("REAPER, option on:", [round(p, 6) for p in want])
    assert has(want, 3.0) and not has(want, 1.5) and has(want, 8.5), f"REAPER, option on: points at {want}"
    setup(1)
    r, _ = im.reamo_move(c, "a1", TO)
    assert r["success"], r
    got = reaper(POINTS)
    print("REAmo, option on:", [round(p, 6) for p in got])
    # Known gap: the point stays where it was.
    assert has(got, 1.5) and not has(got, 3.0), \
        "option on: REAmo no longer leaves the point at 1.5 s. If it now matches REAPER, the known " \
        f"gap is fixed: assert a match here instead.\n  REAPER {want}\n  REAmo  {got}"
