-- Items whose level is changed by item volume, take volume, take polarity,
-- take pan, a take volume envelope, or the track's volume.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local wav = harness.staircase_wav("/tmp/staircase.wav")
local stereo = harness.staircase_wav("/tmp/staircase-stereo.wav", true)

local it, take, t = harness.waveform_item("item volume -6 dB", wav, 1, 8)
reaper.SetMediaItemInfo_Value(it, "D_VOL", 0.5)
it, take = harness.waveform_item("take volume -6 dB", wav, 1, 8)
reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", 0.5)
it, take = harness.waveform_item("item and take -6 dB", wav, 1, 8)
reaper.SetMediaItemInfo_Value(it, "D_VOL", 0.5)
reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", 0.5)
it, take = harness.waveform_item("take polarity flipped", wav, 1, 8)
reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", -1)
it, take, t = harness.waveform_item("track volume -6 dB", wav, 1, 8)
reaper.SetMediaTrackInfo_Value(t, "D_VOL", 0.5)

-- A take volume envelope from silence at the item's start to 0 dB at its end.
it, take = harness.waveform_item("take volume envelope", wav, 1, 8)
reaper.SelectAllMediaItems(0, false)
reaper.SetMediaItemSelected(it, true)
reaper.Main_OnCommand(40693, 0) -- Take: Toggle take volume envelope
reaper.SelectAllMediaItems(0, false)
local env = reaper.GetTakeEnvelopeByName(take, "Volume")
assert(env, "no take volume envelope")
local mode = reaper.GetEnvelopeScalingMode(env)
reaper.DeleteEnvelopePointRange(env, -1, 100)
reaper.InsertEnvelopePoint(env, 0, reaper.ScaleToEnvelopeMode(mode, 0), 0, 0, false, true)
reaper.InsertEnvelopePoint(env, 8, reaper.ScaleToEnvelopeMode(mode, 1), 0, 0, false, true)
reaper.Envelope_SortPoints(env)

it, take = harness.waveform_item("stereo, take pan hard left", stereo, 1, 8)
reaper.SetMediaItemTakeInfo_Value(take, "D_PAN", -1)
harness.waveform_item("stereo", stereo, 1, 8)
harness.ready()
