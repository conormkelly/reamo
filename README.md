# REAmo

A modern web control surface for [REAPER](https://www.reaper.fm/), designed for songwriting workflows. Control transport, tracks, and more from your iPad or tablet while staying at your instrument.

## Quick Start

1. **Install** REAmo ([see Installation](#installation))
2. **Restart REAPER**
3. Go to **Extensions > REAmo > Show QR Code**
4. **Scan the QR code** with your phone or tablet
5. **Add to Home Screen** for a full-screen app experience

That's it. Your phone and computer just need to be on the same WiFi network.

## Installation

### Automatic (Recommended)

1. **Download** the latest `REAmo-vX.X.zip` from [Releases](../../releases)
2. **Extract** the ZIP file
3. **Open REAPER** and open the **Actions** menu (shortcut: `?` or `Cmd+?` on Mac, `Ctrl+?` on Windows)
4. Search for and run: **"ReaScript: Run ReaScript (EEL, Lua, or Python)..."** (Action ID: 41060)
5. Select `Install_REAmo.lua` from the extracted folder
6. **Follow the prompts** to complete installation
7. **Restart REAPER**

### Uninstall

Run `Uninstall_REAmo.lua` from the original extracted folder using the same "Run ReaScript" action.

### Manual Installation

<details>
<summary>Click to expand manual steps</summary>

If the automatic installer doesn't work, copy these files from the extracted ZIP to your REAPER resource path. Find it in REAPER via Options > Show REAPER resource path.

| File in ZIP | Copy to |
|-------------|---------|
| `reaper_reamo.dylib` / `.dll` / `.so` | `UserPlugins/` |
| `web/` (entire folder) | `reaper_www_root/web/` |
| `scripts/reamo_internal_fetch_peaks.lua` | `Scripts/Reamo/` |
| `effects/REAmo/PitchDetect.jsfx` | `Effects/REAmo/` |

Then restart REAPER.

</details>

## Connecting Your Device

The easiest way to connect is the **QR code**: go to **Extensions > REAmo > Show QR Code** and scan it with your phone or tablet's camera.

You can also use **Extensions > REAmo > Show Network Addresses** to see all available URLs.

The **Extensions > REAmo** menu also shows the current server port next to "Change Server Port...".

<details>
<summary>Advanced: Manual connection and configuration</summary>

REAmo runs its own HTTP server on your computer (default port 9224). Any device on the same network can connect by opening the URL in a browser.

**On the same computer:** `http://localhost:9224/`

**From another device:** Find your computer's IP address and open `http://YOUR-IP:9224/` in a browser. Your IP is shown in the QR code dialog and the Network Addresses dialog.

**Changing the port:** Go to **Extensions > REAmo > Change Server Port...** to pick a different port. The server restarts immediately and the new port is remembered across REAPER sessions.

**USB tethering:** For the lowest latency or when no WiFi is available, connect your phone via USB cable. REAmo detects USB network interfaces automatically. See the Network Addresses dialog for platform-specific setup instructions.

**Allowed hosts (Tailscale, VPN, custom DNS):** REAmo protects against DNS rebinding attacks by only accepting connections from private IP addresses (127.x, 10.x, 192.168.x, etc.) and `.local` mDNS hostnames. If you connect via a Tailscale network, VPN, or custom DNS hostname, you may need to add your hostname to the allow list. Go to **Extensions > REAmo > Allowed Hosts...** and add your hostname (e.g., `mypc.tailnet.ts.net`). Multiple hostnames can be comma-separated. Your computer's hostname is added automatically.

</details>

---

## Views

REAmo provides multiple views accessible via the tab bar at the bottom. Double-tap to toggle full-screen mode (hide tab bar and transport).

| View | Description |
|------|-------------|
| **Timeline** | Interactive timeline with regions, markers, waveforms, pinch-to-zoom, and item selection |
| **Mixer** | Full-screen mixer with faders, meters, pan, mute/solo/arm, and track detail modals |
| **Clock** | Large transport display with big play/pause/stop/record buttons. Fully customizable: show/hide elements, resize, and reorder via edit mode |
| **Tuner** | Chromatic tuner with sub-cent accuracy. Auto-inserts a pitch detection plugin on your track's input FX chain |
| **Actions** | User-configurable button grid for REAPER actions and MIDI |
| **Instruments** | Touch instruments: drum pads, piano keyboard, and chord pads |
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
- Track banks and filters (All, Folders, Armed, Muted, etc.)
- Track detail modal with routing, FX chain, and input selection

### Timeline

- Interactive timeline showing regions, markers, and playhead
- Multi-track lanes with waveform display (stereo split view)
- Pinch-to-zoom with smooth momentum scrolling
- Follow playhead toggle (also serves as zoom anchor)
- Time selection display with bar.beat notation
- Tap regions/markers to navigate
- Tap items to select, with multi-select support

### Marker Management

- Navigate between markers
- Long-press time display to open marker sheet with tap-to-jump navigation
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
- Color-based take rating: mark takes as good (green), maybe (orange), or bad (red)
- Colors follow REAPER's priority chain (take color > item color > theme default)

### Touch Instruments

- **Drum Pads** - 4x4 GM drum grid with multi-touch support (portrait mode)
- **Piano Keyboard** - 2-octave keyboard with octave selector, mod wheel, pitch bend (landscape mode)
- **Chord Pads** - Diatonic chords with key/scale selector, inversions, bass notes, strum mode, and voice leading (landscape mode)
- Low-latency MIDI via WebSocket (5-15ms, matches Logic Remote)
- Per-instrument MIDI channel selection

### Mix Monitoring

- Stream REAPER's master output to your phone speakers or headphones
- Hear your mix from the listening position without headphone cables
- Quick A/B checks: flip the mute switch, listen on phone, flip back
- Works over WiFi (typical latency: 80-150ms) and USB tethering (50-100ms)
- Automatic reconnection when backgrounding/foregrounding the app
- **Note:** Latency is too high for real-time monitoring while recording. This is designed for mix checks and playback review, not live cue mixes
- **iPhone users:** Make sure the silent/ring switch on the side of your phone is set to ring (orange not visible). The mute switch silences all Web Audio output and there is no on-screen indicator

### FX Control

- Browse and add FX plugins (VST3, VST2, AU, JS) via searchable list
- View and control FX parameters with real-time feedback
- Preset browsing and selection
- Enable/disable individual FX
- Reorder FX chain via drag-and-drop

### Track Routing

- View, create, and delete sends, receives, and hardware outputs per track
- Track picker for choosing send destinations and receive sources
- Hardware output channel picker with stereo pairs and mono outputs
- Adjust send/receive/hw output levels and pan with gesture-based undo coalescing
- Two-tap delete confirmation (tap to arm, tap again to confirm)

### Folder Navigation

- Folder icon badges on folder tracks with child count
- Folder navigation sheet with breadcrumb trail
- Filter tracks by folder (tap folder badge to focus)
- Combine folder view with property filters (Armed, Muted, etc.)

### Custom Toolbar

- User-configurable buttons for any REAPER action
- Support for native actions, SWS actions, and custom scripts
- MIDI CC and Program Change output for hardware control
- Customizable icons (from lucide-react library) and colors
- Toggle actions show current state
- Swipe between toolbar pages for organization
- In-app edit mode: add, remove, and rearrange buttons without leaving REAmo

### Project Notes

- View and edit REAPER project notes
- External change detection (warns if notes edited in REAPER)
- Character limit with counter (5000 chars)

### Touch-Optimized

- Gesture support for mobile/tablet control surfaces
- Long-press for context actions
- Responsive layout for iPhone and iPad
- Collapsible sections to maximize screen space
- Per-device layout memory: remembers your active view, bank selection, filters, viewport position, and instrument channels separately for each device

### Network Sync

- NTP-style clock synchronization for accurate beat display
- Achieves ±15ms visual accuracy over WiFi
- Real-time sync diagnostics (long-press connection indicator)
- Manual offset adjustment for perceived sync issues

### Auto-Update

- Automatic version detection compares installed frontend against extension version
- Silent update on version mismatch: hard refresh + cache cleanup with no user intervention
- Ensures PWA users always run the matching frontend version

---

## Limitations

Current limitations to be aware of:

- **No waveform editing** - View waveforms but no split/glue/crossfade operations
- **No MIDI editing** - Audio items only, MIDI items shown as blocks
- **No comping lanes** - Basic take switching only
- **No automation editing** - View automation but no touch-based drawing yet
- **Single user** - Designed for single-user home studio, not multi-user
- **Touch instrument speed** - Rapid alternating touches (faster than 16th notes at 120 BPM) may miss triggers on iOS Safari due to browser gesture detection. This is a Safari limitation, not fixable in a PWA. For punching in ideas to quantize later, this is fine; for virtuoso drum performances, a native app would be needed

---

## Coming Soon

- **Region Editing** — Drag-and-drop region repositioning with ripple editing, undo/redo
- **Cue Lists** — Build playlists from regions for rehearsal and arrangement experiments

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
make frontend        # Build frontend (outputs index.html)
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
