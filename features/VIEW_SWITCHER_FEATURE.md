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

**Note on phone layouts:** Seven tabs will be tight on phones. Consider icon-only tabs, scrollable tab bar, or collapsing less-used views into a "More" menu on small screens.

### Key Principles

1. **Persistent transport bar** — Visible by default at the very bottom. Play/stop/record accessible from ANY view. Can be hidden via Full Screen Mode.

2. **Tab bar above transport** — Seven purpose-built views. Tap to switch. No hamburger menus for core navigation.

3. **Active view fills remaining space** — Each view optimized for its workflow.

4. **Header is optional/minimal** — Project name, settings gear. Can be hidden in "Stage Mode" for maximum view space.

5. **Full Screen Mode** — Double-tap to hide tab bar and transport. Enables dedicated-device workflows (phone as clock, iPad as mixer).

---

## The Seven Views

| View | Tab Label | Purpose | Primary Users |
|------|-----------|---------|---------------|
| **Studio** | Studio | All-in-one: transport + mixer + regions (current default layout) | Solo musicians, debugging |
| **Timeline** | Timeline | Visual arrangement with regions, markers, playhead | Everyone |
| **Mixer** | Mixer | Faders, meters, track control | Mixing engineers, tracking |
| **Clock** | Clock | Big transport, BPM, bar.beat | Performers, drummers |
| **Cues** | Cues | Region list, playlist mode | Live performers, arrangers |
| **Actions** | Actions | Quick action buttons | Power users, custom workflows |
| **Notes** | Notes | Project notes, session metadata | Producers, film scorers |

**Default view debate:**

Two strong candidates:

- **Studio** — The "radically simple" choice. Everything a solo musician needs without tab-switching. Research says: *"Users prefer simple hardware to complex apps... Reamo's default view should be radically simple."* This is it.

- **Timeline** — The visual differentiator. Research says: *"Remote apps don't show what matters. Users want to see their actual timeline and arrangement."* This shows your song structure.

**Recommendation:** Default to **Studio** for new users (matches "radically simple" goal). Power users who want focused views will discover the tab bar. Timeline becomes the go-to for anyone who wants arrangement visibility without mixer clutter.

---

## View Details

### Studio View (Default)

The all-in-one view. This is the current Reamo layout — transport, mixer, and regions in one screen. Optimized for full-screen iPad from day one.

```
┌─────────────────────────────────────────────────────────┐
│     Intro    │  Verse 1   │  Chorus   │  Verse 2  │    │  ← Regions
├─────────────────────────────────────────────────────────┤
│ Drm │ Bas │ Gtr │ Vox │ Syn │ Pad │ FX  │ Bus │  ◄  ▶  │
│ ▓▓▓ │ ▓░░ │ ▓▓░ │ ▓░░ │ ░░░ │ ▓▓▓ │ ▓▓░ │ ▓▓▓ │        │
│ ║   │ ║   │ ║   │ ║   │ ║   │ ║   │ ║   │ ║   │        │  ← Mixer
│ ║▓▓ │ ║▓░ │ ║▓▓ │ ║▓░ │ ║░░ │ ║▓▓ │ ║▓▓ │ ║▓▓ │        │
│ M S │ M S │ M S │ M S │ M S │ M S │ M S │ M S │        │
├─────────────────────────────────────────────────────────┤
│  ◄◄  │  ▶  │  ⏹  │  ⏺  │    17.3.2    │  120 BPM     │  ← Transport
├─────────────────────────────────────────────────────────┤
│[Studio]│Timeline│ Mixer │ Clock │ Cues │ Actions│Notes │
└─────────────────────────────────────────────────────────┘
```

**Why this is the default:**
- Solo musicians get everything they need in one view
- No learning curve — works immediately
- Debugging is trivial — all controls accessible
- Research: *"radically simple, with complexity available but not required"*

**Who uses this:**
- Singer-songwriters with iPad mounted at instrument
- Home studio musicians who just want to play
- Developers testing the extension

---

### Timeline View

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

