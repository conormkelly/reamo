"""Items, takes, fixed lanes and comping, and peaks."""
import json
import struct
import time

from reamo_client import reaper
from tour import ANY, Mismatch, Skip, approx, diff, op


# ----------------------------------------------------------------------------
# Helpers

def where(t, g):
    """(unified trackIdx, itemIdx) of item `g` as REAPER has it now: what the
    phone sends, since its items event mirrors REAPER."""
    it = t.d["items"][g]
    return t.d["tracks"][it["track"]]["pos"], it["idx"]


def track_items(t, g, pred=None):
    """Items on track g in REAPER's order on the track."""
    return t.items(lambda x, it: it["track"] == g and (pred is None or pred(x, it)))


def busy_track(t, name, count, pred=None, role=None):
    """A track with at least `count` items (each fitting `pred`), outside
    fixed lanes: the band session's `name` when it fits, else the first."""
    return t.track_for(name, lambda g, tr: tr["freemode"] != 2 and len(track_items(t, g, pred)) >= count,
                       role=role or f"with {count} items")


def str_hash(s):
    """digest.lua's str_hash of a string (its UTF-8 bytes)."""
    b = s.encode("utf-8")
    h = 5381
    for x in b:
        h = (h * 33 + x) % 4294967296
    return f"{len(b)}:{h:08x}"


def selected(flat):
    """GUIDs of the selected items in a flat digest."""
    return {k.split(".")[1] for k, v in flat.items()
            if k.startswith("items.") and k.endswith(".sel") and k.count(".") == 2 and v}


def selection_is(t, sel):
    """t.expect changes: exactly the items in `sel` selected, every other unselected."""
    return {f"items.{g}.sel": int(g in sel) for g in t.d["items"]}


def restore_selection(t):
    """Give the user back the item selection they had when the op started.

    REAPER's own selection actions (unselect all, select in time selection,
    which the phone's select commands run) each record an undo point, and
    REAPER's undo restores the item selection an undo point recorded. So
    the op's selection steps are undone first, as Ctrl+Z would: REAPER then
    restores the selection from before them, and its undo history agrees
    with what is selected. Only what is left is put back the way the phone
    does it (clear, then tap each item); taps record no undo point, so a
    later undo would undo them."""
    t.digest()
    want = selected(t.op_start) & set(t.d["items"])
    for _ in range(12):
        if selected(t.flat) == want or t.flat["undo.can_undo"] == t.op_start["undo.can_undo"]:
            break
        if any(not k.endswith(".sel") for k in diff(t.op_start, t.flat)):
            break  # the op's own edits are still there: not a selection step
        t.send("undo/do", awaited=True)
        t.c.drain(0.2)
        t.digest()
    if selected(t.flat) == want:
        return
    t.ok("item/unselectAll")
    for g in sorted(want):
        t.ok("item/toggleSelect", guid=g)
    t.expect(selection_is(t, want))


def restore_track_selection(t):
    """Give the user back the track selection they had when the op started."""
    t.digest()
    for g, tr in t.tracks():
        want = t.op_start.get(f"tracks.{g}.sel")
        if want is not None and tr["sel"] != want:
            t.ok("track/setSelected", trackGuid=g, selected=int(want))
    t.digest()


def wait_equal_but_selection(t, target, what, timeout=3.0):
    deadline = time.time() + timeout
    while True:
        delta = {k: v for k, v in diff(target, t.digest()).items() if not (k.startswith("items.") and k.endswith(".sel"))}
        if not delta:
            return
        if time.time() > deadline:
            lines = [f"{k}: {a!r} vs {b!r}" for k, (a, b) in sorted(delta.items())][:20]
            raise Mismatch(what + ":\n    " + "\n    ".join(lines))
        t.c.drain(0.15)


def check_undo(t, before=None, after=None):
    """Undo then redo from the phone return the project to its state before
    and after the edit. REAPER's undo puts item selection back as it was at
    the undo point it lands on, which selecting items (not an undo point in
    REAPER either) leaves behind, so selection is left to each op's own
    expectations."""
    before = t.op_start if before is None else before
    after = t.digest() if after is None else after
    r = t.send("undo/do", awaited=True)
    if not r.get("success"):
        raise Mismatch(f"undo/do failed: {r}")
    wait_equal_but_selection(t, before, "after undo/do, the project did not return to its state before the edit")
    r = t.send("redo/do", awaited=True)
    if not r.get("success"):
        raise Mismatch(f"redo/do failed: {r}")
    wait_equal_but_selection(t, after, "after redo/do, the project did not return to its state after the edit")
    t.digest()


def revert(t, steps, what):
    """Undo `steps` edits from the phone, as the user would, and require the
    project to be back as the op found it."""
    for _ in range(steps):
        r = t.send("undo/do", awaited=True)
        if not r.get("success"):
            raise Mismatch(f"undo/do failed: {r}")
    t.c.drain(0.2)
    restore_selection(t)
    restore_track_selection(t)
    t._wait_equal(t.op_start, f"undoing {what} did not return the project to how the op found it")


def tidy(fn):
    """On failure, undo the op's edits and restore the user's selection, so
    the failure is reported once rather than in every later op. Undoing
    stops (and is redone) as soon as a step no longer brings the project
    closer to how the op found it, so earlier ops' edits are left alone."""
    def run(t):
        try:
            fn(t)
        except Exception:
            try:
                left = lambda: len([k for k in diff(t.op_start, t.digest()) if not k.endswith(".sel")])
                n = left()
                for _ in range(12):
                    if not n:
                        break
                    t.send("undo/do", awaited=True)
                    t.c.drain(0.2)
                    m = left()
                    if m >= n:  # past the op's own edits
                        t.send("redo/do", awaited=True)
                        break
                    n = m
                restore_selection(t)
                restore_track_selection(t)
            except Exception as e:  # report the op's own failure, not this
                print(f"      (could not tidy up after the failure: {type(e).__name__}: {e})")
            raise
    run.__doc__ = fn.__doc__
    return run


def selection_lua(flat):
    """Lua that sets every item's and track's selection as in `flat`."""
    items = {k.split(".")[1]: int(v) for k, v in flat.items()
             if k.startswith("items.") and k.endswith(".sel") and k.count(".") == 2}
    tracks = {k.split(".")[1]: int(v) for k, v in flat.items()
              if k.startswith("tracks.") and k.endswith(".sel") and k.count(".") == 2 and k.split(".")[1] != "master"}
    lit = lambda m: "{" + ",".join(f'["{g}"]={v}' for g, v in m.items()) + "}"
    return f"""
local isel, tsel = {lit(items)}, {lit(tracks)}
for i = 0, reaper.CountMediaItems(0) - 1 do
  local it = reaper.GetMediaItem(0, i)
  local v = isel[select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false))]
  if v then reaper.SetMediaItemSelected(it, v == 1) end
end
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  local v = tsel[reaper.GetTrackGUID(tr)]
  if v then reaper.SetTrackSelected(tr, v == 1) end
end
reaper.UpdateArrange()
"""


