"""What a client shows, checked against REAPER's digest.

Every function returns a list of human-readable disagreements; an empty list
means the client's latest events describe the project exactly as REAPER does.
"""
import math


def custom_color(c):
    """REAPER returns a colour without the 0x1000000 "custom" flag for tracks
    that use the theme colour; clients show those as 0 (theme default)."""
    c = int(c)
    return c if c & 0x1000000 else 0


def close(a, b, tol=1e-3):
    return isinstance(a, (int, float)) and isinstance(b, (int, float)) and abs(a - b) <= tol


def mirror_problems(tour, c):
    d = tour.d
    problems = []
    for check in (skeleton, tracks, fx_state, sends_state, items, markers, regions, transport, project, tempo_map, playlists):
        try:
            problems += check(d, c, tour)
        except (KeyError, TypeError, IndexError) as e:
            problems.append(f"{check.__name__}: malformed or missing event ({type(e).__name__}: {e})")
    return problems


def ordered_tracks(d):
    user = sorted(((g, t) for g, t in d["tracks"].items() if g != "master"), key=lambda gt: gt[1]["pos"])
    return [("master", d["tracks"]["master"])] + user


def skeleton(d, c, tour):
    ev = c.latest_event("trackSkeleton")
    if ev is None:
        return ["no trackSkeleton event"]
    got = ev["payload"]["tracks"]
    want = ordered_tracks(d)
    out = []
    if [t["g"] for t in got] != [g for g, _ in want]:
        return [f"skeleton track order/GUIDs: {[t['g'][:9] for t in got]} vs REAPER {[g[:9] for g, _ in want]}"]
    item_counts = {}
    for it in d["items"].values():
        item_counts[it["track"]] = item_counts.get(it["track"], 0) + 1
    for s, (g, t) in zip(got, want):
        label = t["name"] or g[:9]
        exp = {
            "m": bool(t["mute"]), "sel": bool(t["sel"]), "r": bool(t["arm"]),
            "fd": int(t["depth"]), "sc": len(t["sends"]), "hc": len(t["hw"]),
            "ic": item_counts.get(g, 0), "fm": int(t["freemode"]),
        }
        if g != "master":
            exp["c"] = custom_color(t["color"])
            if t["name"]:
                exp["n"] = t["name"]
        for k, v in exp.items():
            if s.get(k) != v:
                out.append(f"skeleton {label}.{k} = {s.get(k)!r}, REAPER {v!r}")
        soloed = t["solo"] > 0
        if (s.get("sl") not in (None, 0)) != soloed:
            out.append(f"skeleton {label}.sl = {s.get('sl')!r}, REAPER solo {t['solo']}")
    return out


def tracks(d, c, tour):
    ev = c.latest_event("tracks")
    if ev is None:
        return ["no tracks event (watcher is subscribed to every track)"]
    got = {t["g"]: t for t in ev["payload"]["tracks"]}
    out = []
    want = ordered_tracks(d)
    if ev["payload"].get("total") != len(want) - 1:
        out.append(f"tracks.total = {ev['payload'].get('total')}, REAPER has {len(want) - 1} user tracks")
    for idx, (g, t) in enumerate(want):
        label = t["name"] or g[:9]
        e = got.get(g)
        if e is None:
            out.append(f"tracks event lacks {label}")
            continue
        exp = {
            "idx": idx, "mute": bool(t["mute"]), "solo": int(t["solo"]), "recArm": bool(t["arm"]),
            "recMon": int(t["mon"]), "fxEnabled": bool(t["fxen"]), "selected": bool(t["sel"]),
            "folderDepth": int(t["depth"]), "fxCount": len(t["fx"]), "sendCount": len(t["sends"]),
            "receiveCount": len(t["recvs"]), "hwOutCount": len(t["hw"]),
        }
        if g != "master":
            exp["color"] = custom_color(t["color"])
            if t["name"]:
                exp["name"] = t["name"]
            if t["arm"]:
                # The input chip shows only on armed tracks, as in REAPER.
                exp["recInput"] = int(t["input"])
        for k, v in exp.items():
            if e.get(k) != v and not (k == "color" and e.get(k) is None and v == 0):
                out.append(f"tracks {label}.{k} = {e.get(k)!r}, REAPER {v!r}")
        if not close(e["volume"], t["vol"], 1e-4):
            out.append(f"tracks {label}.volume = {e['volume']}, REAPER {t['vol']}")
        if not close(e["pan"], t["pan"], 1e-3):
            out.append(f"tracks {label}.pan = {e['pan']}, REAPER {t['pan']}")
    return out


