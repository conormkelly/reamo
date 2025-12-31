# View Switcher Migration Plan

> **Purpose:** Step-by-step migration guide for implementing the View Switcher feature.
> This document is designed to be picked up by a fresh Claude instance if context is lost.
> Update this document after every discovery or decision.

**Target spec:** [features/VIEW_SWITCHER_FEATURE.md](features/VIEW_SWITCHER_FEATURE.md)

---

## Current State Analysis

**Last updated:** 2024-12-31

### Entry Point Flow

```
main.tsx
  └── App.tsx
        └── ReaperProvider (WebSocket context)
              └── AppContent (THE ENTIRE UI)
```

### Key Files

| File | Purpose | Lines |
|------|---------|-------|
| `frontend/src/App.tsx` | Root component, contains `AppContent` which IS the Studio view | ~300 |
| `frontend/src/main.tsx` | React entry point, renders `<App />` | ~10 |
| `frontend/src/components/ReaperProvider.tsx` | WebSocket connection context | ~47 |
| `frontend/src/store/index.ts` | Zustand store combining all slices | ~310 |

### Current AppContent Structure (will become StudioView)

```tsx
// App.tsx lines 121-289
function AppContent() {
  // Local state
  const [trackFilter, setTrackFilter] = useState('');
  const [showAddRegionModal, setShowAddRegionModal] = useState(false);
  const [showMakeSelectionModal, setShowMakeSelectionModal] = useState(false);
  const [mixerCollapsed, setMixerCollapsed] = useState(false);
  const [timelineCollapsed, setTimelineCollapsed] = useState(false);

  // Store access
  const timelineMode = useReaperStore((s) => s.timelineMode);
  const regions = useReaperStore((s) => s.regions);
  const timeSelection = useReaperStore((s) => s.timeSelection);
  const { toasts, showUndo, showRedo, dismissToast } = useToast();

  return (
    <div className="min-h-screen bg-gray-950 text-white p-4">
      {/* Header: Connection + Tempo */}
      {/* Time Display */}
      {/* Transport Controls */}
      {/* Recording Quick Actions */}
      {/* Toolbar */}
      {/* Timeline */}
      {/* Marker Info & Navigation */}
      {/* Mixer */}
      {/* Footer */}
      {/* Modals */}
      {/* Toast notifications */}
    </div>
  );
}
```

### Component Organization

```
frontend/src/components/
├── index.ts                 # Re-exports everything
├── ReaperProvider.tsx       # WebSocket context (stays at App level)
├── ConnectionStatus.tsx     # Connection indicator
├── Toast/                   # Toast notifications
├── Transport/               # TransportBar, TimeDisplay, PlayButton, etc.
├── Track/                   # TrackStrip, Fader, LevelMeter, etc.
├── Markers/                 # MarkerNavigation, MarkerInfoBar
├── Regions/                 # RegionDisplay, RegionNavigation
├── Actions/                 # ActionButton, TapTempoButton, etc.
├── Timeline/                # Timeline, TimelineMarkers, etc.
├── ItemsTimeline/           # Items mode timeline
└── Toolbar/                 # User-configurable toolbar
```

### State Management

**Zustand store slices:**
- `connectionSlice` - WebSocket connection state
- `transportSlice` - play/stop/record, position, BPM
- `projectSlice` - project-level settings, undo/redo
- `tracksSlice` - track list, meters, selection
- `regionsSlice` - region list
- `markersSlice` - marker list
- `regionEditSlice` - region editing mode state
- `itemsSlice` - item data for Items timeline
- `toolbarSlice` - user toolbar configuration

**Key insight:** Store is accessed via `useReaperStore()` hook throughout components. No changes needed to state management for view switching.

### Transport Components (already exist)

| Component | Purpose | Can reuse? |
|-----------|---------|------------|
| `TransportBar` | Play/Stop/Record buttons row | Yes - use directly in PersistentTransport |
| `TimeDisplay` | Position display (bars.beats or time) | Yes |
| `PlayButton`, `StopButton`, `RecordButton` | Individual transport buttons | Yes |
| `RecordingActionsBar` | Quick actions during recording | No - Studio-specific |

