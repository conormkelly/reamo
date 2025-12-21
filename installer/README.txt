================================================================================
                         REAMO - REAPER Web Control
================================================================================

Control REAPER from any device on your network using a web browser.


INSTALLATION
------------

1. Extract this ZIP file to any location

2. Open REAPER

3. Open the Actions menu (shortcut: ? or Cmd+? on Mac, Ctrl+? on Windows)

4. Search for and run: "ReaScript: Run ReaScript (EEL, Lua, or Python)..."
   (Action ID: 41060)

5. Navigate to the extracted folder and select "Install_Reamo.lua"

6. Click "Yes" to confirm installation

7. Enable REAPER's web server:
   - Go to: Options > Preferences > Web interface
   - Check "Enable"
   - Set port (default: 8080)
   - Set "Default interface" to: reamo.html
   - Click OK

8. Restart REAPER


ACCESSING REAMO
---------------

After installation and restart:

  From this computer:
    http://localhost:8080/reamo.html

  From other devices on your network:
    http://YOUR_COMPUTER_IP:8080/reamo.html

    (Find your IP: Mac > System Settings > Network
                   Windows > ipconfig in Command Prompt)


PORTABLE INSTALLS
-----------------

Reamo fully supports portable REAPER installations. The installer automatically
detects portable mode and installs to the correct location within your portable
REAPER folder. All paths are relative to your REAPER resource directory.


UNINSTALLING
------------

1. Open REAPER

2. Open the Actions menu (shortcut: ? or Cmd+? on Mac, Ctrl+? on Windows)

3. Search for and run: "ReaScript: Run ReaScript (EEL, Lua, or Python)..."

4. Select "Uninstall_Reamo.lua" from the original extracted folder

5. Confirm removal and restart REAPER


FEATURES
--------

- Transport controls (play, stop, record, etc.)
- Timeline navigation
- Marker and region management
- Region editing (drag, resize, rename, recolor)
- Marker editing (rename, recolor)
- Works on phones, tablets, and computers


TROUBLESHOOTING
---------------

"Cannot connect to REAPER"
  > Make sure REAPER's web server is enabled (Preferences > Web interface)
  > Check that the port matches (default: 8080)
  > Restart REAPER after enabling

"Scripts not running"
  > Restart REAPER (scripts auto-start after installation)
  > Check Actions list for any error messages

"Cannot access from other devices"
  > Ensure devices are on the same network
  > Check firewall settings on your computer
  > Use your computer's local IP, not localhost


SUPPORT
-------

GitHub: https://github.com/conor/reamo
Issues: https://github.com/conor/reamo/issues


LICENSE
-------

MIT License - See LICENSE file for details.
