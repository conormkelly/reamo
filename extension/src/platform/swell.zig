/// SWELL (Simple Windows Emulation Layer) bindings for Zig.
///
/// Provides access to SWELL graphics and window functions on macOS/Linux.
/// On Windows, these functions map to native Win32 APIs (not yet implemented).
///
/// Usage:
///   const swell = @import("swell.zig");
///   if (swell.init()) {
///       const hwnd = swell.createDialogParam(...);
///   }

const std = @import("std");
const builtin = @import("builtin");

/// True on platforms that use SWELL (macOS, Linux)
/// False on Windows where native Win32 is used
pub const is_swell_platform = builtin.os.tag == .macos or builtin.os.tag == .linux;

// =============================================================================
// Types
// =============================================================================

/// Window handle (opaque pointer)
pub const HWND = ?*anyopaque;

/// Device context handle (opaque pointer)
pub const HDC = ?*anyopaque;

/// PAINTSTRUCT for BeginPaint/EndPaint
pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: c_int,
    rcPaint: [4]c_int, // RECT: left, top, right, bottom
    fRestore: c_int,
    fIncUpdate: c_int,
    rgbReserved: [32]u8,
};

/// Dialog procedure function type
pub const DlgProc = *const fn (HWND, c_uint, usize, isize) callconv(.c) isize;

// =============================================================================
// Window message constants
// =============================================================================

pub const WM_INITDIALOG: c_uint = 0x0110;
pub const WM_COMMAND: c_uint = 0x0111;
pub const WM_PAINT: c_uint = 0x000F;
pub const WM_CLOSE: c_uint = 0x0010;
pub const WM_DESTROY: c_uint = 0x0002;
pub const WM_SIZE: c_uint = 0x0005;
pub const WM_KEYDOWN: c_uint = 0x0100;
pub const WM_LBUTTONDOWN: c_uint = 0x0201;
pub const WM_TIMER: c_uint = 0x0113;

/// Timer callback function type (TIMERPROC)
/// Parameters: hwnd, msg (WM_TIMER), timer_id, tick_count
pub const TIMERPROC = *const fn (?*anyopaque, c_uint, usize, c_uint) callconv(.c) void;

// ShowWindow commands
// SWELL uses different values than Win32: SW_SHOW=2 (not 5), SW_SHOWNA=1 (not 8)
pub const SW_HIDE: c_int = if (is_swell_platform) 0 else 0;
pub const SW_SHOW: c_int = if (is_swell_platform) 2 else 5;
pub const SW_SHOWNA: c_int = if (is_swell_platform) 1 else 8;

// SetWindowPos flags
pub const SWP_NOZORDER: c_uint = 0x0004;
pub const SWP_NOSIZE: c_uint = 0x0001;
pub const SWP_NOMOVE: c_uint = 0x0002;

// SWELL floating window level (macOS only)
pub const NSFloatingWindowLevel: c_int = 3;

// =============================================================================
// Extern declarations (from zig_swell_bridge)
// =============================================================================

