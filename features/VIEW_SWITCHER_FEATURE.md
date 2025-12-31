# View Switcher Feature Specification

## Why This Feature Matters

### The Problem

Different workflows need different interfaces:
- **Recording:** Full timeline visibility with regions and markers
- **Performing:** Big transport controls visible from 10+ feet away
- **Mixing:** Maximum fader real estate
- **Live setlist:** Quick section jumping, current position indicator

Current web interface is one-size-fits-all. Musicians either get too much or too little.

### The Research Says

> "Bottom navigation wins for tablets. Tab bars at bottom offer high discoverability (hamburger menus reduce engagement by 30%+) and thumb accessibility."

> "Transport controls deserve special treatment—always visible, bottom-right corner."

> "Users prefer simple hardware to complex apps... Reamo's default view should be radically simple, with complexity available but not required."

---

## Navigation Architecture

### The Layout

```
┌─────────────────────────────────────────────────────────┐
│  [≡]  │        Project Name        │           [⚙️]     │  ← Header (optional)
├─────────────────────────────────────────────────────────┤
│                                                         │
│                                                         │
│                   ACTIVE VIEW AREA                      │
│                                                         │
│                                                         │
├─────────────────────────────────────────────────────────┤
│ Timeline│ Mixer │ Clock │ Cues │ Actions │ Notes       │  ← Tab bar
├─────────────────────────────────────────────────────────┤
│  ◄◄  │  ▶/❚❚  │  ⏹  │  ⏺  │    03:42.16    │  120 BPM │  ← Persistent transport
└─────────────────────────────────────────────────────────┘
```

**Note on phone layouts:** Six tabs may be tight on phones. Consider icon-only tabs or collapsing Actions/Notes into a "More" menu on small screens.

### Key Principles

1. **Persistent transport bar** — Always visible at the very bottom. Play/stop/record accessible from ANY view.

2. **Tab bar above transport** — Five purpose-built views. Tap to switch. No hamburger menus for core navigation.

3. **Active view fills remaining space** — Each view optimized for its workflow.

4. **Header is optional/minimal** — Project name, settings gear. Can be hidden in "Stage Mode" for maximum view space.

---

## The Six Views

| View | Tab Label | Purpose | Primary Users |
|------|-----------|---------|---------------|
| **Timeline** | Timeline | Visual arrangement with regions, markers, playhead | Everyone (default) |
| **Mixer** | Mixer | Faders, meters, track control | Mixing engineers, tracking |
| **Clock** | Clock | Big transport, BPM, bar.beat | Performers, drummers |
| **Cues** | Cues | Region list, playlist mode | Live performers, arrangers |
| **Actions** | Actions | Quick action buttons | Power users, custom workflows |
| **Notes** | Notes | Project notes, session metadata | Producers, film scorers |

**Why Timeline is the default:**

The research says: *"Remote apps don't show what matters. Users want to see their actual timeline and arrangement, not just controller layouts."*

This is Reamo's visual differentiator. When you open the app, you see your song — regions, markers, where you are in the arrangement. Not just faders. Other remotes are glorified control surfaces. Reamo shows you your project.

---

## View Details

### Timeline View (Default)

The visual differentiator. Shows your actual arrangement.

```
┌─────────────────────────────────────────────────────────┐
│     Intro    │  Verse 1   │  Chorus   │  Verse 2  │    │
│ ─────────────┼────────────┼───────────┼───────────┼─── │
│ Drums   ▓▓▓▓▓│▓▓▓░░▓▓▓▓▓▓│▓▓▓▓▓▓▓▓▓▓▓│▓▓▓░░▓▓▓▓▓▓│    │
│ Bass    ░░░░░│▓▓▓▓▓▓░░▓▓▓│▓▓▓▓▓▓▓▓░░░│▓▓▓▓▓▓░░▓▓▓│    │
│ Guitar  ░░░░░│░░░░▓▓▓▓▓▓▓│▓▓▓▓▓▓▓▓▓▓▓│░░░░▓▓▓▓▓▓▓│    │
│ Vocals  ░░░░░│░░░░░░░░▓▓▓│▓▓▓▓▓▓▓▓▓▓▓│░░░░░░░░▓▓▓│    │
│              │      ▲     │           │           │    │
│              │  (playhead)│           │           │    │
├─────────────────────────────────────────────────────────┤
│ [Timeline] │ Mixer │ Clock │ Cues │ Actions │ Notes   │
├─────────────────────────────────────────────────────────┤
│  ◄◄  │  ▶  │  ⏹  │  ⏺  │    17.3.2    │  120 BPM     │
└─────────────────────────────────────────────────────────┘
```

