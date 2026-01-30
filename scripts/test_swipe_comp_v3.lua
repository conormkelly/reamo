-- Swipe Comp Test v3 - Razor Edit API
-- Uses P_RAZOREDITS_EXT + Action 42475 for proper comp area metadata
-- This should produce the orange highlights on source lanes

-- CONFIG
local TARGET_TRACK_IDX = 2  -- Track 3 (0-indexed)

-- Test swipes: lane index, start time, end time
-- NOTE: These are PRE-shift lane indices (before comp lane created)
-- The razor edit approach shouldn't shift lanes like 42652 does
local SWIPES = {
    { lane = 1, start_time = 3936.0, end_time = 4088.0 },   -- Q1 from lane 1
    { lane = 1, start_time = 4088.0, end_time = 4240.0 },   -- Q2 from lane 1
    { lane = 2, start_time = 4137.0, end_time = 4338.0 },   -- Overlaps Q2, from lane 2
    { lane = 2, start_time = 4338.0, end_time = 4544.0 },   -- Q4 from lane 2
}

local RUN_ALL_SWIPES = true
local TEST_SOURCE_INFERENCE = true  -- Test the comp source mapping
local TEST_RESIZE = true  -- Test resizing comp areas by direct manipulation

-- Get track
local track = reaper.GetTrack(0, TARGET_TRACK_IDX)
if not track then
    reaper.ShowMessageBox("Track not found!", "Error", 0)
    return
end

-- Check fixed lanes
local freemode = reaper.GetMediaTrackInfo_Value(track, "I_FREEMODE")
if freemode ~= 2 then
    reaper.ShowMessageBox("Track not in fixed lanes mode (I_FREEMODE=" .. freemode .. ")", "Error", 0)
    return
end

local numLanes = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES"))
reaper.ShowConsoleMsg("\n=== SWIPE COMP v3 (Razor Edit API) ===\n")
reaper.ShowConsoleMsg("Track: " .. (TARGET_TRACK_IDX + 1) .. ", Lanes: " .. numLanes .. "\n")

-- Helper: show state
local function showState(label)
    reaper.ShowConsoleMsg("--- " .. label .. " ---\n")
    local n = reaper.GetTrackNumMediaItems(track)
    for i = 0, n - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local lane = reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
        local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local plays = reaper.GetMediaItemInfo_Value(item, "C_LANEPLAYS")
        reaper.ShowConsoleMsg(string.format("  lane=%d pos=%.2f-%.2f plays=%d\n",
            lane, pos, pos + len, plays))
    end

    -- Also show current razor edit state
    local retval, razorStr = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS_EXT", "", false)
    if retval and razorStr ~= "" then
        reaper.ShowConsoleMsg("  Razor: " .. razorStr .. "\n")
    end
end

-- Helper: calculate lane Y bounds (normalized 0.0-1.0)
local function getLaneBounds(laneIndex, totalLanes)
    local laneHeight = 1.0 / totalLanes
    local topY = laneIndex * laneHeight
    local btmY = topY + laneHeight
    return topY, btmY
end

-- Helper: get source filename from item
local function getItemSourceFile(item)
    local take = reaper.GetActiveTake(item)
    if not take then return nil end
    local source = reaper.GetMediaItemTake_Source(take)
    if not source then return nil end
    local filename = reaper.GetMediaSourceFileName(source, "")
    return filename
end

-- Helper: infer which source lane a comp item came from
local function getCompSourceLane(compItem)
    local compTake = reaper.GetActiveTake(compItem)
    if not compTake then return nil, "no take" end

    local compSource = reaper.GetMediaItemTake_Source(compTake)
    if not compSource then return nil, "no source" end

    local compFile = reaper.GetMediaSourceFileName(compSource, "")
    local compOffset = reaper.GetMediaItemTakeInfo_Value(compTake, "D_STARTOFFS")
    local compPos = reaper.GetMediaItemInfo_Value(compItem, "D_POSITION")
    local compLen = reaper.GetMediaItemInfo_Value(compItem, "D_LENGTH")

    -- Search source lanes for matching audio
    local numItems = reaper.GetTrackNumMediaItems(track)
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local lane = math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE"))

        if lane > 0 then  -- Source lanes (not comp lane)
            local take = reaper.GetActiveTake(item)
            if take then
                local source = reaper.GetMediaItemTake_Source(take)
                if source then
                    local file = reaper.GetMediaSourceFileName(source, "")

                    if file == compFile then
                        -- Same source file - check if time ranges could match
                        local srcOffset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
                        local srcPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                        local srcLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

                        -- The comp item's offset should be within the source item's range
                        -- And the comp's position should overlap the source's position
                        local srcEndOffset = srcOffset + srcLen
                        local compEndOffset = compOffset + compLen

                        -- Check if the comp's audio range is within the source's audio range
                        if compOffset >= srcOffset - 0.01 and compEndOffset <= srcEndOffset + 0.01 then
                            -- Also verify time position overlap (accounting for offset differences)
                            local expectedSrcPos = compPos - (compOffset - srcOffset)
                            if math.abs(expectedSrcPos - srcPos) < 0.01 then
                                return lane, string.format("matched file=%s", file:match("[^/\\]+$") or file)
                            end
                        end
                    end
                end
            end
        end
    end
    return nil, "no match found"
