# REAmo Frontend Production Review Checklist

**A memory leak or zombie connection in this app means a musician loses their flow during an hour-long session.** This checklist targets the specific architecture: React 19 PWA with 30Hz meter updates, Zustand 5 with 17 slices, WebSocket with iOS Safari workarounds, and 60fps transport animations.

---

## 1. Memory Safety (Critical)

Hour-long sessions on iOS Safari with 30Hz updates create memory pressure. iOS terminates PWAs without warning under memory pressure.

### REAmo-specific memory patterns to audit

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | Timer refs in gesture hooks cleaned up on unmount | Memory leak per component mount |
| **Critical** | `transportSyncEngine` singleton properly destroyed | RAF loop runs forever |
| **Critical** | WebSocket `pendingResponses` Map cleared on disconnect | Unbounded growth on reconnect cycles |
| **High** | Zustand Map objects (`toggleStates`, `guidToIndex`) have bounds | Memory growth over session |
| **High** | `useVirtualizedSubscription` debounce timer cleared | Timer leak on rapid view switching |
| **Medium** | PeaksCache has eviction strategy | Waveform data accumulates |

### Cleanup patterns in this codebase

```typescript
// VERIFIED GOOD: useLongPress.ts cleans up timer
const cancel = useCallback(() => {
  if (timeoutRef.current) {
    clearTimeout(timeoutRef.current);
    timeoutRef.current = null;
  }
}, []);
// But: cancel() only called on mouseLeave - what about unmount?

// NEEDS AUDIT: useDoubleTap.ts - no useEffect cleanup
const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
// If component unmounts during delay, timer still fires

// GOOD: TransportSyncEngine.ts has destroy()
destroy(): void {
  this.stopAnimation();
  this.clockSync.destroy();
  this.subscribers.clear();
}
// But: Is destroy() ever called? It's a singleton.
```

### Grep patterns for memory issues

```bash
# Timers without cleanup return in useEffect
rg "setTimeout|setInterval" --type ts --type tsx -l src/ | xargs rg -L "clearTimeout|clearInterval"

# useRef for timers - check each has cleanup
rg "useRef<.*setTimeout" --type ts --type tsx src/

# Event listeners - verify each has removeEventListener
rg "addEventListener" --type ts --type tsx src/
rg "removeEventListener" --type ts --type tsx src/

# Map/Set that could grow unbounded
rg "new Map|new Set" --type ts src/store/

# requestAnimationFrame without cancel tracking
rg "requestAnimationFrame" --type ts src/ -B2 -A2
```

### Questions to ask during review

- Does `useDoubleTap` need a cleanup effect for `timeoutRef`?
- When does `transportSyncEngine.destroy()` get called?
- What bounds the size of `toggleStates` Map in toolbarSlice?
- Is `pendingResponses` Map in WebSocketConnection cleared on close?

---

## 2. React 19 Concurrent Rendering (Critical)

React 19's concurrent defaults create **tearing risk** for 30Hz meter updates. Tearing = different components showing inconsistent values from same update.

### REAmo's approach (mostly correct)

```typescript
// GOOD: Zustand's useSyncExternalStore prevents tearing
// useReaperStore uses this internally

// GOOD: 60fps animations bypass React state entirely
// TransportAnimationEngine.ts uses refs + RAF
useTransportAnimation((state) => {
  if (elementRef.current) {
    elementRef.current.style.left = `${state.position * 10}px`;
  }
});

// GOOD: Meter updates check for actual changes
updateMeters: (meters) => {
  // Only updates if peak/clipped changed
  if (updatedTracks[idx].lastMeterPeak !== peak ||
      updatedTracks[idx].clipped !== meter.c) {
    // ...update
  }
}
```

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | No `startTransition` wrapping meter/transport updates | Updates become interruptible |
| **Critical** | High-frequency visual updates use refs, not state | 30Hz re-render storm |
| **High** | `useRef` calls have explicit initial value | TypeScript 5.9 strict mode errors |
| **Medium** | Error boundaries use React 19's `onUncaughtError`/`onCaughtError` | Silent failures |

