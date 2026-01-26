# Research Query: React 19 + Zustand Real-Time WebSocket DAW Controller Production Checklist

**Purpose:** This document provides comprehensive context for generating a production code review checklist tailored to the REAmo frontend codebase. The output should match the format of `ZIG_PRODUCTION_REVIEW_CHECKLIST.md`.

**Target Output:** `FRONTEND_PRODUCTION_REVIEW_CHECKLIST.md`

---

## Project Overview

**REAmo** is a React-based web control surface for REAPER (digital audio workstation). It runs as a PWA on iPad/iPhone for hour-long recording sessions. Users rarely refresh - the app must remain stable over extended use.

### Tech Stack (exact versions from package.json)

```json
{
  "react": "^19.2.0",
  "react-dom": "^19.2.0",
  "zustand": "^5.0.9",
  "@tanstack/react-virtual": "^3.13.17",
  "lucide-react": "^0.559.0",
  "vite": "^7.2.4",
  "vite-plugin-singlefile": "^2.3.0",
  "tailwindcss": "^4.1.17",
  "typescript": "~5.9.3"
}
```

- **Build output:** Single HTML file (all CSS/JS inlined via vite-plugin-singlefile)
- **Target platforms:** iOS Safari PWA (primary), desktop browsers
- **Update frequency:** 30Hz meter updates, 60fps playhead animation, transport events every 33ms

---

## Critical Architecture Patterns

### 1. WebSocket Connection with Aggressive Reconnection

**File:** `src/core/WebSocketConnection.ts`

```typescript
// Key patterns in use:

// Auto-reconnect with exponential backoff
const INITIAL_RETRY_DELAY = 1000;
const MAX_RETRY_DELAY = 30000;
const RETRY_MULTIPLIER = 1.5;
const DEFAULT_MAX_RETRIES = 10;

// iOS Safari-specific workarounds:
// 1. Iframe pre-warmup for NSURLSession lazy init
private async warmupViaIframe(wsUrl: string): Promise<void> {
  // Creates hidden iframe with WebSocket to warm network stack
  // Safari's NSURLSession has lazy WebSocket initialization on cold start
}

// 2. Focus cycle trick for PWA cold start
if (isSafari && isPWA) {
  window.blur();
  await new Promise(r => setTimeout(r, 50));
  window.focus();
  await new Promise(r => setTimeout(r, 50));
}

// 3. CONNECTING state timeout (5s) for frozen sockets
const CONNECT_TIMEOUT_MS = 5000;
this.connectTimeout = setTimeout(() => {
  if (this.ws?.readyState === WebSocket.CONNECTING) {
    // Safari: socket stuck, schedule retry
  }
}, CONNECT_TIMEOUT_MS);

// 4. ALWAYS force reconnect on visibility return (zombie detection)
handleVisibilityChange(isVisible: boolean): void {
  if (isVisible) {
    // ALWAYS force reconnect - Safari zombies can't be trusted
    this.forceReconnect();
  }
}

// 5. Heartbeat ping/pong every 10s with 3s timeout
const HEARTBEAT_INTERVAL_MS = 10000;
const HEARTBEAT_TIMEOUT_MS = 3000;

// 6. EXTSTATE discovery with 2s timeout for PWA cold start
async function fetchExtState(section: string, key: string): Promise<string | null> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2000);
  // ...
}

// 7. HTML mtime check for hot reload on reconnect
if (this.htmlMtime !== null && this.htmlMtime !== msg.htmlMtime) {
  window.location.reload();
}
```

### 2. Zustand Store Structure (17 slices, manual localStorage persistence)

**File:** `src/store/index.ts`

