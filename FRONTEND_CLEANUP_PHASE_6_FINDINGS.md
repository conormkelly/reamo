# Phase 6 Findings: RoutingModal Giant Component Analysis

## 1. Current Structure Analysis

### File Overview
- **Location:** `frontend/src/components/Mixer/RoutingModal.tsx`
- **Total LOC:** 1,319
- **Exports:** `RoutingModal`, `RoutingModalProps`

### Import Summary (lines 1-14)
| Category | Imports |
|----------|---------|
| React | useState, useMemo, useCallback, useRef, useEffect, ReactElement |
| Icons | Volume2, VolumeX (lucide-react) |
| Components | BottomSheet |
| Hooks | useTrack, useTrackSkeleton, useReaper |
| Store | useReaperStore, getSendsFromTrack, getSendsToTrack |
| Commands | send, receive, hw, gesture, routing (from WebSocketCommands) |
| Utils | volumeToDbString, faderToVolume, volumeToFader |

### Component Tree Diagram
```
RoutingModal (lines 1056-1318, ~263 LOC)
├── BottomSheet wrapper
│   ├── Header - title with track name
│   ├── Tab selector - 3 buttons (Sends/Receives/Hardware)
│   └── Scrollable content
│       ├── Sends tab
│       │   ├── Empty state (if no sends)
│       │   └── HorizontalSendFader[] (mapped)
│       ├── Receives tab
│       │   ├── Empty state (if no receives)
│       │   └── HorizontalReceiveFader[] (mapped)
│       └── Hardware tab
│           ├── Loading state
│           ├── Empty state
│           └── HwOutputRow[] (mapped)
└── Footer - summary counts
```

### Inline Components Found

| Component | Lines | LOC | Purpose |
|-----------|-------|-----|---------|
| `HorizontalSendFader` | 44-372 | 329 | Volume/pan fader row for sends |
| `HorizontalReceiveFader` | 377-705 | 329 | Volume/pan fader row for receives |
| `HwOutputRow` | 725-1054 | 330 | Volume/pan fader row for hardware outputs |
| **Total inline LOC** | | **988** | 75% of file |

### Utility Functions (also inline)

| Function | Lines | Purpose |
|----------|-------|---------|
| `MODE_LABELS` constant | 31-35 | Maps mode numbers to display strings |
| `nextMode(mode)` | 38-42 | Cycles mode: 0 → 1 → 3 → 0 |
| `formatHwOutputName(destChannel)` | 711-720 | Decodes hardware channel to "HW Out X/Y" |

---

## 2. Critical Finding: Massive Code Duplication

**The three fader components are 99% identical.** Each contains:

| Logic Block | ~LOC per component |
|-------------|-------------------|
| Volume drag handling | 80 |
| Pan drag handling | 80 |
| Double-tap detection | 15 |
| Mute toggle | 5 |
| Mode toggle | 5 |
| `formatPan()` function | 5 (duplicated 3 times!) |
| State declarations | 20 |
| JSX render | 90 |
| Cleanup effects | 20 |

**Only differences between the three:**

| Aspect | SendFader | ReceiveFader | HwOutputRow |
|--------|-----------|--------------|-------------|
| Color scheme | amber/gold (`sends-*`) | blue (`blue-*`) | purple (`purple-*`) |
| Command module | `sendCmd` | `receiveCmd` | `hwCmd` |
| Gesture type | 'send', 'sendPan' | 'receive', 'receivePan' | 'hwOutputVolume', 'hwOutputPan' |
| Index prop | `sendIndex` | `recvIdx` | `hwIdx` |
| Label source | `destName` prop | `srcName` prop | `formatHwOutputName(destChannel)` |
| Mute title | "send" | "receive" | "hw output" |

---

## 3. State Inventory

### Main RoutingModal State
| State/Hook | Source | Used By |
|------------|--------|---------|
| `trackName`, `track`, `guid` | `useTrack(trackIndex)` | Header, subscription |
| `skeleton` | `useTrackSkeleton()` | Name lookup |
| `sends` | `useReaperStore` | Fallback sends data |
| `routingSends/Receives/HwOutputs` | `useReaperStore` | Real-time routing data |
| `setRoutingSubscription` | `useReaperStore` | Subscription setup |
| `clearRoutingSubscription` | `useReaperStore` | Cleanup |
| `activeTab` | `useState<RoutingTab>` | Tab switching |
| `sendCommand` | `useReaper()` | Subscribe/unsubscribe |

### Fader Component State (each has identical pattern)
| State | Purpose |
|-------|---------|
| `isDragging` | Volume fader drag state |
| `isPanDragging` | Pan slider drag state |
| `containerRef` | Volume fader DOM reference |
| `panContainerRef` | Pan slider DOM reference |
| `lastTapRef` | Double-tap detection for volume |
| `lastPanTapRef` | Double-tap detection for pan |
| `cleanupRef` | Volume gesture cleanup function |
| `panCleanupRef` | Pan gesture cleanup function |
| `gestureGuidRef` | Locked GUID during volume gesture |
| `panGestureGuidRef` | Locked GUID during pan gesture |
| `sendIndexRef` (or similar) | Locked index during gesture |

