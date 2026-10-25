"""A real saved project with a non-default start measure: bar numbers match REAPER's own labels."""
from reamo_client import Client, open_project, reaper

print("dialogs:", open_project("/tmp/fixtures/test-project-1.RPP"))
# REAPER's own bar labels (measures.beats, project offset applied) at bar-length steps.
labels = {t: label for t, label in reaper("""
  local bar, out = 60 / reaper.Master_GetTempo() * 4, {}
  for i = 0, 6 do out[#out + 1] = {i * bar, reaper.format_timestr_pos(i * bar, "", 2)} end
  return out""")}
print("REAPER labels:", {round(t, 3): v for t, v in sorted(labels.items())})

with Client(timeout=8) as c:
    skel = c.wait_event("trackSkeleton")["payload"]["tracks"]
    print(f"tracks={len(skel) - 1}")
    mismatches = []
    for t, label in sorted(labels.items()):
        bar = int(label.split(".")[0])                # "-4.1.00" -> -4
        got = c.command("tempo/barsToTime", bar=bar)["payload"]["time"]
        if abs(got - t) > 1e-3:
            mismatches.append(f"bar {bar}: REAPER labels t={t:.3f}s, barsToTime -> {got:.3f}s")
        beats = c.command("tempo/timeToBeats", time=t)["payload"]
        print(f"  t={t:7.3f}s REAPER '{label}'  barsToTime({bar})={got:7.3f}  timeToBeats={beats}")
    n = len(skel) - 1
    assert c.command("peaks/subscribe", range={"start": 1, "end": n},
                     viewport={"start": 0, "end": 30, "widthPx": 400})["success"]
    c.fire("transport/play"); c.drain(2); c.fire("transport/stop"); c.drain(1)
    assert not mismatches, "\n".join(mismatches)
