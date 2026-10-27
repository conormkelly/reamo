# Swipe Comping UI Design

Frontend design for touch-based swipe comping in REAmo.

See [SWIPE_COMPING.md](SWIPE_COMPING.md) for backend API details.

---

## Entry Point

From main track view, tracks with `I_FREEMODE === 2` (fixed lanes mode) show a lanes icon.

Tap icon → enters **Swipe Comp Mode** for that track (full screen, single track focus).

---

## Layout

Follows the app's primary/secondary view pattern (see [UX_GUIDELINES.md](../architecture/frontend/UX_GUIDELINES.md)):

- **Primary View**: Comp target lane + source lanes (main interaction area)
- **Secondary View**: Controls in footer SecondaryPanel (portrait) or ContextRail (landscape)

### Portrait Layout

```
┌──────────────────────────────────────────────────────┐
│  ← Back              Track 3: Vocals                 │  ← Header
├──────────────────────────────────────────────────────┤
│▌ C1 ███████│███████│███████│███████│                 │  ← Comp target (sticky)
│   (comp)   ▓▓▓▓▓▓▓▓│░░░░░░░│▓▓▓▓▓▓▓│░░░░░░░│        │     PRIMARY
├──────────────────────────────────────────────────────┤     VIEW
│  Source 1  ████████│████████│████████│████████│      │
│            ▓▓▓▓▓▓▓▓│░░░░░░░░│▓▓▓▓▓▓▓▓│░░░░░░░░│      │
├──────────────────────────────────────────────────────┤
│           [◀ Prev]  1 of 3  [Next ▶]                │  ← Bank nav
╞══════════════════════════════════════════════════════╡
│  [▲] [▼]  Comp:[C1▼]  Play:[☑☑☐]  [+New]            │  ← SECONDARY
└──────────────────────────────────────────────────────┘     PANEL
```

### Landscape Layout (Dual Rails)

```
┌─────┬────────────────────────────────────────┬──────┐
│     │  Track 3: Vocals                       │      │
│ Nav │────────────────────────────────────────│ Ctx  │
│     │▌ C1 ███████│███████│███████│███████│   │      │
│ ▣   │   (comp)   ▓▓▓▓▓▓▓▓│░░░░░░░│▓▓▓▓▓▓▓│   │ [▲]  │ ← Source
│ ▣   │────────────────────────────────────────│ [▼]  │   cycle
│ ▣   │  Source 1  ████████│████████│████████│ │      │
│     │            ▓▓▓▓▓▓▓▓│░░░░░░░░│▓▓▓▓▓▓▓▓│ │ ───  │
│ ▶◼● │────────────────────────────────────────│Comp▼ │ ← Comp dropdown
│     │           [◀]  1/3  [▶]                │Play☑ │ ← Play toggles
│     │                                        │ [+]  │
└─────┴────────────────────────────────────────┴──────┘
  Nav              PRIMARY VIEW                Context
  Rail                                          Rail
```

### Header Bar

| Element | Function |
|---------|----------|
| ← Back | Exit swipe comp mode, return to track view |
| Track name | Current track being comped |

### Primary View Elements

#### Comp Target Lane (Sticky)

- Always visible at top, doesn't scroll with source lanes
- Yellow strip on left edge indicates this is the comp target
- Shows resulting comp waveform
- Orange overlay shows which segments are active (from which sources)

#### Source Lanes (Bankable)

- Page through source lanes one at a time (mobile) or 2-3 at a time (tablet)
- Excludes the active comp target from pagination
- Each lane shows:
  - Lane name/number
  - Waveform
  - Orange overlay where this source is used in active comp
  - Tappable regions for promoting to comp

#### Bank Navigation

- Shows current position: "1 of 3"
- Prev/Next buttons for paging
- On larger screens, may show multiple sources simultaneously

### Secondary View Elements

Lives in SecondaryPanel footer (portrait) or ContextRail (landscape).

| Element | Function |
|---------|----------|
| **[▲] [▼] Source Cycle** | Cycle selected comp segment through sources (actions 42707/42708) |
| **Comp: [dropdown]** | Select which comp lane receives swipes (sets LANEREC) |
| **Play: [multi-select]** | Toggle which lanes play back (sets C_LANEPLAYS:N per lane) |
| **[+ New]** | Create new comp lane |

