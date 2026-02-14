# Frontend Sweep - V1 Polish

**Created:** 2026-01-24
**Branch:** refactor/responsive-frontend

Catalog of bugs and improvements discovered during frontend sweep. Grouped by effort size for methodical tackling.

---

## Small (S) - Quick Fixes ✅

CSS tweaks, simple behavior changes. Each should take 15-30 minutes.

### ~~S1: Remove "Rotate for Best Experience" Messages~~ ✅

- **Location:** DrumPads, Piano, possibly others
- **Issue:** Messages appear even on iPad where there's plenty of space
- **Fix:** Remove the orientation warning components entirely
- **Note:** Drum pads look fine in both orientations

### ~~S2: Track Strip Padding in Mixer~~ ✅

- **Location:** MixerView / TrackStrip components
- **Issue:** Strips too close together, dragging fader near meter boundary causes meters to shift left
- **Fix:** Add more horizontal padding between strips

### ~~S3: Notes Page Margin/Padding~~ ✅

- **Location:** NotesView (project notes section)
- **Issue:** Content bunched right up against Discard/Save buttons
- **Fix:** Add responsive margin/padding to text content area

### ~~S4: Track Selector Button Opens Info Panel~~ ✅

- **Location:** TrackStrip (bottom selector button)
- **Issue:** Clicking selector has no visible effect unless Info panel is already open
- **Fix:** Auto-open SecondaryPanel Info tab when selector button pressed

---

## Medium (M) - Targeted Fixes

Require investigation or moderate refactoring. Each should take 1-3 hours.

### M1: Ruler Bar Position Labels

- **Location:** TimelineRuler.tsx
- **Issue:** Doesn't show first bar position (shows blank, then 1024) whereas REAPER shows bar 1, then 1025
- **Why it matters:** Label drawing logic needs to be consistent with zoom architecture (power of 2s, tempo-aware)
- **Docs:** Check RESPONSIVE_TIMELINE_AND_MIXER.md, zoom architecture docs
- **Fix:** Review label drawing logic at all zoom levels, ensure first visible bar is always labeled

### M2: Mixer Height in Portrait (Phone, Secondary Collapsed)

- **Location:** MixerView.tsx, Layout Budget System
- **Issue:** Mixer way too tall on phone in portrait when secondary view is collapsed
- **Root cause:** Layout budget calculation may not account for collapsed panel correctly
- **Fix:** Audit fader height calculation in portrait with collapsed SecondaryPanel

### ~~M3: Fader Drag Causes Meter Shift~~ ✅

- **Location:** TrackStrip components
- **Issue:** Dragging fader to half-way meter line causes meters to move left
- **Root cause:** Likely strip container needs fixed width or better containment
- **Fix:** Ensure track strip internals don't resize during interaction

### ~~M4: Drum Pads Portrait Layout~~ ✅

- **Location:** DrumPadGrid.tsx
- **Issue:** Massive gaps between pads in portrait on phone - not centered or bunched
- **Fix:** Center pads in available space, maximize pad size while maintaining grid
- **Note:** Landscape layout is already good, use as reference

### M5: Toolbar Redesign

- **Location:** Toolbar component in timeline SecondaryPanel
- **Status:** Already documented in ROADMAP.md
- **Issue:** No slot concept, buttons sized by text, no overflow handling, poor padding
- **Fix:** Uniform 48-54pt targets, 4 buttons per row, horizontal swipe paging
- **Estimate in ROADMAP:** S (half day) - but depends on scope

---

## Large (L) - Significant Rethink / V2 Deferred

Require design decisions, major refactoring, or are being deferred.

### L1: Region Editing Mode Overhaul

- **Location:** TimelineView region editing mode, RegionInfoBar
- **Issue:**
  - Requires secondary view to be almost twice as tall (wastes space)
  - Designed before pinch/pan/scroll was implemented
  - Not touch-friendly for scrollable canvas
- **Action:** Flag for deep investigation. Needs redesign for touch-first experience.
- **Status:** V2 - needs design research

### L2: Phone Landscape Mode (Timeline & Mixer)

- **Location:** TimelineView, MixerView in landscape on phones
- **Issue:** Currently unusable on phones in landscape
- **Discussion:**
  - Made initial compact mixer changes but they don't work well even on iPad
  - May need to show "Landscape Coming Soon" placeholder on phones
  - Consider reverting landscape-specific mixer changes
  - Tablet (iPad) landscape needs assessment - may work OK
- **Decision needed:**
  1. Test if current landscape works acceptably on iPad
  2. If not, decide: revert changes vs. placeholder
  3. For phones: definitely placeholder for v1
- **Status:** V2 - too time-consuming for v1

### L3: Chord Strips Portrait Mode

- **Location:** InstrumentsView ChordStrips
- **Issue:** Portrait mode not working well on phone
- **Reference:** Commit `e261453` has work on mobile UX but needs more
- **Action:** Add placeholder for portrait, show landscape only for v1
- **Status:** V2

### L4: Piano Portrait Mode

- **Location:** InstrumentsView Piano
- **Issue:** Not usable on phone in portrait
- **Action:** Add placeholder for portrait, show landscape only for v1
- **Status:** V2

---

## Responsive Design Root Causes

Several issues above may be symptomatic of incomplete responsive implementation:

1. **Layout Budget System gaps** - Some views may not properly use `useAvailableContentHeight` or have hardcoded values remaining
2. **Orientation breakpoints** - May need device-specific breakpoints, not just viewport-based
3. **SecondaryPanel integration** - Some views may not account for panel state changes

Consider research session on responsive patterns across all views if individual fixes reveal systemic issues.

---

## Suggested Tackling Order

### Phase 1: Quick Wins (All S items)

1. S1 - Remove rotation messages
2. S2 - Track strip padding
3. S3 - Notes page padding
4. S4 - Track selector opens info

### Phase 2: Core Layout Fixes (M items)

1. M2 - Mixer height issue (foundational)
2. M3 - Fader/meter shift (related to M2)
3. M4 - Drum pads portrait
4. M1 - Ruler labels

### Phase 3: Toolbar

1. M5 - Toolbar redesign (can be done independently)

### Phase 4: V2 Placeholders

1. L2 - Add phone landscape placeholder
2. L3 - Chord strips portrait placeholder
3. L4 - Piano portrait placeholder

### Phase 5: V2 Deep Work

1. L1 - Region editing overhaul
2. L2 - Full landscape implementation

---

## Reference Commits

| Feature | SHA | Notes |
|---------|-----|-------|
| Chord strips mobile UX | `e261453` | Has placeholder pattern |
| Layout Budget System | `856f002` | SecondaryPanel, useAvailableContentHeight |
| Toolbar research | - | See ROADMAP.md Toolbar section |
