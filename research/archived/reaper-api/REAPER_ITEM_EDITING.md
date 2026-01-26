# REAPER C API item editing: complete technical reference for REAmo

The REAPER C API requires **manual property coordination** for left-edge trimming operations. D_STARTOFFS is a **take-level property**, not item-level—this fundamental distinction affects nearly every editing operation. ApplyNudge provides automatic coordination but operates on selected items, while direct property manipulation offers more precise control at the cost of handling interdependencies yourself.

## Trimming mechanics require explicit property coordination

**Left trim** requires coordinating three properties across two object types. When trimming the left edge inward by `trim_amount` seconds:

```
Before: position=5.0s, length=10.0s, take_startoffs=0.0s
After:  position=7.0s, length=8.0s,  take_startoffs=2.0s
```

The formulas are:

- `new_position = old_position + trim_amount`
- `new_length = old_length - trim_amount`
- `new_startoffs = old_startoffs + (trim_amount × playrate)`

**Critical**: D_STARTOFFS is accessed via `GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")`, NOT `GetMediaItemInfo_Value(item, ...)`. This is the most common source of bugs in REAPER scripts.

**Right trim** is simpler—only D_LENGTH changes. No D_STARTOFFS adjustment needed since the visible start point remains unchanged.

**ApplyNudge with nudgewhat=1** (left trim) handles all property coordination automatically:

```c
ApplyNudge(project, nudgeflag, nudgewhat, nudgeunits, value, reverse, copies)
// nudgewhat=1: left trim - coordinates D_POSITION, D_LENGTH, D_STARTOFFS
// nudgewhat=3: right trim - only adjusts D_LENGTH
```

For a mobile app, ApplyNudge is attractive but has a limitation: it operates on **selected items**. This requires selecting items before operations, which may conflict with user selections. Direct property manipulation gives more surgical control.

## Fade shape values map to mathematical curves

The `C_FADEINSHAPE` and `C_FADEOUTSHAPE` parameters accept values **0–6** representing these curves:

| Value | Name | Visual Description |
|-------|------|-------------------|
| 0 | Linear | Straight diagonal line |
| 1 | Fast Start/Slow End | Logarithmic (cosine first quadrant) |
| 2 | Slow Start/Fast End | Exponential (cosine second quadrant) |
| 3 | Fast Start (Steep) | Inverted quartic `1 - (x/L)⁴` |
| 4 | Slow Start (Steep) | Quartic `(1 - x/L)⁴` |
| 5 | S-Curve | Symmetric sigmoid using `cos(πx/L)` |
| 6 | S-Curve (Steeper) | Complex sigmoid with warping |

**API quirk**: Setting shape to 7 via API returns integer `1` when read back, but behaves as shape 7 visually. Shape 8 is "equal power" used in crossfades. The direction modifier `D_FADEINDIR`/`D_FADEOUTDIR` (range **-1 to 1**) adjusts curve steepness within each shape family.

## Auto-crossfade behavior is controllable via API

REAPER auto-creates crossfades when enabled via `Options > Auto-crossfade`. The crossfade spans the **entire overlap region** between items.

**API access to crossfade settings** uses REAPER's ConfigVar system:

```c
*ConfigVar<int>("autoxfade")           // Auto crossfade mode bits
*ConfigVar<double>("defsplitxfadelen") // Default split crossfade length
*ConfigVar<int>("defxfadeshape")       // Default fade shape
*ConfigVar<int>("splitautoxfade")      // Split auto crossfade setting
```

**Detecting crossfades** is indirect—calculate item overlaps manually:

```c
// Items overlap if: item1_end > item2_start AND item1_start < item2_end
double end1 = pos1 + len1;
double start2 = pos2;
bool overlaps = (end1 > start2) && (pos1 < pos2 + len2);
```

Crossfades exist when `D_FADEOUTLEN_AUTO` (item 1) and `D_FADEINLEN_AUTO` (item 2) are both positive and items overlap. A value of **-1** means no auto-fade.

## Slip editing uses D_STARTOFFS or ApplyNudge

**D_STARTOFFS is correct** for slip editing (moving content within item bounds). Since it's per-take, slip editing affects only the active take unless you iterate all takes:

```c
// Slip content 0.5 seconds later in source
MediaItem_Take* take = GetActiveTake(item);
double currentOffset = GetMediaItemTakeInfo_Value(take, "D_STARTOFFS");
SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", currentOffset + 0.5);
UpdateItemInProject(item);
```

**ApplyNudge with nudgewhat=4** performs slip editing on selected items:

```c
ApplyNudge(0, 0, 4, 1, 0.5, false, 0);  // Slip 0.5 seconds right
ApplyNudge(0, 0, 4, 1, 0.5, true, 0);   // Slip 0.5 seconds left (reverse=true)
```

**Beyond source bounds**: REAPER shows digital silence. D_STARTOFFS can be negative (silence before source start) or exceed source length (silence after source end). The API does **not auto-clamp**—REAmo must validate bounds manually if desired.

**Stretch marker warning**: When stretch markers exist, D_STARTOFFS changes may not update the visual display, though the property value changes correctly. SWS works around this by also adjusting stretch marker positions.

## Source length constraints require manual validation

**GetMediaSourceLength** returns the total source duration:

```c
PCM_source* source = GetMediaItemTake_Source(take);
bool lengthIsQN;
double sourceLength = GetMediaSourceLength(source, &lengthIsQN);
// If lengthIsQN is true, length is in quarter notes (beat-based media)
```

