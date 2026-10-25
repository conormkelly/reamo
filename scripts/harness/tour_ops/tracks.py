"""Creating, duplicating and deleting tracks, track subscriptions, inputs, sends, receives, hardware outputs and routing."""
import fnmatch
import functools
import time

from reamo_client import reaper
from tour import ANY, Mismatch, Skip, approx, diff, op

# ----------------------------------------------------------------------------
# Helpers

TRACK_GUIDS = """
local out = {}
for i = 0, reaper.CountTracks(0) - 1 do out[#out + 1] = reaper.GetTrackGUID(reaper.GetTrack(0, i)) end
return out
"""

# The name REAPER shows for every track ("Track 15" for an unnamed one), by GUID.
DISPLAY_NAMES = """
local out = {master = "MASTER"}
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  out[reaper.GetTrackGUID(tr)] = select(2, reaper.GetTrackName(tr))
end
return out
"""

ITEM_GUIDS_ON = """
local want = {%s}
local out = {}
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  if want[reaper.GetTrackGUID(tr)] then
    for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
      out[#out + 1] = select(2, reaper.GetSetMediaItemInfo_String(reaper.GetTrackMediaItem(tr, j), "GUID", "", false))
    end
  end
end
return out
"""

SET_SELECTION = """
local want = {%s}
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  reaper.SetMediaTrackInfo_Value(tr, "I_SELECTED", want[reaper.GetTrackGUID(tr)] or 0)
end
reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(0), "I_SELECTED", want.master or 0)
"""


def lua_set(guids):
    return ", ".join(f'["{g}"] = 1' for g in guids)


def prefer(t, name, pred):
    """The band session's track for this flow, or in another project the first track that fits."""
    for g, tr in t.tracks():
        if tr["name"] == name and pred(g, tr):
            return g, tr
    return t.track(pred)


def as_list(v):
    """A Lua table REAPER returned; an empty one comes back as None or {}."""
    return list(v) if isinstance(v, (list, tuple)) else []


def close(a, b, tol):
    return isinstance(a, (int, float)) and isinstance(b, (int, float)) and abs(a - b) <= tol


def tidy(fn):
    """If the op fails midway, undo its edits so later ops still start from
    the band session as it was (the failure is still reported)."""
    @functools.wraps(fn)
    def run(t):
        try:
            fn(t)
        except Exception:
            recover(t)
            raise
    return run


def recover(t):
    try:
        for _ in range(8):
            left = diff(t.op_start, t.digest())
            if not left:
                return
            if all(k.endswith(".sel") for k in left):
                set_selection(t, t.op_start)
                continue
            if not t.d["undo"]["can_undo"]:
                break
            t.send("undo/do", awaited=True)
            t.c.drain(0.3)
        left = diff(t.op_start, t.digest())
        if left:
            print(f"      could not restore the project after the failure; {len(left)} facts differ, e.g. "
                  + ", ".join(sorted(left)[:5]))
    except Exception as e:  # never mask the op's own failure
        print(f"      restoring the project after the failure raised {type(e).__name__}: {e}")


def selected_in(flat):
    return [k.split(".")[1] for k, v in flat.items() if k.startswith("tracks.") and k.endswith(".sel") and v]


def set_selection(t, flat):
    """Select exactly the tracks selected in `flat`, as the user would in REAPER."""
    reaper(SET_SELECTION % lua_set(selected_in(flat)))


def wait_equal_except(t, target, ignore, what, timeout=3.0):
    """Like the tour's exact comparison, but facts matching `ignore` may differ."""
    deadline = time.time() + timeout
    while True:
        delta = {k: v for k, v in diff(target, t.digest()).items()
                 if not any(fnmatch.fnmatchcase(k, p) for p in ignore)}
        if not delta:
            return
        if time.time() > deadline:
            lines = [f"{k}: {a!r} vs {b!r}" for k, (a, b) in sorted(delta.items())][:20]
            raise Mismatch(what + ":\n    " + "\n    ".join(lines))
        t.c.drain(0.15)


def undo_redo_except(t, before, after, ignore):
    r = t.send("undo/do", awaited=True)
    if not r.get("success"):
        raise Mismatch(f"undo/do failed: {r}")
    wait_equal_except(t, before, ignore, "after undo/do, the project did not return to its state before the op")
    r = t.send("redo/do", awaited=True)
    if not r.get("success"):
        raise Mismatch(f"redo/do failed: {r}")
    wait_equal_except(t, after, ignore, "after redo/do, the project did not return to its state after the op")


def undo_to(t, target, ignore=()):
    """Undo once from the client; the project must be back at `target`."""
    r = t.send("undo/do", awaited=True)
    if not r.get("success"):
        raise Mismatch(f"undo/do failed: {r}")
    wait_equal_except(t, target, ignore, "undoing the op did not restore the project")


def step(t, act, changes, allow=(), undoable=True, keep=False):
    """One user action inside an op: perform it, require exactly `changes`,
    undo and redo it from the client, then (unless `keep`) undo it so the
    next action starts from the same project. Returns what `act` returned."""
    before = t.digest()
    result = act()
    t.flat = before
    t.expect(changes, allow=allow)
    after = t.flat
    if undoable:
        t.undo_redo(before, after)
    if not keep:
        undo_to(t, before)
    return result


def wait_new_tracks(t, before, count, timeout=3.0):
    """GUIDs of tracks REAPER has that `before` lacks, in project order, once there are `count`."""
    deadline = time.time() + timeout
    while True:
        new = [g for g in as_list(reaper(TRACK_GUIDS)) if g not in before]
        if len(new) >= count:
            return new
        if time.time() > deadline:
            raise Mismatch(f"REAPER has {len(new)} new tracks, expected {count}")
        t.c.drain(0.1)


def items_on(guids):
    return as_list(reaper(ITEM_GUIDS_ON % lua_set(guids))) if guids else []


def folder_span(t, g):
    """The track and, for a folder parent, every track in its folder."""
    ts = t.tracks()
    start = [x for x, _ in ts].index(g)
    span, level = [], 0
    for x, tr in ts[start:]:
        span.append(x)
        level += int(tr["depth"])
        if level <= 0:
            break
    return span


def shifted(t, from_pos, by, exclude=()):
    """Position changes for every track at or after `from_pos`."""
    return {f"tracks.{g}.pos": tr["pos"] + by for g, tr in t.tracks() if tr["pos"] >= from_pos and g not in exclude}


def track_copy_facts(t, g, copy_of=None):
    """What a duplicate must copy: everything the user set on the track.
    With `copy_of` (original GUID -> copy GUID), a send to a track copied
    alongside it is shown going to that track's copy, as REAPER routes the
    copies among themselves."""
    tr = t.d["tracks"][g]
    keys = ("name", "vol", "pan", "mute", "solo", "arm", "mon", "input", "fxen", "color", "depth",
            "freemode", "nlanes", "nchan", "mainsend", "envs", "lanes", "hw")
    out = {k: tr[k] for k in keys}
    out["fx"] = [(f["name"], f["enabled"], f["offline"], f["params"]) for f in sorted(tr["fx"].values(), key=lambda f: f["pos"])]
    out["infx"] = [f["name"] for f in sorted(tr["infx"].values(), key=lambda f: f["pos"])]
    out["sends"] = [{k: (copy_of.get(v, v) if copy_of and k == "dest" else v) for k, v in s.items()} for s in tr["sends"]]
    out["items"] = [(it["pos"], it["len"], it["active"], [(tk.get("name"), tk.get("src")) for tk in it["takes"]])
                    for _, it in t.items(lambda _, it: it["track"] == g)]
    return out