def lua_track(g):
    """Lua binding `tr` to the track with GUID g."""
    return (f'local tr; for i = 0, reaper.CountTracks(0) - 1 do local x = reaper.GetTrack(0, i); '
            f'if reaper.GetTrackGUID(x) == "{g}" then tr = x end end\n')


def normalized(flat, old_items):
    """`flat` with items REAPER created during the op (not in `old_items`)
    renamed by where they are, and their take GUIDs blanked: the same edit
    done twice creates the same items under different GUIDs."""
    new = {k.split(".")[1] for k in flat if k.startswith("items.")} - old_items
    order = sorted(new, key=lambda g: (flat[f"items.{g}.track"], flat[f"items.{g}.lane"], flat[f"items.{g}.pos"]))
    names = {g: f"<new{i}>" for i, g in enumerate(order)}
    out = {}
    for k, v in flat.items():
        if k.startswith("undo."):
            continue
        parts = k.split(".", 2)
        if parts[0] == "items" and parts[1] in names:
            k = f"items.{names[parts[1]]}.{parts[2]}"
            if parts[2].startswith("takes.") and parts[2].endswith(".guid"):
                v = "<new take>"
        out[k] = v
    return out


def describe(t, key):
    """A digest path with its item named the way the user sees it."""
    parts = key.split(".")
    if parts[0] == "items" and parts[1] in t.d["items"]:
        it = t.d["items"][parts[1]]
        tr = t.d["tracks"][it["track"]]
        return f"{key} ({tr['name'] or 'track ' + str(tr['pos'])} item at {it['pos']} s, lane {int(it['lane'])})"
    return key


def like_native(t, native_lua, send, what):
    """Do `what` in REAPER itself (native_lua: the user's own action in
    REAPER), note the result and undo it; then do it from the phone (send)
    and require the same result, then undo and redo from the phone."""
    before = t.flat
    old = {k.split(".")[1] for k in before if k.startswith("items.")}
    reaper(native_lua)
    native = normalized(t.digest(), old)
    reaper("reaper.Undo_DoUndo2(0)")
    reaper(selection_lua(before))
    t._wait_equal(before, f"REAPER's own undo of {what} (done in REAPER, as the oracle) did not restore the project")
    send()
    deadline = time.time() + 3.0
    while True:
        delta = diff(native, normalized(t.digest(), old))
        if not delta:
            break
        if time.time() > deadline:
            lines = [f"{describe(t, k)}: REAPER's own action {a!r}, from the phone {b!r}" for k, (a, b) in sorted(delta.items())][:20]
            raise Mismatch(f"{what} from the phone differs from doing it in REAPER:\n    " + "\n    ".join(lines))
        t.c.drain(0.15)
    check_undo(t, before)
    return t.digest()


def new_items(t, before):
    return [(g, it) for g, it in t.d["items"].items() if f"items.{g}.pos" not in before]


def vox_lanes(t):
    """The first fixed-lane track with at least two lanes (the band
    session's lead vocal: three recorded lanes)."""
    g, tr = t.track(pred=lambda g, tr: tr["freemode"] == 2 and tr["nlanes"] >= 2)
    return g, tr


def lane_items(t, g, lane):
    return sorted(((ig, it) for ig, it in t.d["items"].items() if it["track"] == g and it["lane"] == lane),
                  key=lambda gi: gi[1]["pos"])


def comp_target(tr):
    """The comp target lane from the track's LANEREC (-1: none yet)."""
    fields = tr.get("lanerec", "").split()
    return int(fields[1]) if len(fields) > 1 else -1


SWIPE_LUA = """
local n = reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES")
reaper.GetSetMediaTrackInfo_String(tr, "P_RAZOREDITS_EXT", string.format('%.15f %.15f "" %.15f %.15f', {a}, {b}, {lane} / n, ({lane} + 1) / n), true)
reaper.Main_OnCommand(42475, 0) -- Razor edit: Create fixed lane comp area
reaper.GetSetMediaTrackInfo_String(tr, "P_RAZOREDITS_EXT", "", true)
"""


def swipe(t, g, lane, a, b):
    """Swipe lane `lane` of track `g` from a to b; the new comp area must
    play exactly that stretch of that lane's recording, on the comp lane."""
    tr = t.d["tracks"][g]
    target = comp_target(tr) if comp_target(tr) >= 0 else 0
    src = [it for _, it in lane_items(t, g, lane) if it["pos"] <= a and it["pos"] + it["len"] >= b]
    if not src:
        raise Skip(f"lane {lane} has no recording over {a}-{b} s")
    src = src[0]
    before = t.flat
    like_native(t, lua_track(g) + SWIPE_LUA.format(a=a, b=b, lane=lane),
                lambda: t.ok("lanes/swipeComp", trackGuid=g, sourceLane=lane, startTime=a, endTime=b),
                f"swiping lane {lane} {a}-{b} s")
    made = [it for _, it in new_items(t, before) if it["track"] == g]
    # A first comp inserts the comp lane above the recordings.
    shift = int(t.d["tracks"][g]["nlanes"] - tr["nlanes"])
    want_lane = target if shift == 0 else 0
    hit = [it for it in made if it["lane"] == want_lane and abs(it["pos"] - a) < 1e-6 and abs(it["len"] - (b - a)) < 1e-6]
    src_take = src["takes"][src["active"]]
    if not hit or hit[0]["takes"][hit[0]["active"]]["file"] != src_take["file"] or \
            abs(hit[0]["takes"][hit[0]["active"]]["offs"] - (src_take["offs"] + a - src["pos"])) > 1e-4:
        raise Mismatch(f"swiping lane {lane} {a}-{b} s made {made}; wanted {src_take['file']} "
                       f"from {src_take['offs'] + a - src['pos']:.3f} s on lane {want_lane}")


# ----------------------------------------------------------------------------
# Takes

