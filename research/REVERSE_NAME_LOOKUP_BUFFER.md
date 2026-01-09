# REAPER's ReverseNamedCommandLookup has no documented buffer limit

**The function returns an internal pointer—not a caller buffer—but 128 bytes provides a safe upper bound when storing the result.** REAPER's official API documentation specifies no maximum length for command name strings, yet analysis of the SWS Extension source code, naming conventions, and real-world usage reveals that **128 characters** is the de facto safe limit used by the most battle-tested REAPER extension. The longest observed command identifiers reach approximately **47 characters** for section-specific ReaScripts.

## The function returns an internal pointer, not a buffer

A critical first insight: `ReverseNamedCommandLookup` does **not** require callers to provide a buffer at all. Its C signature is:

```c
const char* ReverseNamedCommandLookup(int command_id)
```

This returns a pointer to **REAPER-managed internal memory**. The returned string excludes the leading underscore (e.g., returns `"SWS_ABOUT"` not `"_SWS_ABOUT"`) and returns NULL for native REAPER actions. The buffer size question therefore applies only when **copying or storing** this returned string for later use.

## SWS Extension defines 128 bytes as the action ID limit

The SWS Extension—REAPER's most mature third-party extension—provides authoritative guidance through its source code constants in `SnM/SnM.h`:

| Constant | Value | Purpose |
|----------|-------|---------|
| `SNM_MAX_ACTION_CUSTID_LEN` | **128** | Custom action identifiers |
| `SNM_MAX_MACRO_CUSTID_LEN` | 32 | Macro custom IDs |
| `SNM_MAX_ACTION_NAME_LEN` | 512 | Full action display names |

SWS consistently allocates **128-byte buffers** when working with command ID strings and uses `snprintfStrict()` with size validation to prevent overflow:

```c
char custId[SNM_MAX_ACTION_CUSTID_LEN];
if (snprintfStrict(custId, sizeof(custId), "%s%d", id, slot+1) <= 0)
    return false;  // Graceful failure on truncation
```

This **128-byte** allocation has proven safe across millions of REAPER installations over many years.

## Observed command identifier lengths in practice

Analysis of naming patterns reveals that **47 characters** is the longest common format:

| Action Type | Format | Example | Length |
|-------------|--------|---------|--------|
| Section-specific ReaScript | `_RS{hex}_` + 40 hex | `_RS7d3c_ad8d4cee9621c4cc81e08dfbf1ef658f6d9a539a` | 47 chars |
| Main ReaScript | `_RS` + 40 hex | `_RSef72e1e5ee9cf04d1b458a17760b57aca13ef548` | 43 chars |
| SWS Extension | `PREFIX_NAME` | `XENAKIOS_INSERTMEDIAFROMCLIPBOARD` | 34 chars |
| Custom Action | `_` + 32 hex | `_113088d11ae641c193a2b7ede3041ad5` | 33 chars |

**Section prefixes** explain the 47-character maximum: MIDI Editor (section 32060 = `0x7d3c`) and Media Explorer (32063 = `0x7d3f`) scripts include a hexadecimal section prefix. The SDK confirms command IDs "must be unique across all sections," necessitating these prefixes.

The **40-character hex portion** derives from a SHA-1-style hash of the script's file path, made deterministic since REAPER v5.1 for portability.

## No hard limit exists in official documentation

Neither the official ReaScript API documentation nor the SDK headers (`reaper_plugin.h`, `reaper_plugin_functions.h`) specify a maximum command name length. The only documented constraint is that command IDs must contain **only alphanumeric characters** (A-Z, a-z, 0-9).

A related but distinct limit exists in `reaper-kb.ini`: maximum **1023 characters per ACT line entry**. This affects custom action chains combining multiple commands—not individual command ID lengths. Command strings exceeding this line length get truncated when REAPER rewrites the file.

## Handling the returned string safely

Since the returned pointer's lifetime is undocumented, copy immediately if persistence is needed:

```c
const char* actionId = ReverseNamedCommandLookup(cmdId);
if (actionId) {
    char storedId[128];  // SWS-established safe size
    snprintf(storedId, sizeof(storedId), "_%s", actionId);  // Re-add underscore
}
```

For **truncation handling**, follow SWS's pattern: use size-aware functions and check return values. Never use raw `strcpy()` on the returned string.

## Practical recommendations for extension developers

Based on this research, here are concrete buffer size guidelines:

- **64 bytes**: Absolute minimum for known algorithmically-generated formats (47-char max + null + small margin)
- **128 bytes**: **Recommended safe choice**—matches SWS's battle-tested `SNM_MAX_ACTION_CUSTID_LEN`
- **256 bytes**: Conservative choice providing ample headroom for any future format changes

The **128-byte buffer** represents the best balance: it's proven safe in production across the SWS Extension's massive user base while accommodating all known command ID formats with comfortable margin. Unless REAPER fundamentally changes its command registration system, this limit should remain reliable.

## Conclusion

While REAPER provides no official documented maximum, **128 bytes** is the empirically safe buffer size for storing `ReverseNamedCommandLookup` results. This value comes directly from the SWS Extension's source code—the gold standard for REAPER extension development. The longest observed command identifiers (section-prefixed ReaScripts) reach 47 characters, leaving substantial headroom within the 128-byte allocation. For maximum safety, always check for NULL returns, copy the string immediately, and use size-bounded string functions to handle potential truncation gracefully.