def fx_state(d, c, tour):
    ev = c.latest_event("fx_state")
    if ev is None:
        # The extension sends fx_state only when it changes, so a client that has
        # seen no fx yet has an empty list, which is right while REAPER has none.
        if any(t["fx"] for t in d["tracks"].values()):
            return ["no fx_state event"]
        return []
    got = {}
    for f in ev["payload"]["fx"]:
        got.setdefault(f["trackIdx"], []).append(f)
    out = []
    for idx, (g, t) in enumerate(ordered_tracks(d)):
        want = sorted(t["fx"].items(), key=lambda kv: kv[1]["pos"])
        have = sorted(got.get(idx, []), key=lambda f: f["fxIndex"])
        label = t["name"] or g[:9]
        if [f["fxGuid"] for f in have] != [k for k, _ in want]:
            out.append(f"fx_state {label}: {[f['name'] for f in have]} vs REAPER {[v['name'] for _, v in want]}")
            continue
        for f, (_, w) in zip(have, want):
            if (f["name"], f["enabled"], f["presetName"], f["presetIndex"], f["presetCount"]) != (
                    w["name"], w["enabled"], w["preset"], w["preset_idx"], w["preset_count"]):
                out.append(f"fx_state {label}[{f['fxIndex']}] = {f}, REAPER {w}")
    return out


def sends_state(d, c, tour):
    ev = c.latest_event("sends_state")
    if ev is None:
        # The extension sends sends_state only when it changes, so a client that has
        # seen no sends yet has an empty list, which is right while REAPER has none.
        if any(t["sends"] for t in d["tracks"].values()):
            return ["no sends_state event"]
        return []
    got = {}
    for s in ev["payload"]["sends"]:
        got.setdefault(s["srcTrackIdx"], []).append(s)
    out = []
    for idx, (g, t) in enumerate(ordered_tracks(d)):
        have = sorted(got.get(idx, []), key=lambda s: s["sendIndex"])
        label = t["name"] or g[:9]
        if len(have) != len(t["sends"]):
            out.append(f"sends_state {label}: {len(have)} sends, REAPER {len(t['sends'])}")
            continue
        for s, w in zip(have, t["sends"]):
            dest = d["tracks"].get(w["dest"], {}).get("name")
            if (not close(s["volume"], w["vol"], 1e-4) or not close(s["pan"], w["pan"], 1e-3)
                    or s["muted"] != bool(w["mute"]) or s["mode"] != int(w["mode"])
                    or (dest and s["destName"] != dest)):
                out.append(f"sends_state {label}[{s['sendIndex']}] = {s}, REAPER {w} -> {dest}")
    return out


# Items the items event carries at most (MAX_ITEMS in extension/src/core/constants.zig).
MAX_ITEMS = 512


