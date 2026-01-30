# REAmo Tuner Test Script

Automated accuracy testing for the REAmo Tuner JSFX using REAPER's built-in Tone Generator.

## Prerequisites

1. **Tuner JSFX installed** at `<REAPER>/Effects/REAmo/PitchDetect.jsfx`
2. **REAPER's Tone Generator** available (included with REAPER)

## How It Works

1. Creates a muted test track
2. Adds Tone Generator → PitchDetect in the FX chain
3. Iterates through known frequencies
4. Compares tuner output against expected values
5. Reports pass/fail with error margins

## Test Cases

| Frequency | Note | Description |
|-----------|------|-------------|
| 82.41 Hz | E2 | Low guitar string |
| 110.00 Hz | A2 | Bass range |
| 220.00 Hz | A3 | Mid range |
| 440.00 Hz | A4 | Reference pitch |
| 329.63 Hz | E4 | High guitar string |
| 880.00 Hz | A5 | Upper range |
| 440 +5¢ | A4 | Cents accuracy |
| 440 -5¢ | A4 | Cents accuracy |
| 440 +25¢ | A4 | Cents accuracy |
| 440 -25¢ | A4 | Cents accuracy |

## Running the Test

1. Open REAPER
2. Actions → Show action list → ReaScript: Load...
3. Select `tuner_test.lua`
4. View results in the ReaScript console (View → ReaScript console)

---

## Lua Test Script

Save as `Scripts/REAmo/tuner_test.lua`:

```lua
-- REAmo Tuner Accuracy Test
-- Creates a muted track with tone generator -> tuner, runs test cases

local TEST_CASES = {
  -- { freq, expected_midi_note, expected_octave, description }
  { 82.41, 40, 2, "E2 - Low guitar" },
  { 110.00, 45, 2, "A2" },
  { 220.00, 57, 3, "A3" },
  { 440.00, 69, 4, "A4 - Reference" },
  { 329.63, 64, 4, "E4 - High guitar" },
  { 880.00, 81, 5, "A5" },
  -- Cents accuracy tests (A4 +/- offset)
  { 440 * 2^(5/1200), 69, 4, "A4 +5 cents" },
  { 440 * 2^(-5/1200), 69, 4, "A4 -5 cents" },
  { 440 * 2^(25/1200), 69, 4, "A4 +25 cents" },
  { 440 * 2^(-25/1200), 69, 4, "A4 -25 cents" },
}

local SETTLE_TIME = 0.2  -- seconds to wait for tuner to stabilize
local TOLERANCE_CENTS = 0.5  -- acceptable error

local track, gen_idx, tuner_idx
local current_test = 0
local results = {}
local test_start_time

-- Convert frequency to expected cents deviation from nearest note
local function freq_to_expected_cents(freq)
  local midi_float = 69 + 12 * math.log(freq / 440) / math.log(2)
  local midi_int = math.floor(midi_float + 0.5)
  return (midi_float - midi_int) * 100
end

local function setup()
  reaper.Undo_BeginBlock()

  -- Create track at end
  local track_count = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(track_count, true)
  track = reaper.GetTrack(0, track_count)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "Tuner Test", true)

  -- Mute track (no audio output)
  reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 1)

  -- Add tone generator
  gen_idx = reaper.TrackFX_AddByName(track, "JS: Tone Generator", false, -1)
  if gen_idx < 0 then
    reaper.ShowConsoleMsg("ERROR: Could not find 'JS: Tone Generator'\n")
    return false
  end

  -- Configure tone generator for clean sine
  reaper.TrackFX_SetParam(track, gen_idx, 0, 0)     -- Wet: 0 dB
  reaper.TrackFX_SetParam(track, gen_idx, 1, -120)  -- Dry: -120 dB (muted)
  reaper.TrackFX_SetParam(track, gen_idx, 3, 0)     -- Note offset: 0
  reaper.TrackFX_SetParam(track, gen_idx, 4, 0)     -- Octave: 0
  reaper.TrackFX_SetParam(track, gen_idx, 5, 0)     -- Fine tune: 0
  reaper.TrackFX_SetParam(track, gen_idx, 6, 0)     -- Shape: Sine

  -- Add tuner
  tuner_idx = reaper.TrackFX_AddByName(track, "REAmo/PitchDetect", false, -1)
  if tuner_idx < 0 then
    reaper.ShowConsoleMsg("ERROR: Could not find 'REAmo/PitchDetect'\n")
    reaper.ShowConsoleMsg("Make sure the JSFX is installed at:\n")
    reaper.ShowConsoleMsg("  <REAPER>/Effects/REAmo/PitchDetect.jsfx\n")
    return false
  end

  reaper.Undo_EndBlock("Tuner Test Setup", -1)
  return true
end

local function set_frequency(freq)
  reaper.TrackFX_SetParam(track, gen_idx, 2, freq)  -- slider3 = base freq
end

local function read_tuner()
  local freq = reaper.TrackFX_GetParam(track, tuner_idx, 0)
  local note = reaper.TrackFX_GetParam(track, tuner_idx, 1)
  local cents = reaper.TrackFX_GetParam(track, tuner_idx, 2)
  local confidence = reaper.TrackFX_GetParam(track, tuner_idx, 3)
  return freq, note, cents, confidence
end

local function print_results()
  reaper.ShowConsoleMsg("\n========== TUNER ACCURACY TEST RESULTS ==========\n\n")

  local passed = 0
  local failed = 0

  for i, r in ipairs(results) do
    local status = r.pass and "PASS" or "FAIL"
    if r.pass then passed = passed + 1 else failed = failed + 1 end

    reaper.ShowConsoleMsg(string.format(
      "[%s] %s\n" ..
      "  Input: %.2f Hz | Expected note: %d | Expected cents: %+.2f\n" ..
      "  Got:   %.2f Hz | Actual note: %.0f | Actual cents: %+.2f | Conf: %.1f%%\n" ..
      "  Error: %.3f Hz | Cents error: %+.3f\n\n",
      status, r.description,
      r.input_freq, r.expected_note, r.expected_cents,
      r.actual_freq, r.actual_note, r.actual_cents, r.confidence * 100,
      r.freq_error, r.cents_error
    ))
  end

  reaper.ShowConsoleMsg(string.format(
    "==================================================\n" ..
    "SUMMARY: %d passed, %d failed (tolerance: %.2f cents)\n" ..
    "==================================================\n",
    passed, failed, TOLERANCE_CENTS
  ))
end

local function cleanup()
  reaper.ShowConsoleMsg("\nTest track left in project for inspection.\n")
  reaper.ShowConsoleMsg("Delete manually when done.\n")
end

local function wait_and_measure()
  local elapsed = reaper.time_precise() - test_start_time

  if elapsed < SETTLE_TIME then
    reaper.defer(wait_and_measure)
    return
  end

  -- Read tuner values
  local tc = TEST_CASES[current_test]
  local actual_freq, actual_note, actual_cents, confidence = read_tuner()
  local expected_cents = freq_to_expected_cents(tc[1])

  -- Calculate error
  local freq_error = actual_freq - tc[1]
  local cents_error = actual_cents - expected_cents
  local note_correct = (math.floor(actual_note + 0.5) == tc[2])
  local pass = note_correct and math.abs(cents_error) <= TOLERANCE_CENTS

  table.insert(results, {
    description = tc[4],
    input_freq = tc[1],
    expected_note = tc[2],
    expected_cents = expected_cents,
    actual_freq = actual_freq,
    actual_note = actual_note,
    actual_cents = actual_cents,
    confidence = confidence,
    freq_error = freq_error,
    cents_error = cents_error,
    pass = pass
  })

  -- Next test
  reaper.defer(run_next_test)
end

function run_next_test()
  current_test = current_test + 1

  if current_test > #TEST_CASES then
    print_results()
    cleanup()
    return
  end

  local tc = TEST_CASES[current_test]
  reaper.ShowConsoleMsg(string.format("Testing: %s (%.2f Hz)...\n", tc[4], tc[1]))
  set_frequency(tc[1])
  test_start_time = reaper.time_precise()

  reaper.defer(wait_and_measure)
end

local function main()
  reaper.ShowConsoleMsg("\n\n")
  reaper.ShowConsoleMsg("==================================================\n")
  reaper.ShowConsoleMsg("        REAmo Tuner Accuracy Test\n")
  reaper.ShowConsoleMsg("==================================================\n\n")

  if not setup() then
    return
  end

  reaper.ShowConsoleMsg("Test track created. Running " .. #TEST_CASES .. " test cases...\n\n")

  -- Begin test sequence
  reaper.defer(run_next_test)
end

main()
```

