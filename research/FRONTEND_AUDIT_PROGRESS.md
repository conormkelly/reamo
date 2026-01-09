# Frontend Production Audit - Living Progress Document

**IMPORTANT: Read this document first when continuing frontend audit work.**

This document tracks the production audit for the REAmo frontend codebase. It's based on the comprehensive checklist in `FRONTEND_PRODUCTION_REVIEW_CHECKLIST.md`.

---

## Context

REAmo is a React PWA control surface for REAPER DAW. It runs on iPad/iPhone for hour-long recording sessions. Users rarely refresh - the app must remain stable over extended use.

**Tech Stack:**
- React 19.2.0 + TypeScript 5.9.3
- Zustand 5.0.9 (17 slices)
- Vite 7.2.4 with vite-plugin-singlefile
- TanStack Virtual 3.13.17
- lucide-react 0.559.0 (~1900 icons)

---

## Completed Fixes

### Batch 1: Critical Issues (DONE)

| Issue | Fix | Files Modified |
|-------|-----|----------------|
| No ErrorBoundary | Created ErrorBoundary component, wrapped ViewComponent | `src/components/ErrorBoundary.tsx` (new), `src/components/index.ts`, `src/App.tsx` |
| useDoubleTap timer leak | Added useEffect cleanup | `src/hooks/useDoubleTap.ts` |
| useLongPress timer leak | Added useEffect cleanup | `src/hooks/useLongPress.ts` |
| useMarkerDrag timer leak | Added useEffect cleanup | `src/components/Timeline/hooks/useMarkerDrag.ts` |
| pendingResponses never cleared | Added `clearPendingResponses()` method, called from `stop()` and `forceReconnect()` | `src/core/WebSocketConnection.ts` |
| Icons object imported in 5 files | Created shared `DynamicIcon.tsx` with `getIconComponent()` | `src/components/Toolbar/DynamicIcon.tsx` (new), `ToolbarButton.tsx`, `ToolbarEditor.tsx`, `SectionEditor.tsx`, `ActionsSection.tsx` |
| console.log in production | Configured Vite esbuild `drop: ['console', 'debugger']` for production mode | `vite.config.ts` |
| No prefers-reduced-motion | Added `@media (prefers-reduced-motion: reduce)` rules | `src/index.css` |

### Batch 2: Zustand Selector Stability (DONE)

| Issue | Fix | Files Modified |
|-------|-----|----------------|
| Fallback objects create new refs | Created `stableRefs.ts` with frozen empty references | `src/store/stableRefs.ts` (new) |
| 13 unstable selectors | Updated to use stable refs (`EMPTY_TRACKS`, `EMPTY_REGIONS`, etc.) | `useTrackSkeleton.ts`, `useTracks.ts`, `Timeline.tsx`, `VirtualizedTrackList.tsx`, `ItemsTimeline.tsx` |

**Also verified (no issues found):**
- No array destructuring selectors (would cause infinite loops in Zustand 5)
- No `useRef` without initial value (TypeScript 5.9 strict mode)
- No `forwardRef` usage (deprecated in React 19)

### Batch 3: Component Timer Cleanup + Accessibility (DONE)

| Issue | Fix | Files Modified |
|-------|-----|----------------|
| TransportBar holdTimerRef leak | Added useEffect cleanup | `src/components/Transport/TransportBar.tsx` |
| PersistentTransport holdTimerRef leak | Added useEffect cleanup | `src/components/PersistentTransport.tsx` |
| TapTempoButton holdTimerRef leak | Added useEffect cleanup | `src/components/Actions/TapTempoButton.tsx` |
| MetronomeButton holdTimerRef leak | Added useEffect cleanup | `src/components/Actions/ActionButton.tsx` |
| RegionInfoBar longPressTimerRef leak | Added useEffect cleanup | `src/components/Timeline/RegionInfoBar.tsx` |
| MarkerInfoBar saveTimeoutRef leak | Added useEffect cleanup | `src/components/Markers/MarkerInfoBar.tsx` |
| ColorPickerInput holdTimer leak | Added useEffect cleanup | `src/components/Toolbar/ColorPickerInput.tsx` |
| TransportControls (clock) holdTimerRef leak | Added useEffect cleanup | `src/views/clock/components/TransportControls.tsx` |
| Transport buttons missing aria-label/aria-pressed | Added to all transport buttons | All transport components above |
| MetronomeButton missing aria attributes | Added aria-label + aria-pressed | `src/components/Actions/ActionButton.tsx` |

**Also verified (no issues found):**
- No ResizeObserver or IntersectionObserver usage in codebase (nothing to clean up)

### Batch 4: Medium Priority Audits (DONE)

