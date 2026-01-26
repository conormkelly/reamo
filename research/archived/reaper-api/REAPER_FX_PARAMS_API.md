# REAPER FX Parameter API: Web Controller Development Guide

REAPER's TrackFX_* API handles edge cases gracefully but lacks parameter count change notifications—**polling is required for robust controller applications**. Dynamic parameter changes are supported through Cockos-specific extensions, invalid indices fail silently without crashes, and native FX containers are fully accessible via a specialized indexing scheme. Third-party containers like Blue Cat's Patcher remain opaque to the API.

## Dynamic parameter counts: supported but notification-free

**Yes, VST/AU plugins can change parameter counts dynamically while loaded.** REAPER explicitly supports this through two mechanisms depending on plugin format.

For **VST2 plugins**, Cockos provides a proprietary extension using a vendor-specific callback:

```c
// Plugin notifies REAPER of parameter list change
int listadj[2] = { adjstartparmidx, adjnum };  // adjnum > 0 = added, < 0 = removed
audioMasterCallback(audioMasterVendorSpecific, 0xdeadbeef, audioMasterAutomate, listadj, 0.0);
```

This mechanism preserves automation on higher-indexed parameters when lower parameters are added or removed. For **VST3 plugins**, REAPER follows the Steinberg standard using `restartComponent` with `kReloadComponent`, which requires a brief processing stop/restart cycle.

`TrackFX_GetNumParams()` **returns the new count immediately** after changes—it queries the plugin directly without caching. However, there is **no CSurf callback** when parameter counts change internally. The `CSURF_EXT_SETFXCHANGE` notification only fires when FX are added, removed, or reordered on a track—not when a plugin's internal structure changes.

Real-world scenarios that trigger dynamic changes include multi-band processors adding bands, plugins with collapsible sections, and synths with dynamic modulation routings. Many plugins work around this limitation by allocating worst-case parameter counts upfront and disabling unused parameters.

## Invalid parameter indices fail gracefully

REAPER performs bounds checking on all TrackFX_* parameter functions. **No crashes, NaN values, or undefined behavior occur** with out-of-range indices.

| Function | Return Type | Invalid Index Behavior |
|----------|-------------|------------------------|
| `TrackFX_GetParamNormalized` | double | Returns **0.0** |
| `TrackFX_GetParam` | double | Returns **0.0**; minval/maxval set to 0.0 |
| `TrackFX_GetParamName` | bool | Returns **false**; buffer unchanged |
| `TrackFX_SetParam` | bool | Returns **false** (no effect) |
| `TrackFX_SetParamNormalized` | bool | Returns **false** (no effect) |
| `TrackFX_FormatParamValue` | bool | Returns **false**; buffer unchanged |

This safe-by-default behavior means your web controller won't crash if a plugin changes parameters between your count check and parameter access. However, best practice remains validating indices:

```lua
local param_count = reaper.TrackFX_GetNumParams(track, fx)
if param_idx >= 0 and param_idx < param_count then
    local val = reaper.TrackFX_GetParamNormalized(track, fx, param_idx)
end
```

## CSurf notifications cover values but not structure changes

The CSurf API provides several FX-related callbacks, but none specifically for parameter count changes:

- **`CSURF_EXT_SETFXPARAM`** (0x00010008): Fires when parameter values change. Provides track, combined fxidx<<16|paramidx, and normalized value.
- **`CSURF_EXT_SETFXCHANGE`** (0x00010013): Fires when FX are added, removed, or reordered on a track.
- **`CSURF_EXT_SETFXENABLED`** (0x00010007): Fires when bypass state changes.
- **`CSURF_EXT_SETLASTTOUCHEDFX`** (0x0001000A): Fires when user touches a different FX.

The ReaLearn developer documented this gap explicitly: the API doesn't provide value change notifications "in all cases"—switching presets from within a plugin UI, for instance, may not trigger `CSURF_EXT_SETFXPARAM` for all affected parameters. Forum discussions confirm developers requesting parameter count notifications that don't exist, with one noting "a frustrating lack of callbacks" requiring manual polling for complete state tracking.