**Key distinction:**

- "Comp" = where swipes go (yellow square in REAPER) — single selection
- "Play" = what you hear during playback (yellow radio in REAPER) — **multi-select**
- These are **independent** - you can listen to C2 while comping into C1
- Multiple lanes can play simultaneously for A/B comparison or layered playback

---

## Visual Language

| Element | Meaning |
|---------|---------|
| `▌` Yellow strip (left edge) | This lane is the comp target |
| `▓▓▓` Orange overlay | This time region is in the active comp |
| `░░░` No overlay | Available source, not currently in comp |
| `███` Waveform | Audio content |

---

## Interactions

### Tap Source Region

**Action:** Promote that time slice to the active comp

- If region already in comp from different source → replaces it
- If region not in comp → adds it
- Calls `lanes/swipeComp` with source lane and time bounds

### Tap Comp Region

**Action:** Select for context menu (future)

- Could show: delete, change source, adjust bounds
- v1: may not implement, focus on swipe-to-add

### Swipe Horizontally on Source

**Action:** Create comp segment for swiped range

- Touch down → start time
- Touch up → end time
- Promotes that range from source to comp
- Same as tap but with custom time bounds

---

## Source Cycling Workflow

The ▲/▼ buttons in the secondary panel enable rapid source auditioning without banking through lanes.

### The Problem with Bank-Only Navigation

```
Traditional workflow (slow):
1. Page to source lane 3
2. Tap segment to promote
3. Page to source lane 5
4. Tap same segment to replace
5. Page to source lane 2
6. Tap same segment to replace
... tedious for many takes
```

### The Source Cycle Solution

```
Optimized workflow (fast):
1. Tap comp segment to select it
2. ▲ ▲ ▲ ▼ ▼ — audition through sources in real-time
3. Done when it sounds right
```

### How It Works

When a comp segment is selected:

| Button | Action | Backend |
|--------|--------|---------|
| **▲** | Replace segment source with previous lane | Action 42707 (moveCompUp) |
| **▼** | Replace segment source with next lane | Action 42708 (moveCompDown) |

**Prerequisites:**

- All source takes must be time-aligned (same item positions)
- A comp segment must be selected (tapped) first

**Visual Feedback:**

- Selected segment highlights
- Orange overlay on source lanes updates in real-time
- Waveform in comp lane updates to show new source

### Why This Works

REAPER's "Move comp area up/down" actions (42707/42708) shift the source lane for the selected comp area. Combined with aligned takes (standard multi-take recording), this gives instant A/B/C/D comparison.

---

## Tap Behavior Details

Tapping is **context-aware** based on existing comp segments and source item boundaries.

### Region Types

```
Comp:    [███Seg1███]           [███Seg2███]
                 ↑ gap ↑

Source:  [Item A][Item B][Item C][Item D]
```

| Tap Location | Result |
|--------------|--------|
| Source item within existing segment | Replace segment source (keeps bounds) |
| Source item within gap | Add item to comp (uses item bounds) |
| Long unsplit item within segment | Replace segment source (keeps bounds) |
| Long unsplit item within gap | Fill entire gap (gap start to gap end) |

### Examples

**Setup:** Lane 1 = one long item, Lane 2 = 4 split items (Q1-Q4)

| Action | Result |
|--------|--------|
| Tap Lane 2 Q1 | Adds Q1 to comp (whole item) |
| Tap Lane 2 Q3 | Adds Q3 to comp (whole item, now 2 segments) |
| Tap Lane 1 in Q1 region | Replaces Q1 source with Lane 1 (same bounds) |
| Tap Lane 1 in Q2 region (gap) | Fills gap from Q1 end to Q3 start |

### Key Insight

- **Existing comp segments define time slots**
- **Gaps between segments are also implicit slots**
- Tapping determines bounds from: (1) comp segment boundaries, (2) source item boundaries
- Discrete items take precedence when they exist

### Dropdown: Comp Into

**Action:** Change comp target lane

- Calls `lanes/setCompTarget` (modifies LANEREC via state chunk)
- UI updates: new target becomes sticky top lane
- Previous target moves to source bank

