"""Track FX, FX parameters, presets, the tuner, actions, toggle states, undo and redo."""
import json
import time

from reamo_client import reaper
from tour import ANY, Mismatch, Skip, op


# ----------------------------------------------------------------------------
# Helpers

def bypassed(g, fg, f, enabled):
    """What the digest shows for an FX switched on or off: its enabled flag
    and, when it is among the parameters the digest records, the bypass
    parameter REAPER exposes for the same switch."""
    bp = reaper(f"""
local tr, fx = {track_expr(g)}, {f['pos']}
if reaper.TrackFX_GetParamFromIdent then return reaper.TrackFX_GetParamFromIdent(tr, fx, ":bypass") end
-- Before TrackFX_GetParamFromIdent, the bypass parameter is the one REAPER
-- names "Bypass" among those it appends to the plugin's own.
for p = reaper.TrackFX_GetNumParams(tr, fx) - 1, 0, -1 do
  local _, name = reaper.TrackFX_GetParamName(tr, fx, p, "")
  if name == "Bypass" then return p end
end
return -1
""")
    key = f"tracks.{g}.fx.{fg}"
    out = {f"{key}.enabled": enabled}
    if 0 <= bp < len(f["params"]):
        out[f"{key}.params.{bp}"] = int(not enabled)
    return out


def require_undo_point(t, prior, what):
    """Fail, before any undo/do is sent, when an edit added no undo point:
    Ctrl+Z would then revert the edit before it instead."""
    if t.d["undo"]["can_undo"] == prior:
        raise Mismatch(f"{what} added no undo point: Ctrl+Z now undoes {prior!r} instead")


def chain(t, g, rec=False):
    """A track's FX in chain order, as REAPER reports them: [(fx guid, digest)]."""
    fx = t.d["tracks"][g]["infx" if rec else "fx"]
    return sorted(fx.items(), key=lambda kv: kv[1]["pos"])


def target_fx(t, pred=lambda f: True):
    """The FX a user would open: the lead vocal's compressor in the band
    session, else the first working FX on any track that satisfies pred.
    Returns (track guid, track digest, fx guid, fx digest)."""
    for g, tr in t.tracks():
        if tr["name"] == "Lead Vox":
            for fg, f in chain(t, g):
                if "ReaComp" in f["name"] and pred(f):
                    return g, tr, fg, f
    for g, tr in t.tracks():
        for fg, f in chain(t, g):
            if not f["offline"] and pred(f):
                return g, tr, fg, f
    raise Skip("no track has a working FX the op can use")


def preferred_track(t, name, pred=lambda tr: True):
    """The named track when the project has it, else the first that fits."""
    for g, tr in t.tracks():
        if tr["name"] == name and pred(tr):
            return g, tr
    return t.track(pred=lambda g, tr: pred(tr))


def lua_str(s):
    """A Lua string literal holding s exactly."""
    return "'" + "".join(f"\\{b}" for b in s.encode("utf-8")) + "'"


def track_expr(g):
    """Lua expression for the track with this digest key."""
    if g == "master":
        return "reaper.GetMasterTrack(0)"
    return (f"(function() for i = 0, reaper.CountTracks(0) - 1 do local tr = reaper.GetTrack(0, i) "
            f"if reaper.GetTrackGUID(tr) == {lua_str(g)} then return tr end end end)()")


def since(c):
    """Marker for events received from now on (see wait_payload)."""
    return len(c.events)


def wait_payload(c, event, mark, pred=lambda p: True, timeout=3.0, what=None):
    """The latest `event` received after `mark` whose payload satisfies pred."""
    deadline = time.time() + timeout
    while True:
        for name, msg in reversed(c.events[mark:]):
            if name == event and pred(msg.get("payload")):
                return msg.get("payload")
        if time.time() > deadline:
            seen = [n for n, _ in c.events[mark:]]
            raise Mismatch(f"no {what or event} event within {timeout} s "
                           f"(received after the command: {sorted(set(seen))})")
        c.drain(0.1)


def events_after(c, event, mark):
    return [msg for name, msg in c.events[mark:] if name == event]


def undo_step(t, before):
    """The edit since `before` is one undo step: undo and redo from the
    client return the project to `before` and to its current state."""
    t.undo_redo(before, t.digest())


def chain_problems(t, g, payload):
    """trackFxChain event vs REAPER's FX chain for the track."""
    want = [(fg, f["pos"], f["name"], f["preset"], f["preset_idx"], f["preset_count"], bool(f["enabled"]))
            for fg, f in chain(t, g)]
    have = [(f["fxGuid"], f["fxIndex"], f["name"], f["presetName"], f["presetIndex"], f["presetCount"], f["enabled"])
            for f in payload.get("fx", [])]
    if payload.get("trackGuid") != g:
        return [f"trackFxChain.trackGuid = {payload.get('trackGuid')!r}, subscribed {g!r}"]
    return [] if have == want else [f"trackFxChain {have} vs REAPER {want}"]


