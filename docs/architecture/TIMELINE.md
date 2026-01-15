# Timeline Architecture

Full-screen arrangement view for touch. Shows project structure (items, regions, markers) with multi-track lanes.

## Layout Structure

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

## View Modes

**Navigate Mode** (default)

- Pan/zoom timeline
- Tap markers to jump
- Tap items to select (multi-select with toggle)
- Info bars for selected marker/items

**Regions Mode**

- Region editing (move, resize, create)
- Snap to grid

## Implementation Notes

**Item rendering architecture**:

- `MultiTrackLanes` is the component for rendering items
- Items use `pointer-events-none` - they're purely visual
- ALL click handling happens in `Timeline.tsx` via hit-testing in `handlePointerUp`
- Waveforms render inside MultiTrackLanes via `peaksByTrack` prop

**Multi-track hit-testing** (Timeline.tsx):

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
- `showLabelsTemporarily()` triggers 1-second auto-hide
- Labels styled as horizontal pill with number badge + name

**Timeline ruler** (TimelineRuler.tsx):

- REAPER-style: bar.beat on top, time below, tick line extending down
- Uses unified tick generator (`timelineTicks.ts`) shared with grid lines
- Duration snapped to nearest ZOOM_STEP before threshold comparison
- Adaptive density based on zoom level

**Key constants**:

- Lane item height: 60% of lane height, centered
- Default timeline zoom: 30 seconds minimum
- Bank switch label duration: 1000ms
- Hold delay: 300ms
- Ruler height: 32px

## Canvas Architecture (Future)

Current implementation uses HTML elements with per-item canvas overlays for waveforms. This causes browser compositing issues (brightness changes when items are partially clipped).

**Recommended fix**: Single canvas for all timeline content:

- Track lanes background
- Items (colored rectangles)
- Waveforms
- Grid lines
- Selection highlights

This eliminates browser compositing of partially-clipped child canvases. Hit-testing logic already exists and can be reused.

See ROADMAP.md → "Timeline Canvas Architecture" for status.
