# Production readiness for real-time React 19 DAW controller on iOS Safari

Building a high-performance DAW controller as an iOS Safari PWA with **30Hz meter updates**, **60fps animations**, and **hour-long session stability** requires navigating specific gotchas across your entire stack. This comprehensive checklist synthesizes the most critical production patterns for React 19, Zustand 5, WebSocket communication, and iOS Safari PWA deployment based on current documentation, GitHub discussions, and engineering team experiences through 2025.

The core challenge: iOS Safari's aggressive memory management, limited background execution (~5 seconds), and missing APIs (Battery, Vibration, Background Sync) require defensive patterns not needed on other platforms. Combined with React 19's concurrent rendering defaults and Zustand 5's breaking changes around selector stability, your architecture must prioritize consistency over interruptibility.

---

## React 19's concurrent defaults require external store patterns

React 19 enables concurrent rendering by default, introducing **tearing risk** for your 30Hz meter updates. Tearing occurs when React pauses a render cycle and external state changes during the pause, causing different components to display inconsistent values—catastrophic for synchronized audio meters.

**useSyncExternalStore is mandatory** for external data sources. Zustand uses `useSyncExternalStoreWithSelector` internally, which explicitly trades concurrent features for consistency. The "Sync" behavior means React will de-opt from interruptible rendering to prevent tearing—exactly what you want for audio state.

Critical requirements for snapshot functions:
- `getSnapshot` must return **referentially stable values** (React uses `Object.is()` comparison)
- `subscribe` functions must be stable across renders to prevent resubscription overhead
- Never wrap meter updates in `startTransition`—they should be immediate

**Automatic batching affects WebSocket handlers.** React 19 batches all state updates including those in WebSocket `onmessage` handlers. For 30Hz updates, this is generally beneficial, but avoid `flushSync` except when coordinating with external Canvas/WebGL rendering:

```javascript
// For 30Hz meters, bypass React state entirely for visual updates
const meterRef = useRef(null);
const levelRef = useRef(0);

ws.onmessage = (event) => {
  levelRef.current = JSON.parse(event.data).level;
};

useEffect(() => {
  let rafId;
  const updateVisual = () => {
    if (meterRef.current) {
      meterRef.current.style.width = `${levelRef.current}%`;
    }
    rafId = requestAnimationFrame(updateVisual);
  };
  rafId = requestAnimationFrame(updateVisual);
  return () => cancelAnimationFrame(rafId);
}, []);
```

**Breaking changes requiring attention:**
- `useRef` now requires an argument in TypeScript (`useRef<HTMLDivElement>(null)`)
- `forwardRef` is deprecated—use ref as a regular prop
- String refs and `propTypes` on function components are removed
- Error handling changed: use `onUncaughtError` and `onCaughtError` in `createRoot`

---

## Zustand 5 selector stability prevents render storms

The most dangerous Zustand 5 gotcha for high-frequency updates: **selectors returning new references cause infinite re-render loops**. This is a breaking change from v4 where shallow comparison was implicit.

```javascript
// CAUSES INFINITE LOOP in Zustand 5
const [value, setValue] = useStore((state) => [state.value, state.setValue]);

// Fix with useShallow (new import path in v5)
import { useShallow } from 'zustand/react/shallow';
const [value, setValue] = useStore(
  useShallow((state) => [state.value, state.setValue])
);

// Better: atomic selectors for primitives (fastest)
const value = useStore(state => state.value);
const setValue = useStore(state => state.setValue);
```

**For 17+ slices, use module-based slice composition:**

```typescript
// slices/meterSlice.ts
export const createMeterSlice: StateCreator<
  StoreState,
  [["zustand/devtools", never], ["zustand/subscribeWithSelector", never]],
  [],
  MeterSlice
> = (set, get) => ({
  meters: new Float32Array(32),
  updateMeters: (newLevels) => {
    // Only update if changed (prevents unnecessary re-renders)
    if (hasSignificantChange(get().meters, newLevels)) {
      set({ meters: newLevels });
    }
  }
});
```

