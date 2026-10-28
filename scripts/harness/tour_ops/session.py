"""Playlists, project notes, REAmo's project state, seek preferences, MIDI, audio streaming and diagnostics."""
import json
import time

from reamo_client import Client, reaper
from tour import ANY, Mismatch, Skip, approx, op
from tour_mirror import decode_playlists

MAX_PLAYLISTS = 16  # extension/src/state/playlist.zig
EXTSTATE_LIMIT = 16384  # bytes, extension/src/commands/extstate.zig


def str_hash(s):
    """digest.lua's str_hash: how the digest shows a long string."""
    b = s.encode("utf-8")
    h = 5381
    for byte in b:
        h = (h * 33 + byte) % 4294967296
    return f"{len(b)}:{h:08x}"


def lua_str(s):
    """A Lua string literal holding exactly `s` (any bytes, any length)."""
    return '"' + "".join(f"\\{b}" for b in s.encode("utf-8")) + '"'


# ----------------------------------------------------------------------------
# Playlists

def playlist_regions(t):
    """(id, start, end) of the regions a playlist is built from: the first two
    in the arrangement (intro, verse) and the shortest after the first
    (the chorus the band vamps on, so waiting for its end stays short)."""
    rg = sorted(((int(k[1:]), m["pos"], m["end"]) for k, m in t.d["markers"].items() if k.startswith("R")),
                key=lambda r: r[1])
    if len(rg) < 2:
        raise Skip("fewer than two regions to build a playlist from")
    return rg[0], rg[1], min(rg[1:], key=lambda r: r[2] - r[1])


def saved_playlists(t):
    return decode_playlists(t.d["project"]["reamo"])


def expect_saved(t, want, changes=None, allow=(), timeout=3.0):
    """Wait until the project's saved ExtState holds exactly the playlists
    `want` (list of {"name", "stopAfterLast", "entries": [(regionId, loopCount)]})
    and REAPER shows `changes` and nothing else."""
    deadline = time.time() + timeout
    before = t.flat
    while True:
        t.flat = before
        t.expect({**(changes or {}), "project.reamo.PLAYLIST*": ANY}, timeout=max(0.1, deadline - time.time()),
                 allow=allow)
        got = saved_playlists(t)
        stale = [k for k in t.d["project"]["reamo"]
                 if k.startswith("PLAYLIST_") and int(k[len("PLAYLIST_"):]) >= len(want)]
        if got == want and not stale:
            return
        if time.time() > deadline:
            raise Mismatch(f"the project's saved playlists are {got} (stale keys {stale}), the user built {want}")
        t.c.drain(0.15)


def playlist_event(t, pred, what, timeout=3.0, client=None, since=None):
    """The phone's latest playlist event, once `pred(payload)` holds.

    With `since` (an index into the client's events), any playlist event
    received from there on will do: a state that lasts less than the test
    takes to look, like one loop of a short region, was still shown."""
    c = client or t.c
    deadline = time.time() + timeout
    while True:
        ev = c.latest_event("playlist")
        if since is None:
            if ev is not None and pred(ev["payload"]):
                return ev["payload"]
        else:
            for name, msg in c.events[since:]:
                if name == "playlist" and pred(msg["payload"]):
                    return msg["payload"]
        if time.time() > deadline:
            trail = [(p["currentEntryIndex"], p["currentLoopIteration"], p["isPlaylistActive"])
                     for p in (msg["payload"] for name, msg in c.events[since or 0:] if name == "playlist")]
            raise Mismatch(f"playlist event never showed {what}; last: {ev and ev['payload']}; "
                           f"(entry, loop, active) received{' in this step' if since is not None else ''}: "
                           f"{trail[-12:]}")
        c.drain(0.1)


def at_entry(idx, entry):
    return lambda p: p["isPlaylistActive"] and p["activePlaylistIndex"] == idx and p["currentEntryIndex"] == entry


def wait_play_in(t, start, end, what, timeout=6.0):
    """REAPER's play position lands inside [start, end) (a seek during
    playback may wait for REAPER's smooth seek to reach a measure boundary)."""
    deadline = time.time() + timeout
    while True:
        pos = reaper("return reaper.GetPlayPosition()")
        if start - 0.05 <= pos < end + 0.05:
            return pos
        if time.time() > deadline:
            raise Mismatch(f"{what}: REAPER plays at {pos:.3f}, outside {start:.3f}..{end:.3f}")
        t.c.drain(0.1)


def loop_change(t, start, end):
    """REAPER's loop points set to [start, end]. The time selection follows
    them when the user has loop points linked to it (REAPER's default); the
    digest then shows the loop as "timesel"."""
    if reaper("return reaper.GetToggleCommandState(40621)") == 1:
        return {"project.timesel.0": approx(start), "project.timesel.1": approx(end), "project.loop": "timesel"}
    return {"project.loop.0": approx(start), "project.loop.1": approx(end), "project.loop": ANY}


