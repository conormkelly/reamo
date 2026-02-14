# REAPER Fixed Lanes & Swipe Comping

Implementation guide for swipe comping in REAmo (Zig backend + React frontend).

**Minimum REAPER Version: 7.02** — `C_LANEPLAYS:N` was broken in 7.0/7.01.

---

## The Solution: P_RAZOREDITS_EXT + Action 42475

After extensive research, the only reliable programmatic path for creating comp areas with proper metadata (orange source highlights) is:

1. Set `P_RAZOREDITS_EXT` with lane-targeted Y coordinates
2. Call Action 42475 ("Razor edit: Create fixed lane comp area")
3. Clear the razor edit

This creates proper comp area metadata that REAPER displays as orange highlights on source lanes.

### Why Other Approaches Failed

| Approach | Result |
|----------|--------|
| Action 42652 ("Add comp areas for selected items") | **Replaces** existing comp on each call — can't build up incrementally |
| Direct item manipulation (copy, trim, move to lane 0) | Audio works, but **no comp metadata** — no orange highlights |
| `C_LANEPLAYS` item parameter | **Read-only** — cannot set programmatically |

---

## Fixed Lanes vs Takes: Key Distinction

| Concept | Description |
|---------|-------------|
| **Takes** | Multiple recordings stacked *within a single MediaItem* |
| **Fixed Lanes** | Multiple *separate MediaItems* visually stacked on a track, each in its own lane |

When fixed lanes are enabled, what appears as "stacked takes" are actually separate `MediaItem` objects—not takes within one item.

---

## Working Implementation

### Core Algorithm

```lua
function swipeComp(track, targetLane, startTime, endTime)
    -- Get current lane count
    local numLanes = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES"))

    -- Calculate normalized Y bounds for target lane (0.0-1.0 range)
    local laneHeight = 1.0 / numLanes
    local topY = targetLane * laneHeight
    local btmY = topY + laneHeight

    -- Create razor edit string: "startTime endTime envelopeGUID topY bottomY"
    -- Empty GUID ("") targets media items, not envelopes
    local razorStr = string.format('%f %f "" %f %f', startTime, endTime, topY, btmY)

    reaper.Undo_BeginBlock()

    -- Set razor edit on target lane
    reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS_EXT", razorStr, true)

    -- Convert razor to comp area (creates proper metadata!)
    reaper.Main_OnCommand(42475, 0)  -- "Razor edit: Create fixed lane comp area"

    -- Clear razor edit
    reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS_EXT", "", true)

    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Swipe comp", -1)
end
```

### Lane Y Coordinate Calculation

Lanes use **normalized Y positions (0.0-1.0)** relative to track height:

```
For N lanes:
  Lane 0: topY = 0.0,     btmY = 1/N
  Lane 1: topY = 1/N,     btmY = 2/N
  Lane 2: topY = 2/N,     btmY = 3/N
  ...
  Lane N-1: topY = (N-1)/N, btmY = 1.0

Example (3 lanes):
  Lane 0: topY = 0.0000, btmY = 0.3333
  Lane 1: topY = 0.3333, btmY = 0.6667
  Lane 2: topY = 0.6667, btmY = 1.0000
```

### Lane Shifting Behavior

**Important:** The first comp operation creates a new lane 0 and shifts existing lanes:

```
BEFORE first comp (2 lanes):
  Lane 0: Source take A
  Lane 1: Source take B

AFTER first comp (3 lanes):
  Lane 0: Comp (playing)     ← NEW
  Lane 1: Source take A      ← was lane 0
  Lane 2: Source take B      ← was lane 1
```

The v3 test script handles this by recalculating lane bounds after each swipe based on current `I_NUMFIXEDLANES`.

---

## P_RAZOREDITS_EXT Format

The extended razor edit parameter supports lane targeting:

```
Standard P_RAZOREDITS:     "startTime endTime envelopeGUID"
Extended P_RAZOREDITS_EXT: "startTime endTime envelopeGUID topY bottomY"
```

- Empty GUID (`""`) targets media items
- Multiple razor areas use comma separation: `"0.0 1.0 \"\" 0.0 0.25,2.0 3.0 \"\" 0.25 0.5"`

