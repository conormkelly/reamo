# Fixed lanes and swipe comping

How REAPER's fixed-lane comping can be driven from code, as found by testing against REAPER. `extension/src/commands/lanes.zig` (the `lanes/*` commands, documented in `extension/API.md`) depends on these facts. The phone UI isn't built.

**Minimum REAPER 7.02:** `C_LANEPLAYS:N` is broken in 7.0 and 7.01.

## Fixed lanes vs takes

- **Takes:** several recordings inside one `MediaItem`.
- **Fixed lanes** (`I_FREEMODE` = 2): separate `MediaItem`s, each in its own lane (`I_FIXEDLANE`). What looks like stacked takes are separate items.

## Creating a comp area: `P_RAZOREDITS_EXT` + action 42475

The only way found to create a comp area with REAPER's metadata (the orange source highlights):

1. Set the track's `P_RAZOREDITS_EXT` to the time range on the source lane.
2. Run action 42475 ("Razor edit: Create fixed lane comp area").
3. Clear `P_RAZOREDITS_EXT`.

- Format: `"startTime endTime envelopeGUID topY bottomY"`. Empty GUID (`""`) targets media items; several areas are comma-separated. Undocumented, but works.
- Lane Y bounds are normalised to track height: lane `i` of `N` is `i/N` to `(i+1)/N`.
- **The first comp inserts a new lane 0** (the comp) and shifts every source lane down by one. Recompute bounds from the current `I_NUMFIXEDLANES` before every swipe.

What failed:

- Action 42652 ("Add comp areas for selected items") **replaces** the comp on each call; it can't build one up.
- Copying, trimming and moving items to lane 0 plays correctly but has **no comp metadata**.
- Item `C_LANEPLAYS` is **read-only**.

## Comp target lane: `LANEREC` in the track chunk

The comp target (yellow square in REAPER) is readable and settable only through the track state chunk: `LANEREC v1 v2 v3 v4`.

| Field | Meaning |
|-------|---------|
| v1 | Unknown (observed -1); keep as is |
| v2 | Comp target lane index (0-based) |
| v3 | 1 when the target is lane 0, else 0 (observed) |
| v4 | 1 if the playing lane is the comp target, else 0 |

To set: read the chunk, replace `LANEREC` with `v1 <target> <target==0 ? 1 : 0> 0`, write it back with `SetTrackStateChunk`, inside an undo block.

## Resizing comp areas

Comp metadata is stored apart from item properties.

| Operation | Method | Result |
|-----------|--------|--------|
| Create | `P_RAZOREDITS_EXT` + 42475 | Full metadata |
| Extend start or end | Delete (42642) + re-swipe | Full metadata |
| Shrink | Delete all and recreate | Full metadata |
| Change `D_POSITION` / `D_LENGTH` directly | `SetMediaItemInfo_Value` | Keeps `C_LANEPLAYS=1`, **loses the highlights** |
| Shrink by re-swiping only | `P_RAZOREDITS_EXT` + 42475 | Leaves fragments |
| Track-level delete (42955) | "Delete comp areas for track" | Doesn't work |

## Which source a segment came from

- Not readable from REAPER. It can be inferred by matching each comp item's source file and range against the source lanes' items, but that fails when lanes share a source file.
- So the client should track each segment's source lane itself rather than rely on inference.

## Reference

Track parameters:

| Parameter | R/W | Meaning |
|-----------|-----|---------|
| `I_FREEMODE` | R/W | 0 normal, 1 free positioning, 2 fixed lanes |
| `I_NUMFIXEDLANES` | R/W | Number of lanes |
| `C_LANESCOLLAPSED` | R/W | 0 visible, 1 collapsed, 2 hidden lanes exist |
| `C_LANESETTINGS` | R/W | `&1` auto-remove empty bottom lanes, `&2` don't auto-comp new recording, `&4` new lanes play exclusively, `&8` big lanes, `&16` new recording at bottom, `&32` hide lane buttons |
| `C_LANEPLAYS:N` | R/W | Lane N: 0 off, 1 exclusive, 2 layered |
| `C_ALLLANESPLAY` | R/W | 0 none, 1 all, 2 some |
| `P_LANENAME:n` | R/W | Lane name |
| `P_RAZOREDITS_EXT` | R/W | Razor edits with lane Y bounds |

Item parameters: `I_FIXEDLANE` (lane, 0-based), `C_LANEPLAYS` (read-only: 0 off, 1 exclusive, 2 layered, -1 hidden), `B_FIXEDLANE_HIDDEN` (read-only).

Actions:

| ID | Action | Used for |
|----|--------|----------|
| 42475 | Razor edit: Create fixed lane comp area | Swipe comp |
| 42642 | Fixed lane comp area: Delete comp area | Delete the selected comp area (source items stay) |
| 42707 | Fixed lane comp area: Move comp area up | Selected segment to the previous source |
| 42708 | Fixed lane comp area: Move comp area down | Selected segment to the next source |
| 42797 | Track lanes: Insert new comp lane | New empty comp lane |
| 42652 | Track lanes: Add comp areas for selected items | Not used: replaces the comp |
| 40289 | Item: Unselect all items | Before razor operations |

## Known gaps

- `mod.requireLanes` refuses lane commands below REAPER 7, but doesn't catch 7.0 and 7.01, where `C_LANEPLAYS:N` is broken.
- No `lanes/getCompMapping` (source inference); see above for why the client should track sources instead.