@op("item/getTakes + setActiveTake: pick the best guitar take", "item/getTakes", "item/setActiveTake")
@tidy
def _(t):
    g, it = t.item(lambda g, it: len(it["takes"]) >= 2 and not any(tk.get("empty") for tk in it["takes"]))
    ti, ii = where(t, g)
    r = t.send("item/getTakes", awaited=True, trackIdx=ti, itemIdx=ii)
    if not r.get("success"):
        raise Mismatch(f"item/getTakes failed: {r}")
    got = r["payload"]["takes"]
    want = [{"takeIdx": k, "guid": tk["guid"], "name": tk["name"], "isActive": k == it["active"],
             "isMidi": bool(tk["midi"])} for k, tk in enumerate(it["takes"])]
    shown = [{k: e[k] for k in ("takeIdx", "guid", "name", "isActive", "isMidi")} for e in got]
    if shown != want or any(abs(e["startOffset"] - tk["offs"]) > 1e-5 or abs(e["playrate"] - tk["rate"]) > 1e-5
                            for e, tk in zip(got, it["takes"])):
        raise Mismatch(f"item/getTakes {got}\n    REAPER {it['takes']} (active {it['active']})")
    best = (it["active"] + 1) % len(it["takes"])
    t.ok("item/setActiveTake", trackIdx=ti, itemIdx=ii, takeIdx=best)
    t.expect({f"items.{g}.active": best})
    check_undo(t)
    revert(t, 1, "the take switch")


@op("take/next + take/prev on the selected item", "item/select", "take/next", "take/prev")
@tidy
def _(t):
    g, it = t.item(lambda g, it: len(it["takes"]) >= 2)
    n, a = len(it["takes"]), it["active"]
    t.ok("item/select", trackIdx=where(t, g)[0], itemIdx=where(t, g)[1])
    t.expect(selection_is(t, {g}))
    before = t.flat
    t.ok("take/next")
    t.expect({f"items.{g}.active": (a + 1) % n})
    check_undo(t, before, t.digest())
    before = t.flat
    t.ok("take/prev")
    t.expect({f"items.{g}.active": a})
    check_undo(t, before, t.digest())
    revert(t, 2, "the take steps")


@op("take/setColor: colour the active guitar take, then reset it", "take/setColor")
@tidy
def _(t):
    g, it = t.item(lambda g, it: it["active"] >= 0 and not it["takes"][it["active"]].get("empty")
                   and len(it["takes"]) >= 2)
    ti, ii = where(t, g)
    a = it["active"]
    teal = 0x1000000 | 0x2A9D8F  # hexToReaperColor("#2a9d8f")
    t.ok("take/setColor", trackIdx=ti, itemIdx=ii, takeIdx=a, color=teal)
    t.expect({f"items.{g}.takes.{a}.color": teal})
    check_undo(t)
    t.digest()
    t.ok("take/setColor", trackIdx=ti, itemIdx=ii, takeIdx=a, color=0)
    t.expect({f"items.{g}.takes.{a}.color": 0})
    revert(t, 2, "the take colour")


def takes_now(t, g, want):
    """t.expect changes: item g's takes are exactly `want` (take digests)."""
    out = {f"items.{g}.takes.{i}.{k}": v for i, tk in enumerate(want) for k, v in tk.items()}
    out[f"items.{g}.takes.*"] = ANY  # the dropped takes' entries are gone
    return out


@op("take/delete + take/cropToActive on the selected item", "take/delete", "take/cropToActive")
@tidy
def _(t):
    g, it = t.item(lambda g, it: len(it["takes"]) >= 3 and it["lock"] == 0)
    takes, a = it["takes"], it["active"]
    t.ok("item/select", trackIdx=where(t, g)[0], itemIdx=where(t, g)[1])
    t.expect(selection_is(t, {g}))
    selected_flat = t.flat
    # The user deletes the take they are hearing; another take becomes active.
    rest = takes[:a] + takes[a + 1:]
    t.ok("take/delete")
    t.expect({**takes_now(t, g, rest), f"items.{g}.active": lambda v: 0 <= v < len(rest)})
    check_undo(t, selected_flat, t.digest())
    t.send("undo/do", awaited=True)
    wait_equal_but_selection(t, selected_flat, "undo/do after take/delete did not bring the take back")
    t.ok("item/select", trackIdx=where(t, g)[0], itemIdx=where(t, g)[1])
    t.expect(selection_is(t, {g}))
    selected_flat = t.flat
    # Crop to the active take: only it remains.
    t.ok("take/cropToActive")
    t.expect({**takes_now(t, g, [takes[a]]), f"items.{g}.active": 0})
    check_undo(t, selected_flat, t.digest())
    revert(t, 1, "the crop")


# ----------------------------------------------------------------------------
# Moving, colour, lock, notes, delete

@op("item/move: nudge a late snare hit", "item/move")
@tidy
def _(t):
    unlocked = lambda g, it: not it["lock"]  # noqa: E731
    # A nudge 12 ms earlier that keeps the hit after the one before it.
    g0, tr = busy_track(t, "Snare", 2, unlocked, role="with two unlocked items")
    hits = track_items(t, g0)
    g, it = hits[1]
    if it["lock"] or it["pos"] - 0.012 <= hits[0][1]["pos"]:
        raise Skip("the second item cannot move 12 ms earlier without passing the first")
    ti, ii = where(t, g)
    t.ok("item/move", trackIdx=ti, itemIdx=ii, position=it["pos"] - 0.012)
    t.expect({f"items.{g}.pos": approx(it["pos"] - 0.012, 1e-6)})
    check_undo(t)
    revert(t, 1, "the nudge")


@op("item/moveByGuid: two quick nudges past the next hit", "item/moveByGuid")
@tidy
def _(t):
    def fits(g, tr):
        # The first two items unlocked, and nothing else before where A lands.
        hits = track_items(t, g)
        return (tr["freemode"] != 2 and len(hits) >= 2 and not hits[0][1]["lock"]
                and all(it["pos"] > hits[1][1]["pos"] + 0.6 for _, it in hits[2:]))
    g0, tr = t.track_for("Snare", fits, role="whose first item can be nudged past the second")
    hits = track_items(t, g0)
    (a, ia), (b, ib) = hits[0], hits[1]
    # The first nudge moves A past B: REAPER re-sorts the track at once, so
    # A's index changes before the phone's next items event. The second tap,
    # sent before that event, must still move A.
    p1, p2 = ib["pos"] + 0.5, ib["pos"] + 0.6
    t.ok("item/moveByGuid", guid=a, position=p1)
    t.ok("item/moveByGuid", guid=a, position=p2)
    t.expect({f"items.{a}.pos": approx(p2, 1e-6), f"items.{a}.idx": ib["idx"], f"items.{b}.idx": ia["idx"]})
    revert(t, 2, "the nudges")