Always visible by default. This is the "beat a $15 keypad" differentiator. Can be hidden via Full Screen Mode for dedicated-device setups.

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
┌──────────────────────────────────────────────────────────────────────────┐
│ Studio │ Timeline │  Mixer  │  Clock  │  Cues  │  Actions  │  Notes     │
└──────────────────────────────────────────────────────────────────────────┘
```

- Equal-width tabs (7 tabs = ~14.3% each)
- Active tab highlighted
- Tap to switch (instant, no animation delay)
- Swipe left/right as secondary navigation (optional enhancement)

**Touch targets:** Each tab is full height of bar (~44-54pt) × ~14.3% width

**Phone adaptation:** On narrow screens, consider:
- Icon-only tabs (🏠 🎬 🎚️ ⏱️ 📋 ⚡ 📝)
- Scrollable tab bar
- Collapse Actions + Notes into "More" menu

---

## Frontend Architecture

### Why Not React Router

For a tablet control surface app, react-router is overkill:
- No URL changes needed (tablet stays on one "page")
- No browser back/forward needed
- No deep linking needed
- Simpler debugging (just check `currentView` state)
- One less dependency

**Approach:** State-based routing + feature folders.

### Folder Structure

```
src/
├── App.tsx                    # Root, holds currentView state
├── components/                # Shared UI components
│   ├── PersistentTransport.tsx
│   ├── TabBar.tsx
│   ├── Fader.tsx
│   ├── MeterBar.tsx
│   └── ...
├── views/                     # One folder per view
│   ├── studio/
│   │   ├── StudioView.tsx     # Main component
│   │   ├── index.ts           # Re-export
│   │   └── ...                # View-specific components
│   ├── timeline/
│   │   ├── TimelineView.tsx
│   │   └── index.ts
│   ├── mixer/
│   │   ├── MixerView.tsx
│   │   └── index.ts
│   ├── clock/
│   ├── cues/
│   ├── actions/
│   └── notes/
├── hooks/                     # Shared hooks
│   ├── useWebSocket.ts
│   ├── useTransport.ts
│   └── useTracks.ts
├── types/                     # Shared types
│   └── index.ts
└── viewRegistry.ts            # Maps view IDs to components
```

**Why feature folders:**
- Each view is isolated — easy to find all related code
- Adding a view = add folder + register in viewRegistry
- Claude can easily navigate: "look in `views/mixer/`"
- Deleting a view is clean — remove folder + registry entry

### View Registry Pattern

```typescript
// viewRegistry.ts
import { StudioView } from './views/studio';
import { TimelineView } from './views/timeline';
import { MixerView } from './views/mixer';
import { ClockView } from './views/clock';
import { CuesView } from './views/cues';
import { ActionsView } from './views/actions';
import { NotesView } from './views/notes';

export const views = {
  studio: StudioView,
  timeline: TimelineView,
  mixer: MixerView,
  clock: ClockView,
  cues: CuesView,
  actions: ActionsView,
  notes: NotesView,
} as const;

export type ViewId = keyof typeof views;
```

### App Root

```typescript
// App.tsx
import { useState, useEffect } from 'react';
import { views, ViewId } from './viewRegistry';
import { TabBar } from './components/TabBar';
import { PersistentTransport } from './components/PersistentTransport';
import { useReamoConnection } from './hooks/useReamoConnection';

const VIEW_STORAGE_KEY = 'reamo_current_view';

export function App() {
  const [currentView, setCurrentView] = useState<ViewId>(() => {
    return (localStorage.getItem(VIEW_STORAGE_KEY) as ViewId) || 'studio';
  });
  const [isFullScreen, setIsFullScreen] = useState(false);

  // Shared state from WebSocket
  const { tracks, transport, regions, sendCommand } = useReamoConnection();

  useEffect(() => {
    localStorage.setItem(VIEW_STORAGE_KEY, currentView);
  }, [currentView]);

  const ViewComponent = views[currentView];

  return (
    <div className="app">
      <main className="view-container">
        <ViewComponent
          tracks={tracks}
          transport={transport}
          regions={regions}
          sendCommand={sendCommand}
        />
      </main>

      {!isFullScreen && (
        <>
          <TabBar currentView={currentView} onViewChange={setCurrentView} />
          <PersistentTransport transport={transport} sendCommand={sendCommand} />
        </>
      )}
    </div>
  );
}
```

### Shared State Pattern

WebSocket connection and global state (tracks, transport, regions) live at App level or in a context. Views receive data as props and emit commands — keeping them stateless/presentational where possible.

```typescript
// Views are pure functions of state
interface ViewProps {
  tracks: Track[];
  transport: TransportState;
  regions: Region[];
  sendCommand: (cmd: Command) => void;
}

