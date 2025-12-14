# Reactper Enhancement Ideas

A collection of potential features and improvements for the songwriting workflow.

---

## Maybe (Dogfood First)

### "Last 10 Seconds" Playback

One-tap to hear what was just recorded. Could be simple: seek to (current position - 10s) and play. Sounds useful in theory but might clutter the UI - wait and see if it's actually missed in practice.

### Scratch Notes / Lyrics

Marker functionality exists. Editing marker text would require ReaScript + EXTSTATE polling. Wait until workflow is dogfooded to determine if truly needed.

---

## Already Implemented

### Take Switching

A/B compare takes without leaving your instrument. Long-press a track to select it (blue glow), then use Prev/Next Take buttons to switch between recordings in the current time selection. Fires blind actions (40718 + 42611/42612) - no take counter possible due to API limitations, but works great for the "was that better?" workflow.

### Undo Last Take

Undo button exists. Workflow of stop → listen back is acceptable. Take management provides better solution for comparing ideas.

### Loop Region

Select a region + enable repeat = loop playback. Use play mode to practice/iterate.

### Input Level Meter

Track strips show real-time level metering with peak and clip indicators.

---

## Not Needed

### Count-in / Pre-roll

Handled by REAPER project template with 2-bar count-in. User can toggle metronome off for auto-punch scenarios.

### Quick Track Arm Toggle

At idea generation stage, typically only a few tracks. Mixer is visible and tracks should be named. Trivial to tap the correct arm button.

### Pre-count Toggle

User has time to pick up instrument and settle into BPM. Time selection auto-punch handles precise recording needs.

---

## Implementation Priority

Nothing urgent - dogfood the current workflow and let real usage patterns guide what's next.
