-- Reamo Uninstaller
-- Run this script in REAPER to remove Reamo

local SCRIPT_NAME = "Reamo Uninstaller"

-- Markers (must match installer)
local MARKER_BEGIN = "-- REAMO_AUTOSTART_BEGIN"
local MARKER_END = "-- REAMO_AUTOSTART_END"

--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

local function normalizePath(path)
    return path:gsub("\\", "/")
end

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return content
end

local function writeFile(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

local function deleteFile(path)
    return os.remove(path)
end

local function removeReamoBlock(content)
    local pattern = "\n?" .. MARKER_BEGIN:gsub("%-", "%%-") .. ".-" .. MARKER_END:gsub("%-", "%%-") .. "\n?"
    return content:gsub(pattern, "")
end

local function hasReamoBlock(content)
    return content:find(MARKER_BEGIN, 1, true) ~= nil
end

--------------------------------------------------------------------------------
-- Uninstall Logic
--------------------------------------------------------------------------------

local function uninstall()
    local resourcePath = normalizePath(reaper.GetResourcePath())

    -- Define paths
    local paths = {
        html = resourcePath .. "/reaper_www_root/reamo.html",
        scriptsDir = resourcePath .. "/Scripts/Reamo",
        regionEdit = resourcePath .. "/Scripts/Reamo/Reamo_RegionEdit.lua",
        markerEdit = resourcePath .. "/Scripts/Reamo/Reamo_MarkerEdit.lua",
        startup = resourcePath .. "/Scripts/Reamo/Reamo_Startup.lua",
        startupLua = resourcePath .. "/Scripts/__startup.lua",
    }

    -- Check if Reamo is installed
    local installed = fileExists(paths.html) or fileExists(paths.regionEdit)

    if not installed then
        reaper.MB("Reamo does not appear to be installed.", SCRIPT_NAME, 0)
        return false
    end

    -- Confirm uninstall
    local result = reaper.MB(
        "This will remove Reamo and all its files.\n\nAre you sure?",
        SCRIPT_NAME,
        4
    )

    if result ~= 6 then -- Not "Yes"
        reaper.MB("Uninstall cancelled.", SCRIPT_NAME, 0)
        return false
    end

    -- Remove files
    local removed = {}
    local failed = {}

    local filesToRemove = {paths.html, paths.regionEdit, paths.markerEdit, paths.startup}

    for _, path in ipairs(filesToRemove) do
        if fileExists(path) then
            if deleteFile(path) then
                table.insert(removed, path:match("[^/]+$"))
            else
                table.insert(failed, path)
            end
        end
    end

    -- Try to remove the Reamo scripts directory (will only work if empty)
    os.remove(paths.scriptsDir)

    -- Remove auto-start from __startup.lua
    local startupContent = readFile(paths.startupLua)
    if startupContent and hasReamoBlock(startupContent) then
        local newContent = removeReamoBlock(startupContent)

        -- If file is now empty (or just whitespace), delete it
        if newContent:match("^%s*$") then
            deleteFile(paths.startupLua)
            table.insert(removed, "__startup.lua (was empty)")
        else
            writeFile(paths.startupLua, newContent)
            table.insert(removed, "auto-start entry from __startup.lua")
        end
    end

    -- Report results
    local msg = "Reamo has been uninstalled.\n\n"

    if #removed > 0 then
        msg = msg .. "Removed:\n"
        for _, item in ipairs(removed) do
            msg = msg .. "  - " .. item .. "\n"
        end
    end

    if #failed > 0 then
        msg = msg .. "\nCould not remove:\n"
        for _, path in ipairs(failed) do
            msg = msg .. "  - " .. path .. "\n"
        end
    end

    msg = msg .. "\nRestart REAPER to complete the uninstall."

    reaper.MB(msg, SCRIPT_NAME, 0)
    return true
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

uninstall()
