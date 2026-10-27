"""A pad roll held up by a Wi-Fi stall arrives whole when the phone reconnects.

When a phone's Wi-Fi stalls mid-roll, the hits queue on the phone and land
together when it recovers. Every note-on and note-off must reach REAPER: a
dropped note-off leaves a note hanging on the synth. A JSFX on an armed
MIDI track counts what REAPER delivers, so REAPER is the oracle.
"""
import time

from reamo_client import Client, reaper

HITS = 300

PROBE = r"""desc:REAmo harness MIDI counter
slider1:0<0,100000,1>notes on
slider2:0<0,100000,1>notes off
@block
while (midirecv(ofs, m1, m2, m3)) (
  s = m1 & 0xF0;
  s == 0x90 && m3 > 0 ? slider1 += 1 : (s == 0x80 || s == 0x90) ? slider2 += 1;
  midisend(ofs, m1, m2, m3);
);
"""

reaper(f"""
local dir = reaper.GetResourcePath() .. "/Effects/reamo_harness"
reaper.RecursiveCreateDirectory(dir, 0)
local f = assert(io.open(dir .. "/midi_counter", "w"))
f:write([==[{PROBE}]==])
f:close()
reaper.InsertTrackAtIndex(0, true)
local tr = reaper.GetTrack(0, 0)
reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Pads", true)
reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", 4096 | (63 << 5))
reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)
reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
assert(reaper.TrackFX_AddByName(tr, "JS:reamo_harness/midi_counter", false, -1) == 0)
""")

COUNTS = """
local tr = reaper.GetTrack(0, 0)
return {math.floor(reaper.TrackFX_GetParam(tr, 0, 0) + 0.5), math.floor(reaper.TrackFX_GetParam(tr, 0, 1) + 0.5)}
"""

with Client() as c:
    c.wait_event("trackSkeleton")
    c.drain(0.5)
    # The stalled hits land together: every message written back to back.
    for i in range(HITS):
        note = 36 + i % 4
        c.fire("midi/noteOn", note=note, velocity=100, channel=9)
        c.fire("midi/noteOn", note=note, velocity=0, channel=9)
    deadline = time.time() + 10
    while True:
        c.drain(0.2)
        got = reaper(COUNTS)
        if got == [HITS, HITS] or time.time() > deadline:
            break
    # A refused or dropped hit shows here as a missing count.
    print(f"REAPER saw {got[0]} note-ons and {got[1]} note-offs of {HITS}")
    assert got == [HITS, HITS], f"REAPER saw {got}, the phone sent {HITS} of each"
    # The connection still answers an awaited command.
    assert c.command("transport/seek", position=0.0)["success"]

assert reaper("return true")
