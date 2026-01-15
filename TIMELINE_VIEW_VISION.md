# Timeline View Vision

## Problem Statement

The app has evolved toward mobile-first with universal controls in the persistent transport (hold for markers, double-tap for save/undo/redo/click/loop/BPM). This makes much of Studio view redundant:

- **Transport section**: Duplicates persistent transport
- **Mixer section**: Inferior to dedicated Mixer view
- **Timeline section**: The only unique, valuable component

Studio view has become a "kitchen sink" that doesn't fit the mobile-first philosophy of one focused task per screen.

## Vision

**Timeline becomes a dedicated full-screen view** - "Arrangement view for touch"

Two complementary views:

- **Timeline view**: See and edit project structure (items, regions, markers)
- **Mixer view**: See and edit levels/routing (faders, sends, FX)

Persistent transport ties them together with universal controls.

---

## Core Features

### 1. Multi-Track Lanes ✅

Instead of single-track filtering, show **4-8 tracks simultaneously** in horizontal lanes:

```
┌─────────────────────────────────────────────────────────┐
│ [Region labels / Playhead preview pill]                 │
├─────────────────────────────────────────────────────────┤
│ ████ item ████    │  ██ item ██                        │  Track 1
│      ████████████████████                              │  Track 2
│ ██          ████       ██████                          │  Track 3
│         ████████████                                   │  Track 4
├─────────────────────────────────────────────────────────┤
│ [Marker pills]                                          │
└─────────────────────────────────────────────────────────┘
```

- Each track gets a full-width lane (no labels - horizontal space precious on mobile)
- Items colored by their item color
- Tap item to select (multi-select with toggle)
- Selected items highlighted with blue border
- Vertical space divided among visible tracks
- **Waveforms**: ✅ Implemented - waveform overlays render on all items via peaks subscription

### 2. Track Banks (Like Mixer)

Page through tracks in groups:

- **Bank size**: 4, 6, or 8 tracks (user preference, adapts to screen size)
- **Navigation**: Swipe up/down or bank buttons to page
- **Custom banks**: Save track groupings ("Drums", "Vocals", "All synths")
- **Quick access**: Bank pills/tabs at edge of screen

```
┌──────────────────────────────────────┐
│ [◀ Bank 1/4 ▶]  [Drums] [Vox] [All] │  <- Bank selector
├──────────────────────────────────────┤
│           Timeline content           │
└──────────────────────────────────────┘
```

### 3. View Modes

Two modes (Items mode is deprecated - item selection now lives in Navigate mode):

**Navigate Mode** (default)

- Pan/zoom timeline
- Tap markers to jump
- Tap items to select (multi-select, batch ops - already implemented)
- Time selection gestures
- Info bars for selected marker/items

**Regions Mode**

- Region editing (move, resize, create)
- Region list sidebar (optional, swipe from edge?)
- Snap to grid

### 4. Collapsible Toolbar

Below timeline, a toolbar that:

- Shows contextual actions based on selection
- Allows pinning favorite actions
- Collapses to maximize timeline space
- Survives from Studio view as the useful part

```
┌─────────────────────────────────────────────────────────┐
│                    Timeline                              │
├─────────────────────────────────────────────────────────┤
│ [Color] [Lock] [Delete] [Split] ... [▼ collapse]        │ <- Toolbar
└─────────────────────────────────────────────────────────┘
```

When collapsed:

```
┌─────────────────────────────────────────────────────────┐
│                    Timeline (taller!)                    │
├──────────────────────────────────────────────────────────┤
│                                             [▲ expand]  │
└─────────────────────────────────────────────────────────┘
```

### 5. Info Panels

Selection info appears contextually:

- **Marker selected**: Marker info bar (name, color, position editing)
- **Item(s) selected**: Item info bar (single-item or batch mode, as implemented)
- **Region selected**: Region info (in regions mode)

These can overlay or dock depending on screen real estate.

---

## Layout Structure

Consistent with Mixer view pattern (banks at top):

```
┌─────────────────────────────────────────────────────┐
│ [◀ Bank 1/4 ▶] [Custom Banks...] [Mode] [Zoom]     │  Banks / controls
├─────────────────────────────────────────────────────┤
│ [Region labels bar]                                 │
├─────────────────────────────────────────────────────┤
│                                                     │
│                  Track lanes                        │  Main timeline
│                  (4-8 tracks)                       │
│                                                     │
├─────────────────────────────────────────────────────┤
│ [Marker pills]                                      │
├─────────────────────────────────────────────────────┤
│ [Contextual info bar: marker/item/region]           │  Shows based on selection
├─────────────────────────────────────────────────────┤
│ [Quick Actions Toolbar]                [▼ collapse] │  User-configurable
└─────────────────────────────────────────────────────┘
```

