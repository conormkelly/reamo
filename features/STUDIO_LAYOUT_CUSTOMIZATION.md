# Studio Layout Customization - Implementation Plan

## Current Status

**Phase**: Sweep and Review (Polish Phase)

**Completed Work**:
- ✅ Phase 1-6: Core infrastructure, section refactoring, drag-to-reorder, Timeline tab removal
- ✅ Removed eye toggle feature (simplified to just collapsible sections)
- ✅ Removed lock layout feature (drag-to-reorder now in modal only)
- ✅ Added ReorderSectionsModal with desktop + mobile touch support
- ✅ Reorganized Settings Menu (Global + Studio sections)
- ✅ Changed "Recording Quick Actions" → "Rec Quick Actions"

**Current Work**: Mobile/desktop review and testing - awaiting user feedback on final polish items before Phase 7 start.

---

## Overview

Transform Studio view into a fully customizable workspace where users can collapse, reorder, and show/hide sections. This solves mobile screen space constraints and eliminates the need for a separate Timeline tab.

---

## Problem Statement

1. **Mobile Screen Real Estate**: Two transports (in-view + PersistentTransport) create visual clutter on phones
2. **Timeline Tab Redundancy**: Studio already contains timeline functionality
3. **Fixed Layout**: Users can't customize which controls they see
4. **No Repeat in PersistentTransport**: TransportBar has Repeat button but can't fit in bottom bar

---

## Solution Architecture

### Collapsible Sections

| Section | Contents | Behavior | Draggable? | Desktop Default | Mobile Default |
|---------|----------|----------|------------|-----------------|----------------|
| **Header** | Connection, Metronome, Tap Tempo, Time Sig | Always visible (pinned top) | ❌ No | N/A | N/A |
| **Project** | Time Display + TransportBar + Undo/Redo/Save | Collapsible | ✅ Yes | **EXPANDED** | **COLLAPSED** |
| **Toolbar** | User-configurable action buttons | Collapsible | ✅ Yes | **EXPANDED** | **COLLAPSED** |
| **Timeline** | Regions/Markers/Items timeline | Collapsible | ✅ Yes | **EXPANDED** | **EXPANDED** ⭐ |
| **Mixer** | Track strips with faders/meters | Collapsible | ✅ Yes | **EXPANDED** | **COLLAPSED** |
| **Recording Actions** | Scrap, Retake, Keep buttons | Auto-shows during recording | ❌ No | N/A | N/A |

**Mobile Strategy**: Show ONLY Timeline expanded by default → users see arrangement, rely on PersistentTransport for controls

**Desktop Strategy**: Show all sections expanded by default → full-featured workspace

**Pinned Positions**:
- Header: Always top
- Recording Actions: Desktop/tablet = normal flow, Mobile = floating above bottom nav bars

---

## State Management

### Zustand Store Slice

**File**: `frontend/src/store/slices/studioLayoutSlice.ts`

```typescript
interface SectionConfig {
  collapsed: boolean;
  order: number;
}

interface StudioLayoutState {
  sections: {
    project: SectionConfig;
    toolbar: SectionConfig;
    timeline: SectionConfig;
    mixer: SectionConfig;
  };
  hideCollapsed: boolean; // Eye toggle state
  showRecordingActions: boolean; // Burger menu setting
  layoutLocked: boolean; // Lock layout toggle (Studio view only)

  // Actions
  toggleSection: (id: SectionId) => void;
  setHideCollapsed: (hide: boolean) => void;
  setShowRecordingActions: (show: boolean) => void;
  setLayoutLocked: (locked: boolean) => void;
  reorderSections: (fromIndex: number, toIndex: number) => void;
  loadLayoutFromStorage: () => void;
  saveLayoutToStorage: () => void;
}
```

**localStorage Key**: `reamo_studio_layout`

**Mobile Defaults** (on first load if width ≤ 768px):
```typescript
{
  sections: {
    project: { collapsed: true, order: 0 },
    toolbar: { collapsed: true, order: 1 },
    timeline: { collapsed: false, order: 2 },  // ⭐ Only expanded
    mixer: { collapsed: true, order: 3 }
  },
  hideCollapsed: false,
  showRecordingActions: true,
  layoutLocked: false
}
```

