# Menu Items Architecture

## Overview

REAmo needs a main menu under REAPER's "Extensions" menu bar for actions like showing QR codes, entering license keys, and opening settings. This document describes the architecture for implementing extensible menu items that integrate with REAPER's customizable menu system.

## REAPER Menu API

REAPER provides a two-phase menu hook system:

### Key API Functions

| Function | Purpose |
|----------|---------|
| `AddExtensionsMainMenu()` | Creates the "Extensions" entry in REAPER's main menu bar (idempotent — safe if SWS already called it) |
| `plugin_register("hookcustommenu", callback)` | Registers a callback invoked when any customizable menu is about to display |

### Hook Callback Signature (C)

```c
void hook(const char* menuidstr, void* menu, int flag);
```

Note: the `menu` parameter arrives as `void*` — cast to `HMENU` before passing to SWELL menu functions.

- **`menuidstr`**: Identifies which menu is being built. The Extensions menu is `"Main extensions"`. Other values include `"Main file"`, `"Main edit"`, `"Media item context"`, `"Track control panel context"`, etc.
- **`menu`**: Win32/SWELL menu handle (`HMENU`, which is `NSMenu*` on macOS) to populate
- **`flag`**:
  - `0` — Initialization (called once): add items/submenus to define the default menu structure. Do NOT set checked/grayed state, do NOT add icons, do NOT retain submenu handles.
  - `1` — Display (called every time menu opens): update checked/enabled/grayed state. Can also dynamically add/remove items.

Multiple hooks are all called — the callback returns `void` so no hook can block another. SWS registers two separate `hookcustommenu` callbacks in the same plugin, confirming REAPER iterates all registered hooks.

### hookcommand2 Chaining

```c
bool onAction(KbdSectionInfo *sec, int command, int val, int val2, int relmode, HWND hwnd);
```

- Return `false` for "not my command" — passes to next hook in chain
- Return `true` to consume the command — stops the chain
- Hooks are called in registration order; `"<hookcommand2"` (with `<` prefix) registers at start for higher priority
- SWS returns `false` for unknown commands, so our extension's commands pass through correctly

### Registration Order

Confirmed safe sequence (matches SWS and ReaPack):

1. Register all custom actions via `plugin_register("custom_action", ...)`
2. Register `hookcommand2` callback
3. Register `hookcustommenu` callback
4. Call `AddExtensionsMainMenu()`
5. Return 1 from plugin entrypoint

Register hooks before `AddExtensionsMainMenu()` to guarantee the flag=0 init event isn't missed.

## SWELL Menu API Details

### Critical: SWELL Differs from Win32

Three pitfalls that will cause silent bugs if Win32 values are assumed:

1. **`MIIM_*` flag values are completely reshuffled** — same names, different numbers
2. **`AppendMenu` is a C preprocessor macro** — not loadable via `SWELLAPI_GetFunc`. Must load `"SWELL_InsertMenu"` and call with `pos=-1`
3. **`InsertMenuItem` returns `void`** in SWELL, not `BOOL` as in Win32

### SWELL Function Names for SWELLAPI_GetFunc

| Lookup string | Signature | Notes |
|---|---|---|
| `"CreatePopupMenu"` | `HMENU CreatePopupMenu()` | Returns NSMenu* on macOS |
| `"DestroyMenu"` | `void DestroyMenu(HMENU)` | |
| `"InsertMenuItem"` | `void InsertMenuItem(HMENU, int pos, BOOL byPos, MENUITEMINFO*)` | **Returns void, not BOOL** |
| `"GetMenuItemCount"` | `int GetMenuItemCount(HMENU)` | |
| `"GetMenuItemInfo"` | `BOOL GetMenuItemInfo(HMENU, int pos, BOOL byPos, MENUITEMINFO*)` | |
| `"SetMenuItemInfo"` | `BOOL SetMenuItemInfo(HMENU, int pos, BOOL byPos, MENUITEMINFO*)` | |
| `"CheckMenuItem"` | `bool CheckMenuItem(HMENU, int idx, int chk)` | Returns lowercase `bool` |
| `"EnableMenuItem"` | `bool EnableMenuItem(HMENU, int idx, int en)` | Returns lowercase `bool` |
| `"DeleteMenu"` | `bool DeleteMenu(HMENU, int idx, int flag)` | |
| `"GetSubMenu"` | `HMENU GetSubMenu(HMENU, int pos)` | |
| `"GetMenuItemID"` | `int GetMenuItemID(HMENU, int pos)` | |
| `"SWELL_InsertMenu"` | `void SWELL_InsertMenu(HMENU, int pos, unsigned int flag, UINT_PTR idx, const char*)` | Use with `pos=-1` for append |

