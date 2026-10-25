"""Mixer: volume, pan, mute, solo, arm, monitoring, FX bypass, selection,
name and colour of tracks."""
import time

from tour import approx, op

@op("track/setVolume by index and by GUID", "track/setVolume")
def _(t):
    g, tr = t.track(name="Bass DI")
    t.ok("track/setVolume", trackIdx=tr["pos"], volume=0.5)
    t.expect({f"tracks.{g}.vol": approx(0.5, 1e-4)})
    t.digest()
    t.ok("track/setVolume", trackGuid=g, volume=1.25)
    t.expect({f"tracks.{g}.vol": approx(1.25, 1e-4)})
    t.digest()
    t.ok("track/setVolume", trackIdx=0, volume=0.8)  # master
    t.expect({"tracks.master.vol": approx(0.8, 1e-4)})


@op("track/setPan", "track/setPan")
def _(t):
    g, tr = t.track(name="Guitar")
    t.ok("track/setPan", trackGuid=g, pan=-0.4)
    t.expect({f"tracks.{g}.pan": approx(-0.4)})


@op("fader drag: gesture + 30 setVolume = one undo step", "gesture/start", "gesture/end")
def _(t):
    g, tr = t.track(name="Kick")
    t.ok("gesture/start", controlType="volume", trackGuid=g)
    for i in range(30):
        t.c.fire("track/setVolume", trackGuid=g, volume=1.0 - i * 0.02)
        time.sleep(0.01)
    t.ok("gesture/end", controlType="volume", trackGuid=g)
    t.expect({f"tracks.{g}.vol": approx(0.42, 1e-3)})
    t.check_undo()


@op("track/setMute explicit and toggle", "track/setMute")
def _(t):
    g, tr = t.track(name="Snare")
    t.ok("track/setMute", trackIdx=tr["pos"], mute=1)
    t.expect({f"tracks.{g}.mute": 1})
    t.digest()
    t.ok("track/setMute", trackGuid=g)  # toggle
    t.expect({f"tracks.{g}.mute": 0})


@op("track/setSolo + setSoloExclusive", "track/setSolo", "track/setSoloExclusive")
def _(t):
    g1, _ = t.track(name="Guitar")
    g2, tr2 = t.track(name="Keys")
    t.ok("track/setSolo", trackGuid=g1, solo=1)
    t.expect({f"tracks.{g1}.solo": lambda v: v > 0})
    t.digest()
    t.ok("track/setSoloExclusive", trackIdx=tr2["pos"])
    t.expect({f"tracks.{g1}.solo": 0, f"tracks.{g2}.solo": lambda v: v > 0})
    t.digest()
    t.ok("track/setSolo", trackGuid=g2, solo=0)
    t.expect({f"tracks.{g2}.solo": 0})


@op("track/setRecArm + setRecMon", "track/setRecArm", "track/setRecMon")
def _(t):
    g, tr = t.track(name="Guitar")
    t.ok("track/setRecArm", trackGuid=g, arm=1)
    t.expect({f"tracks.{g}.arm": 1})
    t.digest()
    t.ok("track/setRecMon", trackGuid=g, mon=2)
    t.expect({f"tracks.{g}.mon": 2})
    t.digest()
    t.ok("track/setRecArm", trackGuid=g, arm=0)
    t.expect({f"tracks.{g}.arm": 0})


@op("track/setFxEnabled", "track/setFxEnabled")
def _(t):
    g, tr = t.track(name="Drums")
    t.ok("track/setFxEnabled", trackGuid=g, enabled=0)
    t.expect({f"tracks.{g}.fxen": 0})
    t.digest()
    t.ok("track/setFxEnabled", trackGuid=g)
    t.expect({f"tracks.{g}.fxen": 1})


@op("track/setSelected + unselectAll", "track/setSelected", "track/unselectAll")
def _(t):
    g, tr = t.track(name="BVs")
    t.ok("track/setSelected", trackGuid=g, selected=1)
    t.expect({f"tracks.{g}.sel": 1})
    t.digest()
    t.ok("track/unselectAll")
    t.expect({"tracks.*.sel": 0})


@op("track/rename", "track/rename")
def _(t):
    g, tr = t.track(name="BVs")
    t.ok("track/rename", trackIdx=tr["pos"], name="Backing Vocals – Ünïcødé 🎤")
    t.expect({f"tracks.{g}.name": "Backing Vocals – Ünïcødé 🎤"})
    t.check_undo()


@op("track/setColor + reset", "track/setColor")
def _(t):
    g, tr = t.track(name="Bass DI")
    t.ok("track/setColor", trackGuid=g, color=0x1000000 | 0x3366CC)
    t.expect({f"tracks.{g}.color": 0x1000000 | 0x3366CC})
    t.digest()
    t.ok("track/setColor", trackGuid=g, color=0)
    t.expect({f"tracks.{g}.color": 0})
