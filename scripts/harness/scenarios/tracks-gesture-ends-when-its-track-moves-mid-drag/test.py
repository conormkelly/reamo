"""The user inserts a track above the one a phone is dragging, mid-drag: the
drag still ends at gesture/end, with its own undo point.

The phone sends gesture/start and gesture/end by track GUID and, for
hardware outputs, values by the index it shows (which shifts with the
insert). Within 1.5 s of gesture/end, well inside the 10 s gesture timeout,
the drag's undo point must be on top of REAPER's undo history, and no value
change of the drag may have made an undo step of its own. Afterwards a
change on the track now at the dragged track's old index must be an undo
step of its own, not part of a drag that is still open.

The steps are checked by label, not counted: REAPER may commit a CSurf
volume drag in two parts around the user's insert, and adds "Edit FX
parameter" points of its own.
"""
import time

from reamo_client import Client, reaper

UNDO = "return reaper.Undo_CanUndo2(0) or ''"
LABELS = """
local labels = {}
while reaper.Undo_CanUndo2(0) do labels[#labels + 1] = reaper.Undo_CanUndo2(0); reaper.Undo_DoUndo2(0) end
for _ = 1, #labels do reaper.Undo_DoRedo2(0) end
return labels
"""


def undo_labels():
    """Every undo step's label, newest first."""
    return reaper(LABELS) or []


def index_of(name):
    """Unified index (1 = first user track) of the track called `name`."""
    return reaper(f"""
for i = 0, reaper.CountTracks(0) - 1 do
  local _, n = reaper.GetTrackName(reaper.GetTrack(0, i))
  if n == '{name}' then return i + 1 end
end
""")


def user_inserts_track_at_top(name):
    reaper(f"""
        reaper.Undo_BeginBlock()
        reaper.InsertTrackAtIndex(0, true)
        reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(0, 0), 'P_NAME', '{name}', true)
        reaper.Undo_EndBlock('{name}', -1)
    """)


HW_CHANGE = "REAmo: Adjust audio hardware output volume"  # a change outside a drag
CONTROLS = [
    # controlType, extra address params, value command, value key, values, the drag's undo label
    ("hwOutputVolume", {"hwIdx": 0}, "hw/setVolume", "volume", [0.9, 0.8, 0.7, 0.6, 0.5, 0.4],
     "REAmo: Adjust hardware outputs"),
    ("volume", {}, "track/setVolume", "volume", [0.9, 0.8, 0.7, 0.6, 0.5, 0.4],
     "Adjust track volume (via surface)"),
    ("fxParam", {"paramIdx": 0}, "trackFxParams/set", "value", [0.55, 0.6, 0.65, 0.7, 0.75, 0.8],
     "REAmo: Adjust FX parameters"),
]

problems = []
with Client() as c:
    guid = next(t["g"] for t in c.wait_event("trackSkeleton")["payload"]["tracks"] if t["n"] == "Guitar")
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    assert c.command("trackFx/subscribe", trackGuid=guid)["success"]
    fx = c.wait_event("trackFxChain")["payload"]["fx"][0]["fxGuid"]

    for n, (ctl, extra, cmd, key, values, label) in enumerate(CONTROLS, 1):
        if ctl == "fxParam":
            extra = dict(extra, fxGuid=fx)
        old_idx = index_of("Guitar")
        before = len(undo_labels())
        c.fire("gesture/start", controlType=ctl, trackGuid=guid, **extra)
        for i, v in enumerate(values):
            if i == len(values) // 2:
                # Wait for the changes so far to be applied: a hw/setVolume still
                # queued at the old index would land on the track that moves into it.
                c.command(cmd, **addr, **extra, **{key: values[i - 1]})
                user_inserts_track_at_top(f"Click {n}")
                c.drain(0.3)  # the phone sees the new track list
            addr = {"trackIdx": index_of("Guitar")} if cmd == "hw/setVolume" else {"trackGuid": guid}
            c.fire(cmd, **addr, **extra, **{key: v})
            time.sleep(0.03)
        c.fire("gesture/end", controlType=ctl, trackGuid=guid, **extra)
        c.drain(1.5)

        labels = undo_labels()
        new = labels[: len(labels) - before]
        print(f"{ctl:15s}: Guitar {old_idx} -> {index_of('Guitar')}; new undo steps, newest first: {new}")
        if not new or new[0] != label:
            problems.append(f"{ctl}: after gesture/end the top of undo is {new[:1]}, not the drag's {label!r}")
        if f"Click {n}" not in new:
            problems.append(f"{ctl}: the user's insert has no undo step of its own: {new}")
        if HW_CHANGE in new:
            problems.append(f"{ctl}: changes inside the drag made undo steps of their own: {new}")

        if ctl == "hwOutputVolume":
            # Vocals now sits at Guitar's old index; the phone sets its output
            # (to a new value: REAPER 6 records no undo point for a no-op).
            c.fire("hw/setVolume", trackIdx=old_idx, hwIdx=0, volume=0.5)
            c.drain(0.5)
            after = undo_labels()
            print(f"{'':15s}  Vocals' output at index {old_idx}: new undo steps {after[: len(after) - len(labels)]}")
            if after[: len(after) - len(labels)] != [HW_CHANGE]:
                problems.append(f"a change at Guitar's old index {old_idx} is not an undo step of its own")
assert not problems, "\n".join(problems)