**Not loadable at runtime** (macros only): `AppendMenu`, `InsertMenu`, `InsertMenuItemA`, `GetMenuItemInfoA`, `AppendMenuA`, `SetMenuItemInfoA`. SWELL is UTF-8 only — no A/W distinction.

**SWELL-specific extension**: `CreatePopupMenuEx(const char *title)` — loadable as `"CreatePopupMenuEx"`.

### HMENU Type

On macOS, `HMENU` is a raw `NSMenu*` cast. No wrapper struct, no reference counting. In Zig, map as `?*anyopaque`.

### MENUITEMINFO Struct (SWELL)

```c
typedef struct {
    UINT      cbSize;          // sizeof(MENUITEMINFO)
    UINT      fMask;           // MIIM_* flags (SWELL values — see below!)
    UINT      fType;           // MFT_STRING, MFT_SEPARATOR, MFT_BITMAP, MFT_RADIOCHECK
    UINT      fState;          // MFS_CHECKED, MFS_GRAYED, MFS_ENABLED, etc.
    UINT      wID;             // command ID
    HMENU     hSubMenu;        // submenu handle (pointer-sized)
    HBITMAP   hbmpChecked;     // pointer-sized
    HBITMAP   hbmpUnchecked;   // pointer-sized
    ULONG_PTR dwItemData;      // pointer-sized application data
    char      *dwTypeData;     // pointer to menu item text (UTF-8)
    UINT      cch;             // text length
    HBITMAP   hbmpItem;        // pointer-sized
} MENUITEMINFO;
```

On 64-bit macOS this struct is **larger** than Win32 due to pointer-sized fields. In Zig, ensure `hSubMenu`, `hbmpChecked`, `hbmpUnchecked`, `dwItemData`, `dwTypeData`, and `hbmpItem` are all pointer-width.

### MIIM_* Constants (SWELL values — NOT Win32!)

| Constant | SWELL value | Win32 value | Use |
|---|---|---|---|
| `MIIM_ID` | **1** | 0x2 | wID is valid |
| `MIIM_STATE` | **2** | 0x1 | fState is valid |
| `MIIM_TYPE` | **4** | 0x10 | fType and dwTypeData are valid |
| `MIIM_SUBMENU` | **8** | 0x4 | hSubMenu is valid |
| `MIIM_DATA` | **16** | 0x20 | dwItemData is valid |
| `MIIM_BITMAP` | 0x80 | 0x80 | hbmpItem is valid (same value) |

SWELL does **not** define `MIIM_STRING`, `MIIM_CHECKMARKS`, or `MIIM_FTYPE`. Use `MIIM_TYPE` for both type and string data.

### MF_*/MFS_*/MFT_* Constants (same as Win32)

| Constant | Value | Use |
|---|---|---|
| `MF_ENABLED` / `MFS_ENABLED` | 0 | Item enabled |
| `MF_GRAYED` | 1 | Item grayed |
| `MF_DISABLED` | 2 | Item disabled |
| `MFS_GRAYED` | 3 | MF_GRAYED \| MF_DISABLED |
| `MF_STRING` / `MFT_STRING` | 0 | Text menu item |
| `MF_BITMAP` / `MFT_BITMAP` | 4 | Bitmap menu item |
| `MF_CHECKED` / `MFS_CHECKED` | 8 | Checked item |
| `MF_POPUP` | 0x10 | Item opens submenu |
| `MFT_RADIOCHECK` | 0x200 | Radio-style check |
| `MF_BYCOMMAND` | 0 | idx param is command ID |
| `MF_BYPOSITION` | 0x400 | idx param is position |
| `MF_SEPARATOR` / `MFT_SEPARATOR` | 0x800 | Separator line |

## Design

### Directory Structure