---

## UI Components

### 1. CollapsibleSection Component

**File**: `frontend/src/components/Studio/CollapsibleSection.tsx`

Reusable wrapper for all collapsible sections.

```typescript
interface CollapsibleSectionProps {
  id: 'project' | 'toolbar' | 'timeline' | 'mixer';
  title: string;
  collapsed: boolean;
  locked: boolean; // Hide drag handles and chevron when true
  onToggle: () => void;
  headerControls?: ReactNode;
  children: ReactNode;
  draggable?: boolean;
  onDragStart?: () => void;
  onDragOver?: () => void;
  onDragEnd?: () => void;
  isDragTarget?: boolean;
}
```

**Key Behaviors**:
- When `locked=true`: Hide drag handles AND collapse chevrons (section frozen)
- When `locked=false`: Show drag handles (GripVertical icon) and chevrons
- Conditional render: `{!collapsed && children}`

### 2. ProjectSection Component

**File**: `frontend/src/components/Studio/ProjectSection.tsx`

Combines Time Display + TransportBar + Undo/Redo/Save into one section.

```typescript
export function ProjectSection() {
  const { toasts, showUndo, showRedo, dismissToast } = useToast();

  return (
    <>
      <div className="flex justify-center mb-4">
        <TimeDisplay format="both" />
      </div>

      <div className="mb-4">
        <TransportBar className="mb-3" />
        <div className="flex flex-wrap items-center justify-center gap-2">
          <UndoButton onUndo={showUndo} />
          <RedoButton onRedo={showRedo} />
          <SaveButton />
        </div>
      </div>
    </>
  );
}
```

### 3. Eye Toggle (Show/Hide Collapsed Sections)

**Location**: App header, top-left, right of burger menu

```tsx
<div className="absolute top-3 left-3 z-50 flex items-center gap-2">
  <SettingsMenu {...props} />
  <button
    onClick={toggleHideCollapsed}
    className="p-2 rounded bg-gray-800 hover:bg-gray-700 transition-colors"
    title={hideCollapsed ? "Show collapsed sections" : "Hide collapsed sections"}
  >
    {hideCollapsed ? <EyeOff size={20} /> : <Eye size={20} />}
  </button>
</div>
```

**Behavior**:
- Eye open (default): Collapsed sections show chevron header, can be expanded
- Eye closed: Collapsed sections completely hidden from DOM

### 4. "All Sections Hidden" Empty State

When `hideCollapsed=true` and all sections are collapsed:

```tsx
<div className="flex flex-col items-center justify-center py-20 text-gray-500">
  <button
    onClick={() => setHideCollapsed(false)}
    className="flex flex-col items-center gap-4 hover:text-gray-400 transition-colors"
  >
    <EyeOff size={64} />
    <span className="text-lg">All sections hidden</span>
  </button>
</div>
```

**Behavior**: Large clickable eye icon that toggles `hideCollapsed` back to false

### 5. Settings Menu Additions

**Lock Layout Checkbox** (only visible when `currentView === 'studio'`):

```tsx
{currentView === 'studio' && (
  <label className="flex items-center gap-2 cursor-pointer">
    <input
      type="checkbox"
      checked={layoutLocked}
      onChange={onToggleLayoutLock}
      className="..."
    />
    <span>Lock layout</span>
  </label>
)}
```

**Show Recording Actions Checkbox**:

```tsx
<label className="flex items-center gap-2 cursor-pointer">
  <input
    type="checkbox"
    checked={showRecordingActions}
    onChange={onToggleRecordingActions}
    className="..."
  />
  <span>Show recording quick actions</span>
</label>
```

### 6. Recording Actions Bar - Mobile Positioning

**Current**: Rendered in normal document flow (iPad/desktop)

**New**: Conditional positioning based on device width