def check_copies(t, originals, copies):
    problems = []
    copy_of = dict(zip(originals, copies))
    for a, b in zip(originals, copies):
        fa, fb = track_copy_facts(t, a, copy_of), track_copy_facts(t, b)
        for k in fa:
            if fa[k] != fb[k]:
                problems.append(f"copy of {fa['name']!r}: {k} = {fb[k]!r}, original {fa[k]!r}")
    if problems:
        raise Mismatch("the duplicate differs from what it copies:\n    " + "\n    ".join(problems[:15]))


def route_key(r, peer):
    return (r[peer], r["vol"], r["pan"], r["mute"], r["mode"], r["dstchan"], r["srcchan"])


def added_route(before, after, peer):
    """Index of the one entry in `after` that `before` lacks (multiset difference)."""
    left = [route_key(r, peer) for r in before]
    extra = []
    for i, r in enumerate(after):
        k = route_key(r, peer)
        if k in left:
            left.remove(k)
        else:
            extra.append(i)
    if len(after) != len(before) + 1 or len(extra) != 1 or left:
        raise Mismatch(f"expected exactly one new entry; before {before}, after {after}")
    return extra[0]


def recv_of_send(t, src, send_idx):
    """The receive on the destination that is `src`'s send `send_idx`: the
    k-th receive from a source is its k-th send to that destination."""
    sends = t.d["tracks"][src]["sends"]
    dest = sends[send_idx]["dest"]
    occurrence = sum(1 for s in sends[:send_idx] if s["dest"] == dest)
    recvs = [i for i, r in enumerate(t.d["tracks"][dest]["recvs"]) if r["src"] == src]
    return dest, recvs[occurrence]


def next_mode(mode):
    """The routing modal's mode button: post-fader -> pre-FX -> post-FX -> post-fader."""
    return {0: 1, 1: 3}.get(int(mode), 0)


def routing_problems(t, p, guid, names):
    tr = t.d["tracks"][guid]
    out = []
    pairs = (("sends", "sends", "sendIndex", "destName", "dest"),
             ("receives", "recvs", "receiveIndex", "srcName", "src"),
             ("hwOutputs", "hw", "hwIdx", None, None))
    for key, dkey, idx_key, name_key, peer in pairs:
        got, want = p.get(key, []), tr[dkey]
        if len(got) != len(want):
            out.append(f"routing {key}: {len(got)} shown, REAPER has {len(want)}")
            continue
        for i, (e, w) in enumerate(zip(got, want)):
            exp = {idx_key: i, "muted": bool(w["mute"]), "mode": int(w["mode"])}
            if name_key:
                exp[name_key] = names.get(w[peer])
            else:
                exp["destChannel"] = int(w["dstchan"])
            bad = [k for k, v in exp.items() if e.get(k) != v]
            if bad or not close(e.get("volume"), w["vol"], 1e-5) or not close(e.get("pan"), w["pan"], 1e-5):
                out.append(f"routing {key}[{i}] = {e}, REAPER {w}")
    return out


def latest_routing(c, guid, since=0):
    for name, msg in reversed(c.events[since:]):
        if name == "routing_state" and msg["payload"].get("trackGuid") == guid:
            return msg["payload"]
    return None


def wait_routing(t, c, guid, timeout=3.0):
    """The routing view on phone `c` converges to REAPER's sends, receives and
    hardware outputs for `guid`."""
    names = reaper(DISPLAY_NAMES) or {}
    deadline = time.time() + timeout
    while True:
        c.drain(0.15)
        t.digest()
        p = latest_routing(c, guid)
        problems = ["no routing_state for the open track"] if p is None else routing_problems(t, p, guid, names)
        if not problems:
            return p
        if time.time() > deadline:
            label = t.d["tracks"][guid]["name"] or guid[:9]
            raise Mismatch(f"routing view of {label} disagrees with REAPER:\n    " + "\n    ".join(problems[:15]))


def open_routing(t, c, guid):
    """RoutingModal opening on a track: subscribe and show REAPER's routing."""
    r = t.send("routing/subscribe", client=c, trackGuid=guid)
    if r is not None and not r.get("success"):
        raise Mismatch(f"routing/subscribe failed: {r}")
    return wait_routing(t, c, guid)


def close_routing(t, c):
    try:
        t.send("routing/unsubscribe", client=c)
    except Exception as e:  # cleanup only; the op's own result stands
        print(f"      routing/unsubscribe raised {type(e).__name__}: {e}")


def drag(t, control, guid, cmd, values, index_key, index, track_idx, value_key):
    """A fader drag in the routing modal: gesture/start, a stream of set
    commands without responses, gesture/end."""
    t.ok("gesture/start", controlType=control, trackGuid=guid, **{index_key: index})
    for v in values:
        t.c.fire(cmd, trackIdx=track_idx, **{index_key: index, value_key: v})
        time.sleep(0.01)
    t.ok("gesture/end", controlType=control, trackGuid=guid, **{index_key: index})


def ramp(a, b, n=20):
    return [a + (b - a) * i / (n - 1) for i in range(n)]


def awaited(t, command, **params):
    r = t.send(command, awaited=True, **params)
    if not r.get("success"):
        raise Mismatch(f"{command} failed: {r.get('error')}")
    return r.get("payload") or {}


# ----------------------------------------------------------------------------
# Creating, duplicating and deleting tracks

@op("track/create: a named track at the top, an unnamed one at the end", "track/create")
@tidy
def _(t):
    t.digest()
    cases = (("named at the top", dict(name="Tambourine", afterTrackIdx=0), 1, "Tambourine"),
             ("unnamed at the end", {}, len(t.tracks()) + 1, ""))
    for label, params, pos, name in cases:
        before = t.digest()
        guids = {g for g, _ in t.tracks()}
        changes = shifted(t, pos, 1)
        r = t.ok("track/create", **params)
        g = wait_new_tracks(t, guids, 1)[0]
        changes.update({
            f"tracks.{g}.*": ANY, f"tracks.{g}.pos": pos, f"tracks.{g}.name": name,
            f"tracks.{g}.depth": 0, f"tracks.{g}.vol": 1.0, f"tracks.{g}.mute": 0,
            f"tracks.{g}.sends[]": 0, f"tracks.{g}.recvs[]": 0,
        })
        t.flat = before
        t.expect(changes)
        new = t.d["tracks"][g]
        if new["fx"] or [it for it in t.d["items"].values() if it["track"] == g]:
            raise Mismatch(f"{label}: the new track is not empty: {new}")
        if r is not None and (r.get("payload") or {}).get("trackIdx") != pos:
            raise Mismatch(f"{label}: track/create returned {r.get('payload')}, REAPER put the track at {pos}")
        t.undo_redo(before, t.flat)
        undo_to(t, before)


