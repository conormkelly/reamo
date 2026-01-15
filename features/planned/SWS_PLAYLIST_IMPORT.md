# SWS Region Playlist Import

**Status:** Planned (read-only import)

## Why Import Matters

Users with existing SWS Region Playlists shouldn't have to rebuild them. REAmo can detect and import SWS playlists on project load.

## Confirmed SWS RPP Format

From empirical testing on real .RPP files:

```
<EXTENSIONS
  <S&M_RGN_PLAYLIST Untitled 1
    1073741828 1
    1073741825 1
    1073741827 1
  >
  <S&M_RGN_PLAYLIST "With infinite"
    1073741825 -1
    1073741828 4
  >
>
```

### Format Breakdown

| Element | Format | Example |
|---------|--------|---------|
| Header | `<S&M_RGN_PLAYLIST <name>` | `<S&M_RGN_PLAYLIST "My Set"` |
| Name | Unquoted or `"quoted with spaces"` | `Untitled 1` or `"With infinite"` |
| Entry | `<region_id> <loop_count>` | `1073741828 4` |
| Infinite loop | `loop_count = -1` | `1073741825 -1` |
| Block close | `>` | |

### Region ID Encoding

SWS uses REAPER's internal region IDs with a flag bit:

| Decimal | Hex | Actual Region |
|---------|-----|---------------|
| 1073741825 | `0x40000001` | Region 1 |
| 1073741826 | `0x40000002` | Region 2 |

To extract: `region_index = region_id & 0x3FFFFFFF`

## Import Flow

```
+-------------------------------------------------------------+
| SWS Playlist Detected                         [Import ->]   |
+-------------------------------------------------------------+
| "With infinite" (5 entries)                                 |
| "Untitled 1" (4 entries)                                    |
+-------------------------------------------------------------+
| Import creates a copy in REAmo. Original unchanged.         |
+-------------------------------------------------------------+
```

1. On project load, extension reads .RPP file path via `GetProjectPath()`
2. Parse file for `<S&M_RGN_PLAYLIST` blocks
3. Decode region IDs, cross-reference with current regions
4. Send `swsPlaylistDetected` event to frontend
5. User clicks "Import" -> copy to REAmo's EXTSTATE format

## Why Read-Only

- No risk of corrupting SWS data
- No conflicts with SWS undo integration
- No memory vs disk sync issues
- Clear separation of concerns

## Implementation Notes

- Parsing can be done in Zig with simple line-by-line state machine
- Quoted names need proper handling (escaped quotes inside)
- Region IDs must be validated against current project regions
- Import should preserve loop counts including infinite (-1)

## Effort Estimate

~1 day backend + UI integration