**Elements:**
- Region/marker lane at top showing song structure
- Track lanes with item blobs (visual representation of recorded content)
- Playhead position indicator
- Horizontal scroll/zoom for navigation
- Tap region to jump to position

**What this ISN'T:**
- Not a full DAW arrange view with editing
- Not waveform-accurate (too expensive to render)
- Just enough visual context to know where you are

**This is what competitors don't show.** TouchOSC, Lemur, V-Control — they're all blind to arrangement. Reamo shows you your song.

---

### Mixer View

The workhorse for level control.

```
┌─────────────────────────────────────────────────────────┐
│ Drm │ Bas │ Gtr │ Vox │ Syn │ Pad │ FX  │ Bus │  ◄  ▶  │
│ ▓▓▓ │ ▓░░ │ ▓▓░ │ ▓░░ │ ░░░ │ ▓▓▓ │ ▓▓░ │ ▓▓▓ │ bank   │
│ ║   │ ║   │ ║   │ ║   │ ║   │ ║   │ ║   │ ║   │        │
│ ║▓▓ │ ║▓░ │ ║▓▓ │ ║▓░ │ ║░░ │ ║▓▓ │ ║▓▓ │ ║▓▓ │        │
│ M S │ M S │ M S │ M S │ M S │ M S │ M S │ M S │        │
│ [●] │     │ [●] │     │     │     │     │     │        │
├─────────────────────────────────────────────────────────┤
│  Mixer  │  Clock  │  Cues  │  Actions  │  Notes        │
├─────────────────────────────────────────────────────────┤
│  ◄◄  │  ▶  │  ⏹  │  ⏺  │    17.3.2    │  120 BPM     │
└─────────────────────────────────────────────────────────┘
```

**Elements:**
- 6-8 channel strips (responsive to screen width)
- Vertical faders with meters
- Mute (M) / Solo (S) buttons per track
- Record arm indicator [●]
- Bank navigation (◄ ▶) for projects with many tracks
- Long-press track → Send control panel (see Send Control spec)

---

### Clock View (Transport/Performance)