@op("track/duplicate: the Drums folder", "track/duplicate")
@tidy
def _(t):
    g, tr = prefer(t, "Drums", lambda g, tr: tr["depth"] == 1)
    span = folder_span(t, g)
    end = t.d["tracks"][span[-1]]["pos"]
    before = t.flat
    guids = {x for x, _ in t.tracks()}
    dests = {s["dest"] for x in span for s in t.d["tracks"][x]["sends"]}
    changes = shifted(t, end + 1, len(span))
    # TrackInfoBar sends the track's index.
    r = t.ok("track/duplicate", trackIdx=tr["pos"])
    copies = wait_new_tracks(t, guids, len(span))
    for i, c in enumerate(copies):
        changes[f"tracks.{c}.*"] = ANY
        changes[f"tracks.{c}.pos"] = end + 1 + i
    for ig in items_on(copies):
        changes[f"items.{ig}.*"] = ANY
    for d in dests:
        changes[f"tracks.{d}.recvs*"] = ANY
    # REAPER's duplicate leaves the copy selected and the rest unselected, as
    # when the user duplicates in REAPER.
    for x in guids:
        changes[f"tracks.{x}.sel"] = 0
    t.expect(changes)
    check_copies(t, span, copies)
    for d in dests:
        want = sum(1 for x in span for s in before_sends(before, x) if s == d)
        got = sum(1 for rv in t.d["tracks"][d]["recvs"] if rv["src"] in copies)
        if got != want:
            raise Mismatch(f"{t.d['tracks'][d]['name']} receives {got} sends from the copies, the originals send {want}")
    if r is not None and (r.get("payload") or {}).get("trackIdx") != end + 1:
        raise Mismatch(f"track/duplicate returned {r.get('payload')}; REAPER put the copy of the parent at {end + 1}")
    # Track selection is not part of REAPER's undo state (by default), so undo
    # leaves the copy's selection behind; everything else must come back.
    ignore = ("tracks.*.sel",)
    undo_redo_except(t, before, t.flat, ignore)
    undo_to(t, before, ignore)
    set_selection(t, before)
    t._wait_equal(t.op_start, "restoring the selection did not restore the project")


def before_sends(flat, g):
    """Destinations of track g's sends in a flattened digest."""
    out, i = [], 0
    while f"tracks.{g}.sends.{i}.dest" in flat:
        out.append(flat[f"tracks.{g}.sends.{i}.dest"])
        i += 1
    return out


@op("track/delete: a track another phone has the routing of open", "track/delete")
@tidy
def _(t):
    g, tr = prefer(t, "BVs", lambda g, tr: tr["sends"] and not tr["depth"])
    other = t.watcher
    try:
        open_routing(t, other, g)
        before = t.digest()
        dests = {s["dest"] for s in tr["sends"]}
        recvs_before = {d: [rv["src"] for rv in t.d["tracks"][d]["recvs"]] for d in dests}
        changes = {f"tracks.{g}.*": ANY, **shifted(t, tr["pos"] + 1, -1)}
        for ig, _ in t.items(lambda _, it: it["track"] == g):
            changes[f"items.{ig}.*"] = ANY
        for d in dests:
            changes[f"tracks.{d}.recvs*"] = ANY
        t.ok("track/delete", trackIdx=tr["pos"])
        t.expect(changes)
        if g in t.d["tracks"]:
            raise Mismatch("the track is still in REAPER")
        for d in dests:
            want = [s for s in recvs_before[d] if s != g]
            got = [rv["src"] for rv in t.d["tracks"][d]["recvs"]]
            if got != want:
                raise Mismatch(f"{t.d['tracks'][d]['name']} receives from {got}, expected {want}")
        # The other phone's routing view of the deleted track goes quiet, and
        # what it sends for that track is refused without touching REAPER.
        other.drain(0.5)
        mark = len(other.events)
        other.drain(1.0)
        if latest_routing(other, g, since=mark) is not None:
            raise Mismatch(f"the other phone still gets routing_state for the deleted track: {latest_routing(other, g, mark)}")
        r = t.send("track/getInput", awaited=True, client=other, trackGuid=g)
        if r.get("success"):
            raise Mismatch(f"track/getInput on the deleted track succeeded: {r}")
        after = t.flat
        t.expect({})
        t.undo_redo(before, after)
        undo_to(t, before)
        # Undo brings the track back with its GUID; the open view follows it again.
        wait_routing(t, other, g)
    finally:
        close_routing(t, other)


@op("track/duplicateSelected + deleteSelected: copy the selected tracks, delete the copies",
    "track/duplicateSelected", "track/deleteSelected")
@tidy
def _(t):
    picks = [g for g, tr in t.tracks() if tr["name"] in ("Keys", "Pads (missing plugin)") and not tr["depth"]]
    if len(picks) != 2:
        picks = [g for g, tr in t.tracks() if not tr["depth"]][-2:]
        if len(picks) != 2:
            raise Skip("needs two tracks outside folders")
    # The user selects the two tracks in REAPER, then taps duplicate on the phone.
    reaper(SET_SELECTION % lua_set(picks))
    base = t.digest()
    guids = {g for g, _ in t.tracks()}
    changes = {f"tracks.{x}.sel": 0 for x in guids}
    dests = {s["dest"] for x in picks for s in t.d["tracks"][x]["sends"]}
    for d in dests:
        changes[f"tracks.{d}.recvs*"] = ANY
    t.ok("track/duplicateSelected")
    copies = wait_new_tracks(t, guids, len(picks))
    # Each copy lands right after the track it copies.
    order, pending = [], iter(copies)
    for x, _ in t.tracks():
        order.append(x)
        if x in picks:
            order.append(next(pending))
    for i, x in enumerate(order):
        changes[f"tracks.{x}.pos"] = i + 1
    for c in copies:
        changes[f"tracks.{c}.*"] = ANY
        changes[f"tracks.{c}.sel"] = 1
    for ig in items_on(copies):
        changes[f"items.{ig}.*"] = ANY
    # A copy keeps what the track it copies receives: REAPER gives each
    # source track one more send, to the copy, set as its send to the
    # original. They follow the source's own sends, in the copies' order.
    # A source copied alongside sends from its copy instead (the copies are
    # routed among themselves), so the source itself gains nothing.
    copied_sends = {}
    for x, c in zip(sorted(picks, key=lambda g: base[f"tracks.{g}.pos"]), copies):
        for rv in t.d["tracks"][x]["recvs"]:
            src = rv["src"]
            if src in picks:
                continue
            n = len(t.d["tracks"][src]["sends"]) + len(copied_sends.setdefault(src, []))
            copied_sends[src].append(n)
            changes[f"tracks.{src}.sends.{n}.dest"] = c
            for k in ("vol", "pan", "mute", "mode", "dstchan", "srcchan"):
                changes[f"tracks.{src}.sends.{n}.{k}"] = rv[k]
    t.expect(changes)
    check_copies(t, sorted(picks, key=lambda g: base[f"tracks.{g}.pos"]), copies)
    ignore = ("tracks.*.sel",)
    duplicated = t.flat
    undo_redo_except(t, base, duplicated, ignore)
    set_selection(t, duplicated)
    t._wait_equal(duplicated, "restoring the copies' selection did not restore the project")

    # The copies are selected; delete them.
    changes = {f"tracks.{c}.*": ANY for c in copies}
    changes.update({f"tracks.{x}.pos": base[f"tracks.{x}.pos"] for x in guids})
    for ig in items_on(copies):
        changes[f"items.{ig}.*"] = ANY
    for d in dests:
        changes[f"tracks.{d}.recvs*"] = ANY
    for src, sends in copied_sends.items():
        for n in sends:
            changes[f"tracks.{src}.sends.{n}.*"] = ANY
    t.ok("track/deleteSelected")
    # Which track REAPER selects after deleting the selected ones is its own choice.
    t.expect(changes, allow=ignore)
    wait_equal_except(t, base, ignore, "deleting the copies did not leave the project as before the duplicate")
    undo_redo_except(t, duplicated, t.flat, ignore)
    set_selection(t, t.op_start)
    t._wait_equal(t.op_start, "restoring the selection did not restore the project")