---

## Expected Output

```
==================================================
        REAmo Tuner Accuracy Test
==================================================

Test track created. Running 10 test cases...

Testing: E2 - Low guitar (82.41 Hz)...
Testing: A2 (110.00 Hz)...
Testing: A3 (220.00 Hz)...
Testing: A4 - Reference (440.00 Hz)...
...

========== TUNER ACCURACY TEST RESULTS ==========

[PASS] E2 - Low guitar
  Input: 82.41 Hz | Expected note: 40 | Expected cents: +0.00
  Got:   82.41 Hz | Actual note: 40 | Actual cents: +0.02 | Conf: 98.2%
  Error: 0.001 Hz | Cents error: +0.020

[PASS] A4 - Reference
  Input: 440.00 Hz | Expected note: 69 | Expected cents: +0.00
  Got:   440.00 Hz | Actual note: 69 | Actual cents: +0.01 | Conf: 99.1%
  Error: 0.000 Hz | Cents error: +0.010

...

==================================================
SUMMARY: 10 passed, 0 failed (tolerance: 0.50 cents)
==================================================
```

---

## Extending the Tests

### Add octave error resistance test

Test with harmonically rich waveforms (saw/triangle) to verify the tuner doesn't jump octaves:

```lua
-- Add to TEST_CASES after changing shape to saw (param 6 = 2)
{ 82.41, 40, 2, "E2 - Saw wave (octave test)" },
```

### Add silence detection test

```lua
local function test_silence()
  -- Set wet mix to -120 dB (silence)
  reaper.TrackFX_SetParam(track, gen_idx, 0, -120)

  -- Wait and verify tuner reports 0 Hz
  -- ...
end
```

### Add low confidence test

Test with very quiet signals near the silence threshold.

---

## Tuner JSFX Parameter Reference

| Param | Slider | Purpose |
|-------|--------|---------|
| 0 | slider1 | Detected Frequency (Hz) |
| 1 | slider2 | MIDI Note Number |
| 2 | slider3 | Cents Deviation |
| 3 | slider4 | Confidence (0-1) |
| 4 | slider5 | Reference Pitch (A4) |

## Tone Generator Parameter Reference

| Param | Slider | Purpose |
|-------|--------|---------|
| 0 | slider1 | Wet Mix (dB) |
| 1 | slider2 | Dry Mix (dB) |
| 2 | slider3 | Base Frequency (Hz) |
| 3 | slider4 | Note (0-11) |
| 4 | slider5 | Octave (-4 to +4) |
| 5 | slider6 | Fine Tune (cents) |
| 6 | slider7 | Shape (0=Sine, 1=Tri, 2=Saw) |