@op("item/moveByGuid: move a keys part to the pads track", "item/moveByGuid")
@tidy
def _(t):
    gk, _ = busy_track(t, "Keys", 1, lambda g, it: not it["lock"], role="with an unlocked item")
    pads = [(g, tr) for g, tr in t.tracks() if g != gk and tr["freemode"] != 2]
    gp, _ = next(((g, tr) for g, tr in pads if tr["name"].startswith("Pads")), pads[0] if pads else (None, None))
    if gp is None:
        raise Skip("no other track outside fixed lanes to move the item to")
    parts = track_items(t, gk)
    g, it = parts[-1]
    if it["lock"]:
        raise Skip("the track's last item is locked")
    pads = t.items(lambda g, x: x["track"] == gp)
    idx = sum(1 for _, x in pads if x["pos"] <= it["pos"])
    t.ok("item/moveByGuid", guid=g, destTrackGuid=gp)
    t.expect({f"items.{g}.track": gp, f"items.{g}.idx": idx, f"items.{g}.pos": it["pos"],
              **{f"items.{x}.idx": xi["idx"] + 1 for x, xi in pads if xi["pos"] > it["pos"]}})
    check_undo(t)
    revert(t, 1, "the move")


def region_items(t):
    """Items playing in the chorus, or in the first region that has any."""
    regions = sorted((m for m in t.d["markers"].values() if m.get("end") is not None),
                     key=lambda m: (m["name"] != "Chorus", m["pos"]))
    for r in regions:
        found = t.items(lambda g, it: it["pos"] < r["end"] - 1e-6 and it["pos"] + it["len"] > r["pos"] + 1e-6)
        if found:
            return r, found
    raise Skip("no region with items")


@op("item/setColor: colour the chorus items, then reset one", "item/setColor")
@tidy
def _(t):
    region, found = region_items(t)
    amber = 0x1000000 | 0xE9C46A
    for g, it in found:
        ti, ii = where(t, g)
        t.ok("item/setColor", trackIdx=ti, itemIdx=ii, color=amber)
    t.expect({f"items.{g}.color": amber for g, _ in found})
    before = t.flat
    g, it = found[0]
    t.ok("item/setColor", trackIdx=where(t, g)[0], itemIdx=where(t, g)[1], color=0)
    t.expect({f"items.{g}.color": 0})
    check_undo(t, before, t.digest())
    revert(t, len(found) + 1, f"colouring the {region['name']} items")


@op("item/setLock: lock the bass, then unlock it", "item/setLock")
@tidy
def _(t):
    gb, _ = busy_track(t, "Bass DI", 1, lambda g, it: it["lock"] == 0, role="with an unlocked item")
    g, it = track_items(t, gb, lambda g, it: it["lock"] == 0)[0]
    ti, ii = where(t, g)
    t.ok("item/setLock", trackIdx=ti, itemIdx=ii, locked=1)
    t.expect({f"items.{g}.lock": lambda v: int(v) & 1 == 1})
    check_undo(t)
    t.digest()
    # A locked item stays put when the phone nudges it, and stays whole when
    # the phone deletes it or switches its take, as in REAPER (whose remove,
    # cut, split and take actions all leave a locked item alone); the phone
    # is told why.
    for cmd, params in (("item/moveByGuid", {"guid": g, "position": it["pos"] + 1.0}),
                        ("item/delete", {"itemGuid": g}),
                        ("item/setActiveTake", {"itemGuid": g, "takeIdx": 0})):
        r = t.send(cmd, awaited=True, **params)
        if r.get("success") or r.get("error", {}).get("code") != "ITEM_LOCKED":
            raise Mismatch(f"{cmd} on a locked item answered {r}")
    t.c.drain(0.5)
    t.expect({})
    t.ok("item/setLock", trackIdx=ti, itemIdx=ii, locked=0)
    t.expect({f"items.{g}.lock": 0})


NOTE = "Comp: verse 2 from take 3 — “warmer” 🎸\nBridge: re-record, señor\r\n\ttabbed \"quoted\" back\\slash"


@op("item/setNotes + getNotes: unicode and newlines", "item/setNotes", "item/getNotes")
@tidy
def _(t):
    # An item that already has a note (the user edits it), else any item.
    g, it = (t.items(lambda g, it: not it["notes"].startswith("0:")) or [t.item()])[0]
    ti, ii = where(t, g)
    lua_item = f'local it = reaper.GetTrackMediaItem(reaper.GetTrack(0, {ti - 1}), {ii})\n'
    have = reaper(lua_item + 'return select(2, reaper.GetSetMediaItemInfo_String(it, "P_NOTES", "", false))') or ""
    # REAPER stores notes in the undo state as lines: after undo and redo it
    # gives the text back with CRLF line ends. Ask REAPER what it gives back.
    redone = reaper(lua_item + f"""
reaper.Undo_BeginBlock()
reaper.GetSetMediaItemInfo_String(it, "P_NOTES", {json.dumps(NOTE, ensure_ascii=False)}, true)
reaper.Undo_EndBlock("Item notes", -1)
reaper.Undo_DoUndo2(0)
reaper.Undo_DoRedo2(0)
local s = select(2, reaper.GetSetMediaItemInfo_String(it, "P_NOTES", "", false))
reaper.Undo_DoUndo2(0)
return s""")
    wait_equal_but_selection(t, t.op_start, "REAPER's own undo of an item note did not restore it")
    r = t.send("item/getNotes", awaited=True, trackIdx=ti, itemIdx=ii)
    if not r.get("success") or r["payload"]["notes"] != have:
        raise Mismatch(f"item/getNotes {r}; REAPER has {have!r}")
    t.ok("item/setNotes", trackIdx=ti, itemIdx=ii, notes=NOTE)
    t.expect({f"items.{g}.notes": str_hash(NOTE)})
    r = t.send("item/getNotes", awaited=True, trackIdx=ti, itemIdx=ii)
    if not r.get("success") or r["payload"]["notes"] != NOTE:
        raise Mismatch(f"item/getNotes after setNotes: {r}; wanted {NOTE!r}")
    check_undo(t, after={**t.flat, f"items.{g}.notes": str_hash(redone)})
    revert(t, 1, "the note")


@op("item/delete: delete a stray kick hit", "item/delete")
@tidy
def _(t):
    # Deleting the second item: the ones after it move up a place.
    try:
        gk, _ = busy_track(t, "Kick", 3)
    except Skip:
        gk, _ = busy_track(t, "Kick", 2)
    hits = track_items(t, gk)
    g, it = hits[1]
    if it["lock"]:
        raise Skip("the item to delete is locked")
    ti, ii = where(t, g)
    t.ok("item/delete", trackIdx=ti, itemIdx=ii)
    t.expect({f"items.{g}.*": ANY, **{f"items.{x}.idx": xi["idx"] - 1 for x, xi in hits[2:]}})
    if g in t.d["items"]:
        raise Mismatch(f"item/delete left the item: {t.d['items'][g]}")
    check_undo(t)
    revert(t, 1, "the delete")