**Quick Actions Toolbar:**
- User-configurable actions (like Studio toolbar / Actions page pattern)
- Could support multiple toolbar configs to switch between
- Collapses to maximize timeline space

---

## State Model

### New State (timelineViewSlice)

```typescript
interface TimelineViewState {
  // Track bank
  visibleTrackGuids: string[];      // Currently visible tracks (ordered)
  bankSize: 4 | 6 | 8;              // Tracks per bank
  bankIndex: number;                 // Current bank page

  // Custom banks (persisted)
  customBanks: {
    id: string;
    name: string;
    trackGuids: string[];
  }[];

  // Toolbar
  toolbarExpanded: boolean;
  pinnedActions: string[];          // Action IDs pinned to toolbar

  // View mode (existing, maybe rename)
  timelineMode: 'navigate' | 'regions' | 'items';
}
```

### Shared with Mixer (Optional Link Mode)

If user enables "Link views":

```typescript
interface LinkedViewState {
  linkedMode: boolean;
  // When true, visibleTrackGuids syncs between Timeline and Mixer
}
```

Default: Independent (different track focus per view).

---

## Implementation Phases

**Note**: Pre-release, no users yet - we can delete/restructure freely without migration concerns.

### Phase 1: Create Timeline View ✅

- Create new `/timeline` route with dedicated view component
- Copy TimelineSection implementation as starting point
- Update tab bar to point to new Timeline page
- Keep Studio view intact for reference during development
- Full-height timeline canvas with existing single-track behavior

### Phase 2: Multi-Track Lanes ✅

- Created MultiTrackLanes component showing multiple tracks as horizontal lanes
- Full-width lanes (no labels - horizontal space precious on mobile)
- Items colored by item color, selected items get blue border
- Integrated into Timeline canvas (playhead, markers, regions overlay)
- Tap item to select (multi-select toggle)

### Phase 2.5: Selection UX Cleanup ✅

- ✅ Remove track filter dropdown from NavigateItemInfoBar (no longer needed)
- ✅ Make lane items tappable for direct selection (via Timeline hit-testing)
- ✅ Info bar shows selection count and batch actions
- ✅ Removed region block shading (caused confusion with selection state)
- ✅ Waveform overlays on all items in lanes (via MultiTrackLanes + peaks subscription)

### Phase 3: Banks System ✅

- ✅ Reuse `useBankNavigation` hook from Mixer
- ✅ Add `BankNavigator` component at bottom (prev/next, "1-4 / 24" display)
- ✅ Bank state persisted to localStorage (separate key from Mixer)
- ✅ Simplified to slot/index-based track handling (no GUID lookups for sequential banks)
- ✅ **Hold-to-reveal track labels**: Hold bank display (300ms) to show track labels overlay
- ✅ **Auto-show on bank switch**: Labels appear for 1 second when changing banks
- ✅ Track labels styled as horizontal pills matching mixer design (number badge + name)

### Phase 3.5: Filter & BankSelector ✅

Consistent with Mixer view - same controls, same patterns:

- ✅ **BankSelector in ViewHeader**: Dropdown for custom banks, Add/Edit buttons
- ✅ **TrackFilter in footer**: Search input to filter tracks by name
- ✅ **Custom bank filtering**: Smart banks (pattern) and custom banks (GUID list)
- ✅ **Text filter on top of bank filter**: Combine both for precise filtering
- ✅ **Bank navigation respects filtering**: Shows "1-4 of 10" when filtered
- ✅ **BankEditorModal**: Create/edit custom banks (shared with Mixer)
- ✅ Uses same `useCustomBanks` hook - banks are per-project (ProjExtState)

---

## Current Progress & Known Issues

**Last updated**: Phase 3.5 complete + waveforms implemented + single-track mode deprecated

### What's Working
- Multi-track lanes render correctly with 4 tracks
- Items display with proper colors and selection borders
- Panning/zooming works smoothly (same as single-track mode)
- Tapping items toggles selection (lane-aware hit-testing)
- Selection mode activates on first item tap, shows info bar
- Bank navigation with prev/next buttons and "1-4 / 24" display
- Hold bank display to reveal track labels overlay on lanes
- Track labels auto-show for 1 second on bank switch
- Default timeline zoom set to 30 seconds (was 10)
- Clean region display (no confusing shading)
- **Filter & BankSelector**: Same pattern as Mixer for consistency
- **Custom banks**: Create smart banks (match pattern) or custom banks (manual track selection)
- **Timeline ruler**: REAPER-style ruler with bar.beat on top, time below, tick lines

### Known Issues to Fix
1. ~~**Waveforms rendering in wrong position**~~ - Fixed: MultiTrackLanes now renders its own waveforms
2. **"Item selection mode" concept is awkward** - With items always visible in lanes,
   the mode mainly just shows/hides the info bar. Consider simplifying.
