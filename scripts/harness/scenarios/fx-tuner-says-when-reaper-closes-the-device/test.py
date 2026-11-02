"""With "close audio device when stopped" on, the tuner tells the phone the
device is closed while REAPER is stopped, rather than showing a silence
that looks broken, and reads again once play opens the device.

With that preference (reaper.ini audioclosestop=1) REAPER closes the
device while stopped: the audio hook gets no callbacks at all, and
Audio_IsRunning() and GetNumAudioInputs() read 0. REAPER is restarted
with it on. Then, stopped:
- tuner/subscribe on Guitar (input 2) succeeds: the input can't be checked
  against a closed device, and isn't refused as missing;
- the phone on Guitar and a phone on the master get state "deviceClosed",
  and no reading while A3 is plucked on input 2.
Play: both get state "listening", and a pluck reads A3. Stop: both say
"deviceClosed" again.
"""
import time

from reamo_client import Client, reaper, restart_reaper, skip_unless_linux

skip_unless_linux("REAPER's inputs come from the container's JACK server")

from jack_feeder import Feeder  # noqa: E402  after the skip: Linux only
from tuner_phone import Phone, check_note, watch  # noqa: E402

restart_reaper(ini={"audioclosestop": 1})
problems = []
with Feeder() as f, Client() as a, Client() as b:
    gtr = a.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    running = reaper("return reaper.Audio_IsRunning(), reaper.GetNumAudioInputs()")
    print("stopped: Audio_IsRunning, GetNumAudioInputs =", running)
    assert running == [0, 0] or running == (0, 0), f"REAPER kept the device open while stopped: {running}"

    pa, pm = Phone(a, "Guitar's phone"), Phone(b, "master's phone")
    r = pa.subscribe(gtr)
    assert r["success"], f"a track on a closed device was refused: {r}"
    assert pm.subscribe("master")["success"]
    for p in (pa, pm):
        p.wait_state("deviceClosed")
    pa.mark()
    f.pluck(1, 220.0, 0.8, decay=2.0)
    watch([pa, pm], 1.0)
    if pa.pitched():
        problems.append(f"a reading while the device is closed: {pa.pitched()[:3]}")
    if {p.get("state") for p in pa.since} - {"deviceClosed"}:
        problems.append(f"states while closed: {[p.get('state') for p in pa.since]}")

    reaper("reaper.OnPlayButton()")
    f.wait_connected()  # REAPER registers its JACK ports again as it opens the device
    for p in (pa, pm):
        p.wait_state("listening", timeout=10)
    print("playing: Audio_IsRunning, GetNumAudioInputs =",
          reaper("return reaper.Audio_IsRunning(), reaper.GetNumAudioInputs()"))
    f.silence(1)
    time.sleep(0.5)
    pa.mark()
    freq = f.pluck(1, 220.0, 0.8, decay=4.0)
    watch([pa, pm], 1.5)
    check_note(pa, freq, problems)

    reaper("reaper.OnStopButton()")
    for p in (pa, pm):
        st = p.wait_state("deviceClosed", timeout=10)
        if st["freq"] != 0:
            problems.append(f"{p.name}: a reading with the device closed: {st}")

assert not problems, "\n".join(problems)
print("ok: the tuner says the device is closed while stopped, and reads on play")