extern fn zig_swell_init() bool;
extern fn zig_swell_is_macos() bool;
extern fn zig_swell_create_modeless_dialog(HWND, DlgProc, c_int, c_int) HWND;
extern fn zig_swell_get_CreateDialogParam() ?*const fn (?*anyopaque, ?*const anyopaque, HWND, DlgProc, isize) callconv(.c) HWND;
extern fn zig_swell_get_BeginPaint() ?*const fn (HWND, *PAINTSTRUCT) callconv(.c) HDC;
extern fn zig_swell_get_EndPaint() ?*const fn (HWND, *PAINTSTRUCT) callconv(.c) c_int;
extern fn zig_swell_get_StretchBltFromMem() ?*const fn (HDC, c_int, c_int, c_int, c_int, ?*const anyopaque, c_int, c_int, c_int) callconv(.c) void;
extern fn zig_swell_get_DestroyWindow() ?*const fn (HWND) callconv(.c) void;
extern fn zig_swell_get_SetWindowLevel() ?*const fn (HWND, c_int) callconv(.c) c_int;
extern fn zig_swell_get_InvalidateRect() ?*const fn (HWND, ?*anyopaque, c_int) callconv(.c) void;
extern fn zig_swell_get_ShowWindow() ?*const fn (HWND, c_int) callconv(.c) void;
extern fn zig_swell_get_SetDlgItemText() ?*const fn (HWND, c_int, [*:0]const u8) callconv(.c) c_int;
extern fn zig_swell_get_SetWindowPos() ?*const fn (HWND, HWND, c_int, c_int, c_int, c_int, c_uint) callconv(.c) c_int;
extern fn zig_swell_get_DefWindowProc() ?*const fn (HWND, c_uint, usize, isize) callconv(.c) isize;
extern fn zig_swell_get_CreateSolidBrush() ?*const fn (c_int) callconv(.c) ?*anyopaque;
extern fn zig_swell_get_FillRect() ?*const fn (HDC, *const [4]c_int, ?*anyopaque) callconv(.c) c_int;
extern fn zig_swell_get_DeleteObject() ?*const fn (?*anyopaque) callconv(.c) void;
extern fn zig_swell_get_SetBkMode() ?*const fn (HDC, c_int) callconv(.c) c_int;
extern fn zig_swell_get_SetTextColor() ?*const fn (HDC, c_uint) callconv(.c) c_uint;
extern fn zig_swell_get_DrawText() ?*const fn (HDC, [*:0]const u8, c_int, *[4]c_int, c_uint) callconv(.c) c_int;
extern fn zig_swell_get_SWELL_CreateMemContext() ?*const fn (HDC, c_int, c_int) callconv(.c) HDC;
extern fn zig_swell_get_SWELL_DeleteGfxContext() ?*const fn (HDC) callconv(.c) void;
extern fn zig_swell_get_SWELL_GetCtxFrameBuffer() ?*const fn (HDC) callconv(.c) ?[*]u32;
extern fn zig_swell_get_BitBlt() ?*const fn (HDC, c_int, c_int, c_int, c_int, HDC, c_int, c_int, c_int) callconv(.c) void;
extern fn zig_swell_get_SetTimer() ?*const fn (HWND, usize, c_uint, ?TIMERPROC) callconv(.c) usize;
extern fn zig_swell_get_KillTimer() ?*const fn (HWND, usize) callconv(.c) c_int;

// Window geometry
extern fn zig_swell_get_GetWindowRect() ?*const fn (?*anyopaque, *[4]c_int) callconv(.c) bool;

// Menu functions
extern fn zig_swell_get_CreatePopupMenu() ?*const fn () callconv(.c) ?*anyopaque;
extern fn zig_swell_get_DestroyMenu() ?*const fn (?*anyopaque) callconv(.c) void;
extern fn zig_swell_get_SWELL_InsertMenu() ?*const fn (?*anyopaque, c_int, c_uint, usize, [*:0]const u8) callconv(.c) void;
extern fn zig_swell_get_GetMenuItemCount() ?*const fn (?*anyopaque) callconv(.c) c_int;
extern fn zig_swell_get_GetSubMenu() ?*const fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque;
extern fn zig_swell_get_GetMenuItemID() ?*const fn (?*anyopaque, c_int) callconv(.c) c_int;
extern fn zig_swell_get_CheckMenuItem() ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) bool;
extern fn zig_swell_get_EnableMenuItem() ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) bool;
extern fn zig_swell_get_SWELL_SetMenuItemText() ?*const fn (?*anyopaque, c_int, [*:0]const u8) callconv(.c) void;
extern fn zig_swell_get_SetMenuItemInfo() ?*const fn (?*anyopaque, c_int, c_int, *const MenuItemInfo) callconv(.c) c_int;

// =============================================================================
// Public API
// =============================================================================

/// Initialize SWELL bindings. Must be called before using other functions.
/// Returns true if SWELL was loaded successfully.
pub fn init() bool {
    if (comptime !is_swell_platform) {
        // Windows: no SWELL initialization needed
        return true;
    }
    return zig_swell_init();
}

/// Returns true if running on macOS (useful for SetWindowLevel)
pub fn isMacOS() bool {
    if (comptime !is_swell_platform) return false;
    return zig_swell_is_macos();
}

/// Create a modeless dialog window.
/// Use resid 0x400001 for a resource-less floating window.
pub fn createDialogParam(resid: usize, parent: HWND, dlgProc: DlgProc, param: isize) HWND {
    if (comptime !is_swell_platform) {
        _ = .{ resid, parent, dlgProc, param };
        return null;
    }

    const func = zig_swell_get_CreateDialogParam() orelse return null;
    return func(null, @ptrFromInt(resid), parent, dlgProc, param);
}

