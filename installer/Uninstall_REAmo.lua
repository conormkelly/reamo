-- Uninstall_REAmo.lua
-- Run via Actions > ReaScript: Run ReaScript... (Action ID 41060)
-- Removes REAmo files from REAPER directories.

local resource_path = reaper.GetResourcePath()
local sep = package.config:sub(1, 1)
local os_name = reaper.GetOS()
local is_windows = os_name:match("^Win") ~= nil

-- Extension filename for this platform
local ext_name, ext_suffix
if os_name:match("^OSX") or os_name:match("^macOS") then
  ext_name, ext_suffix = "reaper_reamo.dylib", "dylib"
elseif is_windows then
  ext_name, ext_suffix = "reaper_reamo.dll", "dll"
else
  ext_name, ext_suffix = "reaper_reamo.so", "so"
end

-- Names the installer leaves in UserPlugins (see Install_REAmo.lua).
local TEMP_NAME = "reamo_install.tmp"
local OLD_PREFIX = "old_reaper_reamo"

local confirm = reaper.ShowMessageBox(
  "This will remove REAmo from REAPER:\n\n" ..
  "  - Extension: UserPlugins/" .. ext_name .. "\n" ..
  "  - Frontend: reaper_www_root/web/\n" ..
  "  - Tuner JSFX: Effects/REAmo/\n\n" ..
  "Continue?",
  "Uninstall REAmo", 4) -- 4 = Yes/No

if confirm ~= 6 then return end -- 6 = Yes

local removed = {}
local leftovers = {}

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

-- File and subdirectory names in `dir`, collected before anything is
-- deleted: deleting while enumerating by index skips entries.
local function list_dir(dir)
  local files, dirs = {}, {}
  local i = 0
  while true do
    local name = reaper.EnumerateFiles(dir, i)
    if not name then break end
    files[#files + 1] = name
    i = i + 1
  end
  i = 0
  while true do
    local name = reaper.EnumerateSubdirectories(dir, i)
    if not name then break end
    dirs[#dirs + 1] = name
    i = i + 1
  end
  return files, dirs
end

-- Remove a directory if it's empty. Lua's os.remove does that on Linux and
-- macOS; on Windows it only deletes files, so there it's cmd's rmdir, run by
-- REAPER without a console window. Without /S, rmdir refuses a directory
-- that isn't empty.
local function remove_empty_dir(path)
  if os.remove(path) then return true end
  if not is_windows then return false end
  local result = reaper.ExecProcess('cmd.exe /C rmdir "' .. path .. '"', 10000)
  return result ~= nil and result:match("^0\n") ~= nil
end

-- Delete a directory and everything in it.
local function remove_dir_recursive(dir)
  local files, dirs = list_dir(dir)
  for _, name in ipairs(files) do os.remove(dir .. sep .. name) end
  for _, name in ipairs(dirs) do remove_dir_recursive(dir .. sep .. name) end
  remove_empty_dir(dir)
end

-- 1. Extension binary, and anything an update left beside it
local plugins_dir = resource_path .. sep .. "UserPlugins"
local ext_path = plugins_dir .. sep .. ext_name
if file_exists(ext_path) then
  if os.remove(ext_path) then
    removed[#removed + 1] = "Extension: " .. ext_name
  elseif is_windows then
    -- Loaded by REAPER, so locked: moved aside under a name REAPER won't
    -- load, so REAmo is gone after the restart.
    local aside = plugins_dir .. sep .. OLD_PREFIX .. "." .. os.time() .. "." .. ext_suffix
    if os.rename(ext_path, aside) then
      removed[#removed + 1] = "Extension: " .. ext_name .. " (from the next restart)"
      leftovers[#leftovers + 1] = aside
    else
      leftovers[#leftovers + 1] = ext_path
    end
  else
    leftovers[#leftovers + 1] = ext_path
  end
end
for _, name in ipairs((list_dir(plugins_dir))) do
  if name:sub(1, #OLD_PREFIX) == OLD_PREFIX or name == TEMP_NAME then
    local path = plugins_dir .. sep .. name
    if not os.remove(path) then
      local listed = false
      for _, l in ipairs(leftovers) do if l == path then listed = true end end
      if not listed then leftovers[#leftovers + 1] = path end
    end
  end
end

-- 2. Web frontend directory
local web_dir = resource_path .. sep .. "reaper_www_root" .. sep .. "web"
if reaper.EnumerateFiles(web_dir, 0) or reaper.EnumerateSubdirectories(web_dir, 0) then
  remove_dir_recursive(web_dir)
  removed[#removed + 1] = "Frontend: reaper_www_root/web/"
end

-- 3. JSFX tuner + Effects/REAmo/ directory
local effects_dir = resource_path .. sep .. "Effects" .. sep .. "REAmo"
local jsfx_path = effects_dir .. sep .. "PitchDetect.jsfx"
if os.remove(jsfx_path) then
  removed[#removed + 1] = "Tuner JSFX: PitchDetect.jsfx"
  remove_empty_dir(effects_dir)
end

local leftover_note = ""
if #leftovers > 0 then
  leftover_note = "\n\nThese files are in use until REAPER closes; delete them after\n" ..
    "closing REAPER if you want them gone:\n  " .. table.concat(leftovers, "\n  ")
end

if #removed > 0 then
  reaper.ShowMessageBox(
    "REAmo uninstalled.\n\n" ..
    "Removed:\n  " .. table.concat(removed, "\n  ") ..
    leftover_note .. "\n\n" ..
    "Restart REAPER to finish.",
    "REAmo Uninstall", 0)
elseif #leftovers > 0 then
  reaper.ShowMessageBox("REAmo couldn't be removed." .. leftover_note, "REAmo Uninstall", 0)
else
  reaper.ShowMessageBox(
    "Nothing to remove — REAmo doesn't appear to be installed.",
    "REAmo Uninstall", 0)
end