```typescript
// Combined store type - 17 slices total
export type ReaperStore =
  ConnectionSlice &      // connected, errorCount, lastError
  TransportSlice &       // playState, position, bpm, timeSignature
  ProjectSlice &         // canUndo/canRedo, isDirty, memoryWarning, barOffset
  TracksSlice &          // Record<number, Track>, trackSkeleton, totalTracks
  RegionsSlice &         // Region[] with beat positions
  MarkersSlice &         // Marker[] with beat positions
  RegionEditSlice &      // Complex drag state machine
  ItemsSlice &           // Media items with peaks cache
  ToolbarSlice &         // User actions, Map<string, ToggleState>
  ActionsSlice &         // ~3000 cached REAPER actions for search
  StudioLayoutState &    // Section order/collapse state
  NotesSlice &           // Project notes with dirty/save state
  PlaylistSlice &        // Playlist engine state
  ActionsViewSlice &     // Sections with nested action arrays
  ClockViewSlice &       // Clock display element config
  FxStateSlice &         // FX state for all tracks
  SendsStateSlice &      // Send routing state
  UIPreferencesState;    // Tab bar, transport position, fonts

// Store creation with slice composition
export const useReaperStore = create<ReaperStore>()((set, get, store) => ({
  _testMode: false,
  _setTestMode: (enabled: boolean) => set({ _testMode: enabled }),

  ...createConnectionSlice(set, get, store),
  ...createTransportSlice(set, get, store),
  // ... 15 more slices

  handleWebSocketMessage: (message: ServerMessage) => {
    if (get()._testMode) return; // Skip in E2E tests
    // 15+ event type handlers
  },
}));

// Manual localStorage persistence pattern (NOT Zustand persist middleware)
export const TOOLBAR_STORAGE_KEY = 'reamo-toolbar-config';
saveToolbarToStorage: () => {
  try {
    localStorage.setItem(TOOLBAR_STORAGE_KEY, JSON.stringify(toolbarActions));
  } catch (e) {
    console.error('Failed to save toolbar config:', e);
  }
},
loadToolbarFromStorage: () => {
  try {
    const saved = localStorage.getItem(TOOLBAR_STORAGE_KEY);
    if (saved) {
      const actions = JSON.parse(saved) as ToolbarAction[];
      set({ toolbarActions: actions });
    }
  } catch (e) {
    console.error('Failed to load toolbar config:', e);
  }
},
```

### 3. Real-Time Event Streams (30Hz meter updates)

**File:** `src/core/WebSocketTypes.ts` and `src/store/index.ts`

```typescript
// Event types hitting the store:
export type EventType =
  | 'transport'           // Full transport state (1-5Hz when stopped, 30Hz when playing)
  | 'tt'                  // Transport tick: lightweight position updates (30Hz during playback)
  | 'project'             // Undo state, settings, memoryWarning (1Hz)
  | 'trackSkeleton'       // All track names/GUIDs (1Hz on structure change)
  | 'tracks'              // Subscribed track data only (5Hz)
  | 'meters'              // GUID-keyed map at 30Hz for subscribed tracks
  | 'markers' | 'regions' // Full array replacement (on change)
  | 'items'               // Media items (on change)
  | 'fx_state' | 'sends_state'  // 5Hz broadcast
  | 'actionToggleState'   // Sparse delta updates
  | 'tempoMap'            // Tempo markers for prediction
  | 'playlist'            // Playlist engine state
  | 'reload';             // Hot reload trigger

// Meters event handler - 30Hz updates
} else if (isMetersEvent(message)) {
  const msg = message as unknown as { m: Record<string, MeterData> };
  get().updateMeters(msg.m);
}

// TracksSlice meter update - only updates if values changed
updateMeters: (meters) => {
  const { tracks, guidToIndex } = get();
  const updatedTracks = { ...tracks };
  let hasChanges = false;

  for (const [guid, meter] of Object.entries(meters)) {
    const idx = guidToIndex.get(guid) ?? meter.i;
    if (updatedTracks[idx]) {
      const peak = Math.max(meter.l, meter.r);
      if (
        updatedTracks[idx].lastMeterPeak !== peak ||
        updatedTracks[idx].clipped !== meter.c
      ) {
        updatedTracks[idx] = {
          ...updatedTracks[idx],
          lastMeterPeak: peak,
          lastMeterPos: peak,
          clipped: meter.c,
        };
        hasChanges = true;
      }
    }
  }

  if (hasChanges) {
    set({ tracks: updatedTracks });
  }
},
```

### 4. Transport Sync Engine (NTP-style clock synchronization)

**Files:** `src/core/TransportSyncEngine.ts`, `src/lib/transport-sync/ClockSync.ts`

