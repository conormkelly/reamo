"""The master tuner hears the inputs REAPER monitors through the master
with the transport stopped, and says when it hears several notes.

REAPER runs on JACK with 2 inputs. Bass (input 1) and Guitar (input 2) are
armed and monitor their input, so both reach the master while stopped. One
phone tunes the master; the transport stays stopped and the device running
throughout.
- Guitar alone: A3 plucked on input 2 reads A3 on the master, with stable
  readings within 1 cent of the frequency fed, nothing flagged multiple.
- Guitar not monitoring (I_RECMON 0): the same pluck reaches no output, and
  the master shows no note. So the readings above came through REAPER's
  monitoring and the master, not from the input itself.
- Bass and Guitar plucked together, E2 and G3: the master hears two notes.
  Their mix repeats at a common subharmonic under both, which the analyser
  may read briefly after the pluck, never stably; once the spectrum
  resolves it, the reading is flagged multiple and shows no note, or one
  of the two. So with two instruments sounding the master shows no note
  for most of each pluck, and that is the analyser's answer, not silence.

Notes held from before the tuner opens never show (there is no onset):
fx-tuner-master-reads-the-mix-and-leaves-the-project-alone checks that.
"""
import time

from reamo_client import Client, reaper, skip_unless_linux

skip_unless_linux("REAPER's inputs come from the container's JACK server")

from jack_feeder import Feeder  # noqa: E402  after the skip: Linux only
from tuner_phone import Phone, check_note, midi_note, watch  # noqa: E402

E2, G3 = 82.4069, 195.9977
DEVICE = "return {reaper.GetPlayState(), reaper.Audio_IsRunning()}"

problems = []


def stopped_and_running(when):
    play, running = reaper(DEVICE)
    if (play, running) != (0, 1):
        problems.append(f"{when}: play state {play}, device running {running}; want stopped, running")


def pluck(f, phone, notes, when):
    """Pluck `notes` ((input, freq), ...) together and read the master for
    2.4 s; returns the frequencies plucked."""
    stopped_and_running(when)
    phone.mark()
    fed = [f.pluck(ch, freq, 0.8, decay=2.0) for ch, freq in notes]
    watch([phone], 2.4)
    stopped_and_running(when)
    return fed


def monitor_guitar(on):
    reaper(f"reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, 1), 'I_RECMON', {on})")


with Client() as c, Feeder() as f:
    f.wait_connected()
    c.wait_event("trackSkeleton")
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    master = Phone(c, "master")
    r = master.subscribe("master")
    assert r["success"], r
    # A second of quiet, as a player opening the tuner before plucking: the
    # analyser learns the noise floor while nothing shows.
    watch([master], 1.0)

    for k in range(2):
        when = f"Guitar alone, pluck {k + 1}"
        (fed,) = pluck(f, master, [(1, 220.0)], when)
        print(f"--- {when}: A3 {fed:.4f} Hz on input 2")
        before = len(problems)
        check_note(master, fed, problems, min_readings=3, never=(midi_note(E2),), alone=True)
        problems[before:] = [f"{when}: {p}" for p in problems[before:]]

    # Each switch waits out the last pluck's tail (60 dB down in 2 s), so
    # what the master shows next is the next pluck's alone.
    monitor_guitar(0)
    watch([master], 1.5)
    pluck(f, master, [(1, 220.0)], "Guitar not monitoring")
    shown = master.pitched()
    print(f"--- Guitar not monitoring: {len(shown)} pitched readings")
    if shown:
        problems.append(f"Guitar not monitoring: the master showed {len(shown)} notes, "
                        f"from audio that reaches no output: {shown[:3]}")
    monitor_guitar(1)
    watch([master], 1.5)

    several = 0
    for k in range(2):
        when = f"Bass and Guitar together, pluck {k + 1}"
        fb, fg = pluck(f, master, [(0, E2), (1, G3)], when)
        got = master.pitched()
        flagged = [p for p in master.since if p.get("multiple")]
        several += len(flagged)
        print(f"--- {when}: E2 {fb:.4f} Hz on input 1, G3 {fg:.4f} Hz on input 2; "
              f"{len(master.since)} readings, pitched {[(p['note'], p['freq'], p.get('stable')) for p in got][:8]}, "
              f"{len(flagged)} flagged multiple")
        played = (midi_note(fb), midi_note(fg))
        wrong = [(p["note"], p["freq"]) for p in got if p.get("stable") and p["note"] not in played]
        if wrong:
            problems.append(f"{when}: stable readings of a note neither instrument plays: {wrong[:5]}")
        unflagged = [(p["note"], p["freq"]) for p in got if p.get("stable") and not p.get("multiple")]
        if unflagged:
            problems.append(f"{when}: stable readings with two notes sounding, not flagged multiple: {unflagged[:5]}")
    if several == 0:
        problems.append("two notes plucked together twice, and no reading was flagged multiple")

    assert c.command("tuner/unsubscribe")["success"]

assert not problems, "\n".join(problems)
print("ok: the master tuner hears monitored inputs while stopped, and flags two notes as several")