---

## API Reference

### Track-Level Parameters

| Parameter | Type | R/W | Description |
|-----------|------|-----|-------------|
| `I_FREEMODE` | int | R/W | 0=normal, 1=free positioning, **2=fixed lanes** |
| `I_NUMFIXEDLANES` | int | R/W* | Number of lanes |
| `C_LANESCOLLAPSED` | char | R/W | 0=visible, 1=collapsed, 2=hidden lanes exist |
| `C_LANESETTINGS` | char | R/W | Bitfield (see below) |
| `C_LANEPLAYS:N` | char | R/W | Lane N play state: 0=off, 1=exclusive, 2=layered |
| `C_ALLLANESPLAY` | char | R/W | 0=none, 1=all, 2=some |
| `P_LANENAME:n` | string | R/W | Lane name |
| `P_RAZOREDITS_EXT` | string | R/W | **Key parameter** — razor edits with lane Y bounds |

**C_LANESETTINGS bitfield:**

- `&1` = Auto-remove empty lanes at bottom
- `&2` = Do NOT auto-comp new recording
- `&4` = Newly recorded lanes play exclusively
- `&8` = Big lanes display
- `&16` = Add new recording at bottom
- `&32` = Hide lane buttons

### Item-Level Parameters

| Parameter | Type | R/W | Description |
|-----------|------|-----|-------------|
| `I_FIXEDLANE` | int | R/W* | Lane index (0-based) |
| `C_LANEPLAYS` | char | **R only** | 0=off, 1=exclusive, 2=layered, -1=hidden |
| `B_FIXEDLANE_HIDDEN` | bool | R only | Item in non-displayed lane |
| `D_POSITION` | float | R/W | Start time (seconds) |
| `D_LENGTH` | float | R/W | Duration (seconds) |

### Key Actions

| ID | Action | Use |
|----|--------|-----|
| **42475** | Razor edit: Create fixed lane comp area | **Primary swipe comp action** |
| **42642** | Fixed lane comp area: Delete comp area | Delete selected comp area (preserves source items) |
| **42707** | Fixed lane comp area: Move comp area up | **Shift selected segment to previous source** |
| **42708** | Fixed lane comp area: Move comp area down | **Shift selected segment to next source** |
| **42797** | Track lanes: Insert new comp lane | Create new empty comp lane |
| 42652 | Track lanes: Add comp areas for selected items | Creates/replaces comp (not incremental) |
| 40289 | Item: Unselect all items | Safety before razor operations |
| 40006 | Item: Remove items | Delete selected items |

---

## Setting Comp Target Lane Programmatically

The comp target lane (yellow square highlight in REAPER UI) determines which lane receives new swipe comp operations. This can be read and **set** via the track state chunk.

### LANEREC Field

The `LANEREC` field in the track state chunk controls comp target:

```
LANEREC v1 v2 v3 v4
```

| Field | Meaning |
|-------|---------|
| v1 | Unknown (observed: -1) |
| **v2** | **Comp target lane index** (0-based) |
| v3 | Related to v2 (typically inverse for lanes 0/1) |
| v4 | 1 if play lane == comp target, else 0 |

### Reading Comp Target

```lua
local retval, chunk = reaper.GetTrackStateChunk(track, "", false)
local v1, v2, v3, v4 = chunk:match("LANEREC ([%-%d]+) ([%-%d]+) ([%-%d]+) ([%-%d]+)")
local compTargetLane = tonumber(v2)  -- This is the comp target lane index
```

### Setting Comp Target

```lua
function setCompTargetLane(track, newTargetLane)
    local retval, chunk = reaper.GetTrackStateChunk(track, "", false)
    if not retval then return false end

    local v1, v2, v3, v4 = chunk:match("LANEREC ([%-%d]+) ([%-%d]+) ([%-%d]+) ([%-%d]+)")
    if not v1 then return false end

    -- Build new LANEREC
    local newV2 = tostring(newTargetLane)
    local newV3 = (newTargetLane == 0) and "1" or "0"
    local newV4 = "0"

    local newLanerec = string.format("LANEREC %s %s %s %s", v1, newV2, newV3, newV4)
    local newChunk = chunk:gsub("LANEREC [%-%d]+ [%-%d]+ [%-%d]+ [%-%d]+", newLanerec)

    reaper.Undo_BeginBlock()
    local success = reaper.SetTrackStateChunk(track, newChunk, false)
    reaper.UpdateArrange()  -- Recommended for safety
    reaper.Undo_EndBlock("Set comp target lane", -1)

    return success
end
```

