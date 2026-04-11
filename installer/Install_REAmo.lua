-- Install_REAmo.lua
-- Run via Actions > ReaScript: Run ReaScript... (Action ID 41060)
-- Copies REAmo files from the extracted ZIP to the correct REAPER directories.

local script_path = ({reaper.get_action_context()})[2]
local script_dir = script_path:match("(.+)[/\\]")

if not script_dir then
  reaper.ShowMessageBox(
    "Could not determine installer location.\n\n" ..
    "Make sure you're running this from the extracted REAmo folder.",
    "REAmo Install Error", 0)
  return
end

local resource_path = reaper.GetResourcePath()
local sep = package.config:sub(1, 1) -- "/" on mac/linux, "\" on windows

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

-- Helper: check if file exists
local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

-- Helper: copy a single file (binary-safe)
local function copy_file(src, dst)
  local f_in = io.open(src, "rb")
  if not f_in then return false, "Cannot open: " .. src end
  local data = f_in:read("*a")
  f_in:close()

  local f_out = io.open(dst, "wb")
  if not f_out then return false, "Cannot write: " .. dst end
  f_out:write(data)
  f_out:close()
  return true
end

-- Helper: create directory (recursive via reaper.RecursiveCreateDirectory)
local function ensure_dir(path)
  reaper.RecursiveCreateDirectory(path, 0)
end

-- Helper: copy all files from src_dir to dst_dir (non-recursive, single level)
local function copy_dir_files(src_dir, dst_dir)
  local count = 0
  local i = 0
  while true do
    local filename = reaper.EnumerateFiles(src_dir, i)
    if not filename then break end
    local ok, err = copy_file(src_dir .. sep .. filename, dst_dir .. sep .. filename)
    if ok then
      count = count + 1
    else
      reaper.ShowConsoleMsg("[REAmo Install] " .. (err or "Unknown error") .. "\n")
    end
    i = i + 1
  end
  return count
end

-- Helper: recursively copy a directory tree
local function copy_dir_recursive(src_dir, dst_dir)
  ensure_dir(dst_dir)
  local count = copy_dir_files(src_dir, dst_dir)

  -- Recurse into subdirectories
  local i = 0
  while true do
    local subdir = reaper.EnumerateSubdirectories(src_dir, i)
    if not subdir then break end
    count = count + copy_dir_recursive(
      src_dir .. sep .. subdir,
      dst_dir .. sep .. subdir
    )
    i = i + 1
  end
  return count
end

-- Helper: recursively delete directory contents (for clean upgrades)
local function remove_dir_recursive(dir)
  -- Always enumerate index 0: after deleting, the next file shifts to index 0
  while true do
    local filename = reaper.EnumerateFiles(dir, 0)
    if not filename then break end
    os.remove(dir .. sep .. filename)
  end
  while true do
    local subdir = reaper.EnumerateSubdirectories(dir, 0)
    if not subdir then break end
    remove_dir_recursive(dir .. sep .. subdir)
  end
  os.remove(dir)
end