@op("item/goto", "item/goto")
@tidy
def _(t):
    g, it = t.item(lambda g, it: abs(it["pos"] - t.d["project"]["cursor"]) > 0.1)
    cursor = t.d["project"]["cursor"]
    t.ok("item/goto", trackIdx=where(t, g)[0], itemIdx=where(t, g)[1])
    t.expect({"project.cursor": approx(it["pos"], 1e-6), **t.meter(it["pos"])})
    t.digest()
    t.ok("transport/seek", position=cursor)
    t.expect({"project.cursor": approx(cursor, 1e-6), **t.meter(cursor)})


# ----------------------------------------------------------------------------
# Selection

@op("item selection: select, next, prev, toggle, unselect all",
    "item/selectNext", "item/selectPrev", "item/toggleSelect", "item/unselectAll")
@tidy
def _(t):
    gk, _ = busy_track(t, "Kick", 3)
    hits = track_items(t, gk)
    by_pos = sorted(hits, key=lambda gi: gi[1]["pos"])
    ti = t.d["tracks"][gk]["pos"]
    # REAPER records a change of item selection as an undo step when the
    # user's undo settings include item selection (undomask bit 0, on by
    # default), as for a click on an item. A phone tap is one such step, or
    # none. REAPER 6.0 can't report undomask to a script: there, one step or
    # none, whichever.
    mask = reaper("return harness.config('undomask')")
    records = None if mask is None else bool(int(mask) & 1)

    def as_one_undo_step(before, prior):
        after = t.flat
        top = t.d["undo"]["can_undo"]
        if top == prior and records is not True:
            return
        if top != "REAmo: Change item selection" or records is False:
            raise Mismatch(f"a selection change from the phone left undo step {top!r} (before: {prior!r}; "
                           f"undomask {mask})")
        t.undo_redo(before, after)

    def tap(cmd, want_selected, **kw):
        before, prior = t.flat, t.d["undo"]["can_undo"]
        r = t.send(cmd, awaited=True, **kw)
        t.expect(selection_is(t, want_selected))
        as_one_undo_step(before, prior)
        return r

    tap("item/select", {by_pos[0][0]}, trackIdx=ti, itemIdx=by_pos[0][1]["idx"])

    def step(cmd, cur, want, **kw):
        if want is None:
            r = t.send(cmd, awaited=True, trackIdx=ti, itemIdx=cur[1]["idx"], **kw)
            if r.get("success"):
                raise Mismatch(f"{cmd} from the first/last item without wrap: {r}")
            t.expect({})
            return
        r = tap(cmd, {want[0]}, trackIdx=ti, itemIdx=cur[1]["idx"], **kw)
        if not r.get("success") or r["payload"] != {"trackIdx": ti, "itemIdx": want[1]["idx"]}:
            raise Mismatch(f"{cmd} answered {r}; REAPER's next item by position is #{want[1]['idx']}")

    step("item/selectNext", by_pos[0], by_pos[1])
    step("item/selectNext", by_pos[1], by_pos[2])
    step("item/selectPrev", by_pos[2], by_pos[1])
    step("item/selectPrev", by_pos[1], by_pos[0])
    step("item/selectPrev", by_pos[0], None)
    step("item/selectPrev", by_pos[0], by_pos[-1], wrap=1)
    step("item/selectNext", by_pos[-1], None)
    step("item/selectNext", by_pos[-1], by_pos[0], wrap=1)
    # Multi-select: tap a second item on another track, then untap it.
    other = t.item(lambda g, it: it["track"] != gk)[0]
    tap("item/toggleSelect", {by_pos[0][0], other}, guid=other)
    tap("item/toggleSelect", {by_pos[0][0]}, guid=other)
    t.ok("item/unselectAll")
    t.expect(selection_is(t, set()))
    restore_selection(t)


@op("item/selectInTimeSel: select what is under the time selection", "item/selectInTimeSel")
@tidy
def _(t):
    if not t.d["items"]:
        raise Skip("no items")
    a, b = 2.0, 3.0
    timesel = list(t.d["project"]["timesel"])
    t.ok("timeSelection/set", start=a, end=b)
    # Loop points follow the time selection by REAPER's default preference.
    t.expect({"project.timesel.0": approx(a), "project.timesel.1": approx(b)}, allow=("project.loop.*",))
    # REAPER's "Select all items in current time selection": every item
    # overlapping it, on any track, and nothing else.
    under = {g for g, it in t.d["items"].items() if it["pos"] < b and it["pos"] + it["len"] > a}
    t.ok("item/selectInTimeSel")
    t.expect(selection_is(t, under))
    if timesel[1] > timesel[0]:
        t.ok("timeSelection/set", start=timesel[0], end=timesel[1])
    else:
        t.ok("timeSelection/clear")
    restore_selection(t)
    t._wait_equal(t.op_start, "the time selection and item selection were not restored")


# ----------------------------------------------------------------------------
# Fixed lanes and comping

def check_lane_state(t, g):
    r = t.send("lanes/getState", awaited=True, trackGuid=g)
    tr = t.d["tracks"][g]
    if not r.get("success"):
        raise Mismatch(f"lanes/getState failed: {r}")
    p = r["payload"]
    want = {"numLanes": int(tr["nlanes"]), "freeMode": int(tr["freemode"]), "compTargetLane": comp_target(tr),
            "lanes": [{"lane": i, "plays": int(l["plays"]), "name": l["name"]} for i, l in enumerate(tr["lanes"])]}
    if p != want:
        raise Mismatch(f"lanes/getState {p}\n    REAPER {want}")


@op("lanes/setLanePlays: audition lane 2, then layer lane 3", "lanes/getState", "lanes/setLanePlays")
@tidy
def _(t):
    g, tr = vox_lanes(t)
    if tr["nlanes"] < 3:
        raise Skip("fewer than three lanes")
    check_lane_state(t, g)
    # Lane plays as REAPER sets them for its own lane buttons; REAPER itself
    # adjusts the other lanes (an exclusive lane silences the rest).
    for lane, plays in ((1, 1), (2, 2)):
        native = lua_track(g) + f"""
reaper.Undo_BeginBlock()
reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:{lane}", {plays})
reaper.Undo_EndBlock("Lane plays", -1)
"""
        like_native(t, native, lambda: t.ok("lanes/setLanePlays", trackGuid=g, laneIndex=lane, plays=plays),
                    f"setting lane {lane + 1} to play {('', 'exclusively', 'layered')[plays]}")
        if t.d["tracks"][g]["lanes"][lane]["plays"] != plays:
            raise Mismatch(f"lane {lane + 1} plays {t.d['tracks'][g]['lanes'][lane]['plays']}, asked for {plays}")
        check_lane_state(t, g)
    r = t.send("lanes/setLanePlays", awaited=True, trackGuid=g, laneIndex=int(tr["nlanes"]) + 4, plays=1)
    if r.get("success"):
        raise Mismatch(f"lanes/setLanePlays for a lane the track lacks succeeded: {r}")
    t.expect({})
    revert(t, 2, "the lane auditions")