// Example view
export function MixerView({ tracks, sendCommand }: ViewProps) {
  return (
    <div className="mixer-view">
      {tracks.map(track => (
        <ChannelStrip
          key={track.idx}
          track={track}
          onVolumeChange={(vol) => sendCommand({
            command: 'track/setVolume',
            trackIdx: track.idx,
            volume: vol
          })}
        />
      ))}
    </div>
  );
}
```

This makes views easy to test and debug — they're just UI that renders state.

---

## Per-Device Memory

Each device remembers its last view. A tablet mounted as mixer stays on Mixer. A phone used for transport stays on Clock.

```typescript
// On mount — Studio is default
const savedView = localStorage.getItem(VIEW_STORAGE_KEY) as ViewId || 'studio';

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

- [ ] Wrap existing layout as StudioView (default, no changes needed)
- [ ] Create TimelineView with arrangement visualization
- [ ] Refactor existing mixer into MixerView component
- [ ] Create ClockView with large transport buttons
- [ ] Create placeholder CuesView (links to Cue List feature)
- [ ] Create placeholder ActionsView (links to Quick Actions feature)
- [ ] Create placeholder NotesView (links to Project Notes feature)

### Phase 3: Full Screen Mode

- [ ] Implement double-tap to toggle full screen per view
- [ ] Add swipe-up-from-bottom to exit full screen
- [ ] Store full screen preference per-view in localStorage
- [ ] Add visual indicator showing full screen state

### Phase 4: Polish

- [ ] Add swipe gesture for view switching
- [ ] Implement time display format cycling
- [ ] Add BPM tap-to-edit
- [ ] Responsive layout (phone vs tablet)
- [ ] Stage Mode toggle (enlarge all controls 50%+)

---

## What About "Edit View"?

The previous spec had an "Edit" view combining timeline + regions + markers + mixer. This evolved into **Studio view** — keeping the all-in-one layout as an option rather than removing it entirely.

The research tension resolved:
- *"Users want to see their actual timeline"* → Timeline view exists
- *"Radically simple, complexity available but not required"* → Studio view is the simple default
- *"Purpose-built views"* → Focused views exist for power users

Studio view IS the "everything at once" view, but positioned as the simple default rather than a power-user feature. New users get everything working immediately; power users discover focused views via the tab bar.

---

## Full Screen Mode

Each view can go full screen, hiding both the tab bar and persistent transport. This enables dedicated-device workflows without redundancy.

### Use Cases

- **Phone as clock:** Mount phone with big time display only, control transport from iPad
- **Tablet as mixer:** Full fader real estate, no wasted space on transport you control elsewhere
- **Multi-device setup:** Each device shows one focused view with maximum screen usage

### UX

**Toggle:** Double-tap anywhere in view area, or long-press on the current tab.

**Exit:** Swipe up from bottom edge, or double-tap again.

**Visual indicator:** Small dot or subtle badge on tab when full screen is active (visible when exiting).

### Layout in Full Screen

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                                                         │
│                                                         │
│                    ACTIVE VIEW AREA                     │
│                    (maximum space)                      │
│                                                         │
│                                                         │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

No tab bar. No transport bar. Just the view.

### State Persistence

Full screen preference is stored per-view in localStorage:

```typescript
interface ViewState {
  currentView: ViewId;
  previousView: ViewId | null;
  fullScreenViews: Set<ViewId>;  // Which views are in full screen mode
}

const FULLSCREEN_STORAGE_KEY = 'reamo_fullscreen_views';
```

When switching to a view that was previously full-screened, it opens in full screen again. The preference "sticks" per-device.

### Clock View Special Case

Clock view is the prime candidate for full screen — the transport controls are already in the view, making the persistent bar redundant. Consider auto-suggesting full screen on first Clock view access.

---

## Future Enhancements

- **Stage Mode:** Global toggle that enlarges all controls 50%+
- **Custom views:** Let users pick which components appear
- **Auto-switch:** Automatically switch to Clock when recording starts
- **View presets:** Save and recall view configurations
- **Gesture shortcuts:** Double-tap transport bar to toggle Clock view
