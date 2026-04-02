-- Uninstall_REAmo.lua
-- Run via Actions > ReaScript: Run ReaScript... (Action ID 41060)
-- Removes REAmo files from REAPER directories.

local resource_path = reaper.GetResourcePath()
local sep = package.config:sub(1, 1)

-- Detect platform and extension filename
local ext_name
local os_name = reaper.GetOS()
if os_name:match("^OSX") or os_name:match("^macOS") then
  ext_name = "reaper_reamo.dylib"
elseif os_name:match("^Win") then
  ext_name = "reaper_reamo.dll"
else
  ext_name = "reaper_reamo.so"
end

local confirm = reaper.ShowMessageBox(
  "This will remove REAmo from REAPER:\n\n" ..
  "  - Extension: UserPlugins/" .. ext_name .. "\n" ..
  "  - Frontend: reaper_www_root/web/\n" ..
  "  - Tuner JSFX: Effects/REAmo/\n\n" ..
  "Continue?",
  "Uninstall REAmo", 4) -- 4 = Yes/No

if confirm ~= 6 then return end -- 6 = Yes

local removed = {}

-- Helper: delete a file
local function remove_file(path)
  local ok = os.remove(path)
  return ok
end

-- Helper: recursively delete directory contents then the directory itself
local function remove_dir_recursive(dir)
  -- Delete files first
  local i = 0
  while true do
    local filename = reaper.EnumerateFiles(dir, i)
    if not filename then break end
    os.remove(dir .. sep .. filename)
    i = i + 1
  end

  -- Recurse into subdirectories
  i = 0
  while true do
    local subdir = reaper.EnumerateSubdirectories(dir, i)
    if not subdir then break end
    remove_dir_recursive(dir .. sep .. subdir)
    i = i + 1
  end

  -- Remove the now-empty directory
  os.remove(dir)
end

-- 1. Extension binary
local ext_path = resource_path .. sep .. "UserPlugins" .. sep .. ext_name
if remove_file(ext_path) then
  removed[#removed + 1] = "Extension: " .. ext_name
end

-- 2. Web frontend directory
local web_dir = resource_path .. sep .. "reaper_www_root" .. sep .. "web"
local web_check = reaper.EnumerateFiles(web_dir, 0)
if web_check then
  remove_dir_recursive(web_dir)
  removed[#removed + 1] = "Frontend: reaper_www_root/web/"
end

-- 3. JSFX tuner + Effects/REAmo/ directory
local effects_dir = resource_path .. sep .. "Effects" .. sep .. "REAmo"
local jsfx_path = effects_dir .. sep .. "PitchDetect.jsfx"
if remove_file(jsfx_path) then
  removed[#removed + 1] = "Tuner JSFX: PitchDetect.jsfx"
  -- Remove directory if empty
  os.remove(effects_dir)
end

if #removed > 0 then
  reaper.ShowMessageBox(
    "REAmo uninstalled.\n\n" ..
    "Removed:\n  " .. table.concat(removed, "\n  ") .. "\n\n" ..
    "Please restart REAPER.",
    "REAmo Uninstall", 0)
else
  reaper.ShowMessageBox(
    "Nothing to remove — REAmo doesn't appear to be installed.",
    "REAmo Uninstall", 0)
end
