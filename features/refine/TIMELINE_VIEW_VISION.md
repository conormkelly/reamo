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

**Last updated**: Phase 5 complete (cleanup done)

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
3. ~~**Ruler/grid jank during pan**~~ - Fixed: Unified tick generator with:
   - 10% visibility buffer prevents edge jank
   - Duration snapping to nearest ZOOM_STEP prevents step size flipping
     (e.g., 30.5s clamped duration now treated same as 30s)
   - Time format precision also snaps (prevents decimal place flipping)
   - Grid and ruler use same generator for consistency
4. ~~**React Error 185 on item tap**~~ - Fixed: Removed legacy TimelineWaveformOverlay
   which was creating a second peaks subscription (GUID mode) that conflicted with
   MultiTrackLanes' subscription (range mode). Single-track mode is deprecated.
5. **Waveform brightness changes at viewport edges** - Items appear brighter when fully
   visible, dimmer when partially clipped by parent's `overflow:hidden`. Root cause is
   browser compositing behavior - canvas dimensions are identical in both states (verified
   via HTML snapshot diff). Multiple fix attempts failed:
   - Explicit canvas state reset (setTransform, globalAlpha, clearRect)
   - GPU compositing hints (willChange, transform: translateZ(0))
   - CSS positioning changes (inset-0 vs top-0 left-0)

   **Likely solution**: Full canvas rendering for timeline content area (single canvas
   for all items/waveforms instead of per-item canvases). This eliminates browser
   compositing of partially-clipped child canvases entirely. See "Canvas Architecture
   Considerations" section below.
6. **Waveform jitter during momentum scroll** - Cosmetic issue where waveforms have
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
- Bar numbers come from REAPER via barOffset (can be negative, e.g., project starts at bar -4)
- Uses unified tick generator (`timelineTicks.ts`) shared with grid lines
- Duration snapped to nearest ZOOM_STEP before threshold comparison (prevents step flipping)
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

### Phase 4: Collapsible Toolbar ✅

- ✅ User-configurable quick actions - reuses existing Toolbar component
- ✅ Collapse toggle with expand/collapse button
- ✅ Persist toolbar state (collapsed state saved to localStorage)
- ⏳ Support multiple toolbar configs (future enhancement)
- ⏳ Collapse animation (currently instant, could add transition)

### Phase 5: Cleanup ✅

- ✅ Delete `ItemsTimeline/` folder (archived items mode - 4 components)
- ✅ Delete `ItemDensityBlobs.tsx` (replaced by MultiTrackLanes)
- ✅ Delete `TimelineWaveformOverlay.tsx` (waveforms now in MultiTrackLanes)
- ✅ Remove `useSingleTrackPeaks` deprecated hook
- ✅ Clean up barrel exports
- ✅ Delete Studio view (`components/Studio/`, `views/studio/`) - Timeline + Mixer views replace it
- ✅ Move Pin Master setting to Mixer view settings menu

### Follow-up Tasks (Post-Cleanup)

1. **Wire up Pin Master in Mixer view** - Toggle exists in SettingsMenu (Mixer section) but
   needs to be connected to actual functionality in MixerView that pins the MASTER track.

2. **Rethink Recording Quick Actions** - With Studio view gone, the "Rec Quick Actions"
   toggle is now in the Global settings section. Need to decide:
   - Where should these actions appear in the UI? (Timeline footer? Persistent transport?)
   - Should it be view-specific or truly global?
   - What actions should it include now that it's not tied to Studio's recording workflow?

3. **Toolbar component redesign** - Current toolbar may need rework for better space utilization:
   - **Slot-based layout**: Buttons occupy 1 slot (or 2 if wider), auto-fit based on available width
   - **Variable padding**: Allow compact/normal modes with different spacing
   - **Paging**: When buttons overflow, page through toolbar with indicator (e.g., "1/2")
   - **Swipe navigation**: Swipe left/right to switch pages on mobile
   - Consider whether this should be a Timeline-specific toolbar or reusable across views

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

---

## Canvas Architecture Considerations

The current implementation uses HTML elements with per-item canvas overlays for waveforms.
This has caused browser compositing issues (brightness changes when items are partially
clipped). A full canvas approach may resolve these issues.

### Current: HTML + Canvas Overlays

```
┌─ Timeline Container (HTML div) ─────────────────────┐
│  ┌─ Track Lane (HTML div, overflow:hidden) ───────┐ │
│  │  ┌─ Item (HTML div) ────────────────────────┐  │ │
│  │  │  ┌─ Canvas (waveform) ─────────────────┐ │  │ │
│  │  │  │  [drawn peaks data]                 │ │  │ │
│  │  │  └─────────────────────────────────────┘ │  │ │
│  │  └──────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

**Pros**: React handles layout, DOM events work, accessible
**Cons**: Browser compositing quirks, many layers, sub-pixel issues

### Alternative: Single Canvas for Content

```
┌─ Timeline Container (HTML) ─────────────────────────┐
│  ┌─ Ruler (HTML - keeps crisp text) ──────────────┐ │
│  └────────────────────────────────────────────────┘ │
│  ┌─ Canvas (items + waveforms + grid) ────────────┐ │
│  │  [all content drawn via 2D API]                │ │
│  │  [hit-testing via coordinate math]             │ │
│  └────────────────────────────────────────────────┘ │
│  ┌─ Controls (HTML) ──────────────────────────────┐ │
│  └────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

**Pros**: Complete pixel control, no compositing quirks, batched drawing
**Cons**: Manual hit-testing, canvas text rendering, no DOM for content

### Hybrid Approach (Recommended)

Keep HTML for ruler, controls, and overlays. Use single canvas for:
- Track lanes background
- Items (colored rectangles)
- Waveforms
- Grid lines
- Selection highlights

This gives us:
- Pixel-perfect rendering without compositing issues
- Crisp text via HTML (ruler, labels)
- Hit-testing is already implemented (just reuse coordinate math)
- Eliminates the brightness bug entirely

### Migration Path

1. Create `TimelineCanvas` component with single canvas
2. Move item/waveform rendering from `MultiTrackLanes` to canvas draw calls
3. Keep existing hit-testing logic (already does coordinate math)
4. Remove per-item canvas elements
5. Grid lines can move to same canvas (already calculated)