### Backend Command

```
lanes/setCompTarget → { trackGuid, laneIndex } → modifies LANEREC via state chunk
```

---

## Resizing Comp Areas

**Key finding:** Comp area metadata (orange highlights) is stored separately from item properties. Direct manipulation of `D_POSITION`/`D_LENGTH` preserves `C_LANEPLAYS=1` but **loses orange highlight metadata**.

### What Works

| Operation | Method | Result |
|-----------|--------|--------|
| Create new comp | P_RAZOREDITS_EXT + 42475 | ✓ Full metadata |
| Extend comp end | Delete (42642) + re-swipe | ✓ Full metadata |
| Extend comp start | Delete (42642) + re-swipe | ✓ Full metadata |
| Shrink comp | Full rebuild (delete all + recreate) | ✓ Full metadata |

### What Doesn't Work

| Operation | Method | Result |
|-----------|--------|--------|
| Direct D_LENGTH change | SetMediaItemInfo_Value | ✗ Loses orange highlights |
| Direct D_POSITION change | SetMediaItemInfo_Value | ✗ Loses orange highlights |
| Shrink via re-swipe only | P_RAZOREDITS_EXT + 42475 | ✗ Leaves fragments |
| Track-level delete (42955) | "Delete comp areas for track" | ✗ Does not work |

### Recommended Resize Strategy

For extending comp areas:

```lua
-- 1. Select the comp item to resize
reaper.SetMediaItemSelected(compItem, true)
-- 2. Delete it (preserves source media)
reaper.Main_OnCommand(42642, 0)  -- Fixed lane comp area: Delete comp area
-- 3. Re-swipe with new bounds
doSwipe(sourceLane, newStartTime, newEndTime)
```

For shrinking, consider **full rebuild**: store all comp states, delete all, recreate with modified bounds. This avoids fragment issues but requires tracking source lanes explicitly.

### Source Lane Tracking

The source inference algorithm only works reliably when **different lanes have different source files**. If multiple lanes share the same source file (e.g., same recording duplicated), inference will fail.

**Recommendation:** Track source lanes explicitly in your frontend state rather than relying on inference for resize operations.

---

## Inferring Comp Source Mapping

Comp area metadata (which source lane each segment came from) is **not directly readable**. However, you can infer it by matching audio sources:

```lua
-- For each comp item in lane 0, find its source lane
function getCompSourceLane(compItem, track)
    local compTake = reaper.GetActiveTake(compItem)
    if not compTake then return nil end

    local compSource = reaper.GetMediaItemTake_Source(compTake)
    local _, compFile = reaper.GetMediaSourceFileName(compSource, "")
    local compOffset = reaper.GetMediaItemTakeInfo_Value(compTake, "D_STARTOFFS")
    local compPos = reaper.GetMediaItemInfo_Value(compItem, "D_POSITION")
    local compLen = reaper.GetMediaItemInfo_Value(compItem, "D_LENGTH")

    -- Search source lanes for matching audio
    local numItems = reaper.GetTrackNumMediaItems(track)
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local lane = math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE"))

        if lane > 0 then  -- Source lanes (not comp lane)
            local take = reaper.GetActiveTake(item)
            if take then
                local source = reaper.GetMediaItemTake_Source(take)
                local _, file = reaper.GetMediaSourceFileName(source, "")

                if file == compFile then
                    -- Same source file - check offset overlap
                    local srcOffset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
                    local srcPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                    local srcLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

                    -- If time ranges and offsets align, this is the source
                    if srcPos <= compPos and (srcPos + srcLen) >= (compPos + compLen) then
                        return lane
                    end
                end
            end
        end
    end
    return nil
end
```

---

## Zig Backend Commands

See [SWIPE_COMPING_UI.md](SWIPE_COMPING_UI.md) for frontend usage context.

