# Streaming large tile payloads over WebSocket to mobile browsers

**Sending 1.5MB JSON over WebSocket crashes because the payload exceeds the kernel's default ~128-256KB send buffer, and the server's unhandled `WouldBlock` error either panics or spins.** The fix is a layered approach: shrink the payload 20-30× through binary quantization, implement proper non-blocking write handling with per-client send queues, and switch from server-push flooding to a client-driven pull model with viewport-center priority ordering. Production systems solving identical problems — BBC Peaks.js for waveform data, Leaflet/Mapbox for map tiles, Valve Source Engine for game state — converge on remarkably similar patterns that map directly to this architecture.

---

## The payload is 20× larger than it needs to be

The single highest-impact change is switching from JSON text to a custom binary format with quantized integers. BBC's audiowaveform project — the production standard for waveform peak data, powering BBC Radio's archive and the widely-deployed Peaks.js library — uses **8-bit integers** for waveform display data, not floats. Their reasoning is sound: a waveform display is 100-300 pixels tall, so 256 quantization levels (int8, range -128 to +127) maps roughly 1:1 to pixel resolution. No visual information is lost. The BBC explicitly recommends 8-bit over 16-bit for wire transfer.

The math for this system's payloads is dramatic. With ~50,000 min/max pairs across 250 tiles, the current JSON representation costs roughly 25 bytes per pair (decimal digits, brackets, commas) totaling ~1.5MB. Binary int8 pairs cost exactly 2 bytes each — **~100KB total** plus small per-tile headers. With deflate compression on the binary payload, the wire size drops to **~50-80KB**, a 20-33× reduction. On mobile WiFi, transfer time falls from ~2.6 seconds to under 100 milliseconds.

The conversion is trivial: `int8_value = clamp(round(float_value * 127.0), -128, 127)` on the server, `float_value = int8_value / 127.0` on the client. For the wire format, a custom binary protocol outperforms general-purpose serializers like MessagePack or CBOR. Those formats add 1-9 bytes of type-tag overhead per value — wasteful for homogeneous numeric arrays where every element has the same type. MessagePack's byte-frequency distribution also defeats Huffman encoding, meaning compressed MessagePack can actually be *larger* than compressed JSON, according to the msgpackr library author.