| Issue | Fix | Files Modified |
|-------|-----|----------------|
| IconPicker loads ~1900 icons upfront | Created `LazyIconPicker.tsx` with React.lazy() + Suspense | `src/components/Toolbar/LazyIconPicker.tsx` (new), `ToolbarEditor.tsx`, `SectionEditor.tsx`, `index.ts` |

**Also verified (no issues found):**
- Map mutations in store slices all create new Maps before calling `.set()` (correct pattern)
- All `get()` calls are inside action function bodies (fresh state, no stale closures)
- No async actions in store slices (no stale state risk)

### Batch 5: Deep Audit Items (DONE)

| Issue | Fix | Files Modified |
|-------|-----|----------------|
| No React 19 error callbacks | Added `onUncaughtError` and `onCaughtError` to createRoot | `src/main.tsx` |
| Fader missing touch-action | Added `touch-none` class to prevent browser gesture hijacking | `src/components/Track/Fader.tsx` |
| PanKnob missing touch-action | Added `touch-none` class to prevent browser gesture hijacking | `src/components/Track/PanKnob.tsx` |
| PeaksCache unbounded growth | Added LRU eviction with max 100 entries | `src/core/PeaksCache.ts` |

**Also verified (no issues found):**
- `transportSyncEngine.destroy()` never called - OK, singleton lives for entire PWA lifetime
- `useVirtualizedSubscription` already has proper cleanup (lines 188-196)

### Batch 6: Accessibility + iOS Polish (DONE)

| Issue | Fix | Files Modified |
|-------|-----|----------------|
| No -webkit-touch-callout | Added to body to prevent iOS context menu on long-press | `src/index.css` |
| No aria-live for connection status | Added `role="status"` + `aria-live="polite"` to ConnectionBanner | `src/components/ConnectionStatus.tsx` |
| No aria-live for transport state | Added visually-hidden live region announcing play/record/stop | `src/components/Transport/TransportBar.tsx` |

### Batch 7: localStorage + touch-action + Pointer Capture (DONE)

| Issue | Fix | Files Modified |
|-------|-----|----------------|
| localStorage without try-catch (App.tsx) | Wrapped getItem/setItem in try-catch for iOS quota errors | `src/App.tsx` |
| localStorage without try-catch (TimelineModeToggle) | Wrapped getItem/setItem in try-catch | `src/components/Timeline/TimelineModeToggle.tsx` |
| Missing touch-action (ColorPickerInput) | Added `touch-none` class to hold-to-reset swatch | `src/components/Toolbar/ColorPickerInput.tsx` |
| Missing touch-action (RegionInfoBar) | Added `touch-none` class to Add button with long-press | `src/components/Timeline/RegionInfoBar.tsx` |
| Missing touch-action (ConnectionStatus) | Added `touch-none` class to long-press stats indicator | `src/components/ConnectionStatus.tsx` |
| Pointer capture stuck on cancel | Added try-catch around `releasePointerCapture` calls | `src/components/Timeline/Timeline.tsx`, `hooks/usePlayheadDrag.ts`, `hooks/useMarkerDrag.ts`, `hooks/useRegionDrag.ts` |

**Also verified (already OK):**
- `TransportSyncEngine.ts` already has try-catch around localStorage
- `toggleStates`/`guidToIndex` Maps are bounded by project size (not unbounded growth)
- Style mutations (`.style.left`, `.style.width`) are intentional 60fps animations

### Structural Audit (DONE)

**Verified OK - no action needed:**
- Source maps disabled in production (Vite default)
- Dependencies minimal (5 runtime: react, react-dom, zustand, tanstack-virtual, lucide-react)
- Type assertions (`as unknown as`) - only 4 uses, all necessary for WebSocket message typing
- Barrel exports (`export * from`) - reasonable, not causing issues
- Timeline.tsx (737 lines) - complex but cohesive, splitting would harm readability
- RegionInfoBar.tsx (725 lines) - modals already extracted to separate files

**Structural improvements made:**
| Issue | Fix | Files Modified |
|-------|-----|----------------|
| ActionButton.tsx has 9 components (567 lines) | Split into 6 focused files | `ActionButton.tsx` (94 lines), `MetronomeButton.tsx`, `MarkerButtons.tsx`, `UndoRedoButtons.tsx`, `SaveButton.tsx`, `MixerButtons.tsx`, `index.ts` |
| CuesView.tsx has 5 components (1020 lines) | Split into 3 files | `CuesView.tsx` (560 lines), `components/PlaylistEntryRow.tsx` (220 lines), `components/CuesModals.tsx` (250 lines) |

### Batch 8: Additional Verification (DONE)

**Verified OK - no action needed:**