def wait_chain(t, g, mark):
    """Wait until the phone's latest trackFxChain shows REAPER's chain."""
    deadline = time.time() + 3.0
    while True:
        evs = events_after(t.c, "trackFxChain", mark)
        t.digest()
        problems = chain_problems(t, g, evs[-1]["payload"]) if evs else ["no trackFxChain event"]
        if not problems:
            return
        if time.time() > deadline:
            raise Mismatch("FX chain view disagrees with REAPER:\n    " + "\n    ".join(problems))
        t.c.drain(0.15)


def param_facts(g, fg, indices):
    """REAPER's normalized and formatted values for these params of an FX."""
    idx = ",".join(str(i) for i in indices)
    return reaper(f"""
local tr = {track_expr(g)}
local fx
for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
  if reaper.TrackFX_GetFXGUID(tr, i) == {lua_str(fg)} then fx = i end
end
local out = {{}}
for _, p in ipairs({{{idx}}}) do
  local _, f = reaper.TrackFX_GetFormattedParamValue(tr, fx, p, "")
  out[#out + 1] = {{reaper.TrackFX_GetParamNormalized(tr, fx, p), f}}
end
return out
""")


def param_names(g, fg):
    return reaper(f"""
local tr = {track_expr(g)}
for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
  if reaper.TrackFX_GetFXGUID(tr, i) == {lua_str(fg)} then
    local out = {{}}
    for p = 0, reaper.TrackFX_GetNumParams(tr, i) - 1 do
      out[#out + 1] = select(2, reaper.TrackFX_GetParamName(tr, i, p, ""))
    end
    return out
  end
end
""") or []


def values_problems(payload, facts, indices):
    vals = payload.get("values", {})
    out = []
    if sorted(int(k) for k in vals) != sorted(indices):
        return [f"trackFxParams carries params {sorted(int(k) for k in vals)[:12]}..., subscribed {indices[:12]}..."]
    for p, (norm, fmt) in zip(indices, facts):
        v, f = vals[str(p)]
        if abs(v - norm) > 1e-5 or f != fmt:
            out.append(f"param {p} = [{v}, {f!r}], REAPER [{norm}, {fmt!r}]")
    return out


# ----------------------------------------------------------------------------
# FX chain

@op("fx chain: open the vocal's, bypass the compressor, close",
    "trackFx/subscribe", "trackFx/setEnabled", "trackFx/unsubscribe")
def _(t):
    g, tr, comp, f = target_fx(t)
    mark = since(t.c)
    t.ok("trackFx/subscribe", trackGuid=g)
    wait_chain(t, g, mark)

    # The bypass switch in the FX row toggles (FxModal sends no `enabled`).
    t.digest()
    before = t.flat
    mark = since(t.c)
    on = bool(f["enabled"])
    t.ok("trackFx/setEnabled", trackGuid=g, fxIdx=f["pos"])
    t.expect(bypassed(g, comp, f, not on))
    undo_step(t, before)
    wait_chain(t, g, mark)
    t.digest()
    t.ok("trackFx/setEnabled", trackGuid=g, fxIdx=f["pos"])
    t.expect(bypassed(g, comp, f, on))

    # Explicit state, by unified index, on the master's first FX.
    for m_fx, mf in chain(t, "master")[:1]:
        on = bool(mf["enabled"])
        t.digest()
        t.ok("trackFx/setEnabled", trackIdx=0, fxIdx=mf["pos"], enabled=int(not on))
        t.expect(bypassed("master", m_fx, mf, not on))
        t.digest()
        t.ok("trackFx/setEnabled", trackIdx=0, fxIdx=mf["pos"], enabled=int(on))
        t.expect(bypassed("master", m_fx, mf, on))

    # Closing the chain view stops its events: a bypass made in REAPER now
    # reaches the phone only through fx_state.
    t.ok("trackFx/unsubscribe")
    t.c.drain(0.3)
    mark = since(t.c)
    expr = track_expr(g)
    reaper(f"local tr = {expr}; reaper.TrackFX_SetEnabled(tr, {f['pos']}, {'false' if on else 'true'})")
    t.c.drain(1.0)
    reaper(f"local tr = {expr}; reaper.TrackFX_SetEnabled(tr, {f['pos']}, {'true' if on else 'false'})")
    if events_after(t.c, "trackFxChain", mark):
        raise Mismatch("trackFxChain events still arrive after trackFx/unsubscribe")


@op("plugin browser: add ReaEQ to the vocal, move it before the compressor, remove it",
    "fxPlugin/getList", "trackFx/add", "trackFx/move", "trackFx/delete")
