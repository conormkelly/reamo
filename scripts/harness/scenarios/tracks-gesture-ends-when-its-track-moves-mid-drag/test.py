"""The user inserts a track above the one a phone is dragging, mid-drag: the
drag stays on its track and ends at gesture/end, with its own undo point.

The phone sends gesture/start, every value and gesture/end by the track GUID
it locked at gesture start (Fader, the routing faders, the FX parameter
slider). The values stream without waiting for replies, so some sent before
the insert are applied after it. Within 1.5 s of gesture/end, well inside the
10 s gesture timeout: the dragged value is on the dragged track and nowhere
else, the drag's undo point is on top of REAPER's undo history, and no value
of the drag made an undo step of its own. Afterwards a change on the track
now at the dragged track's old index is an undo step of its own, not part of
a drag that is still open.

A last case is a client that sends routing values by the index it saw at
mousedown: after the insert those values name the track that moved into the
index, so they change that track, each as its own undo step, while the drag
on the GUID still ends at gesture/end.

Undo steps are checked by label, not counted: REAPER may commit a CSurf
volume drag in two parts around the user's insert, and adds "Edit FX
parameter" points of its own.
"""
import time

from reamo_client import Client, reaper

LABELS = """
local labels = {}
while reaper.Undo_CanUndo2(0) do labels[#labels + 1] = reaper.Undo_CanUndo2(0); reaper.Undo_DoUndo2(0) end
for _ = 1, #labels do reaper.Undo_DoRedo2(0) end
return labels
"""


def undo_labels():
    """Every undo step's label, newest first."""
    return reaper(LABELS) or []


def track_expr(name):
    return f"""(function()
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i); local _, n = reaper.GetTrackName(t)
    if n == '{name}' then return t end
  end
end)()"""


def index_of(name):
    """Unified index (1 = first user track) of the track called `name`."""
    return reaper(f"return math.floor(reaper.GetMediaTrackInfo_Value({track_expr(name)}, 'IP_TRACKNUMBER'))")


def user_inserts_track_at_top(name):
    reaper(f"""
        reaper.Undo_BeginBlock()
        reaper.InsertTrackAtIndex(0, true)
        reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(0, 0), 'P_NAME', '{name}', true)
        reaper.Undo_EndBlock('{name}', -1)
    """)


# controlType, extra address params, value command, value key, values,
# Lua reading the value from track `t`, the drag's undo label, the label a
# value outside a drag gets (None for track volume and FX parameters).
HW_VOL = "reaper.GetTrackSendInfo_Value(t, 1, 0, 'D_VOL')"
HW_CHANGE = "REAmo: Adjust audio hardware output volume"
CONTROLS = [
    ("hwOutputVolume", {"hwIdx": 0}, "hw/setVolume", "volume", [0.9, 0.8, 0.7, 0.6, 0.5, 0.4],
     HW_VOL, "REAmo: Adjust hardware outputs", HW_CHANGE),
    ("send", {"sendIdx": 0}, "send/setVolume", "volume", [0.9, 0.8, 0.7, 0.6, 0.5, 0.4],
     "reaper.GetTrackSendInfo_Value(t, 0, 0, 'D_VOL')", "REAmo: Adjust sends", "REAmo: Adjust send volume"),
    ("receivePan", {"recvIdx": 0}, "receive/setPan", "pan", [-0.1, -0.2, -0.3, -0.4, -0.5, -0.6],
     "reaper.GetTrackSendInfo_Value(t, -1, 0, 'D_PAN')", "REAmo: Adjust receives", "REAmo: Adjust receive pan"),
    ("volume", {}, "track/setVolume", "volume", [0.9, 0.8, 0.7, 0.6, 0.5, 0.4],
     "reaper.GetMediaTrackInfo_Value(t, 'D_VOL')", "Adjust track volume (via surface)", None),
    ("fxParam", {"paramIdx": 0}, "trackFxParams/set", "value", [0.55, 0.6, 0.65, 0.7, 0.72, 0.75],
     "reaper.TrackFX_GetParamNormalized(t, 0, 0)", "REAmo: Adjust FX parameters", None),
]


def value_on(name, lua):
    return reaper(f"local t = {track_expr(name)} return {lua}")