/// Create a floating window without dialog resources.
/// Uses special resid 0x400008: titled, closable, minimizable, non-resizable.
/// Bit 3 forces top-level without setting bit 0 (resizable).
pub fn createFloatingWindow(parent: HWND, dlgProc: DlgProc) HWND {
    return createDialogParam(0x400008, parent, dlgProc, 0);
}

/// Create a modeless dialog with a proper SWELL resource template.
/// This is the reliable way to create visible windows on Linux GDK.
/// The templateless path (createFloatingWindow) doesn't produce visible windows on Linux.
pub fn createModelessDialog(parent: HWND, dlgProc: DlgProc, width: c_int, height: c_int) HWND {
    if (comptime !is_swell_platform) {
        _ = .{ parent, dlgProc, width, height };
        return null; // TODO: Windows implementation
    }
    return zig_swell_create_modeless_dialog(parent, dlgProc, width, height);
}

/// Begin painting a window. Must be paired with endPaint().
pub fn beginPaint(hwnd: HWND, ps: *PAINTSTRUCT) HDC {
    if (comptime !is_swell_platform) {
        // Windows: TODO implement native BeginPaint
        _ = .{ hwnd, ps };
        return null;
    }

    const func = zig_swell_get_BeginPaint() orelse return null;
    return func(hwnd, ps);
}

/// End painting a window. Must be called after beginPaint().
pub fn endPaint(hwnd: HWND, ps: *PAINTSTRUCT) void {
    if (comptime !is_swell_platform) {
        // Windows: TODO implement native EndPaint
        _ = .{ hwnd, ps };
        return;
    }

    const func = zig_swell_get_EndPaint() orelse return;
    _ = func(hwnd, ps);
}

/// Blit a raw pixel buffer to a device context.
/// NOTE: Not available on macOS (only in LICE backend used by Linux).
/// Use createMemContext + getCtxFrameBuffer + bitBlt instead.
pub fn stretchBltFromMem(hdc: HDC, x: c_int, y: c_int, w: c_int, h: c_int, bits: [*]const u32, srcw: c_int, srch: c_int, srcspan: c_int) void {
    if (comptime !is_swell_platform) {
        _ = .{ hdc, x, y, w, h, bits, srcw, srch, srcspan };
        return;
    }

    const func = zig_swell_get_StretchBltFromMem() orelse return;
    func(hdc, x, y, w, h, bits, srcw, srch, srcspan);
}

/// Destroy a window.
pub fn destroyWindow(hwnd: HWND) void {
    if (comptime !is_swell_platform) {
        // Windows: TODO implement native DestroyWindow
        return;
    }

    const func = zig_swell_get_DestroyWindow() orelse return;
    func(hwnd);
}

/// Set window floating level (macOS only).
/// Level 3 = NSFloatingWindowLevel (floats above normal windows)
pub fn setWindowLevel(hwnd: HWND, level: c_int) void {
    if (comptime !is_swell_platform) return;

    const func = zig_swell_get_SetWindowLevel() orelse return;
    _ = func(hwnd, level);
}

/// Invalidate a window's client area, causing WM_PAINT to be sent.
pub fn invalidateRect(hwnd: HWND, rect: ?*anyopaque, erase: bool) void {
    if (comptime !is_swell_platform) {
        _ = .{ hwnd, rect, erase };
        return;
    }

    const func = zig_swell_get_InvalidateRect() orelse return;
    func(hwnd, rect, if (erase) 1 else 0);
}

/// Show or hide a window.
pub fn showWindow(hwnd: HWND, cmd: c_int) void {
    if (comptime !is_swell_platform) {
        _ = .{ hwnd, cmd };
        return;
    }

    const func = zig_swell_get_ShowWindow() orelse return;
    func(hwnd, cmd);
}

/// Set window title text.
pub fn setWindowText(hwnd: HWND, text: [*:0]const u8) void {
    if (comptime !is_swell_platform) {
        _ = .{ hwnd, text };
        return;
    }

    // SetWindowText is a macro in SWELL: SetDlgItemText(hwnd, 0, text)
    const func = zig_swell_get_SetDlgItemText() orelse return;
    _ = func(hwnd, 0, text);
}

/// Set window position and size.
pub fn setWindowPos(hwnd: HWND, insertAfter: HWND, x: c_int, y: c_int, cx: c_int, cy: c_int, flags: c_uint) void {
    if (comptime !is_swell_platform) {
        _ = .{ hwnd, insertAfter, x, y, cx, cy, flags };
        return;
    }

    const func = zig_swell_get_SetWindowPos() orelse return;
    _ = func(hwnd, insertAfter, x, y, cx, cy, flags);
}

