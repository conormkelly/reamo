-- reamo_internal_fetch_peaks.lua
-- INTERNAL: Used by Reamo extension for peak data fetching.
-- This script is called synchronously by the Zig extension via Main_OnCommand.
-- Running manually does nothing. Delete = waveforms disabled.

-- Check if there's a pending request
local valid = reaper.Reamo_GetPeakRequestValid()
if valid ~= 1 then return end

-- Get request parameters via individual getter functions
local track_idx = reaper.Reamo_GetPeakRequestTrackIdx()
local item_idx = reaper.Reamo_GetPeakRequestItemIdx()
local start_time = reaper.Reamo_GetPeakRequestStartTime()
local end_time = reaper.Reamo_GetPeakRequestEndTime()
local peakrate = reaper.Reamo_GetPeakRequestPeakrate()

-- Validate peakrate
if peakrate <= 0 or peakrate > 1000 then
    reaper.Reamo_SetPeakRequestComplete(-11) -- Invalid peakrate
    return
end

-- Get track by index (0 = first user track, not master)
-- Master track doesn't have audio items with peaks anyway
local track = reaper.GetTrack(0, track_idx)
if not track then
    reaper.Reamo_SetPeakRequestComplete(-1) -- Track not found
    return
end

-- Get item by index on that track
local item = reaper.GetTrackMediaItem(track, item_idx)
if not item then
    reaper.Reamo_SetPeakRequestComplete(-2) -- Item not found
    return
end

-- Get active take
local take = reaper.GetActiveTake(item)
if not take then
    reaper.Reamo_SetPeakRequestComplete(-3) -- No active take
    return
end

-- Check if take is MIDI (no peaks for MIDI)
if reaper.TakeIsMIDI(take) then
    reaper.Reamo_SetPeakRequestComplete(-4) -- MIDI take, no peaks
    return
end

-- Always request 2 channels. GetMediaSourceNumChannels is unreliable on ARM64 -
-- it returns wrong values in certain states (even via Lua bindings). For mono
-- sources, the second channel will be zeros/duplicates, which is fine.
local channels = 2

-- Calculate number of peaks from time range
local duration = end_time - start_time
if duration <= 0 then
    reaper.Reamo_SetPeakRequestComplete(-5) -- Invalid time range
    return
end

local num_peaks = math.ceil(duration * peakrate)
if num_peaks <= 0 or num_peaks > 100000 then
    reaper.Reamo_SetPeakRequestComplete(-6) -- Invalid peak count
    return
end

-- Allocate buffer: channels * num_peaks * 2 (max + min for each)
local buf_size = channels * num_peaks * 2
local arr = reaper.new_array(buf_size)
arr.clear()

-- Get item position for diagnostics
local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
local take_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")

-- Get source for potential peak building
local source = reaper.GetMediaItemTake_Source(take)
if not source then
    reaper.ShowConsoleMsg("[Reamo] ERROR: source is nil!\n")
    reaper.Reamo_SetPeakRequestComplete(-7)
    return
end

-- Traverse to root source (handles section sources, reversed sources, etc.)
local root_source = source
local parent = reaper.GetMediaSourceParent(root_source)
while parent do
    root_source = parent
    parent = reaper.GetMediaSourceParent(root_source)
end

-- Get source info for diagnostics (use root source for accurate info)
local source_len = reaper.GetMediaSourceLength(root_source)
local source_channels = reaper.GetMediaSourceNumChannels(root_source)
local source_samplerate = reaper.GetMediaSourceSampleRate(root_source)

-- If root source also has invalid properties, the file may not be loaded yet
if source_len == 0 or source_samplerate == 0 then
    -- Signal retry-needed instead of hard failure
    reaper.Reamo_SetPeakRequestComplete(-8) -- Source not ready
    return
end