# ----------------------------------------------------------------------------
# Sends, receives and hardware outputs

@op("send/add + remove: the guitar into the delay bus", "send/add", "send/remove")
@tidy
def _(t):
    src, s_tr = prefer(t, "Guitar", lambda g, tr: True)
    dest, d_tr = prefer(t, "Delay Bus", lambda g, tr: g != src and all(s["dest"] != g for s in s_tr["sends"]))
    try:
        open_routing(t, t.c, src)
        n_before = len(s_tr["sends"])
        sends_before, recvs_before = list(s_tr["sends"]), list(d_tr["recvs"])
        r = step(t, lambda: t.ok("send/add", trackGuid=src, destTrackGuid=dest),
                 {f"tracks.{src}.sends*": ANY, f"tracks.{dest}.recvs*": ANY}, keep=True)
        new = added_route(sends_before, t.d["tracks"][src]["sends"], "dest")
        if t.d["tracks"][src]["sends"][new]["dest"] != dest:
            raise Mismatch(f"the new send goes to {t.d['tracks'][src]['sends'][new]['dest']}, not {d_tr['name']}")
        added_route(recvs_before, t.d["tracks"][dest]["recvs"], "src")
        if r is not None and (r.get("payload") or {}).get("sendIndex") != new:
            raise Mismatch(f"send/add returned {r.get('payload')}; REAPER's new send is index {new} of {n_before + 1}")
        wait_routing(t, t.c, src)
        step(t, lambda: t.ok("send/remove", trackGuid=src, sendIdx=new),
             {f"tracks.{src}.sends*": ANY, f"tracks.{dest}.recvs*": ANY}, keep=True)
        t._wait_equal(t.op_start, "removing the send did not restore the project")
        wait_routing(t, t.c, src)
    finally:
        close_routing(t, t.c)


@op("send: ride the vocal's reverb send, reset it, pan, mute and mode",
    "send/setVolume", "send/setPan", "send/setMute", "send/setMode")
@tidy
def _(t):
    src, tr = prefer(t, "Lead Vox", lambda g, tr: tr["sends"])
    i = 0
    dest, k = recv_of_send(t, src, i)
    pos = tr["pos"]
    send, recv = f"tracks.{src}.sends.{i}", f"tracks.{dest}.recvs.{k}"
    try:
        open_routing(t, t.c, src)
        start = tr["sends"][i]
        steps = [
            ("volume drag", lambda: drag(t, "send", src, "send/setVolume", ramp(start["vol"], 0.6), "sendIdx", i, pos, "volume"),
             "vol", approx(0.6, 1e-5)),
            # Double-tap on the fader resets to 0 dB, without a gesture.
            ("reset tap", lambda: t.ok("send/setVolume", trackIdx=pos, sendIdx=i, volume=1.0), "vol", approx(1.0, 1e-5)),
            ("pan drag", lambda: drag(t, "sendPan", src, "send/setPan", ramp(start["pan"], -0.5), "sendIdx", i, pos, "pan"),
             "pan", approx(-0.5, 1e-4)),
            ("mute tap", lambda: t.ok("send/setMute", trackIdx=pos, sendIdx=i, muted=0 if start["mute"] else 1),
             "mute", 0 if start["mute"] else 1),
            ("mode tap", lambda: t.ok("send/setMode", trackIdx=pos, sendIdx=i, mode=next_mode(start["mode"])),
             "mode", next_mode(start["mode"])),
        ]
        for label, act, field, want in steps:
            if field == "vol" and matches_value(start["vol"], want):
                continue
            try:
                step(t, act, {f"{send}.{field}": want, f"{recv}.{field}": want})
            except Mismatch as e:
                raise Mismatch(f"{label}: {e}") from None
            wait_routing(t, t.c, src)
    finally:
        close_routing(t, t.c)


def matches_value(v, spec):
    return spec(v) if callable(spec) else v == spec


@op("routing edits on a send, receive or output another phone just removed change nothing",
    "send/setVolume", "send/setPan", "send/setMute", "send/setMode",
    "receive/setVolume", "receive/setPan", "receive/setMute", "receive/setMode",
    "hw/setVolume", "hw/setPan", "hw/setMute", "hw/setMode")
@tidy
def _(t):
    # This phone's routing modal still shows a row one past the end: the other
    # phone removed it a moment ago and the next routing_state has not arrived.
    targets = (("send", "sendIdx", prefer(t, "Lead Vox", lambda g, tr: tr["sends"]), "sends"),
               ("receive", "recvIdx", prefer(t, "Verb Bus", lambda g, tr: tr["recvs"]), "recvs"),
               ("hw", "hwIdx", prefer(t, "Headphone mix", lambda g, tr: tr["hw"]), "hw"))
    edits = (("setVolume", {"volume": 0.5}), ("setPan", {"pan": 0.5}), ("setMute", {"muted": 1}), ("setMode", {"mode": 1}))
    accepted = []
    for family, key, (g, tr), dkey in targets:
        stale = len(tr[dkey])
        for name, value in edits:
            r = t.send(f"{family}/{name}", trackIdx=tr["pos"], **{key: stale}, **value)
            if r is None or r.get("success"):
                accepted.append(f"{family}/{name} {key}={stale} on {tr['name']} ({stale} exist): {r}")
    t.expect({})
    if accepted:
        raise Mismatch("edits that changed nothing in REAPER reported success, so the phone shows no error:\n    "
                       + "\n    ".join(accepted))


@op("receive: a second vocal feed into the reverb bus, ridden from the bus",
    "receive/add", "receive/setVolume", "receive/setPan", "receive/setMute", "receive/setMode", "receive/remove")
