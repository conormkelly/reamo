# Velocity Sensitivity for REAmo

## Technical Approach

### The Reality of Touch Pressure on Mobile

True pressure detection (`PointerEvent.pressure`) doesn't work on modern phones:

| Platform | `pressure` value |
|----------|------------------|
| iOS Safari (finger) | Always **0.5** — no pressure hardware since iPhone XR (2018) |
| iOS Safari (Apple Pencil) | Real 0-1 values ✓ |
| Android Chrome (finger) | Always **0.5** on most devices |
| Mouse | **0.5** when pressed, 0 otherwise |

The spec mandates 0.5 as the default for unsupported hardware. This is by design, not a bug.

### Solution: Contact Area as Pressure Proxy

Use `PointerEvent.width` and `PointerEvent.height` instead. Touchscreens physically detect the contact ellipse — harder presses spread the finger, creating a larger contact area.

| Platform | Contact area support |
|----------|---------------------|
| iOS Safari 13+ | ✓ Real values |
| Android Chrome 55+ | ✓ Real values |
| Mouse | Returns 1 (single point) |

Typical values:

- Light tap: ~15-25px
- Medium press: ~30-40px  
- Hard press: ~45-60px

Values vary by device DPI and screen size — calibration ranges are essential.

---

## Core Implementation

```typescript
interface VelocityConfig {
  enabled: boolean;
  curve: 'soft' | 'medium' | 'hard';
  minVelocity: number;      // lowest output (e.g., 35)
  maxVelocity: number;      // highest output (e.g., 127)
  minContactSize: number;   // calibration: light tap (e.g., 18)
  maxContactSize: number;   // calibration: hard press (e.g., 55)
}

const DEFAULT_CONFIG: VelocityConfig = {
  enabled: true,
  curve: 'medium',
  minVelocity: 35,
  maxVelocity: 127,
  minContactSize: 18,
  maxContactSize: 55,
};

function applyCurve(normalized: number, curve: VelocityConfig['curve']): number {
  switch (curve) {
    case 'soft':   return Math.sqrt(normalized);    // more velocity from light touch
    case 'medium': return normalized;                // linear
    case 'hard':   return normalized * normalized;   // need harder touch for high velocity
  }
}

function getVelocityFromPointerEvent(
  e: PointerEvent,
  config: VelocityConfig
): number {
  // Sensitivity disabled — return fixed velocity
  if (!config.enabled) {
    return config.maxVelocity; // or a separate fixedVelocity setting
  }

  // Check for real pressure first (Apple Pencil, some styluses)
  if (e.pressure > 0 && e.pressure !== 0.5) {
    const curved = applyCurve(e.pressure, config.curve);
    return Math.round(
      config.minVelocity + curved * (config.maxVelocity - config.minVelocity)
    );
  }

  // Use contact area (primary method for finger touch)
  const contactSize = Math.max(e.width, e.height);

  // Mouse or unsupported device — return midpoint or fixed
  if (contactSize <= 1) {
    return Math.round((config.minVelocity + config.maxVelocity) / 2);
  }

  // Normalize contact size to 0-1 range
  const normalized = Math.min(1, Math.max(0,
    (contactSize - config.minContactSize) /
    (config.maxContactSize - config.minContactSize)
  ));

  // Apply curve and map to velocity range
  const curved = applyCurve(normalized, config.curve);
  
  return Math.round(
    config.minVelocity + curved * (config.maxVelocity - config.minVelocity)
  );
}
```

---

## UX Design

### Design Principles

1. **Progressive disclosure** — simple default that works, power options hidden
2. **Global + override** — one setting for everything, per-instrument customization for power users
3. **Test pad required** — users must feel the response, not guess at numbers
4. **Presets over curves** — three response options cover 95% of needs

### Settings Hierarchy

```
Settings
└── Touch Sensitivity
    ├── [Toggle] Enable velocity sensitivity
    ├── [Selector] Response curve: Soft / Medium / Hard
    ├── [Range slider] Velocity range: min ←→ max
    ├── [Test Pad] Tap to see/hear velocity
    │
    └── [Expandable] Per-instrument settings
        ├── Drum Pads: [Use global] / Custom
        ├── Piano: [Use global] / Custom
        └── Chord Pads: [Use global] / Custom
```

### Control Specifications

#### 1. Master Toggle

| State | Behavior |
|-------|----------|
| **On** | Contact-area velocity active |
| **Off** | Fixed velocity (show single slider for fixed value) |

Some users explicitly want no velocity variation for consistent mixing.

#### 2. Response Curve (3 Presets)

| Preset | Curve | Who it's for |
|--------|-------|--------------|
| **Soft** | `√x` (square root) | Heavy-handed players; more range from gentle playing |
| **Medium** | `x` (linear) | Default; most users |
| **Hard** | `x²` (quadratic) | Light-touch players who trigger too easily |

Why not a custom curve editor? Overkill for mobile. Three presets suffice.

#### 3. Velocity Range (Dual Slider)

```
Velocity Range
  35 ●━━━━━━━━━━━━━━━━━● 127
     min               max
```