def items(d, c, tour):
    ev = c.latest_event("items")
    if ev is None:
        return ["no items event"]
    got = {i["guid"]: i for i in ev["payload"]["items"]}
    out = []
    pos = {g: t["pos"] for g, t in d["tracks"].items()}
    # The event carries the project's first MAX_ITEMS items, in track order.
    shown = dict(sorted(d["items"].items(), key=lambda gi: (pos[gi[1]["track"]], gi[1]["idx"]))[:MAX_ITEMS])
    if set(got) != set(shown):
        missing = set(shown) - set(got)
        extra = set(got) - set(shown)
        return [f"items: {len(missing)} of REAPER's first {len(shown)} not shown, {len(extra)} shown but not among them"]
    for g, it in shown.items():
        e = got[g]
        active = it["takes"][it["active"]] if it["active"] >= 0 else None
        checks = {
            "trackIdx": e["trackIdx"] == pos[it["track"]],
            "itemIdx": e["itemIdx"] == it["idx"],
            "position": close(e["position"], it["pos"], 1e-3),
            "length": close(e["length"], it["len"], 1e-3),
            "color": e["color"] == custom_color(it["color"]),
            "locked": e["locked"] == bool(int(it["lock"]) & 1),
            "selected": e["selected"] == bool(it["sel"]),
            "activeTakeIdx": e["activeTakeIdx"] == it["active"],
            "takeCount": e["takeCount"] == len(it["takes"]),
            "fixedLane": e["fixedLane"] == int(it["lane"]),
            "hasNotes": e["hasNotes"] == (not it["notes"].startswith("0:")),
        }
        if active and not active.get("empty"):
            checks["activeTakeGuid"] = e["activeTakeGuid"] == active["guid"]
            checks["activeTakeIsMidi"] = e["activeTakeIsMidi"] == bool(active["midi"])
            checks["activeTakeName"] = e["activeTakeName"] == active["name"]
            checks["activeTakeColor"] = e["activeTakeColor"] == (int(active["color"]) or None)
        for k, ok in checks.items():
            if not ok:
                out.append(f"item {g[:9]} on track {pos[it['track']]}: {k} = {e.get(k)!r}, REAPER {it}")
                break
    return out


def markers(d, c, tour):
    ev = c.latest_event("markers")
    if ev is None:
        return ["no markers event"]
    got = {f"M{m['id']}": m for m in ev["payload"]["markers"]}
    want = {k: v for k, v in d["markers"].items() if k.startswith("M")}
    out = []
    if set(got) != set(want):
        return [f"markers ids {sorted(got)} vs REAPER {sorted(want)}"]
    for k, m in want.items():
        e = got[k]
        if not close(e["position"], m["pos"], 1e-6) or e["name"] != m["name"] or e["color"] != m["color"]:
            out.append(f"marker {k} = {e}, REAPER {m}")
        elif e["positionBars"] != m["bars"]:
            out.append(f"marker {k} bars {e['positionBars']!r}, REAPER shows {m['bars']!r}")
    return out


def regions(d, c, tour):
    ev = c.latest_event("regions")
    if ev is None:
        return ["no regions event"]
    got = {f"R{r['id']}": r for r in ev["payload"]["regions"]}
    want = {k: v for k, v in d["markers"].items() if k.startswith("R")}
    out = []
    if set(got) != set(want):
        return [f"regions ids {sorted(got)} vs REAPER {sorted(want)}"]
    for k, r in want.items():
        e = got[k]
        if (not close(e["start"], r["pos"], 1e-6) or not close(e["end"], r["end"], 1e-6)
                or e["name"] != r["name"] or e["color"] != r["color"]):
            out.append(f"region {k} = {e}, REAPER {r}")
        elif (e["startBars"], e["endBars"]) != (r["bars"], r["end_bars"]):
            out.append(f"region {k} bars {e['startBars']}..{e['endBars']}, REAPER shows {r['bars']}..{r['end_bars']}")
    return out


def transport(d, c, tour):
    ev = c.latest_event("transport")
    if ev is None:
        return ["no transport event"]
    p = ev["payload"]
    pr = d["project"]
    out = []
    if p["playState"] != pr["play"]:
        out.append(f"transport.playState = {p['playState']}, REAPER {pr['play']}")
    if pr["play"] == 0 and not close(p["cursorPosition"], pr["cursor"], 2e-3):
        out.append(f"transport.cursorPosition = {p['cursorPosition']}, REAPER {pr['cursor']}")
    ts = p["timeSelection"]
    if not close(ts["start"], pr["timesel"][0], 1e-3) or not close(ts["end"], pr["timesel"][1], 1e-3):
        out.append(f"transport.timeSelection = {ts}, REAPER {pr['timesel']}")
    if pr["play"] == 0 and not close(p["bpm"], pr["bpm"], 0.01):
        out.append(f"transport.bpm = {p['bpm']}, REAPER {pr['bpm']}")
    if pr["play"] == 0 and [p["timeSignature"]["numerator"], p["timeSignature"]["denominator"]] != pr["timesig"]:
        out.append(f"transport.timeSignature = {p['timeSignature']}, REAPER {pr['timesig']}")
    return out


