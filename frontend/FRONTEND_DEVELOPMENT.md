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
8. [Modal System](#8-modal-system)
9. [Touch & Gesture Handling](#9-touch--gesture-handling)
10. [Timeline Coordinate Systems](#10-timeline-coordinate-systems)
11. [PWA & iOS Safari](#11-pwa--ios-safari)
12. [Accessibility](#12-accessibility)
13. [Performance](#13-performance)
14. [Bundle Size](#14-bundle-size)
15. [Error Handling](#15-error-handling)
16. [Testing](#16-testing)
17. [Common Mistakes (Real Examples)](#17-common-mistakes-real-examples)
18. [Anti-Patterns Checklist](#18-anti-patterns-checklist)
19. [Layout Budget System](#19-layout-budget-system)
20. [Centralized Constants](#20-centralized-constants)
21. [Deferred/Future Work](#21-deferredfuture-work)

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

### Feature-Specific Tokens (Added Post-Audit)

These tokens were added after compliance audits found hardcoded colors:

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

### Real Examples of Token Violations (Fixed)

```tsx
// BAD - hardcoded amber for sends mode (was in MixerModeSelector)
<button className="bg-amber-500 text-white">Sends</button>

// GOOD - semantic token
<button className="bg-sends-primary text-on-primary">Sends</button>

// BAD - hardcoded white for fader handle (was in Fader component)
<div style={{ backgroundColor: 'white' }} />

// GOOD - token reference
<div className="bg-fader-handle" />

// BAD - hardcoded hex for selection border (was in RegionInfoBar)
<div className="border-white" />

// GOOD - on-color token
<div className="border-on-primary" />
```

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
| `useReducedMotion` | `hooks/useReducedMotion.ts` | Respect prefers-reduced-motion |
| `usePeakHold` | `hooks/usePeakHold.ts` | Meter peak hold with decay |
| `useResponsiveChannelCount` | `hooks/useResponsiveChannelCount.ts` | Screen-width based channel count |
| `useBankNavigation` | `hooks/useBankNavigation.ts` | Bank state with localStorage |
| `usePortalPosition` | `hooks/usePortalPosition.ts` | Position portaled dropdowns relative to trigger |
| `MARKER_COLORS` | `constants/colors.ts` | Preset marker palette |
| `ITEM_COLORS` | `constants/colors.ts` | Preset item palette |

### Timeline Gesture Hooks

These hooks in `components/Timeline/hooks/` handle all timeline interactions:

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

### Two-Phase Timer Cleanup (Recommended)

For complex components with multiple cancel paths, null the ref after clearing:

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

This was a real bug fixed in `ConnectionStatus.tsx` - using useState for timer IDs caused unnecessary re-renders and cleanup issues.

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
  // Handle timeout (5s) or disconnection
  console.error('Command failed:', error);
}
```

**Key behaviors:**
- Rejects immediately if not connected
- Automatically times out after 5 seconds
- Response matched via unique message ID
- Pending responses cleared on disconnect/reconnect

**When to use:**
| Scenario | Method |
|----------|--------|
| Fire-and-forget actions | `sendCommand()` |
| Need response data | `sendCommandAsync()` |
| Time-critical (meters, transport) | `sendCommand()` |
| Bar/beat ↔ time conversion | `sendCommandAsync()` |

---

## 8. Modal System

### Architecture Overview

Modals use a three-part architecture:

| Component | Purpose |
|-----------|---------|
| `Modal` | Wrapper with Escape, backdrop, focus management |
| `ModalContent` | Content area with consistent padding |
| `ModalFooter` | Action buttons (Cancel/Confirm variants) |
| `modalSlice` | Zustand slice for centralized state |
| `ModalRoot` | Renders Timeline-related modals from state |

### Basic Usage

```tsx
import { Modal, ModalContent, ModalFooter } from '../components/Modal';

function MyModal({ isOpen, onClose }: Props) {
  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Edit Item">
      <ModalContent>
        <input ... />
      </ModalContent>
      <ModalFooter
        onCancel={onClose}
        onConfirm={handleSave}
        confirmDisabled={!isValid}
      />
    </Modal>
  );
}
```

### Modal Props

```typescript
interface ModalProps {
  isOpen: boolean;
  onClose: () => void;
  title: string;
  children: ReactNode;
  showCloseButton?: boolean; // default: true
  closeOnBackdrop?: boolean; // default: true
  closeOnEscape?: boolean;   // default: true
  width?: 'sm' | 'md' | 'lg' | 'xl'; // default: 'md'
  icon?: ReactNode;
}
```

### ModalFooter Variants

```tsx
// Primary (default) - Save, Create, etc.
<ModalFooter onCancel={close} onConfirm={save} confirmText="Save" />

// Danger - Delete, Remove, etc.
<ModalFooter
  onCancel={close}
  onConfirm={handleDelete}
  confirmText="Delete"
  confirmVariant="danger"
/>

// Success - Complete, Confirm, etc.
<ModalFooter
  onCancel={close}
  onConfirm={handleComplete}
  confirmText="Complete"
  confirmVariant="success"
/>

// Loading state
<ModalFooter
  onCancel={close}
  onConfirm={save}
  confirmLoading={isSaving}
/>
```

### Centralized Modal State (modalSlice)

For modals that need to be opened from multiple places (e.g., Timeline components), use the centralized modalSlice:

```typescript
// Opening a modal from any component
const openMarkerEditModal = useReaperStore((s) => s.openMarkerEditModal);
openMarkerEditModal(marker);

// Closing modals
const closeModal = useReaperStore((s) => s.closeModal);
closeModal();
```

Available actions:
- `openMarkerEditModal(marker)` - Edit marker position/color
- `openDeleteRegionModal(region, regionId)` - Confirm region deletion
- `openAddRegionModal()` - Create new region
- `openMakeSelectionModal()` - Set time selection
- `closeModal()` - Close any open modal

### ModalRoot

`ModalRoot` in `App.tsx` renders all Timeline-related modals based on centralized state:

```tsx
// In App.tsx
<ModalRoot />
```

This pattern decouples modal rendering from the components that trigger them, allowing Timeline.tsx to remain focused on timeline rendering.

### When to Use Each Pattern

| Pattern | Use Case |
|---------|----------|
| Local state | View-specific modals (CuesView playlists, Settings) |
| modalSlice | Modals triggered from multiple places (Timeline, RegionInfoBar) |
| ModalRoot | Centralizes Timeline modals (Marker, Region, Selection) |

### Portal Pattern for Overlays (CRITICAL)

**All overlays must be portaled to `document.body`** to escape parent stacking contexts.

#### Why Portals Are Required

CSS stacking contexts are created by:
- `isolation: isolate` (used at App root for z-index isolation)
- `position` + `z-index` combinations
- `transform`, `filter`, `will-change`, `opacity < 1`

When a modal/dropdown is rendered inside a view component, even with `position: fixed` and `z-modal` (500), its z-index is evaluated **within the parent's stacking context**, not against the document root. This causes:
- Modals appearing under footer elements
- Dropdowns appearing behind faders
- Color pickers appearing behind toolbars

#### The Solution: Portal to Body

```tsx
import { createPortal } from 'react-dom';

// BAD - inline rendering, trapped in stacking context
function Dropdown({ isOpen }) {
  return (
    <div className="relative">
      <button>Open</button>
      {isOpen && (
        <div className="absolute top-full z-dropdown">
          Menu content
        </div>
      )}
    </div>
  );
}

// GOOD - portaled to body, escapes all stacking contexts
function Dropdown({ isOpen }) {
  const triggerRef = useRef<HTMLButtonElement>(null);
  const { position } = usePortalPosition(triggerRef, isOpen);

  return (
    <div className="relative">
      <button ref={triggerRef}>Open</button>
      {isOpen && createPortal(
        <div
          className="fixed z-dropdown"
          style={{ top: position.top, left: position.left }}
        >
          Menu content
        </div>,
        document.body
      )}
    </div>
  );
}
```

#### usePortalPosition Hook

For dropdowns/popovers that need to track a trigger element's position:

```tsx
import { usePortalPosition } from '../hooks/usePortalPosition';

const triggerRef = useRef<HTMLButtonElement>(null);
const { position } = usePortalPosition(triggerRef, isOpen, {
  placement: 'bottom-start',  // 'bottom-start' | 'bottom-end' | 'top-start' | 'top-end'
  offset: 4,                   // gap between trigger and dropdown
});

// position.top, position.left - absolute coordinates
// position.triggerWidth, position.triggerHeight - for width matching
```

#### Components That Must Be Portaled

| Type | Positioning | Components |
|------|-------------|------------|
| **Full-screen modals** | `fixed inset-0` (centered) | `Modal`, `BottomSheet`, `SectionEditor`, `ToolbarEditor`, `IconPicker`, `TapTempoButton` dialog, `MetronomeButton` dialog, `TimeSignatureButton` dialog, `MemoryWarningBar` modal |
| **Dropdowns** | `fixed` + `usePortalPosition` | `SettingsMenu`, `QuickFilterDropdown`, `FolderBreadcrumb` |
| **Popovers** | `fixed` + `usePortalPosition` | `MarkerInfoBar` color picker, `RegionInfoBar` color picker |

**Note:** Full-screen modals don't need `usePortalPosition` since they use `fixed inset-0` for viewport-centered positioning. Only dropdowns/popovers that need to track a trigger element's position require the hook.

#### Click-Outside Handling for Portaled Elements

Since portaled elements are no longer DOM children of the trigger, click-outside detection needs both refs:

```tsx
const triggerRef = useRef<HTMLButtonElement>(null);
const menuRef = useRef<HTMLDivElement>(null);

useEffect(() => {
  if (!isOpen) return;

  const handleClickOutside = (e: MouseEvent) => {
    const target = e.target as Node;
    const clickedTrigger = triggerRef.current?.contains(target);
    const clickedMenu = menuRef.current?.contains(target);
    if (!clickedTrigger && !clickedMenu) {
      setIsOpen(false);
    }
  };

  document.addEventListener('mousedown', handleClickOutside);
  return () => document.removeEventListener('mousedown', handleClickOutside);
}, [isOpen]);
```

#### Accessibility for Portaled Dropdowns

Maintain these ARIA attributes when portaling:

```tsx
// Trigger button
<button
  ref={triggerRef}
  aria-expanded={isOpen}
  aria-haspopup="listbox"  // or "true" for menus
>

// Portaled dropdown
{isOpen && createPortal(
  <div role="listbox">
    <button role="option" aria-selected={isSelected}>
      Option
    </button>
  </div>,
  document.body
)}
```

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

### Vertical Cancel Pattern

Allow users to cancel drags by moving finger vertically (common UX pattern):

```typescript
const VERTICAL_CANCEL_THRESHOLD = 50;  // px

const handlePointerMove = (e: PointerEvent) => {
  const rect = containerRef.current?.getBoundingClientRect();
  if (!rect) return;

  // Cancel if finger moved too far vertically
  const isOutsideVertically =
    e.clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
    e.clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD;

  if (isOutsideVertically) {
    // Revert to original value, show preview state
    setPreviewValue(originalValue);
    return;
  }

  // Normal drag handling
  const percent = (e.clientX - rect.left) / rect.width;
  setPreviewValue(calculateValue(percent));
};
```

Used in: `usePlayheadDrag`, `useMarkerDrag`, `usePanGesture`, `RegionInfoBar`

### Pointer Events Over Touch Events

Always use `PointerEvent` instead of `TouchEvent`:

```typescript
// GOOD - unified pointer handling
const handlePointerDown = (e: React.PointerEvent) => {
  e.stopPropagation();
  (e.target as HTMLElement).setPointerCapture(e.pointerId);
  // ...
};

// AVOID - separate touch/mouse handling
const handleTouchStart = (e: React.TouchEvent) => { ... };
const handleMouseDown = (e: React.MouseEvent) => { ... };
```

**Why PointerEvent?**
- Single API for touch, mouse, pen
- Built-in pointer capture
- Better performance (no synthetic events)

---

## 10. Timeline Coordinate Systems

**This section exists because viewport coordinate bugs caused 3+ separate hotfixes.**

### The Problem

The timeline has two coordinate systems that are easy to confuse:

| System | Range | Use Case |
|--------|-------|----------|
| **Project coordinates** | 0 to `projectDuration` (e.g., 0-120s) | Storing positions, REAPER commands |
| **Viewport coordinates** | `viewportStart` to `viewportEnd` (e.g., 45-75s) | Screen rendering, touch handling |

### Common Mistake: Using Wrong Coordinate System

```typescript
// BAD - uses full project duration for touch position
const rawPercent = (clientX - rect.left) / rect.width;
const time = rawPercent * projectDuration;  // WRONG when zoomed!

// GOOD - uses viewport range
const rawPercent = (clientX - rect.left) / rect.width;
const viewportDuration = viewportEnd - viewportStart;
const time = viewportStart + (rawPercent * viewportDuration);
```

**Why this matters:** When zoomed to view only 30s of a 120s project, touching the right edge of the screen should give `viewportEnd` (e.g., 75s), not `projectDuration` (120s).

### Coordinate Conversion Functions

Located in `components/Timeline/hooks/useViewport.ts`:

```typescript
// Time to screen percentage (for rendering)
const timeToPercent = (time: number): number => {
  const duration = viewportEnd - viewportStart;
  return ((time - viewportStart) / duration) * 100;
};

// Screen percentage to time (for touch handling)
const percentToTime = (percent: number): number => {
  const duration = viewportEnd - viewportStart;
  return viewportStart + (percent / 100) * duration;
};

// Check if time range overlaps viewport
const isInView = (start: number, end: number, buffer = 0): boolean => {
  return end >= viewportStart - buffer && start <= viewportEnd + buffer;
};
```

### When to Use Each System

| Operation | Coordinate System | Example |
|-----------|-------------------|---------|
| Send time to REAPER | Project | `transport/seek { time: 45.5 }` |
| Render element position | Viewport % | `left: ${timeToPercent(markerTime)}%` |
| Handle touch/click | Viewport → Project | `percentToTime(clickPercent)` |
| Store in Zustand | Project | `setPlayheadPosition(time)` |
| Check visibility | Both | `isInView(regionStart, regionEnd)` |

### Playhead Drag Example (Real Fix)

From commit `8d2b887` - playhead was jumping to wrong position when zoomed:

```typescript
// BEFORE (broken when zoomed)
const handlePointerMove = (e: PointerEvent) => {
  const percent = (e.clientX - rect.left) / rect.width;
  const newTime = percent * timelineDuration;  // Used full duration!
  setPlayheadPosition(newTime);
};

// AFTER (correct)
const handlePointerMove = (e: PointerEvent) => {
  const percent = (e.clientX - rect.left) / rect.width;
  const viewportDuration = viewportEnd - viewportStart;
  const newTime = viewportStart + (percent * viewportDuration);
  setPlayheadPosition(newTime);
};
```

### Overflow Clipping (Another Real Fix)

From commit `9825e73` - regions overflowed the viewport container:

```typescript
// renderTimeToPercent can return >100% or <0% for items outside viewport
const leftPercent = timeToPercent(regionStart);  // Might be -50%
const widthPercent = timeToPercent(regionEnd) - leftPercent;  // Might be 200%

// Container MUST have overflow-hidden to clip these
<div className="relative overflow-hidden">
  <div style={{ left: `${leftPercent}%`, width: `${widthPercent}%` }} />
</div>
```

**Rule:** Any container that renders time-positioned elements MUST have `overflow-hidden`.

### Checklist for Timeline Features

When adding new timeline interactions:

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

### Service Worker Cache Limit

- iOS Safari: **50MB hard limit**
- Total origin storage: ~20% of disk (60% if added to home screen)

---

## 12. Accessibility

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

Current coverage (~44% statements).

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

## 17. Common Mistakes (Real Examples)

This section documents actual bugs from recent commits to prevent recurrence.

### 1. Hardcoded Colors in Feature Code

**Commit:** `6b63717` - Compliance audit

**Symptom:** Sends mode used `bg-amber-500`, faders used `text-white`, routing indicators used inline hex.

**Root Cause:** Developer used familiar Tailwind classes instead of checking for semantic tokens.

**Fix:** Added `sends-*`, `routing-*`, `fader-*` tokens and migrated 9 components.

**Prevention:** Before using any color class, check:
1. Does a semantic token exist? → Use it
2. Is this feature-specific? → Create a token in `index.css`
3. Is this truly arbitrary? → Only then use Tailwind defaults

### 2. Viewport vs Project Coordinates

**Commits:** `8d2b887`, `9cf1e64`

**Symptom:** Playhead jumped to wrong position when timeline was zoomed. Selection dragged to wrong time.

**Root Cause:** Touch handlers used `projectDuration` instead of viewport range for coordinate conversion.

**Fix:** Updated all timeline gesture hooks to accept and use `viewportStart`/`viewportEnd`.

**Prevention:** See [Timeline Coordinate Systems](#10-timeline-coordinate-systems).

### 3. Missing overflow-hidden

**Commit:** `9825e73`

**Symptom:** Region labels and selection indicators overflowed horizontally, causing page scroll.

**Root Cause:** Timeline top bar and bottom bar containers lacked `overflow-hidden`.

**Fix:** Added `overflow-hidden` to all timeline section containers.

**Prevention:** Any container with percentage-positioned children MUST have `overflow-hidden`.

### 4. Timer State Instead of Ref

**Commit:** `6b63717`

**Symptom:** `ConnectionStatus` component had unnecessary re-renders and cleanup race conditions.

**Root Cause:** Timer ID stored in `useState` instead of `useRef`.

**Fix:** Changed `const [pressTimer, setPressTimer] = useState(...)` to `const pressTimerRef = useRef(...)`.

**Prevention:** Timer IDs never need to trigger re-renders. Always use `useRef`.

### 5. Scattered select-none

**Commit:** `f2bc367`

**Symptom:** Inconsistent text selection behavior, redundant classes in 21+ files.

**Root Cause:** Each component individually added `select-none` without coordination.

**Fix:** Added single `select-none` to App.tsx root, removed from all children.

**Prevention:** Global behaviors belong at the root. Check if behavior already exists before adding to a component.

### 6. Missing Timer Cleanup

**Commits:** `6b63717`, various

**Symptom:** Memory leaks in long sessions, orphaned timeouts firing after unmount.

**Root Cause:** `setTimeout` used without corresponding `useEffect` cleanup.

**Fix:** Added cleanup effects to `TapTempoButton`, `RegionInfoBar`, `ConnectionStatus`.

**Prevention:** Every `setTimeout`/`setInterval` MUST have a cleanup effect. Use the two-phase pattern.

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
| Magic numbers for thresholds | Constants from `constants/` |
| Inline modals/dropdowns with `z-*` | Portal to `document.body` with `createPortal` |
| `absolute` positioning for dropdowns | `fixed` + `usePortalPosition` when portaled |

---

## 19. Layout Budget System

The app is divided into discrete vertical sections, each with a **budget** of space. Content must fit within its budget — no overlap allowed.

### App Layout Structure

```
┌─────────────────────────────────┐
│     ViewHeader (~44px)          │  shrink-0, fixed
├─────────────────────────────────┤
│                                 │
│     PRIMARY CONTENT             │  flex-1 (gets remaining)
│     (faders, timeline canvas)   │
│                                 │
├─────────────────────────────────┤
│     SECONDARY CONTENT           │  44-140px (collapsible)
│     (SecondaryPanel)            │
├─────────────────────────────────┤
│     Tab Bar (~44px)             │  optional via settings
├─────────────────────────────────┤
│     PersistentTransport (~80px) │  optional via settings
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

Centralized in `constants/layout.ts`:

```typescript
// SecondaryPanel heights
export const PANEL_HEIGHT_COLLAPSED = 44;
export const PANEL_HEIGHT_EXPANDED = 140;
export const PANEL_TRANSITION_MS = 200;

// Mixer strip overhead (document the breakdown!)
export const STRIP_OVERHEAD_FULL = 164;   // Color bar + name + pan + M/S + buttons + footer
export const MIXER_CONTENT_PADDING = 32;  // Container padding + breathing room

// Constraints
export const MIN_FADER_PORTRAIT = 80;     // Touch usability floor
export const MAX_FADER_PERCENT = 0.7;     // Prevent overflow ceiling
```

### Why This Matters

- **Cross-device consistency**: Same mental model works on iPhone SE and iPad Pro
- **No overlap bugs**: Each section stays in its lane
- **Predictable behavior**: Expanding SecondaryPanel shrinks primary content predictably
- **Easier debugging**: If something overflows, check if it exceeds its budget

### Common Mistakes

```typescript
// BAD - hardcoded magic numbers
const faderHeight = panelExpanded ? 140 : 220;

// GOOD - calculated from measured budget
const faderHeight = useMemo(() => {
  const budget = availableHeight - MIXER_CONTENT_PADDING;
  return Math.max(MIN_FADER_PORTRAIT, budget - STRIP_OVERHEAD_FULL);
}, [availableHeight]);

// BAD - no overflow protection
<div className="h-full flex items-center">

// GOOD - overflow-hidden as safety net
<div className="h-full flex items-center overflow-hidden">
```

---

## 20. Centralized Constants

Magic numbers scattered across the codebase make behavior inconsistent and hard to tune. Centralize these values.

### Gesture Thresholds

These should be in `constants/gestures.ts`:

```typescript
// Timing (ms)
export const LONG_PRESS_DURATION = 400;    // useLongPress, RegionInfoBar
export const DOUBLE_TAP_WINDOW = 300;      // useDoubleTap
export const HOLD_THRESHOLD = 500;         // FX modal, color picker reset
export const CONFIRM_TIMEOUT = 3000;       // Delete confirmation

// Distance (px)
export const VERTICAL_CANCEL_THRESHOLD = 50;  // Cancel drag if finger moves vertically
export const TAP_MOVE_TOLERANCE = 10;         // Max move before tap becomes drag
export const MARKER_CLUSTER_THRESHOLD = 40;   // Minimum px between markers

// Velocity
export const MIN_VELOCITY_THRESHOLD = 0.0005; // Momentum scrolling cutoff
export const MAX_VELOCITY_CAP = 0.5;          // Prevent runaway scrolling
export const FRICTION_COEFFICIENT = 0.965;    // Per-frame deceleration
```

### Timeline Constants

These should be in `constants/timeline.ts`:

```typescript
export const MIN_VISIBLE_DURATION = 5;      // Minimum 5 seconds visible
export const LOD_TEXT_THRESHOLD = 40;       // Hide region text below 40px
export const EDGE_SCROLL_ZONE = 50;         // Edge scroll activation zone
export const EDGE_SCROLL_SPEED = 0.5;       // Seconds per frame at edge
```

### Mixer/Layout Constants

These are in `constants/layout.ts` (see §19 Layout Budget System):

```typescript
// Strip overhead (document breakdown for maintainability)
export const STRIP_OVERHEAD_FULL = 164;    // Sum of non-fader elements
export const MIXER_CONTENT_PADDING = 32;   // Container padding + breathing room

// Fader constraints
export const MIN_FADER_PORTRAIT = 80;      // Touch usability floor
export const MIN_FADER_LANDSCAPE = 50;     // Compact mode minimum
export const MAX_FADER_PERCENT = 0.7;      // Overflow prevention ceiling

// Note: Fader height is now CALCULATED, not hardcoded
// See useAvailableContentHeight hook and MixerView.tsx
```

### Why Centralize?

1. **Consistency**: Same threshold everywhere
2. **Tuning**: Change once, applies everywhere
3. **Documentation**: Single place to understand system behavior
4. **Testing**: Easy to mock/override in tests

---

## 21. Deferred/Future Work

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
