# Building a touch-first DAW timeline app for iPad

**A hybrid Canvas/DOM architecture with thoughtful gesture handling and accessibility will deliver professional-grade performance.** This research synthesizes best practices across E2E testing patterns, cluster interactions, playhead following, reduced motion accessibility, and rendering performance—drawing from professional DAWs, mapping libraries, and web application case studies. The core findings: expose viewport state via data attributes for testing (not global stores), use single-tap with popovers for small marker clusters, implement auto-follow as a pausable mode rather than on/off toggle, respect `prefers-reduced-motion` by eliminating momentum and zoom animations, and adopt a hybrid Canvas+DOM architecture once your item count exceeds **500 elements**.

---

## 1. E2E testing: Data attributes beat global state promotion

The testing community—Kent C. Dodds, Testing Library, and Playwright documentation—unanimously recommends testing observable behavior over implementation details. For viewport and zoom state in timeline applications, **data attributes** offer the ideal balance between testability and maintainability.

**Promoting local state to Zustand/Redux purely for testing is explicitly discouraged.** Kent C. Dodds recommends treating Redux stores as implementation details, testing them indirectly through connected components. Promoting viewport state to a global store adds complexity, couples components unnecessarily, and makes refactoring harder—all to solve a testing problem that has better solutions.

The recommended pattern renders derived state as DOM attributes that Playwright can query with auto-retry support:

```tsx
// Timeline component exposing testable state
function Timeline({ items }) {
  const [viewport, setViewport] = useState({ scrollX: 0, zoom: 1 });
  
  return (
    <div 
      data-testid="timeline"
      data-scroll-x={viewport.scrollX}
      data-zoom-level={viewport.zoom}
      data-visible-range={`${visibleStart}-${visibleEnd}`}
    >
      {/* timeline content */}
    </div>
  );
}

// Playwright test with auto-retry
test('zoom affects visible range', async ({ page }) => {
  const timeline = page.getByTestId('timeline');
  await expect(timeline).toHaveAttribute('data-zoom', '2');
});
```

For complex internal state impractical to serialize, **window properties are acceptable in development/test builds only**—but strip them from production. Professional apps like VS Code, TLDraw, and React Flow use data attributes extensively (`data-uri`, `data-line-number`) rather than exposing raw internal state globally. The tradeoff matrix:

| Approach | Implementation coupling | Refactor resilience | Playwright integration |
|----------|------------------------|---------------------|------------------------|
| **Data attributes** | Low | High | Excellent (auto-retry) |
| **DOM position/scroll** | Very low | Very high | Good |
| **`window.__TEST__`** | High | Low | Manual only |
| **Global store promotion** | Very high | Very low | Manual |

---

## 2. Marker clusters: Single-tap with context-aware expansion

Professional mapping libraries Mapbox and Google Maps have established clear patterns for cluster interaction on touch devices. **Mapbox uses smart zoom-to-expand**, calculating the exact zoom level where a cluster breaks apart via `getClusterExpansionZoom()`. Google Maps implements delegate-based zoom-to-bounds, animating to show all cluster items.

For a DAW timeline—which is one-dimensional unlike maps—a **hybrid approach based on cluster size** works best:

```
IF cluster contains ≤5 markers:
    → Show popover with tappable list (fastest interaction)
ELSE IF zoom can expand the cluster:
    → Animate zoom to expansion level (250-300ms)
ELSE (at max zoom, markers still clustered):
    → Spiderfy vertically or show scrollable popover
```

**None of the major DAWs implement marker clustering.** Logic Pro, Pro Tools, Final Cut Pro, and Premiere Pro simply display all markers at all zoom levels, accepting overlap at low zoom. A separate marker list panel provides navigation. Your clustering implementation will be novel in the DAW space.

**Single-tap is the correct convention**—it's the primary iOS action, faster than double-tap, and avoids conflicts with timeline zoom gestures. Reserve double-tap for zoom or disable it entirely. Touch targets must be **44×44 points minimum** per Apple's Human Interface Guidelines; smaller targets produce 25%+ tap errors.

For auto-follow interaction with clusters, the critical insight is that **auto-follow should pause, not disable permanently**:

```swift
func handleClusterTap(_ cluster: MarkerCluster) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    
    if isAutoFollowEnabled {
        pauseAutoFollow()  // Temporary, not permanent disable
    }
    
    if cluster.items.count <= 5 {
        showClusterPopover(cluster)
    } else {
        animateTimelineZoom(to: cluster.expansionZoomLevel)
    }
}
```

