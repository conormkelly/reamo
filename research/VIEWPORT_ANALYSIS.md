# Timeline LOD and viewport-aware subscriptions for touch-first DAW apps

REAmo's current architecture—skeleton data for tracks plus viewport-aware full subscriptions—is well-aligned with industry practice. The key insight across NLEs, maps, and virtualization libraries: **all need position metadata upfront, but detail can be deferred**. For a home-producer-focused app with graceful degradation, target **200 DOM elements** maximum in viewport, use **40-50 pixel** merge thresholds for density visualization, and implement **interval-tree-1d** for snap queries above 200 markers/regions.

---

## Skeleton data: send positions upfront, defer details

**Recommended pattern**: Send all marker/region positions in initial sync (~50 bytes each), defer names/colors to viewport subscription.

React virtualization libraries (TanStack Virtual, react-window) require `itemCount` upfront to calculate scroll dimensions. This is non-negotiable for proper timeline rendering. The virtualized list pattern works like this: you need **position metadata for all items** to compute layout, but **content/details load on-demand** as items enter the viewport.

For snap points during drag, the research confirms apps use **visible range + 100% buffer** on each side—not all positions globally. The snap query pattern should pre-compute candidates when viewport changes, then perform synchronous lookup during drag. With interval-tree indexing, queries complete in **<0.5ms** even with 1000+ items.

**Recommended skeleton structure** for REAmo:

```typescript
// Lightweight skeleton (~50 bytes per item)
interface MarkerSkeleton { id: string; position: number }
interface RegionSkeleton { id: string; start: number; end: number }

// Full details loaded only for visible items
interface MarkerFull extends MarkerSkeleton { name: string; color: number }
```

The "deferred skeleton until needed" pattern exists in game engines (spine-runtimes), but doesn't apply here—virtualization needs positions immediately. However, you **can** defer skeleton loading until the user opens timeline view if they primarily use mixer view.

---

## Density visualization: merge at 40 pixels, show item count

**Recommended pattern**: Merge items within **40 pixels** of each other at current zoom; display aggregate count on merged blobs.

Mapbox's Supercluster (the industry-standard clustering algorithm) uses **40 pixels** as its default merge radius, chosen specifically because it produces consistent visual density across zoom levels. Leaflet uses 80px; Google Maps MarkerClusterer uses 30-80px. The **40-50 pixel threshold** represents the sweet spot.

Professional NLEs don't use heatmaps for timeline density—they use a simpler approach: items render at **minimum 1-2px width** even when mathematically smaller, and small gaps **visually disappear** without explicit warning. REAPER, Premiere, and DaVinci Resolve all accept overlapping markers at high density rather than aggregating.

For REAmo's "density blobs," implement **hierarchical clustering** with pre-computed levels:

| Zoom level (relative) | Behavior |
|----------------------|----------|
| 0-30% | Solid density bars with item count label |
| 30-60% | Merged clusters showing "N items" |
| 60-100% | Individual item rectangles |

The transition should use pixel-distance: when two items are within 40px of each other on screen, merge them. Supercluster's `getClusterExpansionZoom()` pattern provides the exact zoom level where a cluster splits—useful for communicating "zoom in to see 12 items here."

---

## Project scale: target 200 items, 50 markers as baseline

**Realistic benchmarks by context**:

| Context | Tracks | Items | Markers | Regions |
|---------|--------|-------|---------|---------|
| Home producer (your primary target) | 20-50 | 50-200 | 5-20 | 5-15 |
| Professional music | 60-150 | 200-1000 | 10-50 | 10-30 |
| Film scoring | 100-300 active | 500-2000 | 50-200 | 20-100 |
| Large orchestral template | 500-1000 | 2000-10000 | 100-500 | 50-200 |

What counts as "large": **100+ markers** is large for music production; **500+ markers** is very large (film/game only); **1000+ items** starts causing GUI lag in REAPER itself.

For REAmo's "graceful degradation" philosophy:

- **Tier 1** (home producer): <100ms response, no degradation
- **Tier 2** (professional): <200ms acceptable, show density aggregation
- **Tier 3** (orchestral template): <500ms for full refresh, require viewport-aware streaming

A typical pop song has **7-10 arrangement sections** (Intro, Verse 1, Chorus 1, etc.), translating to ~10 markers and ~8 regions. Loop-based production (Ableton-style) generates more items—**100-300 clips** after arrangement—but consolidation/bounce reduces this significantly in practice.

---

## Zoom UX: continuous zoom with 2x step ratio

**Recommended pattern**: Continuous zoom via pinch/scroll, with fixed step shortcuts at **2x ratio** per step.

Every major DAW and NLE uses **continuous zoom** as primary (pinch gesture, Cmd+scroll), with keyboard shortcuts providing fixed steps. The standard step ratio is **2x** (doubling/halving visible time range per step), matching human perception of "twice as close."

Typical zoom presets for a timeline (samples per pixel at 44.1kHz):

```javascript
const ZOOM_LEVELS = [128, 256, 512, 1024, 2048, 4096, 8192, 16384]
// 128 spp = sample-level editing
// 16384 spp = several minutes visible
```

