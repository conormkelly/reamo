# Mix Monitoring

Streams REAPER's master output to the phone as raw 16-bit PCM over the existing WebSocket. For mix checks and playback review, not for monitoring while recording (WebSocket is TCP: reliable, but not low latency).

Code: `extension/src/audio/` (`audio_hook.zig`, `ring_buffer.zig`, `stream.zig`, `commands.zig`); `frontend/src/audio/AudioStreamManager.ts`, `frontend/public/audio-worklet-processor.js`, `frontend/src/hooks/useAudioMonitor.ts`, `store/slices/audioMonitorSlice.ts`. Protocol: `audio/*` and the binary frame format in `extension/API.md`.

## Pipeline

- **Audio thread:** `Audio_RegHardwareHook` callback (`audio_hook.zig`). On `isPost=true` it reads `GetBuffer(true, 0)` and `GetBuffer(true, 1)` (non-interleaved f64), converts to interleaved i16 and writes to a lock-free SPSC ring buffer. No allocation, locks, I/O or logging.
- **Ring buffer:** 24000 stereo pairs (~500 ms at 48 kHz). When full, the whole new block is dropped (never a partial write, never moving the reader) and `overflow_count` goes up.
- **Network thread** (`stream.zig`): spawned with the first subscriber, joined when the last one leaves; the hook is registered and unregistered with it. Waits for at least 5 ms of audio, reads up to 10 ms, and sends one binary frame to each subscriber.
- **Frame:** 5-byte header (type byte `0x01`, u32 LE sequence) then interleaved i16 stereo. No per-frame position or sample rate: `audio/startStream`'s response carries the sample rate.
- **Silence gate:** a frame whose samples all stay below 8/32768 (~-72 dBFS) isn't sent; the client's jitter buffer drains and plays true silence.
- **Limits:** `MAX_AUDIO_CLIENTS = 4`.
- **Commands:** `audio/startStream`, `audio/stopStream`, `audio/status` (diagnostics; the app doesn't call it yet).

## Client

- `AudioContext` is created at the server's sample rate, so there's no resampling. `unlockAudio()` creates and resumes it inside the tap handler, which iOS requires; `start()` replaces it if the rate differs.
- **Secure contexts** (localhost, HTTPS): AudioWorklet, frames posted to the worklet.
- **Insecure contexts** (HTTP on the LAN, the usual case): no AudioWorklet, so frames are scheduled as `AudioBufferSourceNode`s on the main thread.
- Both paths decode frames with the same parser (`audioFrame.ts`) and wait for an 80 ms jitter buffer before playing.
- Stops when the page is hidden and resumes when it's visible again, or after a reconnect if monitoring was on.

## REAPER hook facts

- `isPost=true` is the post-master-FX output, what goes to the speakers.
- The hook keeps firing when the transport is stopped. The pre-callback zeroes the output buffers so a stopped transport gives silence rather than stale data repeating as a buzz; live input monitoring still comes through.
- It survives device, sample-rate and buffer-size changes without re-registering: read `len`, `srate` and channel counts on every call, never cache them.
- Only call `GetBuffer` inside the callback. REAPER may not set `output_nch` in the struct, so the code asks for channels 0 and 1 and null-checks instead.
- Struct definition: `docs/reaper_plugin.h` (`audio_hook_register_t`).

## Deliberately not done

- Opus or another codec: raw PCM at 48 kHz stereo is ~1.5 Mbps, trivial on a LAN, with no codec latency and no dependency.
- A separate audio socket or HTTP stream: binary frames on the existing connection reuse its auth and lifecycle.
- Background playback on iOS: Web Audio stops when the PWA is hidden or the screen locks.

## Known gaps

- Latency over WiFi and USB hasn't been measured.
- No monitor volume, mono/stereo switch, latency or buffer-health display, or adaptive jitter buffer (fixed 80 ms).
- If REAPER's "Close audio device when stopped and application is inactive" is on, the engine stops and so does the stream; the app doesn't tell the user. `Audio_IsRunning()` (thread-safe) could detect it.

## Future work notes

Compression:

- QOA first if bandwidth matters: ~5:1, single C file (phoboslab/qoa), ports to Zig, a JS decoder exists, ~0.4 ms codec latency. IMA ADPCM (~4:1) is simpler; ADPCM-XQ adds noise shaping with standard decoding.
- Opus for WAN: build libopus with hexops/opus as a Zig build dependency (native `build.zig`, cross-compiles).
  - Opus's CTL macros are variadic and `@cImport` won't translate them: call `opus_encoder_ctl` with the request code, e.g. `OPUS_SET_BITRATE_REQUEST` = 4002.
  - Real-time-safe setup: `opus_encoder_get_size` + `opus_encoder_init` into memory we allocate (`opus_encoder_create` mallocs). `opus_encode_float` doesn't allocate.
  - 960-sample (20 ms) frames at 48 kHz. Opus doesn't accept 44.1 kHz: resample (libspeexdsp) or ask for a 48 kHz project.
  - Quality presets considered: voice 24 kbps mono, low 48 kbps, medium 96 kbps, high 128 kbps stereo.
- Browser decode: the `opus-decoder` WASM package inside the AudioWorklet (inline WASM, no fetch; untested on iOS). WebCodecs `AudioDecoder` only from iOS 26, with reported Opus bugs: check `AudioDecoder.isConfigSupported()`. Ogg through `decodeAudioData` isn't viable: 50-200 ms per call.
- Adaptive bitrate could use the clock sync's RTT estimate.

Listening with the phone locked (iOS):

- Only a playing `<audio>` element keeps a PWA alive in the background (iOS 15.4+), with lock-screen controls through the Media Session API. So it needs an HTTP audio stream the `<audio>` element can play.
- Caveats: a ~30 s pause suspends the process; background track transitions are broken on iOS 16-17; iOS 18 has reports of background audio muting.
- MediaSource Extensions can't feed WebSocket audio into `<audio>` on iOS.
- A silent looping `<audio>` to keep the process alive is fragile (newer iOS may ignore it). There's no Wake Lock on iOS Safari.

Other:

- SharedArrayBuffer ring buffer: needs `Cross-Origin-Embedder-Policy: require-corp` as well as the COOP header the server already sends (Safari has no `credentialless`).
- Per-track monitoring, a separate cue mix, click-only to the phone.
