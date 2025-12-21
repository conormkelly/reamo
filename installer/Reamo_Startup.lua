-- Reamo Auto-Startup
-- This file is loaded by __startup.lua on REAPER launch
-- Do not run this script manually - it's meant to be called via dofile()

local function startReamo()
    local resourcePath = reaper.GetResourcePath():gsub("\\", "/")
    local scriptsPath = resourcePath .. "/Scripts/Reamo/"

    -- Check if Reamo is actually installed
    if not reaper.file_exists(scriptsPath .. "Reamo_RegionEdit.lua") then
        return -- Silently skip if uninstalled
    end

    -- Defer to let REAPER fully initialize
    reaper.defer(function()
        -- Load the region and marker editing scripts
        local ok1, err1 = pcall(dofile, scriptsPath .. "Reamo_RegionEdit.lua")
        local ok2, err2 = pcall(dofile, scriptsPath .. "Reamo_MarkerEdit.lua")

        -- Log errors to console (don't show dialogs on startup)
        if not ok1 then
            reaper.ShowConsoleMsg("Reamo: Failed to load RegionEdit - " .. tostring(err1) .. "\n")
        end
        if not ok2 then
            reaper.ShowConsoleMsg("Reamo: Failed to load MarkerEdit - " .. tostring(err2) .. "\n")
        end
    end)
end

startReamo()
