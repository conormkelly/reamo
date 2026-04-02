# REAmo

A wireless, zero-config control surface for [REAPER](https://www.reaper.fm/). Transport, mixer, timeline, tuner, instruments — all from your phone or tablet. Supports WiFi and USB.

## What is it?

This was built to solve a specific problem: **staying at the instrument**.

You sit at the piano, get an idea, walk to the computer, set up a track, adjust levels, hit record, walk back, try to remember what you were playing... the moment's gone.

**With REAmo:** mount your phone near your instrument. Tap record, capture the idea, compare takes, move to the next section. End with rough ideas across the whole song instead of 16 over-polished bars.

The goal is **idea capture, not production**. Get the song down while you're in creative mode.

<!-- TODO: Demo video here -->

## Quick Start

1. **Download** the latest release from [Releases](../../releases)
2. **Run** `Install_REAmo.lua` in REAPER (Actions > Run ReaScript)
3. **Restart REAPER**
4. **Extensions > REAmo > Show QR Code** — scan it with your phone
5. **Add to Home Screen** for a native app feel

That's it. Same WiFi network, no account, no cloud.

## What You Get

| View | |
|------|---|
| **Timeline** | Waveforms, regions, markers, pinch-to-zoom, item selection |
| **Mixer** | Faders, meters, pan, mute/solo/arm, routing, FX, track details |
| **Clock** | Big transport controls, fully customizable layout |
| **Tuner** | Select a track, play a note, tune up |
| **Actions** | Custom button grid — REAPER actions, MIDI CC, Program Change |
| **Instruments** | Drum pads, piano keyboard, chord pads with MIDI out |
| **Notes** | Edit project notes from your device |

### Highlights

- **Recording workflow** — Scrap bad takes, retake from the same spot, A/B compare takes, auto-punch, tap tempo
- **Touch instruments** — Drum pads, scrollable piano, diatonic chord pads with strum and voice leading. Low-latency MIDI over WebSocket
- **Mix monitoring** — Stream REAPER's master output to your phone for quick A/B checks from the listening position
- **FX control** — Browse, add, reorder, and tweak FX parameters and presets from your device
- **Track routing** — Sends, receives, and hardware outputs with level/pan control
- **Custom toolbar** — Configurable buttons for any REAPER action, SWS extension, or MIDI command
- **Works everywhere** — Responsive on iPhone, iPad, Android, tablets. Remembers layout per device

For the full feature list, see [FEATURES.md](FEATURES.md).

## Coming Soon

- **Region Editing** — Drag-and-drop repositioning with ripple editing
- **Cue Lists** — Build playlists from regions for rehearsal and arrangement

## Installation

### Automatic (Recommended)

1. **Download** the latest `REAmo-vX.X.zip` from [Releases](../../releases)
2. **Extract** the ZIP file
3. In REAPER, run **Actions > ReaScript: Run ReaScript...** (Action ID: 41060)
4. Select `Install_REAmo.lua` from the extracted folder
5. **Restart REAPER**
6. *(Optional)* **Preferences > Media** — uncheck **Set media items offline when application is not active**. If enabled, REAPER takes media offline when you switch to another app, which prevents waveforms from loading on your device.

### Uninstall

Run `Uninstall_REAmo.lua` using the same Run ReaScript action.

<details>
<summary>Manual installation</summary>

Copy these files from the ZIP to your REAPER resource path (Options > Show REAPER resource path):

| File in ZIP | Copy to |
|-------------|---------|
| `reaper_reamo.dylib` / `.dll` / `.so` | `UserPlugins/` |
| `web/` (entire folder) | `reaper_www_root/web/` |
| `scripts/reamo_internal_fetch_peaks.lua` | `Scripts/Reamo/` |
| `effects/REAmo/PitchDetect.jsfx` | `Effects/REAmo/` |

Restart REAPER.

</details>

## Connecting

Scan the QR code: **Extensions > REAmo > Show QR Code**.

<details>
<summary>Advanced connection options</summary>

REAmo runs an HTTP server on your computer (default port 9224).

- **Same computer:** `http://localhost:9224/`
- **Other device:** `http://YOUR-IP:9224/` (shown in QR code dialog)
- **Change port:** Extensions > REAmo > Change Server Port
- **USB tethering:** Connect phone via USB for lowest latency. REAmo detects USB interfaces automatically.
- **Tailscale/VPN:** Add your hostname in Extensions > REAmo > Allowed Hosts

</details>

## For Developers

**Zig** extension (WebSocket server) + **React 19** / **TypeScript** / **Zustand** / **Tailwind CSS 4** frontend.

```bash
cd frontend && npm install && npm run dev   # Dev server with hot reload
make all                                     # Test + build everything
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for architecture and conventions. See [extension/API.md](extension/API.md) for the WebSocket API.

## Contributing

1. Fork the repo
2. Create a feature branch
3. Open a Pull Request

## License

MIT