/// Get the screen-space rectangle of a window. Returns false on failure.
/// rect is [left, top, right, bottom].
pub fn getWindowRect(hwnd: HWND, rect: *[4]c_int) bool {
    if (comptime !is_swell_platform) {
        _ = .{ hwnd, rect };
        return false;
    }
    const func = zig_swell_get_GetWindowRect() orelse return false;
    return func(hwnd, rect);
}

/// Default window procedure - handles unprocessed messages.
pub fn defWindowProc(hwnd: HWND, msg: c_uint, wParam: usize, lParam: isize) isize {
    if (comptime !is_swell_platform) {
        _ = .{ hwnd, msg, wParam, lParam };
        return 0;
    }

    const func = zig_swell_get_DefWindowProc() orelse return 0;
    return func(hwnd, msg, wParam, lParam);
}

// =============================================================================
// Drawing functions
// NOTE: DrawText may not work on macOS native SWELL (returns 0).
// =============================================================================

/// Background mode constants
pub const TRANSPARENT: c_int = 1;
pub const OPAQUE: c_int = 2;

/// DrawText format flags
pub const DT_LEFT: c_uint = 0x0000;
pub const DT_CENTER: c_uint = 0x0001;
pub const DT_SINGLELINE: c_uint = 0x0020;
pub const DT_NOCLIP: c_uint = 0x0100;

/// Create a solid color brush. Color is 0x00BBGGRR format.
pub fn createSolidBrush(color: c_int) ?*anyopaque {
    if (comptime !is_swell_platform) return null;
    const func = zig_swell_get_CreateSolidBrush() orelse {
        std.log.err("swell: CreateSolidBrush function not loaded", .{});
        return null;
    };
    return func(color);
}

/// Fill a rectangle with a brush.
pub fn fillRect(hdc: HDC, rect: *const [4]c_int, brush: ?*anyopaque) c_int {
    if (comptime !is_swell_platform) {
        _ = .{ hdc, rect, brush };
        return 0;
    }
    const func = zig_swell_get_FillRect() orelse {
        std.log.err("swell: FillRect function not loaded", .{});
        return 0;
    };
    return func(hdc, rect, brush);
}

/// Delete a GDI object (brush, pen, etc).
pub fn deleteObject(obj: ?*anyopaque) void {
    if (comptime !is_swell_platform) return;
    const func = zig_swell_get_DeleteObject() orelse return;
    func(obj);
}

/// Set background mode (TRANSPARENT or OPAQUE).
pub fn setBkMode(hdc: HDC, mode: c_int) c_int {
    if (comptime !is_swell_platform) {
        _ = .{ hdc, mode };
        return 0;
    }
    const func = zig_swell_get_SetBkMode() orelse return 0;
    return func(hdc, mode);
}

/// Set text color. Color is 0x00BBGGRR format.
pub fn setTextColor(hdc: HDC, color: c_uint) c_uint {
    if (comptime !is_swell_platform) {
        _ = .{ hdc, color };
        return 0;
    }
    const func = zig_swell_get_SetTextColor() orelse return 0;
    return func(hdc, color);
}

/// Draw text in a rectangle.
pub fn drawText(hdc: HDC, text: [*:0]const u8, len: c_int, rect: *[4]c_int, format: c_uint) c_int {
    if (comptime !is_swell_platform) {
        _ = .{ hdc, text, len, rect, format };
        return 0;
    }
    const func = zig_swell_get_DrawText() orelse return 0;
    return func(hdc, text, len, rect, format);
}

// =============================================================================
// Memory DC functions (for bitmap blitting without StretchBltFromMem)
// =============================================================================

/// BitBlt mode: copy source to destination
pub const SRCCOPY: c_int = 0x00CC0020;

/// Create a memory device context with pixel buffer.
/// Returns null on failure.
pub fn createMemContext(hdc: HDC, w: c_int, h: c_int) HDC {
    if (comptime !is_swell_platform) {
        _ = .{ hdc, w, h };
        return null;
    }
    const func = zig_swell_get_SWELL_CreateMemContext() orelse {
        std.log.err("swell: SWELL_CreateMemContext not loaded", .{});
        return null;
    };
    return func(hdc, w, h);
}

/// Delete a graphics context (memory DC).
pub fn deleteGfxContext(ctx: HDC) void {
    if (comptime !is_swell_platform) return;
    const func = zig_swell_get_SWELL_DeleteGfxContext() orelse return;
    func(ctx);
}