### Core Commands

| Command | Parameters | Response/Action |
|---------|------------|-----------------|
| `lanes/getState` | trackGuid | numLanes, compTargetLane, playingLane, lanes[] with items |
| `lanes/swipeComp` | trackGuid, sourceLane, startTime, endTime | P_RAZOREDITS_EXT + action 42475 |

### Lane Control

| Command | Parameters | Action |
|---------|------------|--------|
| `lanes/setCompTarget` | trackGuid, laneIndex | Modify LANEREC via state chunk |
| `lanes/setLanePlays` | trackGuid, laneIndex | Set track-level C_LANEPLAYS:N |
| `lanes/createCompLane` | trackGuid | Action 42797 (create new comp lane) |

### Comp Segment Operations

| Command | Parameters | Action |
|---------|------------|--------|
| `lanes/moveCompUp` | trackGuid | Action 42707 — shift selected segment to previous source |
| `lanes/moveCompDown` | trackGuid | Action 42708 — shift selected segment to next source |
| `lanes/deleteCompArea` | trackGuid, itemGuid | Select item + action 42642 |

### Optional

| Command | Parameters | Action |
|---------|------------|--------|
| `lanes/getCompMapping` | trackGuid | Infer source lanes from audio file matching |

### Zig Implementation Sketch

```zig
fn swipeComp(track: MediaTrack, lane: i32, start: f64, end: f64) !void {
    const num_lanes = @as(i32, @intFromFloat(
        reaper.GetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES")
    ));

    const lane_height = 1.0 / @as(f64, @floatFromInt(num_lanes));
    const top_y = @as(f64, @floatFromInt(lane)) * lane_height;
    const btm_y = top_y + lane_height;

    var buf: [256]u8 = undefined;
    const razor_str = std.fmt.bufPrint(&buf, "{d} {d} \"\" {d} {d}", .{
        start, end, top_y, btm_y
    }) catch return error.FormatError;

    _ = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS_EXT", razor_str.ptr, true);
    reaper.Main_OnCommand(42475, 0);
    _ = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS_EXT", "", true);
    reaper.UpdateArrange();
}
```

---

## Frontend UI Strategy

### Rendering

```
┌─────────────────────────────────────────────┐
│ [Comp]    ████│████│████│████               │  ← lane 0, C_LANEPLAYS=1
├─────────────────────────────────────────────┤
│ [Take 1]  ▓▓▓▓│░░░░│▓▓▓▓│░░░░               │  ← highlighted where used
├─────────────────────────────────────────────┤
│ [Take 2]  ░░░░│▓▓▓▓│░░░░│▓▓▓▓               │  ← highlighted where used
└─────────────────────────────────────────────┘
            ▓▓▓▓ = segment used in comp (inferred from source matching)
            ░░░░ = available but not used

            [◀ Page] Lane 1-2 of 4 [Page ▶]   ← paging for many lanes
```

### Data Requirements

- `I_NUMFIXEDLANES` → number of rows to render
- Items per lane with `D_POSITION`, `D_LENGTH` → block positions
- `C_LANEPLAYS` per item → 1 = playing (comp), 0 = muted (source)
- Waveform peaks via existing `item/getPeaks`
- Comp source mapping (inferred) → orange highlight positions

### Touch Interaction

1. **Horizontal swipe** on source lane → creates comp from that time range
2. **Vertical swipe or buttons** → page between lane groups (for many takes)
3. **Tap comp segment** → could show which source it came from

---

## Test Scripts

- `scripts/test_swipe_comp_v3.lua` — **Working implementation** using P_RAZOREDITS_EXT + 42475
- `scripts/test_swipe_comp_v2.lua` — Direct manipulation approach (audio works, no metadata)
- `scripts/test_swipe_comp.lua` — Original 42652 approach (replaces existing comp)

---

## References

- [REAPER API Documentation](https://www.reaper.fm/sdk/reascript/reascripthelp.html)
- REAPER 7.02+ release notes for `C_LANEPLAYS:N` fix
- Action list: search "Track lanes:", "Fixed lane comp area:", "Razor edit:"
- `P_RAZOREDITS_EXT` — undocumented but confirmed working for lane targeting