3. **Ruler labels jank at edges** - DOM-based ruler causes labels to pop in/out at
   viewport edges during scroll. Future: port ruler to canvas for smooth clipping.
4. ~~**React Error 185 on item tap**~~ - Fixed: Removed legacy TimelineWaveformOverlay
   which was creating a second peaks subscription (GUID mode) that conflicted with
   MultiTrackLanes' subscription (range mode). Single-track mode is deprecated.
5. **Waveform jitter during momentum scroll** - Cosmetic issue where waveforms have
   "wibbly wobbly" appearance during momentum/inertial scrolling. Low priority.

### Implementation Notes for Future Sessions

**Item rendering architecture** (DON'T reinvent this):
- `MultiTrackLanes` is the component for rendering items (single-track mode deprecated)
- Items use `pointer-events-none` - they're purely visual
- ALL click handling happens in `Timeline.tsx` via hit-testing in `handlePointerUp`
- The hit-testing calculates click position, determines Y bounds, finds items at that time
- Waveforms render inside MultiTrackLanes via `peaksByTrack` prop (no separate overlay)

**Multi-track hit-testing** (Timeline.tsx ~line 670):
- Uses lane-aware hit-testing based on `multiTrackLanes` prop
- Calculates which lane was clicked based on Y position
- Only finds items on THAT track at that time position

**Slot/index-based track handling**:
- For sequential banks, pass `multiTrackIndices` explicitly (1-based track indices)
- No GUID lookups needed - just use the bank's track indices directly
- `MultiTrackLanes` receives `trackIndices` prop alongside `tracks`
- Timeline hit-testing uses passed indices: `multiTrackIndices[laneIdx]`

**Track labels overlay** (TimelineView.tsx):
- `BankNavigator` has `onHoldStart`/`onHoldEnd` callbacks (300ms delay)
- `showLabelsTemporarily()` triggers 1-second auto-hide (doesn't interrupt hold)
- Labels styled as horizontal pill: `bg-bg-deep` number badge + `bg-bg-surface/95` name
- Black border (`border-2 border-black/60`) for visibility over timeline

**Timeline ruler** (TimelineRuler.tsx):
- REAPER-style: bar.beat on top (e.g. "0.1"), time below, tick line extending down
- Positioned at top (above region labels), 32px height, rounded top corners
- Starts from bar 0 (not bar 1)
- Uses same tempo-aware logic as TimelineGridLines
- Adaptive density (sparser than grid): ≤10s every bar, ≤15s every 2, ≤30s every 4, ≤60s every 8, ≤120s every 16, >120s every 32
- Beat subdivisions shown as small ticks when zoomed in (≤10s)
- Time precision adapts to zoom: ≤15s → 3 decimals (0:00.000), ≤30s → 2 decimals (0:00.00), >30s → no decimals (0:00)

**Key constants**:
- Lane item height: 60% of lane height, centered
- These must match between rendering (MultiTrackLanes) and hit-testing (Timeline)
- Default timeline zoom: 30 seconds minimum
- Bank switch label duration: 1000ms
- Hold delay: 300ms
- Ruler height: 32px

### Phase 4: Collapsible Toolbar

- User-configurable quick actions (like Studio toolbar / Actions page)
- Support multiple toolbar configs users can switch between
- Collapse animation
- Persist toolbar state

### Phase 5: Cleanup

- Delete Studio view and legacy items mode files
- Delete `ItemsDensityOverlay` (replaced by MultiTrackLanes)
- Delete `TimelineWaveformOverlay` (waveforms now in MultiTrackLanes)
- Clean up unused components

---

## Open Questions

1. **Mixer link mode**: Worth the complexity? Or keep views independent?
   - Leaning: Independent by default, maybe add link toggle later if requested

2. **Bank size**: Fixed or adaptive based on screen height?
   - Leaning: Adaptive with user override. Calculate based on min lane height (~60px?)

3. **Region list sidebar**: Swipe from edge, or dedicated button?
   - Leaning: Button to toggle, keeps gestures clean for timeline interaction

4. ~~**Waveforms in multi-track**~~: Resolved - show for ALL visible tracks via range-based peaks subscription

5. **Multiple toolbar configs**: How to expose switching between them?
   - Could be tabs/pills at toolbar edge, or a dropdown

---

## Success Criteria

- Timeline view is the primary way to see project structure
- Can view 4-8 tracks at once without scrolling
- Can quickly switch between track groups (banks)
- Item selection and batch editing works across visible tracks
- Toolbar provides quick access to common actions
- Full-screen = more immersive, less cramped
- Studio view can be retired without losing functionality
