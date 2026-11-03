"""The tuner sends a reading that holds again every 250 ms, so a phone can
tell it from a connection, or a REAPER, that has stopped sending: the page
takes a reading as gone after 750 ms without an event and stops showing
it, green included.

REAPER runs on JACK with 2 inputs, Bass (input 1) and Guitar (input 2),
both armed and monitoring through the master, the transport stopped. Two
phones tune the master.
- Silence for 3 s: each phone is sent the same event over and over, at
  3 times a second or more, never more than GAP_S apart. Sent only on a change, it
  would be sent once.
- Phone 2 leaves: phone 1's resends go on.
- E2 and G3 together for 2 s (the analyser's "several notes": see
  fx-tuner-master-hears-monitored-inputs-while-stopped): events keep coming
  no more than GAP_S apart while the notes sound, so "Several notes"
  doesn't go stale on the screen, and `multiple` is in more than one event
  (sent only on a change, a `multiple` that held was in one).
"""
import json
import time

from reamo_client import Client, skip_unless_linux

skip_unless_linux("REAPER's inputs come from the container's JACK server")

from jack_feeder import Feeder  # noqa: E402  after the skip: Linux only
from tuner_phone import Phone, watch  # noqa: E402

E2, G3 = 82.4069, 195.9977
# The page's stale time is 750 ms. A resend is due 250 ms after the last
# send and goes at the next 30 Hz poll (about 267 ms apart); Phone reads in
# turns of 20-50 ms. Under the page's limit, with room for a main-thread
# hiccup: jackd runs here without realtime scheduling.
GAP_S = 0.7

problems = []


def gaps(phone):
    t = phone.since_at
    return [b - a for a, b in zip(t, t[1:])]


def silence_resent(phone, seconds, when):
    """Since mark(): the same event, again and again, no more than GAP_S apart."""
    got = phone.since
    distinct = {json.dumps(p, sort_keys=True) for p in got}
    widest = max(gaps(phone), default=float("inf"))
    print(f"{when}, {phone.name}: {len(got)} events in {seconds} s, {len(distinct)} distinct, widest gap {widest:.3f} s")
    # 4 a second; 3 a second allows for the poll grid and the reads' timing.
    want = int(3 * seconds)
    if len(got) < want:
        problems.append(f"{when}, {phone.name}: {len(got)} events in {seconds} s of silence, want at least {want}")
    if len(distinct) != 1:
        problems.append(f"{when}, {phone.name}: silence changed the event: {sorted(distinct)[:3]}")
    if widest > GAP_S:
        problems.append(f"{when}, {phone.name}: {widest:.3f} s between events, more than {GAP_S} s")


with Feeder() as f, Client() as a, Client() as b:
    f.wait_connected()
    a.wait_event("trackSkeleton")
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    p1, p2 = Phone(a, "phone 1"), Phone(b, "phone 2")
    for p in (p1, p2):
        assert p.subscribe("master")["success"]
    watch([p1, p2], 1.0)  # the analyser learns the noise floor

    for p in (p1, p2):
        p.mark()
    watch([p1, p2], 3.0)
    for p in (p1, p2):
        silence_resent(p, 3.0, "silence, two phones")

    assert b.command("tuner/unsubscribe")["success"]
    p1.mark()
    watch([p1, p2], 2.0)
    silence_resent(p1, 2.0, "silence, phone 2 gone")

    for k in range(2):
        when = f"E2 and G3 together, time {k + 1}"
        p1.mark()
        f.tone(0, E2, 0.5)
        f.tone(1, G3, 0.5)
        watch([p1], 2.0)
        f.silence(0)
        f.silence(1)
        flagged = [p for p in p1.since if p.get("multiple")]
        widest = max(gaps(p1), default=float("inf"))
        print(f"--- {when}: {len(p1.since)} events, {len(flagged)} flagged multiple, widest gap {widest:.3f} s")
        if len(flagged) < 2:
            problems.append(f"{when}: {len(flagged)} events flagged multiple in 2 s of two notes, want more than one")
        if widest > GAP_S:
            problems.append(f"{when}: {widest:.3f} s between events while two notes sound, more than {GAP_S} s")
        watch([p1], 1.0)

    assert a.command("tuner/unsubscribe")["success"]

assert not problems, "\n".join(problems)
print("ok: the tuner sends a reading that holds again every 250 ms, several notes included")