## Recommended polling architecture for 30Hz web controllers

The REAPER developer community recommends a **hybrid event-driven plus defensive polling strategy**:

```
Main loop (~30Hz):
├── Process CSURF_EXT notifications (event-driven)
│   ├── SETFXPARAM → Update displayed parameter values
│   ├── SETFXCHANGE → Full FX chain rebuild
│   └── SETFXENABLED → Update bypass indicators
│
├── Value polling every cycle (for parameters without notifications):
│   └── TrackFX_GetParamNormalized() for currently visible params
│
└── Structural polling every ~10 cycles (~3Hz):
    ├── TrackFX_GetNumParams() → Detect parameter count changes
    ├── TrackFX_GetCount() → Verify FX count matches cached
    └── TrackFX_GetFXName() → Detect preset/identity changes
```

**Do not assume parameter count only changes on `CSURF_EXT_SETFXCHANGE`**—this assumption will break with any plugin using dynamic parameters. The `TrackFX_GetNumParams()` call is extremely lightweight (returns a cached integer), so calling it at 3-6Hz adds negligible overhead while catching structural changes within 150-300ms.

Cache your parameter metadata (names, ranges, counts) and compare the count each structural poll cycle. When counts differ, rebuild your parameter mapping completely—indices may have shifted.

## Container plugins use specialized 0x2000000 addressing

REAPER 7's native FX Containers are fully accessible via the standard TrackFX_* API using a special index format. The addressing scheme encodes container relationships:

```lua
-- Calculate FX index for contained plugin
fx_index = 0x2000000 + (fx_position_in_container + 1) * (TrackFX_GetCount(track) + 1) + container_index + 1
```

To detect containers and enumerate their contents:

```lua
function getContainedFXParams(track, container_idx, fx_in_container)
    -- Verify it's a container
    local retval, count = reaper.TrackFX_GetNamedConfigParm(track, container_idx, "container_count")
    if not retval or tonumber(count) < 1 then return nil end
    
    -- Calculate contained FX address
    local track_fx_count = reaper.TrackFX_GetCount(track)
    local fx_idx = 0x2000000 + (fx_in_container + 1) * (track_fx_count + 1) + container_idx + 1
    
    -- Standard TrackFX_* calls work normally
    local num_params = reaper.TrackFX_GetNumParams(track, fx_idx)
    local _, fx_name = reaper.TrackFX_GetFXName(track, fx_idx, "")
    return num_params, fx_name
end
```

All standard TrackFX_* functions work with container-addressed indices: `GetNumParams`, `GetParam`, `SetParam`, `GetParamName`, `GetEnabled`, `SetEnabled`, `GetPreset`, `Show`, and others.

**Third-party containers behave differently.** Blue Cat's Patcher, Kushview Element, and similar plugins appear as single FX instances to REAPER's API. Their internal routing and contained plugins are opaque—you can only access parameters the host plugin explicitly exposes. There's no `container_count` detection, no way to enumerate internal FX, and internal plugin GUIDs aren't accessible. For web controller purposes, treat third-party containers as regular plugins with their own parameter set.

## Practical implementation checklist

For a robust REAPER web controller polling FX parameters:

- **Always validate indices** before parameter access, even though invalid calls won't crash
- **Poll `TrackFX_GetNumParams()` at 3-6Hz** to catch dynamic changes—don't rely solely on CSURF_EXT notifications
- **Use `CSURF_EXT_SETFXPARAM`** for real-time value display when available, but verify with polling for preset changes
- **Handle 0x2000000 indices** returned by `GetTouchedOrFocusedFX()` for container-aware interaction
- **Treat third-party containers as opaque**—only their exposed parameters are accessible
- **Rebuild parameter mappings completely** when counts change, as indices may shift
- **Cache FX GUIDs** (`TrackFX_GetFXGUID`) for persistent references across index changes
