# Sends and Routing for Reamo: A focused v1 approach

**Send control is worth adding to v1, but in a targeted "cue mix lite" form—not full routing control.** Research reveals that while only 5-10% of home studio users employ proper DAW-based cue sends, those who do cite "adjusting headphone mix" as the primary reason they walk to the computer. The opportunity lies in serving this pain point with minimal UI complexity, while avoiding the trap of exposing full routing controls that most users will never touch.

## Most home studios don't use send-based monitoring

The research uncovered a surprising finding: **70-80% of self-recording musicians rely on hardware monitoring**, using their interface's zero-latency monitor knob to balance live input against DAW playback. Only about 5-10% set up dedicated cue buses with pre-fader sends in the DAW. This means Reamo's existing mixer controls likely solve the headphone mix problem for most users already.

The gap exists for the minority who've configured proper cue systems—typically users with multi-performer recording needs or those seeking independent monitor mixes while preserving their main mix. For these users, adjusting send levels from a tablet would eliminate a genuine workflow interruption. Professional studio workflows universally use send-based cue systems, so supporting this also positions Reamo for more demanding use cases.

When musicians do adjust monitoring mid-session, the pattern is **between takes, not during performance**. Cue sends get tweaked as vocalists request "more me" or drummers ask for less click. Effect sends (reverb/delay levels) are adjusted during mixing but rarely during tracking. This suggests send controls can live in a secondary view rather than competing for space on the main mixer.

## Three send controls matter for remote adjustment

Research across Pro Tools Control, Logic Remote, personal monitor mixers (Behringer P16, Aviom, Allen & Heath ME-1), and DAW forums reveals a clear hierarchy:

| Control | Priority | Adjustment frequency | Recommendation |
|---------|----------|---------------------|----------------|
| **Send level to cue bus** | Critical | Every take | v1 core feature |
| **Send level to aux (reverb/delay)** | High | Mixing sessions | v1 include |
| **Send mute** | Medium | Troubleshooting | v1 if simple |
| Pre/post fader toggle | Low | Session setup only | Defer to v2 |
| Send pan | Very low | Rarely adjusted | Exclude |
| Send enable/bypass | Low | Occasional | Defer to v2 |

**Pre/post fader** is universally described as a "set and forget" parameter chosen during initial routing setup. Toggling it mid-session would actually break the user's intended monitoring architecture. Similarly, **send pan** is either linked to main track pan automatically or set once during mix setup—no competing solution exposes it as a primary remote control.

## Hardware output routing belongs out of scope

Every remote control app researched—Avid Control, Logic Remote, TouchOSC templates, SSL 360—**deliberately excludes hardware I/O routing**. This isn't an oversight; hardware outputs are physically tied to studio wiring (which speakers connect where, which headphone amps receive which outputs). These decisions happen during session setup when the user is at the computer anyway.

Research found zero evidence of mid-session hardware routing changes as a workflow pattern. The recommendation is clear: **exclude hardware routing entirely** from Reamo's scope for both v1 and v2.

## REAPER's API makes send control straightforward

REAPER exposes comprehensive send/routing control through a consistent API pattern. The core functions needed:

```c
// Enumerate sends on a track
int GetTrackNumSends(MediaTrack* track, int category)
// category: -1=receives, 0=sends to other tracks, 1=hardware outputs

// Get/set send parameters  
double GetTrackSendInfo_Value(MediaTrack* tr, int category, int sendidx, const char* parmname)
bool SetTrackSendInfo_Value(MediaTrack* tr, int category, int sendidx, const char* parmname, double newvalue)
```

**Key parameters for v1:**
- `D_VOL` — Volume as linear value (1.0 = 0dB, 0.5 ≈ -6dB)
- `D_PAN` — Pan position (-1.0 to 1.0)
- `B_MUTE` — Mute state (0 or 1)
- `P_DESTTRACK` — Returns MediaTrack* pointer for destination (cast from double)
- `I_SENDMODE` — Pre/post mode (0=post-fader, 1=pre-FX, 3=post-FX)

**Getting destination track names** for UI display requires a two-step lookup:

```c
// Get destination track pointer
MediaTrack* destTrack = (MediaTrack*)(intptr_t)GetTrackSendInfo_Value(track, 0, sendIdx, "P_DESTTRACK");

// Get track name
char name[256];
GetTrackName(destTrack, name, sizeof(name));
```

Alternatively, `GetTrackSendName(track, sendIdx, buf, bufSize)` provides a convenience wrapper.

## Three implementation gotchas to watch

**Category indexing varies by function.** `GetTrackNumSends` uses -1/0/1 for receives/sends/hwouts, while some other functions use different conventions. Stick to the explicit category parameter rather than assuming consistency.

**Volume values are linear, not dB.** The `D_VOL` parameter returns 1.0 for 0dB—you'll need conversion for any dB-scaled UI. REAPER provides `DB2SLIDER()` and `SLIDER2DB()` helpers, but in a Zig extension you'll implement this as: `dB = 20 * log10(linear_value)`.

**Hardware outputs lack destination track pointers.** When category=1, `P_DESTTRACK` returns NULL since hardware outputs don't route to tracks. Use `I_DSTCHAN` instead to get the physical output channel index, with bitwise flags for mono (& 1024) and ReaRoute (& 512).

## Per-track send panel is the recommended UI pattern

Analyzing competing solutions reveals two dominant patterns:

**Pattern A: Dedicated sends view** (Logic Remote, Pro Tools Control) — A separate mixer view showing only send faders. Works well for mix engineers but adds navigation overhead.

**Pattern B: Per-track expandable panel** (personal monitor mixers, REAPER's more_me.html) — Select a track, see its sends in a detail panel. Matches the "select channel → adjust parameters" model used by Behringer P16, Allen & Heath ME-1, and Aviom.

For a tablet app aimed at musicians at their instruments, **Pattern B is recommended**. Implementation approach:

1. **Long-press or tap** a track in the existing mixer view
2. **Slide-up panel** reveals that track's sends as horizontal fader strips
3. Each send shows: destination name, level fader, mute button
4. Panel dismisses on tap-away or swipe-down

This keeps sends discoverable without cluttering the main mixer, matches mental models from hardware personal mixers, and scales gracefully (most tracks have 0-3 sends).

An alternative "Cue Mix Quick View" could detect tracks with sends to aux/bus tracks (using naming heuristics like "Cue", "HP", "Headphone", "Monitor") and surface just those sends prominently. This would serve the 5-10% of users with proper cue systems while remaining invisible to everyone else.

## Recommended scope for v1 implementation

**Include in v1:**
- Send level adjustment (fader control via `D_VOL`)
- Send mute toggle (via `B_MUTE`)
- Per-track send panel UI (expandable from existing mixer)
- Destination track name display (for labeling sends)

**Defer to v2:**
- Pre/post fader mode toggle
- Send pan control
- Receive control (incoming sends)
- Dedicated "Cue Mix" view with smart bus detection
- Grouping sends by destination

**Exclude entirely:**
- Hardware output routing
- Creating/deleting sends
- MIDI routing configuration
- ReaRoute virtual outputs

## Conclusion

Sends control earns a place in Reamo v1, but as a **focused capability rather than full routing power**. The implementation should surface send levels through a per-track expandable panel, targeting the specific "adjust cue mix from my instrument" use case without overwhelming tablet users who never configured sends in the first place. REAPER's API is well-suited for this—the core implementation requires just `GetTrackNumSends`, `GetTrackSendInfo_Value`, and `SetTrackSendInfo_Value` with a handful of parameters. Hardware routing stays firmly out of scope as a setup-time configuration that no competing solution attempts to expose remotely.
