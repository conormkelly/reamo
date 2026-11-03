-- REAPER on JACK with 2 fed inputs (this scenario's `jack-inputs`). Saves
-- /tmp/rec-session/rec.RPP, recording into /tmp/rec, with three tracks:
--   "Guitar": armed on mono input 1, an item at 4 s;
--   "Vox lanes": fixed lanes (REAPER 7), lane 0 playing, an item on each of
--     its two lanes at 4 s and one with a custom colour on lane 0 at 8 s,
--     armed on mono input 2;
--   "Keys": not armed, an item at 0 s, under where the takes land.
-- The test opens the saved project afresh for each way of recording, so
-- each starts from the same project and undo history.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
harness.mkdir("/tmp/rec-session")
harness.begin_project("/tmp/rec-session/rec.RPP")
reaper.GetSetProjectInfo_String(0, "RECORD_PATH", harness.mkdir("/tmp/rec"), true)
local wav = harness.wav("/tmp/rec-session/existing.wav", 3, 220, 1)

local gtr = harness.track("Guitar")
harness.audio_item(gtr, 4, wav)
reaper.SetMediaTrackInfo_Value(gtr, "I_RECINPUT", 0)
reaper.SetMediaTrackInfo_Value(gtr, "I_RECARM", 1)

local vox = harness.track("Vox lanes")
reaper.SetMediaTrackInfo_Value(vox, "I_FREEMODE", 2)
reaper.SetMediaTrackInfo_Value(vox, "I_NUMFIXEDLANES", 2)
for lane = 0, 1 do
  local it = harness.audio_item(vox, 4, wav)
  reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", lane)
end
local coloured = harness.audio_item(vox, 8, wav)
reaper.SetMediaItemInfo_Value(coloured, "I_FIXEDLANE", 0)
reaper.SetMediaItemInfo_Value(coloured, "I_CUSTOMCOLOR", 0x1000000 | 0x3366CC)
reaper.SetMediaTrackInfo_Value(vox, "C_LANEPLAYS:0", 1)
reaper.SetMediaTrackInfo_Value(vox, "I_RECINPUT", 1)
reaper.SetMediaTrackInfo_Value(vox, "I_RECARM", 1)

local keys = harness.track("Keys")
harness.audio_item(keys, 0, wav)

reaper.Main_OnCommand(40289, 0) -- Item: Unselect all items
harness.save_project("/tmp/rec-session/rec.RPP")
harness.log("GetNumAudioInputs=%d", reaper.GetNumAudioInputs())
harness.ready()