problems = []
with Client() as c:
    guid = next(t["g"] for t in c.wait_event("trackSkeleton")["payload"]["tracks"] if t["n"] == "Guitar")
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    assert c.command("trackFx/subscribe", trackGuid=guid)["success"]
    fx = c.wait_event("trackFxChain")["payload"]["fx"][0]["fxGuid"]
    n = 0

    for ctl, extra, cmd, key, values, lua, label, change_label in CONTROLS:
        n += 1
        if ctl == "fxParam":
            extra = dict(extra, fxGuid=fx)
        old_idx = index_of("Guitar")
        vocals_before = value_on("Vocals", lua)
        before = len(undo_labels())
        c.fire("gesture/start", controlType=ctl, trackGuid=guid, **extra)
        for i, v in enumerate(values):
            if i == len(values) // 2:
                user_inserts_track_at_top(f"Click {n}")
            c.fire(cmd, trackGuid=guid, **extra, **{key: v})
            time.sleep(0.03)
        c.fire("gesture/end", controlType=ctl, trackGuid=guid, **extra)
        c.drain(1.5)

        labels = undo_labels()
        new = labels[: len(labels) - before]
        got, vocals = value_on("Guitar", lua), value_on("Vocals", lua)
        print(f"{ctl:15s}: Guitar {old_idx} -> {index_of('Guitar')}, value {got} (Vocals {vocals_before} -> {vocals}); "
              f"new undo steps, newest first: {new}")
        # The FX drag ends on 0.75, one of the EQ parameter's steps, so REAPER stores it exactly.
        if abs(got - values[-1]) > 1e-6:
            problems.append(f"{ctl}: Guitar ends at {got}, not the drag's last value {values[-1]}")
        if abs(vocals - vocals_before) > 1e-9:
            problems.append(f"{ctl}: the drag changed Vocals ({vocals_before} -> {vocals})")
        if not new or new[0] != label:
            problems.append(f"{ctl}: after gesture/end the top of undo is {new[:1]}, not the drag's {label!r}")
        if f"Click {n}" not in new:
            problems.append(f"{ctl}: the user's insert has no undo step of its own: {new}")
        if change_label and change_label in new:
            problems.append(f"{ctl}: values inside the drag made undo steps of their own: {new}")

        if ctl == "hwOutputVolume":
            # Vocals now sits at Guitar's old index; the phone sets its output
            # (to a new value: REAPER 6 records no undo point for a no-op).
            c.fire("hw/setVolume", trackIdx=old_idx, hwIdx=0, volume=0.5)
            c.drain(0.5)
            after = undo_labels()
            print(f"{'':15s}  Vocals' output at index {old_idx}: new undo steps {after[: len(after) - len(labels)]}")
            if after[: len(after) - len(labels)] != [HW_CHANGE]:
                problems.append(f"a change at Guitar's old index {old_idx} is not an undo step of its own")

    # A client that addresses routing values by the index it saw at mousedown.
    n += 1
    old_idx = index_of("Guitar")
    vocals_before = value_on("Vocals", HW_VOL)
    before = len(undo_labels())
    values = [0.9, 0.8, 0.7, 0.6, 0.5, 0.4]
    c.fire("gesture/start", controlType="hwOutputVolume", trackGuid=guid, hwIdx=0)
    for i, v in enumerate(values):
        if i == len(values) // 2:
            # Wait for the values so far to be applied before the insert, so
            # which track each value reaches is deterministic: a value still
            # queued at old_idx when the insert lands would reach Vocals too.
            c.command("hw/setVolume", trackIdx=old_idx, hwIdx=0, volume=values[i - 1])
            user_inserts_track_at_top(f"Click {n}")
        c.fire("hw/setVolume", trackIdx=old_idx, hwIdx=0, volume=v)
        time.sleep(0.03)
    c.fire("gesture/end", controlType="hwOutputVolume", trackGuid=guid, hwIdx=0)
    c.drain(1.5)
    labels = undo_labels()
    new = labels[: len(labels) - before]
    got, vocals = value_on("Guitar", HW_VOL), value_on("Vocals", HW_VOL)
    late = values[len(values) // 2:]
    print(f"by index {old_idx:5d}: Guitar output {got}, Vocals output {vocals_before} -> {vocals}; new undo steps {new}")
    if abs(got - values[len(values) // 2 - 1]) > 1e-6 or abs(vocals - late[-1]) > 1e-6:
        problems.append(f"index-addressed values: Guitar {got}, Vocals {vocals}; want the values before the insert "
                        f"on Guitar and after it on Vocals, the track now at index {old_idx}")
    if new.count(HW_CHANGE) != len(late):
        problems.append(f"index-addressed values: want each of the {len(late)} values Vocals got as its own undo step: {new}")
    # Every change Guitar got is already inside the user's insert step, so the
    # drag's end adds no undo point of its own. That the drag ended shows in
    # the next change on Guitar: outside any drag, it is its own undo step.
    c.fire("hw/setVolume", trackIdx=index_of("Guitar"), hwIdx=0, volume=0.3)
    c.drain(0.5)
    after = undo_labels()
    print(f"{'':15s}  Guitar's output at index {index_of('Guitar')}: new undo steps {after[: len(after) - len(labels)]}")
    if after[: len(after) - len(labels)] != [HW_CHANGE]:
        problems.append("index-addressed values: after gesture/end a change on Guitar is not an undo step of its own")
assert not problems, "\n".join(problems)