def end_playlists(t, keep):
    """After a failure: stop playlist playback and delete the playlists the
    op created, as the user would, so later ops see the project's own."""
    try:
        t.send("playlist/stop")
        deadline = time.time() + 3.0
        while time.time() < deadline:
            t.c.drain(0.3)
            ev = t.c.latest_event("playlist")
            n = len(ev["payload"]["playlists"]) if ev else keep
            t.digest()
            if n <= keep and len(saved_playlists(t)) <= keep:
                return
            if n > keep:
                t.send("playlist/delete", playlistIdx=n - 1)
    except Exception as e:  # the op's own failure is the one to report
        print(f"      cleanup after the failure: {type(e).__name__}: {e}")


def cleanup_extstate(t, key, was_present):
    """Remove a REAmo ExtState key the op created where the project had none
    (playlist/delete leaves PlaylistCount at 0; no command removes a key)."""
    if not was_present:
        reaper(f'reaper.SetProjExtState(0, "Reamo", "{key}", "")')


@op("playlist: build a gig playlist, edit it, delete it",
    "playlist/create", "playlist/addEntry", "playlist/setLoopCount", "playlist/setStopAfterLast",
    "playlist/rename", "playlist/reorderEntry", "playlist/removeEntry", "playlist/delete")
def _(t):
    intro, verse, chorus = playlist_regions(t)
    had_count = "PLAYLISTCOUNT" in t.d["project"]["reamo"]
    lists = saved_playlists(t)
    if len(lists) >= MAX_PLAYLISTS:
        raise Skip("the project has the maximum number of playlists")
    keep = len(lists)
    try:
        _build_playlist(t, lists, intro, verse, chorus)
    except BaseException:
        end_playlists(t, keep)
        raise
    finally:
        cleanup_extstate(t, "PlaylistCount", had_count)
        t.digest()


def _build_playlist(t, lists, intro, verse, chorus):
    idx = len(lists)
    r = t.ok("playlist/create", name="Friday gig")
    if r is not None and r["payload"]["playlistIdx"] != idx:
        raise Mismatch(f"playlist/create returned {r['payload']}, the project had {idx} playlists")
    gig = {"name": "Friday gig", "stopAfterLast": True, "entries": []}
    lists.append(gig)
    expect_saved(t, lists)

    # The UI adds a region once, then the user sets its count (0 is Skip).
    for rid, count in [(intro[0], 2), (verse[0], 1), (chorus[0], 1), (verse[0], 0), (chorus[0], 1)]:
        entry = len(gig["entries"])
        r = t.ok("playlist/addEntry", playlistIdx=idx, regionId=rid, loopCount=1)
        if r is not None and r["payload"]["entryIdx"] != entry:
            raise Mismatch(f"playlist/addEntry returned {r['payload']}, expected entry {entry}")
        gig["entries"].append((rid, 1))
        expect_saved(t, lists)
        if count != 1:
            t.ok("playlist/setLoopCount", playlistIdx=idx, entryIdx=entry, loopCount=count)
            gig["entries"][entry] = (rid, count)
            expect_saved(t, lists)

    # A phone that connects now loads the same playlist.
    with Client() as phone2:
        ev = phone2.wait_event("playlist")["payload"]
        got = [(e["regionId"], e["loopCount"]) for e in ev["playlists"][idx]["entries"]]
        if ev["playlists"][idx]["name"] != gig["name"] or got != gig["entries"]:
            raise Mismatch(f"a newly connected phone shows {ev['playlists'][idx]}, the playlist is {gig}")

    t.ok("playlist/setStopAfterLast", playlistIdx=idx, stopAfterLast=0)
    gig["stopAfterLast"] = False
    expect_saved(t, lists)
    t.ok("playlist/setStopAfterLast", playlistIdx=idx, stopAfterLast=1)
    gig["stopAfterLast"] = True
    expect_saved(t, lists)

    # A name with the characters the saved format escapes.
    name = "Friday | Acoustic \\ Ünïcødé 🎸"
    t.ok("playlist/rename", playlistIdx=idx, name=name)
    gig["name"] = name
    expect_saved(t, lists)

    # Drag the first Chorus above the Verse.
    t.ok("playlist/reorderEntry", playlistIdx=idx, fromIdx=2, toIdx=1)
    gig["entries"].insert(1, gig["entries"].pop(2))
    expect_saved(t, lists)

    # Drop the skipped Verse.
    t.ok("playlist/removeEntry", playlistIdx=idx, entryIdx=3)
    del gig["entries"][3]
    expect_saved(t, lists)

    t.ok("playlist/delete", playlistIdx=idx)
    lists.pop()
    expect_saved(t, lists)