- **Min**: Lightest touch produces this. Prevents silent notes. Default: 35
- **Max**: Hardest touch produces this. Some users cap for mixing. Default: 127

More intuitive than abstract "sensitivity" — maps directly to MIDI values.

#### 4. Test Pad (Essential)

```
┌─────────────────────────────┐
│                             │
│            87               │  ← velocity number, large
│     ████████████░░░░░       │  ← visual bar
│                             │
│        Tap to test          │
└─────────────────────────────┘
```

- Shows velocity number on each hit (big, readable)
- Visual bar fills proportionally
- Optional: play preview sound if audio enabled
- Number fades after ~1 second

Without this, users can't calibrate effectively.

#### 5. Per-Instrument Override (Hidden by Default)

Expandable section. Each instrument shows:

- **Use global** (default, checkmark)
- **Custom** → reveals same controls (curve, range, test pad)

**Use case**: Piano sensitive (soft curve), drums need harder hit (hard curve).

---

## Mobile UI Layout

### Collapsed (in settings list)

```
Touch Sensitivity              [On] >
```

### Expanded (dedicated screen)

```
← Touch Sensitivity

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[■■■■■■ ON ■■■■■■]  [   off   ]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Response
┌────────┐ ┌────────┐ ┌────────┐
│  Soft  │ │ MEDIUM │ │  Hard  │
└────────┘ └────────┘ └────────┘
                ▲ selected

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Velocity Range
   35 ●━━━━━━━━━━━━━━━━● 127

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

┌─────────────────────────────┐
│                             │
│            --               │
│                             │
│        Tap to test          │
└─────────────────────────────┘

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

▶ Per-instrument settings
```

### When Sensitivity is OFF

```
← Touch Sensitivity

[   on   ]  [■■■■■ OFF ■■■■■]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Fixed Velocity
─────────────────●───────── 100

All notes will play at velocity 100.
```

---

## State Management

```typescript
interface SensitivitySettings {
  enabled: boolean;
  curve: 'soft' | 'medium' | 'hard';
  minVelocity: number;
  maxVelocity: number;
  fixedVelocity: number;  // used when enabled=false
}

interface PerInstrumentSettings {
  drums: SensitivitySettings | 'global';
  piano: SensitivitySettings | 'global';
  chordPads: SensitivitySettings | 'global';
}

interface VelocityState {
  global: SensitivitySettings;
  instruments: PerInstrumentSettings;
  // Calibration (could be auto-detected or manual)
  calibration: {
    minContactSize: number;
    maxContactSize: number;
  };
}

const DEFAULT_STATE: VelocityState = {
  global: {
    enabled: true,
    curve: 'medium',
    minVelocity: 35,
    maxVelocity: 127,
    fixedVelocity: 100,
  },
  instruments: {
    drums: 'global',
    piano: 'global',
    chordPads: 'global',
  },
  calibration: {
    minContactSize: 18,
    maxContactSize: 55,
  },
};
```

### Getting Effective Settings for an Instrument

```typescript
function getEffectiveSettings(
  state: VelocityState,
  instrument: keyof PerInstrumentSettings
): SensitivitySettings {
  const instrumentSetting = state.instruments[instrument];
  return instrumentSetting === 'global' 
    ? state.global 
    : instrumentSetting;
}
```

---

## Deferred Features (V2+)

| Feature | Rationale for deferring |
|---------|------------------------|
| **Custom curve editor** | Three presets cover 95% of needs |
| **Per-pad velocity** (drums) | Complex UI; snare vs hi-hat defaults can wait |
| **Calibration wizard** | Test pad + presets is enough initially |
| **Velocity "amount" slider** | Confusing; min/max range is more intuitive |
| **Auto-calibration** | Needs data collection; start with sensible defaults |

---

## Integration Points

### Drum Pads

```typescript
function handleDrumPadHit(e: PointerEvent, padId: string) {
  const settings = getEffectiveSettings(state, 'drums');
  const velocity = getVelocityFromPointerEvent(e, {
    ...settings,
    ...state.calibration,
  });
  sendMidiNoteOn(padId, velocity);
}
```

### Piano Keys

```typescript
function handlePianoKeyDown(e: PointerEvent, note: number) {
  const settings = getEffectiveSettings(state, 'piano');
  const velocity = getVelocityFromPointerEvent(e, {
    ...settings,
    ...state.calibration,
  });
  sendMidiNoteOn(note, velocity);
}
```

### Chord Pads

```typescript
function handleChordPadHit(e: PointerEvent, chordNotes: number[]) {
  const settings = getEffectiveSettings(state, 'chordPads');
  const velocity = getVelocityFromPointerEvent(e, {
    ...settings,
    ...state.calibration,
  });
  // All notes in chord get same velocity
  chordNotes.forEach(note => sendMidiNoteOn(note, velocity));
}
```

---

## Summary

1. **Use contact area** (`width`/`height`) as the velocity source — it works everywhere
2. **Default to enabled** with medium curve, 35-127 range
3. **Provide test pad** so users can feel the response
4. **Three curve presets** (soft/medium/hard) instead of complex curve editor
5. **Global settings + per-instrument override** for power users
6. **Fixed velocity mode** when sensitivity is disabled