**Never persist high-frequency state.** The persist middleware's `JSON.stringify` bottleneck caused severe performance issues reported in GitHub discussions. Partition your store:

```javascript
// Persist only infrequent changes
partialize: (state) => ({
  projectSettings: state.projectSettings,
  userPreferences: state.userPreferences,
  // NEVER: playheadPosition, meterLevels, activeNotes
})
```

**Stale closure prevention:** Always use `get()` for fresh state in async actions, never closure-captured state. After `await`, state may have changed during the async operation.

---

## WebSocket patterns for iOS Safari's hostile environment

iOS Safari terminates WebSocket connections **within 5 seconds** of backgrounding. The `onclose` event historically didn't fire reliably (fixed in Safari 17.3), and iOS 26 introduced HTTP/2 handshake issues affecting connections through proxies.

**Mandatory reconnection architecture:**

```javascript
class iOSSafeWebSocket {
  constructor(url) {
    this.lastPongTime = Date.now();
    this.setupLifecycleHandlers();
  }
  
  setupLifecycleHandlers() {
    // iOS terminates connections on background
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') {
        if (Date.now() - this.lastPongTime > 5000) {
          this.forceReconnect();
        }
      }
    });
    
    // bfcache restoration
    window.addEventListener('pageshow', (e) => {
      if (e.persisted) this.forceReconnect();
    });
  }
  
  // Application-level heartbeat (don't rely on protocol-level ping/pong)
  startHeartbeat() {
    this.heartbeatInterval = setInterval(() => {
      if (this.ws.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify({ type: 'ping', ts: Date.now() }));
        if (Date.now() - this.lastPongTime > 10000) {
          this.forceReconnect(); // Zombie connection detection
        }
      }
    }, 5000);
  }
}
```

**Backpressure handling for 30Hz updates:** Monitor `bufferedAmount` to detect when the client can't keep up. For DAW control data, use "latest value wins"—dropping stale control values is acceptable.

```javascript
const HIGH_WATER_MARK = 64 * 1024;
function sendWithBackpressure(data) {
  if (ws.bufferedAmount > HIGH_WATER_MARK) {
    return false; // Drop or defer message
  }
  ws.send(data);
  return true;
}
```

**Battery efficiency:** The Battery API is **not supported on iOS Safari**. Implement a user-controllable "Low Power Mode" toggle, time-based throttling after extended use (reduce to 15Hz after 30 minutes), and frame timing monitoring to detect thermal throttling indirectly.

---

## iOS Safari PWA requires defensive lifecycle handling

**Critical iOS Safari bugs to account for:**
- **iOS 17.0-17.1**: Service worker FetchEvent.respondWith TypeError when Safari is killed and reopened (fixed in 17.2)
- **iOS 17+**: IndexedDB connection loss causing logout loops; store session data redundantly
- **Safari 15-17**: WebSocket `onclose` not firing on network disconnection (fixed in 17.3)
- **Ongoing**: requestAnimationFrame throttled to **30fps** in Low Power Mode (cannot detect programmatically)

**Safe area handling requires specific meta tags:**

```html
<meta name="viewport" content="initial-scale=1, viewport-fit=cover, width=device-width">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
```

```css
html {
  min-height: calc(100% + env(safe-area-inset-top));
  padding: env(safe-area-inset-top) env(safe-area-inset-right) 
           env(safe-area-inset-bottom) env(safe-area-inset-left);
}
```

**Memory limits are strict:** Service Worker cache has a **50MB hard limit**. Total origin storage is ~20% of disk (60% if added to home screen). Under memory pressure, iOS terminates PWA processes without warning—persist critical state to IndexedDB/localStorage on every `visibilitychange` to hidden.

**Timer behavior changes when backgrounded:** Timers are suspended and may fire rapidly on foreground. Use time-delta approaches and skip catch-up if delta exceeds 5 seconds:

```javascript
let lastUpdate = Date.now();
function gameLoop() {
  const now = Date.now();
  const delta = now - lastUpdate;
  lastUpdate = now;
  
  if (delta < 5000) {
    update(delta);
  } else {
    handleResume(); // App was backgrounded
  }
  requestAnimationFrame(gameLoop);
}
```