def _(t):
    g, tr, comp, cf = target_fx(t)
    n0 = len(chain(t, g))

    # The browser loads the installed list once, awaiting it.
    r = t.send("fxPlugin/getList", awaited=True)
    if not r.get("success"):
        raise Mismatch(f"fxPlugin/getList failed: {r}")
    if not reaper("return reaper.APIExists('EnumInstalledFX')"):
        # The plugin list isn't supported before REAPER has EnumInstalledFX:
        # the browser is just empty.
        if r["payload"] != []:
            raise Mismatch(f"fxPlugin/getList without EnumInstalledFX: {r['payload'][:3]}..., not an empty list")
        raise Skip("this REAPER has no EnumInstalledFX: the plugin browser is empty, as it should be")
    want = reaper("""
local out = {}
local i = 0
while true do
  local ok, name, ident = reaper.EnumInstalledFX(i)
  if not ok then break end
  out[#out + 1] = {name, ident}
  i = i + 1
end
return out
""", timeout=10)
    got = r["payload"]
    if got != want:
        raise Mismatch(f"fxPlugin/getList: {len(got)} plugins, REAPER {len(want)}; "
                       f"first difference {next((a, b) for a, b in zip(got + [None] * len(want), want + [None] * len(got)) if a != b)}")
    ident = next((i for n, i in got if n == "VST: ReaEQ (Cockos)"), None)
    if ident is None:
        raise Skip("ReaEQ is not installed")

    # Tapping a plugin adds it at the end of the chain with the list's ident.
    t.digest()
    before = t.flat
    r = t.send("trackFx/add", trackGuid=g, fxName=ident)
    if r is None or not r.get("success"):
        raise Mismatch(f"trackFx/add of the browser's ident {ident!r} failed: {r}")
    eq = r["payload"]["fxGuid"]
    t.expect({f"tracks.{g}.fx.{eq}.*": ANY})
    eqd = t.d["tracks"][g]["fx"].get(eq)
    if eqd is None or eqd["pos"] != n0 or eqd["name"] != "VST: ReaEQ (Cockos)" or r["payload"]["fxIndex"] != n0:
        raise Mismatch(f"trackFx/add -> {r['payload']}; REAPER chain {[(k, v['pos'], v['name']) for k, v in chain(t, g)]}")
    undo_step(t, before)

    # Drag it above the compressor.
    t.digest()
    before = t.flat
    r = t.send("trackFx/move", trackGuid=g, fxGuid=eq, toIndex=cf["pos"])
    if r is not None and (not r.get("success") or r["payload"]["newIndex"] != cf["pos"]):
        raise Mismatch(f"trackFx/move: {r}")
    t.expect({f"tracks.{g}.fx.{eq}.pos": cf["pos"], f"tracks.{g}.fx.{comp}.pos": cf["pos"] + 1})
    undo_step(t, before)

    # And back below it: the FX lands at the index the user dropped it on.
    t.digest()
    r = t.send("trackFx/move", trackGuid=g, fxGuid=eq, toIndex=cf["pos"] + 1)
    if r is not None and (not r.get("success") or r["payload"]["newIndex"] != cf["pos"] + 1):
        raise Mismatch(f"trackFx/move: {r}")
    t.expect({f"tracks.{g}.fx.{eq}.pos": cf["pos"] + 1, f"tracks.{g}.fx.{comp}.pos": cf["pos"]})

    # Remove it, as the chain view does (by GUID).
    t.digest()
    before = t.flat
    t.ok("trackFx/delete", trackGuid=g, fxGuid=eq)
    t.expect({f"tracks.{g}.fx.{eq}.*": ANY})
    if eq in t.d["tracks"][g]["fx"]:
        raise Mismatch("trackFx/delete left the FX in the chain")
    undo_step(t, before)


@op("trackFx/add at a position, delete by index", "trackFx/add", "trackFx/delete")
def _(t):
    g, tr = preferred_track(t, "Kick", lambda tr: len(tr["fx"]) >= 2)
    names = [f["name"] for _, f in chain(t, g)]
    t.digest()
    before = t.flat
    r = t.send("trackFx/add", trackGuid=g, fxName="ReaComp", position=1)
    if r is None or not r.get("success"):
        raise Mismatch(f"trackFx/add at position 1 failed: {r}")
    new = r["payload"]["fxGuid"]
    t.expect({f"tracks.{g}.fx.*.pos": ANY, f"tracks.{g}.fx.{new}.*": ANY})
    now = [f["name"] for _, f in chain(t, g)]
    if now != names[:1] + ["VST: ReaComp (Cockos)"] + names[1:] or r["payload"]["fxIndex"] != 1:
        raise Mismatch(f"trackFx/add at position 1 -> {r['payload']}; REAPER chain {now}, was {names}")
    undo_step(t, before)

    t.digest()
    t.ok("trackFx/delete", trackGuid=g, fxIndex=1)
    t.expect({f"tracks.{g}.fx.*.pos": ANY, f"tracks.{g}.fx.{new}.*": ANY})
    now = [f["name"] for _, f in chain(t, g)]
    if now != names:
        raise Mismatch(f"trackFx/delete fxIndex=1 left {now}, expected {names}")


@op("presets: step the compressor's presets, pick one, go back",
    "trackFx/presetNext", "trackFx/presetPrev", "trackFx/presetSet")
