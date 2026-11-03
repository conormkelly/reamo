"""A bassist and a guitarist tune their own tracks on their own phones at
once: each reads only their own instrument, and a third phone joining the
guitar's track sees what the guitarist's phone sees.

REAPER runs on JACK with 2 inputs: Bass records from input 1, Guitar from
input 2. Phone A tunes Bass, phone B Guitar. E1 (the bass's open E) and G3
(the guitar's open G) are plucked together, three times:
- A reads only E1 and B only G3, each with stable readings within 1 cent
  of the frequency fed, no reading of the other's note (an octave either
  side included) and none flagged multiple: no crosstalk either way;
- the hook has one input tap per instrument (audio/status inputTaps 2).
Then phone C opens the tuner on Guitar too:
- it joins B's analyser (still 2 taps) and is told B's settings;
- over the next plucks it reads only G3, and its readings are B's: every
  pitched reading C gets, B gets too, the same to the hundredth of a hertz
  and of a cent;
- a setting B changes reaches C, not A.
"""
import time

from reamo_client import Client, reaper, skip_unless_linux

skip_unless_linux("REAPER's inputs come from the container's JACK server")

from jack_feeder import Feeder  # noqa: E402  after the skip: Linux only
from tuner_phone import Phone, check_note, midi_note, watch  # noqa: E402

E1, G3 = 41.2034, 195.9977


def pluck_both(f, phones):
    """E1 and G3 plucked together, each left to ring out (60 dB down in
    2 s), then 0.6 s of silence before the next. Returns the frequencies
    plucked and the feeder's xruns from E1's start: rendering E1 can cause
    some in the silence before it, but G3's render can gap a sounding E1."""
    for p in phones:
        p.mark()
    fb = f.pluck(0, E1, 0.8, decay=2.0)
    xruns = f.stats()["xruns"]
    fg = f.pluck(1, G3, 0.8, decay=2.0)
    watch(phones, 2.6)
    return fb, fg, f.stats()["xruns"] - xruns


def check(phone, freq, problems, xruns):
    # At least one stable reading, and every stable one, is its own note; no
    # reading names the other instrument's note or an octave either side of
    # it, and none is flagged multiple beyond what the xruns allow.
    n = midi_note(G3 if freq < 100 else E1)
    check_note(phone, freq, problems, min_readings=3, never=(n - 12, n, n + 12),
               alone=True, xruns=xruns)


def taps(c):
    s = c.command("audio/status")["payload"]
    return s["inputTaps"], s["hookUsers"]


problems = []
with Client() as a, Client() as b, Feeder() as f:
    f.wait_connected()
    skel = a.wait_event("trackSkeleton")["payload"]["tracks"]
    bass, gtr = skel[1]["g"], skel[2]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    pa, pb = Phone(a, "A (Bass)"), Phone(b, "B (Guitar)")
    assert pa.subscribe(bass)["success"] and pb.subscribe(gtr)["success"]
    n, users = taps(a)
    print("taps with A and B:", n, users)
    if n != 2:
        problems.append(f"{n} input taps for two inputs, want 2")
    # A second of quiet, as a player opening the tuner before plucking: the
    # analyser takes the start of its input for something already sounding,
    # and learns the noise floor while nothing shows.
    watch([pa, pb], 1.0)

    for k in range(3):
        fb, fg, xruns = pluck_both(f, [pa, pb])
        print(f"--- pluck {k + 1}: E1 {fb:.4f} Hz on input 1, G3 {fg:.4f} Hz on input 2, {xruns} xruns")
        check(pa, fb, problems, xruns)
        check(pb, fg, problems, xruns)

    with Client() as c:
        pc = Phone(c, "C (Guitar)")
        r = pc.subscribe(gtr)
        assert r["success"], r
        n, _ = taps(a)
        print("taps with C on Guitar too:", n, "C told", r["payload"])
        if n != 2:
            problems.append(f"{n} input taps after C joined Guitar, want 2")
        for k in range(2):
            fb, fg, xruns = pluck_both(f, [pa, pb, pc])
            print(f"--- pluck with C {k + 1}, {xruns} xruns")
            check(pa, fb, problems, xruns)
            check(pb, fg, problems, xruns)
            check(pc, fg, problems, xruns)
            # Against everything B has had: the phones are read in turn, so
            # a poll's events can reach one inside a window and the other
            # just outside it.
            pb.pump(0.2)
            seen_by_b = {(p["freq"], p["cents"]) for p in pb.all if p["freq"] > 0}
            not_b = [(p["freq"], p["cents"]) for p in pc.pitched() if (p["freq"], p["cents"]) not in seen_by_b]
            print(f"C's pitched readings not among B's: {len(not_b)} of {len(pc.pitched())}")
            if not_b:
                problems.append(f"C read {len(not_b)} pitched readings B never got: {not_b[:5]}")

        r = b.command("tuner/setParam", trackGuid=gtr, param="reference", value=442.0)
        assert r["success"], r
        pc.wait(lambda p: p["referenceHz"] == 442.0, 2.0, "B's 442 Hz reference")
        pa.pump(0.3)
        if pa.last and pa.last["referenceHz"] != 440.0:
            problems.append(f"B's reference reached A on another input: {pa.last['referenceHz']}")
        assert c.command("tuner/unsubscribe")["success"]

    assert a.command("tuner/unsubscribe")["success"] and b.command("tuner/unsubscribe")["success"]
    n, users = taps(a)
    print("taps after all left:", n, users)
    if n != 0 or users["inputs"]:
        problems.append(f"after every phone left: {n} taps, hook users {users}")

assert not problems, "\n".join(problems)
print("ok: two phones on two inputs each read only their own, and a third shares one")
