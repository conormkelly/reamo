# REAPER Fixed Lanes & Swipe Comping Research

Research notes for implementing swipe comping in a DAW remote app (Zig backend).

## Fixed Lanes vs Takes: Key Distinction

| Concept | Description |
|---------|-------------|
| **Takes** | Multiple recordings stacked *within a single MediaItem* |
| **Fixed Lanes** | Multiple *separate MediaItems* visually stacked on a track, each in its own lane |

When fixed lanes are enabled, what appears as "stacked takes" are actually separate `MediaItem` objects—not takes within one item.

---

## Core API Functions

### Check if Track Has Fixed Lanes Enabled

```zig
// Returns number of fixed lanes (0 = lanes not enabled)
const num_lanes = reaper.GetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES");
const lanes_enabled = num_lanes > 0;
```

### Get Which Lane an Item Is On

```zig
const lane_index = reaper.GetSetMediaItemInfo_Value(item, "I_FIXEDLANE", 0, false);
```

### Set Number of Fixed Lanes on a Track

```zig
reaper.SetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES", 4); // 4 lanes
```

---

## Swipe Comping Implementation

### Key Properties for Comping

```zig
// Get/set which lane is the "comp" lane (the audible one at any given time region)
reaper.GetSetMediaItemInfo_Value(item, "C_LANEPLAYS", ...)

// Item selection for comping workflows
reaper.SetMediaItemSelected(item, true)

// Item positions for drawing lanes in UI
reaper.GetMediaItemInfo_Value(item, "D_POSITION")  // start time (seconds)
reaper.GetMediaItemInfo_Value(item, "D_LENGTH")    // duration (seconds)
```

### C_LANEPLAYS

This is the magic property for comping. It's a bit of item state that indicates "I'm the one playing in my time region." This is how REAPER tracks which lane segments are "active" in the comp.

---

## Suggested Implementation Pattern

```zig
const LaneItem = struct {
    item: MediaItem,
    lane: i32,
    position: f64,
    length: f64,
    is_playing: bool,
};

fn getTrackLaneInfo(track: MediaTrack) !TrackLaneInfo {
    const num_lanes: i32 = @intFromFloat(reaper.GetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES"));
    
    if (num_lanes > 0) {
        // Fixed lanes mode - group items by lane
        const num_items = reaper.GetTrackNumMediaItems(track);
        var lane_items = std.ArrayList(LaneItem).init(allocator);
        
        for (0..@intCast(num_items)) |i| {
            const item = reaper.GetTrackMediaItem(track, @intCast(i));
            const lane: i32 = @intFromFloat(reaper.GetSetMediaItemInfo_Value(item, "I_FIXEDLANE", 0, false));
            const position = reaper.GetMediaItemInfo_Value(item, "D_POSITION");
            const length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH");
            const is_playing = reaper.GetSetMediaItemInfo_Value(item, "C_LANEPLAYS", 0, false) != 0;
            
            try lane_items.append(.{
                .item = item,
                .lane = lane,
                .position = position,
                .length = length,
                .is_playing = is_playing,
            });
        }
        
        return .{ .lanes = num_lanes, .items = lane_items };
    } else {
        // Traditional takes mode - check takes per item
        // ... different logic path
    }
}
```

---

## Swipe Comping UX Flow

1. **Display**: Render lane items as horizontal strips, vertically stacked by `I_FIXEDLANE` index
2. **Visual Feedback**: Highlight items where `C_LANEPLAYS` is true (currently audible)
3. **Swipe Gesture**: On touch/drag across a time region on a lane:
   - Set `C_LANEPLAYS` on touched items
   - Clear `C_LANEPLAYS` on overlapping items in other lanes
4. **Playback**: REAPER handles the rest—only `C_LANEPLAYS` items are audible

---

## Additional Considerations

- **Waveform Display**: May want `PCM_source` access for drawing waveforms per item
- **Razor Edits**: Could complement swipe comping for more precise edits
- **Undo**: Wrap comp changes in `Undo_BeginBlock` / `Undo_EndBlock` for single undo step
- **Performance**: Cache lane layout, only refresh on project change notifications

---

## References

- [REAPER API Documentation](https://www.reaper.fm/sdk/reascript/reascripthelp.html)
- ReaScript/extension SDK for `MediaTrack` and `MediaItem` functions