```
extension/src/
├── platform/
│   ├── menu.zig              # Menu registration, hook callback, HMENU operations
│   ├── menu_items.zig        # Menu item definitions (declarative table)
│   ├── swell.zig             # (existing) — needs new menu function bindings
│   ├── zig_swell_bridge.h    # (existing) — needs new menu function declarations
│   └── zig_swell_bridge.mm   # (existing) — needs new menu function implementations
├── main.zig                  # Calls menu.register() during init, menu.unregister() on shutdown
```

### Architecture Principles

1. **Declarative menu definition** — Menu items defined as a comptime table, similar to the command registry pattern in `commands/registry.zig`
2. **Separation of concerns** — `menu_items.zig` declares WHAT items exist; `menu.zig` handles HOW they're registered and displayed
3. **Action reuse** — Menu items trigger the same `custom_action` command IDs already used by standalone actions (e.g. QR code)
4. **Extensible** — Adding a new menu item = adding one entry to the table

### Module Design

#### `menu_items.zig` — Declarative Menu Table

```zig
/// A single menu item definition.
pub const MenuItem = struct {
    /// Unique REAPER action ID string (e.g. "REAMO_SHOW_QR_CODE")
    action_id: [*:0]const u8,
    /// Display text in the menu
    label: [*:0]const u8,
    /// Whether this item has a checkmark (toggle state)
    is_toggle: bool = false,
    /// Group for submenu organization (null = top-level)
    group: ?Group = null,
};

pub const Group = enum {
    connection,  // "Connection" submenu
    settings,    // "Settings" submenu
};

/// All menu items, evaluated at comptime.
/// Order here = display order in menu.
pub const items = [_]MenuItem{
    // ── Connection ──
    .{ .action_id = "REAMO_SHOW_QR_CODE",   .label = "Show Connection QR Code...", .group = .connection },
    .{ .action_id = "REAMO_SHOW_NETWORKS",   .label = "Show Network Addresses...",  .group = .connection },
    // ── Settings ──
    .{ .action_id = "REAMO_SETTINGS",        .label = "Settings...",                .group = .settings },
    .{ .action_id = "REAMO_ENTER_LICENSE",   .label = "Enter License Key...",       .group = .settings },
    // ── Top-level (no group) ──
    .{ .action_id = "REAMO_ABOUT",           .label = "About REAmo",               },
};
```

#### `menu.zig` — Registration and Hook Logic

