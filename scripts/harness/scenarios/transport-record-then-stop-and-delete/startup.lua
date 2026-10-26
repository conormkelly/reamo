-- One armed track recording under REAPER's dummy audio device (no input
-- channels, so it records its own output) into /dev/shm. REAPER's modal
-- low-disk-space warning and its save/delete prompt after recording are off
-- (boot.sh's reaper.ini): either would block the main thread invisibly.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
reaper.GetSetProjectInfo_String(0, "RECORD_PATH", harness.mkdir("/dev/shm/rec"), true)
local t = harness.track("Guitar DI")
reaper.SetMediaTrackInfo_Value(t, "I_RECMODE", 1)  -- record output (stereo)
reaper.SetMediaTrackInfo_Value(t, "I_RECARM", 1)
harness.log("diskcheck=%s promptendrec=%s", harness.config("diskcheck"), harness.config("promptendrec"))
harness.ready()