### React 19 breaking changes to verify

```typescript
// useRef now requires argument in TypeScript
// BEFORE (breaks in React 19 + TS 5.9)
const ref = useRef<HTMLDivElement>();

// AFTER
const ref = useRef<HTMLDivElement>(null);
```

```bash
# Find useRef without initial value
rg "useRef<[^>]+>\(\)" --type tsx src/

# Find forwardRef usage (deprecated in React 19)
rg "forwardRef" --type tsx src/

# Find string refs (removed in React 19)
rg 'ref="' --type tsx src/
```

---

## 3. Zustand 5 Selector Stability (Critical)

**The most dangerous Zustand 5 gotcha:** selectors returning new references cause infinite re-render loops. This is a breaking change from v4.

### REAmo selector audit

```typescript
// DANGEROUS: Array/object returns create new reference each time
// Check if any components do this:
const [value, setValue] = useStore((state) => [state.value, state.setValue]);
// ^^^ INFINITE LOOP in Zustand 5

// GOOD: Atomic primitive selectors (most of REAmo does this)
const playState = useReaperStore((s) => s.playState);
const connected = useReaperStore((state) => state.connected);

// NEEDS AUDIT: Defensive selector with fallback object
const tracks = useReaperStore((state) => state?.tracks ?? {});
// ^^^ Creates new {} on every render if state is undefined
```

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | No array destructuring in selectors without `useShallow` | Infinite re-render loop |
| **Critical** | Fallback objects (`?? {}`) use stable reference | New object each render |
| **High** | Map objects updated via new Map(), not mutation | Silent non-reactivity |
| **High** | Actions use `get()` for fresh state, not closure capture | Stale state bugs |

### Grep patterns

```bash
# Selectors returning arrays (need useShallow)
rg "useReaperStore\(.*=>\s*\[" --type tsx src/

# Selectors with fallback objects (potential instability)
rg "useReaperStore.*\?\?" --type tsx src/

# Map.set without creating new Map (won't trigger re-render)
rg "\.set\(" src/store/slices/ --type ts

# Actions capturing state in closures instead of using get()
rg "set\(\(state\)" src/store/slices/ --type ts -A5
```

### Stale closure prevention pattern

```typescript
// ANTI-PATTERN: Closure captures stale state
const someAction = (newValue) => {
  set((state) => {
    // After await, state may be stale
    await someAsyncOp();
    return { ...state, value: newValue }; // state is from before await
  });
};

// GOOD: Use get() for fresh state after async
const someAction = async (newValue) => {
  await someAsyncOp();
  const currentState = get();
  set({ ...currentState, value: newValue });
};
```

---

## 4. WebSocket Lifecycle (Critical)

iOS Safari terminates WebSocket connections **within 5 seconds** of backgrounding. REAmo has extensive workarounds - verify they're all active.

### Current workarounds in WebSocketConnection.ts

```typescript
// 1. EXTSTATE fetch timeout (2s) - prevents PWA cold start hang
const timeout = setTimeout(() => controller.abort(), 2000);

// 2. iOS Safari iframe warmup for NSURLSession lazy init
private async warmupViaIframe(wsUrl: string): Promise<void>

// 3. Focus cycle trick for PWA cold start
window.blur(); await delay(50); window.focus(); await delay(50);

// 4. CONNECTING state timeout (5s) for frozen sockets
const CONNECT_TIMEOUT_MS = 5000;

// 5. ALWAYS force reconnect on visibility return
handleVisibilityChange(isVisible: boolean): void {
  if (isVisible) {
    this.forceReconnect(); // Never trust existing connection
  }
}

// 6. Heartbeat ping/pong (10s interval, 3s timeout)
const HEARTBEAT_INTERVAL_MS = 10000;
const HEARTBEAT_TIMEOUT_MS = 3000;
```

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | `forceReconnect()` nulls event handlers BEFORE calling `.close()` | Frozen socket ignores close() |
| **Critical** | Heartbeat timeout triggers reconnect, not just log | Zombie connections persist |
| **Critical** | `pendingResponses` cleared or timed out on disconnect | Memory leak + stale promises |
| **High** | Clock sync invalidated and restarted on reconnect | Stale time offset |
| **High** | Subscriptions re-sent after reconnect | Missing data |