**TransportBar Details** (from `components/Transport/TransportBar.tsx`):

```
Buttons: SkipBack | Play | Pause | Loop | Stop | Record
```

- Uses 44x44px round buttons
- Play/Pause/Stop/Record have active states (color changes)
- Record has long-press for auto-punch mode toggle
- Uses `useTransport()` hook for state and commands
- Uses `useReaper()` for sendCommand

**This is exactly what PersistentTransport needs.** Just add TimeDisplay beside it.

---

## Migration Strategy

### Phase 0: Preparation (No Code Changes)

- [x] Audit current architecture
- [x] Document file structure
- [x] Identify what moves where
- [ ] Create this migration plan (in progress)

### Phase 1: Create View Infrastructure

**Goal:** Set up folder structure and view registry without breaking anything.

1. Create folder structure:
   ```
   frontend/src/
   ├── views/
   │   ├── studio/
   │   │   ├── StudioView.tsx      # Move AppContent here
   │   │   └── index.ts
   │   ├── timeline/
   │   │   ├── TimelineView.tsx    # Placeholder
   │   │   └── index.ts
   │   ├── mixer/
   │   │   ├── MixerView.tsx       # Placeholder
   │   │   └── index.ts
   │   ├── clock/
   │   │   ├── ClockView.tsx       # Placeholder
   │   │   └── index.ts
   │   ├── cues/
   │   │   ├── CuesView.tsx        # Placeholder
   │   │   └── index.ts
   │   ├── actions/
   │   │   ├── ActionsView.tsx     # Placeholder
   │   │   └── index.ts
   │   └── notes/
   │       ├── NotesView.tsx       # Placeholder
   │       └── index.ts
   └── viewRegistry.ts
   ```

2. Create `viewRegistry.ts`:
   ```typescript
   import { StudioView } from './views/studio';
   // ... other imports (placeholders initially)

   export const views = {
     studio: StudioView,
     timeline: () => <div>Timeline View - Coming Soon</div>,
     // ... etc
   } as const;

   export type ViewId = keyof typeof views;
   ```

3. Create placeholder views - simple components that just render a title

### Phase 2: Extract StudioView

**Goal:** Move `AppContent` to `StudioView` with zero functional changes.

1. Create `views/studio/StudioView.tsx`:
   - Copy entire `AppContent` function
   - Copy helper components (`TrackList`, `TrackStripWithMeter`, `MixerLockButton`, `UnselectAllTracksButton`)
   - Update imports

2. Create `views/studio/index.ts`:
   ```typescript
   export { StudioView } from './StudioView';
   ```

3. Update `App.tsx`:
   - Import `StudioView`
   - Replace `<AppContent />` with `<StudioView />`
   - **Test:** App should work identically

### Phase 3: Add View Switching

**Goal:** Add TabBar and view switching, still showing only StudioView.

1. Create `components/TabBar.tsx`:
   ```typescript
   interface TabBarProps {
     currentView: ViewId;
     onViewChange: (view: ViewId) => void;
   }
   ```

2. Create `components/PersistentTransport.tsx`:
   - Extract minimal transport: play/pause/stop/record + time display
   - Can reuse existing `TransportBar` components

3. Update `App.tsx`:
   - Add `currentView` state with localStorage persistence
   - Add view switching logic
   - Render: ViewComponent + TabBar + PersistentTransport

4. **Test:** Should be able to tap tabs, StudioView shows for all (others are placeholders)

### Phase 4: Implement Other Views

Implement one at a time:

1. **MixerView** - Extract mixer section from StudioView
2. **ClockView** - Big transport buttons (new UI)
3. **TimelineView** - Arrangement visualization (new feature)
4. **CuesView** - Region list (see CUE_LIST_FEATURE.md)
5. **ActionsView** - Quick action grid (new UI)
6. **NotesView** - Project notes (new feature)

