-- Reamo_RegionEdit.lua
-- Region editing operations for Reamo web interface
-- Version 2.0 (Background polling version)
--
-- Installation:
-- 1. Copy this file to your REAPER Scripts folder
-- 2. Actions > Show action list > Load ReaScript
-- 3. Select this script
-- 4. Run once to start the background service
-- 5. The script will run in the background, polling for actions
--
-- Usage:
-- This script runs continuously in the background using reaper.defer().
-- The Reamo web interface sets ExtState values, and this script picks them up
-- and processes region operations.

local SECTION = "Reamo"
local VERSION = "2.0"
local POLL_INTERVAL = 0.1 -- Poll every 100ms

-- Track if script is running
local isRunning = true
local lastPollTime = 0

-- Set installed flag on load
reaper.SetExtState(SECTION, "script_installed", "1", false)
reaper.SetExtState(SECTION, "script_version", VERSION, false)

-- Get minimum region length (1 bar in current tempo)
local function getMinRegionLength()
  local bpm = reaper.Master_GetTempo()
  if bpm <= 0 then bpm = 120 end
  local beatsPerBar = 4 -- Assuming 4/4
  return (60 / bpm) * beatsPerBar
end

-- Parse a comma-separated list of integers
local function parseIndices(str)
  local indices = {}
  for idx in string.gmatch(str, "([^,]+)") do
    local num = tonumber(idx)
    if num then
      table.insert(indices, num)
    end
  end
  return indices
end

-- Get region data by enumeration index (includes markers)
local function getRegion(idx)
  local retval, isrgn, pos, rgnend, name, markrgnidx, color = reaper.EnumProjectMarkers3(0, idx)
  if retval and isrgn then
    return {
      idx = idx,
      pos = pos,
      rgnend = rgnend,
      name = name,
      markrgnidx = markrgnidx,
      color = color
    }
  end
  return nil
end