end

-- Main swipe function using razor edit API
local function doSwipe(targetLane, startTime, endTime, swipeNum)
    reaper.ShowConsoleMsg(string.format("\n=== SWIPE %d: lane %d, %.1f-%.1f ===\n",
        swipeNum, targetLane, startTime, endTime))

    -- Get current lane count (may change after first comp)
    local currentLanes = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES"))
    reaper.ShowConsoleMsg(string.format("1. Current lane count: %d\n", currentLanes))

    -- Safety: deselect all items before razor operations (per research feedback)
    reaper.Main_OnCommand(40289, 0)  -- Unselect all items

    -- Calculate normalized Y bounds for target lane
    local topY, btmY = getLaneBounds(targetLane, currentLanes)
    reaper.ShowConsoleMsg(string.format("2. Lane %d bounds: topY=%.4f, btmY=%.4f\n", targetLane, topY, btmY))

    -- Create razor edit string targeting the specific lane
    -- Format: "startTime endTime envelopeGUID topY bottomY"
    -- Empty GUID ("") targets media items, not envelopes
    local razorStr = string.format('%f %f "" %f %f', startTime, endTime, topY, btmY)
    reaper.ShowConsoleMsg("3. Setting P_RAZOREDITS_EXT: " .. razorStr .. "\n")

    -- Set the razor edit
    local success = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS_EXT", razorStr, true)
    if not success then
        reaper.ShowConsoleMsg("   ERROR: Failed to set P_RAZOREDITS_EXT\n")
        return false
    end

    -- Verify it was set
    local retval, verify = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS_EXT", "", false)
    reaper.ShowConsoleMsg("   Verified razor: " .. (verify or "nil") .. "\n")

    -- Run action 42475: "Razor edit: Create fixed lane comp area"
    reaper.ShowConsoleMsg("4. Running action 42475 (Create fixed lane comp area)\n")
    reaper.Main_OnCommand(42475, 0)

    -- Clear the razor edit
    reaper.ShowConsoleMsg("5. Clearing razor edit\n")
    reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS_EXT", "", true)

    -- Update display
    reaper.UpdateArrange()

    return true
end