def _(t):
    g, tr, comp, f = target_fx(t, lambda f: f["preset_count"] >= 3)
    count = f["preset_count"]
    key = f"tracks.{g}.fx.{comp}"
    # Loading a preset sets the plugin's parameters (any of them) and its
    # preset name to whatever the preset holds.
    changed = {f"{key}.params.*": ANY, f"{key}.preset": ANY}
    chunk = reaper(f"return select(2, reaper.GetTrackStateChunk({track_expr(g)}, '', false))")
    try:
        t.digest()
        before = t.flat
        prior = t.d["undo"]["can_undo"]
        start = f["preset_idx"]
        t.ok("trackFx/presetNext", trackIdx=tr["pos"], fxIdx=f["pos"])
        want = (start + 1) % count
        t.expect({**changed, f"{key}.preset_idx": want})
        require_undo_point(t, prior, "trackFx/presetNext")
        undo_step(t, before)

        t.digest()
        t.ok("trackFx/presetNext", trackIdx=tr["pos"], fxIdx=f["pos"])
        t.expect({**changed, f"{key}.preset_idx": (want + 1) % count})
        t.digest()
        t.ok("trackFx/presetPrev", trackIdx=tr["pos"], fxIdx=f["pos"])
        t.expect({**changed, f"{key}.preset_idx": want})
        t.digest()
        pick = count - 1
        t.ok("trackFx/presetSet", trackIdx=tr["pos"], fxIdx=f["pos"], presetIdx=pick)
        t.expect({**changed, f"{key}.preset_idx": pick})
        if not t.d["tracks"][g]["fx"][comp]["preset"]:
            raise Mismatch("presetSet left the compressor with no preset name")
        # Back to how the session had it, one undo step per preset change.
        for _ in range(4):
            t.ok("undo/do")
        t._wait_equal(t.op_start, "undoing the preset changes did not restore the compressor")
    finally:
        t.digest()
        if any(k.startswith(key + ".") and t.flat.get(k) != v for k, v in t.op_start.items()):
            reaper(f"reaper.SetTrackStateChunk({track_expr(g)}, {lua_str(chunk)}, false)")
            t.digest()
            left = {k: v for k, v in t.op_start.items() if not k.startswith("undo.") and t.flat.get(k) != v}
            if left:
                print(f"      presets op could not restore the compressor: {left}")


# ----------------------------------------------------------------------------
# FX parameters

@op("param view: open the compressor's parameters, drag the first one (one undo step)",
    "trackFx/getParams", "trackFxParams/subscribe", "trackFxParams/set", "trackFxParams/unsubscribe")
def _(t):
    g, tr, comp, f = target_fx(t, lambda f: f["nparams"] >= 3)

    r = t.send("trackFx/getParams", awaited=True, trackGuid=g, fxGuid=comp)
    if not r.get("success"):
        raise Mismatch(f"trackFx/getParams failed: {r}")
    names = param_names(g, comp)
    p = r["payload"]
    if (p["trackGuid"], p["fxGuid"], p["paramCount"], p["params"]) != (g, comp, len(names), names):
        raise Mismatch(f"trackFx/getParams = {p}, REAPER names {names}")

    # A scrolling list subscribes to the visible window of parameters.
    rows = list(range(0, min(len(names), 12)))
    mark = since(t.c)
    t.ok("trackFxParams/subscribe", trackGuid=g, fxGuid=comp, range={"start": rows[0], "end": rows[-1]})
    ev = wait_payload(t.c, "trackFxParams", mark, lambda pl: pl.get("fxGuid") == comp)
    if (ev["trackGuid"], ev["paramCount"]) != (g, len(names)):
        raise Mismatch(f"trackFxParams header {ev}")
    problems = values_problems(ev, param_facts(g, comp, rows), rows)
    if problems:
        raise Mismatch("trackFxParams vs REAPER:\n    " + "\n    ".join(problems))

    # Drag the first parameter (the threshold) well away from where it is:
    # gesture, a stream of sets, gesture end.
    t.digest()
    before = t.flat
    prior = t.d["undo"]["can_undo"]
    start = t.flat[f"tracks.{g}.fx.{comp}.params.0"]
    end = 0.25 if start > 0.5 else 0.75
    gesture = dict(controlType="fxParam", trackGuid=g, fxGuid=comp, paramIdx=0)
    t.ok("gesture/start", **gesture)
    for i in range(1, 21):
        t.c.fire("trackFxParams/set", trackGuid=g, fxGuid=comp, paramIdx=0, value=start + (end - start) * i / 20)
        time.sleep(0.01)
    t.ok("gesture/end", **gesture)
    t.expect({f"tracks.{g}.fx.{comp}.params.0": lambda v: abs(v - end) < 0.02})
    try:
        require_undo_point(t, prior, "a gesture over trackFxParams/set")
    except Mismatch:
        # Put the knob back from REAPER's side (its own undo point).
        reaper(f"reaper.TrackFX_SetParamNormalized({track_expr(g)}, {f['pos']}, 0, {start})")
        raise
    undo_step(t, before)
    dragged = t.flat[f"tracks.{g}.fx.{comp}.params.0"]

    mark = since(t.c)
    ev = wait_payload(t.c, "trackFxParams", mark,
                      lambda pl: pl.get("fxGuid") == comp and abs(pl["values"]["0"][0] - dragged) < 1e-5,
                      what="trackFxParams showing the dragged value")
    problems = values_problems(ev, param_facts(g, comp, rows), rows)
    if problems:
        raise Mismatch("trackFxParams after the drag vs REAPER:\n    " + "\n    ".join(problems))

    # Indices mode, as the filtered/pinned parameter view subscribes.
    pinned = [rows[-1], 0, 2]
    mark = since(t.c)
    t.ok("trackFxParams/subscribe", trackGuid=g, fxGuid=comp, indices=pinned)
    ev = wait_payload(t.c, "trackFxParams", mark, lambda pl: len(pl.get("values", {})) == len(pinned))
    problems = values_problems(ev, param_facts(g, comp, pinned), pinned)
    if problems:
        raise Mismatch("trackFxParams (indices) vs REAPER:\n    " + "\n    ".join(problems))

    # Closing the view stops its events: the same knob turned in REAPER no
    # longer reaches the phone as trackFxParams.
    t.ok("trackFxParams/unsubscribe")
    t.c.drain(0.3)
    t.digest()
    prior = t.d["undo"]["can_undo"]
    mark = since(t.c)
    reaper(f"reaper.TrackFX_SetParamNormalized({track_expr(g)}, {f['pos']}, 0, {(start + end) / 2})")
    t.c.drain(0.8)
    if events_after(t.c, "trackFxParams", mark):
        raise Mismatch("trackFxParams events still arrive after trackFxParams/unsubscribe")
    # Ctrl+Z for REAPER's knob turn (when REAPER recorded one), then the drag.
    t.digest()
    if t.d["undo"]["can_undo"] != prior:
        t.ok("undo/do")
    t.ok("undo/do")
    t._wait_equal(t.op_start, "the compressor did not return to its state before the drag")