```tsx
// In StudioView or App.tsx
const isMobile = useMediaQuery('(max-width: 768px)');
const showRecordingActions = useReaperStore((s) => s.showRecordingActions);

{isMobile && showRecordingActions ? (
  // Mobile: Fixed positioning above bottom nav bars
  <div
    className="fixed bottom-0 left-0 right-0 z-40"
    style={{
      bottom: `calc(${tabBarHeight}px + ${persistentTransportHeight}px)`
    }}
  >
    <RecordingActionsBar />
  </div>
) : (
  // Desktop/tablet: Normal document flow
  showRecordingActions && <RecordingActionsBar className="mb-6" />
)}
```

**Mobile Visual Stack** (when recording):
```
┌────────────────────────────────┐
│  Main content                  │
├────────────────────────────────┤ ← Recording Actions (floating)
│  [Scrap] [Retake] [Keep]       │
├────────────────────────────────┤ ← Tab Bar
│ Studio | Mixer | Clock | ...   │
├────────────────────────────────┤ ← Persistent Transport
│ ◄◄ ▶ ❚❚ ⏹ ⏺  17.3.2  120 BPM  │
└────────────────────────────────┘
```

---

## StudioView Refactor

### Key Changes

**Before**: Local state for collapse (`useState`), sections in fixed order

**After**: Zustand store for collapse, sections ordered by `order` field, drag-to-reorder

### New Structure

```tsx
export function StudioView() {
  const [trackFilter, setTrackFilter] = useState('');

  // Section state from Zustand
  const {
    sections,
    hideCollapsed,
    layoutLocked,
    toggleSection,
    reorderSections,
    loadLayoutFromStorage
  } = useStudioLayout();

  // Load layout on mount
  useEffect(() => {
    loadLayoutFromStorage();
  }, []);

  // Build ordered sections array
  const orderedSections = useMemo(() => {
    return [
      { id: 'project', component: ProjectSection, title: 'Project', headerControls: null },
      { id: 'toolbar', component: Toolbar, title: 'Toolbar', headerControls: null },
      { id: 'timeline', component: Timeline, title: 'Timeline', headerControls: <TimelineModeToggle /> },
      { id: 'mixer', component: Mixer, title: 'Mixer', headerControls: null }
    ].sort((a, b) => sections[a.id].order - sections[b.id].order);
  }, [sections]);

  // Filter out collapsed sections if hideCollapsed is true
  const visibleSections = useMemo(() => {
    return orderedSections.filter(s =>
      !hideCollapsed || !sections[s.id].collapsed
    );
  }, [orderedSections, hideCollapsed, sections]);

  // Drag state
  const [dragFromIndex, setDragFromIndex] = useState<number | null>(null);
  const [dragOverIndex, setDragOverIndex] = useState<number | null>(null);

  const handleDragStart = (index: number) => setDragFromIndex(index);
  const handleDragOver = (index: number) => setDragOverIndex(index);
  const handleDragEnd = () => {
    if (dragFromIndex !== null && dragOverIndex !== null && dragFromIndex !== dragOverIndex) {
      reorderSections(dragFromIndex, dragOverIndex);
    }
    setDragFromIndex(null);
    setDragOverIndex(null);
  };

  return (
    <div className="min-h-screen bg-gray-950 text-white p-4">
      {/* Header - always visible */}
      <header className="flex items-center justify-end mb-4">
        <div className="flex items-center gap-3">
          <MetronomeButton />
          <TapTempoButton />
          <TimeSignatureButton />
          <ConnectionStatus />
        </div>
      </header>

      {/* Draggable sections */}
      {visibleSections.length > 0 ? (
        visibleSections.map((section, index) => (
          <CollapsibleSection
            key={section.id}
            id={section.id}
            title={section.title}
            collapsed={sections[section.id].collapsed}
            locked={layoutLocked}
            onToggle={() => toggleSection(section.id)}
            draggable={!layoutLocked}
            onDragStart={() => handleDragStart(index)}
            onDragOver={() => handleDragOver(index)}
            onDragEnd={handleDragEnd}
            isDragTarget={dragOverIndex === index && dragFromIndex !== index}
            headerControls={section.headerControls}
          >
            <section.component />
          </CollapsibleSection>
        ))
      ) : (
        // Empty state when all sections hidden
        <div className="flex flex-col items-center justify-center py-20 text-gray-500">
          <button
            onClick={() => setHideCollapsed(false)}
            className="flex flex-col items-center gap-4 hover:text-gray-400 transition-colors"
          >
            <EyeOff size={64} />
            <span className="text-lg">All sections hidden</span>
          </button>
        </div>
      )}

      {/* Recording Actions - positioning handled in component */}
      <RecordingActionsBar />

      <footer className="mt-8 text-center text-gray-600 text-sm">
        REAmo - REAPER Web Control
      </footer>

      {/* Modals */}
      <AddRegionModal isOpen={showAddRegionModal} onClose={() => setShowAddRegionModal(false)} />
      <MakeSelectionModal isOpen={showMakeSelectionModal} onClose={() => setShowMakeSelectionModal(false)} />
      <ToastContainer toasts={toasts} onDismiss={dismissToast} />
    </div>
  );
}
```