/// Get the frame buffer pointer for a memory DC.
/// Pixel format is ARGB (0xAARRGGBB) in native byte order.
pub fn getCtxFrameBuffer(ctx: HDC) ?[*]u32 {
    if (comptime !is_swell_platform) return null;
    const func = zig_swell_get_SWELL_GetCtxFrameBuffer() orelse {
        std.log.err("swell: SWELL_GetCtxFrameBuffer not loaded", .{});
        return null;
    };
    return func(ctx);
}

/// Copy pixels from one DC to another.
pub fn bitBlt(hdcOut: HDC, x: c_int, y: c_int, w: c_int, h: c_int, hdcIn: HDC, xin: c_int, yin: c_int, mode: c_int) void {
    if (comptime !is_swell_platform) {
        _ = .{ hdcOut, x, y, w, h, hdcIn, xin, yin, mode };
        return;
    }
    const func = zig_swell_get_BitBlt() orelse {
        std.log.err("swell: BitBlt not loaded", .{});
        return;
    };
    func(hdcOut, x, y, w, h, hdcIn, xin, yin, mode);
}

// =============================================================================
// Timer functions
// =============================================================================

/// Create a timer that fires at the specified interval.
/// If hwnd is null and callback is provided, uses TIMERPROC callback directly.
/// Returns timer ID on success, 0 on failure.
pub fn setTimer(hwnd: HWND, id: usize, interval_ms: c_uint, callback: ?TIMERPROC) usize {
    if (comptime !is_swell_platform) {
        // Windows: handled by fast_timer.zig directly
        _ = .{ hwnd, id, interval_ms, callback };
        return 0;
    }
    const func = zig_swell_get_SetTimer() orelse {
        std.log.err("swell: SetTimer not loaded", .{});
        return 0;
    };
    return func(hwnd, id, interval_ms, callback);
}

/// Destroy a timer created with setTimer.
/// Returns true on success.
pub fn killTimer(hwnd: HWND, id: usize) bool {
    if (comptime !is_swell_platform) {
        // Windows: handled by fast_timer.zig directly
        _ = .{ hwnd, id };
        return false;
    }
    const func = zig_swell_get_KillTimer() orelse {
        std.log.err("swell: KillTimer not loaded", .{});
        return false;
    };
    return func(hwnd, id) != 0;
}

// =============================================================================
// Menu functions
// =============================================================================

/// Menu handle (HMENU — NSMenu* on macOS, opaque pointer)
pub const HMENU = ?*anyopaque;

/// MENUITEMINFO — matches SWELL's struct layout (swell-types.h)
pub const MenuItemInfo = extern struct {
    cbSize: c_uint = @sizeOf(MenuItemInfo),
    fMask: c_uint = 0,
    fType: c_uint = 0,
    fState: c_uint = 0,
    wID: c_uint = 0,
    hSubMenu: HMENU = null,
    hbmpChecked: ?*anyopaque = null,
    hbmpUnchecked: ?*anyopaque = null,
    dwItemData: usize = 0,
    dwTypeData: ?[*:0]u8 = null,
    cch: c_int = 0,
    hbmpItem: ?*anyopaque = null,
};

// SWELL MIIM_* constants (NOT Win32 values — completely reshuffled!)
pub const MIIM_ID = 1;
pub const MIIM_STATE = 2;
pub const MIIM_TYPE = 4;
pub const MIIM_SUBMENU = 8;
pub const MIIM_DATA = 16;

// MF_* constants (same as Win32)
pub const MF_STRING: c_uint = 0;
pub const MF_GRAYED: c_uint = 1;
pub const MF_CHECKED: c_uint = 8;
pub const MF_POPUP: c_uint = 0x10;
pub const MF_BYCOMMAND: c_uint = 0;
pub const MF_BYPOSITION: c_uint = 0x400;
pub const MF_SEPARATOR: c_uint = 0x800;
pub const MF_ENABLED: c_uint = 0;

/// Create an empty popup menu. Returns null on failure.
pub fn createPopupMenu() HMENU {
    if (comptime !is_swell_platform) return null;
    const func = zig_swell_get_CreatePopupMenu() orelse return null;
    return func();
}

/// Destroy a menu handle.
pub fn destroyMenu(menu: HMENU) void {
    if (comptime !is_swell_platform) return;
    const func = zig_swell_get_DestroyMenu() orelse return;
    func(menu);
}