# A plugin with as many parameters as REAPER allows a JSFX, each with a long
# name and long value labels: big synths and channel strips are this size.
BIG_JSFX = "harness/many-params"


def big_jsfx_source():
    lines = ["desc: Harness many-parameter plugin"]
    for i in range(1, 257):
        a = f"Option A for parameter {i:03d} ".ljust(120, "a")
        b = f"Option B for parameter {i:03d} ".ljust(120, "b")
        name = f"Parameter {i:03d} ".ljust(254, "x")
        lines.append(f"slider{i}:0<0,1,1{{{a},{b}}}>{name}")
    lines += ["@sample", ""]
    return "\n".join(lines)


@op("param view on a plugin with hundreds of long-named parameters",
    "trackFx/getParams", "trackFxParams/subscribe", "trackFxParams/unsubscribe")
def _(t):
    g, tr = t.track()
    src = big_jsfx_source()
    fg = reaper(f"""
local dir = reaper.GetResourcePath() .. "/Effects/harness"
reaper.RecursiveCreateDirectory(dir, 0)
local f = assert(io.open(dir .. "/many-params", "wb"))
f:write({lua_str(src)})
f:close()
local tr = {track_expr(g)}
local i = reaper.TrackFX_AddByName(tr, "JS:{BIG_JSFX}", false, -1)
if i < 0 then return nil end
return reaper.TrackFX_GetFXGUID(tr, i)
""", timeout=10)
    if not fg:
        raise Skip("REAPER could not load the generated JSFX")
    try:
        t.digest()
        names = param_names(g, fg)
        r = t.send("trackFx/getParams", awaited=True, trackGuid=g, fxGuid=fg)
        if not r.get("success"):
            raise Mismatch(f"trackFx/getParams on {len(names)} parameters failed: {r}")
        size = len(json.dumps(r["payload"]))
        if r["payload"]["params"] != names:
            raise Mismatch(f"trackFx/getParams ({size} bytes) names differ from REAPER's {len(names)}")
        if size <= 65536:
            longest = max(len(n.encode()) for n in names)
            if len(names) < 256 or longest < 254:
                raise Skip(f"this REAPER loads {len(names)} of the plugin's 256 sliders, with names of up to "
                           f"{longest} bytes: the list ({size} bytes) can't exceed 64 KB")
            raise Mismatch(f"the fixture plugin's parameter list is only {size} bytes; it must exceed 64 KB")

        # The parameter list scrolls to show every row at once on a tablet.
        rows = list(range(len(names)))
        mark = since(t.c)
        t.ok("trackFxParams/subscribe", trackGuid=g, fxGuid=fg, range={"start": 0, "end": rows[-1]})
        deadline = time.time() + 3.0
        while True:
            err = events_after(t.c, "trackFxParamsError", mark)
            if err:
                raise Mismatch(f"trackFxParams/subscribe over {len(rows)} params got {err[-1]} instead of values "
                               f"(REAPER still has the FX)")
            evs = [e for e in events_after(t.c, "trackFxParams", mark) if e["payload"].get("fxGuid") == fg]
            if evs:
                problems = values_problems(evs[-1]["payload"], param_facts(g, fg, rows), rows)
                if problems:
                    raise Mismatch("trackFxParams vs REAPER:\n    " + "\n    ".join(problems[:10]))
                break
            if time.time() > deadline:
                raise Mismatch(f"no trackFxParams event for a {len(rows)}-param range subscription")
            t.c.drain(0.1)
        t.ok("trackFxParams/unsubscribe")
    finally:
        reaper(f"""
local tr = {track_expr(g)}
for i = reaper.TrackFX_GetCount(tr) - 1, 0, -1 do
  if reaper.TrackFX_GetFXGUID(tr, i) == {lua_str(fg)} then reaper.TrackFX_Delete(tr, i) end
end
""")


