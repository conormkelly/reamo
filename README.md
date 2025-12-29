# Reamo

A modern web control surface for [REAPER](https://www.reaper.fm/), designed for songwriting workflows. Control transport, tracks, and more from your iPad or tablet while staying at your instrument.

## Installation

### Automatic (Recommended)

1. **Download** the latest `Reamo-vX.X.zip` from [Releases](../../releases)
2. **Extract** the ZIP file
3. **Open REAPER** and open the **Actions** menu (shortcut: `?` or `Cmd+?` on Mac, `Ctrl+?` on Windows)
4. Search for and run: **"ReaScript: Run ReaScript (EEL, Lua, or Python)..."** (Action ID: 41060)
5. Select `Install_Reamo.lua` from the extracted folder
6. **Follow the prompts** to complete installation

After installation, enable REAPER's web server:

1. Go to **Preferences > Web interface** (or **Control/OSC/Web** on older versions)
2. Check **Enable**
3. Set port (default: 8080)
4. Restart REAPER

Access Reamo at `http://localhost:8080/reamo.html` (or your computer's IP for other devices).

### Uninstall

Run `Uninstall_Reamo.lua` from the original extracted folder using the same "Run ReaScript" action.

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

## Features

- **Transport Control** - Play, pause, stop, record with visual feedback
- **Recording Workflow** - Scrap (delete take), Retake (delete and restart), or Keep (stop recording) - quick actions visible during recording
- **Track Management** - Volume faders, pan knobs, mute/solo/arm, real-time level metering
- **Timeline Visualization** - Interactive timeline with regions, markers, playhead, and time selection
- **Region Editing** - Drag, resize, and reorder regions directly on the timeline with ripple editing and full undo/redo support
- **Marker Management** - Navigate between markers, add/move/delete markers, inline name and color editing with auto-advance during playback
- **Time Selection** - Set precise start/end points using bar.beat notation or time, with quick clear option
- **Tempo Control** - Display BPM, tap tempo, set exact tempo
- **Auto-Punch Mode** - Time selection recording with visual indicators
- **Take Switching** - A/B compare takes without leaving your instrument
- **Toolbar** - User-configurable buttons for REAPER actions, SWS/scripts, and MIDI CC/PC with customizable icons and colors
- **Touch-Optimized** - Gesture support for mobile/tablet control surfaces, responsive layout for iPhone and iPad

## Why Reamo?

This project was built to solve a specific songwriting problem: **staying at the instrument**.

The typical home recording workflow kills creativity. You sit at the piano, get an idea, walk to the computer, set up a track, adjust levels, hit record, walk back, try to remember what you were playing... by then the moment's gone. Worse, you end up polishing 16 bars forever while the song goes nowhere.

**The Reamo workflow:**

1. **Pre-structure or start blank** - Set up a REAPER project with regions (intro, verse, chorus, bridge, outro) or start completely fresh
2. **Stay at your instrument** - Mount an iPad near your piano/guitar running Reamo
3. **Tap in the tempo** - No need to touch the computer, dial in or tap the BPM from your playing position
4. **Capture ideas in boxes** - Each region is a container for an idea. Record a rough verse, move to the chorus, try a bridge. Use auto-punch to nail specific sections
5. **Compare takes on the fly** - Not sure if that last take was better? Long-press the track, switch between takes to A/B compare without touching the computer
6. **End with a scaffold** - Instead of 16 over-produced bars, you have rough ideas across the whole song structure recorded to a click

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
