REAmo v0.7.0
Control REAPER from your phone. Free, open source, zero config.
https://github.com/conormkelly/reamo

================================================================================
INSTALL
================================================================================

1. Extract this ZIP anywhere
2. Open REAPER
3. Actions > Run ReaScript > Run ReaScript... (or just drag Install_REAmo.lua
   into REAPER)
4. Select Install_REAmo.lua from the extracted folder
5. Restart REAPER
6. Extensions > REAmo > Show QR Code
7. Scan the QR code with your phone

Tip: Add to your home screen as a PWA for fullscreen (no browser address bar etc).

Supports Windows, macOS (Intel + Apple Silicon), and Linux.
Works on iPhone, iPad, Android - anything with a browser.
WiFi and USB tethering supported.

================================================================================
UNINSTALL
================================================================================

Option A: Uninstall script
  1. Open REAPER
  2. Actions > Run ReaScript > Uninstall_REAmo.lua
  3. Restart REAPER

Option B: Manual uninstall
  On Windows, the extension DLL is locked while REAPER is running, so the
  uninstall script may not be able to remove it. To uninstall manually:

  1. Close REAPER
  2. Delete the following files/folders:

  WINDOWS:
    C:\Users\<you>\AppData\Roaming\REAPER\UserPlugins\reaper_reamo.dll
    C:\Users\<you>\AppData\Roaming\REAPER\reaper_www_root\web\
    C:\Users\<you>\AppData\Roaming\REAPER\Effects\REAmo\

  macOS:
    ~/Library/Application Support/REAPER/UserPlugins/reaper_reamo.dylib
    ~/Library/Application Support/REAPER/reaper_www_root/web/
    ~/Library/Application Support/REAPER/Effects/REAmo/

  LINUX:
    ~/.config/REAPER/UserPlugins/reaper_reamo.so
    ~/.config/REAPER/reaper_www_root/web/
    ~/.config/REAPER/Effects/REAmo/

  PORTABLE INSTALL (any OS):
    Same paths, but inside your portable REAPER folder.

================================================================================
CRASH TO DESKTOP FIX
================================================================================

If REAPER crashes at startup after installing REAmo:

WINDOWS:
  1. Go to C:\Users\<you>\AppData\Roaming\REAPER\UserPlugins
  2. Rename "reaper_reamo.dll" to anything else (e.g. "old_reamo.dll")
  3. Start REAPER (it should now open normally)
  4. Actions > Run ReaScript > Uninstall_REAmo.lua
  5. Delete the renamed .dll

macOS:
  1. Go to ~/Library/Application Support/REAPER/UserPlugins
  2. Rename "reaper_reamo.dylib" to anything else (e.g. "old_reamo.dylib")
  3. Start REAPER
  4. Actions > Run ReaScript > Uninstall_REAmo.lua
  5. Delete the renamed .dylib

LINUX:
  1. Go to ~/.config/REAPER/UserPlugins
  2. Rename "reaper_reamo.so" to anything else (e.g. "old_reamo.so")
  3. Start REAPER
  4. Actions > Run ReaScript > Uninstall_REAmo.lua
  5. Delete the renamed .so

PORTABLE INSTALL (any OS):
  Same steps, but the UserPlugins folder is inside your portable REAPER folder.

================================================================================
ISSUES / FEEDBACK
================================================================================

If you run into any problems, please let me know:

  GitHub: https://github.com/conormkelly/reamo/issues
  Reddit: u/ck-reamo

When reporting a crash, it helps to know:
  - Your OS and version (e.g. Windows 11, macOS Sonoma)
  - CPU architecture (Intel / AMD / Apple Silicon)
  - REAPER version