Big, readable from across the room. 80-100pt touch targets.

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                      ♩ = 120                            │
│                                                         │
│                    17 . 3 . 2                           │
│                                                         │
│         ┌─────┐    ┌─────┐    ┌─────┐                  │
│         │ ⏮️  │    │ ▶️  │    │ ⏹️  │                  │
│         └─────┘    └─────┘    └─────┘                  │
│                                                         │
│                    ┌─────┐                              │
│                    │ ⏺️  │                              │
│                    └─────┘                              │
│                                                         │
│      [Cycle]      [Click]      [Punch]                 │
├─────────────────────────────────────────────────────────┤
│  Mixer  │ [Clock] │  Cues  │  Actions  │  Notes        │
├─────────────────────────────────────────────────────────┤
│  ◄◄  │  ▶  │  ⏹  │  ⏺  │    17.3.2    │  120 BPM     │
└─────────────────────────────────────────────────────────┘
```

**Elements:**
- Huge BPM display (tap to edit)
- Large bar.beat.subdivision counter
- Giant transport buttons (80-100pt minimum)
- Prominent record button
- Toggle buttons for cycle, click, punch modes
- Current marker/region name (optional)

**Note:** Transport bar at bottom is redundant here but stays for consistency. Could hide in this view.

---

### Cues View

Vertical list of regions. Tap to jump. See [CUE_LIST_FEATURE.md](CUE_LIST_FEATURE.md) for full spec.

```
┌─────────────────────────────────────────────────────────┐
│ Cue List                              [Edit] [▶ Play]  │
├─────────────────────────────────────────────────────────┤
│ ▶ Intro                     x1              0:00       │
│   Verse 1                   x4              0:32       │
│   Chorus                    x2              1:04       │
│   Verse 2                   x4              1:36       │
│   Chorus                    x2              2:08       │
│   Bridge                    x1              2:40       │
│   Outro                     x1              3:12       │
├─────────────────────────────────────────────────────────┤
│  Mixer  │  Clock  │ [Cues] │  Actions  │  Notes        │
├─────────────────────────────────────────────────────────┤
│  ◄◄  │  ▶  │  ⏹  │  ⏺  │    17.3.2    │  120 BPM     │
└─────────────────────────────────────────────────────────┘
```

---

### Actions View

User-configurable quick action buttons. Grid of large touch targets.

```
┌─────────────────────────────────────────────────────────┐
│ Quick Actions                                  [Edit]  │
├─────────────────────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────┐  ┌──────────┐             │
│  │  Delete  │  │   Undo   │  │   Redo   │             │
│  │Last Take │  │          │  │          │             │
│  └──────────┘  └──────────┘  └──────────┘             │
│                                                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐             │
│  │  Save    │  │  Render  │  │  Toggle  │             │
│  │ Project  │  │          │  │  Click   │             │
│  └──────────┘  └──────────┘  └──────────┘             │
│                                                         │
├─────────────────────────────────────────────────────────┤
│  Mixer  │  Clock  │  Cues  │ [Actions] │  Notes        │
├─────────────────────────────────────────────────────────┤
│  ◄◄  │  ▶  │  ⏹  │  ⏺  │    17.3.2    │  120 BPM     │
└─────────────────────────────────────────────────────────┘
```

**Elements:**
- Grid of configurable buttons (3x3 or 4x4 depending on screen)
- Each button maps to a REAPER action ID
- Edit mode to configure button labels and actions
- Stored per-device in localStorage

---

### Notes View

Project notes with read/edit capability. See Project Notes section in PLANNED_FEATURES.md.

```
┌─────────────────────────────────────────────────────────┐
│ Project Notes                          [Edit] [Save]   │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  Client: Acme Records                                  │
│  Session: 2024-01-15                                   │
│                                                         │
│  TODO:                                                 │
│  - Re-record verse 2 vocals                            │
│  - Fix timing on bridge guitar                         │
│  - Add backing vocals to chorus                        │
│                                                         │
├─────────────────────────────────────────────────────────┤
│  Mixer  │  Clock  │  Cues  │  Actions  │ [Notes]       │
├─────────────────────────────────────────────────────────┤
│  ◄◄  │  ▶  │  ⏹  │  ⏺  │    17.3.2    │  120 BPM     │
└─────────────────────────────────────────────────────────┘
```

---

## Persistent Transport Bar

Always visible. Never hidden. This is the "beat a $15 keypad" differentiator.

```
┌─────────────────────────────────────────────────────────┐
│  ◄◄  │  ▶/❚❚  │  ⏹  │  ⏺  │    17.3.2    │  120 BPM  │
└─────────────────────────────────────────────────────────┘
```

| Element | Touch Target | Behavior |
|---------|--------------|----------|
| ◄◄ Rewind | 54pt | Jump to previous marker or start |
| ▶/❚❚ Play/Pause | 54pt | Toggle playback |
| ⏹ Stop | 54pt | Stop transport |
| ⏺ Record | 54pt | Toggle record (red when armed) |
| Time display | — | Shows position (tap to cycle format) |
| BPM display | — | Shows tempo (tap to edit) |

**Time display formats** (cycle on tap):
- `17.3.2` — Bars.beats.subdivisions
- `1:23.456` — Minutes:seconds.milliseconds
- `00:01:23:12` — SMPTE timecode (if frame rate set)

---

## Tab Bar

```
┌───────────────────────────────────────────────────────────────────┐
│ Timeline │  Mixer  │  Clock  │  Cues  │  Actions  │  Notes       │
└───────────────────────────────────────────────────────────────────┘
```

- Equal-width tabs (6 tabs = ~16.7% each)
- Active tab highlighted
- Tap to switch (instant, no animation delay)
- Swipe left/right as secondary navigation (optional enhancement)

**Touch targets:** Each tab is full height of bar (~44-54pt) × ~16.7% width

**Phone adaptation:** On narrow screens, consider:
- Icon-only tabs (🎬 🎚️ ⏱️ 📋 ⚡ 📝)
- Scrollable tab bar
- Collapse Actions + Notes into "More" menu

---

## State Management

### Frontend State

```typescript
type ViewId = 'timeline' | 'mixer' | 'clock' | 'cues' | 'actions' | 'notes';