---

## Code organization scales with feature-based boundaries

**File size guidelines based on industry consensus:**
- **200 lines**: Target for React components; extract utilities to adjacent files
- **400-500 lines**: Review threshold; likely contains multiple responsibilities
- **600+ lines**: Strong refactoring signal requiring immediate attention

**Feature-based structure scales better than layer-based** for complex applications:

```
src/
├── features/
│   ├── transport/
│   │   ├── components/
│   │   ├── hooks/
│   │   ├── stores/
│   │   └── index.ts  # Public API
│   ├── mixer/
│   └── sequencer/
├── components/       # Shared UI only
└── stores/          # Global stores only
```

**Barrel file caution:** One production case reduced bundle size by **400KB** by removing a barrel file. Next.js found barrel files caused ~30 second compilation times with large packages. Use barrel files only at feature boundaries for public APIs, never within features. Always mark packages as side-effect-free in package.json.

**Circular dependency prevention:** Enable `eslint-plugin-import` with `import/no-cycle` from day one. Use `circular-dependency-plugin` with `failOnError: true` in CI.

---

## Tailwind design tokens prevent drift in long-lived projects

**Tailwind v4's @theme directive creates enforceable design tokens:**

```css
@import "tailwindcss";
@theme {
  --color-*: initial; /* Reset defaults */
  --color-primary: oklch(0.72 0.11 221.19);
  --color-surface: oklch(0.129 0.042 264.695);
  --color-fader-track: oklch(0.2 0.05 265);
}
```

Use **eslint-plugin-tailwindcss** with `no-custom-classname` rule to detect arbitrary values outside your config. The `no-contradicting-classname` rule catches conflicting utility classes.

**Touch targets for audio controls:** WCAG 2.5.5 requires minimum **44×44 CSS pixels**. For precision audio controls, use 48-56px for knobs and full-height touch areas for faders. Apple HIG specifies 44pt minimum.

**iOS Safari haptic limitation:** The Vibration API is **not supported**. Use audio feedback (short click sounds) and strong visual feedback (scale, glow, color change) for touch interactions. If you need true haptics, wrap in Capacitor for native bridge access.

**Animation performance:** Only animate `transform` and `opacity` (compositor thread). Avoid animating `width`, `height`, `top`, `left` which trigger layout. For 30Hz meters, use CSS transforms with refs rather than React state to avoid re-render overhead.

---

## Gesture handling requires @use-gesture for unified patterns

```jsx
import { useDrag } from '@use-gesture/react';

function Fader() {
  const bind = useDrag(({ offset: [, y], memo }) => {
    api.start({ y: clamp(y, 0, 200) });
  }, {
    bounds: { top: 0, bottom: 200 },
    rubberband: true,
    filterTaps: true // Distinguish taps from drags
  });
  
  return <animated.div {...bind()} style={{ touchAction: 'none' }} />;
}
```

**Critical:** Set `touch-action: none` on all draggable elements. For vertical-only drag with page scroll, use `touch-action: pan-x`. Add `-webkit-touch-callout: none` to prevent iOS native popups. Note that iOS Safari PWAs cannot disable the swipe-to-go-back gesture—design around it.

**Long-press detection:** Use `@use-gesture`'s `delay` option (500ms typical) and check `elapsedTime` in the drag handler.

---

## Memory profiling for hour-long sessions

**performance.measureUserAgentSpecificMemory()** is the modern replacement for deprecated `performance.memory`, but it's **Chromium-only and requires cross-origin isolation** (COOP+COEP headers). Not supported in Safari.

**For Safari, use indirect detection:**
- Monitor session duration and frame timing degradation
- Track dropped frames via rAF timestamps (>50ms deltas indicate problems)
- Implement automatic complexity reduction when degradation detected

**MemLab from Meta** automates leak detection in CI by taking heap snapshots during navigation (A→B→A pattern) and diffing them to identify retained objects.

