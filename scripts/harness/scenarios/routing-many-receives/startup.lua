-- An orchestral template: one reverb bus fed by every instrument track.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local rev = harness.track("Hall Reverb")
local sections = {"Violins 1", "Violins 2", "Violas", "Celli", "Basses", "Flutes", "Oboes", "Clarinets",
                  "Bassoons", "Horns", "Trumpets", "Trombones", "Tuba", "Timpani", "Percussion", "Harp"}
local arts = {"Legato", "Spiccato", "Pizzicato", "Tremolo", "Staccato"}
local n = 0
for _, s in ipairs(sections) do
  for _, a in ipairs(arts) do
    local t = harness.track(s .. " - " .. a .. " (Close Mic)")
    reaper.CreateTrackSend(t, rev)
    n = n + 1
  end
end
harness.oracle("receives", reaper.GetTrackNumSends(rev, -1))
harness.ready()