### Verified patterns

```typescript
// GOOD: Handlers nulled before close (WebSocketConnection.ts:312-318)
if (this.ws) {
  this.ws.onopen = null;
  this.ws.onclose = null;
  this.ws.onerror = null;
  this.ws.onmessage = null;
  try { this.ws.close(); } catch { /* frozen socket */ }
  this.ws = null;
}

// GOOD: Clock sync reset on reconnect (useReaperConnection.ts:151)
transportSyncEngine.resync();

// NEEDS AUDIT: pendingResponses handling on disconnect
// WebSocketConnection.ts - Map exists, but is it cleared?
private pendingResponses = new Map<string, (response: unknown) => void>();
```

### Questions to ask during review

- What happens to pending `sendAsync()` promises when connection closes?
- Does `sendAsync` timeout (5s) race against disconnect properly?
- Is there a connection state machine diagram anywhere?
- What if `warmupViaIframe` hangs - is there a fallback?

---

## 5. Touch Gesture Correctness (High)

iOS Safari has specific quirks that can break gestures or cause unwanted behaviors.

### Current patterns

```typescript
// useLongPress.ts - blocks synthesized mouse events
if (!isTouch && isTouchRef.current) return; // Block synthesized mouse events
// ...
setTimeout(() => { isTouchRef.current = false; }, 300); // Reset after delay

// usePlayheadDrag.ts - uses pointer capture
(e.target as HTMLElement).setPointerCapture(e.pointerId);
// ...
(e.target as HTMLElement).releasePointerCapture(e.pointerId);
```

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | `touch-action: none` on all draggable elements | Browser hijacks gesture |
| **Critical** | `-webkit-touch-callout: none` on interactive elements | iOS shows context menu |
| **High** | `preventDefault()` only on touchstart, not touchmove | Blocks scrolling globally |
| **High** | Pointer capture released in ALL exit paths (up, cancel, leave) | Stuck capture |
| **Medium** | 44x44px minimum touch targets | Accessibility + usability |

### Grep patterns

```bash
# Find draggable elements - verify touch-action
rg "onPointerDown|onTouchStart|useDrag" --type tsx src/

# Find elements without touch-action
rg "touch-action" --type css --type tsx src/

# Find elements missing -webkit-touch-callout
rg "webkit-touch-callout" src/

# Touch targets - look for small dimensions
rg "w-\d|h-\d|width:|height:" --type tsx src/components/
```

### iOS Safari swipe-back limitation

```typescript
// CANNOT disable swipe-to-go-back gesture in iOS Safari PWA
// Design must account for accidental navigation
// Consider: Add confirmation for destructive actions near left edge
```

---

## 6. PWA Safe Areas (High)

iOS safe areas (notch, home indicator, Dynamic Island) require specific handling that can fail silently.

### Current implementation (index.css)

```css
/* GOOD: WebKit timing bug fallback */
@media (display-mode: standalone) {
  .safe-area-bottom {
    /* 34px fallback for WebKit bug where env() returns 0 initially */
    padding-bottom: calc(0.5rem + env(safe-area-inset-bottom, 34px)) !important;
  }
}

/* GOOD: Dynamic viewport height */
.h-screen-safe {
  height: 100vh; /* Fallback */
  height: 100dvh; /* Safari URL bar aware */
}
```

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | `viewport-fit=cover` in meta tag | Safe areas not reported |
| **High** | Fallback values for `env()` (34px bottom, 47px top) | Content hidden on iPhone |
| **High** | Fixed bottom elements use `safe-area-bottom` class | Covered by home indicator |
| **Medium** | Landscape mode tested with safe-area-left/right | Notch/Dynamic Island occlusion |