# ----------------------------------------------------------------------------
# Tuner

def tuner_round(t, g, label):
    """Open the tuner on a track, set reference and threshold, close it.
    The tuner is a JSFX the extension puts first in the track's input FX
    and takes away again, leaving the project as it was. On a track, adding
    and removing it are REAPER's own two undo steps ("Add FX", "Remove FX"),
    as the tuner is meant to work; on the master its input FX is REAPER's
    monitoring chain, outside the project, so there is no undo history."""
    start = t.digest()
    undo_before = dict(t.d["undo"])
    n_in = len(chain(t, g, rec=True))
    mark = since(t.c)
    r = t.send("tuner/subscribe", trackGuid=g)
    if r is None or not r.get("success"):
        raise Mismatch(f"tuner/subscribe on {label}: {r}")
    p = r["payload"]
    t.expect({f"tracks.{g}.infx.*": ANY})
    rec = chain(t, g, rec=True)
    if len(rec) != n_in + 1 or rec[0][0] != p["fxGuid"] or "Pitch" not in rec[0][1]["name"]:
        raise Mismatch(f"tuner/subscribe on {label} -> {p}; REAPER input FX {[(k, v['name']) for k, v in rec]}")
    # The name REAPER shows for the track ("MASTER" for the master).
    want_name = reaper(f"return select(2, reaper.GetTrackName({track_expr(g)}))")
    if (p["trackGuid"], p["trackName"], p["reference"], p["threshold"]) != (g, want_name, 440.0, -60.0):
        raise Mismatch(f"tuner/subscribe payload {p}")
    ev = wait_payload(t.c, "tuner", mark, lambda pl: pl.get("trackGuid") == g)
    if (ev["referenceHz"], ev["thresholdDb"]) != (440.0, -60.0):
        raise Mismatch(f"tuner event {ev}")

    t.ok("tuner/setParam", trackGuid=g, param="reference", value=442)
    t.ok("tuner/setParam", trackGuid=g, param="threshold", value=-50)
    jsfx = "reaper.TrackFX_GetParam(tr, 0x1000000, %d)"
    got = reaper(f"local tr = {track_expr(g)}; return {{{jsfx % 4}, {jsfx % 6}}}")
    if abs(got[0] - 442) > 0.05 or abs(got[1] + 50) > 0.5:
        raise Mismatch(f"tuner/setParam on {label}: the JSFX reads reference {got[0]}, threshold {got[1]}; sent 442, -50")
    mark = since(t.c)
    ev = wait_payload(t.c, "tuner", mark, lambda pl: pl.get("trackGuid") == g and abs(pl["referenceHz"] - 442) < 0.05,
                      what="tuner event showing the new reference")
    if abs(ev["thresholdDb"] + 50) > 0.5:
        raise Mismatch(f"tuner event after setParam {ev}")

    t.ok("tuner/unsubscribe")
    t._wait_equal(start, f"closing the tuner on {label} left REAPER's input FX changed")
    t.digest()
    if g == "master":
        if t.d["undo"]["can_undo"] != undo_before["can_undo"]:
            raise Mismatch(f"the tuner on {label} left undo history: Ctrl+Z now offers "
                           f"{t.d['undo']['can_undo']!r} (before the tuner: {undo_before['can_undo']!r})")
        return
    # Exactly two steps: undoing "Remove FX" puts the tuner back, undoing
    # "Add FX" takes it away again, and then the history is as before.
    top = t.d["undo"]["can_undo"]
    if not top.startswith("Remove FX"):
        raise Mismatch(f"closing the tuner on {label} left undo step {top!r}, not REAPER's \"Remove FX\"")
    reaper("reaper.Undo_DoUndo2(0)")
    t.digest()
    if not t.d["undo"]["can_undo"].startswith("Add FX"):
        raise Mismatch(f"before the tuner's \"Remove FX\" on {label}: {t.d['undo']['can_undo']!r}, not \"Add FX\"")
    reaper("reaper.Undo_DoUndo2(0)")
    t._wait_equal(start, f"undoing the tuner's two steps on {label} did not return the project to how it was")
    if t.d["undo"]["can_undo"] != undo_before["can_undo"]:
        raise Mismatch(f"the tuner on {label} left more than its two undo steps: Ctrl+Z now offers "
                       f"{t.d['undo']['can_undo']!r} (before the tuner: {undo_before['can_undo']!r})")


