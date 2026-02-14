# Tuner Frontend Implementation Handover

This document provides all context needed to implement the tuner UI in the React frontend.

---

## Backend Implementation (Complete)

The Zig extension backend is fully implemented and tested. It provides:

1. **JSFX auto-insertion** - PitchDetect JSFX inserted into Input FX chain at position 0
2. **GUID-based tracking** - Robust against user reordering the FX chain
3. **30Hz polling** - Real-time pitch detection data broadcast to subscribed clients
4. **Ref-counting** - Multiple clients can share one track's tuner

---

## API Reference

### Commands

#### `tuner/subscribe`

Subscribe to tuner on a track. Inserts JSFX if first subscriber.

```json
{
  "type": "command",
  "command": "tuner/subscribe",
  "trackGuid": "{TRACK-GUID-HERE}",
  "id": "1"
}
```

**Response:**

```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "payload": {
    "trackGuid": "{AAA}",
    "fxGuid": "{BBB}",
    "trackName": "Guitar",
    "reference": 440.0,
    "threshold": -60.0
  }
}
```

**Behavior:**

- Each client can subscribe to ONE track's tuner at a time
- Subscribing auto-unsubscribes from previous track
- Multiple clients can share a single track's JSFX (ref-counted)
- JSFX is inserted at position 0 in Input FX chain

#### `tuner/unsubscribe`

Unsubscribe from tuner. Removes JSFX if this was the last subscriber.

```json
{
  "type": "command",
  "command": "tuner/unsubscribe",
  "id": "1"
}
```

#### `tuner/setParam`

Set tuner parameters (reference frequency or silence threshold).

