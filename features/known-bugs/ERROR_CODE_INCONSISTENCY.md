# Error Code Naming Inconsistency

**Status:** Tech debt - inconsistent but functional

## Problem

Command handlers use inconsistent error code styles across the codebase:

**Specific codes** (newer pattern, used in routing-related handlers):

```zig
// send.zig, hw_output.zig
response.err("MISSING_TRACK_IDX", "trackIdx is required");
response.err("MISSING_SEND_IDX", "sendIdx is required");
response.err("MISSING_VOLUME", "volume is required");
response.err("INVALID_MODE", "mode must be 0, 1, or 3");
```

**Generic codes** (older pattern, used in tracks.zig and others):

```zig
// tracks.zig older handlers
response.err("INVALID_PARAMS", "trackIdx is required");
response.err("INVALID_PARAMS", "Missing required parameter");
```

## Impact

- Frontend error handling must check message strings for specific failures instead of relying on error codes
- No impact on functionality — all errors are caught and reported
- Makes error handling code more fragile and harder to test

## Files Affected

**Specific codes:**

- `commands/send.zig` — `MISSING_TRACK_IDX`, `MISSING_SEND_IDX`, `MISSING_VOLUME`, etc.
- `commands/hw_output.zig` — `MISSING_TRACK_IDX`, `MISSING_HW_IDX`, `MISSING_VOLUME`, etc.

**Generic codes:**

- `commands/tracks.zig` — `INVALID_PARAMS` for various missing parameters
- `commands/items.zig` — mixed usage
- Various other handlers

## Recommended Fix

Standardize on specific error codes codebase-wide:

1. **Parameter validation errors:** `MISSING_{PARAM_NAME}` (e.g., `MISSING_TRACK_IDX`)
2. **Invalid value errors:** `INVALID_{PARAM_NAME}` (e.g., `INVALID_MODE`)
3. **Not found errors:** `NOT_FOUND` with message specifying what
4. **Operation failures:** `{OPERATION}_FAILED` (e.g., `SET_FAILED`)

This allows frontend to handle errors programmatically:

```typescript
if (error.code === 'MISSING_TRACK_IDX') {
  // Handle missing track index specifically
}
```

## Priority

Low. Purely cosmetic/DX improvement. Current code works correctly; this is about consistency and maintainability.

## Notes

Discovered during Routing Modal Enhancement PR review. New `hw_output.zig` follows the `send.zig` pattern for internal consistency with related routing functionality.