@op("lanes: comp the lead vox by swiping, move and delete comp areas",
    "lanes/swipeComp", "lanes/moveCompUp", "lanes/moveCompDown", "lanes/deleteCompArea")
@tidy
def _(t):
    g, tr = vox_lanes(t)
    if tr["nlanes"] < 3:
        raise Skip("fewer than three lanes")
    check_lane_state(t, g)
    rec = lane_items(t, g, 1)
    if not rec:
        raise Skip("lane 2 has no recording")
    start, end = rec[0][1]["pos"], rec[0][1]["pos"] + rec[0][1]["len"]
    if end - start < 3:
        raise Skip("recordings too short to comp")
    # The user has the bass selected on the computer; comping must not lose that.
    other = (t.items(lambda x, it: t.d["tracks"][it["track"]]["name"] == "Bass DI")
             or t.items(lambda x, it: it["track"] != g) or [(None, None)])[0][0]
    if other is None:
        raise Skip("no item on another track")
    t.ok("item/toggleSelect", guid=other)
    t.expect(selection_is(t, {other}))
    a, b = start + 1.2, start + 3.2
    n0 = int(tr["nlanes"])
    swipe(t, g, 1, a, b)
    check_lane_state(t, g)
    # A second swipe from the last recording lane, before the first one.
    last = int(t.d["tracks"][g]["nlanes"]) - 1
    swipe(t, g, last, start + 0.2, start + 1.2)
    comp = comp_target(t.d["tracks"][g])
    areas = lane_items(t, g, comp)
    if len(areas) != 2:
        raise Mismatch(f"two swipes left comp lane {comp} with {areas}")
    first = [x for x, it in areas if abs(it["pos"] - a) < 1e-6][0]

    # Select the first comp area (tap it, adding to the selection) and move it up and down.
    t.digest()
    t.ok("item/toggleSelect", guid=first)
    t.expect(selection_is(t, {other, first}))
    for cmd, action in (("lanes/moveCompUp", 42707), ("lanes/moveCompDown", 42708), ("lanes/moveCompDown", 42708)):
        before = t.flat
        like_native(t, f"reaper.Main_OnCommand({action}, 0)", lambda: t.ok(cmd, trackGuid=g), cmd)
        moved = [x for x, it in new_items(t, before) if it["track"] == g]
        # The user's other selection stays as it was.
        if t.d["items"][other]["sel"] != 1:
            raise Mismatch(f"{cmd} unselected the user's {other[:9]}")
        if moved:
            first = moved[0]

    # Delete the second comp area by its index; the user's selection stays.
    t.digest()
    second = [x for x, it in lane_items(t, g, comp) if abs(it["pos"] - (start + 0.2)) < 1e-6]
    if not second:
        raise Mismatch(f"the second comp area is gone: {lane_items(t, g, comp)}")
    second = second[0]
    ii = t.d["items"][second]["idx"]
    # One undo block, as the phone's command makes: unselecting is an undo
    # point of its own in REAPER, which one undo would leave behind.
    native = lua_track(g) + f"""
reaper.Undo_BeginBlock()
local keep = {{}}
for i = 0, reaper.CountMediaItems(0) - 1 do
  local it = reaper.GetMediaItem(0, i)
  if reaper.IsMediaItemSelected(it) then keep[#keep + 1] = it end
end
reaper.Main_OnCommand(40289, 0)
reaper.SetMediaItemSelected(reaper.GetTrackMediaItem(tr, {ii}), true)
reaper.Main_OnCommand(42642, 0) -- Fixed lane comp area: Delete comp area
for _, it in ipairs(keep) do
  if reaper.ValidatePtr2(0, it, "MediaItem*") then reaper.SetMediaItemSelected(it, true) end
end
reaper.Undo_EndBlock("Delete comp area", -1)
"""
    like_native(t, native, lambda: t.ok("lanes/deleteCompArea", trackGuid=g, itemIdx=ii),
                "deleting a comp area, keeping the user's selection")
    # Two swipes, three moves and a delete, and the two taps on items where
    # REAPER's undo settings include item selection.
    taps = 2 if int(reaper("return harness.config('undomask')")) & 1 else 0
    revert(t, 6 + taps, f"the comp ({n0} lanes)")


@op("lanes/createCompLane on the vox keeps the user's track selection; setCompTarget picks where comps land",
    "lanes/createCompLane", "lanes/setCompTarget")
@tidy
def _(t):
    g, tr = vox_lanes(t)
    # The user has two other tracks selected in REAPER.
    others = [x for x, _ in t.tracks() if x != g][:2]
    if len(others) < 2:
        raise Skip("too few tracks")
    for x, xt in t.tracks():
        want = int(x in others)
        if xt["sel"] != want:
            t.ok("track/setSelected", trackGuid=x, selected=want)
    t.expect({f"tracks.{x}.sel": int(x in others) for x, _ in t.tracks()})
    native = lua_track(g) + """
local keep = {}
for i = 0, reaper.CountTracks(0) - 1 do keep[i] = reaper.IsTrackSelected(reaper.GetTrack(0, i)) end
reaper.SetOnlyTrackSelected(tr)
reaper.Main_OnCommand(42797, 0) -- Track lanes: Insert new comp lane
for i = 0, reaper.CountTracks(0) - 1 do reaper.SetTrackSelected(reaper.GetTrack(0, i), keep[i]) end
"""
    like_native(t, native, lambda: t.ok("lanes/createCompLane", trackGuid=g), "inserting a comp lane on the vox")
    if t.d["tracks"][g]["nlanes"] != tr["nlanes"] + 1:
        raise Mismatch(f"no comp lane added: {t.d['tracks'][g]['nlanes']} lanes, was {tr['nlanes']}")
    check_lane_state(t, g)
    # Make lane 2 (the other comp lane) the target: the next swipe lands there.
    target = 1
    before = t.digest()
    t.ok("lanes/setCompTarget", trackGuid=g, laneIndex=target)
    t.expect({f"tracks.{g}.lanerec": lambda v: int(v.split()[1]) == target})
    check_undo(t, before, t.digest())
    check_lane_state(t, g)
    lanes = int(t.d["tracks"][g]["nlanes"])
    rec = lane_items(t, g, lanes - 1)
    if not rec:
        raise Skip("no recording on the last lane")
    s = rec[0][1]["pos"]
    swipe(t, g, lanes - 1, s + 2.0, s + 3.0)
    landed = [it["lane"] for x, it in t.d["items"].items() if it["track"] == g and abs(it["pos"] - (s + 2.0)) < 1e-6]
    if target not in landed:
        raise Mismatch(f"after setCompTarget {target} the swipe landed on lanes {landed}")
    r = t.send("lanes/setCompTarget", awaited=True, trackGuid=g, laneIndex=lanes + 3)
    if r.get("success"):
        raise Mismatch(f"lanes/setCompTarget for a lane the track lacks succeeded: {r}")
    revert(t, 3, "the comp lane")