| Item | Status | Notes |
|------|--------|-------|
| `sendAsync` promise handling | OK | `clearPendingResponses()` resolves all pending with error objects on disconnect |
| Landscape safe areas | OK | Already handled in `index.css` (safe-area-left, safe-area-right utilities) |
| `startTransition` for expensive updates | N/A | Zustand uses `useSyncExternalStore` internally which handles this |
| 60fps `style.left`/`style.width` animations | Deferred | Timeline components use percentage-based left/width - requires canvas migration for true compositor-only rendering |

### Batch 9: Design System + Code Organization (DONE)

| Issue | Fix | Files Modified |
|-------|-----|----------------|
| Design tokens / CSS variables | Added 129 semantic tokens to `@theme` block, converted all Tailwind color classes | `src/index.css`, ~60 component files |
| On-color text tokens | Added `text-on-primary`, `text-on-success`, etc. for buttons on colored backgrounds | `src/index.css`, ~35 files |
| Unified drag-and-drop | Created `useListReorder` hook with HTML5 drag + touch fallback | `src/hooks/useListReorder.ts` (new), `ReorderSectionsModal.tsx`, `Toolbar.tsx`, `ActionsSection.tsx` |

**Commits:**
- `74abfcd` - Complete CSS design tokens refactor (129 tokens)
- `6f42ffb` - Add on-color text tokens for theme robustness
- `781e156` - Unify drag-and-drop with useListReorder hook

---

## Remaining Items (Priority Order)

### Deferred / Future Work

| Item | Notes | Priority |
|------|-------|----------|
| Canvas-based Timeline rendering | `style.left`/`style.width` at 60fps triggers layout. Canvas would enable compositor-only rendering. Significant refactor. | Medium |
| Service worker for offline caching | Currently relies on HTML mtime check for updates. Not critical for local REAPER connection. | Low |
| Test coverage expansion | 200 source files, 17 test files - prioritize WebSocketConnection, regionEditSlice if needed. | Low |
| Small touch targets (24x24 color swatches) | ColorPickerInput swatches below 44x44 minimum. Rarely used during performance. | Low |
| Frame rate monitoring | No Battery API on iOS Safari - would need indirect detection. | Low |

### Checklist Coverage Summary

**From FRONTEND_PRODUCTION_CHECKLIST_QUERY.md - all sections reviewed:**

| Section | Status | Notes |
|---------|--------|-------|
| 1. Memory Leaks | ✅ Complete | Timer cleanup, pendingResponses, PeaksCache eviction, RAF cleanup |
| 2. Re-render Performance | ✅ Complete | Stable selectors (stableRefs.ts), animation bypass pattern in use |
| 3. WebSocket Lifecycle | ✅ Complete | sendAsync promises resolved on disconnect, reconnection tested |
| 4. TypeScript Strictness | ✅ Complete | Only 4 `as unknown as` uses, all necessary for WS typing |
| 5. Zustand Patterns | ✅ Complete | get() in actions OK, Map mutations create new Maps, localStorage try-catch |
| 6. Touch/Gesture | ✅ Complete | touch-action added, pointer capture error handling, useListReorder unified DnD |
| 7. PWA Issues | ✅ Complete | Safe areas, -webkit-touch-callout, localStorage try-catch. Service worker deferred. |
| 8. Error Boundaries | ✅ Complete | ErrorBoundary added, React 19 error callbacks added |
| 9. Testing Gaps | ⏸️ Deferred | Low priority - current coverage adequate for production |
| 10. Bundle Analysis | ✅ Complete | IconPicker lazy loaded, console.log stripped in prod |
| 11. Accessibility | ✅ Complete | aria-live regions, prefers-reduced-motion, aria-label/pressed on buttons |
| 12. Design System | ✅ Complete | 129 semantic tokens, on-color text tokens, zero Tailwind color classes remaining |

---

## Related Documentation

| Document | Purpose |
|----------|---------|
| `frontend/FRONTEND_DEVELOPMENT.md` | **Best practices guide** - Patterns, anti-patterns, code conventions |
| `research/FRONTEND_PRODUCTION_REVIEW_CHECKLIST.md` | Original audit checklist with grep patterns |
| `research/css-var-refactor.md` | Design token system reference (129 tokens) |
| `src/store/stableRefs.ts` | Stable empty references for Zustand selectors |
| `src/core/WebSocketConnection.ts` | iOS Safari workarounds |

---

## Build & Test Commands

```bash
cd frontend
npm run build          # Production build (strips console.log)
npm run dev            # Dev server
npm run test           # Run tests
npm run lint           # Type check + lint
```

**Bundle size target:** ≤1,050 kB (currently ~1,048 kB)

---

*Last updated: 2026-01-09 - Audit complete. All high-priority items addressed. See `FRONTEND_DEVELOPMENT.md` for implementation guide.*