```typescript
// TransportSyncEngine - Singleton architecture:
export class TransportSyncEngine {
  private clockSync: ClockSync;           // NTP-style offset calculation
  private beatPredictor: BeatPredictor;   // Client-side extrapolation
  private adaptiveBuffer: AdaptiveBuffer; // Jitter measurement
  private networkState: NetworkState;     // Quality tracking
  private subscribers = new Set<TransportSyncSubscriber>();
  private rafId: number | null = null;    // Animation frame tracking

  // Cached state to avoid allocations in 60fps loop
  private cachedState: TransportSyncState = {
    position: 0,
    beat: 0,
    phase: 0,
    tempo: 120,
    isPlaying: false,
    isRecording: false,
    timeSignature: { numerator: 4, denominator: 4 },
    isSynced: false,
    barBeatTicks: '1.1.00',
  };

  // Animation frame callback
  private tick = (): void => {
    if (!this.isPlaying) {
      this.rafId = null;
      return;
    }
    this.clockSync.tick();
    this.networkState.tick();
    this.notifySubscribers();
    this.rafId = requestAnimationFrame(this.tick);
  };

  subscribe(callback: TransportSyncSubscriber): () => void {
    this.subscribers.add(callback);
    callback(this.cachedState);
    return () => this.subscribers.delete(callback);
  }

  destroy(): void {
    this.stopAnimation();
    this.clockSync.destroy();
    this.subscribers.clear();
  }
}

// Singleton instance
export const transportSyncEngine = new TransportSyncEngine();

// ClockSync - NTP algorithm:
export class ClockSync {
  private offset = 0;
  private targetOffset = 0;
  private samples: SyncSample[] = [];
  private manualOffset = 0; // User-configurable ±50ms, persisted to localStorage

  onSyncResponse(t0: number, t1: number, t2: number): SyncResult | null {
    const t3 = this.timeProvider.now();
    // NTP formula
    const rtt = t3 - t0 - (t2 - t1);
    const offset = ((t1 - t0) + (t2 - t3)) / 2;
    // ... sample collection and slewing
  }

  // Gradual slew toward target offset (0.5ms per second)
  tick(): void {
    const diff = this.targetOffset - this.offset;
    if (Math.abs(diff) > this.stepThresholdMs) {
      this.offset = this.targetOffset; // Step immediately
    } else {
      const maxSlew = (this.slewRateMs * deltaMs) / 1000;
      this.offset += Math.max(-maxSlew, Math.min(maxSlew, diff));
    }
  }
}
```

### 5. Virtualized Subscriptions (viewport-driven)

**Files:** `src/hooks/useVirtualizedSubscription.ts`, `src/components/Studio/VirtualizedTrackList.tsx`

```typescript
// useVirtualizedSubscription - bridges viewport to WebSocket
export function useVirtualizedSubscription(options: UseVirtualizedSubscriptionOptions): void {
  const {
    visibleStart,
    visibleEnd,
    totalTracks,
    filteredSkeleton,
    filterActive,
    includeMaster,
    sendCommand,
    subscriptionBuffer = 30,  // Subscribe 30 beyond visible
    debounceMs = 200,         // Debounce to prevent subscription storms
  } = options;

  const debounceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const prevSubscriptionRef = useRef<string | null>(null);

  // Build subscription key for change detection
  const buildSubscriptionKey = useCallback((): string => {
    if (filterActive) {
      // GUID mode: use visible GUIDs from filtered skeleton
      const guids = filteredSkeleton.slice(startIdx, endIdx + 1).map(t => t.g);
      return `guids:${guids.sort().join(',')}`;
    } else {
      // Range mode: calculate track indices from virtual indices
      return `range:${subStart}-${subEnd}:master=${includeMaster}`;
    }
  }, [/* deps */]);

  // Debounced subscription update
  useEffect(() => {
    const subscriptionKey = buildSubscriptionKey();
    if (subscriptionKey === prevSubscriptionRef.current) return;

    if (debounceTimerRef.current) clearTimeout(debounceTimerRef.current);

    debounceTimerRef.current = setTimeout(() => {
      sendSubscription();
      prevSubscriptionRef.current = subscriptionKey;
    }, debounceMs);

    return () => {
      if (debounceTimerRef.current) clearTimeout(debounceTimerRef.current);
    };
  }, [/* deps */]);

  // NOTE: Subscriptions are NOT cleaned up on unmount to avoid data gaps
}

// VirtualizedTrackList - TanStack Virtual
const TRACK_WIDTH = 116; // 100px strip + 12px meter + 4px gap
const OVERSCAN = 5;

export function VirtualizedTrackList({ filter, includeMaster, className }) {
  const [scrollElement, setScrollElement] = useState<HTMLDivElement | null>(null);
  // Defensive selector - handles hydration timing issues
  const tracks = useReaperStore((state) => state?.tracks ?? {});

  const virtualizer = useVirtualizer({
    count: trackCount,
    getScrollElement: () => scrollElement,
    estimateSize: () => TRACK_WIDTH,
    horizontal: true,
    overscan: OVERSCAN,
  });
  // ...
}
```