---

## Component Refactors

### Timeline Component

**Before**: Internal collapse state
```tsx
const [timelineCollapsed, setTimelineCollapsed] = useState(false);
```

**After**: Receives collapsed prop, remove internal state
```tsx
export function Timeline() {
  // No collapse state - handled by parent via CollapsibleSection wrapper
  return (
    <>
      <Timeline height={80} />
      <RegionInfoBar />
      <RegionEditActionBar />
    </>
  );
}
```

### Mixer Component

**Before**: Internal collapse state
```tsx
const [mixerCollapsed, setMixerCollapsed] = useState(false);
```

**After**: Receives collapsed prop, remove internal state
```tsx
export function Mixer() {
  // No collapse state - handled by parent via CollapsibleSection wrapper
  return (
    <>
      <TrackFilter />
      <MixerLockButton />
      <TrackList />
    </>
  );
}
```

### Toolbar Component

**Before**: `toolbarCollapsed` in its own slice
```tsx
const { toolbarCollapsed, setToolbarCollapsed } = useReaperStore();
```

**After**: Collapse state migrated to unified `studioLayoutSlice`, Toolbar becomes pure presentation
```tsx
export function Toolbar() {
  // No collapse state - handled by parent via CollapsibleSection wrapper
  // Keep edit mode, actions, alignment, etc. internal to Toolbar
  return (
    <div className="flex gap-2 overflow-x-auto">
      {toolbarActions.map(action => <ToolbarButton key={action.id} action={action} />)}
    </div>
  );
}
```

---

## View Registry Update

**Remove Timeline tab** (functionality merged into Studio view):

```typescript
// viewRegistry.ts
export const views = {
  studio: StudioView,
  // timeline: TimelineView, ← REMOVED
  mixer: MixerView,
  clock: ClockView,
  cues: CuesView,
  actions: ActionsView,
  notes: NotesView,
} as const;
```

**Update TabBar** to reflect removed Timeline tab.

---

## Implementation Phases

> **⚠️ TESTING REMINDER**: After completing each phase, run:
> - `npm run test` (Vitest unit tests)
>
> E2E tests (`npm run test:e2e`) only run in Phase 7, as they require updates to work with the new collapsible sections pattern.

---

### Phase 1: Core Infrastructure
**Goal**: State management + CollapsibleSection component

**Tasks**:
1. Create `studioLayoutSlice.ts` with all state and actions
2. Integrate slice into main Zustand store
3. Create `<CollapsibleSection>` component with drag/lock support
4. Create `<ProjectSection>` component
5. Test localStorage persistence and mobile defaults
6. **Run Vitest tests**

**Files Changed**:
- `frontend/src/store/slices/studioLayoutSlice.ts` (new)
- `frontend/src/store/index.ts` (integrate slice)
- `frontend/src/components/Studio/CollapsibleSection.tsx` (new)
- `frontend/src/components/Studio/ProjectSection.tsx` (new)

### Phase 2: Refactor Existing Sections
**Goal**: Migrate Timeline/Mixer/Toolbar to new pattern