```json
{
  "type": "command",
  "command": "tuner/setParam",
  "trackGuid": "{AAA}",
  "param": "reference",
  "value": 442.0,
  "id": "1"
}
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `trackGuid` | string | Track GUID |
| `param` | `"reference"` or `"threshold"` | Parameter to set |
| `value` | float | Reference: Hz (400-480), Threshold: dB (-96 to 0) |

### Events

#### `tuner` Event

Sent to subscribed clients at 30Hz with pitch detection data.

```json
{
  "type": "event",
  "event": "tuner",
  "payload": {
    "trackGuid": "{AAA}",
    "freq": 440.0,
    "note": 69,
    "noteName": "A",
    "octave": 4,
    "cents": -2.5,
    "conf": 0.95,
    "inTune": false
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `trackGuid` | string | Track GUID |
| `freq` | float | Detected frequency in Hz (0 = no signal) |
| `note` | int | MIDI note number (69 = A4) |
| `noteName` | string | Note name: "C", "C#", "D", etc. |
| `octave` | int | Octave number (4 for A4) |
| `cents` | float | Deviation from note (-50 to +50) |
| `conf` | float | Detection confidence (0-1) |
| `inTune` | bool | True when `|cents| < 2` |

#### `tunerError` Event

Sent when the tuner can no longer function. Client is auto-unsubscribed.

```json
{
  "type": "event",
  "event": "tunerError",
  "error": "TUNER_NOT_FOUND"
}
```

Error codes:

- `TUNER_NOT_FOUND` - Track or tuner JSFX no longer exists
- `GENERATION_FAILED` - Failed to read pitch data

---

## Frontend Implementation Plan

### 1. State Management (Zustand Slice)

Create `frontend/src/store/slices/tunerSlice.ts` following the established pattern from `routingSlice.ts`:

```typescript
import type { StateCreator } from 'zustand';
import type { TunerEventPayload } from '../../core/WebSocketTypes';

export interface TunerSlice {
  // Subscription state
  /** GUID of the currently subscribed track (null = not subscribed) */
  tunerSubscribedGuid: string | null;

  // Current tuner data (from 30Hz events)
  tunerFreq: number;
  tunerNote: number;
  tunerNoteName: string;
  tunerOctave: number;
  tunerCents: number;
  tunerConf: number;
  tunerInTune: boolean;

  // Settings (persisted to localStorage separately)
  tunerReferenceHz: number;

  // Actions
  /** Set subscription state (call before sending tuner/subscribe command) */
  setTunerSubscription: (trackGuid: string | null) => void;
  /** Handle incoming tuner event from backend (30Hz) */
  handleTunerEvent: (payload: TunerEventPayload) => void;
  /** Handle tuner error (auto-unsubscribes) */
  handleTunerError: (error: string) => void;
  /** Clear subscription and data (call after sending tuner/unsubscribe command) */
  clearTunerSubscription: () => void;
  /** Update reference Hz (sends command to backend) */
  setTunerReferenceHz: (hz: number) => void;
}

export const createTunerSlice: StateCreator<TunerSlice, [], [], TunerSlice> = (set, get) => ({
  // Initial state
  tunerSubscribedGuid: null,
  tunerFreq: 0,
  tunerNote: 0,
  tunerNoteName: '',
  tunerOctave: 0,
  tunerCents: 0,
  tunerConf: 0,
  tunerInTune: false,
  tunerReferenceHz: 440,

  setTunerSubscription: (trackGuid) =>
    set({
      tunerSubscribedGuid: trackGuid,
      // Clear old data when subscription changes
      tunerFreq: 0,
      tunerNote: 0,
      tunerNoteName: '',
      tunerOctave: 0,
      tunerCents: 0,
      tunerConf: 0,
      tunerInTune: false,
    }),

  handleTunerEvent: (payload) => {
    const currentGuid = get().tunerSubscribedGuid;
    if (!currentGuid || payload.trackGuid !== currentGuid) return;

    set({
      tunerFreq: payload.freq,
      tunerNote: payload.note,
      tunerNoteName: payload.noteName,
      tunerOctave: payload.octave,
      tunerCents: payload.cents,
      tunerConf: payload.conf,
      tunerInTune: payload.inTune,
    });
  },

  handleTunerError: (_error) => {
    // Auto-unsubscribed by backend, clear local state
    set({
      tunerSubscribedGuid: null,
      tunerFreq: 0,
      tunerNote: 0,
      tunerNoteName: '',
      tunerOctave: 0,
      tunerCents: 0,
      tunerConf: 0,
      tunerInTune: false,
    });
  },

  clearTunerSubscription: () =>
    set({
      tunerSubscribedGuid: null,
      tunerFreq: 0,
      tunerNote: 0,
      tunerNoteName: '',
      tunerOctave: 0,
      tunerCents: 0,
      tunerConf: 0,
      tunerInTune: false,
    }),

  setTunerReferenceHz: (hz) => set({ tunerReferenceHz: hz }),
});
```

**Don't forget to:**

1. Add `TunerSlice` to the combined store type in `store/index.ts`
2. Import and spread `createTunerSlice(set, get, store)` in the store creation

### 2. WebSocket Types & Event Handlers

The codebase uses type guard functions for event routing. Add to `frontend/src/core/WebSocketTypes.ts`:

```typescript
// =============================================================================
// Tuner Event (per-client, pushed by backend at 30Hz)
// =============================================================================

export interface TunerEventPayload {
  trackGuid: string;
  freq: number;      // Detected frequency in Hz (0 = no signal)
  note: number;      // MIDI note number (69 = A4)
  noteName: string;  // "C", "C#", "D", etc.
  octave: number;    // Octave number (4 for A4)
  cents: number;     // Deviation from note (-50 to +50)
  conf: number;      // Detection confidence (0-1)
  inTune: boolean;   // True when |cents| < 2
}

export interface TunerErrorEventPayload {
  error: string;     // "TUNER_NOT_FOUND" | "GENERATION_FAILED"
}

// Add type guards at the bottom of the file:
export function isTunerEvent(
  msg: EventMessage
): msg is EventMessage & { payload: TunerEventPayload } {
  return msg.event === 'tuner';
}

export function isTunerErrorEvent(
  msg: EventMessage
): msg is EventMessage & { error: string } {
  return msg.event === 'tunerError';
}
```

Then add to `frontend/src/store/index.ts` in the `handleWebSocketMessage` function:

```typescript
import { isTunerEvent, isTunerErrorEvent } from '../core/WebSocketTypes';

// In handleWebSocketMessage, add these cases:
} else if (isTunerEvent(message)) {
  const p = message.payload;
  get().handleTunerEvent(p);
} else if (isTunerErrorEvent(message)) {
  get().handleTunerError(message.error);
}
```

### 3. Component Structure

Following the codebase convention, views go in `views/` not `components/`:

```
frontend/src/views/tuner/
├── index.ts                    # Barrel export: export { TunerView } from './TunerView';
├── TunerView.tsx              # Main view component
├── TunerMeter.tsx             # Cents deviation meter
├── TunerNote.tsx              # Note name + octave display
├── TunerTrackSelector.tsx     # Track selection (BottomSheet pattern)
└── TunerSettings.tsx          # Reference Hz adjustment
```

The `useTuner` hook can live in `hooks/useTuner.ts` since it's subscription lifecycle logic.

### 4. Command Builders

Add to `frontend/src/core/WebSocketCommands.ts`:

```typescript
// =============================================================================
// Tuner Subscription Commands
// =============================================================================

export const tuner = {
  /**
   * Subscribe to tuner on a track. Inserts JSFX if first subscriber.
   * Each client can only subscribe to one track at a time.
   *
   * @param trackGuid - GUID of the track to tune
   */
  subscribe: (trackGuid: string): WSCommand => ({
    command: 'tuner/subscribe',
    params: { trackGuid },
  }),

  /** Unsubscribe from tuner. Removes JSFX if last subscriber. */
  unsubscribe: (): WSCommand => ({
    command: 'tuner/unsubscribe',
  }),

  /**
   * Set tuner parameter (reference frequency or silence threshold).
   *
   * @param trackGuid - GUID of the track
   * @param param - "reference" (Hz, 400-480) or "threshold" (dB, -96 to 0)
   * @param value - Parameter value
   */
  setParam: (trackGuid: string, param: 'reference' | 'threshold', value: number): WSCommand => ({
    command: 'tuner/setParam',
    params: { trackGuid, param, value },
  }),
};
```

### 5. Track Selection

Use existing track skeleton data for the track selector. Follow the `InputSelectionSheet` pattern for BottomSheet-based selection:

```typescript
import { EMPTY_TRACKS } from '../store/stableRefs';

const tracks = useReaperStore((s) => s.tracks ?? EMPTY_TRACKS);
const tracksArray = Object.entries(tracks)
  .filter(([_, t]) => !t.isMaster)
  .sort((a, b) => a[1].idx - b[1].idx);

// Prefer record-armed tracks (show at top or auto-select)
const armedTracks = tracksArray.filter(([_, t]) => t.armed);
const defaultTrack = armedTracks[0]?.[0] ?? tracksArray[0]?.[0] ?? null;
```

For the track selector UI, use `BottomSheet` from `components/Modal/BottomSheet.tsx` following the `InputSelectionSheet` pattern with scrollable list and check icons for current selection.

---

## UI/UX Requirements

### CRITICAL: Responsive Design

The tuner MUST work in both portrait and landscape orientations. Follow [UX_GUIDELINES.md](../../docs/architecture/frontend/UX_GUIDELINES.md).

#### Portrait Layout

```
┌─────────────────────────────┐
│        [Track Name]         │
├─────────────────────────────┤
│                             │
│           A 4               │  ← Large note display
│                             │
│    -50 ──────|────── +50    │  ← Cents meter
│            -2.5¢            │
│                             │
│         440.0 Hz            │  ← Frequency (smaller)
│                             │
├─────────────────────────────┤
│    [Track Selector ▼]       │
├─────────────────────────────┤
│        [Settings]           │  ← Reference Hz
└─────────────────────────────┘
```

#### Landscape Layout

```
┌───────────────────────────────────────────────────────┐
│  [Track]  │           A 4           │    Settings    │
│   Name    │                         │   (compact)    │
│           ├─────────────────────────┤                │
│  [Select  │  -50 ────|──── +50      │   440 Hz ref   │
│   Track]  │        -2.5¢            │                │
│           │       440.0 Hz          │                │
└───────────────────────────────────────────────────────┘
```

### View Registration

To add the tuner as a navigable view:

**1. Add to `frontend/src/viewRegistry.ts`:**

```typescript
import { TunerView } from './views/tuner';

export const views = {
  // ... existing views
  tuner: TunerView,
} as const;

export const viewMeta: Record<ViewId, { label: string; shortLabel?: string }> = {
  // ... existing metadata
  tuner: { label: 'Tuner' },
};
```

**2. Add to `TabBar.tsx` VIEW_ORDER:**

```typescript
const VIEW_ORDER: ViewId[] = ['timeline', 'mixer', 'clock', 'playlist', 'actions', 'notes', 'instruments', 'tuner'];
```

### ViewLayout Pattern (REQUIRED)

Use the `ViewLayout` component from `components/Layout/ViewLayout.tsx` - do NOT write raw flex containers:

```tsx
import { ViewLayout } from '../../components/Layout/ViewLayout';
import { ViewHeader } from '../../components/Layout/ViewHeader';

export function TunerView() {
  return (
    <ViewLayout
      viewId="tuner"
      header={
        <ViewHeader currentView="tuner">
          {/* View-specific controls go here */}
          <TrackName />
        </ViewHeader>
      }
      footer={<TunerSettings />}
      scrollable={false}  // Tuner content is centered, not scrollable
      className="bg-bg-app text-text-primary p-view"
    >
      {/* Main content - automatically gets flex-1 min-h-0 */}
      <div className="h-full flex flex-col items-center justify-center">
        <TunerNote />
        <TunerMeter />
        <TunerFrequencyDisplay />
      </div>
    </ViewLayout>
  );
}
```

**Why ViewLayout?** It guarantees the critical `flex-1 min-h-0` pattern that prevents content overflow, and ensures consistent structure across all views.

### Visual States

#### No Signal (freq = 0)

- Show "Waiting for signal..." with guitar icon
- Muted colors, subtle animation
- Display track name so user knows which track is monitored

#### Signal Detected

- Large note name (96px+ portrait, 72px+ landscape)
- Octave number (smaller, beside note)
- Cents meter with color-coded indicator:
  - **Green** (`|cents| < 2`): In tune
  - **Yellow** (`|cents| < 10`): Close
  - **Red** (`|cents| >= 10`): Out of tune

#### In Tune Celebration

- Brief visual feedback when `inTune` becomes true
- Consider haptic feedback: `navigator.vibrate?.(10)`
- Don't be too flashy - musicians need to focus

### Color Tokens

Use semantic tokens from the design system:

```tsx
// In-tune indicator
className={cn(
  Math.abs(cents) < 2 && "bg-success text-on-success",
  Math.abs(cents) < 10 && Math.abs(cents) >= 2 && "bg-warning text-on-warning",
  Math.abs(cents) >= 10 && "bg-error text-on-error"
)}
```

### Touch Targets

- Track selector: minimum 48x48px
- Settings buttons: minimum 44x44px
- Follow Apple HIG for touch accessibility

---

## Implementation Checklist

### Phase 1: Core Functionality

- [ ] Create tunerSlice in Zustand store
- [ ] Add WebSocket event handlers
- [ ] Implement useTuner hook (subscribe/unsubscribe lifecycle)
- [ ] Create TunerView component with basic layout
- [ ] Add route/tab for tuner view

### Phase 2: UI Polish

- [ ] TunerMeter component with smooth animation
- [ ] TunerNote with responsive sizing
- [ ] No-signal state with helpful messaging
- [ ] In-tune celebration feedback

### Phase 3: Settings & Track Selection

- [ ] TunerTrackSelector with armed track preference
- [ ] Reference Hz adjustment (440 default, common: 432, 442, 443)
- [ ] Remember last selected track in localStorage

### Phase 4: Responsive Testing

- [ ] Test portrait on iPhone SE (smallest)
- [ ] Test portrait on iPhone 14 Pro Max
- [ ] Test landscape on all devices
- [ ] Test on iPad
- [ ] Verify no overflow/overlap in any orientation

---

## Reusable Components & Patterns

Before implementing custom components, check if these existing patterns apply:

| Need | Reuse | File |
|------|-------|------|
| View wrapper | `ViewLayout` | `components/Layout/ViewLayout.tsx` |
| View header | `ViewHeader` | `components/Layout/ViewHeader.tsx` |
| Track selector sheet | `BottomSheet` + list pattern | `components/Modal/BottomSheet.tsx`, `components/Mixer/InputSelectionSheet.tsx` |
| Settings sheet | `TimelineSettingsSheet` pattern | `components/Modal/TimelineSettingsSheet.tsx` |
| Color-coded status | `ConnectionStatus` pattern | `components/ConnectionStatus.tsx` |
| Audio meter | `LevelMeter` (colors, animation) | `components/Track/LevelMeter.tsx` |
| Stable empty refs | `EMPTY_TRACKS`, etc. | `store/stableRefs.ts` |
| Commands | `routing`, `trackFxParams` patterns | `core/WebSocketCommands.ts` |
| Slice pattern | `routingSlice` | `store/slices/routingSlice.ts` |

**Color tokens for tuner states:**

- In-tune: `bg-success`, `text-on-success`
- Close: `bg-warning`, `text-on-warning`
- Out of tune: `bg-error`, `text-on-error`

---

## Key Documents to Read

1. **[FRONTEND_DEVELOPMENT.md](../../frontend/FRONTEND_DEVELOPMENT.md)** - REQUIRED
   - Section 1: Design tokens (color usage)
   - Section 4: Memory safety (timer cleanup)
   - Section 6: Zustand patterns
   - Section 7: WebSocket usage
   - Section 9: Touch handling

2. **[UX_GUIDELINES.md](../../docs/architecture/frontend/UX_GUIDELINES.md)** - REQUIRED
   - Section 2: View layout template
   - Section 4: Height management
   - Section 9: Instruments orientation strategy

3. **[extension/API.md](../../extension/API.md)**
   - Tuner section for complete API reference
   - Protocol overview for message format

4. **[TUNER.md](./TUNER.md)**
   - Full specification including JSFX algorithm
   - Architecture diagram

## Key Source Files to Reference

| File | Why |
|------|-----|
| `views/clock/ClockView.tsx` | Real-time display, responsive sizing with `clamp()` |
| `views/mixer/MixerView.tsx` | Subscription lifecycle, bank navigation |
| `components/Modal/RoutingModal.tsx` | Per-track subscription pattern |
| `store/slices/routingSlice.ts` | Slice pattern for subscription state |
| `core/WebSocketTypes.ts` | Type guards and event payloads |
| `core/WebSocketCommands.ts` | Command builder pattern |
| `hooks/useTransportAnimation.ts` | 60fps ref-based updates |
| `components/Track/LevelMeter.tsx` | Color-coded meter animation |

---

## Gotchas & Tips

### 1. Subscribe on mount, unsubscribe on unmount

Follow the `RoutingModal` pattern - set store state BEFORE sending command:

```typescript
import { tuner } from '../core/WebSocketCommands';

const { sendCommand } = useReaper();
const setTunerSubscription = useReaperStore((s) => s.setTunerSubscription);
const clearTunerSubscription = useReaperStore((s) => s.clearTunerSubscription);

useEffect(() => {
  if (!selectedTrackGuid) return;

  // 1. Set store state first (prepares to receive events)
  setTunerSubscription(selectedTrackGuid);

  // 2. Send subscribe command
  sendCommand(tuner.subscribe(selectedTrackGuid));

  return () => {
    // 3. Unsubscribe on cleanup
    sendCommand(tuner.unsubscribe());
    clearTunerSubscription();
  };
}, [selectedTrackGuid, sendCommand, setTunerSubscription, clearTunerSubscription]);
```

### 2. Handle track deletion gracefully

The backend auto-unsubscribes and sends `tunerError`. UI should:

- Show error state briefly
- Fall back to track selector
- Don't crash if track no longer exists

### 3. Animation performance

Cents meter updates at 30Hz. Use CSS transitions OR ref-based DOM updates, not React state for position.

**Pattern 1: CSS transitions (simplest for tuner meter)**

```tsx
// Good - CSS handles animation, React just updates style prop
<div
  className="transition-[left] duration-50 ease-out"
  style={{ left: `${50 + cents}%` }}
/>
```

**Pattern 2: Ref-based DOM updates (for higher frequency)**

See `TimeDisplay.tsx` and `BarBeatDisplay.tsx` for examples using `useTransportAnimation`:

```tsx
// From TimeDisplay.tsx - bypasses React rendering entirely
const timeRef = useRef<HTMLSpanElement>(null);

useTransportAnimation((state) => {
  if (timeRef.current) {
    timeRef.current.textContent = formatTime(state.position);
  }
}, []);

return <span ref={timeRef}>0:00.0</span>;
```

**Bad - triggers 30 re-renders/second:**

```tsx
const [position, setPosition] = useState(50);
useEffect(() => setPosition(50 + cents), [cents]);
```

### 4. Don't show stale data

When `freq === 0`, don't show the last detected note - show "no signal" state.

### 5. Reference Hz persistence

Store in localStorage, restore on mount:

```typescript
const [referenceHz, setReferenceHz] = useState(() => {
  try {
    return parseFloat(localStorage.getItem('tuner-reference') ?? '440');
  } catch {
    return 440;
  }
});
```

---

## Testing the Backend

You can test the tuner backend using the reamo-ws skill or websocat:

```bash
# Subscribe to tuner on a track
/bin/bash -c '
TOKEN="<session-token>"
PORT="9224"
(echo "{\"type\":\"hello\",\"clientVersion\":\"1.0.0\",\"protocolVersion\":1,\"token\":\"$TOKEN\"}"
 echo "{\"type\":\"command\",\"command\":\"tuner/subscribe\",\"trackGuid\":\"{YOUR-TRACK-GUID}\",\"id\":\"1\"}"
 sleep 2) | /opt/homebrew/bin/websocat ws://localhost:$PORT 2>&1'
```

You'll see tuner events streaming at 30Hz with pitch data.

---

## Questions?

If anything is unclear, check:

1. The API.md tuner section
2. TUNER.md specification
3. Existing subscription implementations (peaks, trackFx, routing) for patterns
