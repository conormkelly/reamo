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

---

## Remaining Items (Priority Order)

### Medium Priority

| Item | Risk | Notes |
|------|------|-------|
| Lazy-load IconPicker | Bundle size (~1900 icons loaded when modal opens) | Use React.lazy() |
| Check Map mutation patterns | Won't trigger re-renders | `rg "\.set\(" src/store/slices/` |
| Actions using get() vs closure capture | Stale state bugs | `rg "set\(\(state\)" src/store/slices/` |

### Low Priority / Nice to Have

| Item | Notes |
|------|-------|
| Add more aria-live regions for real-time updates | Currently none |
| Service worker for offline caching | Currently relies on HTML mtime check for updates |
| useShallow for multi-value selectors | Not currently needed (no array destructuring found) |

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

*Last updated: Session completed Batch 1 + Batch 2 + Batch 3*
