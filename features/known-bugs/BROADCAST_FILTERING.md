# Per-Client Track Filtering on Broadcast

**Status:** Bug - wastes bandwidth in multi-client scenarios

## Problem

Track subscriptions optimize **polling** but not **broadcasting**:

- Each client can subscribe to different track ranges (e.g., Client A: 0-10, Client B: 50-60)
- Backend polls only the union of all subscriptions (tracks 0-10 and 50-60)
- **However**, `shared_state.broadcast()` sends the same JSON to ALL clients
- Both clients receive all 22 tracks instead of just their subscribed range

## Impact

Wastes bandwidth when multiple clients view different portions of large projects. For single-client usage or overlapping viewports, impact is negligible.

## Implementation Options

1. **Per-client serialization** — Serialize tracks per-client based on their subscription. More CPU, but straightforward.

2. **Chunked broadcast** — Split track data by index ranges, send relevant chunks per-client.

3. **Client-side filtering** — Keep current broadcast, let frontend ignore tracks outside its viewport (already happens implicitly).

## Recommended Fix

Option 1 (per-client serialization) is cleanest. In the broadcast loop:

```zig
for (clients) |client| {
    const subscription = track_subs.getClientSubscription(client.id);
    const filtered_json = serializeTracksForSubscription(tracks, subscription);
    client.send(filtered_json);
}
```

This requires refactoring `broadcast()` to accept a filter function or moving serialization into the per-client loop.

## Priority

Low-medium. Worth fixing for correctness, but not urgent unless users report bandwidth issues with multi-client setups.
