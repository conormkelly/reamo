-- Reamo_MarkerEdit.lua
-- Marker name/color editing for Reamo web interface
-- Version 1.0
--
-- This script is automatically installed and started by the Reamo installer.
-- It runs continuously in the background using reaper.defer(), polling for
-- marker editing commands from the Reamo web interface via ExtState.

local SECTION = "Reamo"
local VERSION = "1.0"
local POLL_INTERVAL = 0.1 -- 100ms polling

-- Set installed flag on load
reaper.SetExtState(SECTION, "marker_script_installed", "1", false)
reaper.SetExtState(SECTION, "marker_script_version", VERSION, false)

-- Find marker by ID (user-visible number, not array index)
-- Returns: array index or nil
local function findMarkerByID(targetID)
  local numMarkers = reaper.CountProjectMarkers(0)

  for i = 0, numMarkers - 1 do
    local retval, isrgn, pos, rgnend, name, markrgnidx, color = reaper.EnumProjectMarkers3(0, i)
    if retval and not isrgn and markrgnidx == targetID then
      return i, pos, name, color
    end
  end

  return nil
end

-- Handle marker edit operation
local function handleEdit(markerID, newName, newColor)
  local idx, pos, currentName, currentColor = findMarkerByID(markerID)
  if not idx then
    return false, "Marker " .. tostring(markerID) .. " not found"
  end

  -- Use current values if new values not provided
  local finalName = newName
  if finalName == nil or finalName == "" then
    finalName = currentName
  end

  local finalColor = currentColor
  local resetToDefault = false
  if newColor and newColor ~= "" then
    local colorNum = tonumber(newColor)
    if colorNum ~= nil then
      if colorNum == 0 then
        -- Special case: reset to default color requires delete/recreate
        -- because SetProjectMarkerByIndex2 treats color=0 as "don't modify"
        resetToDefault = true
        finalColor = 0
      else
        finalColor = colorNum
      end
    end
  end

  if resetToDefault then
    -- Delete and recreate marker to reset color to default
    -- This is required because REAPER's API doesn't clear the color enable bit with color=0
    reaper.DeleteProjectMarkerByIndex(0, idx)
    reaper.AddProjectMarker2(0, false, pos, pos, finalName, markerID, 0)
  else
    -- Normal update - SetProjectMarkerByIndex2 works fine for non-zero colors
    reaper.SetProjectMarkerByIndex2(0, idx, false, pos, pos, markerID, finalName, finalColor, 0)
  end

  return true
end

-- Clear ExtState keys after processing
local function clearExtState()
  reaper.SetExtState(SECTION, "marker_action", "", false)
  reaper.SetExtState(SECTION, "marker_id", "", false)
  reaper.SetExtState(SECTION, "marker_name", "", false)
  reaper.SetExtState(SECTION, "marker_color", "", false)
end

-- Main polling function
local function poll()
  local action = reaper.GetExtState(SECTION, "marker_action")

  if action == "edit" then
    local markerIDStr = reaper.GetExtState(SECTION, "marker_id")
    local markerID = tonumber(markerIDStr)

    if markerID then
      local newName = reaper.GetExtState(SECTION, "marker_name")
      local newColor = reaper.GetExtState(SECTION, "marker_color")

      reaper.Undo_BeginBlock()
      reaper.PreventUIRefresh(1)

      local success, errMsg = handleEdit(markerID, newName, newColor)

      reaper.PreventUIRefresh(-1)
      reaper.Undo_EndBlock("Reamo: Edit marker " .. markerIDStr, -1)

      -- Signal completion
      reaper.SetExtState(SECTION, "marker_processed", "1", false)
      if not success and errMsg then
        reaper.SetExtState(SECTION, "marker_error", errMsg, false)
      else
        reaper.SetExtState(SECTION, "marker_error", "", false)
      end

      -- Clear action keys
      clearExtState()

      reaper.UpdateArrange()
    else
      -- Invalid marker ID - clear and signal error
      reaper.SetExtState(SECTION, "marker_processed", "1", false)
      reaper.SetExtState(SECTION, "marker_error", "Invalid marker ID: " .. tostring(markerIDStr), false)
      clearExtState()
    end
  end

  -- Continue polling
  reaper.defer(poll)
end

-- Start polling
poll()