-- Test comp source inference
local function testSourceInference()
    reaper.ShowConsoleMsg("\n=== TESTING COMP SOURCE INFERENCE ===\n")

    local numItems = reaper.GetTrackNumMediaItems(track)
    local compItems = {}

    -- Find all comp items (lane 0, C_LANEPLAYS=1)
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local lane = math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE"))
        local plays = math.floor(reaper.GetMediaItemInfo_Value(item, "C_LANEPLAYS"))

        if lane == 0 and plays == 1 then
            table.insert(compItems, item)
        end
    end

    reaper.ShowConsoleMsg(string.format("Found %d comp items in lane 0\n", #compItems))

    -- For each comp item, try to infer its source lane
    for i, item in ipairs(compItems) do
        local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local sourceLane, reason = getCompSourceLane(item)

        if sourceLane then
            reaper.ShowConsoleMsg(string.format("  Comp %d (%.2f-%.2f): source lane %d (%s)\n",
                i, pos, pos + len, sourceLane, reason))
        else
            reaper.ShowConsoleMsg(string.format("  Comp %d (%.2f-%.2f): UNKNOWN (%s)\n",
                i, pos, pos + len, reason))
        end
    end

    reaper.ShowConsoleMsg("=== INFERENCE TEST COMPLETE ===\n")
end

-- Test resizing comp areas via FULL REBUILD (delete ALL, recreate ALL)
-- Action 42955 clears all comp area metadata, then we re-swipe everything
local function testResize()
    reaper.ShowConsoleMsg("\n=== TESTING COMP AREA RESIZE VIA FULL REBUILD ===\n")

    -- Step 1: Gather current comp state before we delete everything
    local numItems = reaper.GetTrackNumMediaItems(track)
    local compAreas = {}  -- Store {startTime, endTime, sourceLane} for each comp area

    reaper.ShowConsoleMsg("  Step 1: Gathering current comp state...\n")

    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local lane = math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE"))
        local plays = math.floor(reaper.GetMediaItemInfo_Value(item, "C_LANEPLAYS"))

        if lane == 0 and plays == 1 then
            local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            local sourceLane, _ = getCompSourceLane(item)
            if not sourceLane then sourceLane = 1 end  -- Default

            table.insert(compAreas, {
                startTime = pos,
                endTime = pos + len,
                sourceLane = sourceLane
            })
            reaper.ShowConsoleMsg(string.format("    Comp: %.2f-%.2f from lane %d\n",
                pos, pos + len, sourceLane))
        end
    end

    if #compAreas == 0 then
        reaper.ShowConsoleMsg("  No comp areas found!\n")
        return
    end

    -- Modify first comp area for test (extend end by 20)
    local extendAmount = 20.0
    reaper.ShowConsoleMsg(string.format("\n  Modifying first comp: extend end by %.1f\n", extendAmount))
    compAreas[1].endTime = compAreas[1].endTime + extendAmount

    -- Also trim start of first comp by 10 for second test
    local trimAmount = 10.0
    reaper.ShowConsoleMsg(string.format("  Also trimming start by %.1f\n", trimAmount))
    compAreas[1].startTime = compAreas[1].startTime + trimAmount

    reaper.ShowConsoleMsg(string.format("  New first comp bounds: %.2f-%.2f\n",
        compAreas[1].startTime, compAreas[1].endTime))

    -- Step 2: Delete ALL comp items using action 42642
    reaper.ShowConsoleMsg("\n  Step 2: Deleting ALL comp areas (action 42642 per item)...\n")

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    -- Delete each comp item individually using 42642
    -- Must iterate backwards since we're deleting items
    numItems = reaper.GetTrackNumMediaItems(track)
    for i = numItems - 1, 0, -1 do
        local item = reaper.GetTrackMediaItem(track, i)
        if item then
            local lane = math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE"))
            local plays = math.floor(reaper.GetMediaItemInfo_Value(item, "C_LANEPLAYS"))

            if lane == 0 and plays == 1 then
                reaper.ShowConsoleMsg(string.format("    Deleting comp item %d...\n", i))
                reaper.Main_OnCommand(40289, 0)  -- Unselect all items
                reaper.SetMediaItemSelected(item, true)
                reaper.Main_OnCommand(42642, 0)  -- Fixed lane comp area: Delete comp area
            end
        end
    end

    showState("AFTER DELETE ALL COMP AREAS")

    -- Step 3: Recreate all comp areas with new bounds
    reaper.ShowConsoleMsg("\n  Step 3: Recreating comp areas with new bounds...\n")

    local currentLanes = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES"))
    reaper.ShowConsoleMsg(string.format("    Current lane count: %d\n", currentLanes))

    for i, comp in ipairs(compAreas) do
        reaper.ShowConsoleMsg(string.format("    Recreating comp %d: %.2f-%.2f from lane %d\n",
            i, comp.startTime, comp.endTime, comp.sourceLane))

        reaper.Main_OnCommand(40289, 0)  -- Unselect all items

        local topY, btmY = getLaneBounds(comp.sourceLane, currentLanes)
        local razorStr = string.format('%f %f "" %f %f',
            comp.startTime, comp.endTime, topY, btmY)

        reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS_EXT", razorStr, true)
        reaper.Main_OnCommand(42475, 0)  -- Create fixed lane comp area
        reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS_EXT", "", true)

        -- Update lane count after each swipe (first one adds a lane)
        currentLanes = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES"))
    end

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Full rebuild with resize", -1)

    -- Show final state
    showState("AFTER FULL REBUILD")

    reaper.ShowConsoleMsg("\n=== RESIZE VIA FULL REBUILD TEST COMPLETE ===\n")
    reaper.ShowConsoleMsg("Check REAPER visually:\n")
    reaper.ShowConsoleMsg("  1. Orange highlights should be PRESERVED\n")
    reaper.ShowConsoleMsg("  2. No fragment items should exist\n")
    reaper.ShowConsoleMsg("  3. First comp should be extended and trimmed\n")
end

-- Show initial state
showState("BEFORE")

-- Run swipes
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local swipesToRun = RUN_ALL_SWIPES and #SWIPES or 1
for i = 1, swipesToRun do
    local s = SWIPES[i]
    doSwipe(s.lane, s.start_time, s.end_time, i)

    if i < swipesToRun then
        reaper.ShowConsoleMsg("\n")
        showState("AFTER SWIPE " .. i)
    end
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Swipe comp v3 (razor)", -1)

-- Show final state
reaper.ShowConsoleMsg("\n")
showState("FINAL")

-- Test source inference if enabled
if TEST_SOURCE_INFERENCE then
    testSourceInference()
end

-- Test resize if enabled
if TEST_RESIZE then
    testResize()
end

reaper.ShowConsoleMsg("\n=== DONE ===\n")
reaper.ShowConsoleMsg("Check for orange highlights on source lanes!\n")