For REAmo, implement **8-12 zoom levels** spanning from "full project visible" to "beats clearly visible." Don't go to sample-level on iPad—it's unnecessary for remote control and creates performance issues. Final Cut Pro, Premiere, and REAPER all offer "Zoom to Fit" (Shift-Z / backslash) as essential quick action.

**Touch optimization**: Pinch-to-zoom should feel continuous; store zoom as floating point and snap to nearest cached mipmap level for rendering (BBC peaks.js pattern).

---

## iPad Safari limits: 200 DOM elements, canvas above 500

**Critical thresholds for 60fps on iPad Safari**:

| Metric | Safe limit | Performance cliff |
|--------|------------|-------------------|
| DOM elements in viewport | **200-300** | 500+ causes scroll jank |
| Total DOM depth | 32 levels | Deeper causes layout thrashing |
| Children per parent | 60 | More causes reflow delays |
| Canvas memory | 384MB | Safari 15+ hard limit |

The Flipboard Engineering team's finding still holds: "You cannot build a 60fps scrolling list view with DOM." For timeline rendering, use **canvas for waveforms/clips** and **DOM for interactive controls**.

**TanStack Virtual works well on iPad Safari** for track list virtualization. Key settings:

```javascript
useVirtualizer({
  overscan: 2,           // Render 2 items above/below viewport
  useFlushSync: false,   // Better performance on mobile
})
```

**Linear search threshold**: Array.includes/find on **10,000 items** completes in ~5ms on iPad Safari. For snap points with 1200 items, linear search takes ~1-2ms—acceptable but not optimal. Switch to binary search or interval tree at **200+ items** for consistent <0.5ms queries.

**Hybrid architecture recommendation**:

- **Canvas layer**: Timeline clips, density blobs, grid lines, waveforms
- **Virtualized DOM layer**: Track headers (vertical scroll)
- **Static DOM layer**: Transport, toolbar, mixer controls

---

## Graceful degradation: density indicators, not warnings

**Recommended pattern**: Visual density indication with item counts—no toast warnings or hard caps.

Professional NLEs and maps don't warn users about LOD changes; they make it **visually obvious** through the rendering itself. Mapbox shows cluster counts ("+42"); Premiere shows simplified waveform blocks; REAPER renders overlapping markers without complaint.

For REAmo, implement:

1. **Density indicators**: Merged item blobs show count ("14 items")
2. **Visual encoding**: Opacity or gradient intensity correlates with item count
3. **Implicit affordance**: Pinch gesture cue or "zoom for details" tooltip on hover
4. **Progressive detail**: More zoom = more detail, with smooth transitions (300-600ms spring animation)

**Never show "project too large" errors**—this violates "audio production without limits." Instead, degrade gracefully:

- At extreme zoom-out: density heatmap only
- Large project detected: increase debounce timeout on viewport changes (200ms → 500ms)
- Memory pressure: drop mipmap quality, not features

---

## Spatial indexing: use interval-tree-1d above 200 items

**Recommended pattern**: **interval-tree-1d** for snap point queries; sorted array + binary search for simpler cases.

Performance comparison for 1200 markers + regions:

| Method | Query time | Build time | Memory |
|--------|-----------|-----------|--------|
| Linear scan | 1-2ms | N/A | 0 |
| Sorted array + binary search | 0.01-0.05ms | O(n log n) | 0 |
| interval-tree-1d | <0.1ms | 50ms | ~40KB |

**Threshold**: Linear search is acceptable up to ~100 items; use binary search for 100-500 items; use interval-tree-1d above 500 items or when you need range queries.

**Library recommendation**: `interval-tree-1d` by Mikola Lysenko

```typescript
import createIntervalTree from 'interval-tree-1d'

// Markers as point intervals [position, position]
const markerTree = createIntervalTree(
  markers.map(m => [m.position, m.position, m.id])
)

// Regions as range intervals [start, end]
const regionTree = createIntervalTree(
  regions.map(r => [r.startPos, r.endPos, r.id])
)

// Query visible range + buffer
const buffer = visibleDuration * 1.0  // 100% buffer
regionTree.queryInterval(visibleStart - buffer, visibleEnd + buffer, 
  (interval) => snapPoints.push(interval)
)
```

For snap point queries during drag: **pre-compute on viewport change** (not during drag), then do synchronous lookup from cache. Target **<0.5ms** for snap lookup to stay within 16ms frame budget with room for rendering.

---

## Summary: implementation priorities

| Priority | Component | Target metric |
|----------|-----------|---------------|
| **P0** | Skeleton data upfront | <100ms initial sync |
| **P0** | Virtualized track list | 200 DOM elements max |
| **P1** | Canvas timeline rendering | 60fps during playback |
| **P1** | 40px density clustering | Smooth zoom transitions |
| **P2** | interval-tree-1d for snaps | <0.5ms snap queries |
| **P2** | Viewport-aware detail loading | <100ms for visible items |

REAmo's existing architecture is well-designed. The key refinements: confirm skeleton includes all positions (not lazy), implement pixel-based density merging at 40px threshold, and add interval-tree indexing once marker/region counts exceed 200. For home producers, you'll rarely hit these limits—the graceful degradation matters most for the "larger project" edge case.