### 6. Touch Gesture Hooks

**Files:** `src/hooks/useLongPress.ts`, `src/hooks/useDoubleTap.ts`, `src/components/Timeline/hooks/usePlayheadDrag.ts`

```typescript
// useLongPress - tap vs long-press detection
export function useLongPress({ onTap, onLongPress, duration = 400 }) {
  const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const longPressTriggeredRef = useRef(false);
  const isTouchRef = useRef(false);

  const start = useCallback((isTouch: boolean) => {
    if (!isTouch && isTouchRef.current) return; // Block synthesized mouse events
    isTouchRef.current = isTouch;
    longPressTriggeredRef.current = false;

    if (timeoutRef.current) clearTimeout(timeoutRef.current);
    if (onLongPress) {
      timeoutRef.current = setTimeout(() => {
        longPressTriggeredRef.current = true;
        onLongPress();
      }, duration);
    }
  }, [onLongPress, duration]);

  const end = useCallback((isTouch: boolean) => {
    if (!isTouch && isTouchRef.current) return;
    if (timeoutRef.current) { clearTimeout(timeoutRef.current); timeoutRef.current = null; }
    if (!longPressTriggeredRef.current && onTap) onTap();
    if (isTouch) {
      setTimeout(() => { isTouchRef.current = false; }, 300); // Block synthesized events
    }
  }, [onTap]);

  // Event handlers with preventDefault
  const onTouchStart = useCallback((e: React.TouchEvent) => {
    e.preventDefault();
    start(true);
  }, [start]);
}

// usePlayheadDrag - pointer capture with vertical cancel
const VERTICAL_CANCEL_THRESHOLD = 50;

export function usePlayheadDrag({ containerRef, onSeek, bpm, ... }) {
  const handlePointerDown = useCallback((e: React.PointerEvent) => {
    e.stopPropagation();
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
    setIsDragging(true);
    setDragStartY(e.clientY);
  }, []);

  const handlePointerMove = useCallback((e: React.PointerEvent) => {
    if (!isDragging) return;
    const deltaY = Math.abs(e.clientY - dragStartY);
    if (deltaY > VERTICAL_CANCEL_THRESHOLD) {
      // Cancel - snap preview back to current position
      setPreviewPercent(playheadPercent);
      return;
    }
    // Calculate snapped position
    const snappedTime = bpm ? snapToGrid(rawTime, bpm, 4) : rawTime;
    setPreviewPercent(snappedPercent);
  }, [/* deps */]);

  const handlePointerUp = useCallback((e: React.PointerEvent) => {
    (e.target as HTMLElement).releasePointerCapture(e.pointerId);
    if (deltaY <= VERTICAL_CANCEL_THRESHOLD) {
      onSeek(previewTime);
    }
    setIsDragging(false);
  }, [/* deps */]);
}
```

### 7. Animation Engines (separate from React state)

**File:** `src/core/TransportAnimationEngine.ts`, `src/hooks/useTransportAnimation.ts`

```typescript
// TransportAnimationEngine - 60fps playhead position interpolation
// Separate from React to avoid re-renders

// Hook for direct DOM updates
export function useTransportAnimation(callback: TransportSubscriber, deps: DependencyList = []): void {
  useLayoutEffect(() => {
    return transportEngine.subscribe(callback);
  }, deps);
}

// Usage pattern - zero React re-renders:
function Playhead() {
  const elementRef = useRef<HTMLDivElement>(null);

  useTransportAnimation((state) => {
    if (elementRef.current) {
      elementRef.current.style.left = `${state.position * 10}px`;
    }
  });

  return <div ref={elementRef} className="playhead" />;
}
```