### Verification

```bash
# Check viewport meta tag
rg "viewport-fit" src/ public/ *.html

# Check safe area CSS usage
rg "safe-area-inset" src/

# Check for fixed bottom elements
rg "fixed.*bottom|bottom.*fixed" --type tsx src/
```

---

## 7. Error Handling (High)

Silent failures in a DAW controller mean lost recordings or missed cues.

### Current state (needs improvement)

```typescript
// NO ErrorBoundary components found in codebase
// React 19 error handling not configured

// Console errors only:
} catch (e) {
  console.error('Failed to save toolbar config:', e);
}
```

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | ErrorBoundary at view level (recover per-view) | Full app crash on component error |
| **High** | React 19 `onUncaughtError`/`onCaughtError` configured | Silent failures |
| **High** | WebSocket errors surface to user (connection indicator) | User doesn't know connection died |
| **Medium** | localStorage errors don't break app (quota exceeded on iOS) | Settings loss |

### Recommended pattern

```typescript
// React 19 error configuration in main.tsx
createRoot(document.getElementById('root')!, {
  onUncaughtError: (error, errorInfo) => {
    // Log to service, show toast
    console.error('Uncaught:', error, errorInfo);
  },
  onCaughtError: (error, errorInfo) => {
    // Caught by ErrorBoundary - log for debugging
    console.warn('Caught:', error, errorInfo);
  }
}).render(<App />);
```

---

## 8. Performance (High)

30Hz updates must process within 33ms budget. 60fps animations need compositor-only properties.

### Current optimizations (good)

```typescript
// Meter updates check for changes before set()
if (updatedTracks[idx].lastMeterPeak !== peak || ...) {
  hasChanges = true;
}
if (hasChanges) {
  set({ tracks: updatedTracks });
}

// Transport animation bypasses React
useTransportAnimation((state) => {
  elementRef.current.style.left = `${state.position}px`;
});

// Subscription debouncing (200ms)
debounceTimerRef.current = setTimeout(() => {
  sendSubscription();
}, debounceMs);
```

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **Critical** | No `width`/`height`/`top`/`left` animations (layout thrashing) | 60fps impossible |
| **High** | Meter visuals use `transform` or CSS variables | Re-render per update |
| **High** | IconPicker limits rendered items (currently 100) | 1900 icons = freeze |
| **Medium** | Virtual list overscan appropriate (currently 5) | Scroll jank |

### Grep patterns

```bash
# Animations that cause layout
rg "animate.*width|animate.*height|animate.*top|animate.*left" --type tsx --type css src/

# Style mutations that should use transform
rg "\.style\.(width|height|top|left)" --type ts --type tsx src/

# Large arrays being rendered
rg "\.map\(" --type tsx src/components/ -B2 | rg -v "slice|filter"
```

---

## 9. Bundle Size (Medium)

Single-file output means no code splitting. Every byte loads on first paint.

### Current concerns

```typescript
// IconPicker imports entire lucide-react icon set
import { icons } from 'lucide-react';
const iconNames = Object.keys(icons); // ~1900 icons in bundle

// vs. tree-shakeable individual imports elsewhere
import { Play, Pause, Square } from 'lucide-react';
```

### Checklist items

| Severity | Item | Risk |
|----------|------|------|
| **High** | `icons` object import replaced with metadata file | ~200KB unnecessary icons |
| **Medium** | Source maps disabled in production | Bundle includes debug info |
| **Medium** | Unused dependencies removed | Dead weight |

### Analysis commands

```bash
# Build and check size
cd frontend && npm run build && ls -lh dist/index.html

# Analyze bundle composition (if vite-bundle-visualizer installed)
npx vite-bundle-visualizer

# Check lucide-react usage
rg "from 'lucide-react'" --type ts --type tsx src/ | sort | uniq -c
```