The behavior matrix for follow-mode + cluster interaction:

| Auto-follow state | On cluster tap | On playback resume |
|-------------------|---------------|-------------------|
| **ON** | Pause follow, expand cluster | Resume following |
| **PAUSED** | Expand cluster | Resume following |
| **OFF** | Expand cluster | Stay manual |

---

## 3. Playhead following: Page-scroll default with explicit re-enable

Research across **seven major DAWs** reveals consistent patterns. Logic Pro X offers the most sophisticated model with "Catch Playhead" (page scroll), "Scroll in Play" (smooth/centered), and preferences for auto-enabling catch on playback start. Ableton Live provides a dedicated Follow button in the Control Bar with `Ctrl+Shift+F` toggle. Adobe Premiere Pro treats it as a global preference with three modes but no quick toggle.

| DAW | Default mode | Disable trigger | Re-enable method | Visual indicator |
|-----|-------------|----------------|------------------|------------------|
| **Logic Pro X** | Catch + page scroll | Manual scroll | Catch button (blue/grey) | Walking man icon |
| **Ableton Live** | Page mode | Any edit, scroll | Follow button, stop/start | Arrow button |
| **Pro Tools** | Page scroll | Preference-based | Options menu | None |
| **Final Cut Pro** | Off (until 10.7) | Scroll past playhead | Playhead reaches center | Playhead position |
| **REAPER** | Auto-scroll on | Scroll bar, selection | `'` key, Options menu | Toolbar button |
| **DaVinci Resolve** | Varies by page | Manual navigation | Timeline View Options | Menu icon |

For touch-first interfaces, **these gestures should disable auto-follow**:

- Horizontal pan/scroll gesture
- Tap on timeline ruler (not playhead)
- Tap on marker
- Drag selection
- Any touch-hold editing gesture

**Re-enabling should require explicit action**, not happen automatically. The recommended approach:

1. **Dedicated toggle button** in transport area (most intuitive)
2. **Tap-on-playhead** gesture as quick shortcut
3. **Optional**: Re-enable on playback start (user preference)

Visual feedback is critical: a **clearly visible button state** (highlighted when following) plus optional toast notification when mode changes. Logic's blue/grey distinction and Ableton's arrow icon are effective patterns.

**Zoom should NOT disable follow in most cases**—Ableton specifically zooms to the playhead when Follow is enabled. This is desirable behavior: zooming to see detail at the current position shouldn't break the follow relationship.

---

## 4. Reduced motion: Preserve essential playhead updates, eliminate momentum

WCAG 2.3.3 (Level AAA) requires that motion animation triggered by interaction can be disabled unless essential to functionality. The critical distinction: **user-controlled scrolling is essential; momentum deceleration after release is not**.

Apple's reduced motion guidance specifically flags problematic patterns: multi-axis motion, scaling animations simulating depth, spinning effects, and auto-advancing content. For timeline apps, this means:

| Animation | Normal behavior | Under reduced motion | Rationale |
|-----------|-----------------|---------------------|-----------|
| **Playhead during playback** | Smooth update | **Keep** | Essential functionality |
| **Momentum scrolling** | Deceleration curve | **Instant stop** | Non-essential, vestibular trigger |
| **Zoom animation** | Animated scale | **Instant snap** | Scaling is known trigger |
| **Scroll-to-playhead** | Smooth scroll | **Instant jump** | Non-essential transition |
| **Cluster expand/collapse** | Spring animation | **Instant or fade** | Decorative motion |
| **Playhead following** | Smooth scroll | **Page-snap jumps** | Reduces continuous motion |

Implementation requires checking both the CSS media query and listening for changes:

```javascript
const prefersReducedMotion = window.matchMedia(
  '(prefers-reduced-motion: reduce)'
).matches;

// For momentum scrolling
const scrollDeceleration = prefersReducedMotion ? 0 : 0.95;

// For zoom
function handleZoom(targetScale) {
  if (prefersReducedMotion) {
    timeline.zoomLevel = targetScale;  // Instant
  } else {
    animateZoom(targetScale, 250);     // 250ms ease
  }
}
```

**Opacity and color changes are not considered motion animation** per WCAG, making fade effects a valid replacement for position/scale animations. When removing motion, replace with opacity transitions or instant state changes plus haptic feedback—critical on iPad where tactile confirmation compensates for missing visual feedback.

**No major DAW documents reduced motion support**, representing an opportunity for your app to lead in accessibility. Apple's own apps demonstrate the pattern: Weather stops animations, Maps reduces zoom smoothness, and system-wide zoom transitions fall back to dissolve.