def project(d, c, tour):
    ev = c.latest_event("project")
    if ev is None:
        return ["no project event"]
    p = ev["payload"]
    pr, u = d["project"], d["undo"]
    out = []
    if p["repeat"] != bool(pr["repeat"]):
        out.append(f"project.repeat = {p['repeat']}, REAPER {pr['repeat']}")
    if p["metronome"]["enabled"] != bool(pr["metronome"] == 1):
        out.append(f"project.metronome.enabled = {p['metronome']['enabled']}, REAPER {pr['metronome']}")
    if (p["canUndo"] or "") != u["can_undo"]:
        out.append(f"project.canUndo = {p['canUndo']!r}, REAPER {u['can_undo']!r}")
    if (p["canRedo"] or "") != u["can_redo"]:
        out.append(f"project.canRedo = {p['canRedo']!r}, REAPER {u['can_redo']!r}")
    if p["master"]["stereoEnabled"] != (d["tracks"]["master"]["mono"] != 1):
        out.append(f"project.master.stereoEnabled = {p['master']['stereoEnabled']}, REAPER mono toggle {d['tracks']['master']['mono']}")
    if str(p["barOffset"]) != str(pr["start_measure"]):
        out.append(f"project.barOffset = {p['barOffset']}, REAPER start measure {pr['start_measure']}")
    return out


def tempo_map(d, c, tour):
    ev = c.latest_event("tempoMap")
    if ev is None:
        return ["no tempoMap event"]
    got = ev["payload"]["markers"]
    want = d["tempo"]
    if len(got) != len(want):
        return [f"tempoMap has {len(got)} markers, REAPER {len(want)}"]
    out = []
    for i, (e, w) in enumerate(zip(got, want)):
        if (not close(e["position"], w["pos"], 1e-6) or not close(e["bpm"], w["bpm"], 0.01)
                or e["timesigNum"] != w["num"] and w["num"] > 0 or e["linear"] != bool(w["linear"])):
            out.append(f"tempoMap[{i}] = {e}, REAPER {w}")
    return out


def decode_playlists(reamo):
    """REAmo's playlists as saved in the project's ExtState:
    [{"name", "stopAfterLast", "entries": [(regionId, loopCount)]}].
    Each value is `name|S:<0/1>|regionId,loopCount|...`, with `|` and `\\`
    in the name escaped by a backslash."""
    out = []
    reamo = {k.upper(): v for k, v in reamo.items()}  # REAPER upper-cases ExtState keys
    for i in range(int(reamo.get("PLAYLISTCOUNT") or 0)):
        raw = reamo.get(f"PLAYLIST_{i}")
        if raw is None:
            break
        fields, cur, esc = [], "", False
        for ch in raw:
            if esc:
                cur += ch
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == "|":
                fields.append(cur)
                cur = ""
            else:
                cur += ch
        fields.append(cur)
        p = {"name": fields[0], "stopAfterLast": True, "entries": []}
        for f in fields[1:]:
            if f.startswith("S:"):
                p["stopAfterLast"] = f[2:3] == "1"
            elif "," in f:
                r, n = f.split(",", 1)
                p["entries"].append((int(r), int(n)))
        out.append(p)
    return out


def playlists(d, c, tour):
    ev = c.latest_event("playlist")
    if ev is None:
        return ["no playlist event"]
    p = ev["payload"]
    want = decode_playlists(d["project"]["reamo"])
    got = [{"name": pl["name"], "stopAfterLast": pl["stopAfterLast"],
            "entries": [(e["regionId"], e["loopCount"]) for e in pl["entries"]]} for pl in p["playlists"]]
    out = []
    if got != want:
        out.append(f"playlists {got} vs saved in the project {want}")
    regions = {int(k[1:]) for k in d["markers"] if k.startswith("R")}
    for i, pl in enumerate(p["playlists"]):
        for j, e in enumerate(pl["entries"]):
            if bool(e.get("deleted")) != (e["regionId"] not in regions):
                out.append(f"playlist {i} entry {j}: deleted = {e.get('deleted')!r}, REAPER has regions {sorted(regions)}")
    if d["project"]["play"] == 0 and p["isPlaylistActive"]:
        out.append("playlist shown active while REAPER's transport is stopped")
    return out