```zig
const std = @import("std");
const menu_items = @import("menu_items.zig");
const swell = @import("swell.zig");
const logging = @import("../core/logging.zig");

const HMENU = ?*anyopaque;

/// Resolved command IDs for each menu item (populated during register).
/// Index matches menu_items.items.
var g_cmd_ids: [menu_items.items.len]c_int = [_]c_int{0} ** menu_items.items.len;

var g_plugin_register: ?PluginRegisterFn = null;

/// Register the Extensions menu and hook callback.
/// Called from main.zig during doInitialization().
pub fn register(plugin_register: PluginRegisterFn, add_ext_menu: AddExtMenuFn) bool {
    g_plugin_register = plugin_register;

    // 1. Register each menu item as a custom_action to get command IDs
    for (menu_items.items, 0..) |item, i| {
        var action = CustomActionRegister{
            .uniqueSectionId = 0,
            .idStr = item.action_id,
            .name = item.label,
            .extra = null,
        };
        g_cmd_ids[i] = plugin_register("custom_action", @ptrCast(&action));
        if (g_cmd_ids[i] == 0) {
            logging.warn("menu: failed to register action {s}", .{item.action_id});
        }
    }

    // 2. Register hookcommand2 for dispatching menu actions
    if (plugin_register("hookcommand2", @constCast(@ptrCast(&onCommand))) == 0) {
        logging.err("menu: failed to register hookcommand2", .{});
        return false;
    }

    // 3. Register the hookcustommenu callback
    if (plugin_register("hookcustommenu", @constCast(@ptrCast(&menuHook))) == 0) {
        logging.err("menu: failed to register hookcustommenu", .{});
        return false;
    }

    // 4. Create the Extensions menu (idempotent — safe if SWS already created it)
    _ = add_ext_menu();

    logging.info("menu: registered {d} items", .{menu_items.items.len});
    return true;
}

/// The hookcustommenu callback — called by REAPER for all customizable menus.
/// Multiple extensions' hooks all fire — this returns void so no blocking.
fn menuHook(menuidstr: [*:0]const u8, menu: ?*anyopaque, flag: c_int) callconv(.c) void {
    // Only handle the "Main extensions" menu
    if (!std.mem.eql(u8, std.mem.span(menuidstr), "Main extensions")) return;

    if (flag == 0) {
        // INIT (once): Build default menu structure
        buildMenu(menu);
    } else if (flag == 1) {
        // DISPLAY (every open): Update checked/enabled state
        updateMenuState(menu);
    }
}

/// Build the default menu structure (flag=0).
/// Creates "REAmo" submenu with grouped items.
fn buildMenu(hMenu: HMENU) void {
    const submenu = swell.createPopupMenu() orelse return;

    // Build groups in order
    var added_connection = false;
    var added_settings = false;

    for (menu_items.items, 0..) |item, i| {
        const cmd_id = g_cmd_ids[i];
        if (cmd_id == 0) continue;
        if (item.group == null) continue; // ungrouped items added below

        // Add separator between groups
        if (item.group == .settings and !added_settings and added_connection) {
            swell.insertMenuSeparator(submenu, -1); // -1 = append
        }

        swell.insertMenuItem(submenu, -1, cmd_id, item.label); // -1 = append

        if (item.group == .connection) added_connection = true;
        if (item.group == .settings) added_settings = true;
    }

    // Add separator before ungrouped items
    if (added_connection or added_settings) {
        swell.insertMenuSeparator(submenu, -1);
    }
    for (menu_items.items, 0..) |item, i| {
        if (item.group != null) continue;
        const cmd_id = g_cmd_ids[i];
        if (cmd_id == 0) continue;
        swell.insertMenuItem(submenu, -1, cmd_id, item.label);
    }

    // Add "REAmo" submenu to Extensions menu
    // Uses SWELL_InsertMenu with MF_POPUP | MF_STRING, pos=-1 (append)
    swell.insertSubMenu(hMenu, -1, submenu, "REAmo");
}

/// Update checked/enabled state (flag=1).
/// Recurses into submenus to find our items by command ID.
fn updateMenuState(hMenu: HMENU) void {
    const count = swell.getMenuItemCount(hMenu);
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        const sub = swell.getSubMenu(hMenu, i);
        if (sub != null) {
            updateMenuState(sub); // Recurse
        } else {
            const wID = swell.getMenuItemID(hMenu, i);
            // Check if this is one of our items
            for (menu_items.items, 0..) |item, idx| {
                if (wID == g_cmd_ids[idx] and g_cmd_ids[idx] != 0) {
                    if (item.is_toggle) {
                        const checked = queryToggleState(g_cmd_ids[idx]);
                        swell.checkMenuItem(hMenu, @intCast(i), checked);
                    }
                    break;
                }
            }
        }
    }
}

/// hookcommand2 callback — dispatches menu item clicks to handlers.
/// Returns false for unrecognized commands to let other extensions handle them.
fn onCommand(
    section: ?*anyopaque,
    command: c_int,
    val: c_int,
    val2hw: c_int,
    relmode: c_int,
    hwnd: ?*anyopaque,
) callconv(.c) bool {
    _ = .{ section, val, val2hw, relmode, hwnd };
    for (menu_items.items, 0..) |_, i| {
        if (command == g_cmd_ids[i] and g_cmd_ids[i] != 0) {
            dispatchAction(i);
            return true;
        }
    }
    return false; // Not our command — let other hooks handle it
}
```

### Integration with Existing Actions

The QR code and network address actions are currently registered in `network_action.zig`. With the menu system:

1. **Action registration moves to `menu.zig`** — All `custom_action` registrations happen in one place
2. **`network_action.zig` becomes a handler module** — It keeps `showQRCode()` and `showNetworkAddresses()` as public functions but drops its own registration logic
3. **`hookcommand2` consolidation** — One `hookcommand2` callback in `menu.zig` replaces the one in `network_action.zig`

This means `network_action.register()` / `network_action.unregister()` calls in `main.zig` are replaced by `menu.register()` / `menu.unregister()`.

### New SWELL Bindings Required

Functions to load via `SWELLAPI_GetFunc` (exact lookup strings):