---

## 4. Extraction Candidates

| Candidate | Current LOC | After Extraction | Dependencies | Risk | Priority |
|-----------|-------------|------------------|--------------|------|----------|
| **Unified HorizontalRoutingFader** | 988 (3×329) | ~350 | Color config, command callbacks | Low | **HIGH** |
| **useHorizontalDrag hook** | ~160 (3×80) | ~100 | Gesture commands | Low | HIGH |
| **formatPan utility** | 15 (3×5) | 5 | None | Very Low | HIGH |
| RoutingSendsTab | N/A | ~30 | trackSends, trackNameLookup | Very Low | Low |
| RoutingReceivesTab | N/A | ~30 | trackReceives, trackNameLookup | Very Low | Low |
| RoutingHardwareTab | N/A | ~30 | hwOutputs | Very Low | Low |

### Recommended Approach: Parameterized Component

Create a single `HorizontalRoutingFader` component that takes:

```typescript
interface HorizontalRoutingFaderProps {
  trackIndex: number;
  itemIndex: number;           // sendIndex | recvIdx | hwIdx
  volume: number;
  pan: number;
  muted: boolean;
  mode: number;
  label: string;               // destName | srcName | formatted HW name
  colorScheme: 'send' | 'receive' | 'hardware';
  onVolumeChange: (volume: number) => void;
  onVolumeGestureStart: () => void;
  onVolumeGestureEnd: () => void;
  onPanChange: (pan: number) => void;
  onPanGestureStart: () => void;
  onPanGestureEnd: () => void;
  onMuteToggle: () => void;
  onModeToggle: () => void;
}
```

Or simpler - pass the command module and gesture type as props.

---

## 5. Proposed File Structure

### Final Structure

```
Mixer/
  RoutingModal/
    index.ts                    # Re-export main component
    RoutingModal.tsx            # Main modal shell (~180 LOC)
    HorizontalRoutingFader.tsx  # Unified fader (~300 LOC)
    SendsTab.tsx                # Sends tab content (~60 LOC)
    ReceivesTab.tsx             # Receives tab content (~60 LOC)
    HardwareTab.tsx             # Hardware tab content (~60 LOC)
    routingUtils.ts             # formatPan, formatHwOutputName, MODE_LABELS, nextMode
  ... (other Mixer files)
```

**Actual LOC After Extraction:**
| File | LOC |
|------|-----|
| RoutingModal.tsx | 236 |
| HorizontalRoutingFader.tsx | 301 |
| SendsTab.tsx | 127 |
| ReceivesTab.tsx | 127 |
| HardwareTab.tsx | 135 |
| routingUtils.ts | 97 |
| index.ts | 1 |
| **Total** | **1,024** |

**Reduction:** 1,319 → 1,024 LOC (22% reduction)

**Key Improvements:**
- Zero code duplication (988 LOC of duplicated fader code eliminated)
- Single source of truth for fader behavior
- Clear separation of concerns (each file has one job)
- Easier to maintain, extend, and test

### Why This Structure?
1. **Routing faders are RoutingModal-specific** - not used elsewhere
2. **Keeps related code together** - easy to find and modify
3. **Matches Layout/ folder pattern** from Phase 5
4. **Clean barrel export** - external code still imports from `Mixer/`

---

## 6. Extraction Plan

### Step 1: Extract Utilities (Very Low Risk)
**Files to create:** `Mixer/RoutingModal/routingUtils.ts`

Extract:
- `MODE_LABELS` constant
- `nextMode()` function
- `formatPan()` function (deduplicated from 3 copies)
- `formatHwOutputName()` function

### Step 2: Create HorizontalRoutingFader (Low Risk)
**Files to create:** `Mixer/RoutingModal/HorizontalRoutingFader.tsx`

**DECISION: Option A - Fully Parameterized**
- Single component with color scheme prop
- Callbacks for all mutations
- Cleanest, more extensible for future use cases

```typescript
type RoutingColorScheme = 'send' | 'receive' | 'hardware';

interface HorizontalRoutingFaderProps {
  trackIndex: number;
  itemIndex: number;
  volume: number;
  pan: number;
  muted: boolean;
  mode: number;
  label: string;
  colorScheme: RoutingColorScheme;
  // Callbacks - parent handles command dispatch
  onVolumeChange: (volume: number) => void;
  onVolumeGestureStart: () => void;
  onVolumeGestureEnd: () => void;
  onPanChange: (pan: number) => void;
  onPanGestureStart: () => void;
  onPanGestureEnd: () => void;
  onMuteToggle: () => void;
  onModeToggle: () => void;
}
```

Parent components (SendsTab, etc.) handle the command dispatch, making the fader purely presentational + interactive.

