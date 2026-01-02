# REAPER API Consistency - FFI Validation Migration

**Status: ✅ COMPLETE**
**Last Updated: 2026-01-02**

## Executive Summary

Migrate FFI validation from `raw.zig` (pure C bindings) to `RealBackend` (validation wrapper). This follows the research-backed principle: **raw bindings should return exactly what REAPER returns**.

---

## Architecture Target

```
┌──────────────────┐     ┌──────────────────┐
│     raw.zig      │     │  MockBackend     │
│  Pure C binding  │     │  (injectable)    │
│  Returns f64     │     │  FFIError!T      │
└────────┬─────────┘     └────────┬─────────┘
         │                        │
         ▼                        │
┌──────────────────┐              │
│   RealBackend    │◄─────────────┘
│  Validates here  │    same signatures
│  FFIError!T      │
└──────────────────┘
```

**Principle**: `raw.zig` methods return exactly what REAPER's C API returns. All validation and type conversion happens in `RealBackend`.

---

## Phase 1: Audit ALL raw.zig Against REAPER Header

> **Do the audit FIRST** before making any changes. This ensures we know the complete scope.

Cross-reference every function in `raw.zig` against `docs/reaper_plugin_functions.h` to ensure return types match.

### Reference: REAPER C API Signatures

| C Function | C Return Type | raw.zig Method | Status |
|------------|--------------|----------------|--------|
| `GetPlayState()` | `int` | `playState()` → `c_int` | ✅ Correct |
| `GetPlayPosition()` | `double` | `playPosition()` → `f64` | ✅ Correct |
| `GetCursorPosition()` | `double` | `cursorPosition()` → `f64` | ✅ Correct |
| `GetToggleCommandState(int)` | `int` | `getCommandState()` → `c_int` | ✅ Correct |
| `GetMediaTrackInfo_Value(MediaTrack*, const char*)` | `double` | Various → should be `f64` | ⚠️ Some incorrect |
| `GetMediaItemInfo_Value(MediaItem*, const char*)` | `double` | Various → should be `f64` | ⚠️ Some incorrect |
| `Track_GetPeakInfo(MediaTrack*, int)` | `double` | `getTrackPeakInfo()` → `f64` | ✅ Correct |
| `Track_GetPeakHoldDB(MediaTrack*, int, bool)` | `double` | `getTrackPeakHoldDB()` → `f64` | ✅ Correct |
| `CountTracks(ReaProject*)` | `int` | `trackCount()` → `c_int` | ✅ Correct |
| `CountTrackMediaItems(MediaTrack*)` | `int` | `trackItemCount()` → `c_int` | ✅ Correct |
| `GetProjectLength(ReaProject*)` | `double` | `projectLength()` → `f64` | ✅ Correct |

### Methods to Audit (GetMediaTrackInfo_Value wrappers)

| raw.zig Method | Param | C Return | Current | Should Be | Status |
|----------------|-------|----------|---------|-----------|--------|
| `getTrackVolume` | `D_VOL` | `double` | `f64` | `f64` | ✅ |
| `getTrackPan` | `D_PAN` | `double` | `f64` | `f64` | ✅ |
| `getTrackMute` | `B_MUTE` | `double` | `bool` | `f64` | ⚠️ Does `!= 0` |
| `getTrackSolo` | `I_SOLO` | `double` | `FFIError!c_int` | `f64` | ❌ Change |
| `getTrackRecArm` | `I_RECARM` | `double` | `bool` | `f64` | ⚠️ Does `!= 0` |
| `getTrackRecMon` | `I_RECMON` | `double` | `FFIError!c_int` | `f64` | ❌ Change |
| `getTrackFxEnabled` | `I_FXEN` | `double` | `bool` | `f64` | ⚠️ Does `!= 0` |
| `getTrackSelected` | `I_SELECTED` | `double` | `bool` | `f64` | ⚠️ Does `!= 0` |
| `getTrackColor` | `I_CUSTOMCOLOR` | `double` | `c_int` | `f64` | ❌ Change |

### Methods to Audit (GetMediaItemInfo_Value wrappers)