interface ViewState {
  currentView: ViewId;
  previousView: ViewId | null;  // For "back" gesture if needed
}

// Persist to localStorage
const VIEW_STORAGE_KEY = 'reamo_current_view';
```

### Per-Device Memory

Each device remembers its last view. A tablet mounted as mixer stays on Mixer. A phone used for transport stays on Clock.

```typescript
// On mount — Timeline is default
const savedView = localStorage.getItem(VIEW_STORAGE_KEY) as ViewId || 'timeline';

// On view change
localStorage.setItem(VIEW_STORAGE_KEY, newView);
```

---

## Touch Targets

Per research recommendations:

| Control Type | Minimum Size | Notes |
|--------------|--------------|-------|
| Transport buttons | 54pt | Persistent bar |
| Clock view transport | 80-100pt | Stage use |
| Tab bar tabs | 44pt height | Full width ÷ 5 |
| Mixer faders | 44pt width | Vertical drag |
| Action buttons | 60pt × 60pt | Easy to hit |

---

## Implementation Checklist

### Phase 1: Core Navigation (Frontend-only)

- [ ] Create persistent transport bar component
- [ ] Create tab bar component with 5 tabs
- [ ] Create view container with conditional rendering
- [ ] Implement view switching with localStorage persistence
- [ ] Wire transport bar to existing WebSocket commands

### Phase 2: View Components

- [ ] Refactor existing mixer into MixerView component
- [ ] Create ClockView with large transport buttons
- [ ] Create placeholder CuesView (links to Cue List feature)
- [ ] Create placeholder ActionsView (links to Quick Actions feature)
- [ ] Create placeholder NotesView (links to Project Notes feature)

### Phase 3: Polish

- [ ] Add swipe gesture for view switching
- [ ] Implement time display format cycling
- [ ] Add BPM tap-to-edit
- [ ] Responsive layout (phone vs tablet)
- [ ] Stage Mode toggle (enlarge all controls 50%+)

---

## What About "Edit View"?

The previous spec had an "Edit" view combining timeline + regions + markers + mixer. This was removed because:

1. **Research doesn't validate it** — Users want purpose-built views, not "everything at once"
2. **Mixer view already shows regions** — The timeline/region display exists in current app
3. **Cues view handles navigation** — Quick section jumping is there
4. **Simpler is better** — Five focused views > three overloaded views

If users want timeline + mixer together, the Mixer view can optionally show a compact region bar above the faders (future enhancement).

---

## Future Enhancements

- **Stage Mode:** Global toggle that enlarges all controls 50%+
- **Custom views:** Let users pick which components appear
- **Auto-switch:** Automatically switch to Clock when recording starts
- **View presets:** Save and recall view configurations
- **Gesture shortcuts:** Double-tap transport bar to toggle Clock view