@tidy
def _(t):
    bus, b_tr = prefer(t, "Verb Bus", lambda g, tr: tr["recvs"])
    # A source already sending to the bus: the new receive is its second send there.
    src = b_tr["recvs"][-1]["src"]
    for rv in b_tr["recvs"]:
        if t.d["tracks"][rv["src"]]["name"] == "Lead Vox":
            src = rv["src"]
    try:
        open_routing(t, t.c, bus)
        sends_before, recvs_before = list(t.d["tracks"][src]["sends"]), list(b_tr["recvs"])
        r = step(t, lambda: t.ok("receive/add", trackGuid=bus, srcTrackGuid=src),
                 {f"tracks.{src}.sends*": ANY, f"tracks.{bus}.recvs*": ANY}, keep=True)
        j = added_route(sends_before, t.d["tracks"][src]["sends"], "dest")
        k = added_route(recvs_before, t.d["tracks"][bus]["recvs"], "src")
        if t.d["tracks"][src]["sends"][j]["dest"] != bus or t.d["tracks"][bus]["recvs"][k]["src"] != src:
            raise Mismatch(f"receive/add made a send to {t.d['tracks'][src]['sends'][j]['dest']} "
                           f"and a receive from {t.d['tracks'][bus]['recvs'][k]['src']}")
        if recv_of_send(t, src, j) != (bus, k):
            raise Mismatch(f"REAPER lists the new receive at {k}, which is not the source's send {j}")
        if r is not None and (r.get("payload") or {}).get("sendIndex") != j:
            raise Mismatch(f"receive/add returned {r.get('payload')}; the new send on the source is index {j}")
        wait_routing(t, t.c, bus)
        pos = t.d["tracks"][bus]["pos"]
        start = t.d["tracks"][bus]["recvs"][k]
        send, recv = f"tracks.{src}.sends.{j}", f"tracks.{bus}.recvs.{k}"
        steps = [
            ("volume set", lambda: t.ok("receive/setVolume", trackIdx=pos, recvIdx=k, volume=0.5), "vol", approx(0.5, 1e-5)),
            ("volume drag", lambda: drag(t, "receive", bus, "receive/setVolume", ramp(start["vol"], 0.25), "recvIdx", k, pos, "volume"),
             "vol", approx(0.25, 1e-5)),
            ("pan drag", lambda: drag(t, "receivePan", bus, "receive/setPan", ramp(start["pan"], 0.75), "recvIdx", k, pos, "pan"),
             "pan", approx(0.75, 1e-4)),
            ("mute tap", lambda: t.ok("receive/setMute", trackIdx=pos, recvIdx=k, muted=0 if start["mute"] else 1),
             "mute", 0 if start["mute"] else 1),
            ("mode tap", lambda: t.ok("receive/setMode", trackIdx=pos, recvIdx=k, mode=next_mode(start["mode"])),
             "mode", next_mode(start["mode"])),
        ]
        for label, act, field, want in steps:
            try:
                step(t, act, {f"{send}.{field}": want, f"{recv}.{field}": want})
            except Mismatch as e:
                raise Mismatch(f"{label} on receive {k}: {e}") from None
            wait_routing(t, t.c, bus)
        step(t, lambda: t.ok("receive/remove", trackGuid=bus, recvIdx=k),
             {f"tracks.{src}.sends*": ANY, f"tracks.{bus}.recvs*": ANY}, keep=True)
        t._wait_equal(t.op_start, "removing the receive did not restore the project")
        wait_routing(t, t.c, bus)
    finally:
        close_routing(t, t.c)


OUTPUT_NAMES = """
local out = {}
for i = 0, reaper.GetNumAudioOutputs() - 1 do out[#out + 1] = reaper.GetOutputChannelName(i) end
return out
"""


def expected_outputs():
    """HwChannelPicker's list as REAPER's outputs define it: stereo pairs, then each mono output."""
    names = as_list(reaper(OUTPUT_NAMES))
    out = [{"destChan": ch, "name": f"{names[ch]} / {names[ch + 1]}", "stereo": True} for ch in range(0, len(names) - 1, 2)]
    out += [{"destChan": ch | 1024, "name": n, "stereo": False} for ch, n in enumerate(names)]
    return out


@op("hw: a re-amp output on the guitar: pick its channel, ride its send, remove it",
    "hw/listOutputs", "hw/add", "hw/setDestChannel", "hw/remove")
@tidy
def _(t):
    g, tr = prefer(t, "Guitar", lambda g, tr: tr["sends"] and not tr["hw"])
    pos = tr["pos"]
    try:
        open_routing(t, t.c, g)
        outputs = awaited(t, "hw/listOutputs").get("outputs")
        if outputs != expected_outputs():
            raise Mismatch(f"hw/listOutputs = {outputs}, REAPER's outputs give {expected_outputs()}")
        if not outputs:
            raise Skip("REAPER has no audio outputs to pick")
        n = len(tr["hw"])
        payload = step(t, lambda: awaited(t, "hw/add", trackGuid=g), {f"tracks.{g}.hw*": ANY}, keep=True)
        if len(t.d["tracks"][g]["hw"]) != n + 1:
            raise Mismatch(f"hw/add: the track has {len(t.d['tracks'][g]['hw'])} hardware outputs, expected {n + 1}")
        if payload.get("hwIdx") != n:
            raise Mismatch(f"hw/add returned {payload}; REAPER's new output is index {n}")
        wait_routing(t, t.c, g)
        # HardwareTab sends the picked channel right after the add response.
        dest = outputs[-1]["destChan"]
        step(t, lambda: t.ok("hw/setDestChannel", trackIdx=pos, hwIdx=n, destChannel=dest),
             {f"tracks.{g}.hw.{n}.dstchan": dest})
        wait_routing(t, t.c, g)
        # Its sends follow its hardware outputs in REAPER's control-surface
        # numbering; a send fader must still move the send.
        dest_track, k = recv_of_send(t, g, 0)
        step(t, lambda: t.ok("send/setVolume", trackIdx=pos, sendIdx=0, volume=0.5),
             {f"tracks.{g}.sends.0.vol": approx(0.5, 1e-5), f"tracks.{dest_track}.recvs.{k}.vol": approx(0.5, 1e-5)})
        wait_routing(t, t.c, g)
        step(t, lambda: t.ok("hw/remove", trackGuid=g, hwIdx=n), {f"tracks.{g}.hw*": ANY}, keep=True)
        t._wait_equal(t.op_start, "removing the hardware output did not restore the project")
        wait_routing(t, t.c, g)
    finally:
        close_routing(t, t.c)


def headphone_output(t):
    return prefer(t, "Headphone mix", lambda g, tr: tr["hw"])


@op("hw: ride the headphone mix output: volume and pan drags, mute, mode",
    "hw/setVolume", "hw/setPan", "hw/setMute", "hw/setMode")
@tidy
def _(t):
    g, tr = headphone_output(t)
    pos, h = tr["pos"], 0
    start = tr["hw"][h]
    out = f"tracks.{g}.hw.{h}"
    try:
        open_routing(t, t.c, g)
        steps = [
            ("volume drag", lambda: drag(t, "hwOutputVolume", g, "hw/setVolume", ramp(start["vol"], 0.5), "hwIdx", h, pos, "volume"),
             "vol", approx(0.5, 1e-5)),
            ("pan drag", lambda: drag(t, "hwOutputPan", g, "hw/setPan", ramp(start["pan"], -0.5), "hwIdx", h, pos, "pan"),
             "pan", approx(-0.5, 1e-4)),
            ("mute tap", lambda: t.ok("hw/setMute", trackIdx=pos, hwIdx=h, muted=0 if start["mute"] else 1),
             "mute", 0 if start["mute"] else 1),
            ("mode tap", lambda: t.ok("hw/setMode", trackIdx=pos, hwIdx=h, mode=next_mode(start["mode"])),
             "mode", next_mode(start["mode"])),
        ]
        for label, act, field, want in steps:
            try:
                step(t, act, {f"{out}.{field}": want})
            except Mismatch as e:
                raise Mismatch(f"{label}: {e}") from None
            wait_routing(t, t.c, g)
    finally:
        close_routing(t, t.c)