```
zig_swell_bridge.mm / .h — new function pointer getters:
  "CreatePopupMenu"     → zig_swell_get_CreatePopupMenu    // () -> HMENU
  "DestroyMenu"         → zig_swell_get_DestroyMenu        // (HMENU) -> void
  "SWELL_InsertMenu"    → zig_swell_get_SWELL_InsertMenu   // (HMENU, int pos, uint flags, UINT_PTR id, const char*) -> void
  "InsertMenuItem"      → zig_swell_get_InsertMenuItem      // (HMENU, int pos, BOOL byPos, MENUITEMINFO*) -> void (NOT BOOL!)
  "GetMenuItemCount"    → zig_swell_get_GetMenuItemCount    // (HMENU) -> int
  "GetMenuItemInfo"     → zig_swell_get_GetMenuItemInfo     // (HMENU, int pos, BOOL byPos, MENUITEMINFO*) -> BOOL
  "GetSubMenu"          → zig_swell_get_GetSubMenu          // (HMENU, int pos) -> HMENU
  "GetMenuItemID"       → zig_swell_get_GetMenuItemID       // (HMENU, int pos) -> int
  "CheckMenuItem"       → zig_swell_get_CheckMenuItem       // (HMENU, int idx, int chk) -> bool
  "EnableMenuItem"      → zig_swell_get_EnableMenuItem      // (HMENU, int idx, int en) -> bool
  "DeleteMenu"          → zig_swell_get_DeleteMenu          // (HMENU, int idx, int flag) -> bool
```

swell.zig new public wrappers:

```zig
// SWELL MIIM_* constants (NOT Win32 values!)
pub const MIIM_ID = 1;
pub const MIIM_STATE = 2;
pub const MIIM_TYPE = 4;
pub const MIIM_SUBMENU = 8;
pub const MIIM_DATA = 16;

// MF_* constants (same as Win32)
pub const MF_STRING = 0;
pub const MF_CHECKED = 8;
pub const MF_POPUP = 0x10;
pub const MF_BYCOMMAND = 0;
pub const MF_BYPOSITION = 0x400;
pub const MF_SEPARATOR = 0x800;
pub const MF_ENABLED = 0;
pub const MF_GRAYED = 1;

pub const HMENU = ?*anyopaque;

pub const MenuItemInfo = extern struct {
    cbSize: c_uint,
    fMask: c_uint,
    fType: c_uint,
    fState: c_uint,
    wID: c_uint,
    hSubMenu: ?*anyopaque,     // pointer-sized on macOS
    hbmpChecked: ?*anyopaque,
    hbmpUnchecked: ?*anyopaque,
    dwItemData: usize,
    dwTypeData: ?[*:0]u8,
    cch: c_uint,
    hbmpItem: ?*anyopaque,
};

pub fn createPopupMenu() HMENU { ... }
pub fn destroyMenu(menu: HMENU) void { ... }
pub fn insertMenuItem(menu: HMENU, pos: c_int, cmd_id: c_int, text: [*:0]const u8) void { ... }
pub fn insertMenuSeparator(menu: HMENU, pos: c_int) void { ... }
pub fn insertSubMenu(parent: HMENU, pos: c_int, submenu: HMENU, text: [*:0]const u8) void { ... }
pub fn getMenuItemCount(menu: HMENU) c_int { ... }
pub fn getSubMenu(menu: HMENU, pos: c_int) HMENU { ... }
pub fn getMenuItemID(menu: HMENU, pos: c_int) c_int { ... }
pub fn checkMenuItem(menu: HMENU, idx: c_int, checked: bool) void { ... }
pub fn enableMenuItem(menu: HMENU, idx: c_int, enabled: bool) void { ... }
```

Note: `insertMenuItem`, `insertMenuSeparator`, and `insertSubMenu` are Zig wrappers around `SWELL_InsertMenu` (with `pos=-1` for append). They compose the raw function with appropriate `MF_*` flags:
- `insertMenuItem(menu, -1, id, text)` → `SWELL_InsertMenu(menu, -1, MF_STRING, id, text)`
- `insertMenuSeparator(menu, -1)` → `SWELL_InsertMenu(menu, -1, MF_SEPARATOR, 0, "")`
- `insertSubMenu(parent, -1, sub, text)` → `SWELL_InsertMenu(parent, -1, MF_POPUP|MF_STRING, @intFromPtr(sub), text)`

### REAPER API Additions to raw.zig

