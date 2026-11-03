-- Takes at other playrates, with and without preserve pitch.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local wav = harness.staircase_wav("/tmp/staircase.wav")
local function rated(name, rate, preserve, len)
  local _, take = harness.waveform_item(name, wav, 1, len)
  reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", rate)
  reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", preserve and 1 or 0)
end
rated("rate 2", 2, false, 4)
rated("rate 2, preserve pitch", 2, true, 4)
rated("rate 0.5, preserve pitch", 0.5, true, 8)
harness.ready()