The recommended wire format uses a **16-byte fixed header** per message (inspired by BBC's .dat format):

| Offset | Type | Field |
|--------|------|-------|
| 0 | u8 | Message type (0x01=tile data, 0x03=tile request, etc.) |
| 1 | u8 | LOD level |
| 2-3 | u16 LE | Flags (compressed, dirty, partial) |
| 4-7 | u32 LE | Tile ID |
| 8-11 | u32 LE | Payload length in bytes |
| 12-15 | u32 LE | Sequence number |

Payload follows immediately: raw int8 min/max pairs. In Zig, this is a zero-copy `extern struct` cast to `[]const u8`; in the browser, `DataView` parses the header while `new Int8Array(buffer, 16)` creates a zero-copy typed array view over the payload. **Always set `ws.binaryType = 'arraybuffer'`** on the client — the default `'blob'` requires an async conversion step that adds latency and complicates sequencing.

For compression, use **application-level deflate** rather than WebSocket's permessage-deflate extension. Safari has a long history of permessage-deflate bugs — the `coder/websocket` Go library documents Safari as not properly implementing the extension, and WebKit bug reports include truncated payloads. Application-level compression with `DecompressionStream` (supported in Chrome 80+, Safari 16.4+, Firefox 113+) gives explicit per-message control and avoids these compatibility landmines.

---

## How map tiles and waveform apps actually deliver data

Every major map tile system — Leaflet, Mapbox GL JS, Google Maps — uses a **client-pull model** where the client calculates needed tile coordinates from viewport bounds and requests them from the server. This is the opposite of the current architecture's server-push approach, and for good reason: the client knows what it needs, pull provides natural flow control, and the server stays stateless per-client.

Leaflet's `GridLayer` implements the most instructive pattern for tile prioritization. When the viewport changes, it builds a queue of needed tile coordinates, then **sorts by Euclidean distance from viewport center** — `queue.sort((a, b) => a.distanceTo(tileCenter) - b.distanceTo(tileCenter))`. Center tiles load first because they're where the user is looking. On mobile, Leaflet defaults to `updateWhenIdle: true`, meaning tiles only load after panning stops, and uses a **200ms throttle interval** during continuous movement. The `keepBuffer` option (default: 2) retains tiles 2 rows/columns beyond the visible edge for smooth panning.

BBC Peaks.js, the closest production analog to this system, takes a simpler approach: it downloads the entire pre-computed waveform data file via HTTP and renders only the visible portion locally. This works because their binary format is compact enough — a 30-minute audio file at 256 samples-per-pixel in 8-bit binary is roughly 50KB. For a DAW with potentially hours of multi-track audio, a tiled approach is necessary, but the lesson is clear: **make the data small enough that the delivery mechanism barely matters**.

The recommended hybrid architecture for this system combines pull and push. The client sends viewport state messages (`{type: "viewport", lod: 3, startTile: 10, endTile: 25}`) over WebSocket. The server responds with the requested tiles, ordered center-out. When underlying audio data changes (recording, editing), the server pushes invalidation notices for tiles currently in the client's viewport. This mirrors Figma's multiplayer architecture — full state download on connection, then WebSocket delta sync — and Amazon CloudWatch's pattern of push for critical updates with pull for bulk queries.

For prefetching, always load **1-2 tiles beyond the visible range** on each side. During audio playback, prefetch tiles ahead of the playhead position. The ForeCache system (SIGMOD 2016) demonstrated that even simple Markov chain prediction based on the last few scroll movements can achieve 90% cache-hit ratios by prefetching only 20% of total tiles. A simpler momentum heuristic — if the user is scrolling right, weight prefetch toward the right — captures most of this benefit.

---

## Why the WebSocket crashes and how to fix it today

The root cause is almost certainly this sequence: the server calls `send()` with 1.5MB of data, which exceeds the kernel's TCP send buffer (default **SO_SNDBUF is ~128-256KB on most systems**). The kernel returns `EAGAIN`/`WouldBlock`. The server code either treats this as a fatal error (panic/crash) or retries in a tight loop (CPU spin, starving other connections). When multiple clients trigger this simultaneously, the server becomes unresponsive and connections drop.

**The immediate fix has four parts, in priority order:**

First, handle `WouldBlock` correctly. On a non-blocking socket, `EAGAIN` is not an error — it's the kernel saying "I kept my promise not to block you." The correct response is to **stop writing, store the unsent bytes and offset in per-connection state, register for `EPOLLOUT`/writable notification, and return to the event loop**. When the socket becomes writable again, resume from the stored offset. With edge-triggered epoll (`EPOLLET`), you must write until `EAGAIN` — a single writable notification won't repeat until new state changes occur. **Only register for `EPOLLOUT` when you have pending data**, or you'll get constant spurious wakeups.

Second, increase `SO_SNDBUF` to at least 2× the maximum message size: `setsockopt(fd, SOL_SOCKET, SO_SNDBUF, 4MB)`. Linux internally doubles this value, so setting 4MB gives ~8MB actual buffer. This buys breathing room while other fixes are implemented, but it's not a long-term solution — at 4MB × 100 connections, that's 400MB of kernel buffers.

Third, fragment large messages into **64KB WebSocket frames** using continuation frames (`FIN=0` on intermediate frames, `FIN=1` on the final frame). This allows the TCP send buffer to drain between chunks and lets heartbeat frames interleave with data, preventing the connection timeout that likely causes disconnections.

Fourth, rate-limit broadcast frequency to no faster than **50ms intervals** (20 updates/second). If the viewport hasn't changed, skip the update. If it has, coalesce all intermediate viewport states into one response containing only the latest tile set.

---

## Per-client send queues with latest-value-wins semantics

The long-term architecture requires per-client send queues with message coalescing — the pattern used by every production real-time system from game servers to live sports platforms. A team scaling WebSocket connections from 100k to 1M users on a live sports platform documented the key insight: **real-time data has an expiry date**. If a client is 10 seconds behind on tile updates, the intermediate 200 queued tile messages are worthless — only the latest viewport state matters.

The coalescing buffer pattern replaces a FIFO queue with a **map from message key to latest value**. For tile data, the key is `(lod, tile_id)`. When the server generates a new version of tile (3, 47), it overwrites any pending unsent version of that tile in the client's queue. The write pump, triggered by socket writability, iterates the map, sends all pending tiles in priority order, and clears the map. This decouples production rate from consumption rate — the server can generate 100 tile updates per second, but a slow client on weak WiFi gets only the 5 most recent snapshots per second without falling behind.

uWebSockets provides the gold standard for this with its `send()` return values: **1** (success), **0** (building backpressure), **2** (dropped). The `maxBackpressure` setting (default 64KB) automatically drops messages when the buffer exceeds the limit, and a `drain` handler fires when the buffer empties. For a Zig server, libwebsockets offers an equivalent model through its writability callback — you should **only send data from `LWS_CALLBACK_SERVER_WRITEABLE`**, calling `lws_callback_on_writable(wsi)` to request notification when the socket is ready.

For slow client detection, monitor per-client queue depth and round-trip time via WebSocket ping/pong. On the browser side, `WebSocket.bufferedAmount` is a read-only property returning bytes queued by `send()` but not yet transmitted — poll it before sending to implement client-side flow control. When a client is consistently slow, **degrade gracefully**: drop to a lower LOD (fewer samples per tile, smaller payloads), reduce update frequency, or as a last resort, disconnect with a reconnect hint.

Consider using **two WebSocket connections**: one for small control messages (heartbeat, pong, viewport updates) and one for bulk tile data. WebSocket doesn't support frame interleaving within a message — a 1.5MB data frame blocks a ping frame behind it. This head-of-line blocking is likely contributing to the disconnections, because heartbeat responses can't get through while large tile payloads are being transmitted.

---

## Patterns borrowed from games, video streaming, and collaborative editors

**Game netcode delta compression** is directly applicable. The Quake 3 / Source Engine pattern: server sends full state snapshots, client ACKs receipt, subsequent snapshots are encoded **relative to the most recently ACK'd baseline**. For unchanged tiles, a single "not changed" bit replaces the entire payload. Gaffer on Games documented reducing bandwidth from **17.37 Mbps to 256 Kbps** through delta encoding combined with quantization (quaternion "smallest three" compression, position quantization to 2mm precision, "at rest" flags). The waveform equivalent: for tiles whose underlying audio hasn't changed, send a 1-bit flag instead of re-sending the full tile data.

**Adaptive LOD from HLS streaming** maps naturally to waveform tiles. The hls.js player uses a **dual EWMA bandwidth estimator** — a "fast" EWMA that responds quickly to degradation and a "slow" EWMA that's cautious about improvements, taking the minimum of both. This "drops fast, climbs slow" behavior prevents over-optimistic quality upgrades. Apply this to tile streaming: track WebSocket message delivery round-trip times, and when bandwidth estimate drops below a threshold, switch to lower-LOD tiles (fewer samples per tile, coarser waveform). Bootstrap with the lowest LOD for instant display, then progressively upgrade — identical to HLS's fast-start behavior.

**Figma's multiplayer architecture** demonstrates the pattern for authoritative state sync. Each document maps to one server process (written in Rust). On file open, the client downloads a full document copy; subsequent changes sync via WebSocket. The server batches multiple client updates together before writing, providing temporal coalescing on the write path. They checkpoint the entire file state to S3 every 30-60 seconds, with a DynamoDB write-ahead log capturing individual changes with 95th-percentile latency of 600ms. For waveform tile streaming, this translates to: send full tile cache on connection, stream deltas over WebSocket, and use the server as the authoritative source for tile generation state.

For **background thread tile generation** in the REAPER extension, audio plugin threading patterns apply directly. The standard is a **single-producer single-consumer (SPSC) lock-free ring buffer** between the audio/computation thread and the network sender thread. The audio thread must never block (no allocation, no locks, no I/O), so it writes computed tile data into the ring buffer with atomic operations. The WebSocket sender thread reads from the ring buffer at its own pace. Ross Bencina's "double buffer / pointer flip" pattern is an alternative: compute the new tile set into a shadow buffer, then atomically swap a pointer to make it the active set — O(1) state update regardless of data size.

---

## Implementation specifics for Zig server and browser client

For the Zig WebSocket server, **karlseguin/websocket.zig** (480 stars, actively maintained) is the simplest option — pure Zig, binary frame support via `conn.writeBin()`, thread-safe write methods. However, it lacks built-in backpressure handling, so you'll need a custom send queue that detects `error.WouldBlock` from the underlying `net.Stream` and buffers unsent data. An important caveat: Zig issue #25047 documents that `std.Io.Reader` erases `error.WouldBlock` to `error.ReadFailed`, losing the distinction — you may need to call POSIX `send`/`recv` directly for proper WouldBlock detection.

For the event loop, **libxev** (by Mitchell Hashimoto) provides a cross-platform proactor API over io_uring, epoll, and kqueue with both Zig and C APIs. It handles partial writes internally. If the REAPER extension only targets Linux, **zig-aio** offers coroutine-based io_uring abstraction. TigerBeetle's I/O library is another production-proven option.

The binary protocol uses Zig's `extern struct` for the 16-byte header — this guarantees C ABI field layout with predictable offsets, unlike regular Zig structs which have no defined layout. Serialization is a zero-copy pointer cast: `@as([*]const u8, @ptrCast(&header))[0..@sizeOf(TileHeader)]`. All fields use little-endian, which is native on x86/ARM and matches JavaScript's DataView convention when passing `true` as the littleEndian parameter.

On the browser side, the optimal pipeline is: **WebSocket → main thread (parse header) → transferable ArrayBuffer to Web Worker → process/decode → transfer back → Canvas render**. `postMessage(data, [data.buffer])` performs zero-copy ownership transfer of ArrayBuffer to a worker — a 32MB buffer transfers near-instantly versus hundreds of milliseconds for structured cloning. SharedArrayBuffer is an option for a shared tile cache (the Zig HTTP server can set the required `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` headers since it controls the server), but transferable ArrayBuffer is simpler and sufficient for the one-directional flow from server to renderer.

For rendering, keep peak data as typed arrays rather than converting to JavaScript objects. Draw directly from `Int8Array` values, scaling in the draw loop: `canvasY = centerY - (value / 127.0 * halfHeight)`. SoundCloud's iOS team discovered that the key to waveform performance is **rendering the waveform once, then animating a played/unplayed mask** rather than redrawing 60 times per second — this reduced GPU usage from 90% to under 20%.

---

## Conclusion

The path from crashing WebSocket connections to a production-grade tile streaming system involves three layers that should be implemented in sequence. **This week**: handle `WouldBlock` properly, increase `SO_SNDBUF`, fragment large messages, and add a 50ms rate limit — these four changes will stop the crashes immediately. **Next sprint**: switch to binary int8 format with the 16-byte header protocol, achieving the 20× payload reduction that makes most delivery problems disappear. **Following sprint**: implement client-pull tile requests with center-out priority ordering, per-client coalescing queues, and adaptive LOD based on bandwidth estimation.

The most important insight from this research is that **the payload size problem and the delivery architecture problem are multiplicative, not additive**. At 50-80KB per viewport update (binary + compression) instead of 1.5MB, even a naive server-push model would work on most WiFi networks. Combined with client-pull, delta encoding, and backpressure, the system has roughly 200× more headroom than the current architecture — enough to handle multi-track waveforms, zoomed-in high-LOD views, and multiple simultaneous clients without strain.
