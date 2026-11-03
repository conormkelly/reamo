"""Item moves, REAPER's way and REAmo's, on one small layout (RV1-39).

The `items-move-*` scenarios move an item with REAPER's own nudge (the
oracle: what REAPER does when its user nudges the selected item by that
much) and with REAmo's `item/moveByGuid`, from the same starting layout and
with the same ripple, grouping and snap settings, and compare where every
item and the marker end up.

The layout, on tracks A and B (the fixture makes the tracks):

    A:  a1 at 1    a2 at 4                 a3 at 8
    B:  b1 at 1               b2 at 6
    marker "m7" at 7

Every item is 1 s long. a1 and b1 are in group 1.
"""
from reamo_client import reaper

LAYOUT = {"a1": ("A", 1.0), "a2": ("A", 4.0), "a3": ("A", 8.0), "b1": ("B", 1.0), "b2": ("B", 6.0)}
MARKER = ("m7", 7.0)
# REAPER's ripple modes, each set by its own action ("Set ripple editing ...").
RIPPLE = {"off": 40309, "per-track": 40310, "all-tracks": 40311}
GROUPING = 1156  # Options: Toggle item grouping
SNAP = 1157      # Options: Toggle snapping

_LUA = r"""
local layout, marker, ripple_cmd, grouping, snap, grouping_cmd, snap_cmd = ...
local function set_toggle(id, want)
  if reaper.GetToggleCommandState(id) ~= want then reaper.Main_OnCommand(id, 0) end
end
for i = reaper.CountMediaItems(0) - 1, 0, -1 do
  local it = reaper.GetMediaItem(0, i)
  reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(it), it)
end
local _, nm, nr = reaper.CountProjectMarkers(0)
for i = nm + nr - 1, 0, -1 do reaper.DeleteProjectMarkerByIndex(0, i) end
MOVE_ITEMS = {}
for _, spec in ipairs(layout) do
  local name, track, pos = spec[1], spec[2], spec[3]
  local tr
  for t = 0, reaper.CountTracks(0) - 1 do
    local _, tn = reaper.GetTrackName(reaper.GetTrack(0, t), "")
    if tn == track then tr = reaper.GetTrack(0, t) end
  end
  local it = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 1)
  if name == "a1" or name == "b1" then reaper.SetMediaItemInfo_Value(it, "I_GROUPID", 1) end
  MOVE_ITEMS[name] = it
end
reaper.AddProjectMarker(0, false, marker[2], 0, marker[1], -1)
reaper.Main_OnCommand(ripple_cmd, 0)
set_toggle(grouping_cmd, grouping)
set_toggle(snap_cmd, snap)
reaper.Main_OnCommand(40289, 0) -- Item: Unselect all items
reaper.UpdateArrange()
"""

_STATE = r"""
local out = {}
for name, it in pairs(MOVE_ITEMS) do
  local _, tn = reaper.GetTrackName(reaper.GetMediaItem_Track(it), "")
  out[name] = {tn, reaper.GetMediaItemInfo_Value(it, "D_POSITION")}
end
local _, nm, nr = reaper.CountProjectMarkers(0)
for i = 0, nm + nr - 1 do
  local _, _, pos, _, name = reaper.EnumProjectMarkers(i)
  out["marker " .. name] = {"", pos}
end
return out
"""


def _lua_value(v):
    if isinstance(v, str):
        return '"' + v + '"'
    if isinstance(v, (list, tuple)):
        return "{" + ",".join(_lua_value(x) for x in v) + "}"
    return repr(v)


def setup(ripple="off", grouping=1, snap=0, lua=""):
    """Build the layout afresh with these settings, then run `lua` (which can
    reach the items as MOVE_ITEMS.a1 and so on)."""
    layout = [[n, t, p] for n, (t, p) in LAYOUT.items()]
    values = (layout, list(MARKER), RIPPLE[ripple], grouping, snap, GROUPING, SNAP)
    reaper(f"(function(...)\n{_LUA}\nend)({', '.join(_lua_value(v) for v in values)})\n{lua}")


def state():
    """{name: (track, position)} for every item, and "marker m7"."""
    return {k: (v[0], v[1]) for k, v in reaper(_STATE).items()}


def reaper_move(name, delta):
    """REAPER's own move: select only `name` and nudge the selection by
    `delta` seconds (ApplyNudge: selected items, position, seconds, no snap)."""
    reaper(f"""
    reaper.Main_OnCommand(40289, 0)
    reaper.SetMediaItemSelected(MOVE_ITEMS.{name}, true)
    reaper.ApplyNudge(0, 0, 0, 1, {abs(delta)!r}, {'true' if delta < 0 else 'false'}, 0)
    reaper.Main_OnCommand(40289, 0)
    """)
    return state()


def reamo_move(client, name, position):
    """REAmo's move, as the phone sends it: item/moveByGuid with an absolute
    position (a nudge button sends the item's start plus the nudge). Returns
    (response, state)."""
    guid = reaper(f'local _, g = reaper.GetSetMediaItemInfo_String(MOVE_ITEMS.{name}, "GUID", "", false); return g')
    r = client.command("item/moveByGuid", guid=guid, position=position)
    return r, state()


def same(a, b, tol=1e-9):
    return a[0] == b[0] and abs(a[1] - b[1]) <= tol


def moved(before, after):
    """{name: (from, to)} for what changed track or position."""
    return {k: (before[k], after[k]) for k in before if not same(before[k], after[k])}


def moved_exactly(before, after, expected):
    """Whether exactly the names in `expected` ({name: (track, position)})
    moved, each to where `expected` says (positions within `same`'s tolerance)."""
    m = moved(before, after)
    return set(m) == set(expected) and all(same(after[k], v) for k, v in expected.items())


def diff(want, got):
    """Lines naming each item or marker where `got` isn't `want`."""
    return [f"  {k}: REAPER {want[k][0]}@{want[k][1]:.6f}, REAmo {got[k][0]}@{got[k][1]:.6f}"
            for k in sorted(want) if not same(want[k], got[k])]