### 8. PWA Safe Area Handling

**File:** `src/index.css`

```css
/* Root document setup for PWA */
html {
  height: 100%;
  min-height: calc(100% + env(safe-area-inset-top, 0px));
  background: #1a1a1a;
}

body {
  height: 100%;
  min-height: 100dvh; /* Dynamic viewport height - Safari URL bar */
  margin: 0;
  overflow: hidden;
}

/* iOS Safari-safe full height */
.h-screen-safe {
  height: 100vh; /* Fallback */
  height: 100dvh; /* Dynamic viewport height */
}

/* Bottom safe area - 34px fallback for WebKit timing bug */
.safe-area-bottom {
  padding-bottom: calc(5px + env(safe-area-inset-bottom, 0px)) !important;
}

@media (display-mode: standalone) {
  .safe-area-bottom {
    /* 34px fallback for WebKit bug where env() returns 0 initially */
    padding-bottom: calc(0.5rem + env(safe-area-inset-bottom, 34px)) !important;
  }
}

/* Horizontal safe areas - for landscape orientation */
.safe-area-x {
  padding-left: env(safe-area-inset-left, 0px);
  padding-right: env(safe-area-inset-right, 0px);
}
```

### 9. Icon Picker with 1900 Icons

**File:** `src/components/Toolbar/IconPicker.tsx`

```typescript
import { icons } from 'lucide-react';

// All icon names from lucide-react (~1900 entries)
const iconNames = Object.keys(icons);

// Featured audio icons shown first (100+)
const FEATURED_ICONS = ['Play', 'Pause', 'Square', 'Circle', /* ... */];

// Filter limits to 100 to prevent performance issues
const filteredIcons = useMemo(() => {
  if (!searchLower) {
    const featured = FEATURED_ICONS.filter(name => iconNames.includes(name));
    const others = iconNames.filter(name => !FEATURED_ICONS.includes(name)).slice(0, 100);
    return [...featured, ...others];
  }
  return iconNames.filter(name => name.toLowerCase().includes(searchLower)).slice(0, 100);
}, [search]);

// No virtualization - relies on slice limiting
```

### 10. Testing Infrastructure

**File:** `src/test/setup.ts`

```typescript
import { afterEach, beforeEach } from 'vitest'
import { cleanup } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import { useReaperStore } from '../store'

afterEach(() => {
  cleanup()
})

beforeEach(() => {
  // Manual reset of regionEditSlice state
  useReaperStore.setState({
    pendingChanges: {},
    selectedRegionIds: [],
    dragType: 'none',
    // ... more state reset
  })
})
```

```typescript
// E2E support: Store exposed on window
if (import.meta.env.DEV) {
  (window as unknown as { __REAPER_STORE__: typeof useReaperStore }).
    __REAPER_STORE__ = useReaperStore;
}

// Test mode flag to skip WebSocket message processing
handleWebSocketMessage: (message: ServerMessage) => {
  if (get()._testMode) return; // Allows E2E fixtures to persist
  // ...
}
```

---

## Specific Concerns to Address in Checklist

### 1. Memory Leaks (Critical for hour-long sessions)

**Patterns to audit:**

```typescript
// WebSocket listeners - connection lifetime
// useReaperConnection cleanup exists: connection.stop() + null refs
// But does it properly clean up all listeners?

// Zustand subscriptions
const foo = useReaperStore((s) => s.foo);
// Risk: Selectors that capture component props in closures?

// Refs with timers - found in:
// - useLongPress: timeoutRef
// - useDoubleTap: timeoutRef
// - useVirtualizedSubscription: debounceTimerRef
// Are all cleaned up on unmount?

// Animation frame tracking:
// - TransportAnimationEngine: rafId tracking + cancelAnimationFrame
// - TransportSyncEngine: same pattern
// Cleanup verified?

// Event listeners with cleanup needed:
// - window.addEventListener('resize', ...) in App.tsx
// - window.addEventListener('visibilitychange', ...)
// - window.addEventListener('online/offline', ...)
// - window.addEventListener('keydown', ...) in IconPicker

// Map objects in state that grow:
// - toggleStates: Map<string, ToggleState>
// - actionsToggleStates: Map<number, ToggleState>
// - guidToIndex: Map<string, number>
// These should stabilize but need bounds checking

// Peaks cache (core/PeaksCache.ts):
// What's the eviction strategy?
```

