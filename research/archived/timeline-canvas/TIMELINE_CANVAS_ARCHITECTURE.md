# Canvas architecture for 60fps DAW timeline on iPad Safari

**Canvas2D with a layered architecture is the optimal approach for REAmo's timeline view**, avoiding WebGL due to critical stability issues on iOS Safari. A 3-4 layer canvas stack—separating static content from the animated playhead—combined with viewport culling and tile-based caching will achieve 60fps performance within iPad Safari's strict memory constraints. The key architectural insight: treat the playhead as a CSS-transformed DOM element, reserve canvas rendering for waveforms and clips, and never exceed Safari's **16 megapixel per-canvas limit**.

---

## Recommended architecture: Layered Canvas2D with hybrid DOM

The consensus from professional web DAWs (Soundtrap, BandLab) and canvas applications (Figma, Excalidraw) is clear: **use 3-5 stacked canvas layers** organized by update frequency. This prevents expensive full-canvas redraws when only the playhead moves.

```
┌─────────────────────────────────────────────────┐
│  Layer 4: DOM Playhead (CSS transform, 60fps)   │ ← No canvas redraw needed
├─────────────────────────────────────────────────┤
│  Layer 3: Selection Overlay Canvas              │ ← Updates on selection change
├─────────────────────────────────────────────────┤
│  Layer 2: Clips + Waveforms Canvas              │ ← Updates on pan/zoom/edit
│    (viewport-culled, tile-cached)               │
├─────────────────────────────────────────────────┤
│  Layer 1: Grid + Regions Canvas                 │ ← Updates on zoom only
└─────────────────────────────────────────────────┘
```

**Playhead as DOM element** is the critical optimization. Professional timeline apps use CSS `transform: translateX()` with `will-change: transform` for playhead animation—this runs on the compositor thread, completely bypassing canvas rendering. The playhead becomes a simple styled `<div>` positioned absolutely over the canvas stack.

For **z-ordering of selected items**, use the dedicated selection overlay canvas (Layer 3). Render items normally on Layer 2, then draw selection highlights and resize handles on Layer 3. This eliminates expensive re-sorting and full redraws when selection changes.

---

## Canvas2D over WebGL: Safari stability concerns

**Canvas2D is the correct choice** despite WebGL's theoretical performance advantages for batched rendering. Research uncovered serious WebGL stability issues on iOS Safari that make it unsuitable for a production DAW:

- **Context loss bug (iOS 16.7, 17.x)**: Widespread reports of "WebGL: context lost" errors when backgrounding Safari or locking the device. Once affected, all tabs show unresponsive canvases until Safari restart.
- **Metal backend translation overhead**: Safari's WebGL runs through Apple's ANGLE Metal backend, introducing performance inconsistencies. Some developers report only **12fps** in scenes that should run at 60fps until disabling "WebGL on Metal."
- **Memory crashes**: iOS WebGL can crash even when allocating within reported memory limits.

For your scale of **400+ rectangles** with waveform overlays, Canvas2D's `fillRect()` and path operations are hardware-accelerated and performant. WebGL batching benefits primarily appear at **10,000+ elements**. The complexity, stability risk, and text rendering challenges of WebGL (requiring texture atlases or canvas-to-texture uploads) are not justified.

| Factor | Canvas2D | WebGL |
|--------|----------|-------|
| iOS stability | Reliable | Context loss issues |
| 400 rectangles | Hardware accelerated | Overkill complexity |
| Text rendering | Native `fillText()` | Requires workarounds |
| Battery impact | Lower | Higher sustained load |

---

## Safari/iPad constraints: Memory budgets and limits

Understanding Safari's hard limits is essential for avoiding silent failures:

**Per-canvas limit: 16,777,216 pixels (16 megapixels)**. This equals roughly 4096×4096 physical pixels. With iPad's **2x device pixel ratio**, a 2048×2048 logical canvas consumes the entire budget. Exceeding this limit doesn't crash Safari—the canvas simply renders transparent/blank with a console warning.