---

## 10. Testing Gaps (Medium)

### Hard-to-test areas in this architecture

| Area | Challenge | Mitigation |
|------|-----------|------------|
| WebSocket reconnection | Multi-step state machine | Mock at 5-second intervals, verify state transitions |
| 30Hz meter updates | Timing-dependent | Mock WebSocket, verify update count matches send count |
| iOS Safari workarounds | Platform-specific | BrowserStack/LambdaTest on real devices |
| Touch gestures | Synthetic events differ | Playwright touch simulation + real device testing |
| Memory accumulation | Time-dependent | Heap snapshots at 0, 30, 60 minutes |

### Current test infrastructure

```typescript
// test/setup.ts - resets store between tests
beforeEach(() => {
  useReaperStore.setState({
    pendingChanges: {},
    selectedRegionIds: [],
    // ...
  });
});

// _testMode flag skips WebSocket processing
if (get()._testMode) return;
```

### Missing tests to add

```bash
# Files without test coverage (compare with src/)
ls src/**/*.ts src/**/*.tsx | while read f; do
  test_file="${f%.ts*}.test.${f##*.}"
  [ ! -f "$test_file" ] && echo "Missing: $test_file"
done
```

---

## Quick Audit Commands

Run these to find issues fast:

```bash
# 1. Memory leak candidates
rg "setTimeout|setInterval" --type ts --type tsx src/ | rg -v "clear"

# 2. Zustand selector issues
rg "useReaperStore\(.*=>\s*\[" --type tsx src/

# 3. Missing touch-action
rg "onPointerDown|onTouchStart" --type tsx src/ -l | xargs rg -L "touch-action"

# 4. Unsafe type assertions
rg " as any| as unknown" --type ts --type tsx src/

# 5. Console.log in production
rg "console\.(log|debug)" --type ts --type tsx src/ | rg -v "error|warn"

# 6. useEffect without cleanup
rg "useEffect\(\(\) =>" --type tsx src/ -A10 | rg -B10 "^\s*\}\s*\);" | rg -v "return"
```

---

## Pre-Release Checklist

### Before every release

- [ ] `npm run build` succeeds with no TypeScript errors
- [ ] Bundle size hasn't grown unexpectedly (track over time)
- [ ] Test on real iOS Safari (not just simulator)
- [ ] Test background/foreground cycle 5 times
- [ ] Run for 30+ minutes monitoring memory in Safari Web Inspector
- [ ] Verify WebSocket reconnects within 1 second of foreground

### iOS Safari specific

- [ ] Test in Low Power Mode (30fps throttle)
- [ ] Test PWA from cold start (not in recents)
- [ ] Verify safe areas render correctly in portrait AND landscape
- [ ] Check swipe-back doesn't cause data loss

### Performance targets

- [ ] 30Hz updates: <33ms processing time
- [ ] 60fps animations: only transform/opacity animated
- [ ] Memory: <10% growth per hour
- [ ] Reconnection: <100ms after foreground
- [ ] Input latency: <50ms touch-to-visual

---

## File Reference

Key files for each concern:

| Concern | Primary Files |
|---------|---------------|
| Memory | `src/hooks/useLongPress.ts`, `src/hooks/useDoubleTap.ts`, `src/core/TransportSyncEngine.ts` |
| Zustand | `src/store/index.ts`, `src/store/slices/*.ts` |
| WebSocket | `src/core/WebSocketConnection.ts`, `src/hooks/useReaperConnection.ts` |
| Touch | `src/hooks/useLongPress.ts`, `src/components/Timeline/hooks/usePlayheadDrag.ts` |
| Safe Areas | `src/index.css`, `index.html` |
| Performance | `src/store/slices/tracksSlice.ts`, `src/hooks/useTransportAnimation.ts` |
| Icons | `src/components/Toolbar/IconPicker.tsx` |