**Grep patterns:**
```bash
# setTimeout without cleanup tracking
grep -rn "setTimeout" --include="*.ts" --include="*.tsx" | grep -v "useRef\|clearTimeout"

# setInterval without cleanup
grep -rn "setInterval" --include="*.ts" --include="*.tsx"

# addEventListener without removeEventListener
grep -rn "addEventListener" --include="*.ts" --include="*.tsx"

# requestAnimationFrame without cancel
grep -rn "requestAnimationFrame" --include="*.ts" --include="*.tsx"

# Map/Set that could grow unbounded
grep -rn "new Map\|new Set" --include="*.ts" --include="*.tsx"
```

### 2. Re-render Performance (30Hz updates hitting React)

**Current patterns:**

```typescript
// Meters update at 30Hz - updateMeters() in tracksSlice:
// Optimization: Only updates if peak/clipped changed
// But: Creates new tracks object spread every time

// Selector patterns to audit:
const playState = useReaperStore((s) => s.playState); // Fine - primitive
const tracks = useReaperStore((state) => state?.tracks ?? {}); // Object - re-renders

// Animation bypass (good pattern):
useTransportAnimation((state) => {
  elementRef.current.style.left = `${state.position}px`; // No re-render
});
```

**Questions:**
1. Which components select entire `tracks` object unnecessarily?
2. Are there selectors that re-run on every meter update?
3. Any cargo-cult useMemo/useCallback that adds overhead without benefit?
4. Any missing memoization causing cascading re-renders?

**Grep patterns:**
```bash
# Components selecting entire objects
grep -rn "useReaperStore.*=> state\." --include="*.tsx"

# useMemo with no deps or empty deps
grep -rn "useMemo.*\[\]" --include="*.tsx"

# Large inline objects in JSX (re-created each render)
grep -rn "style={{" --include="*.tsx"
```

### 3. WebSocket Lifecycle Edge Cases

**Covered scenarios:**
- Reconnect with exponential backoff
- iOS Safari zombie socket detection
- PWA cold start workarounds
- Visibility change handling
- Online/offline events

**Questions to audit:**
- What happens if message arrives during reconnect?
- `pendingResponses` Map - cleared on disconnect? Timeout handling?
- `sendAsync()` has 5s timeout - but what if WS closes before timeout?
- Clock sync state on reconnect - is resync() sufficient?

**Grep patterns:**
```bash
# Pending response handling
grep -rn "pendingResponses" --include="*.ts"

# Async operations that could race
grep -rn "sendAsync\|sendCommand" --include="*.ts" --include="*.tsx"
```

### 4. TypeScript Strictness Escape Hatches

**Patterns that hide bugs:**

```typescript
// Type assertions
as unknown as { m: Record<string, MeterData> }  // In store meter handling
as ToolbarAction  // In updateToolbarAction

// Non-null assertions
msg.id!  // In sendAsync pendingResponses

// Optional chaining hiding errors
state?.tracks ?? {}  // Defensive but masks timing issues

// Record<K, V> vs proper Map - key validation?
tracks: Record<number, Track>
```

**Grep patterns:**
```bash
# Type assertions
grep -rn " as " --include="*.ts" --include="*.tsx" | grep -v "import"

# Non-null assertions
grep -rn "\!" --include="*.ts" --include="*.tsx" | grep -v "!=\|!/\|=!"

# any type usage
grep -rn ": any\|as any" --include="*.ts" --include="*.tsx"
```

### 5. Zustand Patterns

**Slice composition concerns:**

```typescript
// 17 slices spread into one store
export const useReaperStore = create<ReaperStore>()((set, get, store) => ({
  ...createConnectionSlice(set, get, store),
  // ...16 more
}));
```

**Potential issues:**
- Stale closures in callbacks that capture `get()` results
- Manual localStorage sync (not persist middleware) - race conditions?
- Map objects in state don't trigger re-renders on internal mutation
- Slice interdependencies - can one slice break another?

**Grep patterns:**
```bash
# get() usage in action definitions (closure risk)
grep -rn "get()\." --include="*Slice.ts"

# localStorage access patterns
grep -rn "localStorage\." --include="*.ts"

# Map.set without triggering state update
grep -rn "\.set(" --include="*Slice.ts"
```

