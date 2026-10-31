# REAmo Frontend Development Guide

Patterns and conventions for the REAmo React frontend. ESLint messages cite the section numbers (§1a, §4, §5, §6, §7, §11, §14), so keep them stable. Responsive layout rules: [docs/architecture/frontend/UX_GUIDELINES.md](../docs/architecture/frontend/UX_GUIDELINES.md). Toolchain, build and the extension: [DEVELOPMENT.md](../DEVELOPMENT.md).

**Quick Reference:**

- Build: `make frontend`
- Test: `npm run test` / `npm run test:e2e`

---

## Table of Contents

1. [Design System (Design Tokens)](#1-design-system-design-tokens)
1a. [Button System](#1a-button-system)
2. [Code Organization](#2-code-organization)
3. [Reusable Utilities](#3-reusable-utilities-check-before-creating)
4. [Memory Safety](#4-memory-safety-critical-for-hour-long-sessions)
5. [React 19 Patterns](#5-react-19-patterns)
6. [Zustand 5 Patterns](#6-zustand-5-patterns)
7. [WebSocket & Connection](#7-websocket--connection)
8. [Modal System](#8-modal-system)
9. [Touch & Gesture Handling](#9-touch--gesture-handling)
10. [Timeline Coordinate Systems](#10-timeline-coordinate-systems)
11. [PWA & iOS Safari](#11-pwa--ios-safari)
12. [Accessibility](#12-accessibility)
13. [Performance](#13-performance)
14. [Bundle Size](#14-bundle-size)
15. [Error Handling](#15-error-handling)
16. [Testing](#16-testing)
17. [Why the Checklist Says So](#17-why-the-checklist-says-so)
18. [Anti-Patterns Checklist](#18-anti-patterns-checklist)
19. [Layout Budget System](#19-layout-budget-system)
20. [Constants](#20-constants)
21. [Dual-Rail Responsive Layout](#21-dual-rail-responsive-layout-landscape-phones)
22. [ESLint Governance & Pre-commit Hooks](#22-eslint-governance--pre-commit-hooks)

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

### Token Categories

| Category | Examples |
|----------|----------|
| **Core UI** | `bg-app`, `bg-deep`, `bg-surface`, `bg-elevated`, `bg-hover`, `bg-disabled`, `text-primary`/`secondary`/`tertiary`/`muted`/`disabled`, `border-default`/`subtle`/`muted`, `primary`/`hover`/`active` |
| **REAPER-Specific** | `playhead`, `marker-default`, `region-default`, `item-default`, `success`, `warning`, `error` |
| **Region/Purple** | `accent-region`, `accent-region-hover`, `accent-region-dark`, `region-nav` variants |
| **Recording** | `record` states, `scrap`/`retake`/`keep` variants with bg/hover/border/text each |
| **Network** | `network-optimal`, `network-good`, `network-moderate`, `network-poor`, `network-degraded`, `network-reconnecting` |
| **Timeline Editing** | `selection-preview`, `delta-positive`/`negative`, `count-in`, `sync` |
| **Track Controls** | `meter-clip`/`hot`/`good`/`low`, `fader-fill`, `solo`, `monitor-auto`, `toggle-yellow` |
| **Warnings/Errors** | `memory-warning`, `external-change`, `error-display`, `counter-warning` |
| **Interactive** | `focus-ring`, `row-selected`, `delete`, `drag-target-ring`, `pending` |

### On-Color Text Tokens

For text on colored backgrounds (buttons), use `text-on-*` tokens:

```tsx
// Text on primary button - stays light regardless of theme
<button className="bg-primary text-on-primary">Save</button>

// Available: text-on-primary, text-on-success, text-on-error, text-on-accent
```

### Feature-Specific Tokens

| Feature | Tokens | Purpose |
|---------|--------|---------|
| **Sends Mode** | `sends-primary`, `sends-hover`, `sends-bg`, `sends-text`, `sends-mute-*` | Amber/gold faders in mixer sends mode |
| **Routing** | `routing-master`, `routing-sends`, `routing-receives`, `routing-disabled` | Track routing indicator colors |
| **Fader** | `fader-handle`, `fader-fill` | Mixer fader handle and fill colors |
| **Selection** | `selection-overlay-bg`, `selection-overlay-border`, `selection-overlay-text` | Timeline selection overlays |

**When adding a new feature with distinct colors:**

1. Add semantic tokens to `src/index.css` under `@theme`
2. Use descriptive names: `feature-purpose` (e.g., `sends-mute-hover`)
3. Reference via Tailwind: `bg-sends-primary`, `text-routing-master`

### DO NOT

- Use hardcoded hex colors (except in color picker inputs that need `#rrggbb`)
- Use Tailwind color classes like `bg-gray-700`, `text-blue-500`, `bg-amber-500`, `text-white`
- Use generic Tailwind colors for feature-specific styling (use semantic tokens)
- Forget fallback for user-defined REAPER colors (use `reaperColorToHex()`)

```tsx
// BAD - hardcoded amber for sends mode
<button className="bg-amber-500 text-white">Sends</button>
// GOOD - semantic token
<button className="bg-sends-primary text-on-primary">Sends</button>

// BAD - hardcoded white for fader handle
<div style={{ backgroundColor: 'white' }} />
// GOOD - token reference
<div className="bg-fader-handle" />
```

### Spacing Tokens

Semantic spacing tokens use Tailwind 4's `--spacing-*` namespace, which generates utility classes, so visual rhythm can change in one place:

```css
@theme {
  --spacing-modal: 1rem;  /* Generates p-modal, m-modal, gap-modal, etc. */
}
```

| Category | Tokens | Purpose |
|----------|--------|---------|
| **Layout** | `modal`, `modal-footer-x/y`, `sheet-x`, `sheet-bottom`, `view` | Container padding for modals, sheets, views |
| **Components** | `infobar-x/y`, `menu-item-x/y`, `control` | Consistent component padding |
| **Gaps** | `panel-gap`, `section-gap`, `inline-gap`, `tight-gap` | Flex/grid gap standardization |
| **Audio** | `fader-track`, `meter-gap`, `channel-strip`, `transport` | Mixer/timeline-specific spacing |

```tsx
<div className="p-modal space-y-section-gap">Modal content</div>
<div className="px-infobar-x py-infobar-y">Info bar</div>
```

- Tiers: Tailwind primitives (`p-2`) rarely; semantic tokens (`--spacing-modal`) normally; component tokens (`--spacing-fader-track`) when needed.
- Tokenize a value used three or more times across files. Single-use values stay raw Tailwind.
- `@theme` can't nest in `@media`; use responsive variants (`p-modal-compact md:p-modal`).
- CSS is the source of truth; JS reads spacing via `getComputedStyle()`.
- Don't duplicate `constants/layout.ts`: those are layout dimensions, not spacing.

---

## 1a. Button System

### Control Height Tokens

All interactive controls (buttons, inputs, selects) use shared height tokens defined in `src/index.css`:

| Token | Value | Use Case |
|-------|-------|----------|
| `--size-control-sm` | 32px | Compact density mode |
| `--size-control-md` | 40px | Default controls |
| `--size-control-lg` | 44px | Touch-friendly (Apple HIG minimum) |
| `--size-control-xl` | 48px | Large touch targets |
| `--size-touch-target-min` | 44px | Reference for accessibility audits |

**Why shared tokens?** Buttons, inputs, and selects should align visually. Using `--size-control-md` everywhere ensures 40px buttons pair correctly with 40px inputs.

### Button Categories

| Category | Component | Usage |
|----------|-----------|-------|
| **Transport** | `CircularTransportButton` | Play, Stop, Pause, Record, Loop |
| **Track Controls** | `MuteButton`, `SoloButton`, etc. | Mixer strip toggles |
| **Modal Actions** | `ModalFooter` | Cancel/Confirm in dialogs |
| **Toolbar** | `ToolbarButton` | User-configurable action buttons |

### Intent Variants (Semantic Colors)

Use intent tokens for button colors (`bg-intent-primary-bg hover:bg-intent-primary-hover`), not raw color tokens:

- `--color-intent-primary-*` - Primary actions (save, confirm)
- `--color-intent-danger-*` - Destructive actions (delete, cancel recording)
- `--color-intent-success-*` - Positive actions (keep, approve)
- `--color-intent-secondary-*` - Secondary/neutral actions

**Exception:** Domain-specific buttons (Mute=blue, Solo=yellow, Arm=red) use their semantic color tokens directly as they have established DAW meanings.

### Touch Targets

**Minimum:** 44×44px (Apple HIG, WCAG 2.5.5). Known gap: track control buttons are smaller, for density.

**Best practice:** `min-h-11 min-w-11` (44px), or `min-h-(--size-touch-target-min)`, on touchable elements.

### Binary vs Tri-State Toggles

- **Binary** (on/off): `aria-pressed={isActive}`.
- **3+ states:** no `aria-pressed` (MonitorButton cycles Off → On → Auto; `aria-pressed` can't tell On from Auto). Use `aria-label={`Mode: ${state}`}` plus a live region:

```tsx
<span role="status" aria-live="polite" className="sr-only">{stateChangeAnnouncement}</span>
```

### Track Control Button Utilities

Track buttons share styling via `components/Track/trackControlStyles.ts`:

```typescript
import { getInactiveClasses, getLockedClasses, trackControlBaseClasses } from './trackControlStyles';

const inactiveBg = getInactiveClasses(isSelected);  // Selection-aware background
const lockedClasses = getLockedClasses(mixerLocked); // Disabled appearance when locked
```

### Creating New Buttons

1. **Check existing components first** - Don't create a new button if an existing one fits
2. **Use shared styling utilities** - Import from `trackControlStyles.ts` for track buttons
3. **Follow the category pattern** - Transport? Use CircularTransportButton. Track control? Follow MuteButton pattern.
4. **Add accessibility** - `aria-pressed` for binary, `aria-label` + live region for multi-state

### DO NOT

- Create one-off button styles without checking existing patterns
- Use `aria-pressed` for toggles with more than 2 states
- Rely solely on color to indicate state (add icons, labels, or shape differences)
- Create buttons smaller than 32×32px (absolute minimum for any interactive element)

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

Folders are by layer (`components/`, `hooks/`, `store/`, …). Reorganising by feature is undecided; don't start it piecemeal.

### Barrel Exports (index.ts)

Every feature folder should have an `index.ts`:

```typescript
// components/Actions/index.ts
export { MixerLockButton } from './MixerLockButton';
export { UnselectAllTracksButton } from './UnselectAllTracksButton';
```

- Export components AND their prop types
- Group related exports with comments
- Single import point: `import { MixerLockButton } from '../components/Actions'`

### File Size Guidelines

| Lines | Status |
|-------|--------|
| ≤200 | Target |
| 400-500 | Review threshold |
| 600+ | Refactor signal - split into focused files |

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
| `useReducedMotion` | `hooks/useReducedMotion.ts` | Respect prefers-reduced-motion |
| `usePeakHold` | `hooks/usePeakHold.ts` | Meter peak hold with decay |
| `useResponsiveChannelCount` | `hooks/useResponsiveChannelCount.ts` | Screen-width based channel count |
| `useBankNavigation` | `hooks/useBankNavigation.ts` | Bank state with localStorage |
| `usePortalPosition` | `hooks/usePortalPosition.ts` | Position portaled dropdowns relative to trigger |
| `MARKER_COLORS` | `constants/colors.ts` | Preset marker palette |
| `ITEM_COLORS` | `constants/colors.ts` | Preset item palette |

### Timeline Gesture Hooks

Timeline interaction hooks live in `components/Timeline/hooks/`, except `useViewport` and `useMarkerClusters`, which are in `src/hooks/`:

| Hook | Purpose |
|------|---------|
| `useViewport` | Viewport state, zoom levels, coordinate conversion |
| `usePanGesture` | Drag-to-pan with momentum scrolling |
| `usePinchGesture` | Two-finger zoom |
| `usePlayheadDrag` | Playhead seek with snap-to-grid |
| `useMarkerDrag` | Marker repositioning |
| `useEdgeScroll` | Auto-scroll when dragging near edges |
| `useMarkerClusters` | Group nearby markers to prevent overlap |


---

## 4. Memory Safety (Critical for Hour-Long Sessions)

### Timer Cleanup Pattern

Every hook with `setTimeout`/`setInterval` **MUST** have cleanup. Null the ref after clearing, so double-clears and "is a timer running?" checks stay safe:

```typescript
const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

// Cancel helper - prevents double-clear bugs
const cancelTimer = () => {
  if (timerRef.current) {
    clearTimeout(timerRef.current);
    timerRef.current = null;  // Prevent stale reference
  }
};

// Start timer (always cancel first)
const startTimer = () => {
  cancelTimer();
  timerRef.current = setTimeout(() => {
    timerRef.current = null;  // Self-clear on completion
    // ... handler logic
  }, 400);
};

// Cleanup on unmount
useEffect(() => cancelTimer, []);
```

**Why null after clear?**

- Prevents accidental double-clearing
- Makes "is timer active?" checks reliable (`if (timerRef.current)`)
- Prevents stale closures from accessing dead timers

### useState vs useRef for Timers

```typescript
// BAD - useState causes re-renders and stale closure issues
const [pressTimer, setPressTimer] = useState<ReturnType<typeof setTimeout> | null>(null);

// GOOD - useRef doesn't cause re-renders
const pressTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
```


### Event Listener and RAF Cleanup

Return the remover from the effect: `removeEventListener` for listeners, `cancelAnimationFrame(rafRef.current)` for a RAF loop kept in a ref.

### Map/Set Bounds

- `toggleStates`, `guidToIndex` Maps are bounded by project size (OK)
- Peak tiles: `peaksSlice` keeps at most `MAX_TILE_CACHE_SIZE` (500) tiles; `core/TileBitmapCache.ts` keeps 200 rendered bitmaps (LRU, `bitmap.close()` on evict)
- `pendingResponses` (`core/websocketActor.ts`): at most 100 in flight, each with a timeout; all rejected and cleared when the connection is lost, stopped or force-reconnected

---
## 5. React 19 Patterns

### useSyncExternalStore (via Zustand)

Zustand uses this internally - prevents tearing for 30Hz updates. **Never wrap meter/transport updates in `startTransition`**.

### useRef Requires Initial Value

```typescript
// Required by React 19's types:
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
import { useReaper } from '../hooks/useReaper';
const { sendCommand, sendCommandAsync } = useReaper();

// WRONG outside ReaperProvider:
import { useReaperConnection } from '../hooks/useReaperConnection';
```

The connection itself is a module-level XState actor (`core/websocketMachine.ts`, `core/websocketActor.ts`), so there's only ever one socket. `useReaperConnection` also registers the lifecycle effects (visibility, online/offline, action-cache fetch); `ReaperProvider` calls it once, and a second caller would register them twice.

### iOS Safari Considerations

- WebSocket dies within 5 seconds of backgrounding
- `onclose` may not fire (zombie connections)
- Force reconnect on visibility change
- Heartbeat ping/pong every 10s (`HEARTBEAT_INTERVAL`)

### Async Commands (sendCommandAsync)

Use `sendCommandAsync` for operations that need response data:

```typescript
const { sendCommandAsync } = useReaper();

// Example: Convert bar.beat position to time
try {
  const response = await sendCommandAsync(tempoCmd.barsToTime(4, 1, 0));
  const time = (response as { payload?: { time?: number } })?.payload?.time;
  if (time !== undefined) {
    // Use the converted time
  }
} catch (error) {
  // Handle timeout (30s) or disconnection
  console.error('Command failed:', error);
}
```

**Key behaviors:**

- Rejects immediately if not connected
- Times out after 30 seconds (`DEFAULT_REQUEST_TIMEOUT`)
- Response matched via unique message ID
- Pending responses rejected and cleared on connection loss, stop and forced reconnect

**When to use:**

| Scenario | Method |
|----------|--------|
| Fire-and-forget actions | `sendCommand()` |
| Need response data | `sendCommandAsync()` |
| Time-critical (meters, transport) | `sendCommand()` |
| Bar/beat ↔ time conversion | `sendCommandAsync()` |

---

## 8. Modal System

### Architecture

| Component | Purpose |
|-----------|---------|
| `Modal` | Wrapper with Escape, backdrop, focus management |
| `ModalContent` | Content area with consistent padding |
| `ModalFooter` | Action buttons (Cancel/Confirm variants) |
| `modalSlice` | Zustand slice for modals opened from several places |
| `ModalRoot` | Renders the modalSlice modals |

```tsx
import { Modal, ModalContent, ModalFooter } from '../components/Modal';

<Modal isOpen={isOpen} onClose={onClose} title="Edit Item">
  <ModalContent>
    <input ... />
  </ModalContent>
  <ModalFooter onCancel={onClose} onConfirm={handleSave} confirmDisabled={!isValid} />
</Modal>
```

- `Modal` props: `isOpen`, `onClose`, `title`, `children`, `showCloseButton`, `closeOnBackdrop`, `closeOnEscape` (all default true), `width` (`'sm' | 'md' | 'lg' | 'xl'`, default `'md'`), `icon`, `className`.
- `ModalFooter` props: `confirmText` (default "Save"), `confirmVariant` (`'primary' | 'danger' | 'success'`), `confirmDisabled`, `confirmLoading`, `leftContent`.

### Centralized Modal State (modalSlice)

```typescript
const openMarkerEditModal = useReaperStore((s) => s.openMarkerEditModal);
openMarkerEditModal(marker);
const closeModal = useReaperStore((s) => s.closeModal);
```

Actions (`store/slices/modalSlice.ts`): `openMarkerEditModal(marker)`, `openAddRegionModal()`, `openMakeSelectionModal()`, `openTimelineSettingsModal()`, `openViewCustomizationModal()`, `closeModal()`. `ModalRoot` in `App.tsx` renders whichever is open, so the components that trigger them don't render them.

| Pattern | Use Case |
|---------|----------|
| Local state | View-specific modals (Playlist view, Settings) |
| modalSlice + ModalRoot | Modals triggered from several places (Timeline, RegionInfoBar) |

### Portal Pattern for Overlays (CRITICAL)

**All overlays must be portaled to `document.body`** to escape parent stacking contexts.

- Stacking contexts come from `isolation: isolate` (the App root), `position` + `z-index`, and `transform`, `filter`, `will-change`, `opacity < 1`.
- An overlay rendered inside a view is ranked within that view's context whatever its own z-index, so it ends up under the footer, behind faders or behind toolbars.

```tsx
import { createPortal } from 'react-dom';

const triggerRef = useRef<HTMLButtonElement>(null);
const { position } = usePortalPosition(triggerRef, isOpen, {
  placement: 'bottom-start', // 'bottom-start' | 'bottom-end' | 'top-start' | 'top-end'
  offset: 4,
});

{isOpen && createPortal(
  <div className="fixed z-dropdown" style={{ top: position.top, left: position.left }}>
    Menu content
  </div>,
  document.body
)}
```

`position` also carries `triggerWidth` and `triggerHeight` for width matching.

| Type | Positioning | Components |
|------|-------------|------------|
| **Full-screen modals** | `fixed inset-0` (centered) | `Modal`, `BottomSheet`, `SectionEditor`, `ToolbarEditor`, `IconPicker`, `TapTempoButton` dialog, `MetronomeButton` dialog, `TimeSignatureButton` dialog, `MemoryWarningBar` modal |
| **Dropdowns** | `fixed` + `usePortalPosition` | `SettingsMenu`, `QuickFilterDropdown`, `FolderBreadcrumb` |
| **Popovers** | `fixed` + `usePortalPosition` | `MarkerInfoBar` color picker, `RegionInfoBar` color picker |

Full-screen modals don't need `usePortalPosition`; only overlays that track a trigger do.

**Click-outside:** a portaled element isn't a DOM child of its trigger, so check both refs:

```tsx
const handleClickOutside = (e: MouseEvent) => {
  const target = e.target as Node;
  if (!triggerRef.current?.contains(target) && !menuRef.current?.contains(target)) {
    setIsOpen(false);
  }
};
```

**ARIA:** keep `aria-expanded` and `aria-haspopup` ("listbox", or "true" for menus) on the trigger, and `role="listbox"` / `role="option"` + `aria-selected` in the portaled content.

---

## 9. Touch & Gesture Handling

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

- Minimum **44×44px** (WCAG 2.5.5, Apple HIG)
- Known gap: color swatches are 24×24

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

### Vertical Cancel Pattern

Moving the finger more than `VERTICAL_CANCEL_THRESHOLD` (50px) above or below the control cancels the drag and reverts to the original value; moving back resumes it. Used in `usePlayheadDrag`, `useMarkerDrag`, `usePanGesture`, `RegionInfoBar`.

### Pointer Events Over Touch Events

Use `PointerEvent`, not `TouchEvent` + `MouseEvent`: one API for touch, mouse and pen, with built-in pointer capture (`setPointerCapture` on pointerdown).

---

## 10. Timeline Coordinate Systems

Viewport coordinate mix-ups are the most repeated timeline bug.

### The Problem

The timeline has two coordinate systems that are easy to confuse:

| System | Range | Use Case |
|--------|-------|----------|
| **Project coordinates** | 0 to `projectDuration` (e.g., 0-120s) | Storing positions, REAPER commands |
| **Viewport coordinates** | `viewportStart` to `viewportEnd` (e.g., 45-75s) | Screen rendering, touch handling |

```typescript
// BAD - uses full project duration for touch position
const rawPercent = (clientX - rect.left) / rect.width;
const time = rawPercent * projectDuration;  // WRONG when zoomed!

// GOOD - uses viewport range
const rawPercent = (clientX - rect.left) / rect.width;
const viewportDuration = viewportEnd - viewportStart;
const time = viewportStart + (rawPercent * viewportDuration);
```

When zoomed to 30s of a 120s project, touching the right edge must give `viewportEnd` (e.g. 75s), not `projectDuration` (120s).

### Coordinate Conversion Functions

`src/hooks/useViewport.ts` returns `timeToPercent(time)` (for rendering) and `percentToTime(percent)` (for touch handling), both relative to the visible range.

### When to Use Each System

| Operation | Coordinate System | Example |
|-----------|-------------------|---------|
| Send time to REAPER | Project | `transport/seek { time: 45.5 }` |
| Render element position | Viewport % | `left: ${timeToPercent(markerTime)}%` |
| Handle touch/click | Viewport → Project | `percentToTime(clickPercent)` |
| Store in Zustand | Project | `setPlayheadPosition(time)` |

### Overflow Clipping

`timeToPercent` returns values below 0% or above 100% for elements outside the viewport, so a region can be `left: -50%; width: 200%`:

```tsx
// Container MUST have overflow-hidden to clip these
<div className="relative overflow-hidden">
  <div style={{ left: `${leftPercent}%`, width: `${widthPercent}%` }} />
</div>
```

**Rule:** Any container that renders time-positioned elements MUST have `overflow-hidden`.

### Checklist for Timeline Features

- [ ] Am I using viewport coordinates for touch → time conversion?
- [ ] Am I using project coordinates when sending to REAPER?
- [ ] Does my container have `overflow-hidden`?
- [ ] Have I tested with the viewport zoomed in (not showing full project)?
- [ ] Do percentage calculations handle elements outside viewport gracefully?

---

## 11. PWA & iOS Safari

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

### Service Workers

REAmo registers none; `utils/versionStorage.ts` unregisters any it finds, so a stale cached app can't outlive an extension update. If one is ever added: iOS Safari caps its cache at 50 MB.

---
## 12. Accessibility

### ARIA Live Regions

```tsx
// For status updates (connection, transport state):
<div role="status" aria-live="polite">
  {statusMessage}
</div>
```

### Toggle Button Patterns

Binary toggles use `aria-pressed`; 3+ state controls use `aria-label` with the current state plus a live region. See [Button System](#1a-button-system).

### Non-Color Indicators

Track buttons use domain-standard colors (mute=blue, solo=yellow, arm=red) which have accessibility concerns. Mitigations:

- Mute/Solo buttons have text labels ("M", "S")
- Position-based meaning (mute always leftmost)
- Active state has visual difference beyond color (brightness, fill)

Known gap: no icon or shape cue alongside the colour yet.

### Reduced Motion

`index.css` cuts animation and transition durations to ~0 under `@media (prefers-reduced-motion: reduce)`; `useReducedMotion` covers JS-driven animation.

---

## 13. Performance

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
## 14. Bundle Size

No size budget is enforced. Check a build's output with:

```bash
cd frontend && npm run build && ls -lh dist/assets/   # chunk sizes
npm run analyze                                        # visual bundle analyzer
```

### Curated Icon System

Icons are curated in `src/icons/commonIcons.ts` instead of importing all ~1,900 from lucide-react, which keeps hundreds of kB out of the bundle.

**Files:**

- `src/icons/commonIcons.ts` - curated DAW-relevant icons
- `src/icons/iconSearchIndex.ts` - Semantic search (e.g., "record" → Circle, Mic, Disc)
- `scripts/analyze-icons.ts` - Maintenance script to regenerate (requires REAPER running)

**To add new icons:**

1. Add to `ADDITIONAL_DAW_ICONS` array in `scripts/analyze-icons.ts`
2. Add synonyms to `SYNONYMS` object if semantic search needed
3. Run `npx tsx scripts/analyze-icons.ts` (needs REAPER + REAmo extension)
4. Rebuild frontend

**Icon names:** use lucide's canonical names (`Trash`, `CircleX`, `LoaderCircle`), never its deprecated aliases (`Trash2`, `XCircle`, `Loader2`). Saved toolbar buttons and action sections can still hold alias names, so `LEGACY_ICON_NAMES` in `src/icons/iconLookup.ts` maps each alias the curated set used to offer to its canonical icon.

### Other Optimizations

- `LazyIconPicker` via `React.lazy()` loads `IconPicker` as its own chunk. Nothing may import `IconPicker` statically, the Toolbar barrel included: Rolldown keeps a module that is imported anywhere statically in the main chunk; `no-restricted-imports` enforces this.
- `console.*` calls and `debugger` statements are dropped from production builds by the Oxc minifier (`build.rolldownOptions.output.minify` in `vite.config.ts`)

### Import Patterns

```typescript
// GOOD - uses curated set:
import { Play, Pause } from 'lucide-react';
import { commonIcons } from '../icons/commonIcons';

// BAD - includes every lucide icon:
import { icons } from 'lucide-react';
```

---

## 15. Error Handling

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

## 16. Testing

### Running Tests

```bash
npm run test           # Single run
npm run test:watch     # Watch mode
npm run test:coverage  # With coverage report
npm run test:e2e       # Playwright E2E tests
npm run test:e2e:ui    # Playwright with UI
```

### Coverage

Coverage uses `@vitest/coverage-v8`. Run `npm run test:coverage` to see a text report.


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
## 17. Why the Checklist Says So

Bugs that produced the §18 rules:

- **Hardcoded colors:** sends mode, faders and routing indicators used `bg-amber-500`, `text-white` and inline hex; the `sends-*`, `routing-*` and `fader-*` tokens replaced them. Before any color class: use a semantic token if one exists, add one to `index.css` if the color is feature-specific, raw Tailwind only if truly arbitrary.
- **Viewport vs project coordinates:** the playhead and selection jumped to the wrong time when zoomed, because touch handlers used `projectDuration`. See §10.
- **Missing `overflow-hidden`:** region labels and selection indicators overflowed the timeline bars and scrolled the page.
- **Timer IDs in `useState`:** extra re-renders and cleanup races in `ConnectionStatus`. Timer IDs never need to trigger a render.
- **Scattered `select-none`:** 21+ components set it separately and inconsistently. It's set once on the App root; global behaviour belongs at the root.
- **Missing timer cleanup:** orphaned timeouts firing after unmount in long sessions. Every `setTimeout`/`setInterval` gets a cleanup effect (§4).

---

## 18. Anti-Patterns Checklist

| Don't | Do Instead |
|-------|------------|
| `useRef<T>()` | `useRef<T>(null)` |
| `state?.tracks ?? {}` | `state?.tracks ?? EMPTY_TRACKS` |
| `useReaperConnection()` in components | `useReaper()` from context |
| Hardcoded colors `#374151` | Design tokens `bg-bg-elevated` |
| Tailwind colors `bg-amber-500` | Semantic tokens `bg-sends-primary` |
| `text-white` on colored bg | `text-on-primary`, `text-on-success` |
| `100vh` for height | `100dvh` or `.h-screen-safe` |
| Unguarded `localStorage` | try-catch wrapper |
| Timer without cleanup effect | Add `useEffect` return |
| `useState` for timer IDs | `useRef` for timer IDs |
| `touch-action: manipulation` | `touch-action: none` |
| Animate `width`/`height`/`top`/`left` | Animate `transform`/`opacity` |
| `import { icons }` from lucide | Import individual icons |
| Mutate Zustand Map in place | Create new Map, then set |
| Select array/object without useShallow | Atomic primitives or useShallow |
| `percent * projectDuration` for touch | `viewportStart + percent * viewportDuration` |
| Percentage children without overflow | Add `overflow-hidden` to container |
| `select-none` on individual components | Single `select-none` at App root |
| Magic numbers for thresholds | Named constants (§20) |
| Inline modals/dropdowns with `z-*` | Portal to `document.body` with `createPortal` |
| `absolute` positioning for dropdowns | `fixed` + `usePortalPosition` when portaled |
| Whole hook object as useCallback dep (`[bank]` is new each render: infinite loop) | Destructure stable fns: `const { goBack } = useBankNavigation()` |
| Fixed rail width on notched device (60px - 34px notch = 26px content) | `calc(60px + env(safe-area-inset-left))` |

---
## 19. Layout Budget System

The app is divided into discrete vertical sections, each with a **budget** of space. Content must fit within its budget — no overlap allowed.

### App Layout Structure

```
┌─────────────────────────────────┐
│     ViewHeader                  │  shrink-0, fixed
├─────────────────────────────────┤
│                                 │
│     PRIMARY CONTENT             │  flex-1 (gets remaining)
│     (faders, timeline canvas)   │
│                                 │
├─────────────────────────────────┤
│     SECONDARY CONTENT           │  44-140px (collapsible)
│     (SecondaryPanel)            │
├─────────────────────────────────┤
│     Tab Bar                     │  optional via settings
├─────────────────────────────────┤
│     PersistentTransport         │  optional via settings
└─────────────────────────────────┘
```

### Budget Rules

1. **Each section gets a fixed or flex budget** — no negotiation
2. **Content must fit within its budget** — add `overflow-hidden` as safety net
3. **Primary content maximizes within its budget** — faders/canvas fill available space
4. **Padding/margins count against the budget** — must be subtracted from calculations

### Responsive Height Calculation Pattern

Use `useAvailableContentHeight` hook to measure container and calculate component heights:

```typescript
import { useAvailableContentHeight } from '../../hooks';
import { STRIP_OVERHEAD_FULL, MIN_FADER_PORTRAIT, MAX_FADER_PERCENT, MIXER_CONTENT_PADDING } from '../../constants/layout';

// 1. Measure available height via ResizeObserver
const { availableHeight, isLandscape } = useAvailableContentHeight({
  containerRef,
  viewId: 'mixer',
});

// 2. Calculate component height within budget
const faderHeight = useMemo(() => {
  if (availableHeight === 0) return MIN_FADER_PORTRAIT;

  // Budget = measured height - container padding
  const stripBudget = availableHeight - MIXER_CONTENT_PADDING;
  // Component height = budget - overhead (non-interactive elements)
  const calculated = stripBudget - STRIP_OVERHEAD_FULL;

  return Math.min(
    Math.max(MIN_FADER_PORTRAIT, calculated), // Floor: touch usability
    stripBudget * MAX_FADER_PERCENT           // Ceiling: prevent overflow
  );
}, [availableHeight]);
```

### Layout Constants

In `constants/layout.ts`: `PANEL_HEIGHT_COLLAPSED` (44) / `PANEL_HEIGHT_EXPANDED` (140) / `PANEL_TRANSITION_MS`, `STRIP_OVERHEAD_FULL` (164: color bar + name + pan + M/S + buttons + footer), `MIXER_CONTENT_PADDING` (36), `MIN_FADER_PORTRAIT` (80) / `MIN_FADER_LANDSCAPE` (50), `MAX_FADER_PERCENT` (0.7). Document the breakdown of any overhead constant next to it.

Why: the same model works from iPhone SE to iPad Pro; expanding SecondaryPanel shrinks primary content predictably; an overflow means something exceeded its budget.

### Common Mistakes

- Hardcoded heights (`panelExpanded ? 140 : 220`) instead of a value calculated from the measured budget.
- No `overflow-hidden` safety net on a budgeted container.

---

## 20. Constants

What's centralised:

- `constants/layout.ts`: layout dimensions and thresholds (panel heights, strip overhead, fader limits, rail widths, size-class thresholds; see §19 and §21).
- `constants/colors.ts`: marker and item color palettes.

What isn't: gesture timings and thresholds are defined in each component, and they differ.

- Long-press: 300 ms (`Toolbar/ToolbarButton.tsx`), 400 ms (`Timeline/TimelineFooter.tsx`), 500 ms (`RegionInfoBar.tsx`, `RegionContextBar.tsx`).
- Hold-to-reset: 500 ms (`Toolbar/ColorPickerInput.tsx`, `AddRegionModal.tsx`, `MarkerEditModal.tsx`); hold delay 300 ms (`Mixer/BankNavigator.tsx`, `hooks/useRecordButton.ts`).
- Double-tap: 300 ms (`Mixer/FxParamModal.tsx`).
- `VERTICAL_CANCEL_THRESHOLD = 50` px, repeated in `usePlayheadDrag`, `useMarkerDrag`, `usePanGesture` and `useTimelinePointerEvents`.
- Pan momentum: `FRICTION` and `MAX_VELOCITY_RATIO` in `usePanGesture.ts`.

Known gap: there's no shared gesture or timeline constants module. When adding a gesture, name the constant at the top of the file and match the nearest existing value rather than inventing a new one.

---

## 21. Dual-Rail Responsive Layout (Landscape Phones)

When viewport height drops below 480px in landscape orientation, the app switches
from bottom navigation to a dual-rail layout to reclaim vertical space.

### Rules

- Fingers don't scale with screens: size touch controls with pixel floors and ceilings, never percentages of the viewport (10% is 32px on a 320px phone).
- Width is the primary layout trigger (vertical scrolling is expected), but height below 480px forces the side rail: bottom chrome would leave too little room.
- Size classes follow Material Design's window size classes: width compact < 600px, medium 600-839px, expanded ≥ 840px; height compact < 480px (`constants/layout.ts`).
- Orientation comes from the device (`screen.orientation`), room from the viewport, so the on-screen keyboard or a short browser viewport can't flip the layout (and remount the view).
- Faders get their length from flex (the space available); their width stays fixed.

### Layout Modes

| Mode | Condition | Navigation | Transport |
|------|-----------|------------|-----------|
| **Bottom** | Portrait OR height ≥ 480px | TabBar at bottom | PersistentTransport at bottom |
| **Side Rail** | Landscape AND height < 480px | NavRail (left, 60px) | Integrated in NavRail |

### Detection Hook: `useLayoutContext`

```typescript
const { navPosition, isLandscapeConstrained, widthClass, heightClass } = useLayoutContext();

// Conditional rendering in App.tsx
{navPosition === 'side' ? <SideRail /> : <TabBar />}

// Hide SecondaryPanel when side rail active
{!isLandscapeConstrained && <SecondaryPanel />}
```

### Component Architecture

```
┌──────┬───────────────────────┬──────┐
│      │        Header         │      │
│ NAV  ├───────────────────────┤CONTXT│
│ RAIL │                       │ RAIL │
│      │     Main Content      │      │
│(60px)│   (faders/timeline)   │(72px)│
│      │                       │      │
│ Tabs │                       │ Tabs │
│  +   │                       │ Bank │
│Trans │                       │ Nav  │
└──────┴───────────────────────┴──────┘
```

**Components:**

- `SideRail` (NavRail): Left side - view tabs + play/stop/record
- `ContextRail`: Right side - info tabs + bank nav + search + expandable panel
- `ContextRailTab`: Individual tab button with badge support
- `ContextRailPanel`: Animated slide-in overlay for expanded content

### View Integration Pattern

Views must sync their bank navigation and info content to the side rail store
when in landscape-constrained mode:

```typescript
// In MixerView / TimelineView
const { isLandscapeConstrained } = useAvailableContentHeight({ containerRef, viewId });
const setSideRailBankNav = useReaperStore((s) => s.setSideRailBankNav);
const setSideRailBankNavCallbacks = useReaperStore((s) => s.setSideRailBankNavCallbacks);
const setSideRailInfo = useReaperStore((s) => s.setSideRailInfo);

useEffect(() => {
  if (isLandscapeConstrained) {
    setSideRailBankNav({ bankDisplay, canGoBack, canGoForward });
    setSideRailBankNavCallbacks({ onBack: handleBack, onForward: handleForward });
    setSideRailInfo({ content: infoTabContent, label: 'Track Info' });
  }
  return () => {
    if (isLandscapeConstrained) {
      setSideRailBankNav(null);
      setSideRailBankNavCallbacks({ onBack: null, onForward: null });
      setSideRailInfo(null);
    }
  };
}, [isLandscapeConstrained, /* stable dependencies */]);
```

**Critical:** destructure stable functions from hooks (`const { goBack } = useBankNavigation(...)`) and depend on those; the `bank` object is new every render, so `[bank]` as a dependency loops forever.

### Safe Area Handling

Rail width is content width **plus** the safe-area inset, not content including it: `calc(60px + env(safe-area-inset-left, 0px))` for the nav rail, `calc(72px + env(safe-area-inset-right, 0px))` for the context rail, with a 34px fallback in standalone landscape (`.nav-rail-width`, `.context-rail-width` in `index.css`).

### Layout Constants

`constants/layout.ts`: `NAV_RAIL_WIDTH` (60), `CONTEXT_RAIL_WIDTH` (72), `CONTEXT_PANEL_WIDTH` (200), `HEIGHT_COMPACT_THRESHOLD` (480), `WIDTH_MEDIUM_THRESHOLD` (600), `WIDTH_EXPANDED_THRESHOLD` (840).

### Common Pitfalls

| Mistake | Consequence | Fix |
|---------|-------------|-----|
| Fixed rail width without safe area | Controls cut off on notched devices | `calc(Xpx + env(safe-area-inset-*))` |
| Forgetting cleanup in sync effect | Stale state after orientation change | Return a cleanup that nulls the state |
| Not hiding SecondaryPanel | Duplicate controls, wasted space | Check `isLandscapeConstrained` before rendering |

### Not built yet

- Tablet layouts for the expanded width class: 2-3 channel strips side by side, revealing controls hidden on phones (EQ, dynamics), list + detail, and a capped content width.
- A compact (36px) header in landscape; `ViewHeader` is the same height in every orientation.
- Per-view footer defaults (in landscape, Instruments and Clock hide both the tab bar and the transport), merged with the user's tab bar and transport toggles. See UX_GUIDELINES §7.

---

## 22. ESLint Governance & Pre-commit Hooks

Custom ESLint rules and a pre-commit hook enforce the patterns in this document.

### What's Automated

| Rule | Section | Detection |
|------|---------|-----------|
| `reamo/require-effect-cleanup` | §4 Memory Safety | Warns on useEffect with timers/listeners without cleanup |
| `reamo/no-state-for-timer-ids` | §4 Memory Safety | Warns on useState for timer/RAF IDs (use useRef) |
| `reamo/prefer-button-primitive` | §1a Button System | Warns on raw `<button>` (turned off in `eslint.config.js`) |
| `no-restricted-syntax` | §5 React 19 | useRef<T>() without initial value |
| `no-restricted-syntax` | §6 Zustand 5 | Array/object selectors without useShallow |
| `no-restricted-syntax` | §6 Zustand 5 | Inline `?? {}` or `?? []` fallbacks |
| `no-restricted-syntax` | §7 WebSocket | useReaperConnection() outside ReaperProvider |
| `no-restricted-syntax` | §11 iOS Safari | h-screen without dvh |
| `no-restricted-imports` | §14 Bundle Size | Barrel imports from lucide-react |

### Pre-commit Hook

Runs automatically on staged `.ts`/`.tsx` files via Husky + lint-staged:

```bash
# Triggered by: git commit
cd frontend && npx lint-staged
# Runs: eslint --cache --fix --max-warnings=0
```

Commits are blocked if warnings remain after auto-fix.

### Known Limitations

1. **Conditional cleanup detection**: `require-effect-cleanup` cannot detect cleanup returns inside `if` blocks. Only top-level returns are recognized:

   ```typescript
   // ❌ Rule misses this valid cleanup
   useEffect(() => {
     if (condition) {
       const id = setInterval(...);
       return () => clearInterval(id);  // Not detected
     }
   }, []);
   ```

2. **AST selector limits**: `no-restricted-syntax` patterns match syntax, not semantics. Some edge cases may false-positive.

### Adding Exceptions

For legitimate exceptions, add file-specific overrides in `eslint.config.js`:

```javascript
{
  files: ['src/components/MyException.tsx'],
  rules: {
    'reamo/require-effect-cleanup': 'off',
  },
},
```

Always add a comment explaining why the exception is needed.

### Configuration Files

- `eslint.config.js` - Rule definitions and file overrides
- `eslint-rules/index.js` - Custom rule implementations
- `lint-staged.config.js` - Pre-commit lint configuration
- `.husky/pre-commit` - Git hook entry point