-- Try a simple test: get peaks for just a tiny portion
local test_arr = reaper.new_array(16)
test_arr.clear()
local test_result = reaper.GetMediaItemTake_Peaks(take, 1.0, item_pos, 2, 4, 0, test_arr)
local test_peaks = test_result & 0xFFFFF

-- Fetch peaks using REAPER's API
-- Note: start_time must be PROJECT time (timeline position), not item-relative
local result = reaper.GetMediaItemTake_Peaks(take, peakrate, start_time, channels, num_peaks, 0, arr)

-- Parse result: low 20 bits = actual peak count, bits 20-23 = mode
local actual_peaks = result & 0xFFFFF
local mode = (result >> 20) & 0xF

-- If we got 0 peaks, try building peaks first then retry
if actual_peaks == 0 and root_source then
    -- Build peaks on root source (mode 1 = fast/incremental, mode 0 = full)
    local build_start = reaper.time_precise()
    local build_result = reaper.PCM_Source_BuildPeaks(root_source, 1) -- Try fast mode first
    local build_time = (reaper.time_precise() - build_start) * 1000

    -- Clear and retry
    arr.clear()
    result = reaper.GetMediaItemTake_Peaks(take, peakrate, start_time, channels, num_peaks, 0, arr)
    actual_peaks = result & 0xFFFFF
    mode = (result >> 20) & 0xF

    -- If fast mode didn't help, try full build
    if actual_peaks == 0 then
        build_start = reaper.time_precise()
        build_result = reaper.PCM_Source_BuildPeaks(root_source, 0) -- Full build
        build_time = build_time + (reaper.time_precise() - build_start) * 1000

        arr.clear()
        result = reaper.GetMediaItemTake_Peaks(take, peakrate, start_time, channels, num_peaks, 0, arr)
        actual_peaks = result & 0xFFFFF
        mode = (result >> 20) & 0xF
    end

    if actual_peaks == 0 then
        reaper.ShowConsoleMsg(string.format(
            "[Reamo] DIAG: build_time=%.1fms source_len=%.2f source_ch=%d source_sr=%d test_peaks=%d build=%s\n",
            build_time, source_len, source_channels, source_samplerate, test_peaks, tostring(build_result)
        ))
    elseif build_time > 10 then
        -- Log if build took significant time
        reaper.ShowConsoleMsg(string.format("[Reamo] BuildPeaks took %.1fms\n", build_time))
    end
end

if actual_peaks == 0 then
    -- Debug: log why we got 0 peaks even after building
    reaper.ShowConsoleMsg(string.format(
        "[Reamo] GetMediaItemTake_Peaks returned 0! item_pos=%.2f item_len=%.2f take_offset=%.2f req_start=%.2f req_end=%.2f peakrate=%.2f channels=%d num_peaks=%d result=%d\n",
        item_pos, item_len, take_offset, start_time, end_time, peakrate, channels, num_peaks, result
    ))
    reaper.Reamo_SetPeakRequestComplete(0) -- No peaks returned
    return
end

-- Convert to table for packing
local t = arr.table()
local n = #t

if n == 0 then
    reaper.Reamo_SetPeakRequestComplete(0)
    return
end

-- Optimized batched packing with cached format strings
-- BATCH=1000 is optimal based on benchmarks (~1.7x faster than BATCH=100)
local FMT_1000 = string.rep("<d", 1000)
local BATCH = 1000
local parts = {}

for i = 1, n, BATCH do
    local remaining = n - i + 1
    if remaining >= BATCH then
        parts[#parts + 1] = string.pack(FMT_1000, table.unpack(t, i, i + BATCH - 1))
    else
        -- For remainder, build format string on demand
        parts[#parts + 1] = string.pack(string.rep("<d", remaining), table.unpack(t, i, n))
    end
end

local packed = table.concat(parts)

-- Transfer to extension
reaper.Reamo_ReceivePeakData(packed, n)

-- Signal completion with peak count
reaper.Reamo_SetPeakRequestComplete(n)