### 6. Touch/Gesture Correctness

**iOS Safari quirks to check:**
- `preventDefault()` on touchstart - does this block scroll?
- 300ms delay to block synthesized mouse events - correct?
- `setPointerCapture` - iOS Safari support confirmed?
- `passive: false` for touch listeners - performance impact?

**Grep patterns:**
```bash
# preventDefault usage
grep -rn "preventDefault" --include="*.ts" --include="*.tsx"

# Touch event handling
grep -rn "onTouch\|TouchEvent" --include="*.ts" --include="*.tsx"

# Pointer capture
grep -rn "setPointerCapture\|releasePointerCapture" --include="*.ts" --include="*.tsx"
```

### 7. PWA Production Issues

**Current handling:**
- Service worker: **NOT present in codebase**
- Manifest: Referenced in HTML but file location unclear
- Standalone mode detection: `window.matchMedia('(display-mode: standalone)')`
- Safe area handling: Comprehensive CSS utilities

**Questions:**
- What's the caching strategy without service worker?
- App update flow? (Currently: HTML mtime check on reconnect → reload)
- iOS standalone mode limitations being hit?
- What happens when REAPER isn't running but PWA is opened?

### 8. Error Boundaries

**Current state:**
- No `ErrorBoundary` components found in codebase
- Console errors but no user-facing recovery
- What happens when a slice throws?

**Grep patterns:**
```bash
# Error boundary usage
grep -rn "ErrorBoundary\|componentDidCatch" --include="*.tsx"

# Uncaught error handling
grep -rn "window.onerror\|unhandledrejection" --include="*.ts"
```

### 9. Testing Gaps

**Current coverage:**
- Unit tests: Pure functions (tempoUtils, time, rippleOperations)
- Store tests: Slice behavior (transportSlice, regionEditSlice)
- Hook tests: useCurrentMarker, usePeakHold
- Component tests: MakeSelectionModal, Timeline
- E2E: Playwright setup

**Hard-to-test areas:**
- WebSocket reconnection flows (multi-step state machine)
- 30Hz real-time update handling
- Touch gesture sequences on iOS
- iOS Safari-specific code paths
- Memory accumulation over time

### 10. Bundle Analysis

**Concerns:**

```typescript
// lucide-react: ~1900 icons
import { icons } from 'lucide-react';
const iconNames = Object.keys(icons); // Entire icon set in bundle?

// Individual imports elsewhere - tree-shaking?
import { Play, Pause, Square } from 'lucide-react';
```

- vite-plugin-singlefile: Everything inlined, no code splitting
- Initial load size critical for PWA
- No lazy loading possible with single-file output

**Grep patterns:**
```bash
# Large imports that might not tree-shake
grep -rn "from 'lucide-react'" --include="*.ts" --include="*.tsx"

# Dynamic imports (should be none with singlefile)
grep -rn "import(" --include="*.ts" --include="*.tsx"
```

### 11. Accessibility

**Current gaps:**
- Touch-optimized but keyboard navigation unclear
- No `aria-live` regions for real-time updates
- `prefers-reduced-motion`: Not referenced
- Focus management across views?
- Screen reader announcements for transport state?

**Grep patterns:**
```bash
# ARIA attributes
grep -rn "aria-" --include="*.tsx"

# Focus management
grep -rn "focus\|tabIndex" --include="*.tsx"

# Motion preferences
grep -rn "prefers-reduced-motion" --include="*.ts" --include="*.tsx" --include="*.css"
```

---

## File Structure Reference

