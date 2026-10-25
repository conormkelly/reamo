"""A track name with a newline, quotes, a leading '<' or a backtick (any client can
send these) does not corrupt the saved project: save, reopen, same tracks."""
from reamo_client import Client, reaper

NAMES = """
local t = {}
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  local _, n = reaper.GetTrackName(tr)
  t[#t + 1] = {n, reaper.CountTrackMediaItems(tr)}
end
return t
"""
PATH = "/tmp/reamo-rename-save.RPP"

with Client() as c:
    c.wait_event("trackSkeleton")
    evil = 'Lead\nVox "x" `y` \'z\''
    assert c.command("track/rename", trackIdx=1, name=evil)["success"]
    assert c.command("track/rename", trackIdx=2, name="<TRACK\n>")["success"]
    before = reaper(NAMES)
    reaper(f'harness.save_as("{PATH}")')
    rpp_names = reaper(f"""
local t = {{}}
for line in io.lines("{PATH}") do if line:match("^%s*NAME ") then t[#t + 1] = line end end
return t
""")
    print("stored:", before)
    print(".rpp NAME lines:", rpp_names)
    reaper(f'reaper.Main_openProject("noprompt:{PATH}")')
    after = reaper(NAMES)
    print("reopened:", after)
    assert len(after) == len(before) and [x[1] for x in after] == [x[1] for x in before], \
        f"project changed shape after save/reopen: {before} -> {after}"
