-- Reamo_TimeSig.lua
-- Time signature control for Reamo web interface
-- Version 1.1
--
-- This script is automatically installed and started by the Reamo installer.
-- It runs continuously in the background using reaper.defer(), polling for
-- time signature commands from the Reamo web interface via ExtState.
--
-- REQUIRES: SWS Extension (for SNM_SetIntConfigVar)
-- Uses project config variables to set time signature without creating tempo markers.

local SECTION = "Reamo"
local VERSION = "1.1"

-- Check if SWS is available
local function checkSWS()
  if not reaper.SNM_SetIntConfigVar then
    return false
  end
  return true
end

-- Set installed flag on load
reaper.SetExtState(SECTION, "timesig_script_installed", "1", false)
reaper.SetExtState(SECTION, "timesig_script_version", VERSION, false)

-- Check SWS availability
local hasSWS = checkSWS()
if not hasSWS then
  reaper.SetExtState(SECTION, "timesig_script_error", "SWS Extension required", false)
  reaper.ShowConsoleMsg("Reamo TimeSig: SWS Extension is required for time signature control\n")
end

-- Set project time signature using config variables (no tempo marker created)
-- This matches REAPER's native behavior when changing time sig via Project Settings dialog
local function setProjectTimeSignature(numerator, denominator)
  if not hasSWS then
    return false, "SWS Extension required"
  end

  -- projmeaslen = numerator (beats per measure, e.g., 6 for 6/8)
  -- projtsdenom = denominator (beat note value, e.g., 8 for 6/8)
  reaper.SNM_SetIntConfigVar("projmeaslen", numerator)
  reaper.SNM_SetIntConfigVar("projtsdenom", denominator)

  return true
end

-- Clear ExtState keys after processing
local function clearExtState()
  reaper.SetExtState(SECTION, "timesig_action", "", false)
  reaper.SetExtState(SECTION, "timesig_numerator", "", false)
  reaper.SetExtState(SECTION, "timesig_denominator", "", false)
end

-- Main polling function
local function poll()
  local action = reaper.GetExtState(SECTION, "timesig_action")

  if action == "set" then
    local numStr = reaper.GetExtState(SECTION, "timesig_numerator")
    local denomStr = reaper.GetExtState(SECTION, "timesig_denominator")

    local num = tonumber(numStr)
    local denom = tonumber(denomStr)

    if num and denom and num >= 1 and num <= 32 and (denom == 2 or denom == 4 or denom == 8 or denom == 16) then
      reaper.Undo_BeginBlock()
      reaper.PreventUIRefresh(1)

      local success, errMsg = setProjectTimeSignature(num, denom)

      reaper.PreventUIRefresh(-1)
      reaper.UpdateTimeline()
      reaper.Undo_EndBlock("Reamo: Set time signature to " .. num .. "/" .. denom, -1)

      -- Signal completion
      reaper.SetExtState(SECTION, "timesig_processed", "1", false)
      if success then
        reaper.SetExtState(SECTION, "timesig_error", "", false)
      else
        reaper.SetExtState(SECTION, "timesig_error", errMsg or "Failed to set time signature", false)
      end

      -- Clear action keys
      clearExtState()
    else
      -- Invalid values - signal error
      reaper.SetExtState(SECTION, "timesig_processed", "1", false)
      reaper.SetExtState(SECTION, "timesig_error",
        "Invalid time signature: " .. tostring(numStr) .. "/" .. tostring(denomStr), false)
      clearExtState()
    end
  end

  -- Continue polling
  reaper.defer(poll)
end

-- Start polling
poll()