-- Find region by markrgnidx (REAPER's region ID)
-- This is needed because EnumProjectMarkers3 enumerates both markers and regions
local function findRegionByMarkrgnidx(targetMarkrgnidx)
  local numMarkers = reaper.CountProjectMarkers(0)
  for i = 0, numMarkers - 1 do
    local retval, isrgn, pos, rgnend, name, markrgnidx, color = reaper.EnumProjectMarkers3(0, i)
    if retval and isrgn and markrgnidx == targetMarkrgnidx then
      return {
        idx = i,  -- Enumeration index (needed for SetProjectMarkerByIndex2)
        pos = pos,
        rgnend = rgnend,
        name = name,
        markrgnidx = markrgnidx,
        color = color
      }
    end
  end
  return nil
end

-- Count total regions
local function countRegions()
  local count = 0
  local i = 0
  while true do
    local retval, isrgn = reaper.EnumProjectMarkers3(0, i)
    if not retval then break end
    if isrgn then count = count + 1 end
    i = i + 1
  end
  return count
end

-- Shift all regions starting at or after fromPos by delta
local function shiftRegionsFrom(fromPos, delta, excludeIdx)
  local numMarkers = reaper.CountProjectMarkers(0)
  local toShift = {}

  for i = 0, numMarkers - 1 do
    local retval, isrgn, pos, rgnend, name, markrgnidx, color = reaper.EnumProjectMarkers3(0, i)
    if retval and isrgn and i ~= excludeIdx and pos >= fromPos - 0.001 then
      table.insert(toShift, {
        idx = i,
        pos = pos + delta,
        rgnend = rgnend + delta,
        name = name,
        markrgnidx = markrgnidx,
        color = color
      })
    end
  end

  -- Apply shifts (use flag 2 to defer re-sort)
  for _, r in ipairs(toShift) do
    reaper.SetProjectMarkerByIndex2(0, r.idx, true, r.pos, r.rgnend, r.markrgnidx, r.name, r.color, 2)
  end

  -- Force re-sort
  if #toShift > 0 then
    reaper.SetProjectMarkerByIndex2(0, -1, false, 0, 0, 0, "", 0, 2)
  end
end

-- Trim regions overlapping a range (for replace mode)
local function trimRegionsInRange(startPos, endPos)
  local numMarkers = reaper.CountProjectMarkers(0)
  local toDelete = {}
  local toModify = {}
  local toCreate = {} -- For split regions

  for i = 0, numMarkers - 1 do
    local retval, isrgn, pos, rgnend, name, markrgnidx, color = reaper.EnumProjectMarkers3(0, i)
    if retval and isrgn then
      -- Check overlap
      if pos < endPos and rgnend > startPos then
        if pos >= startPos and rgnend <= endPos then
          -- Fully covered - delete
          table.insert(toDelete, i)
        elseif pos < startPos and rgnend > endPos then
          -- Range is inside region - split into two
          table.insert(toModify, {
            idx = i, pos = pos, rgnend = startPos,
            name = name, markrgnidx = markrgnidx, color = color
          })
          -- Add second part as new region
          table.insert(toCreate, {
            pos = endPos, rgnend = rgnend,
            name = name, color = color
          })
        elseif pos < startPos then
          -- Overlaps on left - trim end
          table.insert(toModify, {
            idx = i, pos = pos, rgnend = startPos,
            name = name, markrgnidx = markrgnidx, color = color
          })
        else
          -- Overlaps on right - trim start
          table.insert(toModify, {
            idx = i, pos = endPos, rgnend = rgnend,
            name = name, markrgnidx = markrgnidx, color = color
          })
        end
      end
    end
  end

  -- Delete (reverse order to preserve indices)
  table.sort(toDelete, function(a, b) return a > b end)
  for _, idx in ipairs(toDelete) do
    reaper.DeleteProjectMarkerByIndex(0, idx)
  end

  -- Modify
  for _, r in ipairs(toModify) do
    reaper.SetProjectMarkerByIndex2(0, r.idx, true, r.pos, r.rgnend, r.markrgnidx, r.name, r.color, 0)
  end

  -- Create split regions
  for _, r in ipairs(toCreate) do
    reaper.AddProjectMarker2(0, true, r.pos, r.rgnend, r.name, -1, r.color or 0)
  end
end

-- Trim region at a specific point (for ripple insert)
local function trimRegionAtPoint(pos)
  local numMarkers = reaper.CountProjectMarkers(0)

  for i = 0, numMarkers - 1 do
    local retval, isrgn, rpos, rgnend, name, markrgnidx, color = reaper.EnumProjectMarkers3(0, i)
    if retval and isrgn and pos > rpos and pos < rgnend then
      -- Point is inside this region - trim end
      reaper.SetProjectMarkerByIndex2(0, i, true, rpos, pos, markrgnidx, name, color, 0)
      return
    end
  end
end

-- Handle resize operation
-- markrgnidx: REAPER's region ID (not enumeration index)
local function handleResize(markrgnidx, newStart, newEnd, mode)
  local region = findRegionByMarkrgnidx(markrgnidx)
  if not region then return false, "Region not found (markrgnidx=" .. tostring(markrgnidx) .. ")" end

  local minLen = getMinRegionLength()

  -- Ensure newStart and newEnd are valid
  if newStart == nil then newStart = region.pos end
  if newEnd == nil then newEnd = region.rgnend end

  -- Enforce minimum length
  if newEnd - newStart < minLen then
    if newStart ~= region.pos then
      newStart = newEnd - minLen
    else
      newEnd = newStart + minLen
    end
  end

  -- Ensure non-negative
  if newStart < 0 then newStart = 0 end
  if newEnd < newStart then newEnd = newStart + minLen end

  if mode == "ripple" then
    -- Calculate deltas
    local deltaEnd = newEnd - region.rgnend
    local deltaStart = newStart - region.pos

    if deltaEnd ~= 0 then
      shiftRegionsFrom(region.rgnend, deltaEnd, region.idx)
    end
    if deltaStart ~= 0 then
      shiftRegionsFrom(region.pos, deltaStart, region.idx)
    end
  end

  -- Use region.idx (enumeration index) for the actual update
  reaper.SetProjectMarkerByIndex2(0, region.idx, true, newStart, newEnd, region.markrgnidx, region.name, region.color, 0)
  return true
end

-- Handle move operation
local function handleMove(indices, destStart, mode)
  if #indices == 0 then return false, "No regions specified" end

  -- Collect region data before modifying
  local regions = {}
  local blockStart = nil

  -- Sort indices
  table.sort(indices)

  for _, idx in ipairs(indices) do
    local region = getRegion(idx)
    if region then
      if not blockStart then blockStart = region.pos end
      table.insert(regions, {
        idx = idx,
        offset = region.pos - blockStart,
        length = region.rgnend - region.pos,
        name = region.name,
        markrgnidx = region.markrgnidx,
        color = region.color
      })
    end
  end

  if #regions == 0 then return false, "No valid regions found" end

  -- Calculate block dimensions
  local lastReg = regions[#regions]
  local blockLength = lastReg.offset + lastReg.length
  local destEnd = destStart + blockLength

  -- Delete source regions (reverse order to preserve indices)
  for i = #indices, 1, -1 do
    reaper.DeleteProjectMarkerByIndex(0, indices[i])
  end

  if mode == "replace" then
    trimRegionsInRange(destStart, destEnd)
  else -- ripple
    trimRegionAtPoint(destStart)
    shiftRegionsFrom(destStart, blockLength, -1)
  end

  -- Insert regions at destination (maintaining relative positions)
  for _, reg in ipairs(regions) do
    local newPos = destStart + reg.offset
    local newEnd = newPos + reg.length
    reaper.AddProjectMarker2(0, true, newPos, newEnd, reg.name, -1, reg.color or 0)
  end

  return true
end

-- Handle create operation
local function handleCreate(startPos, endPos, name, color)
  local minLen = getMinRegionLength()
  if endPos - startPos < minLen then
    endPos = startPos + minLen
  end

  -- Trim existing regions (replace semantics)
  trimRegionsInRange(startPos, endPos)

  -- Create new region with color
  local regionColor = color or 0
  reaper.AddProjectMarker2(0, true, startPos, endPos, name, -1, regionColor)
  return true
end

-- Handle update operation (position, name, and/or color)
-- markrgnidx: REAPER's region ID (not enumeration index)
-- If color=0, we need to delete/recreate to reset to default (REAPER API quirk)
local function handleUpdate(markrgnidx, newStart, newEnd, newName, newColor)
  local region = findRegionByMarkrgnidx(markrgnidx)
  if not region then return false, "Region not found (markrgnidx=" .. tostring(markrgnidx) .. ")" end

  local minLen = getMinRegionLength()

  -- Use existing values if not provided
  local finalStart = newStart or region.pos
  local finalEnd = newEnd or region.rgnend
  local finalName = newName or region.name
  local finalColor = region.color

  -- Handle color (check for explicit 0 vs nil/empty)
  local resetToDefault = false
  if newColor ~= nil then
    if newColor == 0 then
      -- Special case: reset to default requires delete/recreate
      -- because SetProjectMarkerByIndex2 treats color=0 as "don't modify"
      resetToDefault = true
      finalColor = 0
    else
      finalColor = newColor
    end
  end

  -- Enforce minimum length
  if finalEnd - finalStart < minLen then
    finalEnd = finalStart + minLen
  end

  -- Ensure non-negative
  if finalStart < 0 then finalStart = 0 end
  if finalEnd < finalStart then finalEnd = finalStart + minLen end

  if resetToDefault then
    -- Delete and recreate region to reset color to default
    reaper.DeleteProjectMarkerByIndex(0, region.idx)
    reaper.AddProjectMarker2(0, true, finalStart, finalEnd, finalName, markrgnidx, 0)
  else
    -- Normal update
    reaper.SetProjectMarkerByIndex2(0, region.idx, true, finalStart, finalEnd, region.markrgnidx, finalName, finalColor, 0)
  end
  return true
end

-- Handle delete operation
-- markrgnidx: REAPER's region ID (not enumeration index)
local function handleDelete(markrgnidx)
  local region = findRegionByMarkrgnidx(markrgnidx)
  if not region then return false, "Region not found (markrgnidx=" .. tostring(markrgnidx) .. ")" end

  reaper.DeleteProjectMarkerByIndex(0, region.idx)
  return true
end

-- Parse batch data and execute operations
-- NOTE: Batch operations use "replace" mode because the web UI already calculates
-- all final positions including ripple effects. We don't want to double-ripple.
local function handleBatch(batchData, mode)
  if not batchData or batchData == "" then
    return false, "No batch data"
  end

  -- For batch operations, always use "replace" mode to avoid double-rippling
  -- The web UI already calculated all the final positions
  local batchMode = "replace"

  -- Parse operations (semicolon-separated)
  for op in string.gmatch(batchData, "([^;]+)") do
    local parts = {}
    for part in string.gmatch(op, "([^|]+)") do
      table.insert(parts, part)
    end

    local opType = parts[1]

    if opType == "resize" then
      -- resize|markrgnidx|newStart|newEnd (legacy, for backwards compatibility)
      local markrgnidx = tonumber(parts[2])
      local newStart = tonumber(parts[3])
      local newEnd = tonumber(parts[4])
      if markrgnidx then
        handleResize(markrgnidx, newStart, newEnd, batchMode)
      end

    elseif opType == "update" then
      -- update|markrgnidx|newStart|newEnd|name|color
      local markrgnidx = tonumber(parts[2])
      local newStart = tonumber(parts[3])
      local newEnd = tonumber(parts[4])
      local name = parts[5] or nil
      local color = tonumber(parts[6])
      if markrgnidx then
        handleUpdate(markrgnidx, newStart, newEnd, name, color)
      end

    elseif opType == "move" then
      -- move|idx1,idx2,...|destStart
      local indices = parseIndices(parts[2] or "")
      local destStart = tonumber(parts[3])
      if #indices > 0 and destStart then
        handleMove(indices, destStart, batchMode)
      end

    elseif opType == "create" then
      -- create|start|end|name|color
      local startPos = tonumber(parts[2])
      local endPos = tonumber(parts[3])
      local name = parts[4] or "Region"
      local color = tonumber(parts[5])
      if startPos and endPos then
        handleCreate(startPos, endPos, name, color)
      end

    elseif opType == "delete" then
      -- delete|markrgnidx
      local markrgnidx = tonumber(parts[2])
      if markrgnidx then
        handleDelete(markrgnidx)
      end
    end
  end

  return true
end

-- Clear ExtState keys after processing
local function clearExtState()
  reaper.SetExtState(SECTION, "action", "", false)
  reaper.SetExtState(SECTION, "batch_data", "", false)
  reaper.SetExtState(SECTION, "mode", "", false)
end

-- Process any pending action
local function processAction()
  local action = reaper.GetExtState(SECTION, "action")
  if action == "" then
    return -- No action to perform
  end

  local mode = reaper.GetExtState(SECTION, "mode")
  if mode == "" then mode = "replace" end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local success, errMsg = true, nil

  if action == "batch" then
    local batchData = reaper.GetExtState(SECTION, "batch_data")
    success, errMsg = handleBatch(batchData, mode)
  end

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Reamo: Edit regions", -1)

  -- Signal completion
  reaper.SetExtState(SECTION, "processed", "1", false)
  if not success and errMsg then
    reaper.SetExtState(SECTION, "error", errMsg, false)
  else
    reaper.SetExtState(SECTION, "error", "", false)
  end

  -- Clear action keys
  clearExtState()

  reaper.UpdateArrange()
end

-- Main polling loop
local function poll()
  -- Check if we should stop
  local stopFlag = reaper.GetExtState(SECTION, "stop_script")
  if stopFlag == "1" then
    reaper.SetExtState(SECTION, "stop_script", "", false)
    reaper.SetExtState(SECTION, "script_installed", "0", false)
    return -- Don't defer, script exits
  end

  -- Process any pending action
  processAction()

  -- Keep running
  reaper.defer(poll)
end

-- Start the polling loop
reaper.ShowConsoleMsg("Reamo Region Edit v" .. VERSION .. " started (background polling mode)\n")
poll()
