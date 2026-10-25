"""The MIDI pads/faders send every value in their range, and a fast burst
(a pad roll, a fader sweep) of fire-and-forget messages neither drops the
connection nor stalls REAPER. Out-of-range values are refused.
"""
import subprocess
import time

from reamo_client import Client, reaper

with Client() as c:
    c.wait_event("transport")
    server_errors = []
    _next = c._next_message

    def recording(deadline):
        m = _next(deadline)
        if m.get("type") == "error":
            server_errors.append(m)
        return m
    c._next_message = recording
    ok = [("midi/cc", dict(cc=0, value=0)), ("midi/cc", dict(cc=127, value=127, channel=15)),
          ("midi/pc", dict(program=0)), ("midi/pc", dict(program=127, channel=15)),
          ("midi/noteOn", dict(note=60, velocity=100)), ("midi/noteOn", dict(note=60, velocity=0)),
          ("midi/pitchBend", dict(value=0)), ("midi/pitchBend", dict(value=8192)),
          ("midi/pitchBend", dict(value=16383, channel=9))]
    for cmd, params in ok:
        r = c.command(cmd, **params)
        assert r["success"], (cmd, params, r)
    bad = [("midi/cc", dict(cc=128, value=0)), ("midi/cc", dict(cc=1, value=-1)),
           ("midi/cc", dict(cc=1, value=1, channel=16)), ("midi/pc", dict(program=128)),
           ("midi/noteOn", dict(note=128, velocity=1)), ("midi/noteOn", dict(note=1, velocity=128)),
           ("midi/pitchBend", dict(value=-1)), ("midi/noteOn", dict(note=60))]
    for cmd, params in bad:
        r = c.command(cmd, **params)
        assert not r["success"], f"{cmd} {params} accepted"

    # Ten fingers on pads and faders: ~600 messages/s for 3 s, fire-and-forget.
    t0 = time.time()
    sent = 0
    while time.time() - t0 < 3:
        for k in range(6):
            c.fire("midi/cc", cc=7 + k, value=sent % 128, channel=k)
            sent += 1
        c.fire("midi/noteOn", note=36 + sent % 16, velocity=(sent * 7) % 128)
        sent += 1
        time.sleep(0.01)
    t1 = time.time()
    try:
        r = c.command("playlist/create", name="after-burst", timeout=5)  # the UI's await timeout
    except TimeoutError:
        r = None
    c.drain(0.5)
    errors = server_errors
    codes = sorted({m["error"]["code"] for m in errors})
    print(f"awaited command after the burst: {'ok' if r else 'NO RESPONSE'} ({time.time() - t1:.2f} s); "
          f"{len(errors)} server errors {codes}")
    if not r:
        c.drain(1.0)
        ran = any(p["name"] == "after-burst" for p in c.latest_event("playlist")["payload"]["playlists"])
        print("the command itself", "RAN (its response was lost)" if ran else "has not run")
        c.send({"type": "ping"})  # any later frame from the client
        seen = []
        try:
            dl = time.time() + 1.5
            while True:
                seen.append(c._next_message(dl).get("type"))
        except TimeoutError:
            pass
        except Exception as e:
            seen.append(f"{type(e).__name__}: {e}")
        print("after the ping the client received:", sorted(set(map(str, seen))), len(seen))
        print(subprocess.run("grep -E 'CLIENT|WARN' /tmp/reaper/Logs/reamo.log | grep -v FastTimer | tail -5",
                             shell=True, capture_output=True, text=True).stdout)
        ran = any(p["name"] == "after-burst" for p in c.latest_event("playlist")["payload"]["playlists"])
        print("after one more client frame the command", "RAN" if ran else "still has not run")
        print(subprocess.run("grep -E 'WARN|ERR' /tmp/reaper/Logs/reamo.log | grep -v FastTimer | tail -8",
                             shell=True, capture_output=True, text=True).stdout)
    assert r and r["success"], "the awaited command sent right after the burst got no response"
    print(f"{sent} messages in 3 s ({sent / 3:.0f}/s); server errors: {len(errors)} {errors[:1]}")
    assert not errors, f"the server refused messages during a realistic burst: {errors[:3]}"
    assert reaper("return 1") == 1