**Tasks**:
1. Refactor Timeline: Remove local collapse state
2. Refactor Mixer: Remove local collapse state
3. Refactor Toolbar: Migrate collapse state to `studioLayoutSlice`
4. Update StudioView to use ordered sections pattern
5. Test all sections still work correctly
6. **Run Vitest tests**

**Files Changed**:
- `frontend/src/components/Timeline/Timeline.tsx`
- `frontend/src/components/Mixer/Mixer.tsx` (if it exists, or handle in StudioView)
- `frontend/src/components/Toolbar/Toolbar.tsx`
- `frontend/src/views/studio/StudioView.tsx`

### Phase 3: Drag-to-Reorder
**Goal**: Sections can be reordered via drag-and-drop

**Tasks**:
1. Add drag handlers to `<CollapsibleSection>` (touch-friendly)
2. Implement `reorderSections` logic in slice
3. Visual feedback during drag (border highlight)
4. Test reordering saves to localStorage
5. Test touch drag on actual mobile device
6. **Run Vitest tests**

**Files Changed**:
- `frontend/src/components/Studio/CollapsibleSection.tsx`
- `frontend/src/store/slices/studioLayoutSlice.ts`
- `frontend/src/views/studio/StudioView.tsx`

### Phase 4: Eye Toggle & Lock Mode
**Goal**: Hide collapsed sections + lock layout feature

**Tasks**:
1. Add eye toggle button in App header (next to burger menu)
2. Wire up `hideCollapsed` state
3. Filter sections in StudioView when `hideCollapsed` is true
4. Add "All sections hidden" empty state with clickable eye
5. Add "Lock layout" checkbox to SettingsMenu (Studio view only)
6. Wire up `layoutLocked` state
7. Update CollapsibleSection to hide drag handles/chevrons when locked
8. **Run Vitest tests**

**Files Changed**:
- `frontend/src/App.tsx` (add eye toggle)
- `frontend/src/components/SettingsMenu.tsx` (add lock checkbox)
- `frontend/src/views/studio/StudioView.tsx` (filter sections, empty state)
- `frontend/src/components/Studio/CollapsibleSection.tsx` (lock behavior)

### Phase 5: Recording Actions & Settings
**Goal**: Settings menu additions + mobile positioning

**Tasks**:
1. Add "Show recording quick actions" checkbox to SettingsMenu
2. Wire up `showRecordingActions` state
3. Implement mobile positioning for RecordingActionsBar
4. Calculate heights for tab bar + persistent transport
5. Test mobile layout (stacked correctly)
6. Test desktop/tablet layout (normal flow)
7. **Run Vitest tests**

**Files Changed**:
- `frontend/src/components/SettingsMenu.tsx`
- `frontend/src/components/Transport/RecordingActionsBar.tsx`
- `frontend/src/views/studio/StudioView.tsx` or `frontend/src/App.tsx`

### Phase 6: View Cleanup
**Goal**: Remove Timeline tab

**Tasks**:
1. Remove Timeline view from `viewRegistry.ts`
2. Update TabBar component (remove Timeline tab)
3. Test tab bar still works correctly
4. Ensure Studio view is default view
5. Test view switching
6. **Run Vitest tests**

**Files Changed**:
- `frontend/src/viewRegistry.ts`
- `frontend/src/components/TabBar.tsx`

**Files Removed**:
- `frontend/src/views/timeline/TimelineView.tsx`
- `frontend/src/views/timeline/index.ts`

### Phase 7: Polish & Testing
**Goal**: Edge cases, responsive behavior, documentation, E2E test fixes

**Tasks**:
1. Handle empty sections gracefully
2. Add touch-friendly drag feedback
3. Keyboard accessibility for collapse toggles
4. Test on actual devices (iPhone, iPad)
5. Add "Reset to defaults" option in settings menu
6. Update DEVELOPMENT.md with new patterns
7. Update PLANNED_FEATURES.md (remove Timeline tab item)
8. **Fix E2E tests** - Update timeline tests to expand Timeline section before interacting
9. **Run full Vitest and Playwright test suites**
10. **Manual testing on mobile/tablet/desktop**

