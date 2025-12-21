-- Reamo Installer
-- Run this script in REAPER to install Reamo

local SCRIPT_NAME = "Reamo Installer"
local VERSION = "1.0"

-- Markers for __startup.lua (DO NOT CHANGE - used for detection/removal)
local MARKER_BEGIN = "-- REAMO_AUTOSTART_BEGIN"
local MARKER_END = "-- REAMO_AUTOSTART_END"

--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

local function getScriptDir()
    local info = debug.getinfo(1, "S")
    local scriptPath = info.source:match("@(.+)") or ({reaper.get_action_context()})[2]
    return scriptPath:match("^(.+)[/\\]") or "."
end

local function isWindows()
    return reaper.GetOS():match("Win") ~= nil
end

local function isPortableInstall()
    local resourcePath = reaper.GetResourcePath()
    local os = reaper.GetOS()
    if os:match("Win") then
        return not resourcePath:match("AppData")
    elseif os:match("OSX") or os:match("macOS") then
        return not resourcePath:match("Application Support")
    else -- Linux
        return not resourcePath:match("%.config")
    end
end

local function pathJoin(...)
    local sep = isWindows() and "\\" or "/"
    return table.concat({...}, sep)
end

local function normalizePath(path)
    -- Use forward slashes internally (works on all platforms for Lua io)
    return path:gsub("\\", "/")
end

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function copyFile(source, dest)
    local input = io.open(source, "rb")
    if not input then
        return false, "Cannot open source: " .. source
    end

    local output = io.open(dest, "wb")
    if not output then
        input:close()
        return false, "Cannot create destination: " .. dest
    end

    local content = input:read("*all")
    local success = output:write(content)

    input:close()
    output:close()

    if not success then
        return false, "Failed to write: " .. dest
    end
    return true
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

local function removeReamoBlock(content)
    -- Remove everything between MARKER_BEGIN and MARKER_END (inclusive)
    -- Also remove the blank line before if present
    local pattern = "\n?" .. MARKER_BEGIN:gsub("%-", "%%-") .. ".-" .. MARKER_END:gsub("%-", "%%-") .. "\n?"
    return content:gsub(pattern, "")
end

local function hasReamoBlock(content)
    return content:find(MARKER_BEGIN, 1, true) ~= nil
end

--------------------------------------------------------------------------------
-- Installation Logic
--------------------------------------------------------------------------------

local function install()
    local scriptDir = getScriptDir()
    local resourcePath = reaper.GetResourcePath()

    -- Normalize paths
    scriptDir = normalizePath(scriptDir)
    resourcePath = normalizePath(resourcePath)

    -- Define source files (in the extracted ZIP folder)
    local sourceFiles = {
        html = scriptDir .. "/reamo.html",
        regionEdit = scriptDir .. "/Reamo_RegionEdit.lua",
        markerEdit = scriptDir .. "/Reamo_MarkerEdit.lua",
        startup = scriptDir .. "/Reamo_Startup.lua",
    }

    -- Define destination paths
    local destPaths = {
        wwwRoot = resourcePath .. "/reaper_www_root",
        scriptsReamo = resourcePath .. "/Scripts/Reamo",
        startupLua = resourcePath .. "/Scripts/__startup.lua",
    }

    -- Verify source files exist
    local missing = {}
    for name, path in pairs(sourceFiles) do
        if not fileExists(path) then
            table.insert(missing, name .. ": " .. path)
        end
    end

    if #missing > 0 then
        reaper.MB(
            "Missing required files:\n\n" .. table.concat(missing, "\n") ..
            "\n\nMake sure you extracted the ZIP and are running the installer from the extracted folder.",
            SCRIPT_NAME .. " - Error",
            0
        )
        return false
    end

    -- Show confirmation dialog
    local portableNote = ""
    if isPortableInstall() then
        portableNote = "PORTABLE REAPER DETECTED\n\n"
    end

    local confirmMsg = string.format([[
%sReamo will be installed to:

Web Interface:
  %s/reamo.html

Scripts:
  %s/

Auto-start will be configured in:
  %s

Proceed with installation?]],
        portableNote,
        destPaths.wwwRoot,
        destPaths.scriptsReamo,
        destPaths.startupLua
    )

    local result = reaper.MB(confirmMsg, SCRIPT_NAME, 4)
    if result ~= 6 then -- Not "Yes"
        reaper.MB("Installation cancelled.", SCRIPT_NAME, 0)
        return false
    end

    -- Create directories
    reaper.RecursiveCreateDirectory(destPaths.wwwRoot, 0)
    reaper.RecursiveCreateDirectory(destPaths.scriptsReamo, 0)

    -- Copy files
    local errors = {}

    local ok, err = copyFile(sourceFiles.html, destPaths.wwwRoot .. "/reamo.html")
    if not ok then table.insert(errors, err) end

    ok, err = copyFile(sourceFiles.regionEdit, destPaths.scriptsReamo .. "/Reamo_RegionEdit.lua")
    if not ok then table.insert(errors, err) end

    ok, err = copyFile(sourceFiles.markerEdit, destPaths.scriptsReamo .. "/Reamo_MarkerEdit.lua")
    if not ok then table.insert(errors, err) end

    ok, err = copyFile(sourceFiles.startup, destPaths.scriptsReamo .. "/Reamo_Startup.lua")
    if not ok then table.insert(errors, err) end

    if #errors > 0 then
        reaper.MB(
            "Installation failed:\n\n" .. table.concat(errors, "\n"),
            SCRIPT_NAME .. " - Error",
            0
        )
        return false
    end

    -- Setup auto-start in __startup.lua
    local startupContent = readFile(destPaths.startupLua) or ""
    local existingBackedUp = false

    -- Backup existing __startup.lua if it has content and we haven't modified it before
    if #startupContent > 0 and not hasReamoBlock(startupContent) then
        local backupPath = destPaths.startupLua .. ".bak"
        writeFile(backupPath, startupContent)
        existingBackedUp = true
    end

    -- Check if already installed (upgrade scenario)
    if hasReamoBlock(startupContent) then
        -- Already has Reamo block - this is an upgrade, remove old block first
        startupContent = removeReamoBlock(startupContent)
    end

    -- Append Reamo auto-start block
    local autoStartBlock = string.format([[

%s
pcall(dofile, "%s/Scripts/Reamo/Reamo_Startup.lua")
%s
]], MARKER_BEGIN, resourcePath, MARKER_END)

    startupContent = startupContent .. autoStartBlock

    if not writeFile(destPaths.startupLua, startupContent) then
        reaper.MB(
            "Warning: Could not configure auto-start.\n\n" ..
            "Files were copied successfully, but you'll need to manually run the Reamo scripts each session.\n\n" ..
            "Scripts location: " .. destPaths.scriptsReamo,
            SCRIPT_NAME .. " - Warning",
            0
        )
    end

    -- Success message
    local backupNote = ""
    if existingBackedUp then
        backupNote = "\n\n(Your existing __startup.lua was backed up to __startup.lua.bak)"
    end

    reaper.MB(
        [[Installation complete!

NEXT STEPS:

1. Enable REAPER's web server:
   - Go to: Preferences > Web interface
   - Check "Enable"
   - Set port (default: 8080)
   - Set "Default interface" to: reamo.html
   - Click Apply/OK

2. *** RESTART REAPER to activate auto-start ***

3. Access Reamo at:
   http://localhost:8080/reamo.html
   (or use your computer's IP for other devices)]] .. backupNote,
        SCRIPT_NAME .. " - Success",
        0
    )

    return true
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

install()
