-- Items with 3 s fades in and out: linear, and curved shapes.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local wav = harness.staircase_wav("/tmp/staircase.wav")
local function faded(name, in_shape, out_shape)
  local it = harness.waveform_item(name, wav, 1, 8)
  reaper.SetMediaItemInfo_Value(it, "D_FADEINLEN", 3)
  reaper.SetMediaItemInfo_Value(it, "D_FADEOUTLEN", 3)
  reaper.SetMediaItemInfo_Value(it, "C_FADEINSHAPE", in_shape)
  reaper.SetMediaItemInfo_Value(it, "C_FADEOUTSHAPE", out_shape)
end
faded("linear fades", 0, 0)
faded("curved fades", 2, 3)
harness.ready()