@op("playlist: play a playlist with next, prev, loop counts, pause and stop",
    "playlist/play", "playlist/playFromEntry", "playlist/pause", "playlist/stop",
    "playlist/next", "playlist/prev", "playlist/advanceAfterLoop")
def _(t):
    intro, verse, chorus = playlist_regions(t)
    had_count = "PLAYLISTCOUNT" in t.d["project"]["reamo"]
    lists = saved_playlists(t)
    if len(lists) >= MAX_PLAYLISTS:
        raise Skip("the project has the maximum number of playlists")
    # A pickup: a region half a bar long, two bars after the last region.
    pickup_id, ps, pe = reaper("""
        local last = 0
        local i = 0
        while true do
          local ok, isrgn, pos, rend = reaper.EnumProjectMarkers3(0, i)
          if ok == 0 then break end
          if isrgn and rend > last then last = rend end
          i = i + 1
        end
        local _, meas = reaper.TimeMap2_timeToBeats(0, last)
        local s = reaper.TimeMap2_beatsToTime(0, 0, meas + 2)
        local e = reaper.TimeMap2_beatsToTime(0, 2, meas + 2)
        local id = reaper.AddProjectMarker2(0, true, s, e, "Pickup", -1, 0)
        return id, s, e
    """)
    t.digest()
    keep = len(lists)
    try:
        _play_playlist(t, lists, (pickup_id, ps, pe), intro, verse, chorus)
    except BaseException:
        end_playlists(t, keep)
        raise
    finally:
        reaper(f"reaper.DeleteProjectMarker(0, {pickup_id}, true)")
        cleanup_extstate(t, "PlaylistCount", had_count)
        t.digest()


def _play_playlist(t, lists, pickup, intro, verse, chorus):
    idx = len(lists)
    t.ok("playlist/create", name="Rehearsal")
    plan = [(intro, 2), (verse, 1), (verse, 0), (pickup, 2), (chorus, -1)]
    for entry, (rg, count) in enumerate(plan):
        t.ok("playlist/addEntry", playlistIdx=idx, regionId=rg[0], loopCount=1)
        if count != 1:
            t.ok("playlist/setLoopCount", playlistIdx=idx, entryIdx=entry, loopCount=count)
    lists.append({"name": "Rehearsal", "stopAfterLast": True, "entries": [(rg[0], n) for rg, n in plan]})
    expect_saved(t, lists)

    def looping(rg):
        return {"project.play": 1, "project.repeat": 1, "project.cursor": ANY, **t.meter(), **loop_change(t, rg[1], rg[2])}

    ended = {"project.play": 0, "project.repeat": 0, "project.cursor": ANY, **t.meter(), **loop_change(t, 0, 0)}

    # Play: the first entry loops natively in REAPER.
    t.ok("playlist/play", playlistIdx=idx)
    t.expect(looping(intro))
    p = playlist_event(t, at_entry(idx, 0), "entry 0 playing")
    if (p["loopsRemaining"], p["currentLoopIteration"]) != (2, 1):
        raise Mismatch(f"Intro x2 started with {p}")
    wait_play_in(t, intro[1], intro[2], "playlist/play")

    t.ok("playlist/next")
    t.expect(looping(verse))
    playlist_event(t, at_entry(idx, 1), "next: entry 1")
    wait_play_in(t, verse[1], verse[2], "playlist/next to the Verse")

    # The skipped Verse is passed over both ways.
    t.ok("playlist/next")
    t.expect(looping(pickup))
    playlist_event(t, at_entry(idx, 3), "next past the skipped entry: entry 3")
    t.ok("playlist/prev")
    t.expect(looping(verse))
    playlist_event(t, at_entry(idx, 1), "prev past the skipped entry: entry 1")

    # The pickup, shorter than a bar, plays twice and then moves on. Each
    # loop lasts about a second, so its events are looked for among all
    # received since the step began, not only the latest.
    mark = len(t.c.events)
    t.ok("playlist/next")
    t.expect(looping(pickup))
    playlist_event(t, at_entry(idx, 3), "next: entry 3", since=mark)
    playlist_event(t, lambda p: at_entry(idx, 3)(p) and p["currentLoopIteration"] == 2,
                   "the pickup's second loop", timeout=6.0, since=mark)
    playlist_event(t, at_entry(idx, 4), "the Chorus after the pickup's two loops", timeout=8.0)
    t.expect(looping(chorus), timeout=4.0)
    wait_play_in(t, chorus[1], chorus[2], "after the pickup")

    # The Chorus vamps until the band leader cues the end; the playlist then stops.
    t.ok("playlist/advanceAfterLoop")
    playlist_event(t, lambda p: p["advanceAfterLoop"], "advanceAfterLoop")
    t.expect(ended, timeout=chorus[2] - chorus[1] + 4.0)
    playlist_event(t, lambda p: not p["isPlaylistActive"], "the playlist ended")

    # Pause and resume from an entry.
    t.ok("playlist/playFromEntry", playlistIdx=idx, entryIdx=1)
    t.expect(looping(verse))
    playlist_event(t, at_entry(idx, 1), "playFromEntry 1")
    t.ok("playlist/pause")
    t.expect({"project.play": 2, "project.cursor": ANY, **t.meter()})
    playlist_event(t, lambda p: p["isPaused"] and p["currentEntryIndex"] == 1, "paused on entry 1")
    t.ok("playlist/play", playlistIdx=idx)
    t.expect({"project.play": 1, "project.cursor": ANY, **t.meter()})
    playlist_event(t, lambda p: at_entry(idx, 1)(p) and not p["isPaused"], "resumed on entry 1")
    t.ok("playlist/stop")
    t.expect(ended)
    playlist_event(t, lambda p: not p["isPlaylistActive"], "stopped")

    # Deleting the playing playlist ends its playback.
    last = len(lists[-1]["entries"]) - 1
    t.ok("playlist/playFromEntry", playlistIdx=idx, entryIdx=last)
    t.expect(looping(chorus))
    playlist_event(t, at_entry(idx, last), "playFromEntry of the last entry")
    t.ok("playlist/delete", playlistIdx=idx)
    lists.pop()
    expect_saved(t, lists, ended)
    playlist_event(t, lambda p: not p["isPlaylistActive"], "the deleted playlist stopped")


