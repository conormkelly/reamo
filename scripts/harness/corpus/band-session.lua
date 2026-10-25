-- A typical small band session, the shape of the larger projects REAmo users
-- run: 48 kHz, 4/4 at 100 BPM, project starting at measure -5, timebase
-- "beats (position only)"; ~16 tracks in folders; multi-take audio and MIDI;
-- stock Cockos plugins plus one plugin that isn't installed (offline); an FX
-- container, input FX, take FX and master FX; sends, a bus, hardware outputs;
-- a volume envelope; a fixed-lane comp track; markers, regions, item notes.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")

local dir = "/tmp/corpus/band-session"
os.execute("mkdir -p " .. dir .. "/Media")
local function wav(name, secs, freq, ch) return harness.wav(dir .. "/Media/" .. name, secs, freq, ch) end

reaper.SetCurrentBPM(0, 100, false)
local bar = 60 / 100 * 4 -- 2.4 s

local kick_wav = wav("kick.wav", 4, 55, 1)
local snare_wav = wav("snare.wav", 4, 180, 1)
local oh_wav = wav("overheads.wav", 8, 330, 2)
local bass_wav = wav("bass.wav", 8, 82.41, 1) -- E2: a tuner target
local gtr1_wav = wav("gtr-take1.wav", 6, 196, 2)
local gtr2_wav = wav("gtr-take2.wav", 6, 247, 2)
local gtr3_wav = wav("gtr-take3.wav", 6, 294, 2)
local vox_wav = {wav("vox-lane1.wav", 5, 440, 1), wav("vox-lane2.wav", 5, 445, 1), wav("vox-lane3.wav", 5, 435, 1)}

local function track(name, depth)
  local t = harness.track(name)
  if depth then reaper.SetMediaTrackInfo_Value(t, "I_FOLDERDEPTH", depth) end
  return t
end

-- Drums folder
local drums = track("Drums", 1)
reaper.SetMediaTrackInfo_Value(drums, "I_CUSTOMCOLOR", reaper.ColorToNative(200, 60, 60) | 0x1000000)
local kick = track("Kick")
local snare = track("Snare")
local oh = track("Overheads", -1)
for i = 0, 3 do harness.audio_item(kick, i * bar, kick_wav, bar) end
for i = 0, 3 do harness.audio_item(snare, i * bar, snare_wav, bar) end
harness.audio_item(oh, 0, oh_wav)
reaper.TrackFX_AddByName(kick, "ReaEQ", false, -1)
reaper.TrackFX_AddByName(kick, "ReaGate", false, -1)
reaper.TrackFX_AddByName(snare, "ReaComp", false, -1)
reaper.TrackFX_AddByName(drums, "ReaComp", false, -1)

local bass = track("Bass DI")
harness.audio_item(bass, 0, bass_wav)
reaper.TrackFX_AddByName(bass, "ReaEQ", false, -1)
reaper.TrackFX_AddByName(bass, "JS: Utility/volume", false, -1)

-- Guitar with three takes on one item, a take FX and an FX container.
local gtr = track("Guitar")
local gitem, gtake = harness.audio_item(gtr, bar, gtr1_wav)
harness.add_take(gitem, gtr2_wav, "gtr take 2")
harness.add_take(gitem, gtr3_wav, "gtr take 3")
reaper.SetActiveTake(reaper.GetTake(gitem, 1))
reaper.TakeFX_AddByName(gtake, "ReaEQ", -1)
local container = reaper.TrackFX_AddByName(gtr, "Container", false, -1)
reaper.TrackFX_AddByName(gtr, "ReaDelay", false, -1)
reaper.GetSetMediaItemInfo_String(gitem, "P_NOTES", "Take 2 is the keeper.\nRedo the bridge.", true)
harness.oracle("gtr_container_idx", container)

-- Keys: MIDI into ReaSynth, plus a track whose plugin isn't installed here.
local keys = track("Keys")
reaper.TrackFX_AddByName(keys, "ReaSynth", false, -1)
harness.midi_item(keys, 0, 4 * bar, {{0, 1, 60}, {1, 1, 64}, {2, 1, 67}, {3, 1, 72}, {4, 4, 60, 80}})
harness.midi_item(keys, 4 * bar, 2 * bar, {{0, 2, 62}, {2, 2, 65}})
local pads = track("Pads (missing plugin)")
harness.midi_item(pads, 0, 4 * bar, {{0, 8, 48, 70}})
harness.track_chunk_append(pads, [[
<FXCHAIN
SHOW 0
LASTSEL 0
DOCKED 0
BYPASS 0 0 0
<VST "VSTi: Serum (Xfer Records)" Serum.so 0 "" 1397572658<5653545866724073657275>
ZmVyU+5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAAAEAAAAAAAAQAAAAAAAAA=
AAAQAAAA
>
FLOATPOS 0 0 0 0
FXID {11111111-2222-3333-4444-555555555555}
WAK 0 0
>]])

