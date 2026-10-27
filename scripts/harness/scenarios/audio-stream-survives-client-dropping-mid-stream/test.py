"""Audio monitoring: frames flow to a listening phone, stop when it stops,
and a phone that vanishes mid-stream (no stopStream, socket just dies) frees
its listener slot so the next phone can listen. REAPER survives all of it.
"""
import time

from reamo_client import Client, reaper


def status(c):
    r = c.command("audio/status")
    assert r["success"], r
    return r["payload"]


def frames_for(c, seconds):
    n = len(c.binary)
    c.drain(seconds)
    return len(c.binary) - n


problems = []
reaper("reaper.OnPlayButton()")
with Client() as ctl:
    with Client() as a:
        r = a.command("audio/startStream")
        assert r["success"] and r["payload"]["sampleRate"] > 0, r
        got = frames_for(a, 1.5)
        print(f"frames in 1.5 s: {got}; status {status(ctl)}")
        if got == 0:
            problems.append("no audio frames reached the listening client")
        assert a.command("audio/stopStream")["success"]
        a.drain(0.3)
        if frames_for(a, 1.0) > 0:
            problems.append("frames kept coming after stopStream")
        assert a.command("audio/startStream")["success"]
        a.drain(0.5)
        # vanish: close the socket mid-stream without stopStream
    deadline = time.time() + 3
    while status(ctl)["clientCount"] != 0 and time.time() < deadline:
        time.sleep(0.2)
    if status(ctl)["clientCount"] != 0:
        problems.append(f"listener slot not freed after the client vanished: {status(ctl)}")

    # Four listeners fit; a fifth is refused cleanly; a freed slot is reusable.
    phones = [Client() for _ in range(5)]
    res = [p.command("audio/startStream") for p in phones]
    ok = [r["success"] for r in res]
    print("5 listeners:", ok)
    if ok != [True, True, True, True, False]:
        problems.append(f"listener cap: {ok}")
    phones[0].close()
    deadline = time.time() + 3
    while time.time() < deadline:
        r = phones[4].command("audio/startStream")
        if r["success"]:
            break
        time.sleep(0.3)
    if not r["success"]:
        problems.append(f"a freed listener slot was not reusable: {r}")
    elif frames_for(phones[4], 1.0) == 0:
        problems.append("the late listener gets no frames")
    for p in phones[1:]:
        p.close()
    assert ctl.command("debug/memoryStats")["success"]
assert not problems, "\n".join(problems)