### Step 3: Create Folder Structure
1. Create `Mixer/RoutingModal/` folder
2. Move `RoutingModal.tsx` into folder (as main file or index)
3. Add `index.ts` with exports
4. Update `Mixer/index.ts` to import from new location

### Step 4: Slim Down RoutingModal
After HorizontalRoutingFader exists:
1. Import the unified component
2. Replace HorizontalSendFader with `<HorizontalRoutingFader type="send" ... />`
3. Replace HorizontalReceiveFader with `<HorizontalRoutingFader type="receive" ... />`
4. Replace HwOutputRow with `<HorizontalRoutingFader type="hardware" ... />`
5. Delete the old inline components

---

## 7. State Management Notes

### Current Pattern
Each fader accesses store directly:
```typescript
const mixerLocked = useReaperStore((s) => s.mixerLocked);
const { guid } = useTrack(trackIndex);
const { sendCommand } = useReaper();
```

### After Extraction
Same pattern works - each fader instance calls these hooks.

**No custom hook needed** for routing state - it's simple enough that:
1. `mixerLocked` is a single boolean selector
2. `guid` comes from `useTrack` (already a hook)
3. Commands are called via `sendCommand`

A `useRoutingCommands(type, trackIndex, itemIndex)` hook **could** be extracted but would be over-engineering for the current use case.

---

## 8. Color Scheme Mapping

```typescript
const ROUTING_COLORS = {
  send: {
    muted: 'bg-sends-primary/20 text-sends-primary',
    unmuted: 'bg-bg-surface text-text-secondary hover:bg-bg-elevated',
    faderFill: 'bg-sends-primary',
    faderHandle: 'bg-sends-light',
    ring: 'ring-sends-ring',
    db: 'text-sends-primary',
    dbMuted: 'text-sends-primary/50 line-through',
  },
  receive: {
    muted: 'bg-blue-500/20 text-blue-400',
    unmuted: 'bg-bg-surface text-text-secondary hover:bg-bg-elevated',
    faderFill: 'bg-blue-500/50',
    faderHandle: 'bg-blue-200',
    ring: 'ring-blue-400',
    db: 'text-blue-400',
    dbMuted: 'text-blue-400/50 line-through',
  },
  hardware: {
    muted: 'bg-purple-500/20 text-purple-400',
    unmuted: 'bg-bg-surface text-text-secondary hover:bg-bg-elevated',
    faderFill: 'bg-purple-500',
    faderHandle: 'bg-purple-300',
    ring: 'ring-purple-500/50',
    db: 'text-purple-400',
    dbMuted: 'text-purple-400/50 line-through',
  },
} as const;
```

---

## 9. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Gesture tracking breaks | Low | High | Test all three fader types after extraction |
| Cleanup refs fail | Low | Medium | Keep exact same ref pattern in unified component |
| Color class mismatch | Very Low | Low | Map colors carefully, visual QA |
| Import path changes break callers | Low | Low | Barrel export maintains same external API |
| Index prop confusion | Low | Medium | Clear prop naming, JSDoc comments |

### Verification Plan
After each extraction step:
1. Open RoutingModal on a track with sends, receives, AND hardware outputs
2. Verify each tab displays correctly
3. Test volume fader drag
4. Test pan slider drag
5. Test double-tap reset (volume and pan)
6. Test mute toggle
7. Test mode cycle
8. Verify gesture undo coalescing still works

---

## 10. Decisions Made

1. **Tab content wrappers?**
   - **DECISION: YES** - Extract `SendsTab`, `ReceivesTab`, `HardwareTab` components
   - Easier to grok from directory structure
   - Each tab wrapper handles its own command dispatch

2. **Should `useHorizontalDrag` be a general hook?**
   - **DECISION: NO for now** - Keep drag logic in component
   - Will revisit if reuse need arises elsewhere
   - Vertical faders use different Y-axis logic anyway

3. **Color tokens for receives/hardware?**
   - **DECISION: YES** - Add semantic tokens as part of this refactor
   - Add `receives-*` and `hardware-*` tokens to index.css
   - Keeps everything consistent with existing `sends-*` pattern

4. **formatHwOutputName location?**
   - **DECISION: routingUtils.ts** - It's RoutingModal-specific

---

## 11. Summary

### The Core Problem
988 LOC of nearly identical code duplicated across 3 components.

### The Solution
Create a single parameterized `HorizontalRoutingFader` component (~350 LOC) that handles all three routing types via a `type` prop.

### Expected Outcome
| Metric | Before | After |
|--------|--------|-------|
| Total LOC | 1,319 | ~660 |
| Component count | 4 (1 main + 3 inline) | 2 (1 main + 1 fader) |
| Duplicated code | 988 LOC | 0 |
| Maintainability | Poor (3 places to update) | Good (1 place) |

### Execution Order
1. Create folder structure and move files
2. Extract utilities to `routingUtils.ts`
3. Create `HorizontalRoutingFader.tsx`
4. Update RoutingModal to use unified fader
5. Delete old inline components
6. Update barrel exports
7. Verify on device

Each step produces a working, committable state.