---

## 5. Rendering architecture: Hybrid Canvas+DOM above 500 elements

Performance benchmarks show a clear threshold: **DOM with virtualization handles up to ~300 items well; Canvas becomes necessary above 500 items** for smooth 60fps interaction on iPad Safari.

| Scale | DOM performance | Canvas performance | Recommendation |
|-------|-----------------|-------------------|----------------|
| **<100 items** | Excellent | Overkill | DOM + virtualization |
| **100-300 items** | Good with LOD | Good | DOM acceptable |
| **300-500 items** | Degraded (~21ms/update) | Smooth 60fps | Canvas recommended |
| **500-1000 items** | Noticeable lag | Good with optimization | **Canvas required** |
| **1000+ items** | Unfeasible | Excellent with WebGL | Canvas/WebGL essential |

**iPad Safari has critical limitations** you must design around. Canvas memory is capped at ~224-256MB total. The "GPU Process: Canvas Rendering" experimental feature (iOS 15+) causes severe performance degradation for large canvases—**up to one-second delays** on drag operations for ~5000×5000 canvases, with no programmatic workaround.

Professional web apps demonstrate the patterns. **Figma** uses a custom WebGL/WebGPU engine with WebAssembly—essentially "a browser inside a browser." **Felt** (mapping tool) migrated from SVG/React to Canvas, reducing "Select All on 1000 elements" from seconds to milliseconds. Web DAWs like BandLab and Soundtrap remain DOM-based but don't target the 100+ track scenario.

**Touch interaction complexity differs significantly**:

| Feature | DOM | Canvas |
|---------|-----|--------|
| Tap detection | Automatic | Manual hit testing |
| Drag | CSS + events | Calculate deltas, redraw |
| Multi-touch | Automatic | Manual touch tracking |
| Keyboard nav | Built-in | Must implement entirely |
| Accessibility | Built-in | Shadow DOM required |

The recommended hybrid architecture separates concerns:

```
┌─────────────────────────────────────────────┐
│  DOM Layer (z-index: 2)                     │
│  - Track headers, transport controls        │
│  - Accessible buttons, text inputs          │
│  - Context menus, faders/knobs             │
├─────────────────────────────────────────────┤
│  Canvas Layer (z-index: 1)                  │
│  - Timeline grid, track content            │
│  - Waveforms, clips, automation curves     │
│  - Selection rectangles, playhead          │
├─────────────────────────────────────────────┤
│  Accessibility Layer (visually hidden)      │
│  - ARIA live regions                       │
│  - Focusable items mirroring canvas        │
└─────────────────────────────────────────────┘
```

For React integration, **react-konva** works well up to ~500 shapes before lagging. **PixiJS** (WebGL-accelerated) handles thousands of elements. **Imperative Canvas** with React refs provides maximum control and performance. Key optimizations: use `Path2D` caching, implement viewport culling, cache text as textures, and use CSS transforms during drag with redraw only on gesture end.

**Migration difficulty from DOM to Canvas is medium-high** (4-8 weeks for a timeline), but Felt's experience shows it "didn't feel like a rewrite" with comprehensive tests and shared geometry code. Their strategy: feature flags for renderer switching, pixel-position-based tests rather than DOM selectors, and shared code for geometry calculations.

---

## Conclusion: Key architectural decisions

**Testing architecture**: Use data attributes (`data-zoom-level`, `data-scroll-x`) for E2E viewport assertions. Keep viewport state local to components; don't promote to global stores for testing purposes. Strip any `window.__TEST__` properties from production builds.

**Cluster interaction design**: Implement single-tap with popover for ≤5 markers, zoom-to-expand for larger clusters. Auto-follow should pause (not disable) on cluster interaction and resume on playback. Minimum 44pt touch targets are non-negotiable.

**Follow-mode UX**: Default to page-scroll following with a prominently visible toggle button. Disable follow on pan gestures, re-enable explicitly via button or playhead tap. Consider optional "re-enable on playback start" preference.

**Accessibility commitment**: Under `prefers-reduced-motion`, eliminate momentum scrolling, make zoom instant, and switch playhead following to page-snap mode. Keep essential playhead position updates. Replace motion with opacity fades and haptic feedback.

**Rendering strategy**: Start with DOM + virtualization/LOD for development velocity. Plan Canvas migration when approaching 500 items. Use hybrid architecture from day one—Canvas for timeline content, DOM for controls and accessibility. Design for iPad Safari's memory limits and test with "GPU Process: Canvas Rendering" both enabled and disabled.