### Multi-Select: Play

**Action:** Toggle playback for individual lanes

- Calls `lanes/setLanePlays` for each lane being toggled
- **Multiple lanes can play simultaneously** — REAPER supports layered playback
- Visual indicator on each playing lane (speaker icon or highlight)

**Why multi-select?**

REAPER's fixed lanes support three play states per lane:

- `0` = Off (muted)
- `1` = Exclusive (standard comp playback)
- `2` = Layered (plays alongside other lanes)

Use cases for multi-lane playback:

- **A/B comparison:** Play comp lane + a source lane to compare
- **Layered takes:** Blend multiple performances (harmonies, doubles)
- **Debugging:** Verify which audio is coming from where

### Button: + New Comp

**Action:** Create new comp lane

- Calls action 42797 or equivalent
- New lane becomes comp target automatically
- User can then swipe to populate it

---

## State from Backend

`lanes/getState` response provides:

```typescript
interface LanesState {
  numLanes: number;
  freeMode: number;            // 2 = fixed lanes
  compTargetLane: number;      // from LANEREC v2
  lanes: LaneInfo[];
}

interface LaneInfo {
  lane: number;                // lane index
  name: string;                // P_LANENAME:N
  plays: number;               // C_LANEPLAYS:N (0=off, 1=exclusive, 2=layered)
}
```

**Note:** Multiple lanes can have `plays > 0` simultaneously. The frontend derives "playing lanes" by filtering `lanes.filter(l => l.plays > 0)`.

---

## Comp Source Mapping

To show orange overlays on source lanes, we need to know which source each comp segment came from.

**Challenge:** REAPER doesn't expose this directly. Orange highlights are computed at display time.

**Solution:** Infer from audio source matching (see SWIPE_COMPING.md "Inferring Comp Source Mapping").

**Limitation:** Only works when sources have different audio files. If same file is duplicated across lanes, inference fails.

**Recommendation:** Track source lanes in frontend state when user creates swipes, rather than relying solely on inference.

---

## Edge Cases

### No Comp Lane Exists

- Show source lanes only
- Prompt: "Swipe to create comp" or show [+ Create Comp Lane] prominently
- First swipe auto-creates comp lane

### Multiple Comp Lanes

- Dropdown lists all comp lanes (C1, C2, etc.)
- User selects which to comp into
- Non-selected comps appear in source bank (can be swiped from!)

### Many Source Lanes

- Bank pagination handles 10+ lanes gracefully
- Consider: collapse/expand, search, or thumbnails for quick navigation

### Overlapping Comp Regions

- Swipe comp naturally handles overlaps
- Later swipe replaces earlier in overlap zone
- UI shows final state, not history

---

## Backend Commands

### Core Commands

| Command | Parameters | Action |
|---------|------------|--------|
| `lanes/getState` | trackGuid | Returns full lane state (see State from Backend) |
| `lanes/swipeComp` | trackGuid, sourceLane, startTime, endTime | P_RAZOREDITS_EXT + action 42475 |

### Lane Control

| Command | Parameters | Action |
|---------|------------|--------|
| `lanes/setCompTarget` | trackGuid, laneIndex | Modify LANEREC via state chunk |
| `lanes/setLanePlays` | trackGuid, laneIndex, plays | Set C_LANEPLAYS:N (0=off, 1=exclusive, 2=layered) |
| `lanes/createCompLane` | trackGuid | Action 42797 — creates new comp lane |

### Comp Segment Operations

| Command | Parameters | Action |
|---------|------------|--------|
| `lanes/moveCompUp` | trackGuid | Action 42707 — selected segment uses previous source |
| `lanes/moveCompDown` | trackGuid | Action 42708 — selected segment uses next source |
| `lanes/deleteCompArea` | trackGuid, itemGuid | Select item + action 42642 |

### Optional (Future)

| Command | Parameters | Action |
|---------|------------|--------|
| `lanes/getCompMapping` | trackGuid | Infer which source lane each comp segment came from |

---

## Future Enhancements

- **Waveform zoom:** Pinch to zoom timeline
- **Crossfade adjustment:** Drag comp boundaries to adjust crossfades
- **Markers:** Show arrangement markers for navigation context