@op("hw: double-tap resets of the headphone output are undo steps", "hw/setVolume", "hw/setPan")
@tidy
def _(t):
    g, tr = headphone_output(t)
    pos, h = tr["pos"], 0
    out = f"tracks.{g}.hw.{h}"
    problems = []
    for label, control, cmd, key, dragged, default in (
            ("volume", "hwOutputVolume", "hw/setVolume", "volume", 0.5, 1.0),
            ("pan", "hwOutputPan", "hw/setPan", "pan", 0.4, 0.0)):
        field = {"volume": "vol", "pan": "pan"}[key]
        # Drag off the default (its own undo step)...
        step(t, lambda: drag(t, control, g, cmd, ramp(tr["hw"][h][field], dragged), "hwIdx", h, pos, key),
             {f"{out}.{field}": approx(dragged, 1e-4)}, keep=True)
        # ...then double-tap back to it, as HardwareTab sends it: no gesture,
        # and the user expects Ctrl+Z to bring the dragged value back.
        try:
            step(t, lambda: t.ok(cmd, trackIdx=pos, hwIdx=h, **{key: default}), {f"{out}.{field}": approx(default, 1e-4)})
            undo_to(t, t.op_start)
        except Mismatch as e:
            problems.append(f"{label} reset: {e}")
            recover(t)
    if problems:
        raise Mismatch("\n".join(problems))


# ----------------------------------------------------------------------------
# What the mixer shows on demand

@op("track/getFx + getSends + getHwOutputs: every track's details match REAPER",
    "track/getFx", "track/getSends", "track/getHwOutputs")
@tidy
def _(t):
    names = reaper(DISPLAY_NAMES) or {}
    problems = []
    tracks = [("master", t.d["tracks"]["master"])] + t.tracks()
    for g, tr in tracks:
        label = tr["name"] or names.get(g, g[:9])
        idx = tr["pos"]
        fx = awaited(t, "track/getFx", trackIdx=idx)
        want = sorted(tr["fx"].values(), key=lambda f: f["pos"])
        got = fx.get("fx", [])
        if (fx.get("total"), fx.get("offset"), fx.get("hasMore"), len(got)) != (len(want), 0, False, len(want)):
            problems.append(f"getFx {label}: total {fx.get('total')} offset {fx.get('offset')} hasMore {fx.get('hasMore')} "
                            f"with {len(got)} FX; REAPER has {len(want)}")
        for i, (e, w) in enumerate(zip(got, want)):
            exp = {"fxIndex": i, "name": w["name"], "enabled": bool(w["enabled"]), "presetName": w["preset"],
                   "presetIndex": w["preset_idx"], "presetCount": w["preset_count"]}
            if any(e.get(k) != v for k, v in exp.items()):
                problems.append(f"getFx {label}[{i}] = {e}, REAPER {exp}")
        if len(want) >= 2:
            # The FX list pages through a long chain.
            page = awaited(t, "track/getFx", trackIdx=idx, offset=1, limit=1)
            if ([f["fxIndex"] for f in page.get("fx", [])], page.get("total"), page.get("hasMore")) != (
                    [1], len(want), len(want) > 2):
                problems.append(f"getFx {label} offset 1 limit 1 = {page}")

        sends = awaited(t, "track/getSends", trackIdx=idx)
        got = sends.get("sends", [])
        if (sends.get("total"), len(got), sends.get("hasMore")) != (len(tr["sends"]), len(tr["sends"]), False):
            problems.append(f"getSends {label}: {sends}; REAPER has {len(tr['sends'])} sends")
        for i, (e, w) in enumerate(zip(got, tr["sends"])):
            exp = {"sendIndex": i, "destName": names.get(w["dest"]), "muted": bool(w["mute"]), "mode": int(w["mode"])}
            if any(e.get(k) != v for k, v in exp.items()) or not close(e.get("volume"), w["vol"], 1e-5):
                problems.append(f"getSends {label}[{i}] = {e}, REAPER {w} to {names.get(w['dest'])}")

        hw = awaited(t, "track/getHwOutputs", trackIdx=idx)
        got = hw.get("hwOutputs", [])
        if (hw.get("total"), len(got), hw.get("hasMore")) != (len(tr["hw"]), len(tr["hw"]), False):
            problems.append(f"getHwOutputs {label}: {hw}; REAPER has {len(tr['hw'])} hardware outputs")
        for i, (e, w) in enumerate(zip(got, tr["hw"])):
            exp = {"hwIdx": i, "destChannel": int(w["dstchan"]), "muted": bool(w["mute"]), "mode": int(w["mode"])}
            if (any(e.get(k) != v for k, v in exp.items()) or not close(e.get("volume"), w["vol"], 1e-5)
                    or not close(e.get("pan"), w["pan"], 1e-3)):
                problems.append(f"getHwOutputs {label}[{i}] = {e}, REAPER {w}")
    if problems:
        raise Mismatch("on-demand details disagree with REAPER:\n    " + "\n    ".join(problems[:20]))
    t.expect({})


# ----------------------------------------------------------------------------
# Inputs

def decode_input(raw):
    """What the input sheet shows for REAPER's I_RECINPUT (REAPER's encoding)."""
    raw = int(raw)
    if raw < 0:
        return {"type": "none", "raw": -1}
    if raw & 4096:
        dev = (raw >> 5) & 63
        return {"type": "midi", "raw": raw, "device": dev, "channel": raw & 31, "isVKB": dev == 62, "isAll": dev == 63}
    ch = raw & 1023
    return {"type": "audio", "raw": raw, "channel": ch - 512 if ch >= 512 else ch, "stereo": bool(raw & 1024),
            "multi": bool(raw & 2048), "rearoute": ch >= 512}


ENUM = """
local audio, midi = {}, {}
for i = 0, reaper.GetNumAudioInputs() - 1 do audio[#audio + 1] = reaper.GetInputChannelName(i) end
for i = 0, reaper.GetMaxMidiInputs() - 1 do
  local ok, name = reaper.GetMIDIInputName(i, "")
  if ok and i ~= 62 and i ~= 63 then midi[#midi + 1] = {i, name} end
end
return {audio = audio, midi = midi}
"""


@op("input/enumerateAudio + enumerateMidi: the input sheet lists REAPER's inputs",
    "input/enumerateAudio", "input/enumerateMidi")
@tidy
def _(t):
    want = reaper(ENUM) or {}
    audio = awaited(t, "input/enumerateAudio").get("inputs")
    exp = [{"idx": i, "name": n} for i, n in enumerate(as_list(want.get("audio")))]
    if audio != exp:
        raise Mismatch(f"input/enumerateAudio = {audio}, REAPER's inputs are {exp}")
    midi = awaited(t, "input/enumerateMidi").get("devices")
    exp = [{"idx": i, "name": n} for i, n in as_list(want.get("midi"))]
    exp += [{"idx": 62, "name": "Virtual MIDI Keyboard"}, {"idx": 63, "name": "All MIDI Inputs"}]
    if midi != exp:
        raise Mismatch(f"input/enumerateMidi = {midi}, REAPER's MIDI inputs give {exp}")
    t.expect({})


