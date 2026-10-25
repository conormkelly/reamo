"""The input sheet's choices (sent exactly as InputSelectionSheet.tsx sends them,
awaited, by track GUID) land in REAPER's I_RECINPUT and read back via getInput."""
from reamo_client import Client, reaper

RECINPUT = "return math.floor(reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, %d), 'I_RECINPUT'))"

with Client() as c:
    g = [t["g"] for t in c.wait_event("trackSkeleton")["payload"]["tracks"]]
    c.drain(1.2)  # GUIDs resolve after the first 1 Hz tick (tracks-guid-commands-right-after-connect)
    audio = c.command("input/enumerateAudio")
    midi = c.command("input/enumerateMidi")
    print("enumerateAudio:", str(audio.get("payload"))[:200])
    print("enumerateMidi:", str(midi.get("payload"))[:200])
    assert audio["success"] and midi["success"], (audio, midi)

    cases = [
        # (what the user picks, params as the sheet sends them, REAPER I_RECINPUT wanted)
        ("Input 1 (mono)", dict(trackGuid=g[1], inputType="audio", channel=0, stereo=False), 0),
        ("Input 1/2 (stereo)", dict(trackGuid=g[1], inputType="audio", channel=0, stereo=True), 1024),
        ("Input 3/4 (stereo)", dict(trackGuid=g[1], inputType="audio", channel=2, stereo=True), 1024 + 2),
        ("MIDI VKB, all channels", dict(trackGuid=g[2], inputType="midi", device=62, channel=0), 4096 + (62 << 5)),
        ("MIDI all devices, ch 10", dict(trackGuid=g[2], inputType="midi", device=63, channel=10), 4096 + 10 + (63 << 5)),
        ("No input", dict(trackGuid=g[1], inputType="none"), -1),
    ]
    problems = []
    for label, params, want in cases:
        r = c.command("track/setInput", **params)
        idx = g.index(params["trackGuid"])
        got = reaper(RECINPUT % (idx - 1))
        back = c.command("track/getInput", trackGuid=params["trackGuid"]).get("payload")
        print(f"{label:>24}: success={r['success']} REAPER I_RECINPUT={got} (want {want}) getInput={back}")
        if not r["success"] or got != want:
            problems.append(f"{label}: REAPER I_RECINPUT={got}, want {want} ({r.get('error')})")
        elif params["inputType"] == "audio" and back.get("stereo") != params["stereo"]:
            problems.append(f"{label}: getInput reports stereo={back.get('stereo')}")
    assert not problems, "\n".join(problems)
