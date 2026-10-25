-- Names typed in REAPER itself that are longer than the extension's 128-byte name buffers.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
harness.track(string.rep("ギ", 50))          -- 150 bytes, 3-byte characters
harness.track(string.rep("é", 70))           -- 140 bytes, 2-byte characters
harness.track("a" .. string.rep("é", 70))    -- same, odd byte offset
harness.track(string.rep("x", 126) .. "🎤")  -- 4-byte character across byte 127
harness.track("Short")
harness.ready()
