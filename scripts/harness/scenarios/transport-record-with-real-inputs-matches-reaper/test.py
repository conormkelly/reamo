"""Recording from the phone, with real inputs, leaves the project as REAPER's own
record actions do, and stopAndDelete leaves nothing behind.

REAPER runs on JACK with 2 inputs, each fed a tone. Two tracks are armed on
them, one of them in fixed lanes; a third, unarmed, has an item under where
the takes land (startup.lua). The same steps run twice from the same saved
project: once with REAPER's own actions run from a script (the control),
once with the phone's commands.

1. Record about 1.5 s from 0 s (Transport: Record / transport/record), then
   stop (Transport: Stop / transport/stop).
2. Undo it (Undo_DoUndo2 / undo/do).
3. Record about 1 s, then Transport: Stop (DELETE all recorded media) /
   transport/stopAndDelete.

What each leaves is compared between the two: new items (track, lane,
position, selection, source, whether coloured), every change to existing
items and tracks (a colour REAPER gives existing items counts as "the new
take's colour"), the undo history's top and the project's dirty flag, and
how many files appear in the record path. Neither may differ.

The phone's run must also, on its own:
- after 1: a take on each armed track at 0 s, about 1.5 s long, holding the
  fed tone (so the inputs really reached it), and nothing on "Keys";
- after 2: the project exactly as before recording;
- after 3: the project exactly as before recording, the same undo top and
  dirty flag, no new file in the record path, and the phone's items event
  showing REAPER's item count.
"""
import os
import time

from reamo_client import Client, open_project, reaper, skip_unless_linux

skip_unless_linux("REAPER's inputs come from the container's JACK server")

from jack_feeder import Feeder  # noqa: E402  after the skip: Linux only
from tour import diff, flatten  # noqa: E402

N = 2
assert int(os.environ.get("HARNESS_JACK_INPUTS", "0")) == N, "boot.sh did not start JACK with jack-inputs"
PROJECT = "/tmp/rec-session/rec.RPP"
ARMED = {"Guitar", "Vox lanes"}
LEVEL = 0.5
# Keys that move with the transport, not with the edit.
MOVING = ("project.cursor", "project.play")

FILES = """local dir, out, i = "/tmp/rec", {}, 0
while reaper.EnumerateFiles(dir, i) do out[#out + 1] = reaper.EnumerateFiles(dir, i); i = i + 1 end
return out"""

# The loudest sample of each item's active take between 0.3 s and 1.0 s.
PEAKS = """local out = {}
for i = 0, reaper.CountMediaItems(0) - 1 do
  local it = reaper.GetMediaItem(0, i)
  local tk = reaper.GetActiveTake(it)
  local g = select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false))
  local acc = reaper.CreateTakeAudioAccessor(tk)
  local n = 33600
  local buf = reaper.new_array(n)
  reaper.GetAudioAccessorSamples(acc, 48000, 1, 0.3, n, buf)
  reaper.DestroyAudioAccessor(acc)
  local peak = 0
  for k = 1, n do peak = math.max(peak, math.abs(buf[k])) end
  out[g] = peak
end
return out"""


def digest():
    d = reaper("return dofile('/harness/digest.lua').digest()", timeout=10)
    d["items"] = d["items"] or {}
    return d


def wait_play_state(want, timeout=3.0):
    deadline = time.time() + timeout
    while reaper("return reaper.GetPlayState()") != want:
        if time.time() > deadline:
            raise AssertionError(f"REAPER's play state stayed {reaper('return reaper.GetPlayState()')}, not {want}")
        time.sleep(0.05)


def name_of(d, track_guid):
    return d["tracks"][track_guid]["name"]


def changes(before, after):
    """What an action did, in terms that don't depend on the run: GUIDs,
    file names, exact lengths and REAPER's random colours left out."""
    fb, fa = flatten(before), flatten(after)
    delta = {k: v for k, v in diff(fb, fa).items() if k not in MOVING}
    new = sorted(g for g in after["items"] if g not in before["items"])
    gone = sorted(g for g in before["items"] if g not in after["items"])
    new_items = []
    for g in new:
        it = after["items"][g]
        new_items.append({
            "track": name_of(after, it["track"]), "lane": it["lane"], "idx": it["idx"],
            "pos~0": abs(it["pos"]) < 0.05, "sel": it["sel"], "mute": it["mute"],
            "coloured": it["color"] != 0, "takes": [(tk.get("src"), tk.get("midi")) for tk in it["takes"]],
        })
    new_items.sort(key=lambda x: (x["track"], x["lane"]))
    take_colour = {(after["items"][g]["track"], after["items"][g]["lane"]): after["items"][g]["color"] for g in new}
    edits = []
    for k, (old, now) in sorted(delta.items()):
        parts = k.split(".")
        if parts[0] == "items" and (parts[1] in new or parts[1] in gone):
            continue
        where = k
        if parts[0] == "items":
            it = before["items"][parts[1]]
            where = f"item on {name_of(before, it['track'])} lane {it['lane']} at {it['pos']}: {'.'.join(parts[2:])}"
            if parts[2] == "color" and take_colour.get((it["track"], after["items"][parts[1]]["lane"])) == now:
                now = "the new take's colour"
        elif parts[0] == "tracks" and parts[1] in before["tracks"]:
            where = f"track {name_of(before, parts[1])}: {'.'.join(parts[2:])}"
        edits.append((where, old, now))
    return {"new": new_items, "removed": sorted(name_of(before, before["items"][g]["track"]) for g in gone),
            "edits": sorted(edits, key=repr)}