-- Lead vocal: fixed lanes, three recorded lanes, lane 0 playing. Input FX.
local vox = track("Lead Vox")
reaper.SetMediaTrackInfo_Value(vox, "I_FREEMODE", 2)
reaper.SetMediaTrackInfo_Value(vox, "I_NUMFIXEDLANES", 3)
for lane = 0, 2 do
  local it = harness.audio_item(vox, bar * 2, vox_wav[lane + 1])
  reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", lane)
end
reaper.SetMediaTrackInfo_Value(vox, "C_LANEPLAYS:0", 1)
reaper.SetMediaTrackInfo_Value(vox, "I_RECARM", 1)
reaper.SetMediaTrackInfo_Value(vox, "I_RECMON", 1)
reaper.SetMediaTrackInfo_Value(vox, "I_RECINPUT", 0)
reaper.TrackFX_AddByName(vox, "ReaEQ", true, -1) -- input FX
reaper.TrackFX_AddByName(vox, "ReaComp", false, -1)

local bv = track("BVs")
harness.audio_item(bv, bar * 2, vox_wav[2])
reaper.SetMediaTrackInfo_Value(bv, "D_VOL", 0.5)
reaper.SetMediaTrackInfo_Value(bv, "D_PAN", -0.3)
reaper.SetMediaTrackInfo_Value(bv, "B_MUTE", 1)

-- Buses: reverb and delay sends; a hidden click track; a print track with a hardware output.
local verb = track("Verb Bus")
reaper.TrackFX_AddByName(verb, "ReaVerbate", false, -1)
local dly = track("Delay Bus")
reaper.TrackFX_AddByName(dly, "ReaDelay", false, -1)
for _, src in ipairs({vox, bv, gtr, snare}) do
  local s = reaper.CreateTrackSend(src, verb)
  reaper.SetTrackSendInfo_Value(src, 0, s, "D_VOL", 0.3)
end
local s = reaper.CreateTrackSend(vox, dly)
reaper.SetTrackSendInfo_Value(vox, 0, s, "I_SENDMODE", 3)
local click = track("Click")
reaper.SetMediaTrackInfo_Value(click, "B_SHOWINMIXER", 0)
reaper.SetMediaTrackInfo_Value(click, "B_SHOWINTCP", 0)
local print_trk = track("Headphone mix")
reaper.CreateTrackSend(print_trk, nil) -- hardware output
reaper.SetMediaTrackInfo_Value(print_trk, "B_MAINSEND", 0)
local empty = track("") -- unnamed track, as REAPER shows "Track 15"

-- Master: FX and a hardware output.
local master = reaper.GetMasterTrack(0)
reaper.TrackFX_AddByName(master, "ReaLimit", false, -1)

-- Volume automation on the bass.
reaper.SetOnlyTrackSelected(bass)
reaper.Main_OnCommand(40406, 0) -- Track: Toggle track volume envelope visible
local env = reaper.GetTrackEnvelopeByName(bass, "Volume")
if env then
  reaper.InsertEnvelopePoint(env, 0, 716.2, 0, 0, false, true)
  reaper.InsertEnvelopePoint(env, 4 * bar, 400, 0, 0, false, true)
  reaper.Envelope_SortPoints(env)
end
reaper.SetOnlyTrackSelected(vox)

-- Arrangement.
reaper.AddProjectMarker2(0, true, 0, 4 * bar, "Intro", 1, 0)
reaper.AddProjectMarker2(0, true, 4 * bar, 8 * bar, "Verse 1", 2, reaper.ColorToNative(60, 120, 200) | 0x1000000)
reaper.AddProjectMarker2(0, true, 8 * bar, 10 * bar, "Chorus", 3, 0)
reaper.AddProjectMarker2(0, false, 2 * bar, 0, "Vox in", 1, 0)
reaper.AddProjectMarker2(0, false, 6 * bar, 0, "Fill", 2, 0)
reaper.AddProjectMarker2(0, false, 9 * bar, 0, "Drop", 5, 0) -- gap in numbering, as after deletes
reaper.GetSetProjectNotes(0, true, "Band session\nTODO: comp vox, print stems")

harness.save_project(dir .. "/band-session.RPP", {PROJOFFS = "0 -5 0", TIMELOCKMODE = "2", SAMPLERATE = "48000 1 0"})
reaper.Main_OnCommand(40859, 0) -- File: New project tab (empty), so the test opens the session