@op("playlist: drop the playing song; playback moves on past a skipped entry", "playlist/removeEntry")
def _(t):
    intro, verse, chorus = playlist_regions(t)
    if len({intro, verse, chorus}) < 3:
        raise Skip("needs three regions")
    had_count = "PLAYLISTCOUNT" in t.d["project"]["reamo"]
    lists = saved_playlists(t)
    if len(lists) >= MAX_PLAYLISTS:
        raise Skip("the project has the maximum number of playlists")
    keep = len(lists)
    try:
        _drop_playing(t, lists, intro, verse, chorus)
    except BaseException:
        end_playlists(t, keep)
        raise
    finally:
        cleanup_extstate(t, "PlaylistCount", had_count)
        t.digest()


def _drop_playing(t, lists, intro, verse, chorus):
    idx = len(lists)
    t.ok("playlist/create", name="Encore")
    plan = [(intro, 1), (verse, 1), (intro, 0), (chorus, 1)]
    for entry, (rg, count) in enumerate(plan):
        t.ok("playlist/addEntry", playlistIdx=idx, regionId=rg[0], loopCount=1)
        if count != 1:
            t.ok("playlist/setLoopCount", playlistIdx=idx, entryIdx=entry, loopCount=count)
    lists.append({"name": "Encore", "stopAfterLast": True, "entries": [(rg[0], n) for rg, n in plan]})
    expect_saved(t, lists)

    t.ok("playlist/playFromEntry", playlistIdx=idx, entryIdx=1)
    t.expect({"project.play": 1, "project.repeat": 1, "project.cursor": ANY, **t.meter(),
              **loop_change(t, verse[1], verse[2])})
    playlist_event(t, at_entry(idx, 1), "playFromEntry 1")
    # The skipped Intro moves up into the removed Verse's place; the Chorus plays.
    t.ok("playlist/removeEntry", playlistIdx=idx, entryIdx=1)
    del lists[-1]["entries"][1]
    p = playlist_event(t, at_entry(idx, 2), "the Chorus (entry 2) playing after removing the playing Verse")
    if p["loopsRemaining"] != 1:
        raise Mismatch(f"the Chorus x1 plays with {p}")
    expect_saved(t, lists, {"project.cursor": ANY, **t.meter(), **loop_change(t, chorus[1], chorus[2])})
    wait_play_in(t, chorus[1], chorus[2], "after removing the playing entry")

    t.ok("playlist/stop")
    t.ok("playlist/delete", playlistIdx=idx)
    lists.pop()
    expect_saved(t, lists, {"project.play": 0, "project.repeat": 0, "project.cursor": ANY, **t.meter(),
                            **loop_change(t, 0, 0)})


# ----------------------------------------------------------------------------
# Project notes

def rpp_notes(path):
    """The project notes in a saved .RPP, line by line as REAPER wrote them:
    each line of the <NOTES chunk is `|` followed by the user's text."""
    with open(path, encoding="utf-8", newline="") as f:
        lines = f.read().replace("\r\n", "\n").split("\n")
    start = next((i for i, ln in enumerate(lines) if ln.strip().startswith("<NOTES")), None)
    if start is None:
        return None
    out = []
    for ln in lines[start + 1:]:
        s = ln.strip()
        if s == ">":
            return out
        if not s.startswith("|"):
            raise Mismatch(f"project notes saved as a line REAPER cannot read back: {ln!r}")
        out.append(s[1:])
    raise Mismatch("the saved project's <NOTES chunk is not closed")


