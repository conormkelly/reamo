-- REAPER on JACK with 2 fed inputs (`jack-inputs`), and a track for each
-- record input the tuner can't read, plus one it can.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local function track(name, rec_input)
  local t = harness.track(name)
  reaper.SetMediaTrackInfo_Value(t, "I_RECINPUT", rec_input)
end
track("No input", -1)
track("MIDI", 4096 + 63 * 32)       -- all MIDI devices (63 << 5), all channels
track("Input 5", 4)                  -- a 2-input device has no input 5
track("Stereo 2/3", 1024 + 1)        -- its second channel isn't there
track("ReaRoute", 512)
track("Multichannel", 2048)
track("Guitar", 1)
harness.ready()