| raw.zig Method | Param | C Return | Current | Should Be | Status |
|----------------|-------|----------|---------|-----------|--------|
| `getItemPosition` | `D_POSITION` | `double` | `f64` | `f64` | ✅ |
| `getItemLength` | `D_LENGTH` | `double` | `f64` | `f64` | ✅ |
| `getItemColor` | `I_CUSTOMCOLOR` | `double` | `c_int` | `f64` | ❌ Change |
| `getItemLocked` | `C_LOCK` | `double` | `bool` | `f64` | ❌ Change |
| `getItemSelected` | `B_UISEL` | `double` | `bool` | `f64` | ❌ Change |
| `getItemActiveTakeIdx` | `I_CURTAKE` | `double` | `c_int` | `f64` | ❌ Change |

### Additional Methods Verified

| C Function | C Return | raw.zig Method | Status |
|------------|----------|----------------|--------|
| `CountProjectMarkers(...)` | `int` | `markerCount()` → struct | ✅ Correct |
| `EnumProjectMarkers3(...)` | `int` | `enumMarker()` → `?MarkerInfo` | ✅ Correct |
| `SetProjectMarker4(...)` | `bool` | `updateMarker/Region()` → `bool` | ✅ Correct |
| `DeleteProjectMarker(...)` | `bool` | `deleteMarker/Region()` → `bool` | ✅ Correct |
| `CreateTakeAudioAccessor(...)` | `AudioAccessor*` | `makeTakeAccessor()` → `?*anyopaque` | ✅ Correct |
| `DestroyAudioAccessor(...)` | `void` | `destroyTakeAccessor()` → `void` | ✅ Correct |
| `GetAudioAccessorSamples(...)` | `int` | `readAccessorSamples()` → `c_int` | ✅ Correct |

### Audit Progress

| Step | Status | Notes |
|------|--------|-------|
| Audit transport methods | ✅ Complete | All correct |
| Audit track methods | ✅ Complete | 3 methods need changes (Solo, RecMon, Color) |
| Audit item methods | ✅ Complete | 4 methods need changes (Color, Locked, Selected, ActiveTakeIdx) |
| Audit metering methods | ✅ Complete | All correct |
| Audit marker methods | ✅ Complete | All correct |
| Document discrepancies | ✅ Complete | 7 methods total need migration |

---

## Known Issue: Boolean NaN Handling (Tech Debt)

Methods using `!= 0` comparison (getTrackMute, getTrackRecArm, etc.) won't crash on NaN but may return incorrect `true` values. This is low-priority because:
- NaN indicates stale pointer (track likely deleted)
- Track will be removed on next refresh cycle
- Incorrect mute=true for 33ms is not user-visible

**Current decision**: Keep boolean comparisons for now. They're technically safe and widely used.

**Future fix:** Validate float before comparison, return `FFIError!bool`.

---

## Phase 2: Per-Method Atomic Migration

> **Strategy**: Update each method atomically across all layers, then test. This avoids broken intermediate states.

For each method requiring change:
1. Change raw.zig → return `f64`
2. Update RealBackend → add `ffi.safeFloatToInt` validation
3. Update MockBackend → match signature, add injectable error field
4. Verify: `zig build test --summary all`
5. Commit

### Methods Requiring Migration

| Method | raw.zig Change | RealBackend Change | MockBackend Change | Status |
|--------|---------------|-------------------|-------------------|--------|
| `getTrackSolo` | `FFIError!c_int` → `f64` | Add `safeFloatToInt` call | Add `inject_getTrackSolo_error` | ⬜ |
| `getTrackRecMon` | `FFIError!c_int` → `f64` | Add `safeFloatToInt` call | Add `inject_getTrackRecMon_error` | ⬜ |
| `getTrackColor` | `c_int` → `f64` | `c_int` → `FFIError!c_int` + validation | Add `inject_getTrackColor_error` | ⬜ |
| `getItemColor` | `c_int` → `f64` | `c_int` → `FFIError!c_int` + validation | Add `inject_getItemColor_error` | ⬜ |
| `getItemLocked` | `bool` → `f64` | `bool` → `FFIError!bool` + validation | Add `inject_getItemLocked_error` | ⬜ |
| `getItemSelected` | `bool` → `f64` | `bool` → `FFIError!bool` + validation | Add `inject_getItemSelected_error` | ⬜ |
| `getItemActiveTakeIdx` | `c_int` → `f64` | `c_int` → `FFIError!c_int` + validation | Add `inject_getItemActiveTakeIdx_error` | ⬜ |