@op("projectNotes: edit on one phone, another sees it, saved exactly",
    "projectNotes/subscribe", "projectNotes/unsubscribe", "projectNotes/get", "projectNotes/set")
def _(t):
    original = reaper('return reaper.GetSetProjectNotes(0, false, "")')
    for c in (t.c, t.watcher):  # both phones open the Notes view
        r = t.send("projectNotes/subscribe", awaited=True, client=c)
        if not r["success"] or r["payload"]["notes"] != original:
            raise Mismatch(f"projectNotes/subscribe: {r}, REAPER has {original!r}")
    old_hash = r["payload"]["hash"]

    # Lines that look like RPP chunk syntax must stay text.
    lines = ["Friday setlist", "| capo 2 for the bridge", "<intro> count in from the hi-hat",
             "> drop the second chorus", ">", "<", "|", "  indented: Ünïcødé 🎸", "", "end"]
    typed = "\n".join(lines)
    r = t.send("projectNotes/set", awaited=True, notes=typed)
    if not r["success"]:
        raise Mismatch(f"projectNotes/set: {r}")
    t.expect({"project.notes": ANY})
    now = reaper('return reaper.GetSetProjectNotes(0, false, "")')
    if now.replace("\r\n", "\n").split("\n") != lines:
        raise Mismatch(f"REAPER's notes are {now!r}, the user typed {typed!r}")
    if t.d["project"]["notes"] != str_hash(now) or r["payload"]["notes"] != now:
        raise Mismatch(f"projectNotes/set answered {r['payload']!r}, REAPER has {now!r}")
    new_hash = r["payload"]["hash"]
    if new_hash == old_hash:
        raise Mismatch("projectNotes/set returned the old hash")

    # The other phone hears of the change and fetches the new text.
    deadline = time.time() + 4.0
    while True:
        evs = [m for n, m in t.watcher.events if n == "projectNotesChanged"]
        if evs and evs[-1]["payload"]["hash"] == new_hash:
            break
        if time.time() > deadline:
            raise Mismatch(f"the second phone got no projectNotesChanged with hash {new_hash}: {evs[-3:]}")
        t.watcher.drain(0.2)
    r = t.send("projectNotes/get", awaited=True, client=t.watcher)
    if r["payload"] != {"notes": now, "hash": new_hash}:
        raise Mismatch(f"projectNotes/get on the second phone: {r['payload']}, REAPER has {now!r}")

    # Saved: REAPER writes every line back as the user typed it.
    path = reaper("return select(2, reaper.EnumProjects(-1))")
    if path:
        reaper("reaper.Main_SaveProject(0, false)", timeout=10)
        saved = rpp_notes(path)
        if saved != lines:
            raise Mismatch(f"the saved project's notes are {saved}, the user typed {lines}")

    for c in (t.c, t.watcher):
        t.ok("projectNotes/unsubscribe", client=c)
    t.watcher.drain(0.3)
    seen = len(t.watcher.events)
    reaper(f"reaper.GetSetProjectNotes(0, true, {lua_str(original)})")
    t.expect({"project.notes": str_hash(original)})
    t.watcher.drain(1.5)
    late = [m for n, m in t.watcher.events[seen:] if n == "projectNotesChanged"]
    if late:
        raise Mismatch(f"an unsubscribed phone still got {late}")


# ----------------------------------------------------------------------------
# Custom banks (REAmo's project state)

@op("extstate: custom banks round-trip exactly, an over-limit save is refused",
    "extstate/projGet", "extstate/projSet")
