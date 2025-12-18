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

### Region Editing Mode

Edit song structure directly from the web interface without touching REAPER. Toggle into "Regions" mode via the timeline mode button to:

- **Resize regions**: Drag the start or end edge to extend/shorten. Tap the info bar to type exact bar positions (e.g., "1.1.00" for bar 1, beat 1).
- **Ripple editing**: Extending a region automatically shifts all subsequent regions to make room. No overlaps, no gaps.
- **Move regions**: Drag a region to reorder song sections. Multi-select supported.
- **Edit properties**: Two-line info bar shows name/color on top, start/end/length below. Tap any field to edit directly.
- **Add regions**: Tap the Add button to create a new region with custom name, color, start bar, and length. Defaults to end of last region.
- **Clone regions**: Long-press the Add button (turns green with "Clone" label) to duplicate the selected region at the end of the timeline. Auto-selects the clone for immediate editing.
- **Delete regions**: Three modes via modal - leave empty space, extend previous region to fill, or ripple-delete (shift all following regions back).
- **Tap to deselect**: Tap an already-selected region to deselect it.
- **Live preview**: See ripple effects in real-time as you drag. Selection highlighting follows the actual region being dragged, not the position it originated from.
- **Bidirectional snap points**: When dragging regions, snap points are calculated correctly in both directions. Moving right accounts for gap closure from the original position.
- **Stable selection tracking**: After completing a move, the moved region stays selected (not the region that rippled into the gap). Uses stable region identifiers rather than display indices.
- **Batch commits**: Changes are staged locally, then saved to REAPER in one operation with full undo support.

**Requirements**: Install and run `Reamo_RegionEdit.lua` (found in REAPER Scripts folder). The script runs in the background using `defer()` and processes edit commands via ExtState polling.

**Architecture**:

- Web UI calculates all final positions (including ripple effects) client-side
- Lua script receives batch operations with pre-calculated positions
- Uses REAPER's `markrgnidx` (region ID) for reliable region identification, not enumeration indices
- Beat-grid snapping based on project tempo
- Pending changes work seamlessly with new/deleted regions before committing

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
