-- Install_REAmo.lua
-- Run via Actions > ReaScript: Run ReaScript... (Action ID 41060)
-- Copies REAmo files from the extracted ZIP to the correct REAPER directories.
--
-- Safe to run while REAmo is loaded, to update it. The running extension is
-- never written over: REAPER is executing it, and on macOS changing a loaded
-- binary in place can get REAPER killed. The new binary is written beside it
-- and swapped in by rename; on Windows, where a loaded DLL can be renamed but
-- not replaced, the old one is first moved aside under a name REAPER doesn't
-- load (old_reaper_reamo.*), which REAmo deletes when it next starts.

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

-- Not reaper_*: REAPER loads every reaper_*.<suffix> in UserPlugins.
local TEMP_NAME = "reamo_install.tmp"
local OLD_PREFIX = "old_reaper_reamo"

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_file(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  local ok = f:write(data)
  f:close()
  return ok ~= nil
end

local function ensure_dir(path)
  reaper.RecursiveCreateDirectory(path, 0)
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

-- The version this package installs, from the first line of its README.
local function package_version()
  local f = io.open(script_dir .. sep .. "README.txt", "r")
  if not f then return nil end
  local first = f:read("*l") or ""
  f:close()
  return first:match("REAmo v(%S+)")
end

------------------------------------------------------------------------
-- Extension binary
------------------------------------------------------------------------

-- Delete binaries moved aside by earlier updates. One still loaded (an
-- update made twice before restarting) can't be deleted yet and is skipped.
local function remove_old_binaries(plugins_dir)
  local files = list_dir(plugins_dir)
  for _, name in ipairs(files) do
    if name:sub(1, #OLD_PREFIX) == OLD_PREFIX or name == TEMP_NAME then
      os.remove(plugins_dir .. sep .. name)
    end
  end
end

-- A name for the binary being moved aside that no earlier one has taken.
local function old_binary_path(plugins_dir)
  local base = plugins_dir .. sep .. OLD_PREFIX .. "." .. os.time()
  local path, n = base .. "." .. ext_suffix, 1
  while file_exists(path) do
    path = base .. "-" .. n .. "." .. ext_suffix
    n = n + 1
  end
  return path
end

-- Install `src` as `dst`. Returns "installed" or "updated", or nil and why.
local function install_binary(src, dst, plugins_dir)
  local data = read_file(src)
  if not data then return nil, "Cannot read " .. src end

  local tmp = plugins_dir .. sep .. TEMP_NAME
  os.remove(tmp)
  if not write_file(tmp, data) then
    os.remove(tmp)
    return nil, "Cannot write to " .. plugins_dir .. " (is the disk full, or the folder read-only?)"
  end

  if not file_exists(dst) then
    if os.rename(tmp, dst) then return "installed" end
    os.remove(tmp)
    return nil, "Cannot create " .. dst
  end

  if not is_windows then
    -- rename() replaces dst in one step; the running copy keeps its file.
    if os.rename(tmp, dst) then return "updated" end
    os.remove(tmp)
    return nil, "Cannot replace " .. dst
  end

  -- Windows: a DLL REAPER hasn't loaded can simply be deleted; a loaded one
  -- can only be moved aside.
  local old
  if not os.remove(dst) then
    old = old_binary_path(plugins_dir)
    if not os.rename(dst, old) then
      os.remove(tmp)
      return nil, "Cannot move the running " .. ext_name .. " aside. " ..
        "Close REAPER, delete it from " .. plugins_dir .. ", then run this installer again."
    end
  end
  if os.rename(tmp, dst) then return "updated" end
  -- Put the previous version back rather than leave none.
  if old then os.rename(old, dst) end
  os.remove(tmp)
  return nil, "Cannot create " .. dst
end

------------------------------------------------------------------------
-- Web frontend
------------------------------------------------------------------------

-- Copy the tree at src into dst; records each relative path copied.
local function copy_tree(src, dst, rel, copied, errors)
  ensure_dir(dst)
  local files, dirs = list_dir(src)
  for _, name in ipairs(files) do
    local data = read_file(src .. sep .. name)
    if data and write_file(dst .. sep .. name, data) then
      copied[rel .. name] = true
    else
      errors[#errors + 1] = "Cannot copy web file " .. rel .. name
    end
  end
  for _, name in ipairs(dirs) do
    copy_tree(src .. sep .. name, dst .. sep .. name, rel .. name .. "/", copied, errors)
  end
end

-- Delete files under dst that the new frontend doesn't have (old builds'
-- hashed assets), and directories left empty.
local function remove_stale(dst, rel, keep)
  local files, dirs = list_dir(dst)
  local removed = 0
  for _, name in ipairs(files) do
    if not keep[rel .. name] and os.remove(dst .. sep .. name) then removed = removed + 1 end
  end
  for _, name in ipairs(dirs) do
    removed = removed + remove_stale(dst .. sep .. name, rel .. name .. "/", keep)
    os.remove(dst .. sep .. name) -- succeeds only if now empty
  end
  return removed
end

------------------------------------------------------------------------
-- Installation
------------------------------------------------------------------------

local errors = {}
local installed = {}
local updated = false

-- 1. Extension binary → UserPlugins/
local plugins_dir = resource_path .. sep .. "UserPlugins"
local ext_src = script_dir .. sep .. ext_name
if file_exists(ext_src) then
  ensure_dir(plugins_dir)
  remove_old_binaries(plugins_dir)
  local result, err = install_binary(ext_src, plugins_dir .. sep .. ext_name, plugins_dir)
  if result then
    updated = result == "updated"
    installed[#installed + 1] = "Extension: " .. ext_name
  else
    errors[#errors + 1] = err
  end
else
  errors[#errors + 1] = "Extension binary not found: " .. ext_name ..
    "\n(Expected at: " .. ext_src .. ")"
end

-- 2. Web frontend → reaper_www_root/web/ (REAmo's own folder)
local web_src = script_dir .. sep .. "web"
local web_dst = resource_path .. sep .. "reaper_www_root" .. sep .. "web"
if reaper.EnumerateFiles(web_src, 0) then
  local copied, web_errors = {}, {}
  copy_tree(web_src, web_dst, "", copied, web_errors)
  local count = 0
  for _ in pairs(copied) do count = count + 1 end
  installed[#installed + 1] = "Frontend: " .. count .. " files"
  if #web_errors == 0 then
    remove_stale(web_dst, "", copied)
  else
    -- Keep the old files: the new set is incomplete.
    for _, e in ipairs(web_errors) do errors[#errors + 1] = e end
  end
else
  errors[#errors + 1] = "Web frontend folder not found.\n(Expected at: " .. web_src .. ")"
end

-- 3. JSFX tuner → Effects/REAmo/
local jsfx_src = script_dir .. sep .. "effects" .. sep .. "REAmo" .. sep .. "PitchDetect.jsfx"
local jsfx_dst_dir = resource_path .. sep .. "Effects" .. sep .. "REAmo"
local jsfx_data = read_file(jsfx_src)
if jsfx_data then
  ensure_dir(jsfx_dst_dir)
  if write_file(jsfx_dst_dir .. sep .. "PitchDetect.jsfx", jsfx_data) then
    installed[#installed + 1] = "Tuner JSFX: PitchDetect.jsfx"
  else
    errors[#errors + 1] = "Cannot write " .. jsfx_dst_dir .. sep .. "PitchDetect.jsfx"
  end
else
  errors[#errors + 1] = "Tuner JSFX not found.\n(Expected at: " .. jsfx_src .. ")"
end

------------------------------------------------------------------------
-- Results
------------------------------------------------------------------------

local version = package_version()
local name = version and ("REAmo v" .. version) or "REAmo"

if #errors > 0 then
  reaper.ShowMessageBox(
    name .. " was not fully installed.\n\n" ..
    (#installed > 0 and ("Installed:\n  " .. table.concat(installed, "\n  ") .. "\n\n") or "") ..
    "Problems:\n  " .. table.concat(errors, "\n  ") .. "\n\n" ..
    "Fix the problem above and run the installer again.",
    "REAmo Install", 0)
elseif updated then
  reaper.ShowMessageBox(
    name .. " is installed.\n\n" ..
    "  " .. table.concat(installed, "\n  ") .. "\n\n" ..
    "Restart REAPER to finish the update: until then the previous\n" ..
    "version keeps running.",
    "REAmo Install", 0)
else
  reaper.ShowMessageBox(
    name .. " is installed.\n\n" ..
    "  " .. table.concat(installed, "\n  ") .. "\n\n" ..
    "Restart REAPER to load the extension, then go to:\n" ..
    "  Extensions > REAmo > Show QR Code\n" ..
    "and scan it with your phone to connect.",
    "REAmo Install", 0)
end