```
frontend/src/
├── App.tsx                  # Root with view switching
├── main.tsx                 # React entry point
├── index.css                # Tailwind + safe area utilities
├── viewRegistry.ts          # View component registry
├── core/
│   ├── WebSocketConnection.ts   # Connection manager (608 lines)
│   ├── WebSocketTypes.ts        # Protocol types + type guards (592 lines)
│   ├── WebSocketCommands.ts     # Command builders
│   ├── TransportSyncEngine.ts   # Clock sync singleton (415 lines)
│   ├── TransportAnimationEngine.ts  # 60fps interpolation
│   ├── PeaksCache.ts            # Waveform data cache
│   ├── types.ts                 # Core domain types
│   └── tempoUtils.ts            # Beat/time calculations
├── store/
│   ├── index.ts                 # Combined store (395 lines, 17 slices)
│   └── slices/
│       ├── connectionSlice.ts   # 34 lines
│       ├── transportSlice.ts    # Transport state
│       ├── projectSlice.ts      # Project metadata
│       ├── tracksSlice.ts       # 135 lines, Record + Map
│       ├── regionsSlice.ts      # Region arrays
│       ├── markersSlice.ts      # Marker arrays
│       ├── regionEditSlice.ts   # Complex drag state machine
│       ├── itemsSlice.ts        # Media items
│       ├── toolbarSlice.ts      # 249 lines, Map<string, ToggleState>
│       ├── actionsSlice.ts      # 3000+ cached actions
│       ├── actionsViewSlice.ts  # 309 lines, nested sections
│       ├── studioLayoutSlice.ts # Section layout
│       ├── notesSlice.ts        # Project notes
│       ├── playlistSlice.ts     # Playlist engine
│       ├── clockViewSlice.ts    # Clock display config
│       ├── fxStateSlice.ts      # FX routing
│       ├── sendsStateSlice.ts   # Send routing
│       └── uiPreferencesSlice.ts # 155 lines, localStorage
├── hooks/
│   ├── useReaperConnection.ts   # 287 lines, lifecycle
│   ├── useVirtualizedSubscription.ts  # 198 lines
│   ├── useTransportAnimation.ts # 49 lines
│   ├── useTransportSync.ts      # Clock sync hook
│   ├── useLongPress.ts          # 142 lines
│   ├── useDoubleTap.ts          # 76 lines
│   └── usePeakHold.ts           # Meter peak hold
├── components/
│   ├── ReaperProvider.tsx       # Connection context
│   ├── Studio/
│   │   └── VirtualizedTrackList.tsx  # 189 lines
│   ├── Timeline/
│   │   └── hooks/usePlayheadDrag.ts  # 145 lines
│   ├── Toolbar/
│   │   └── IconPicker.tsx       # 235 lines, 1900 icons
│   └── Track/
│       ├── LevelMeter.tsx       # 30Hz display
│       └── Fader.tsx            # Touch-optimized
└── lib/transport-sync/
    ├── ClockSync.ts             # 245 lines, NTP algorithm
    ├── BeatPredictor.ts         # Client extrapolation
    ├── AdaptiveBuffer.ts        # Jitter handling
    └── NetworkState.ts          # Quality tracking
```

---

## Output Format Requirements

Generate a checklist document (`FRONTEND_PRODUCTION_REVIEW_CHECKLIST.md`) with:

### 1. Severity-rated tables for each concern area

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | Memory leak from X pattern | App becomes unusable after 2+ hours |
| **High** | Re-render storm on Y event | UI stutters during 30Hz updates |
| **Medium** | Missing cleanup in Z hook | Gradual memory growth |

### 2. Specific grep/search patterns

```bash
# Description of what issue this finds
grep -rn "pattern" --include="*.ts" --include="*.tsx" src/
```

### 3. Anti-patterns with fixes

```typescript
// ANTI-PATTERN: Selecting entire object causes re-render on any change
const tracks = useReaperStore((s) => s.tracks);

// GOOD: Select only needed values
const trackCount = useReaperStore((s) => Object.keys(s.tracks).length);
const specificTrack = useReaperStore((s) => s.tracks[trackIndex]);
```

### 4. Questions to ask during review

For each section, include 3-5 questions like:
- When exactly does this cleanup run?
- What happens if the component unmounts during the async operation?
- Is this selector stable across re-renders?

### 5. React 19 / Zustand 5 specific gotchas

Include any breaking changes or new patterns specific to:
- React 19 concurrent features
- React 19 automatic batching
- Zustand 5 API changes from v4
- TypeScript 5.9 strict mode implications

### Focus areas for this specific codebase:

1. **Silent failures during hour-long sessions** - memory leaks, stale subscriptions
2. **Memory growth that compounds** - Map/Set growth, uncleaned refs, cached data
3. **iOS Safari-specific issues** - PWA cold start, WebSocket zombies, safe areas
4. **State inconsistencies after reconnection** - partial state, stale closures
5. **30Hz update performance** - re-render storms, selector efficiency