def _(t):
    def get():
        r = t.send("extstate/projGet", awaited=True, extname="Reamo", key="CustomBanks")
        if not r["success"]:
            raise Mismatch(f"extstate/projGet: {r}")
        return r["payload"]["value"]

    def in_reaper():
        ok, val = reaper('return reaper.GetProjExtState(0, "Reamo", "CustomBanks")')
        return val if ok else None

    original = in_reaper()
    if get() != original:
        raise Mismatch(f"extstate/projGet does not show REAPER's value {original!r}")
    drums = [g for g, tr in t.tracks() if tr["name"] in ("Drums", "Kick", "Snare", "Overheads")]
    banks = [
        {"id": "5f0c3c1e-8d7a-4a39-9a51-2f6d1b7e0c11", "name": "Drums", "type": "custom", "trackGuids": drums},
        {"id": "a3e1b2c4-0f9e-4d8c-b7a6-112233445566", "name": "Vocals \"lead\" & BVs — Ünïcødé 🎤",
         "type": "smart", "pattern": "vox", "trackGuids": []},
        {"id": "0b9d8e7f-6a5b-4c3d-2e1f-0a9b8c7d6e5f", "name": "Stems\\print\\2026", "type": "custom",
         "trackGuids": [g for g, _ in t.tracks()]},
    ]
    value = json.dumps(banks, ensure_ascii=False, separators=(",", ":"))  # as JSON.stringify
    t.send("extstate/projSet", awaited=True, extname="Reamo", key="CustomBanks", value=value)
    t.expect({"project.reamo.CUSTOMBANKS": str_hash(value)})
    if in_reaper() != value or get() != value:
        raise Mismatch(f"custom banks did not round-trip: REAPER {in_reaper()!r}, sent {value!r}")

    # The largest value allowed, ending in multi-byte characters.
    def padded(n):
        return json.dumps([{"x": "a" * n, "name": "🎛️ é"}], ensure_ascii=False, separators=(",", ":"))
    n = EXTSTATE_LIMIT - len(padded(0).encode())
    big, over = padded(n), padded(n + 1)
    r = t.send("extstate/projSet", awaited=True, extname="Reamo", key="CustomBanks", value=big)
    if not r["success"]:
        raise Mismatch(f"a {EXTSTATE_LIMIT}-byte value was refused: {r}")
    t.expect({"project.reamo.CUSTOMBANKS": str_hash(big)})
    if in_reaper() != big or get() != big:
        raise Mismatch("a value at the size limit was not stored exactly")

    # One byte over: refused, and what was saved stays whole.
    r = t.send("extstate/projSet", awaited=True, extname="Reamo", key="CustomBanks", value=over)
    if r["success"]:
        raise Mismatch(f"a {len(over.encode())}-byte value was accepted")
    t.expect({})
    if in_reaper() != big:
        raise Mismatch("a refused save changed the stored banks")

    reaper(f'reaper.SetProjExtState(0, "Reamo", "CustomBanks", {lua_str(original or "")})')
    t.expect({"project.reamo.CUSTOMBANKS": str_hash(original)} if original is not None else {},
             allow=() if original is not None else ("project.reamo.CUSTOMBANKS",))
    if in_reaper() != original:
        raise Mismatch("could not restore the project's custom banks")


# ----------------------------------------------------------------------------
# Seek preferences

@op("preferences: seek settings round-trip", "preferences/getSeekSettings", "preferences/setSeekSettings")
def _(t):
    t.need("project.seek.0", "project.seek.1")

    def cfg():
        ss, meas = t.d["project"]["seek"]
        return int(ss), int(meas)

    def get():
        r = t.send("preferences/getSeekSettings", awaited=True)
        if not r["success"]:
            raise Mismatch(f"getSeekSettings: {r}")
        return r["payload"]

    def shown(ss, meas):
        return {"enabled": bool(ss & 1), "measures": meas, "mode": "marker" if ss & 2 else "measures"}

    ss, meas = cfg()
    if get() != shown(ss, meas):
        raise Mismatch(f"getSeekSettings {get()}, REAPER smoothseek={ss} smoothseekmeas={meas}")
    want_ss = (ss & ~3) | (0 if ss & 1 else 1) | (0 if ss & 2 else 2)
    want_meas = 4 if meas != 4 else 2
    t.ok("preferences/setSeekSettings", enabled=want_ss & 1, measures=want_meas, mode=(want_ss >> 1) & 1)
    t.expect({"project.seek.0": str(want_ss), "project.seek.1": str(want_meas)})
    if get() != shown(want_ss, want_meas):
        raise Mismatch(f"getSeekSettings {get()} after setting smoothseek={want_ss} measures={want_meas}")
    # Out of range: refused, nothing written.
    r = t.send("preferences/setSeekSettings", awaited=True, measures=9)
    if r["success"]:
        raise Mismatch("setSeekSettings accepted measures=9")
    t.expect({})
    # Restore the user's own settings.
    t.ok("preferences/setSeekSettings", enabled=ss & 1, measures=meas, mode=(ss >> 1) & 1)
    t.expect({"project.seek.0": str(ss), "project.seek.1": str(meas)})


# ----------------------------------------------------------------------------
# MIDI pads

PROBE_JSFX = r"""desc:REAmo harness MIDI probe
slider1:0<0,100000,1>notes on
slider2:0<0,100000,1>notes off
slider3:0<0,100000,1>CC
slider4:0<0,100000,1>program changes
slider5:0<0,100000,1>pitch bends
slider6:0<0,16777215,1>last message
@block
while (midirecv(ofs, m1, m2, m3)) (
  s = m1 & 0xF0;
  s == 0x90 && m3 > 0 ? slider1 += 1 : (s == 0x80 || s == 0x90) ? slider2 += 1 :
  s == 0xB0 ? slider3 += 1 : s == 0xC0 ? slider4 += 1 : s == 0xE0 ? slider5 += 1;
  slider6 = m1 * 65536 + m2 * 256 + m3;
  midisend(ofs, m1, m2, m3);
);
"""