**Common leak patterns to audit:**
- Uncleared event listeners, forgotten timers/intervals
- Closures capturing large objects (audio buffers)
- useEffect missing cleanup returns
- Unbounded client-side caches
- Detached DOM nodes from dynamic component mounting

---

## Testing strategies for real-time behavior

**Playwright WebKit for CI testing**, but note it tests the WebKit engine, not actual Safari. For real iOS Safari testing, use **BrowserStack or LambdaTest**, which now support Playwright on real iOS 17/18 devices.

**Touch gesture simulation in Playwright:**

```javascript
async function pan(locator, deltaX, deltaY, steps = 5) {
  const bounds = await locator.boundingBox();
  const centerX = bounds.x + bounds.width / 2;
  const centerY = bounds.y + bounds.height / 2;
  
  const touches = [{ identifier: 0, clientX: centerX, clientY: centerY }];
  await locator.dispatchEvent('touchstart', { touches, changedTouches: touches });
  
  for (let i = 1; i <= steps; i++) {
    const newTouches = [{
      identifier: 0,
      clientX: centerX + (deltaX * i / steps),
      clientY: centerY + (deltaY * i / steps),
    }];
    await locator.dispatchEvent('touchmove', { touches: newTouches });
  }
  await locator.dispatchEvent('touchend');
}
```

**High-frequency update testing:** Mock WebSocket at 30Hz for 3+ second bursts and verify update consistency (average delta < 40ms) and render count stability.

---

## Lightweight observability for PWA constraints

Heavy SDKs hurt PWA performance. Alternatives to Sentry's full SDK:
- **TrackJS** (~10KB): Focused JS error tracking
- **GlitchTip** (self-hosted): Sentry SDK compatible, open source
- **Honeybadger** (~12KB): Developer-focused, simple

**web-vitals library (~2KB)** with sendBeacon provides reliable metrics without blocking:

```javascript
import { onCLS, onINP, onLCP } from 'web-vitals';

function sendMetric({ name, value, delta, id }) {
  navigator.sendBeacon('/api/vitals', JSON.stringify({
    metric: name,
    value: Math.round(value),
  }));
}

onCLS(sendMetric);
onINP(sendMetric);
onLCP(sendMetric);
```

**Logging without performance impact:** Strip `console.log` in production (synchronous, blocks main thread, prevents GC in DevTools). Use async logging with `requestIdleCallback` and sample rates (100% errors, 10% warnings, 1% info).

**Remote debugging iOS Safari PWAs:** Requires macOS with Safari. Enable Web Inspector on iOS device (Settings → Safari → Advanced), connect via USB, access from Safari Develop menu. PWAs added to home screen appear in the device list.

---

## Production readiness checklist

**Before launch:**
- [ ] All useEffect hooks have cleanup functions for subscriptions/timers
- [ ] Zustand selectors use `useShallow` for object/array returns or atomic primitives
- [ ] High-frequency state (meters, playhead) separated from persisted state
- [ ] WebSocket implements visibility-change reconnection and application-level heartbeat
- [ ] Session state persisted on every `visibilitychange` to hidden
- [ ] Safe area CSS applied with `viewport-fit=cover`
- [ ] Touch targets minimum 44×44px for all controls
- [ ] `touch-action: none` on draggable elements
- [ ] Animations use only transform/opacity properties
- [ ] Service worker handles update prompts without disrupting sessions
- [ ] Error tracking configured with offline queue
- [ ] Frame rate monitoring alerts on sustained <50fps

**iOS Safari specific:**
- [ ] Test with Low Power Mode enabled (30fps throttling)
- [ ] Test background/foreground transitions during active sessions  
- [ ] Verify WebSocket reconnection timing after foreground
- [ ] Validate cache stays under 50MB limit
- [ ] Implement user-controllable power saving mode (no Battery API)
- [ ] Design assumes swipe-back gesture cannot be disabled

**Performance targets for DAW controller:**
- 30Hz WebSocket updates processed within 33ms budget
- 60fps animations using compositor-only properties
- Memory growth <10% per hour of session
- Sub-100ms reconnection after foreground return
- Sub-50ms input-to-visual-feedback latency for controls