def run(c, native):
    """The three steps from the saved project; returns what each left and
    the raw digests the phone's run is checked against."""
    def do(action, command):
        if native:
            reaper(f"reaper.Main_OnCommand({action}, 0)")
        else:
            c.fire(command)

    open_project(PROJECT)
    reaper("reaper.SetEditCurPos(0, false, false)")
    c.drain(0.3)
    start, files0 = digest(), reaper(FILES)
    out = {}

    do(1013, "transport/record")  # Transport: Record
    wait_play_state(5)
    c.drain(1.5)
    do(1016, "transport/stop")  # Transport: Stop
    wait_play_state(0)
    c.drain(0.3)
    recorded, files1 = digest(), reaper(FILES)
    out["record"] = (changes(start, recorded), recorded["undo"], len(files1) - len(files0))
    peaks = reaper(PEAKS)

    if native:
        reaper("reaper.Undo_DoUndo2(0)")
    else:
        r = c.command("undo/do", timeout=5)
        assert r.get("success"), f"undo/do failed: {r}"
    c.drain(0.3)
    undone = digest()
    out["undo"] = (changes(start, undone), undone["undo"], len(reaper(FILES)) - len(files1))

    reaper("reaper.SetEditCurPos(0, false, false)")
    do(1013, "transport/record")
    wait_play_state(5)
    c.drain(1.0)
    do(40668, "transport/stopAndDelete")  # Transport: Stop (DELETE all recorded media)
    wait_play_state(0)
    c.drain(0.5)
    deleted, files3 = digest(), reaper(FILES)
    out["stopAndDelete"] = (changes(undone, deleted), deleted["undo"], len(files3) - len(files1))
    return out, start, recorded, peaks, undone, deleted


with Feeder() as f:
    f.wait_connected()
    for ch in range(N):
        f.tone(ch, 330.0 + 110.0 * ch, LEVEL)
    with Client() as c:
        c.wait_event("trackSkeleton")
        native, *_ = run(c, native=True)
        phone, start, recorded, peaks, undone, deleted = run(c, native=False)
        for step in ("record", "undo", "stopAndDelete"):
            print(f"  {step}: REAPER {native[step]}")
            print(f"  {step}: phone  {phone[step]}")

        problems = []
        # The phone's own run, against what the user asked for.
        new = [g for g in recorded["items"] if g not in start["items"]]
        on = sorted(name_of(recorded, recorded["items"][g]["track"]) for g in new)
        if on != sorted(ARMED):
            problems.append(f"recording from the phone made takes on {on}, not one on each of {sorted(ARMED)}")
        for g in new:
            it = recorded["items"][g]
            if abs(it["pos"]) > 0.05 or not 1.2 < it["len"] < 2.5:
                problems.append(f"take on {name_of(recorded, it['track'])} at {it['pos']} s, {it['len']} s long; "
                                "recorded about 1.5 s from 0 s")
            if not peaks.get(g, 0) > LEVEL * 0.8:
                problems.append(f"take on {name_of(recorded, it['track'])} peaks at {peaks.get(g)}, "
                                f"the input was fed a tone at {LEVEL}")
        if phone["undo"][0] != {"new": [], "removed": [], "edits": []}:
            problems.append(f"undo/do of the recording left {phone['undo'][0]}")
        if phone["stopAndDelete"][0] != {"new": [], "removed": [], "edits": []}:
            problems.append(f"stopAndDelete left {phone['stopAndDelete'][0]}")
        if deleted["undo"] != undone["undo"]:
            problems.append(f"stopAndDelete changed the undo state: {undone['undo']} -> {deleted['undo']}")
        if phone["stopAndDelete"][2] != 0:
            problems.append(f"stopAndDelete left {phone['stopAndDelete'][2]} new file(s) in the record path")
        deadline = time.time() + 2
        count = reaper("return reaper.CountMediaItems(0)")
        while time.time() < deadline:
            ev = c.latest_event("items")
            shown = len(ev["payload"]["items"]) if ev else 0
            if shown == count:
                break
            c.drain(0.2)
        else:
            problems.append(f"after stopAndDelete the phone's items event shows {shown} items, REAPER {count}")

        # The phone against REAPER's own actions.
        for step in ("record", "undo", "stopAndDelete"):
            if phone[step] != native[step]:
                problems.append(f"{step} from the phone left {phone[step]}, REAPER's own action {native[step]}")
        assert not problems, "\n".join(problems)