---

## Edge Cases & Fallbacks

### 1. Corrupted localStorage
- Catch JSON parse error → fall back to defaults → log warning

### 2. All Sections Collapsed + Eye Closed
- Show empty state: "All sections hidden" + clickable eye icon → toggles `hideCollapsed` to false

### 3. Drag on Touch Devices
- Use touch event handlers (`onTouchStart`, `onTouchMove`, `onTouchEnd`)
- Visual drag handle icon (`GripVertical`)
- Test on actual iOS Safari/Chrome

### 4. Recording Actions When Setting OFF
- Component returns `null` → takes up no space
- Expected behavior for users who disable it

### 5. Mobile Width Changes (Orientation)
- Layout state persists (user customization takes precedence)
- Defaults only apply on FIRST load per device

### 6. Lock Mode When Dragging
- If user locks layout mid-drag → cancel drag operation
- Reset `dragFromIndex` and `dragOverIndex` to null

---

## Testing Strategy

### Unit Tests

**`studioLayoutSlice.test.ts`**:
- Toggle section collapse state
- Reorder sections
- Save/load from localStorage
- Mobile defaults on first load
- Lock mode prevents reordering

**`CollapsibleSection.test.tsx`**:
- Renders collapsed/expanded correctly
- Calls onToggle when chevron clicked
- Shows/hides children based on collapsed prop
- Drag events fire correctly
- Lock mode hides drag handles and chevrons

### Integration Tests

**`StudioView.test.tsx`**:
- All sections render in correct order
- Eye toggle filters out collapsed sections
- Empty state appears when all sections hidden
- Recording actions bar appears during recording (if setting enabled)
- Mobile: Recording actions positioned above bottom nav

### Manual Testing

- [ ] iPad: All sections except Timeline collapsed by default
- [ ] iPhone portrait: Only Timeline expanded by default
- [ ] iPhone landscape: Layout persists from portrait
- [ ] Collapse Project section → rely on PersistentTransport
- [ ] Expand Project section → hide PersistentTransport via settings
- [ ] Drag sections to reorder → reload page → order persists
- [ ] Close eye toggle → collapsed sections disappear
- [ ] Open eye toggle → collapsed sections reappear as headers
- [ ] Click eye icon in empty state → sections reappear
- [ ] Enable lock layout → drag handles and chevrons hidden
- [ ] Disable lock layout → drag handles and chevrons visible
- [ ] Toggle "Show recording quick actions" → bar appears/disappears
- [ ] Mobile: Recording actions float above bottom nav
- [ ] Desktop: Recording actions in normal flow

---

## Critical Files Summary

### New Files
- `frontend/src/store/slices/studioLayoutSlice.ts`
- `frontend/src/components/Studio/CollapsibleSection.tsx`
- `frontend/src/components/Studio/ProjectSection.tsx`

### Modified Files
- `frontend/src/store/index.ts` (integrate slice)
- `frontend/src/views/studio/StudioView.tsx` (major refactor)
- `frontend/src/components/Timeline/Timeline.tsx` (remove collapse state)
- `frontend/src/components/Toolbar/Toolbar.tsx` (remove collapse state)
- `frontend/src/components/SettingsMenu.tsx` (add checkboxes)
- `frontend/src/components/Transport/RecordingActionsBar.tsx` (mobile positioning)
- `frontend/src/App.tsx` (add eye toggle)
- `frontend/src/viewRegistry.ts` (remove Timeline view)
- `frontend/src/components/TabBar.tsx` (remove Timeline tab)

### Removed Files
- `frontend/src/views/timeline/TimelineView.tsx`
- `frontend/src/views/timeline/index.ts`

---

## Notes

- **No migration path needed**: Prerelease app, no existing users
- **Lock mode solves drag handle visibility**: When unlocked, handles always visible; when locked, handles and chevrons hidden
- **Per-device customization**: Layout preferences stored in localStorage per device (iPad vs phone have different needs)
- **Mobile-first defaults**: Only Timeline expanded on mobile → users see arrangement, use persistent transport for controls