**Items CAN extend beyond source**—REAPER fills with silence and shows hatch marks visually. REAPER 7.08+ added an option "Limit edits to source media content for unlooped media items" for UI operations, but API calls bypass this.

**Boundary validation formula** (accounting for playrate):

```c
double playrate = GetMediaItemTakeInfo_Value(take, "D_PLAYRATE");
double itemLength = GetMediaItemInfo_Value(item, "D_LENGTH");
double itemLengthInSourceTime = itemLength * playrate;

// Valid range for D_STARTOFFS:
double minOffset = 0.0;  // or allow negative for silence
double maxOffset = sourceLength - itemLengthInSourceTime;

// Clamp new offset
if (newOffset < minOffset) newOffset = minOffset;
if (newOffset > maxOffset && maxOffset > 0) newOffset = maxOffset;
```

## Multi-take items have per-take D_STARTOFFS

**D_STARTOFFS is per-take**—each take has independent source offset. Trimming via direct property manipulation affects only the take you modify:

```c
int numTakes = CountTakes(item);
for (int i = 0; i < numTakes; i++) {
    MediaItem_Take* take = GetTake(item, i);
    double offset = GetMediaItemTakeInfo_Value(take, "D_STARTOFFS");
    SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", offset + trimAmount);
}
```

**Per-take vs per-item properties**:

- **Item-level (shared)**: D_POSITION, D_LENGTH, D_FADEINLEN, D_FADEOUTLEN, C_FADEINSHAPE, C_FADEOUTSHAPE, I_GROUPID
- **Take-level (independent)**: D_STARTOFFS, D_VOL, D_PAN, D_PITCH, D_PLAYRATE, P_NAME

**Gotchas**: Check `B_ALLTAKESPLAY` on items—when true, all takes play simultaneously. Take envelopes are per-take while item/track envelopes are shared. Use `GetActiveTake(item)` for operations on the user-visible take.

## Item groups require explicit handling

**API calls do NOT propagate to grouped items**. This differs from UI behavior where grouped items move together. SetMediaItemInfo_Value affects only the target item.

**SWS pattern for disabling group editing** uses ConfigVarOverride:

```c
// Temporarily disable item grouping
int* projgroupover = ConfigVar<int>("projgroupover");
int savedValue = *projgroupover;
*projgroupover = 1;  // 1 = group editing disabled

// Perform operations...

*projgroupover = savedValue;  // Restore
```

**Practical approach for REAmo**: Check I_GROUPID and process grouped items explicitly:

```c
int targetGroupId = GetMediaItemInfo_Value(item, "I_GROUPID");
if (targetGroupId != 0) {
    // Find and process all items in this group
    for (int i = 0; i < CountMediaItems(project); i++) {
        MediaItem* it = GetMediaItem(project, i);
        if (GetMediaItemInfo_Value(it, "I_GROUPID") == targetGroupId) {
            // Apply operation to this item
        }
    }
}
```

Note that `CountMediaItems()` is O(N)—avoid calling it in tight loops. Cache the count or use SWS's optimized functions for large projects.

## Recommended approach for mobile touch UI

For REAmo's touch-based interface, here are optimal strategies:

**Move operations**: Use **direct SetMediaItemInfo_Value** for D_POSITION. ApplyNudge requires item selection and doesn't offer advantages for position-only changes. Handle group propagation explicitly if desired.

**Trim operations**: Use **ApplyNudge** (nudgewhat=1 for left, nudgewhat=3 for right) when possible—it handles D_STARTOFFS coordination automatically. For non-selected item trimming, use direct property manipulation with this pattern:

```c
// Left trim implementation
void TrimItemLeft(MediaItem* item, double trimAmount) {
    double pos = GetMediaItemInfo_Value(item, "D_POSITION");
    double len = GetMediaItemInfo_Value(item, "D_LENGTH");
    MediaItem_Take* take = GetActiveTake(item);
    double offs = GetMediaItemTakeInfo_Value(take, "D_STARTOFFS");
    double rate = GetMediaItemTakeInfo_Value(take, "D_PLAYRATE");
    
    SetMediaItemInfo_Value(item, "D_POSITION", pos + trimAmount);
    SetMediaItemInfo_Value(item, "D_LENGTH", len - trimAmount);
    SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", offs + (trimAmount * rate));
    
    UpdateItemInProject(item);
}
```

**Fade operations**: Use **direct SetMediaItemInfo_Value**. Fades are simpler than trimming with no property interdependencies:

```c
SetMediaItemInfo_Value(item, "D_FADEINLEN", 0.5);    // 500ms fade in
SetMediaItemInfo_Value(item, "C_FADEINSHAPE", 5);   // S-curve
SetMediaItemInfo_Value(item, "D_FADEINDIR", 0.0);   // Neutral direction
```

**Undo integration**: REAmo's "Reamo: " undo prefix is correct. Wrap operations in undo blocks:

```c
Undo_BeginBlock();
// ... operations ...
Undo_EndBlock("Reamo: Trim item left", UNDO_STATE_ITEMS);
UpdateTimeline();
```

**Touch-specific considerations**: For drag-based trimming, calculate delta from touch movement and apply incrementally. Consider implementing "snap preview" showing where item will land before committing. For fades, a simple shape selector (0–6) with visual preview works well on mobile—direction adjustment can be secondary.
