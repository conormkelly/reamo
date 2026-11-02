"""A track's tuner reads the hardware input the track records from, armed
or not, stopped or playing, and puts nothing on the track.

REAPER runs on JACK with 2 inputs. Guitar records from input 2 (I_RECINPUT
1), unarmed. Input 1 carries a steady E2 throughout, so a reading of
anything but the pluck on input 2 shows as a wrong note. For each of
unarmed and stopped, armed and stopped, unarmed and playing, and armed and
playing, A3 is plucked on input 2, and the phone tuning Guitar must:
- read A3 and no other note;
- have stable readings within 1 cent of the frequency fed;
- get the analyser's flags (settling, stable, multiple, starting) and
  state "listening" on every event.
Against a tuner on the JSFX, unarmed reads nothing (input FX don't run on
an unarmed track) and the events carry no flags or state.

The subscribe response has no fxGuid and the analyser's -90 dB threshold,
and the track's FX chains stay empty throughout.
"""
import time

from reamo_client import Client, reaper, skip_unless_linux

skip_unless_linux("REAPER's inputs come from the container's JACK server")

from jack_feeder import Feeder  # noqa: E402  after the skip: Linux only
from tuner_phone import Phone, check_note, watch  # noqa: E402

FX = "local t = reaper.GetTrack(0, 1); return reaper.TrackFX_GetCount(t) + reaper.TrackFX_GetRecCount(t)"

problems = []
with Client() as c, Feeder() as f:
    f.wait_connected()
    gtr = c.wait_event("trackSkeleton")["payload"]["tracks"][2]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    f.tone(0, 82.41, 0.5)  # E2 on input 1: not Guitar's
    phone = Phone(c, "Guitar's phone")
    r = phone.subscribe(gtr)
    assert r["success"], r
    print("subscribe:", r["payload"])
    assert r["payload"]["fxGuid"] == "" and r["payload"]["threshold"] == -90.0, r["payload"]
    assert r["payload"]["trackName"] == "Guitar", r["payload"]

    for armed in (0, 1):
        for playing in (False, True):
            when = f"{'armed' if armed else 'unarmed'}, {'playing' if playing else 'stopped'}"
            reaper(f"reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, 1), 'I_RECARM', {armed})")
            reaper("reaper.OnPlayButton()" if playing else "reaper.OnStopButton()")
            f.silence(1)
            time.sleep(0.6)
            phone.mark()
            freq = f.pluck(1, 220.0, 0.8, decay=4.0)
            watch([phone], 1.5)
            print(f"--- {when}: plucked {freq:.3f} Hz")
            before = len(problems)
            check_note(phone, freq, problems, never=(40,))  # nothing of input 1's E2
            missing = [k for k in ("settling", "stable", "multiple", "starting", "state") if k not in phone.since[-1]]
            if missing:
                problems.append(f"{when}: events lack {missing}")
            states = {p.get("state") for p in phone.since}
            if states != {"listening"}:
                problems.append(f"{when}: states {states}, want only listening")
            problems[before:] = [f"{when}: {p}" for p in problems[before:]]
            fx = reaper(FX)
            if fx != 0:
                problems.append(f"{when}: {fx} FX on Guitar while tuning")
    reaper("reaper.OnStopButton()")
    assert c.command("tuner/unsubscribe")["success"]

assert not problems, "\n".join(problems)
print("ok: the tuner reads input 2, armed or not, stopped or playing")