HEAVY = """
reaper.Undo_BeginBlock()
local src = reaper.GetMediaItemTake_Source(reaper.GetActiveTake(reaper.GetTrackMediaItem(tr, 0)))
local file = reaper.GetMediaSourceFileName(src, "")
local n = reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES")
for i = 0, {count} - 1 do
  local it = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", 30 + i * 0.25)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 0.2)
  reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", i % n)
  local tk = reaper.AddTakeToMediaItem(it)
  reaper.SetMediaItemTake_Source(tk, reaper.PCM_Source_CreateFromFile(file))
  reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "punch " .. i, true)
end
reaper.UpdateArrange()
reaper.Undo_EndBlock("Record punch-ins", -1)
local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
return #chunk
"""


@op("lanes/setCompTarget on a lane-heavy track keeps every item; items event caps at 512", "lanes/setCompTarget")
@tidy
def _(t):
    g, tr = vox_lanes(t)
    if not any(it["track"] == g and it["takes"] for it in t.d["items"].values()):
        raise Skip("no recording on the comp track")
    # The singer punched in 700 times: the track's chunk is several times
    # the 64 KB a chunk read starts with, and the project has more items
    # than the items event carries.
    size = reaper(lua_track(g) + HEAVY.format(count=700), timeout=30)
    if size <= 256 * 1024:
        raise Mismatch(f"the lane-heavy track's chunk is only {size} bytes")
    t.converge(timeout=6.0)
    before = t.digest()
    lane = 1 if comp_target(t.d["tracks"][g]) != 1 else 0
    t.ok("lanes/setCompTarget", trackGuid=g, laneIndex=lane)
    t.expect({f"tracks.{g}.lanerec": lambda v: int(v.split()[1]) == lane}, timeout=6.0)
    check_undo(t, before, t.digest())
    revert(t, 2, "the punch-ins")


# ----------------------------------------------------------------------------
# Peaks

DURATION = [4096, 1024, 256, 64, 16, 4, 1]
PEAKRATE = [0.0625, 0.25, 1, 4, 16, 64, 256]

REAPER_PEAKS = """
local tk = reaper.GetMediaItemTakeByGUID(0, "%s")
local rate, start, n, ch = %r, %r, %d, %d
local buf = reaper.new_array(n * 2 * 2)
local r = reaper.GetMediaItemTake_Peaks(tk, rate, start, 2, n, 0, buf)
local got = r %% 1048576
local out = {}
for p = 0, n - 1 do
  for c = 0, ch - 1 do
    if p < got then
      out[#out + 1] = buf[got * 2 + p * 2 + c + 1]
      out[#out + 1] = buf[p * 2 + c + 1]
    else
      out[#out + 1] = 0; out[#out + 1] = 0
    end
  end
end
return out
"""


def tiles(frame):
    """Decode a binary peaks frame (extension/src/core/binary_protocol.zig)."""
    if frame[0] != 2:
        raise Mismatch(f"peaks frame type {frame[0]}")
    count = struct.unpack_from("<H", frame, 2)[0]
    off, out = 4, []
    for _ in range(count):
        lod, ch, idx, npk, _r, epoch, start, itempos = struct.unpack_from("<BBHHHIff", frame, off)
        off += 20
        guid = frame[off:off + 40].rstrip(b"\0").decode()
        off += 40
        data = list(struct.unpack_from(f"<{npk * ch * 2}b", frame, off))
        off += npk * ch * 2
        out.append({"guid": guid, "lod": lod, "idx": idx, "npk": npk, "ch": ch, "item": itempos, "data": data})
    if off != len(frame):
        raise Mismatch(f"peaks frame has {len(frame) - off} trailing bytes")
    return out


def next_tiles(t, after, timeout=4.0):
    deadline = time.time() + timeout
    while len(t.c.binary) <= after:
        if time.time() > deadline:
            raise Mismatch("no peaks frame arrived")
        t.c.drain(0.1)
    t.c.drain(0.3)
    out = {}
    for frame in t.c.binary[after:]:
        for tile in tiles(frame):
            out[(tile["guid"], tile["lod"], tile["idx"])] = tile
    return list(out.values())


_WAVS = {}


def wav_channels(path):
    """A 16-bit PCM WAV's samples per channel, as REAPER reads them (v / 32768)."""
    if path not in _WAVS:
        import wave
        with wave.open(path, "rb") as w:
            ch, n = w.getnchannels(), w.getnframes()
            if w.getsampwidth() != 2:
                raise Skip(f"{path} is not 16-bit PCM")
            raw = struct.unpack(f"<{n * ch}h", w.readframes(n))
            _WAVS[path] = (w.getframerate(), [[v / 32768 for v in raw[c::ch]] for c in range(ch)])
    return _WAVS[path]


def wav_peak(path, offs, rate, k0, k1, slack, loop=False):
    """(min, max) per channel of the source over peaks k0..k1 at `rate`
    peaks/s from source time `offs`, widened by `slack` samples each side.
    An item that loops its source (REAPER's "Loop source") plays the file
    again from its start past its end; one that does not plays silence."""
    sr, chans = wav_channels(path)
    a = max(0, int((offs + k0 / rate) * sr) - slack)
    out = []
    for c in chans:
        n = len(c)
        end = max(a + 1, int((offs + k1 / rate) * sr) + slack)
        if loop:
            seg = [c[i % n] for i in range(a, end)]
        else:
            seg = c[a:min(n, end)] or [0.0]
        out.append((min(seg), max(seg)))
    return out


