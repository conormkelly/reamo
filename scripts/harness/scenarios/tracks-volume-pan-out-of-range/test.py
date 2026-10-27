"""Out-of-range fader values (negative, huge, exponent forms) leave REAPER with a
sane volume/pan that the tracks event reports exactly, and never kill REAPER."""
import time

from reamo_client import Client, reaper

VP = "local t = reaper.GetTrack(0, 0); return reaper.GetMediaTrackInfo_Value(t, 'D_VOL'), reaper.GetMediaTrackInfo_Value(t, 'D_PAN')"

with Client() as c:
    c.wait_event("trackSkeleton")
    assert c.command("track/subscribe", range={"start": 1, "end": 1})["success"]
    problems = []
    for vol in (-1.0, 0.0, 1e-9, 3.98, 1e6, 1e300, 2.5e-3):
        r = c.command("track/setVolume", trackIdx=1, volume=vol)
        deadline = time.time() + 1.5
        while time.time() < deadline:
            c.drain(0.15)
            ev = c.latest_event("tracks")
            shown = ev["payload"]["tracks"][0]["volume"] if ev else None
            got = reaper(VP)[0]
            if shown is not None and abs(shown - got) <= 1e-9 * max(1, got):
                break
        print(f"volume {vol!r:>8}: success={r['success']} REAPER D_VOL={got!r} shown={shown!r}")
        if not (got >= 0 and got < float("inf")):
            problems.append(f"volume {vol}: REAPER D_VOL={got}")
        if shown is None or abs(shown - got) > 1e-6 * max(1, got):
            problems.append(f"volume {vol}: tracks event shows {shown}, REAPER has {got}")
    for pan in (-5, 5, 0.25):
        c.command("track/setPan", trackIdx=1, pan=pan)
        c.drain(0.3)
        got = reaper(VP)[1]
        print(f"pan {pan!r:>5}: REAPER D_PAN={got}")
        if not -1 <= got <= 1:
            problems.append(f"pan {pan}: REAPER D_PAN={got}")
    # Raw JSON a client could send: an exponent the float scanner must not mis-read.
    c.send({"type": "command", "command": "track/setVolume", "id": "raw1", "trackIdx": 1, "volume": 1E-2})
    c.drain(0.4)
    print("volume 1E-2 ->", reaper(VP)[0])
    if abs(reaper(VP)[0] - 0.01) > 1e-9:
        problems.append(f"volume 1E-2: REAPER D_VOL={reaper(VP)[0]}")
    assert not problems, "\n".join(problems)
