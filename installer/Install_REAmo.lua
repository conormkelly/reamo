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

------------------------------------------------------------------------
-- Installation
------------------------------------------------------------------------

local errors = {}
local installed = {}

-- 1. Extension binary → UserPlugins/
local ext_src = script_dir .. sep .. ext_name
local ext_dst = resource_path .. sep .. "UserPlugins" .. sep .. ext_name
if file_exists(ext_src) then
  ensure_dir(resource_path .. sep .. "UserPlugins")
  local ok, err = copy_file(ext_src, ext_dst)
  if ok then
    installed[#installed + 1] = "Extension: " .. ext_name
  else
    errors[#errors + 1] = err
  end
else
  errors[#errors + 1] = "Extension binary not found: " .. ext_name ..
    "\n(Expected at: " .. ext_src .. ")"
end

-- 2. Web frontend → reaper_www_root/web/
local web_src = script_dir .. sep .. "web"
local web_dst = resource_path .. sep .. "reaper_www_root" .. sep .. "web"
local web_check = reaper.EnumerateFiles(web_src, 0)
if web_check then
  ensure_dir(web_dst)
  local count = copy_dir_recursive(web_src, web_dst)
  installed[#installed + 1] = "Frontend: " .. count .. " files"
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