### Cleanup After All Methods

- [ ] Remove `ffi` import from `raw.zig`
- [ ] Remove local `safeFloatToInt` helper from `raw.zig` (lines 301-308)

---

## Phase 3: Update Callers (State Modules)

State modules that call these methods need to handle errors gracefully.

### Caller Discovery

Run before making changes to find all call sites:

```bash
# Find all callers of methods being migrated
grep -rn "getTrackColor\|getItemColor\|getItemLocked\|getItemSelected\|getItemActiveTakeIdx" src/

# Find all callers of already-error-union methods
grep -rn "getTrackSolo\|getTrackRecMon" src/

# Find any direct raw.zig usage (should be RealBackend only)
grep -rn "\.inner\.get" src/

# Verify no test files directly import raw.zig
grep -l "raw\.zig" src/**/*_test.zig 2>/dev/null || echo "None found"
```

### Graceful Degradation Strategy

```zig
// Use cached value on transient errors (1-2 consecutive)
// Mark stale after 3 consecutive errors
const solo_result = api.getTrackSolo(track);
if (solo_result) |value| {
    cached.solo = value;
    error_count = 0;
} else |err| {
    error_count +|= 1;
    if (error_count >= 3) {
        track_stale = true;
    }
    // Use cached value
}
```

### Files to Update

- [ ] Run caller discovery grep
- [ ] Document all call sites found
- [ ] `tracks.zig` - track state polling
- [ ] `items.zig` - item state polling
- [ ] Any command handlers that call these methods
- [ ] Run tests: `zig build test --summary all`

---

## Implementation Log

### Phase 1 (Audit) Progress - ✅ COMPLETE

| Step | Status | Notes |
|------|--------|-------|
| Audit transport methods | ✅ Complete | All correct |
| Audit track methods | ✅ Complete | 3 methods migrated (Solo, RecMon, Color) |
| Audit item methods | ✅ Complete | 4 methods migrated (Color, Locked, Selected, ActiveTakeIdx) |
| Audit metering methods | ✅ Complete | All correct |
| Audit marker methods | ✅ Complete | All correct |

### Phase 2 (Per-Method Migration) Progress - ✅ COMPLETE

| Method | raw.zig | RealBackend | MockBackend | Tests | Status |
|--------|---------|-------------|-------------|-------|--------|
| `getTrackSolo` | ✅ f64 | ✅ validation | ✅ injectable | ✅ pass | Complete |
| `getTrackRecMon` | ✅ f64 | ✅ validation | ✅ injectable | ✅ pass | Complete |
| `getTrackColor` | ✅ f64 | ✅ validation | ✅ injectable | ✅ pass | Complete |
| `getItemColor` | ✅ f64 | ✅ validation | ✅ injectable | ✅ pass | Complete |
| `getItemLocked` | ✅ f64 | ✅ validation | ✅ injectable | ✅ pass | Complete |
| `getItemSelected` | ✅ f64 | ✅ validation | ✅ injectable | ✅ pass | Complete |
| `getItemActiveTakeIdx` | ✅ f64 | ✅ validation | ✅ injectable | ✅ pass | Complete |

**Cleanup**: Removed `ffi` import and local `safeFloatToInt` from raw.zig

### Phase 3 (Callers) Progress - ✅ COMPLETE

| Step | Status | Notes |
|------|--------|-------|
| Update tracks.zig | ✅ Complete | Track.color now `?c_int`, uses `catch null` |
| Update items.zig | ✅ Complete | Item fields now nullable, uses `catch null` |
| JSON serialization | ✅ Complete | Handles null values for corrupt data |
| All tests passing | ✅ Complete | 309/309 tests pass |

---

## Test Commands

```bash
# Build check (catch compile errors)
cd extension && zig build

# Run all tests
cd extension && zig build test --summary all

# Find callers of migrated methods
grep -rn "getTrackColor\|getItemColor\|getItemLocked" src/

# Find any raw.zig leakage
grep -rn "\.inner\.get" src/  # Should only be in RealBackend
```

---

## References

- [REAPER API Header](../docs/reaper_plugin_functions.h) - Official C function signatures
- [FFI Validation Research](./RESILIENT_ZIG_EXTENSION.md) - Error handling patterns
- [API Refactor Doc](./REAPER_API_FILE_REFACTOR.md) - Testability architecture