/// Append a text menu item. Uses SWELL_InsertMenu with pos=-1 (append).
pub fn insertMenuItem(menu: HMENU, pos: c_int, cmd_id: c_int, text: [*:0]const u8) void {
    if (comptime !is_swell_platform) {
        _ = .{ menu, pos, cmd_id, text };
        return;
    }
    const func = zig_swell_get_SWELL_InsertMenu() orelse return;
    func(menu, pos, MF_STRING, @intCast(@as(c_uint, @bitCast(cmd_id))), text);
}

/// Append a separator. Uses SWELL_InsertMenu with MF_SEPARATOR.
pub fn insertMenuSeparator(menu: HMENU, pos: c_int) void {
    if (comptime !is_swell_platform) {
        _ = .{ menu, pos };
        return;
    }
    const func = zig_swell_get_SWELL_InsertMenu() orelse return;
    func(menu, pos, MF_SEPARATOR, 0, "");
}

/// Append a submenu. Uses SWELL_InsertMenu with MF_POPUP | MF_STRING.
pub fn insertSubMenu(parent: HMENU, pos: c_int, submenu: HMENU, text: [*:0]const u8) void {
    if (comptime !is_swell_platform) {
        _ = .{ parent, pos, submenu, text };
        return;
    }
    const func = zig_swell_get_SWELL_InsertMenu() orelse return;
    const sub_ptr = submenu orelse return;
    func(parent, pos, MF_POPUP | MF_STRING, @intFromPtr(sub_ptr), text);
}

/// Get the number of items in a menu.
pub fn getMenuItemCount(menu: HMENU) c_int {
    if (comptime !is_swell_platform) return 0;
    const func = zig_swell_get_GetMenuItemCount() orelse return 0;
    return func(menu);
}

/// Get submenu at a given position. Returns null if not a submenu.
pub fn getSubMenu(menu: HMENU, pos: c_int) HMENU {
    if (comptime !is_swell_platform) {
        _ = .{ menu, pos };
        return null;
    }
    const func = zig_swell_get_GetSubMenu() orelse return null;
    return func(menu, pos);
}

/// Get the command ID of a menu item at a given position.
pub fn getMenuItemID(menu: HMENU, pos: c_int) c_int {
    if (comptime !is_swell_platform) {
        _ = .{ menu, pos };
        return 0;
    }
    const func = zig_swell_get_GetMenuItemID() orelse return 0;
    return func(menu, pos);
}

/// Set or clear the checkmark on a menu item (by position).
pub fn checkMenuItem(menu: HMENU, idx: c_int, checked: bool) void {
    if (comptime !is_swell_platform) {
        _ = .{ menu, idx, checked };
        return;
    }
    const func = zig_swell_get_CheckMenuItem() orelse return;
    _ = func(menu, idx, if (checked) @as(c_int, MF_BYPOSITION | MF_CHECKED) else @as(c_int, @bitCast(MF_BYPOSITION)));
}

/// Enable or gray out a menu item (by position).
pub fn enableMenuItem(menu: HMENU, idx: c_int, enabled: bool) void {
    if (comptime !is_swell_platform) {
        _ = .{ menu, idx, enabled };
        return;
    }
    const func = zig_swell_get_EnableMenuItem() orelse return;
    _ = func(menu, idx, if (enabled) @as(c_int, @bitCast(MF_BYPOSITION | MF_ENABLED)) else @as(c_int, @bitCast(MF_BYPOSITION | MF_GRAYED)));
}

/// Set the text of a menu item (by position).
pub fn setMenuItemText(menu: HMENU, idx: c_int, text: [*:0]const u8) void {
    if (comptime !is_swell_platform) {
        _ = .{ menu, idx, text };
        return;
    }
    const func = zig_swell_get_SWELL_SetMenuItemText() orelse return;
    func(menu, idx, text);
}

/// Set menu item text by position using SetMenuItemInfo (proven SWS approach).
/// This works for both regular items and submenu items, unlike SWELL_SetMenuItemText.
pub fn setMenuItemTextByPos(menu: HMENU, pos: c_int, text: [*:0]u8) void {
    if (comptime !is_swell_platform) {
        _ = .{ menu, pos, text };
        return;
    }
    const func = zig_swell_get_SetMenuItemInfo() orelse return;
    var mi = MenuItemInfo{
        .fMask = MIIM_TYPE,
        .fType = MF_STRING,
        .dwTypeData = text,
    };
    _ = func(menu, pos, 1, &mi); // byPos=true
}
