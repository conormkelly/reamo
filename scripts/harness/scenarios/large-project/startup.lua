-- A big session: 300 tracks, 2,000 items, 200 markers, 200 regions.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
for i = 1, 300 do
  local t = harness.track(string.format("Track %03d", i))
  if i <= 100 then
    for j = 0, 19 do harness.item(t, j * 2, 1.5) end
  end
end
for i = 0, 199 do
  reaper.AddProjectMarker(0, false, i * 3, 0, "Marker " .. i, -1)
  reaper.AddProjectMarker(0, true, i * 3, i * 3 + 2, "Region " .. i, -1)
end
harness.ready()
