# REAmo Features

Detailed feature list for REAmo. For quick start and installation, see [README.md](README.md).

---

## Transport Control

- Play, pause, stop, record with visual feedback
- Seek to position via timeline tap or time display input
- Go to start/end of project or time selection

## Recording Workflow

- **Scrap** — Delete the current take and continue (removes bad takes instantly)
- **Retake** — Delete the current take and restart recording from the same position
- **Keep** — Stop recording and keep the take
- Quick actions bar visible during recording (toggleable in settings)

## Track Mixer

- Volume faders with dB readout
- Pan knobs
- Mute, solo, record arm, input monitoring
- Real-time level metering
- Clip indicators (tap to clear)
- Master track mono/stereo toggle
- Mixer lock to prevent accidental changes
- Track banks and filters (All, Folders, Armed, Muted, etc.)
- Track detail modal with routing, FX chain, and input selection

## Timeline

- Regions, markers, and playhead
- Multi-track lanes with waveform display (stereo split view)
- Pinch-to-zoom with smooth momentum scrolling
- Follow playhead toggle
- Time selection display with bar.beat notation
- Tap regions/markers to navigate
- Tap items to select, with multi-select support

## Markers

- Navigate between markers
- Long-press time display to open marker sheet with tap-to-jump
- Add markers at cursor position
- Inline name and color editing
- Auto-advance to next marker during playback (optional)

## Time Selection

- Set precise start/end points
- Bar.beat notation input
- Quick clear option

## Tempo and Time Signature

- Display and set BPM (2–960 range)
- Tap tempo with visual feedback
- Time signature control (numerator: 1–32, denominator: 2/4/8/16)

## Auto-Punch Recording

- Set time selection for punch-in/punch-out boundaries
- Visual indicators for punch region

## Take Management

- Switch between takes on selected items
- A/B compare takes without touching the computer
- Delete active take, crop to active take
- Color-based take rating: green (good), orange (maybe), red (bad)

## Touch Instruments

- **Drum Pads** — 4x4 GM drum grid with multi-touch support
- **Piano Keyboard** — Scrollable C0–C7 keyboard with octave selector, mod wheel, pitch bend, 8va/8vb transposition
- **Chord Pads** — Diatonic chords with key/scale selector, bass notes, strum mode, and adaptive voice leading
- Low-latency MIDI via WebSocket
- Per-instrument MIDI channel selection

## Mix Monitoring

- Stream REAPER's master output to your phone speakers or headphones
- Hear your mix from the listening position
- Works over WiFi (80–150ms latency) and USB (50–100ms)
- Automatic reconnection when backgrounding/foregrounding
- **Note:** Designed for mix checks and playback review, not live monitoring while recording
- **iPhone:** Make sure the silent/ring switch is set to ring — it silences all Web Audio output

## FX Control

- Browse and add FX plugins (VST3, VST2, AU, JS) via searchable list
- View and control FX parameters with real-time feedback
- Preset browsing and selection
- Enable/disable individual FX
- Reorder FX chain via drag-and-drop

## Track Routing

- View, create, and delete sends, receives, and hardware outputs
- Track picker for send destinations and receive sources
- Hardware output channel picker with stereo pairs and mono outputs
- Adjust send/receive/hw output levels and pan

## Folder Navigation

- Folder icon badges with child count
- Folder navigation sheet with breadcrumb trail
- Filter tracks by folder (tap folder badge to focus)
- Combine folder view with property filters

## Custom Toolbar

- Configurable buttons for any REAPER action
- Support for native actions, SWS actions, and custom scripts
- MIDI CC and Program Change output for hardware control
- Customizable icons and colors
- Toggle actions show current state
- Swipe between toolbar pages
- In-app edit mode: add, remove, and rearrange buttons

## Project Notes

- View and edit REAPER project notes from your device
- Warns if notes were edited in REAPER while you were editing on your device

## General

- Responsive layout for iPhone, iPad, and Android tablets
- Long-press for context actions throughout the app
- Per-device layout memory: remembers your active view, bank selection, filters, viewport position, and instrument channels separately for each device
- Automatic frontend updates when the extension version changes

## Limitations

- **No waveform editing** — View waveforms but no split/glue/crossfade
- **No MIDI editing** — Audio items only, MIDI items shown as blocks
- **No comping lanes** — Basic take switching only
- **No automation editing** — View automation but no touch-based drawing yet
- **Single user** — Designed for single-user home studio
- **Touch instrument speed** — Very rapid alternating touches may miss triggers on iOS Safari due to browser gesture detection. Fine for punching in ideas; a native app would be needed for virtuoso drum performances
