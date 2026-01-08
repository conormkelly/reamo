# REAmo

A modern web control surface for [REAPER](https://www.reaper.fm/), designed for songwriting workflows. Control transport, tracks, and more from your iPad or tablet while staying at your instrument.

## Installation

### Automatic (Recommended)

1. **Download** the latest `REAmo-vX.X.zip` from [Releases](../../releases)
2. **Extract** the ZIP file
3. **Open REAPER** and open the **Actions** menu (shortcut: `?` or `Cmd+?` on Mac, `Ctrl+?` on Windows)
4. Search for and run: **"ReaScript: Run ReaScript (EEL, Lua, or Python)..."** (Action ID: 41060)
5. Select `Install_REAmo.lua` from the extracted folder
6. **Follow the prompts** to complete installation

After installation, enable REAPER's web server:

1. Go to **Preferences > Web interface** (or **Control/OSC/Web** on older versions)
2. Check **Enable**
3. Set port (default: 8080)
4. Restart REAPER

Access REAmo at `http://localhost:8080/reamo.html` (or your computer's IP for other devices).

### Uninstall

Run `Uninstall_REAmo.lua` from the original extracted folder using the same "Run ReaScript" action.

### Manual Installation

<details>
<summary>Click to expand manual steps</summary>

If the automatic installer doesn't work:

1. Copy `reamo.html` to your REAPER www folder:
   - **macOS**: `~/Library/Application Support/REAPER/reaper_www_root/`
   - **Windows**: `%APPDATA%\REAPER\reaper_www_root\`
   - **Linux**: `~/.config/REAPER/reaper_www_root/`

2. Enable REAPER's web server (see below)

</details>

### REAPER Web Server Setup

1. Open **REAPER**
2. Go to **Options** > **Preferences** (or press `Cmd+,` / `Ctrl+,`)
3. Navigate to **Control/OSC/Web** in the left sidebar
4. Click **Add** and select **Web browser interface**
5. Configure:
   - **Port**: 8080 (or choose another)
   - **Default interface**: Set to `reamo.html`
6. Click **OK** to save
7. Find your computer's IP address (System Preferences > Network on macOS, or `ipconfig` on Windows)
8. On your tablet, open: `http://YOUR-IP:8080/reamo.html`

---

## Views

REAmo provides multiple views accessible via the tab bar at the bottom. Double-tap to toggle full-screen mode (hide tab bar and transport).

| View | Description |
|------|-------------|
| **Studio** | All-in-one default view: transport, timeline, mixer in one screen |
| **Mixer** | (Coming soon) Dedicated full-screen mixer |
| **Clock** | Large transport display with big play/pause/stop/record buttons |
| **Cues** | Playlist manager for building setlists from regions |
| **Actions** | User-configurable button grid for REAPER actions and MIDI |
| **Notes** | Project notes editor with external change detection |

---

## Features

### Transport Control
- Play, pause, stop, record with visual feedback
- Seek to position via timeline tap or time display input
- Go to start/end of project or time selection

### Recording Workflow
- **Scrap** - Delete the current take and continue (removes bad takes instantly)
- **Retake** - Delete the current take and restart recording from the same position
- **Keep** - Stop recording and keep the take
- Quick actions bar visible during recording (toggleable in settings)

### Track Mixer
- Volume faders with dB readout
- Pan knobs
- Mute, solo, record arm, input monitoring buttons
- Real-time level metering (30Hz updates)
- Clip indicators (tap to clear)
- Master track mono/stereo toggle
- Mixer lock to prevent accidental changes

### Timeline
- Interactive timeline showing regions, markers, and playhead
- Time selection display with bar.beat notation
- Tap regions/markers to navigate
- Visual item density blobs showing where recordings exist

### Region Editing
- Drag regions to reposition
- Resize regions by dragging edges
- Ripple editing (subsequent regions shift automatically)
- Add, rename, delete, and color regions
- Full undo/redo support

### Marker Management
- Navigate between markers
- Add markers at cursor position
- Inline name and color editing
- Auto-advance to next marker during playback (optional)

### Time Selection
- Set precise start/end points
- Bar.beat notation input
- Quick clear option
- Visual highlight on timeline

### Tempo and Time Signature
- Display and set BPM (2-960 range)
- Tap tempo with visual feedback
- Time signature control (numerator: 1-32, denominator: 2/4/8/16)

### Auto-Punch Recording
- Set time selection for punch-in/punch-out boundaries
- Visual indicators for punch region

### Take Management
- Switch between takes on selected items
- A/B compare takes without touching the computer
- Delete active take, crop to active take

### Cue Lists (Playlists)
- Build playlists from project regions
- Set loop count per entry (1x, 2x, infinite)
- Drag to reorder entries
- Play/pause/stop/skip controls
- Visual progress bar within current region
- "Advance after loop" to exit infinite loops gracefully
- Auto-advance through playlist during playback
- Playlists persist with the project file

### Custom Toolbar
- User-configurable buttons for any REAPER action
- Support for native actions, SWS actions, and custom scripts
- MIDI CC and Program Change output for hardware control
- Customizable icons (from lucide-react library) and colors
- Toggle actions show current state
- Multiple sections for organization

### Project Notes
- View and edit REAPER project notes
- External change detection (warns if notes edited in REAPER)
- Character limit with counter (5000 chars)

### Touch-Optimized
- Gesture support for mobile/tablet control surfaces
- Long-press for context actions
- Responsive layout for iPhone and iPad
- Collapsible sections to maximize screen space

### Network Sync
- NTP-style clock synchronization for accurate beat display
- Achieves ±15ms visual accuracy over WiFi
- Real-time sync diagnostics (long-press connection indicator)
- Manual offset adjustment for perceived sync issues

---

## Limitations

Current limitations to be aware of:

- **No waveform editing** - View waveforms but no split/glue/crossfade
- **No MIDI editing** - Audio items only, MIDI items shown as blocks
- **No comping lanes** - Basic take switching only
- **No FX parameter control** - FX presets work but individual parameters are not exposed
- **No send level UI** - Backend supports sends, frontend UI pending
- **Single user** - Designed for single-user home studio, not multi-user

---

## Why REAmo?

This project was built to solve a specific songwriting problem: **staying at the instrument**.

The typical home recording workflow kills creativity. You sit at the piano, get an idea, walk to the computer, set up a track, adjust levels, hit record, walk back, try to remember what you were playing... by then the moment's gone. Worse, you end up polishing 16 bars forever while the song goes nowhere.

**The REAmo workflow:**

1. **Pre-structure or start blank** - Set up a REAPER project with regions (intro, verse, chorus, bridge, outro) or start completely fresh
2. **Stay at your instrument** - Mount an iPad near your piano/guitar running REAmo
3. **Tap in the tempo** - No need to touch the computer, dial in or tap the BPM from your playing position
4. **Capture ideas in boxes** - Each region is a container for an idea. Record a rough verse, move to the chorus, try a bridge. Use auto-punch to nail specific sections
5. **Compare takes on the fly** - Not sure if that last take was better? Long-press the track, switch between takes to A/B compare without touching the computer
6. **Build a cue list** - Arrange regions into a playlist to hear your song structure without duplicating audio
7. **End with a scaffold** - Instead of 16 over-produced bars, you have rough ideas across the whole song structure recorded to a click

The goal is **idea capture, not production**. Get the song down while you're in creative mode. The engineering can wait.

---

## For Developers

### Tech Stack

- **Zig** native REAPER extension (WebSocket server)
- **React 19** + **TypeScript 5.9** frontend
- **Vite 7** with single-file output
- **Zustand** for state management
- **Tailwind CSS 4** for styling

### Quick Start

```bash
cd frontend
npm install
npm run dev          # Dev server with hot reload
```

### Build & Test

```bash
make all             # Run tests, build extension + frontend
make test            # Run all test suites
make extension       # Build Zig extension (installs to REAPER)
make frontend        # Build frontend (outputs reamo.html)
```

### Architecture

The app uses a **WebSocket-based architecture**:

1. **Zig extension** runs inside REAPER, polls state at ~30ms, broadcasts JSON events
2. **React frontend** receives events, sends commands back over WebSocket
3. **Zustand store** manages state, components subscribe to slices

See [DEVELOPMENT.md](DEVELOPMENT.md) for detailed architecture, API conventions, and gotchas.

See [extension/API.md](extension/API.md) for the complete WebSocket API reference.

---

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

MIT
