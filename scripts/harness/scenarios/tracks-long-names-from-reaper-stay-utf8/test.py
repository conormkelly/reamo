"""Long non-ASCII track names typed in REAPER reach clients as valid UTF-8 text
frames (a browser fails the whole WebSocket on an invalid one), shortened if at
all only on a character boundary."""
from reamo_client import Client, reaper


class StrictClient(Client):
    bad_frames = []

    def _recv_frame(self):
        opcode, payload = super()._recv_frame()
        if opcode == 1:
            try:
                payload.decode("utf-8")
            except UnicodeDecodeError as e:
                kind = payload[:60].split(b'"event":"')[-1].split(b'"')[0]
                self.bad_frames.append(f"{kind.decode()} frame: {e.reason} at byte {e.start}: "
                                       f"{payload[max(0, e.start - 12):e.start + 4]!r}")
                payload = payload.decode("utf-8", "replace").encode("utf-8")
        return opcode, payload


names = reaper("""
local t = {}
for i = 0, reaper.CountTracks(0) - 1 do local _, n = reaper.GetTrackName(reaper.GetTrack(0, i)); t[#t + 1] = n end
return t
""")

with StrictClient() as c:
    skel = [t["n"] for t in c.wait_event("trackSkeleton")["payload"]["tracks"]][1:]
    assert c.command("track/subscribe", range={"start": 0, "end": 5})["success"]
    tracks = [t["name"] for t in c.wait_event("tracks")["payload"]["tracks"] if t["idx"] > 0]
    c.drain(1.5)
    problems = list(StrictClient.bad_frames)
    for i, full in enumerate(names):
        for where, shown in (("skeleton", skel[i]), ("tracks", tracks[i])):
            ok = full.startswith(shown) and "�" not in shown
            print(f"track {i + 1} {where:>8}: REAPER {len(full.encode())} B, shown {len(shown.encode())} B, ok={ok}")
            if not ok:
                problems.append(f"track {i + 1} {where}: shows {shown[-6:]!r}, not a prefix of REAPER's name")
    assert not problems, "\n".join(problems[:8])