@op("track/getInput + setInput: the input sheet's stereo, mono, MIDI and none choices",
    "track/getInput", "track/setInput")
@tidy
def _(t):
    if not t.tracks():
        raise Skip("the project has no tracks to pick an input for")
    problems = []
    for g, tr in t.tracks():
        got = awaited(t, "track/getInput", trackGuid=g)
        if got != decode_input(tr["input"]):
            problems.append(f"getInput {tr['name'] or g[:9]} = {got}, REAPER I_RECINPUT {int(tr['input'])} is {decode_input(tr['input'])}")
    if problems:
        raise Mismatch("track/getInput disagrees with REAPER:\n    " + "\n    ".join(problems[:10]))
    midi = [d for d in awaited(t, "input/enumerateMidi").get("devices", []) if d["idx"] < 62]
    by_name = {tr["name"]: g for g, tr in t.tracks()}
    users = [g for g, _ in t.tracks()]
    pick = lambda name, i: by_name.get(name) or users[i % len(users)]  # noqa: E731
    # (what the user picks, the track, params as InputSelectionSheet sends them, I_RECINPUT REAPER should hold)
    cases = [
        ("stereo input 1/2", pick("Guitar", 0), dict(inputType="audio", channel=0, stereo=True), 1024),
        ("mono input 2", pick("Lead Vox", 1), dict(inputType="audio", channel=1, stereo=False), 1),
        ("all MIDI inputs, all channels", pick("Keys", 2), dict(inputType="midi", device=63, channel=0), 4096 + (63 << 5)),
        ("virtual keyboard, channel 10", pick("Pads (missing plugin)", 3), dict(inputType="midi", device=62, channel=10), 4096 + 10 + (62 << 5)),
        ("no input", pick("BVs", 4), dict(inputType="none"), -1),
    ]
    if midi:
        cases.append((f"MIDI {midi[0]['name']}, channel 1", pick("Click", 5),
                      dict(inputType="midi", device=midi[0]["idx"], channel=1), 4096 + 1 + (midi[0]["idx"] << 5)))
    for label, g, params, want in cases:
        orig = int(t.d["tracks"][g]["input"])
        if orig == want:
            continue
        awaited(t, "track/setInput", trackGuid=g, **params)
        t.expect({f"tracks.{g}.input": want})
        got = awaited(t, "track/getInput", trackGuid=g)
        if got != decode_input(want):
            raise Mismatch(f"{label}: getInput = {got}, REAPER holds {decode_input(want)}")
        # The tracks event carries the input of an armed track; converge() checks it.
        t.converge()
        t.ok("track/setInput", trackGuid=g, raw=orig)
        t.expect({f"tracks.{g}.input": orig})


# ----------------------------------------------------------------------------
# Subscriptions

def track_event_problems(t, ev, want_guids):
    got = {e["g"]: e for e in ev["tracks"]}
    out = []
    if set(got) != set(want_guids):
        names = {g: (t.d["tracks"].get(g) or {}).get("name", g[:9]) for g in set(got) | set(want_guids)}
        return [f"tracks event carries {sorted(names[g] for g in got)}, subscribed {sorted(names[g] for g in want_guids)}"]
    if ev.get("total") != len(t.tracks()):
        out.append(f"tracks.total = {ev.get('total')}, REAPER has {len(t.tracks())}")
    for g in want_guids:
        e, tr = got[g], t.d["tracks"][g]
        exp = {"idx": tr["pos"], "mute": bool(tr["mute"]), "solo": int(tr["solo"]), "recArm": bool(tr["arm"]),
               "fxCount": len(tr["fx"]), "sendCount": len(tr["sends"]), "receiveCount": len(tr["recvs"]),
               "hwOutCount": len(tr["hw"])}
        if g != "master" and tr["name"]:
            exp["name"] = tr["name"]
        bad = {k: (e.get(k), v) for k, v in exp.items() if e.get(k) != v}
        if bad or not close(e.get("volume"), tr["vol"], 1e-4) or not close(e.get("pan"), tr["pan"], 1e-3):
            out.append(f"tracks {tr['name'] or g[:9]}: {bad or e}, REAPER vol {tr['vol']} pan {tr['pan']}")
    return out


def wait_tracks_event(t, c, want, what, timeout=3.0):
    """The latest tracks and meters events reaching phone `c` carry exactly
    the tracks in `want`, as REAPER has them."""
    deadline = time.time() + timeout
    while True:
        c.drain(0.2)
        t.digest()
        ev, m = c.latest_event("tracks"), c.latest_event("meters")
        problems = ["no tracks event"] if ev is None else track_event_problems(t, ev["payload"], want)
        if m is None or set(m["m"]) != set(want):
            problems.append(f"meters for {len(m['m']) if m else 0} tracks, subscribed {len(want)}")
        if not problems:
            return
        if time.time() > deadline:
            raise Mismatch(f"{what}:\n    " + "\n    ".join(problems[:10]))


MUTE = """
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  if reaper.GetTrackGUID(tr) == "%s" then reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", %d) end
end
"""


@op("track/subscribe + unsubscribe: the mixer follows its tracks by GUID, then by range, then stops",
    "track/subscribe", "track/unsubscribe")
@tidy
def _(t):
    users = t.tracks()
    if len(users) < 4:
        raise Skip("needs four tracks")
    by_name = {tr["name"]: g for g, tr in users}
    picked = [by_name.get("Bass DI", users[1][0]), by_name.get("Lead Vox", users[-1][0])]
    w = t.watcher
    try:
        # The other phone leaves the mixer, so only this phone's tracks are polled.
        t.send("track/unsubscribe", awaited=True, client=w)
        r = awaited(t, "track/subscribe", guids=picked)
        if r.get("subscribedCount") != len(picked):
            raise Mismatch(f"track/subscribe by GUID returned {r}")
        wait_tracks_event(t, t.c, picked, "subscribed by GUID")
        # The mixer bank: unified indices 0..3, master included.
        r = awaited(t, "track/subscribe", range={"start": 0, "end": 3}, includeMaster=True)
        window = ["master"] + [g for g, tr in users if tr["pos"] <= 3]
        if r.get("subscribedCount") != len(window):
            raise Mismatch(f"track/subscribe by range returned {r}, expected {len(window)} tracks")
        wait_tracks_event(t, t.c, window, "subscribed to range 0..3")
        # A mute in REAPER on a track in the window reaches the phone.
        g = window[2]
        was = int(t.d["tracks"][g]["mute"])
        reaper(MUTE % (g, 1 - was))
        wait_tracks_event(t, t.c, window, "after a mute in REAPER")
        reaper(MUTE % (g, was))
        wait_tracks_event(t, t.c, window, "after the mute is undone in REAPER")
        # Leaving the mixer: tracks and meters stop once the grace period ends.
        awaited(t, "track/unsubscribe")
        deadline = time.time() + 4
        while True:
            t.c.drain(0.5)
            mark = len(t.c.events)
            reaper(MUTE % (g, 1 - was))
            t.c.drain(0.8)
            reaper(MUTE % (g, was))
            t.c.drain(0.4)
            late = [n for n, _ in t.c.events[mark:] if n in ("tracks", "meters")]
            if not late:
                break
            if time.time() > deadline:
                raise Mismatch(f"after track/unsubscribe the phone still gets {sorted(set(late))} events")
    finally:
        n = len(t.tracks())
        t.send("track/subscribe", client=w, range={"start": 0, "end": max(n, 1)}, includeMaster=True)
    t.expect({})