def check_tiles(t, ts, takes, lod):
    """Every tile is one of `takes` (active take GUID -> item), at the LOD
    the viewport needs, and shows that stretch of the take as REAPER does.

    REAPER's GetMediaItemTake_Peaks resamples its peak file, so the same
    window's peaks differ slightly with where a request starts (the
    extension asks for whole items, this check for single tiles). A tile
    matches when nearly all its values are within 2 of REAPER's for that
    tile, and every value lies within what the source WAV holds around that
    window (5 ms either side, the reach of REAPER's resampling). An item
    that loops its source is held to the WAV alone: REAPER's readings of a
    looped source differ with the request's start and length by more than
    that tolerance."""
    bad = []
    for tile in ts:
        it = takes.get(tile["guid"])
        if it is None:
            bad.append(f"tile for take {tile['guid'][:9]}, not an audio take on the subscribed track")
            continue
        if tile["lod"] != lod:
            bad.append(f"tile {tile['idx']} at LOD {tile['lod']}, viewport needs {lod}")
        if abs(tile["item"] - it["pos"]) > 1e-4:
            bad.append(f"tile {tile['idx']} says item at {tile['item']}, REAPER {it['pos']}")
        tk = it["takes"][it["active"]]
        rate, dur, per = PEAKRATE[tile["lod"]], DURATION[tile["lod"]], 2 * tile["ch"]
        label = f"take {tile['guid'][:9]} (item at {it['pos']}) LOD {tile['lod']} tile {tile['idx']}"
        want = reaper(REAPER_PEAKS % (tile["guid"], rate, it["pos"] + tile["idx"] * dur, tile["npk"], tile["ch"]))
        want = [max(-128, min(127, round(v * 127))) for v in want]
        path, loop = reaper(f'local tk = reaper.GetMediaItemTakeByGUID(0, "{tile["guid"]}") '
                            f'return {{reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(tk), ""), '
                            f'reaper.GetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(tk), "B_LOOPSRC") == 1}}')
        # REAPER resamples a looped source's peaks differently for every
        # request start and length (a tile can come from any of the
        # extension's cached requests), so there only the WAV decides.
        off = [] if loop else [i for i, (a, b) in enumerate(zip(tile["data"], want)) if abs(a - b) > 2]
        if len(off) > 0.03 * len(want):
            bad.append(f"{label}: {len(off)} of {len(want)} peak values differ from REAPER's: "
                       + ", ".join(f"peak {i // per} {'min' if i % 2 == 0 else 'max'} phone {tile['data'][i]} "
                                   f"REAPER {want[i]}" for i in off[:6]))
            continue
        k0 = round(tile["idx"] * dur * rate)
        for j in range(tile["npk"]):
            near = wav_peak(path, tk["offs"], rate / tk["rate"], k0 + j, k0 + j + 1, wav_channels(path)[0] // 200, loop)
            for c, (lo, hi) in enumerate(near):
                for v in tile["data"][j * per + 2 * c:j * per + 2 * c + 2]:
                    if not round(lo * 127) - 2 <= v <= round(hi * 127) + 2:
                        bad.append(f"{label} peak {j} channel {c}: {v}, but the WAV there spans "
                                   f"{round(lo * 127)}..{round(hi * 127)}")
                        break
    if bad:
        raise Mismatch("peaks:\n    " + "\n    ".join(bad[:12]))


@op("peaks: subscribe, scroll and zoom the kick, follow an edit, unsubscribe",
    "peaks/subscribe", "peaks/updateViewport", "peaks/unsubscribe")
@tidy
def _(t):
    playable = t.playable_audio()
    gk, tr = busy_track(t, "Kick", 2, lambda g, it: g in playable, role="with two items of playable audio")
    hits = track_items(t, gk, lambda g, it: g in playable)
    takes = lambda: {it["takes"][it["active"]]["guid"]: it for g, it in t.items(lambda g, it: it["track"] == gk)}
    # REAPER builds peak files in the background after opening the project.
    guid0 = hits[0][1]["takes"][hits[0][1]["active"]]["guid"]
    deadline = time.time() + 15
    while reaper(f'local b = reaper.new_array(4); return reaper.GetMediaItemTake_Peaks(reaper.GetMediaItemTakeByGUID(0, "{guid0}"), 1, {hits[0][1]["pos"]}, 2, 1, 0, b) % 1048576') == 0:
        if time.time() > deadline:
            raise Mismatch("REAPER has no peaks for the kick 15 s after opening the project")
        time.sleep(0.2)
    ti = tr["pos"]
    n = len(t.c.binary)
    t.ok("peaks/subscribe", range={"start": ti, "end": ti}, sampleCount=30,
         viewport={"start": 0, "end": 8, "widthPx": 390})
    ts = next_tiles(t, n)
    check_tiles(t, ts, takes(), 6)
    # The tiles reach every kick hit in view (and the half-screen buffer either side).
    shown = {tile["guid"] for tile in ts}
    want = {k for k, it in takes().items() if it["pos"] < 12 and it["pos"] + it["len"] > -4}
    if shown != want:
        raise Mismatch(f"peaks for takes {sorted(x[:9] for x in shown)}, kick hits in view {sorted(x[:9] for x in want)}")
    # Scroll right.
    t.c.drain(0.6)
    n = len(t.c.binary)
    t.ok("peaks/updateViewport", viewport={"start": 6, "end": 14, "widthPx": 390})
    check_tiles(t, next_tiles(t, n), takes(), 6)
    # Zoom out to the whole song.
    n = len(t.c.binary)
    t.ok("peaks/updateViewport", viewport={"start": 0, "end": 40, "widthPx": 390})
    check_tiles(t, next_tiles(t, n), takes(), 5)
    # Nudge a hit: its peaks follow it.
    g, it = hits[0]
    t.c.drain(0.6)
    n = len(t.c.binary)
    t.ok("item/moveByGuid", guid=g, position=it["pos"] + 0.3)
    t.expect({f"items.{g}.pos": approx(it["pos"] + 0.3, 1e-6)})
    ts = [x for x in next_tiles(t, n) if x["guid"] == it["takes"][it["active"]]["guid"]]
    if not ts:
        raise Mismatch("no peaks for the nudged kick hit")
    check_tiles(t, ts, takes(), 5)
    revert(t, 1, "the nudge")
    t.ok("peaks/unsubscribe")
    t.c.drain(0.6)
    n = len(t.c.binary)
    t.ok("item/moveByGuid", guid=g, position=it["pos"] + 0.3)
    t.expect({f"items.{g}.pos": approx(it["pos"] + 0.3, 1e-6)})
    revert(t, 1, "the nudge")
    t.c.drain(0.6)
    if len(t.c.binary) != n:
        raise Mismatch(f"{len(t.c.binary) - n} peaks frames after peaks/unsubscribe")
    r = t.send("peaks/updateViewport", awaited=True, viewport={"start": 0, "end": 8, "widthPx": 390})
    if r.get("success") or r.get("error", {}).get("code") != "NOT_SUBSCRIBED":
        raise Mismatch(f"peaks/updateViewport after unsubscribe: {r}")