**Total canvas memory budget: ~384MB across all canvases**. Each canvas costs `width × height × 4 bytes` (RGBA). A 2048×1536 physical canvas (common iPad viewport at 2x DPR) consumes ~12.5MB. With 4 canvas layers plus tile caches, memory accumulates quickly.

**Critical memory release pattern**—Safari holds canvas memory even after dereferencing:

```javascript
function releaseCanvas(canvas) {
  canvas.width = 1;
  canvas.height = 1;
  const ctx = canvas.getContext('2d');
  ctx?.clearRect(0, 0, 1, 1);
}
```

**OffscreenCanvas is fully supported in Safari 17+** (including iOS Safari), enabling Web Worker rendering for waveforms. This is a key enabler for offloading peak computation without blocking gesture handling.

### High-DPR rendering strategy

Render waveforms at **1x DPR** and UI elements at **2x DPR**. Waveforms represent temporal data where Retina clarity provides minimal benefit, but the 4× pixel cost is significant. Apply this selectively:

```javascript
const uiDPR = window.devicePixelRatio; // Full resolution
const waveformDPR = 1; // Save 75% memory on waveform canvases
```

---

## Rendering loop for 60fps with gesture coordination

The rendering loop must separate gesture input capture from canvas updates to maintain responsiveness:

```javascript
// Gesture state in refs (no React re-renders)
const gestureState = useRef({
  scrollX: 0,
  scrollY: 0,
  velocityX: 0,
  isDragging: false,
  pendingUpdates: [],
  needsRender: false
});

// Input capture: immediate, never blocks
function handlePointerMove(e) {
  const state = gestureState.current;
  state.pendingUpdates.push({ x: e.clientX, y: e.clientY, time: performance.now() });
  
  if (!state.needsRender) {
    state.needsRender = true;
    requestAnimationFrame(flushUpdates);
  }
}

// Render: batched, once per frame
function flushUpdates(timestamp) {
  const state = gestureState.current;
  const updates = state.pendingUpdates;
  
  // Process accumulated gestures
  if (updates.length > 0) {
    const latest = updates[updates.length - 1];
    updateViewport(latest);
    updates.length = 0; // Clear without allocation
  }
  
  // Render only changed layers
  if (viewportChanged) renderClipsLayer();
  updatePlayheadPosition(); // CSS transform only
  
  state.needsRender = false;
}
```

**Dirty-rect invalidation vs full redraw**: For a timeline with **50+ visible items per track**, full layer redraw is simpler and often faster than dirty-rect tracking overhead. Use dirty rects only for the selection overlay layer where changes are localized (single item edits, handle drags).

**Double-buffering** is handled automatically by modern browsers with `requestAnimationFrame`. Manual double-buffering (offscreen canvas → visible canvas copy) adds overhead without benefit except for extremely complex scenes.

---

## Waveform rendering optimization

Pre-computing waveform peaks at multiple resolutions is the single most impactful optimization. Real-time peak calculation during scroll kills frame rate.

### Multi-resolution peak pyramid

Generate peaks at multiple samples-per-pixel ratios during audio load:

```javascript
class WaveformLOD {
  constructor(audioBuffer) {
    this.levels = [];
    // Pre-compute at common zoom levels
    const scales = [64, 256, 1024, 4096]; // samples per peak
    
    for (const scale of scales) {
      this.levels.push({
        scale,
        peaks: this.computePeaks(audioBuffer, scale)
      });
    }
  }
  
  getPeaksForZoom(samplesPerPixel) {
    // Select appropriate LOD level
    for (const level of this.levels) {
      if (level.scale <= samplesPerPixel * 2) {
        return level.peaks;
      }
    }
    return this.levels[this.levels.length - 1].peaks;
  }
}
```

### Efficient waveform drawing with single path

Batch all waveform lineTo operations into a single path to minimize draw calls:

```javascript
function drawWaveform(ctx, peaks, x, y, width, height) {
  const halfHeight = height / 2;
  const centerY = y + halfHeight;
  
  ctx.beginPath();
  ctx.moveTo(x, centerY);
  
  // Draw positive peaks (top half)
  for (let i = 0; i < peaks.length; i += 2) {
    const px = x + (i / 2);
    const max = peaks[i + 1];
    ctx.lineTo(px, centerY - max * halfHeight);
  }
  
  // Draw negative peaks (bottom half, reverse for fill)
  for (let i = peaks.length - 2; i >= 0; i -= 2) {
    const px = x + (i / 2);
    const min = peaks[i];
    ctx.lineTo(px, centerY - min * halfHeight);
  }
  
  ctx.closePath();
  ctx.fill();
}
```

### Caching waveforms to ImageBitmap

Pre-render waveforms to `ImageBitmap` for GPU-accelerated blitting:

```javascript
async function cacheWaveform(peaks, width, height, color) {
  const offscreen = new OffscreenCanvas(width, height);
  const ctx = offscreen.getContext('2d');
  ctx.fillStyle = color;
  drawWaveform(ctx, peaks, 0, 0, width, height);
  return offscreen.transferToImageBitmap();
}

// Render cached waveform: blazing fast
ctx.drawImage(cachedBitmap, itemX, itemY);
```

---

## Virtualization: Viewport culling with tile caching

For timelines with **1000+ items**, viewport culling is essential. Only render items intersecting the visible region plus a buffer zone:

```javascript
class VirtualizedTimeline {
  constructor() {
    this.buffer = 300; // pixels beyond viewport
    this.spatialIndex = new IntervalIndex(1); // 1-second buckets
  }
  
  getVisibleItems(scrollX, viewportWidth, pixelsPerSecond) {
    const startTime = Math.max(0, (scrollX - this.buffer) / pixelsPerSecond);
    const endTime = (scrollX + viewportWidth + this.buffer) / pixelsPerSecond;
    
    return this.spatialIndex.query(startTime, endTime);
  }
}

// Spatial index for O(log n) queries
class IntervalIndex {
  constructor(bucketSize = 1) {
    this.buckets = new Map();
    this.bucketSize = bucketSize;
  }
  
  query(startTime, endTime) {
    const results = new Set();
    const startBucket = Math.floor(startTime / this.bucketSize);
    const endBucket = Math.ceil(endTime / this.bucketSize);
    
    for (let b = startBucket; b <= endBucket; b++) {
      (this.buckets.get(b) || []).forEach(item => results.add(item));
    }
    return [...results];
  }
}
```

### Tile-based caching for smooth scrolling

Pre-render timeline segments to tiles for instant scroll response:

```javascript
class TileCache {
  constructor(tileWidth = 512, maxTiles = 25) {
    this.tileWidth = tileWidth;
    this.cache = new Map();
    this.maxTiles = maxTiles;
  }
  
  getTile(tileIndex, zoomLevel, renderFn) {
    const key = `${zoomLevel}_${tileIndex}`;
    
    if (this.cache.has(key)) {
      return this.cache.get(key);
    }
    
    // Render tile to offscreen canvas
    const bitmap = renderFn(tileIndex, this.tileWidth);
    this.set(key, bitmap);
    return bitmap;
  }
  
  set(key, bitmap) {
    // LRU eviction
    if (this.cache.size >= this.maxTiles) {
      const oldest = this.cache.keys().next().value;
      this.cache.get(oldest).close(); // Free GPU memory
      this.cache.delete(oldest);
    }
    this.cache.set(key, bitmap);
  }
}
```

---

## React integration pattern

Canvas should be an **uncontrolled component** with refs—React manages UI controls, not canvas rendering:

```jsx
function TimelineCanvas({ clips, zoom, scrollX }) {
  const staticCanvasRef = useRef(null);
  const clipsCanvasRef = useRef(null);
  const selectionCanvasRef = useRef(null);
  const renderStateRef = useRef({ clips: [], zoom: 1, scrollX: 0 });
  
  // Sync React props to render state without causing re-renders
  useEffect(() => {
    renderStateRef.current = { clips, zoom, scrollX };
    renderClips();
  }, [clips, zoom, scrollX]);
  
  const renderClips = useCallback(() => {
    const ctx = clipsCanvasRef.current?.getContext('2d');
    if (!ctx) return;
    
    const { clips, zoom, scrollX } = renderStateRef.current;
    ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);
    
    const visible = getVisibleClips(clips, scrollX, viewportWidth, zoom);
    visible.forEach(clip => drawClip(ctx, clip, scrollX, zoom));
  }, []);
  
  return (
    <div className="timeline-container" style={{ position: 'relative' }}>
      <canvas ref={staticCanvasRef} style={{ position: 'absolute', zIndex: 1 }} />
      <canvas ref={clipsCanvasRef} style={{ position: 'absolute', zIndex: 2 }} />
      <canvas ref={selectionCanvasRef} style={{ position: 'absolute', zIndex: 3 }} />
      <Playhead position={playheadX} /> {/* DOM element with CSS transform */}
      <Tooltips /> {/* DOM overlays for interactive elements */}
    </div>
  );
}
```

**Zustand for canvas state** works well because it can be accessed outside React (in animation loops) and supports selective subscriptions:

```javascript
const useTimelineStore = create((set, get) => ({
  scrollX: 0,
  zoom: 1,
  selectedItems: new Set(),
  setScrollX: (x) => set({ scrollX: x }),
  // Access in render loop without hooks
  getScrollX: () => get().scrollX,
}));
```

---

## Hit testing and gesture handling

**Canvas-based hit testing with Path2D** is efficient for clip selection:

```javascript
const clipPaths = new Map(); // clipId -> Path2D

function updateClipPath(clip, scrollX, zoom) {
  const path = new Path2D();
  const x = (clip.startTime * zoom) - scrollX;
  const width = clip.duration * zoom;
  path.rect(x, clip.trackY, width, TRACK_HEIGHT);
  clipPaths.set(clip.id, path);
}

function hitTest(ctx, clientX, clientY) {
  const rect = ctx.canvas.getBoundingClientRect();
  const x = clientX - rect.left;
  const y = clientY - rect.top;
  
  for (const [clipId, path] of clipPaths) {
    if (ctx.isPointInPath(path, x, y)) {
      return clipId;
    }
  }
  return null;
}
```

**Touch event configuration for iOS**—passive listeners are critical:

```javascript
canvas.addEventListener('touchstart', handleTouchStart, { passive: false });
canvas.addEventListener('touchmove', handleTouchMove, { passive: false });

// CSS to prevent browser gestures on canvas
.timeline-canvas {
  touch-action: none;
}
```

---

## Memory management for iPad Safari

Implement a memory-aware caching strategy:

```javascript
class MemoryAwareCache {
  constructor() {
    this.maxSizeBytes = 100 * 1024 * 1024; // 100MB limit (conservative)
    this.currentSize = 0;
    this.cache = new Map();
  }
  
  estimateSize(bitmap) {
    return bitmap.width * bitmap.height * 4; // RGBA
  }
  
  set(key, bitmap) {
    const size = this.estimateSize(bitmap);
    
    // Evict until under budget
    while (this.currentSize + size > this.maxSizeBytes && this.cache.size > 0) {
      const oldest = this.cache.keys().next().value;
      this.evict(oldest);
    }
    
    this.cache.set(key, { bitmap, size });
    this.currentSize += size;
  }
  
  evict(key) {
    const entry = this.cache.get(key);
    if (entry) {
      entry.bitmap.close(); // Critical: free GPU memory
      this.currentSize -= entry.size;
      this.cache.delete(key);
    }
  }
}
```

---

## Conclusion

REAmo's canvas architecture should prioritize **stability and predictable performance** over theoretical optimization. The recommended stack: Canvas2D rendering, 3-4 layered canvases separated by update frequency, CSS-transformed DOM playhead, pre-computed multi-resolution waveform peaks cached as ImageBitmaps, viewport culling with spatial indexing, and conservative memory budgets respecting Safari's 16MP/384MB limits.

This architecture handles the specified scale—8 tracks × 50+ items, 60fps playback, pan/pinch gestures—within iPad Safari's constraints while avoiding WebGL's iOS stability pitfalls. The key insight: the most impactful optimizations are structural (layer separation, playhead as DOM, pre-computed waveforms) rather than low-level rendering tricks.