@op("midi: pad notes, CC, program change and pitch bend reach an armed MIDI track",
    "midi/noteOn", "midi/cc", "midi/pc", "midi/pitchBend")
def _(t):
    # The user's pads track: armed, monitoring, input "All MIDI inputs". A
    # JSFX on it counts what REAPER delivers, so REAPER is the oracle.
    probe = reaper(f"""
        local dir = reaper.GetResourcePath() .. "/Effects/reamo_harness"
        reaper.RecursiveCreateDirectory(dir, 0)
        local f = assert(io.open(dir .. "/midi_probe", "w"))
        f:write({lua_str(PROBE_JSFX)})
        f:close()
        local n = reaper.CountTracks(0)
        reaper.InsertTrackAtIndex(n, true)
        local tr = reaper.GetTrack(0, n)
        reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Pads", true)
        reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", 4096 | (63 << 5))
        reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)
        reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
        local fx = reaper.TrackFX_AddByName(tr, "JS:reamo_harness/midi_probe", false, -1)
        if fx < 0 then error("could not load the MIDI probe JSFX") end
        return reaper.GetTrackGUID(tr)
    """)
    try:
        t.digest()
        _midi(t, probe)
    finally:
        reaper(f"""
            for i = 0, reaper.CountTracks(0) - 1 do
              local tr = reaper.GetTrack(0, i)
              if reaper.GetTrackGUID(tr) == "{probe}" then reaper.DeleteTrack(tr) break end
            end
        """)
        t.digest()


def _midi(t, probe):
    def counts():
        return reaper(f"""
            for i = 0, reaper.CountTracks(0) - 1 do
              local tr = reaper.GetTrack(0, i)
              if reaper.GetTrackGUID(tr) == "{probe}" then
                local out = {{}}
                for p = 0, 5 do out[#out + 1] = math.floor(reaper.TrackFX_GetParam(tr, 0, p) + 0.5) end
                return out
              end
            end
        """)

    def wait_counts(want, what, timeout=3.0):
        deadline = time.time() + timeout
        while True:
            got = counts()
            if got[:5] == want[:5] and (len(want) < 6 or got[5] == want[5]):
                return got
            if time.time() > deadline:
                raise Mismatch(f"{what}: REAPER's MIDI input saw {got} (on, off, cc, pc, bend, last), expected {want}")
            t.c.drain(0.1)

    base = counts()
    on, off, cc, pc, pb = base[:5]
    # Drum pad on channel 10: kick, velocity 100, then release.
    t.ok("midi/noteOn", note=36, velocity=100, channel=9)
    on += 1
    wait_counts([on, off, cc, pc, pb, 0x99 * 65536 + 36 * 256 + 100], "noteOn")
    t.ok("midi/noteOn", note=36, velocity=0, channel=9)
    off += 1
    wait_counts([on, off, cc, pc, pb, 0x99 * 65536 + 36 * 256], "note release")
    t.ok("midi/cc", cc=1, value=64, channel=0)  # mod wheel
    cc += 1
    wait_counts([on, off, cc, pc, pb, 0xB0 * 65536 + 1 * 256 + 64], "midi/cc")
    t.ok("midi/pc", program=5, channel=0)
    pc += 1
    wait_counts([on, off, cc, pc, pb, 0xC0 * 65536 + 5 * 256], "midi/pc")
    t.ok("midi/pitchBend", value=12000, channel=0)
    pb += 1
    wait_counts([on, off, cc, pc, pb, 0xE0 * 65536 + (12000 & 0x7F) * 256 + (12000 >> 7)], "midi/pitchBend")
    t.ok("midi/pitchBend", value=8192, channel=0)  # spring back to centre
    pb += 1
    wait_counts([on, off, cc, pc, pb, 0xE0 * 65536 + 64], "pitch bend centre")

    # Out-of-range values are refused, not wrapped into another message.
    for cmd, params in [("midi/noteOn", {"note": 128, "velocity": 100}), ("midi/cc", {"cc": 1, "value": 200}),
                        ("midi/pitchBend", {"value": 16384}), ("midi/pc", {"program": 5, "channel": 16})]:
        r = t.send(cmd, awaited=True, **params)
        if r["success"]:
            raise Mismatch(f"{cmd} {params} accepted")

    # A fast finger-drum roll: 200 hits, 100 a second; every one arrives.
    for i in range(200):
        t.c.fire("midi/noteOn", note=38 + i % 4, velocity=90, channel=9)
        t.c.fire("midi/noteOn", note=38 + i % 4, velocity=0, channel=9)
        time.sleep(0.01)
    on, off = on + 200, off + 200
    wait_counts([on, off, cc, pc, pb], "200 pad hits", timeout=5.0)
    # Only the probe's own counters moved.
    t.expect({f"tracks.{probe}.fx.*.params.*": ANY})


# ----------------------------------------------------------------------------
# Audio monitoring

