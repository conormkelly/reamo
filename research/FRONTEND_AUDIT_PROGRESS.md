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
| ActionButton.tsx has 9 components (567 lines) | Split into separate files | `ActionButton.tsx` (base only, 94 lines), `MetronomeButton.tsx` (new), `MarkerButtons.tsx` (new), `UndoRedoButtons.tsx` (new), `SaveButton.tsx` (new), `index.ts` (updated exports) |

---

## Remaining Items (Priority Order)

### Low Priority / Nice to Have

| Item | Notes |
|------|-------|
| Service worker for offline caching | Currently relies on HTML mtime check for updates |
| useShallow for multi-value selectors | Not currently needed (no array destructuring found) |
| Test coverage expansion | 200 source files, 17 test files - prioritize WebSocketConnection, regionEditSlice |

---

## Key Files to Read

When continuing this audit, read these files for context:

1. **This file** - `research/FRONTEND_AUDIT_PROGRESS.md`
2. **Full checklist** - `research/FRONTEND_PRODUCTION_REVIEW_CHECKLIST.md`
3. **Original research query** - `research/FRONTEND_PRODUCTION_CHECKLIST_QUERY.md`
4. **Stable refs module** - `src/store/stableRefs.ts`
5. **WebSocket connection** - `src/core/WebSocketConnection.ts` (iOS Safari workarounds)
6. **Store structure** - `src/store/index.ts` (17 slices)

---

## Build & Test Commands

```bash
cd frontend
npm run build          # Production build (strips console.log)
npm run dev            # Dev server
npm run test           # Run tests
npm run lint           # Type check + lint
```

**Bundle size target:** ~1.0MB (currently 1,038 kB - acceptable)

---

## Notes for Future Sessions

1. **Timer cleanup pattern** - All gesture hooks should have:
   ```typescript
   useEffect(() => {
     return () => {
       if (timerRef.current) clearTimeout(timerRef.current);
     };
   }, []);
   ```

2. **Stable selector pattern** - Use frozen refs for fallbacks:
   ```typescript
   // BAD: Creates new object each render
   const tracks = useReaperStore((s) => s?.tracks ?? {});

   // GOOD: Uses stable reference
   const tracks = useReaperStore((s) => s?.tracks ?? EMPTY_TRACKS);
   ```

3. **iOS Safari quirks** - WebSocketConnection.ts has extensive workarounds. Don't remove:
   - Iframe warmup for NSURLSession lazy init
   - Focus cycle trick for PWA cold start
   - CONNECTING state timeout (5s) for frozen sockets
   - Force reconnect on visibility return

---

*Last updated: Session completed Batch 1-7 (all high-priority items complete)*
