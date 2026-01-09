# REAmo Frontend Development Guide

Best practices, patterns, and conventions for the REAmo React frontend.

**Quick Reference:**
- Build: `make frontend` (auto-reloads on iPad)
- Test: `npm run test` / `npm run test:e2e`
- Bundle target: ≤1,050 kB

---

## Table of Contents

1. [Design System (Design Tokens)](#1-design-system-design-tokens)
2. [Code Organization](#2-code-organization)
3. [Reusable Utilities](#3-reusable-utilities-check-before-creating)
4. [Memory Safety](#4-memory-safety-critical-for-hour-long-sessions)
5. [React 19 Patterns](#5-react-19-patterns)
6. [Zustand 5 Patterns](#6-zustand-5-patterns)
7. [WebSocket & Connection](#7-websocket--connection)
8. [Touch & Gesture Handling](#8-touch--gesture-handling)
9. [PWA & iOS Safari](#9-pwa--ios-safari)
10. [Accessibility](#10-accessibility)
11. [Performance](#11-performance)
12. [Bundle Size](#12-bundle-size)
13. [Error Handling](#13-error-handling)
14. [Testing](#14-testing)
15. [Anti-Patterns Checklist](#15-anti-patterns-checklist)
16. [Deferred/Future Work](#16-deferredfuture-work)

---

## 1. Design System (Design Tokens)

### Token Architecture

All colors are defined in `src/index.css` using Tailwind v4's `@theme` block:

```css
@theme {
  --color-bg-surface: #1f2937;
  --color-text-muted: #6b7280;
  --color-primary: #2563eb;
}
```

Use via Tailwind utilities: `bg-bg-surface`, `text-text-muted`, `bg-primary`

### Token Categories (129 total)

| Category | Count | Examples |
|----------|-------|----------|
| **Core UI** | 17 | `bg-app`, `bg-deep`, `bg-surface`, `bg-elevated`, `bg-hover`, `bg-disabled`, `text-primary`/`secondary`/`tertiary`/`muted`/`disabled`, `border-default`/`subtle`/`muted`, `primary`/`hover`/`active` |
| **REAPER-Specific** | 10 | `playhead`, `marker-default`, `region-default`, `item-default`, `success`, `warning`, `error` |
| **Region/Purple** | 6 | `accent-region`, `accent-region-hover`, `accent-region-dark`, `region-nav` variants |
| **Recording** | 23 | `record` states, `scrap`/`retake`/`keep` variants with bg/hover/border/text each |
| **Network** | 6 | `network-optimal`, `network-good`, `network-moderate`, `network-poor`, `network-degraded`, `network-reconnecting` |
| **Timeline Editing** | 17 | `selection-preview`, `delta-positive`/`negative`, `count-in`, `sync` |
| **Track Controls** | 15 | `meter-clip`/`hot`/`good`/`low`, `fader-fill`, `solo`, `monitor-auto`, `toggle-yellow` |
| **Warnings/Errors** | 18 | `memory-warning`, `external-change`, `error-display`, `counter-warning` |
| **Interactive** | 17 | `focus-ring`, `row-selected`, `delete`, `drag-target-ring`, `pending` |

### On-Color Text Tokens

For text on colored backgrounds (buttons), use `text-on-*` tokens:

```tsx
// Text on primary button - stays light regardless of theme
<button className="bg-primary text-on-primary">Save</button>

// Available: text-on-primary, text-on-success, text-on-error, text-on-accent
```

### DO NOT

- Use hardcoded hex colors (except in color picker inputs that need `#rrggbb`)
- Use Tailwind color classes like `bg-gray-700`, `text-blue-500`
- Forget fallback for user-defined REAPER colors (use `reaperColorToHex()`)

---

## 2. Code Organization

### File Structure

```
frontend/src/
├── components/      # React components by feature
│   ├── Actions/     # Has index.ts barrel export
│   ├── Track/
│   ├── Transport/
│   └── ...
├── hooks/           # Custom hooks (barrel export)
├── store/           # Zustand store + slices/
├── core/            # WebSocket, types, commands
├── utils/           # Shared utilities (barrel export)
├── constants/       # Shared constants
└── views/           # Top-level view components
```

### Barrel Exports (index.ts)

Every feature folder should have an `index.ts`:

```typescript
// components/Actions/index.ts
export { ActionButton, type ActionButtonProps } from './ActionButton';
export { MetronomeButton } from './MetronomeButton';
export { UndoButton, RedoButton } from './UndoRedoButtons';
```

- Export components AND their prop types
- Group related exports with comments
- Single import point: `import { ActionButton } from '../components/Actions'`

### File Size Guidelines

| Lines | Status |
|-------|--------|
| ≤200 | Target |
| 400-500 | Review threshold |
| 600+ | Refactor signal - split into focused files |

### Feature-Based > Layer-Based

Prefer colocating related code:

```
features/transport/
  ├── components/
  ├── hooks/
  └── index.ts
```

Over scattering across `components/`, `hooks/`, etc.

---

## 3. Reusable Utilities (Check Before Creating)

**ALWAYS check these exist before writing new code:**

| Utility | Location | Purpose |
|---------|----------|---------|
| `reaperColorToHex()` | `utils/color.ts` | REAPER 0xaarrggbb → CSS hex |
| `getContrastColor()` | `utils/color.ts` | Black/white text for contrast |
| `volumeToDb()` / `dbToVolume()` | `utils/volume.ts` | Linear ↔ dB conversion |
| `faderToVolume()` | `utils/volume.ts` | Fader position ↔ linear |
| `EMPTY_TRACKS` etc. | `store/stableRefs.ts` | Stable empty references |
| `DynamicIcon` | `components/Toolbar/DynamicIcon.tsx` | Render icon by name |
| `LazyIconPicker` | `components/Toolbar/LazyIconPicker.tsx` | Deferred icon picker |
| `useListReorder` | `hooks/useListReorder.ts` | Drag-and-drop reordering |
| `useLongPress` | `hooks/useLongPress.ts` | Tap vs long-press |
| `useDoubleTap` | `hooks/useDoubleTap.ts` | Double-tap detection |
| `MARKER_COLORS` | `constants/colors.ts` | Preset marker palette |
| `ITEM_COLORS` | `constants/colors.ts` | Preset item palette |

---

## 4. Memory Safety (Critical for Hour-Long Sessions)

### Timer Cleanup Pattern

Every hook with `setTimeout`/`setInterval` **MUST** have cleanup:

```typescript
const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

// In handler:
timerRef.current = setTimeout(() => { ... }, 400);

// Cleanup effect:
useEffect(() => {
  return () => {
    if (timerRef.current) clearTimeout(timerRef.current);
  };
}, []);
```

### Components with this pattern (reference):

- `useLongPress`, `useDoubleTap`, `useMarkerDrag`
- `TransportBar`, `PersistentTransport`, `TapTempoButton`
- `ActionButton`, `RegionInfoBar`, `MarkerInfoBar`
- `ColorPickerInput`, `TransportControls` (clock)

### Event Listener Cleanup

```typescript
useEffect(() => {
  const handler = () => { ... };
  window.addEventListener('resize', handler);
  return () => window.removeEventListener('resize', handler);
}, []);
```

### RAF Cleanup

```typescript
const rafRef = useRef<number | null>(null);

useEffect(() => {
  const tick = () => {
    // ... work
    rafRef.current = requestAnimationFrame(tick);
  };
  rafRef.current = requestAnimationFrame(tick);

  return () => {
    if (rafRef.current) cancelAnimationFrame(rafRef.current);
  };
}, []);
```

### Map/Set Bounds

- `toggleStates`, `guidToIndex` Maps are bounded by project size (OK)
- `PeaksCache` has LRU eviction (max 100 entries)
- `pendingResponses` Map cleared on WebSocket disconnect

---

## 5. React 19 Patterns

### useSyncExternalStore (via Zustand)

Zustand uses this internally - prevents tearing for 30Hz updates. **Never wrap meter/transport updates in `startTransition`**.

### useRef Requires Initial Value

```typescript
// Required in React 19 + TypeScript 5.9:
const ref = useRef<HTMLDivElement>(null);  // NOT useRef<HTMLDivElement>()
```

### Error Handling

```typescript
// In main.tsx:
createRoot(document.getElementById('root')!, {
  onUncaughtError: (error, errorInfo) => { console.error('Uncaught:', error); },
  onCaughtError: (error, errorInfo) => { console.warn('Caught:', error); },
}).render(<App />);
```

### forwardRef is Deprecated

Use ref as a regular prop instead.

---

## 6. Zustand 5 Patterns

### Selector Stability (CRITICAL)

```typescript
// CAUSES INFINITE LOOP:
const [value, setValue] = useStore((state) => [state.value, state.setValue]);

// FIX with useShallow:
import { useShallow } from 'zustand/react/shallow';
const [value, setValue] = useStore(useShallow((state) => [state.value, state.setValue]));

// BETTER - atomic selectors:
const value = useStore(state => state.value);
const setValue = useStore(state => state.setValue);
```

### Fallback Object Stability

```typescript
// BAD - new object each render:
const tracks = useReaperStore((state) => state?.tracks ?? {});

// GOOD - stable reference:
import { EMPTY_TRACKS } from '../store/stableRefs';
const tracks = useReaperStore((state) => state?.tracks ?? EMPTY_TRACKS);
```

### Stale Closure Prevention

```typescript
// BAD - closure captures stale state:
const someAction = async (newValue) => {
  await someAsyncOp();
  set((state) => ({ ...state, value: newValue })); // state is stale!
};

// GOOD - use get() for fresh state:
const someAction = async (newValue) => {
  await someAsyncOp();
  const currentState = get();
  set({ ...currentState, value: newValue });
};
```

### Map Mutations

```typescript
// BAD - mutates existing Map (no re-render):
state.toggleStates.set(key, value);

// GOOD - create new Map:
const newMap = new Map(state.toggleStates);
newMap.set(key, value);
set({ toggleStates: newMap });
```

---

## 7. WebSocket & Connection

### Use Context, Not Hook Directly

```typescript
// CORRECT - shared connection:
import { useReaper } from '../components/ReaperProvider';
const { sendCommand, sendCommandAsync } = useReaper();

// WRONG - creates duplicate connection:
import { useReaperConnection } from '../hooks/useReaperConnection';
```

### iOS Safari Considerations

- WebSocket dies within 5 seconds of backgrounding
- `onclose` may not fire (zombie connections)
- Force reconnect on visibility change
- Heartbeat ping/pong every 10s

### pendingResponses Cleanup

Cleared on disconnect via `clearPendingResponses()`, called from `stop()` and `forceReconnect()`.

---

## 8. Touch & Gesture Handling

### Required CSS

```css
/* On all draggable elements: */
.draggable {
  touch-action: none;           /* Prevent browser gesture hijacking */
  -webkit-touch-callout: none;  /* Prevent iOS context menu */
  user-select: none;            /* Prevent text selection */
}
```

Or use Tailwind: `touch-none select-none`

### Touch Target Size

- Minimum **44×44px** (WCAG 2.5.5)
- Exception: color swatches at 24×24 (rarely used during performance)

### Pointer Capture Safety

```typescript
const handlePointerUp = (e: React.PointerEvent) => {
  try {
    (e.target as HTMLElement).releasePointerCapture(e.pointerId);
  } catch {
    // pointercancel may have already released
  }
};
```

### Synthesized Event Blocking

Touch devices fire touch events then synthesized mouse events:

```typescript
const isTouchRef = useRef(false);

const handleMouseDown = () => {
  if (isTouchRef.current) return;  // Block synthesized
  // ... handle
};

const handleTouchEnd = () => {
  // ... handle
  setTimeout(() => { isTouchRef.current = false; }, 300);
};
```

---

## 9. PWA & iOS Safari

### Viewport

```html
<meta name="viewport" content="initial-scale=1, viewport-fit=cover, width=device-width">
```

### Safe Areas

```css
/* Bottom safe area (home indicator): */
.safe-area-bottom {
  padding-bottom: calc(5px + env(safe-area-inset-bottom, 0px)) !important;
}

/* PWA standalone mode (WebKit timing bug - env() returns 0 initially): */
@media (display-mode: standalone) {
  .safe-area-bottom {
    padding-bottom: calc(0.5rem + env(safe-area-inset-bottom, 34px)) !important;
  }
}

/* Dynamic viewport height (Safari URL bar): */
.h-screen-safe {
  height: 100vh;   /* Fallback */
  height: 100dvh;  /* Dynamic */
}
```

### localStorage Error Handling

```typescript
// Always wrap - fails in private browsing:
try {
  localStorage.setItem(key, value);
} catch (e) {
  console.warn('localStorage failed:', e);
}
```

### Service Worker Cache Limit

- iOS Safari: **50MB hard limit**
- Total origin storage: ~20% of disk (60% if added to home screen)

---

## 10. Accessibility

### ARIA Live Regions

```tsx
// For status updates (connection, transport state):
<div role="status" aria-live="polite">
  {statusMessage}
</div>
```

### Button Accessibility

```tsx
<button
  aria-label="Play"
  aria-pressed={isPlaying}
>
  <PlayIcon />
</button>
```

### Reduced Motion

```css
@media (prefers-reduced-motion: reduce) {
  * {
    animation-duration: 0.01ms !important;
    transition-duration: 0.01ms !important;
  }
}
```

---

## 11. Performance

### 30Hz Budget: 33ms per update

- Meter updates check for changes before `set()`
- Only update if peak/clipped actually changed

### 60fps Animations

- Use `transform` and `opacity` only (compositor thread)
- **Never** animate `width`, `height`, `top`, `left` (triggers layout)
- Bypass React state - use refs + direct DOM mutation

### Animation Bypass Pattern

```typescript
const elementRef = useRef<HTMLDivElement>(null);

useTransportAnimation((state) => {
  if (elementRef.current) {
    elementRef.current.style.left = `${state.position * scale}px`;
  }
}, [scale]);

return <div ref={elementRef} />;
```

### Virtual Scrolling

- Mixer uses `useVirtualizedSubscription`
- Only renders visible tracks
- Critical for 100+ track projects

### Icon Optimization

- Use `LazyIconPicker` (defers ~1900 icons)
- Individual icon imports elsewhere tree-shake correctly

---

## 12. Bundle Size

### Target: ≤1,050 kB (single-file output)

**Current**: ~652 kB (gzip: ~181 kB)

### Monitoring

```bash
# Quick check
cd frontend && npm run build && ls -lh dist/index.html

# Visual bundle analyzer (opens browser)
npm run analyze
```

### Curated Icon System (305 icons)

Icons are curated in `src/icons/commonIcons.ts` instead of importing all 1,663 from lucide-react. This saves ~400 kB.

**Files:**
- `src/icons/commonIcons.ts` - 305 curated DAW-relevant icons
- `src/icons/iconSearchIndex.ts` - Semantic search (e.g., "record" → Circle, Mic, Disc)
- `scripts/analyze-icons.ts` - Maintenance script to regenerate (requires REAPER running)

**To add new icons:**
1. Add to `ADDITIONAL_DAW_ICONS` array in `scripts/analyze-icons.ts`
2. Add synonyms to `SYNONYMS` object if semantic search needed
3. Run `npx tsx scripts/analyze-icons.ts` (needs REAPER + REAmo extension)
4. Rebuild frontend

### Other Optimizations

- `LazyIconPicker` via `React.lazy()`
- `console.log`/`debugger` stripped in production (Vite esbuild)
- No code splitting (vite-plugin-singlefile bundles everything into one HTML)

### Import Patterns

```typescript
// GOOD - uses curated set:
import { Play, Pause } from 'lucide-react';
import { commonIcons } from '../icons/commonIcons';

// BAD - includes all 1663 icons:
import { icons } from 'lucide-react';
```

---

## 13. Error Handling

### ErrorBoundary

Wraps `ViewComponent` in `App.tsx`. Catches component-level errors and shows recovery UI.

```tsx
<ErrorBoundary>
  <ViewComponent />
</ErrorBoundary>
```

### localStorage Fallbacks

- Always provide default values
- Never crash on parse failure

---

## 14. Testing

### Store Reset Between Tests

```typescript
beforeEach(() => {
  useReaperStore.setState({
    pendingChanges: {},
    selectedRegionIds: [],
    // ... initial state
  });
});
```

### Test Mode for E2E

```typescript
// Prevents WebSocket from overwriting fixtures:
store.getState()._setTestMode(true);
store.setState({ connected: true, tracks: mockTracks });
```

### Timer Testing

```typescript
vi.useFakeTimers();
// ... trigger action
vi.advanceTimersByTime(400);  // Long-press duration
// ... assert
vi.useRealTimers();
```

---

## 15. Anti-Patterns Checklist

| Don't | Do Instead |
|-------|------------|
| `useRef<T>()` | `useRef<T>(null)` |
| `state?.tracks ?? {}` | `state?.tracks ?? EMPTY_TRACKS` |
| `useReaperConnection()` in components | `useReaper()` from context |
| Hardcoded colors `#374151` | Design tokens `bg-bg-elevated` |
| `100vh` for height | `100dvh` or `.h-screen-safe` |
| Unguarded `localStorage` | try-catch wrapper |
| Timer without cleanup effect | Add `useEffect` return |
| `touch-action: manipulation` | `touch-action: none` |
| Animate `width`/`height`/`top`/`left` | Animate `transform`/`opacity` |
| `import { icons }` from lucide | Import individual icons |
| Mutate Zustand Map in place | Create new Map, then set |
| Select array/object without useShallow | Atomic primitives or useShallow |

---

## 16. Deferred/Future Work

Items intentionally not addressed yet:

| Item | Reason |
|------|--------|
| Canvas-based Timeline | Major refactor for compositor-only rendering |
| Service worker | Offline caching not critical for local REAPER |
| Test coverage expansion | Current coverage adequate |
| 24×24 color swatches | Rarely used during performance |
| Frame rate monitoring | No Battery API on iOS |

---

## Related Documentation

| Document | Purpose |
|----------|---------|
| `research/FRONTEND_AUDIT_PROGRESS.md` | Audit completion tracking |
| `research/FRONTEND_PRODUCTION_REVIEW_CHECKLIST.md` | Original checklist with grep patterns |
| `research/css-var-refactor.md` | Design token system reference |
| `DEVELOPMENT.md` | Full-stack development guide (extension + frontend) |