def remove_tuners(g):
    """Take any tuner JSFX out of the track's input FX (cleanup after a failure)."""
    return reaper(f"""
local tr = {track_expr(g)}
local n = 0
for i = reaper.TrackFX_GetRecCount(tr) - 1, 0, -1 do
  local _, name = reaper.TrackFX_GetFXName(tr, 0x1000000 + i, "")
  if name:find("Pitch Detector", 1, true) then reaper.TrackFX_Delete(tr, 0x1000000 + i); n = n + 1 end
end
return n
""")


@op("tuner on a track (the guitar)", "tuner/subscribe", "tuner/unsubscribe", "tuner/setParam")
def _(t):
    g, tr = preferred_track(t, "Guitar")
    try:
        tuner_round(t, g, tr["name"] or "an unnamed track")
    finally:
        t.send("tuner/unsubscribe")
        remove_tuners(g)


@op("tuner on the master", "tuner/subscribe", "tuner/unsubscribe", "tuner/setParam")
def _(t):
    try:
        tuner_round(t, "master", "the master")
    finally:
        t.send("tuner/unsubscribe")
        remove_tuners("master")


# ----------------------------------------------------------------------------
# Actions and toggle states

METRONOME = 40364  # Options: Toggle metronome
SCRIPT = "/tmp/harness-toggle-metronome.lua"
SCRIPT_SRC = """
reaper.Main_OnCommand(40364, 0)
local _, _, sec, cmd = reaper.get_action_context()
reaper.SetToggleCommandState(sec, cmd, reaper.GetToggleCommandState(40364))
reaper.RefreshToolbar2(sec, cmd)
"""


@op("toolbar: metronome by id and by a script's named command, toggle states",
    "action/execute", "action/executeByName", "action/getToggleState",
    "actionToggleState/subscribe", "actionToggleState/unsubscribe")
def _(t):
    # A user's script on a toolbar button: REAPER knows it by a named command.
    cmd = reaper(f"""
local f = assert(io.open({lua_str(SCRIPT)}, "wb")); f:write({lua_str(SCRIPT_SRC)}); f:close()
local id = reaper.AddRemoveReaScript(true, 0, {lua_str(SCRIPT)}, true)
reaper.SetToggleCommandState(0, id, reaper.GetToggleCommandState(40364))
return id
""")
    named = "_" + reaper(f"return reaper.ReverseNamedCommandLookup({cmd})")
    metro0 = t.d["project"]["metronome"]
    try:
        r = t.send("actionToggleState/subscribe", awaited=True,
                 actions=[{"c": METRONOME, "s": 0}], namedActions=[{"n": named, "s": 0}])
        if not r.get("success"):
            raise Mismatch(f"actionToggleState/subscribe: {r}")
        states = {(s["s"], s["c"]): s["v"] for s in r["payload"]["states"]}
        if states != {(0, METRONOME): metro0, (0, cmd): metro0} or r["payload"]["nameToId"] != [{"n": named, "s": 0, "c": cmd}]:
            raise Mismatch(f"actionToggleState/subscribe payload {r['payload']}; REAPER metronome {metro0}, script {cmd}")

        for how, params in (("id", {"commandId": METRONOME}), ("name", {"name": named})):
            t.digest()
            want = 1 - t.d["project"]["metronome"]
            mark = since(t.c)
            t.ok("action/execute" if how == "id" else "action/executeByName", **params)
            # REAPER keeps the metronome's on/off in bit 0 of its metronome
            # flags, where this REAPER can report them.
            changes = {"project.metronome": want}
            if "metro_flags" in t.d["project"]:
                changes["project.metro_flags"] = str(int(t.d["project"]["metro_flags"]) & ~1 | want)
            t.expect(changes)
            wait_payload(t.c, "actionToggleState", mark,
                         lambda pl: {"s": 0, "c": METRONOME, "v": want} in pl["changes"],
                         what=f"actionToggleState for the metronome (by {how})")
            r = t.send("action/getToggleState", awaited=True, commandId=METRONOME)
            if r["payload"]["state"] != reaper(f"return reaper.GetToggleCommandState({METRONOME})"):
                raise Mismatch(f"action/getToggleState {r['payload']} vs REAPER")
        # The script's own toggle state follows the metronome.
        r = t.send("action/getToggleState", awaited=True, name=named)
        if r["payload"]["state"] != reaper(f"return reaper.GetToggleCommandState({cmd})"):
            raise Mismatch(f"action/getToggleState by name {r['payload']} vs REAPER")

        # Leaving the actions view unsubscribes both, as ActionsView sends it.
        t.ok("actionToggleState/unsubscribe", actions=[{"c": METRONOME, "s": 0}], namedActions=[{"n": named, "s": 0}])
        t.c.drain(0.3)
        mark = since(t.c)
        reaper(f"reaper.Main_OnCommand({cmd}, 0)")
        t.c.drain(1.0)
        late = [c for e in events_after(t.c, "actionToggleState", mark) for c in e["payload"]["changes"]]
        if late:
            raise Mismatch(f"actionToggleState changes after unsubscribing {METRONOME} and {named} "
                           f"(command {cmd}): {late}")
    finally:
        reaper(f"""
if reaper.GetToggleCommandState({METRONOME}) ~= {metro0} then reaper.Main_OnCommand({METRONOME}, 0) end
reaper.AddRemoveReaScript(false, 0, {lua_str(SCRIPT)}, true)
os.remove({lua_str(SCRIPT)})
""")