### Phase 5: Full Screen Mode

Add double-tap to toggle full screen per view.

---

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2024-12-31 | StudioView = current AppContent exactly | Zero-risk migration, works immediately |
| 2024-12-31 | No react-router | Overkill for control surface, state-based simpler |
| 2024-12-31 | Keep Zustand store unchanged | Views access same store, no refactoring needed |
| 2024-12-31 | Studio as default view | "Radically simple" - everything works out of box |

---

## Open Questions

1. **PersistentTransport extraction:** ✅ RESOLVED
   - **Finding:** `TransportBar` is already minimal! Contains: Skip, Play, Pause, Loop, Stop, Record
   - Undo/Redo/Save are separate components rendered in AppContent, NOT in TransportBar
   - **Decision:** PersistentTransport = TransportBar + TimeDisplay + BPM display
   - Just need to compose these in a new wrapper component

2. **StudioView transport redundancy:**
   - StudioView has its own transport section (TransportBar + Undo/Redo/Save)
   - When in Studio view, persistent transport at bottom would be redundant
   - **Options:**
     a) Hide persistent transport in Studio view
     b) Accept redundancy (consistent UX)
     c) Remove transport from StudioView (use persistent only)
   - **Tentative:** Option (a) - hide persistent transport in Studio view
   - **Alternative:** Keep both, Studio users might like the bigger touch targets in the main area

3. **Header (Connection status, tempo, etc.):**
   - Currently in AppContent header: MetronomeButton, TapTempoButton, TimeSignatureButton, ConnectionStatus
   - Should this move to a global header above views?
   - Or stay per-view?
   - **Tentative:** Keep in StudioView for now, revisit later
   - **Note:** Some of these (ConnectionStatus) might make sense globally

---

## File Change Checklist

### New Files to Create

- [ ] `frontend/src/views/studio/StudioView.tsx`
- [ ] `frontend/src/views/studio/index.ts`
- [ ] `frontend/src/views/timeline/TimelineView.tsx`
- [ ] `frontend/src/views/timeline/index.ts`
- [ ] `frontend/src/views/mixer/MixerView.tsx`
- [ ] `frontend/src/views/mixer/index.ts`
- [ ] `frontend/src/views/clock/ClockView.tsx`
- [ ] `frontend/src/views/clock/index.ts`
- [ ] `frontend/src/views/cues/CuesView.tsx`
- [ ] `frontend/src/views/cues/index.ts`
- [ ] `frontend/src/views/actions/ActionsView.tsx`
- [ ] `frontend/src/views/actions/index.ts`
- [ ] `frontend/src/views/notes/NotesView.tsx`
- [ ] `frontend/src/views/notes/index.ts`
- [ ] `frontend/src/viewRegistry.ts`
- [ ] `frontend/src/components/TabBar.tsx`
- [ ] `frontend/src/components/PersistentTransport.tsx`

### Files to Modify

- [ ] `frontend/src/App.tsx` - remove AppContent, add view switching
- [ ] `frontend/src/components/index.ts` - export new components

### Files to Keep (No Changes Needed)

- `frontend/src/main.tsx` - entry point unchanged
- `frontend/src/store/index.ts` - store unchanged
- `frontend/src/components/ReaperProvider.tsx` - context unchanged
- All existing component files - they'll be imported by views

---

## Current Progress

**Status:** Phase 0 - COMPLETE ✅

**Next step:** Phase 1 - Create view folder structure and viewRegistry.ts

**Ready to start:** Yes - all analysis done, architecture understood, plan documented

---

## Notes for Future Claude

1. **Read this document first** when resuming work
2. The spec is at `features/VIEW_SWITCHER_FEATURE.md`
3. Current app works - don't break it during migration
4. StudioView should be a copy-paste of AppContent initially
5. Test after each phase before proceeding
6. Update this document after every change