SEND_VOL = """
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  if reaper.GetTrackGUID(tr) == "%s" then reaper.SetTrackSendInfo_Value(tr, 0, %d, "D_VOL", %r) end
end
"""


@op("routing/subscribe + unsubscribe: the routing modal follows REAPER, switches track, closes",
    "routing/subscribe", "routing/unsubscribe")
@tidy
def _(t):
    bus, b_tr = prefer(t, "Verb Bus", lambda g, tr: tr["recvs"])
    src = b_tr["recvs"][0]["src"]
    k = [i for i, s in enumerate(t.d["tracks"][src]["sends"]) if s["dest"] == bus][0]
    vol = t.d["tracks"][src]["sends"][k]["vol"]
    try:
        open_routing(t, t.c, bus)
        # The engineer rides the send in REAPER; the open modal follows.
        reaper(SEND_VOL % (src, k, 0.125))
        wait_routing(t, t.c, bus)
        reaper(SEND_VOL % (src, k, vol))
        wait_routing(t, t.c, bus)
        # Tapping another track's routing replaces the subscription.
        open_routing(t, t.c, src)
        t.c.drain(0.5)
        mark = len(t.c.events)
        reaper(SEND_VOL % (src, k, 0.125))
        wait_routing(t, t.c, src)
        reaper(SEND_VOL % (src, k, vol))
        wait_routing(t, t.c, src)
        if latest_routing(t.c, bus, since=mark) is not None:
            raise Mismatch("routing_state for the previous track still arrives after switching tracks")
        # Closing the modal stops routing events.
        awaited(t, "routing/unsubscribe")
        t.c.drain(0.3)
        mark = len(t.c.events)
        reaper(SEND_VOL % (src, k, 0.125))
        t.c.drain(0.8)
        reaper(SEND_VOL % (src, k, vol))
        t.c.drain(0.4)
        late = [m for n, m in t.c.events[mark:] if n == "routing_state"]
        if late:
            raise Mismatch(f"routing_state still arrives after routing/unsubscribe: {late[-1]['payload'].get('trackGuid')}")
    finally:
        reaper(SEND_VOL % (src, k, vol))
        close_routing(t, t.c)
    t.expect({})


# ----------------------------------------------------------------------------
# Master and meters

@op("master/toggleMono: mono and back", "master/toggleMono")
@tidy
def _(t):
    for _ in range(2):
        mono = int(t.d["tracks"]["master"]["mono"])
        before = t.digest()
        r = t.ok("master/toggleMono")
        t.flat = before
        t.expect({"tracks.master.mono": 1 - mono})
        if r is not None and (r.get("payload") or {}).get("stereoEnabled") != (mono == 1):
            raise Mismatch(f"master/toggleMono returned {r.get('payload')}; REAPER's mono toggle is now {1 - mono}")
        # REAPER's own action makes the undo point.
        t.undo_redo(before, t.flat)


PEAK_HOLDS = """
local out = {master = {reaper.Track_GetPeakHoldDB(reaper.GetMasterTrack(0), 0, false),
                       reaper.Track_GetPeakHoldDB(reaper.GetMasterTrack(0), 1, false)}}
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  out[reaper.GetTrackGUID(tr)] = {reaper.Track_GetPeakHoldDB(tr, 0, false), reaper.Track_GetPeakHoldDB(tr, 1, false)}
end
return out
"""

CLEAR_HOLDS = """
local function clear(tr) reaper.Track_GetPeakHoldDB(tr, 0, true); reaper.Track_GetPeakHoldDB(tr, 1, true) end
clear(reaper.GetMasterTrack(0))
for i = 0, reaper.CountTracks(0) - 1 do clear(reaper.GetTrack(0, i)) end
"""

TRACK_VOL = """
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  if reaper.GetTrackGUID(tr) == "%s" then reaper.SetMediaTrackInfo_Value(tr, "D_VOL", %r) end
end
"""


@op("meter/clearClip: the kick clips during playback, a tap on its clip LED clears only it", "meter/clearClip")
@tidy
def _(t):
    playable = t.playable_audio()
    loud = [(it["track"], it["pos"]) for _, it in t.items(
        lambda g, it: not t.d["tracks"][it["track"]]["mute"] and not it["mute"] and g in playable)]
    if not loud:
        raise Skip("needs an unmuted item whose audio REAPER can play (offline media plays silent)")
    by_name = {tr["name"]: g for g, tr in t.tracks()}
    g = by_name.get("Kick") if by_name.get("Kick") in {x for x, _ in loud} else loud[0][0]
    start = min(p for x, p in loud if x == g)
    vol, cursor = t.d["tracks"][g]["vol"], t.d["project"]["cursor"]
    pos = t.d["tracks"][g]["pos"]
    try:
        # The engineer pushes the kick +12 dB in REAPER and plays from its first hit.
        reaper(CLEAR_HOLDS + TRACK_VOL % (g, 4.0) + f"reaper.SetEditCurPos({start!r}, false, false); reaper.OnPlayButton()")
        deadline = time.time() + 4
        while True:
            t.c.drain(0.2)
            m = t.c.latest_event("meters")
            if m and m["m"].get(g, {}).get("c") is True:
                break
            if time.time() > deadline:
                raise Mismatch(f"the kick never shows clip: meters {m and m['m'].get(g)}, REAPER holds {reaper(PEAK_HOLDS).get(g)}")
        reaper("reaper.OnStopButton()" + TRACK_VOL % (g, vol))
        t.c.drain(0.3)
        holds = reaper(PEAK_HOLDS)
        others = [x for x, h in holds.items() if x != g and max(h) > 0]
        # LevelMeter sends the track's index.
        t.ok("meter/clearClip", trackIdx=pos)
        deadline = time.time() + 2
        while True:
            t.c.drain(0.2)
            m = t.c.latest_event("meters")["m"]
            holds = reaper(PEAK_HOLDS)
            problems = []
            if m.get(g, {}).get("c") is not False or max(holds[g]) > 0:
                problems.append(f"the kick still clips: meter {m.get(g)}, REAPER hold {holds[g]}")
            for x in others:
                if max(holds[x]) <= 0 or (x in m and m[x].get("c") is not True):
                    problems.append(f"clearing the kick cleared {t.d['tracks'][x]['name'] or x}: meter {m.get(x)}, REAPER hold {holds[x]}")
            if not problems:
                break
            if time.time() > deadline:
                raise Mismatch("after meter/clearClip:\n    " + "\n    ".join(problems))
    finally:
        reaper("reaper.OnStopButton()" + TRACK_VOL % (g, vol) + CLEAR_HOLDS + f"reaper.SetEditCurPos({cursor!r}, false, false)")
    t.expect({})