@op("action list: getActions matches REAPER's action list", "action/getActions")
def _(t):
    r = t.send("action/getActions", awaited=True)
    if not r.get("success"):
        raise Mismatch(f"action/getActions failed: {r}")
    got = r["payload"]
    if not reaper("return reaper.APIExists('kbd_enumerateActions') and reaper.APIExists('SectionFromUniqueID')"):
        # REAPER 6.0 lists actions to an extension but not to a script, so
        # there is no oracle for the list.
        raise Skip(f"this REAPER can't list its actions to a script ({len(got)} from the extension, unchecked)")
    want = reaper("""
local out = {}
for _, sec in ipairs({0, 100, 32060, 32061, 32062, 32063}) do
  local s = reaper.SectionFromUniqueID(sec)
  local i = 0
  while true do
    local id, name = reaper.kbd_enumerateActions(s, i)
    if id == 0 then break end
    local nid = reaper.ReverseNamedCommandLookup(id)
    out[#out + 1] = {id, sec, name, reaper.GetToggleCommandStateEx(sec, id) ~= -1 and 1 or 0, nid and ("_" .. nid) or false}
    i = i + 1
  end
end
return out
""", timeout=20)
    want = [w[:4] + [w[4] or None] for w in want]
    if len(got) != len(want):
        raise Mismatch(f"action/getActions returned {len(got)} actions; REAPER's action list has {len(want)}")
    bad = [(a, b) for a, b in zip(got, want) if a != b]
    if bad:
        raise Mismatch(f"action/getActions: {len(bad)} entries differ from REAPER, e.g. {bad[:3]}")


# ----------------------------------------------------------------------------
# Undo and redo

@op("undo/do + redo/do after an edit made in REAPER", "undo/do", "redo/do")
def _(t):
    g, tr = t.track()
    edit = "Mute a track for the verse"
    before = t.digest()
    reaper(f"""
local tr = {track_expr(g)}
reaper.Undo_BeginBlock2(0)
reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1 - reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"))
reaper.Undo_EndBlock2(0, "{edit}", -1)
""")
    t.expect({f"tracks.{g}.mute": 1 - tr["mute"]})
    after = t.flat
    r = t.send("undo/do", awaited=True)
    if r != {**r, "success": True, "action": edit}:
        raise Mismatch(f"undo/do = {r}; REAPER's undo history offered {edit!r}")
    t._wait_equal(before, "undo/do did not undo REAPER's last edit")
    if t.d["undo"]["can_redo"] != edit:
        raise Mismatch(f"after undo/do REAPER offers redo of {t.d['undo']['can_redo']!r}")
    r = t.send("redo/do", awaited=True)
    if r != {**r, "success": True, "action": edit}:
        raise Mismatch(f"redo/do = {r}")
    t._wait_equal(after, "redo/do did not redo the edit")
    if t.d["undo"]["can_undo"] != edit:
        raise Mismatch(f"after redo/do REAPER offers undo of {t.d['undo']['can_undo']!r}")
    t.ok("undo/do")
    t._wait_equal(before, "undo/do did not restore the session")


@op("undo/add records the client's edit under the description as typed", "undo/add")
def _(t):
    gi, it = t.item(lambda g, i: not i["mute"])
    # An edit REAPER has not recorded yet (a script's change without its own
    # undo point); the client then names the undo step.
    def set_mute(v):
        reaper(f"""
for i = 0, reaper.CountMediaItems(0) - 1 do
  local it = reaper.GetMediaItem(0, i)
  if select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)) == {lua_str(gi)} then
    reaper.SetMediaItemInfo_Value(it, "B_MUTE", {v})
  end
end
reaper.UpdateArrange()
""")
    set_mute(1)
    t.expect({f"items.{gi}.mute": 1})
    prior = t.d["undo"]["can_undo"]
    undone = False
    try:
        # Quotes, a backslash and a tab: JSON.stringify escapes all three.
        desc = 'Mute "take 2" \\ keep\tbridge'
        t.ok("undo/add", description=desc)
        deadline = time.time() + 3.0
        while True:
            t.digest()
            got = t.d["undo"]["can_undo"]
            if got == desc:
                break
            if time.time() > deadline:
                raise Mismatch(f"undo/add with {desc!r}: REAPER's undo history shows {got!r}")
            t.c.drain(0.1)
        r = t.send("undo/do", awaited=True)
        undone = True
        if r.get("action") != desc:
            raise Mismatch(f"undo/do after undo/add = {r}")
        t._wait_equal(t.op_start, "undoing the client's undo point did not unmute the item")
    finally:
        # Leave history as the next op expects it: the client's undo point
        # undone, whatever description it got, and the item unmuted.
        t.digest()
        if not undone and t.d["undo"]["can_undo"] != prior:
            t.send("undo/do", awaited=True)
            t.digest()
        if t.d["items"][gi]["mute"]:
            set_mute(0)