-- Helper: clean up old renamed DLLs from previous upgrades (Windows only)
-- Collects filenames first to avoid modifying the directory while enumerating
local function cleanup_old_dlls(plugins_dir)
  local to_delete = {}
  local i = 0
  while true do
    local filename = reaper.EnumerateFiles(plugins_dir, i)
    if not filename then break end
    if filename:match("^old_reaper_reamo%.dll$")
      or filename:match("^old_reaper_reamo%..+%.dll$") then
      to_delete[#to_delete + 1] = filename
    end
    i = i + 1
  end
  for _, filename in ipairs(to_delete) do
    os.remove(plugins_dir .. sep .. filename)
  end
end

------------------------------------------------------------------------
-- Installation
------------------------------------------------------------------------

local errors = {}
local installed = {}
local is_windows = os_name:match("^Win")
local plugins_dir = resource_path .. sep .. "UserPlugins"

-- Clean up leftover renamed DLLs from previous upgrades
if is_windows then
  cleanup_old_dlls(plugins_dir)
end

-- 1. Extension binary → UserPlugins/
local ext_src = script_dir .. sep .. ext_name
local ext_dst = plugins_dir .. sep .. ext_name
if file_exists(ext_src) then
  ensure_dir(plugins_dir)
  local ok, err = copy_file(ext_src, ext_dst)
  if not ok and is_windows and file_exists(ext_dst) then
    -- DLL is locked by running REAPER — rename it out of the way
    local old_path = plugins_dir .. sep .. "old_reaper_reamo.dll"
    os.remove(old_path) -- remove any leftover from a previous upgrade
    local renamed = os.rename(ext_dst, old_path)
    if renamed then
      ok, err = copy_file(ext_src, ext_dst)
      if ok then
        installed[#installed + 1] = "Extension: " .. ext_name .. " (upgraded — old DLL renamed, restart REAPER)"
      else
        errors[#errors + 1] = err
      end
    else
      errors[#errors + 1] = "Cannot update " .. ext_name .. " — DLL is locked.\n" ..
        "Close REAPER, replace the DLL manually, then restart."
    end
  elseif ok then
    installed[#installed + 1] = "Extension: " .. ext_name
  else
    errors[#errors + 1] = err
  end
else
  errors[#errors + 1] = "Extension binary not found: " .. ext_name ..
    "\n(Expected at: " .. ext_src .. ")"
end

-- 2. Web frontend → reaper_www_root/reamo/
local web_src = script_dir .. sep .. "reamo"
-- Fall back to old "web" directory name in case user has an older ZIP layout
if not reaper.EnumerateFiles(web_src, 0) then
  web_src = script_dir .. sep .. "web"
end
local web_dst = resource_path .. sep .. "reaper_www_root" .. sep .. "reamo"
local web_check = reaper.EnumerateFiles(web_src, 0)
if web_check then
  -- Clean out old frontend files before copying (prevents stale hashed files accumulating)
  if reaper.EnumerateFiles(web_dst, 0) then
    remove_dir_recursive(web_dst)
  end
  ensure_dir(web_dst)
  local count = copy_dir_recursive(web_src, web_dst)
  installed[#installed + 1] = "Frontend: " .. count .. " files"

  -- Migrate: remove old reaper_www_root/web/ if it was ours (pre-v0.8 installs)
  -- Only delete if index.html contains "REAmo" — avoid nuking other extensions' files
  local old_web = resource_path .. sep .. "reaper_www_root" .. sep .. "web"
  local old_index = old_web .. sep .. "index.html"
  local f = io.open(old_index, "r")
  if f then
    local content = f:read("*a")
    f:close()
    if content and content:find("REAmo") then
      remove_dir_recursive(old_web)
      installed[#installed + 1] = "Cleaned up old web/ directory (migrated to reamo/)"
    end
  end
else
  errors[#errors + 1] = "Web frontend folder not found.\n(Expected at: " .. web_src .. ")"
end

-- 3. JSFX tuner → Effects/REAmo/
local jsfx_src = script_dir .. sep .. "effects" .. sep .. "REAmo" .. sep .. "PitchDetect.jsfx"
local jsfx_dst_dir = resource_path .. sep .. "Effects" .. sep .. "REAmo"
local jsfx_dst = jsfx_dst_dir .. sep .. "PitchDetect.jsfx"
if file_exists(jsfx_src) then
  ensure_dir(jsfx_dst_dir)
  local ok, err = copy_file(jsfx_src, jsfx_dst)
  if ok then
    installed[#installed + 1] = "Tuner JSFX: PitchDetect.jsfx"
  else
    errors[#errors + 1] = err
  end
else
  errors[#errors + 1] = "Tuner JSFX not found.\n(Expected at: " .. jsfx_src .. ")"
end

------------------------------------------------------------------------
-- Results
------------------------------------------------------------------------

if #errors > 0 then
  reaper.ShowMessageBox(
    "REAmo installed with warnings:\n\n" ..
    "Installed:\n  " .. table.concat(installed, "\n  ") .. "\n\n" ..
    "Errors:\n  " .. table.concat(errors, "\n  ") .. "\n\n" ..
    "Please restart REAPER.",
    "REAmo Install", 0)
else
  reaper.ShowMessageBox(
    "REAmo installed successfully!\n\n" ..
    "  " .. table.concat(installed, "\n  ") .. "\n\n" ..
    "Please restart REAPER to load the extension.\n\n" ..
    "After restart, go to:\n" ..
    "  Extensions > REAmo > Show QR Code\n" ..
    "and scan with your phone to connect.",
    "REAmo Install", 0)
end