```zig
// In Api struct:
addExtensionsMainMenu: ?*const fn () callconv(.c) bool = null,

// In Api.load():
.addExtensionsMainMenu = getFunc(info, "AddExtensionsMainMenu", fn () callconv(.c) bool),
```

### Registration Sequence (main.zig)

```zig
// In doInitialization(), replaces current network_action.register() block:
if (g_plugin_register) |plugin_register| {
    if (g_api) |*inner_api| {
        if (inner_api.addExtensionsMainMenu) |add_ext_menu| {
            if (menu.register(plugin_register, add_ext_menu)) {
                logging.info("Extension menu registered", .{});
            }
        }
    }
}
```

### Shutdown

```zig
// In shutdown(), replaces network_action.unregister():
menu.unregister();
```

## Menu Structure (User-Visible)

```
Extensions
└── REAmo
    ├── Show Connection QR Code...
    ├── Show Network Addresses...
    ├── ────────────────────────
    ├── Settings...
    ├── Enter License Key...
    ├── ────────────────────────
    └── About REAmo
```

Position among other extensions' items depends on plugin load order (alphabetical by .dylib filename). Users can customize item order via REAPER's menu customization UI.

## Adding New Menu Items

To add a new menu item:

1. Add an entry to `menu_items.zig`:
   ```zig
   .{ .action_id = "REAMO_MY_FEATURE", .label = "My Feature...", .group = .settings },
   ```

2. Add a handler case in `menu.zig`'s dispatch function (or a handler registry)

3. Implement the handler in the appropriate `platform/` or other module

No changes needed to `main.zig`, SWELL bindings, or the menu hook — it's all driven by the comptime table.

## Resolved Questions

1. **AddExtensionsMainMenu idempotency**: Confirmed safe to call multiple times. SWS, ReaPack, and others all call it. Subsequent calls are no-ops.

2. **menuidstr for Extensions menu**: `"Main extensions"` — verified from SWS source (`swsMenuHook` and `SNM_Menuhook` both check this string).

3. **SWELL function availability**: All needed functions are loadable via `SWELLAPI_GetFunc` under their Win32 names (no `SWELL_` prefix), except `AppendMenu`/`InsertMenu` which are C macros — use `"SWELL_InsertMenu"` instead.

4. **MENUITEMINFO struct**: Same field names as Win32 but pointer-sized fields make it larger on 64-bit. Full layout documented above with Zig mapping.

5. **MIIM_* constants**: Completely reshuffled from Win32 (MIIM_ID=1, MIIM_STATE=2, MIIM_TYPE=4, MIIM_SUBMENU=8). Must use SWELL values, not Win32 values.

6. **Flag=0 restrictions**: Confirmed — no checked/grayed state, no icons, no retaining submenu handles. `CreatePopupMenu` + `InsertMenuItem` / `SWELL_InsertMenu` are safe during flag=0.

7. **hookcommand2 coexistence**: Hooks chain correctly. Return `false` for unrecognized commands. First `true` return stops the chain. Multiple extensions coexist safely.

8. **Menu item ordering**: Determined by hook registration order (which follows alphabetical plugin load order). No explicit sort-position API. Users can reorder via REAPER's menu customization. SDK advises handling by command ID, not position.

## Implementation Plan

### Phase 1: SWELL Menu Bindings
- Add menu-related function pointer getters to `zig_swell_bridge.mm/.h`
- Add `MenuItemInfo` extern struct and SWELL-specific `MIIM_*`/`MF_*` constants to `swell.zig`
- Add Zig wrapper functions in `swell.zig`
- Verify `CreatePopupMenu` etc. load successfully at plugin init

### Phase 2: Menu Core
- Create `menu.zig` with registration, hook callback, command dispatch
- Create `menu_items.zig` with initial item table
- Add `AddExtensionsMainMenu` to `raw.zig` API loading
- Wire into `main.zig` init/shutdown

### Phase 3: Migrate Existing Actions
- Move QR code and network address action registration from `network_action.zig` into the menu system
- Keep handler functions in `network_action.zig` (it becomes a handler-only module)
- Remove `network_action.register()` / `.unregister()` calls from `main.zig`

### Phase 4: New Menu Items
- Add Settings dialog menu item
- Add License Key entry menu item
- Add About dialog menu item