@op("audio: stream to one phone while playing, status before, during and after",
    "audio/startStream", "audio/stopStream", "audio/status")
def _(t):
    def status(client=None):
        r = t.send("audio/status", awaited=True, client=client)
        if not r["success"]:
            raise Mismatch(f"audio/status: {r}")
        return r["payload"]

    def audio_frames(c):
        return [f for f in c.binary if f[:1] == b"\x01"]

    s = status()
    if s["clientCount"] != 0 or s["hookRegistered"]:
        raise Mismatch(f"audio/status before anyone streams: {s}")

    srate = int(reaper('return select(2, reaper.GetAudioDeviceInfo("SRATE", ""))') or 0)
    r = t.send("audio/startStream", awaited=True)
    if not r["success"] or (srate and r["payload"]["sampleRate"] != srate):
        raise Mismatch(f"audio/startStream: {r}; REAPER's device runs at {srate} Hz")
    rate = r["payload"]["sampleRate"]
    s = status()
    if s["clientCount"] != 1 or not s["hookRegistered"] or not s["hasThread"]:
        raise Mismatch(f"audio/status while streaming: {s}")

    t.ok("transport/seek", position=0)
    t.ok("transport/play")
    t.expect({"project.play": 1, "project.cursor": ANY, **t.meter()})
    t.c.binary.clear()
    t.watcher.binary.clear()
    # REAPER's master meter is the oracle for what the phone should hear.
    t0 = time.time()
    peaks = []
    for _ in range(6):
        t.c.drain(0.25)
        peaks.append(reaper("local m = reaper.GetMasterTrack(0) "
                            "return math.max(reaper.Track_GetPeakInfo(m, 0), reaper.Track_GetPeakInfo(m, 1))"))
    elapsed = time.time() - t0
    frames = audio_frames(t.c)
    if max(peaks) < 1e-4:
        # Silence is not streamed (the phone's jitter buffer covers the gap).
        if frames:
            raise Mismatch(f"{len(frames)} audio frames while REAPER's master is silent")
    elif not frames:
        raise Mismatch(f"no audio frames while REAPER's master peaked at {max(peaks):.3f}; status {status()}")
    seqs = [int.from_bytes(f[1:5], "little") for f in frames]
    if any(b <= a for a, b in zip(seqs, seqs[1:])):
        raise Mismatch(f"audio frame sequence numbers not increasing: {seqs[:20]}")
    if any((len(f) - 5) % 4 for f in frames):
        raise Mismatch("an audio frame is not whole stereo 16-bit samples")
    secs = sum(len(f) - 5 for f in frames) / 4 / rate
    if min(peaks) >= 1e-4 and not 0.3 * elapsed < secs < 1.5 * elapsed:
        raise Mismatch(f"{secs:.2f} s of audio arrived in {elapsed:.2f} s of audible playback")
    if frames and not any(any(f[i:i + 2] != b"\x00\x00" for i in range(5, len(f), 2)) for f in frames):
        raise Mismatch("every streamed audio frame is silent")
    if audio_frames(t.watcher):
        raise Mismatch("a phone that did not ask for audio received audio frames")

    t.ok("audio/stopStream")
    s = status()
    if s["clientCount"] != 0 or s["hookRegistered"]:
        raise Mismatch(f"audio/status after stopStream: {s}")
    t.c.drain(0.3)
    t.c.binary.clear()
    t.c.drain(1.0)
    if audio_frames(t.c):
        raise Mismatch(f"{len(audio_frames(t.c))} audio frames after stopStream")

    # A phone that streams and then drops off the network releases the stream.
    with Client() as phone2:
        phone2.wait_event("trackSkeleton")
        r = phone2.command("audio/startStream")
        if not r["success"]:
            raise Mismatch(f"audio/startStream on a second phone: {r}")
    deadline = time.time() + 3.0
    while status()["clientCount"] != 0:
        if time.time() > deadline:
            raise Mismatch(f"a disconnected phone still holds the audio stream: {status()}")
        t.c.drain(0.2)

    t.ok("transport/stop")
    t.expect({"project.play": 0, "project.cursor": ANY, **t.meter()})


# ----------------------------------------------------------------------------
# Diagnostics

@op("debug/memoryStats", "debug/memoryStats")
def _(t):
    # The memory-warning bar's info button.
    r = t.send("debug/memoryStats", awaited=True)
    if not r["success"]:
        raise Mismatch(f"debug/memoryStats: {r}")
    p = r["payload"]
    for tier in ("high", "medium", "low"):
        u = p[tier]
        if not 0 <= u["used"] <= u["peak"] <= u["capacity"] or u["capacity"] <= 0:
            raise Mismatch(f"debug/memoryStats {tier}: {u}")
    if p["total"]["allocated"] <= 0:
        raise Mismatch(f"debug/memoryStats total: {p['total']}")
    t.expect({})
