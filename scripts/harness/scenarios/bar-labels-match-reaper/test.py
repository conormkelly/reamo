"""Bar.beat labels the UI shows (markers, regions, timeToBeats) match REAPER's own."""
from reamo_client import Client, oracle

truth = oracle()

def reaper_label(s):
    # format_timestr_pos(.., 2) gives "bar.beat.hundredths"; REAmo shows "bar.beat.ticks"
    # with ticks in hundredths too, so the strings compare directly.
    return s.strip()

with Client() as c:
    markers = {m["id"]: m for m in c.wait_event("markers")["payload"]["markers"]}
    regions = c.wait_event("regions")["payload"]["regions"]
    bad = []
    n = sum(1 for k in truth if k.startswith("marker"))
    for i in range(1, n + 1):
        want = reaper_label(truth[f"marker{i}"])
        got_marker = markers[i]["positionBars"]
        got_ttb = c.command("tempo/timeToBeats", time=float(truth[f"time{i}"]))["payload"]["bars"]
        flag = "" if got_marker == want == got_ttb else "   <-- MISMATCH"
        print(f"  t={float(truth[f'time{i}']):8.4f}  REAPER {want:>9}  marker {got_marker:>9}  timeToBeats {got_ttb:>9}{flag}")
        if flag:
            bad.append(i)
    r = regions[0]
    for key, field in (("region1_start", "startBars"), ("region1_end", "endBars")):
        if r[field] != reaper_label(truth[key]):
            bad.append(f"{field}: REAPER {truth[key]} vs {r[field]}")
    assert not bad, f"{len(bad)} labels differ from REAPER: {bad}"
