"""REAPER's windows on a Windows desktop, for reamo_client on the Windows
runner (windows/boot.ps1): list them, press keys in them, click their
buttons, and screenshot the screen. Stdlib only (ctypes, zlib).

The test runs in the same desktop session as REAPER (a scheduled task in
the logged-in session), so these see and drive the windows a user would.
"""

import ctypes
import os
import struct
import zlib
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

# Screenshots in physical pixels, whatever the display scaling.
user32.SetProcessDPIAware()

WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumWindows.argtypes = [WNDENUMPROC, wintypes.LPARAM]
user32.EnumChildWindows.argtypes = [wintypes.HWND, WNDENUMPROC, wintypes.LPARAM]
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.SendMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.SendMessageW.restype = wintypes.LPARAM
user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.SetForegroundWindow.argtypes = [wintypes.HWND]
user32.GetDlgCtrlID.argtypes = [wintypes.HWND]
user32.GetDC.argtypes = [wintypes.HWND]
user32.GetDC.restype = wintypes.HDC
user32.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
gdi32.CreateCompatibleDC.argtypes = [wintypes.HDC]
gdi32.CreateCompatibleDC.restype = wintypes.HDC
gdi32.CreateCompatibleBitmap.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int]
gdi32.CreateCompatibleBitmap.restype = wintypes.HBITMAP
gdi32.SelectObject.argtypes = [wintypes.HDC, wintypes.HGDIOBJ]
gdi32.SelectObject.restype = wintypes.HGDIOBJ
gdi32.BitBlt.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                         wintypes.HDC, ctypes.c_int, ctypes.c_int, wintypes.DWORD]
gdi32.GetDIBits.argtypes = [wintypes.HDC, wintypes.HBITMAP, wintypes.UINT, wintypes.UINT,
                            ctypes.c_void_p, ctypes.c_void_p, wintypes.UINT]
gdi32.DeleteObject.argtypes = [wintypes.HGDIOBJ]
gdi32.DeleteDC.argtypes = [wintypes.HDC]
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
                                                ctypes.POINTER(wintypes.DWORD)]
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]

WM_COMMAND = 0x0111
BM_CLICK = 0x00F5
DM_GETDEFID = 0x0400
DC_HASDEFID = 0x534B
IDOK, IDCANCEL = 1, 2
BN_CLICKED = 0
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
DIALOG_CLASS = "#32770"


WM_GETTEXT = 0x000D


def _text(hwnd):
    # WM_GETTEXT, not GetWindowText: across processes GetWindowText returns
    # a control's caption but not an edit field's contents.
    buf = ctypes.create_unicode_buffer(512)
    user32.SendMessageW(hwnd, WM_GETTEXT, len(buf), ctypes.cast(buf, ctypes.c_void_p).value)
    return buf.value


def _class(hwnd):
    buf = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, buf, len(buf))
    return buf.value


_exe_by_pid = {}


def _exe(hwnd):
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    if pid.value not in _exe_by_pid:
        name = ""
        h = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
        if h:
            buf = ctypes.create_unicode_buffer(1024)
            n = wintypes.DWORD(len(buf))
            if kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)):
                name = os.path.basename(buf.value).lower()
            kernel32.CloseHandle(h)
        _exe_by_pid[pid.value] = name
    return _exe_by_pid[pid.value]


def visible_windows():
    """[(hwnd, title)] of REAPER's visible, titled top-level windows. Other
    programs' windows (the taskbar, Explorer) are left out, as the Linux
    harness's display has nothing but REAPER on it."""
    out = []

    def each(hwnd, _):
        if user32.IsWindowVisible(hwnd):
            title = _text(hwnd)
            if title and _exe(hwnd) == "reaper.exe":
                out.append((hwnd, title))
        return True

    user32.EnumWindows(WNDENUMPROC(each), 0)
    return out


def all_visible_windows():
    """[(hwnd, title, exe)] of every visible, titled top-level window, for
    diagnosing what else is on the screen (a Windows prompt, say)."""
    out = []

    def each(hwnd, _):
        if user32.IsWindowVisible(hwnd):
            title = _text(hwnd)
            if title:
                out.append((hwnd, title, _exe(hwnd)))
        return True

    user32.EnumWindows(WNDENUMPROC(each), 0)
    return out


WM_CLOSE = 0x0010


def close_explorer_windows(path_fragment):
    """Close Explorer windows whose title shows a path containing
    `path_fragment`: an earlier run's Open Log Folder leaves them open."""
    for hwnd, title, exe in all_visible_windows():
        if exe == "explorer.exe" and path_fragment.lower() in title.lower():
            user32.PostMessageW(hwnd, WM_CLOSE, 0, 0)


def _children(hwnd):
    out = []

    def each(child, _):
        out.append(child)
        return True

    user32.EnumChildWindows(hwnd, WNDENUMPROC(each), 0)
    return out


def describe(hwnd):
    """A window's title and the text of its labels, fields and buttons: what
    a dialog says, for a report from a run that got stuck on one."""
    parts = [_text(hwnd)]
    for child in _children(hwnd):
        if _class(child).lower() in ("static", "edit", "button", "richedit20w", "richedit50w"):
            text = _text(child).strip()
            if text:
                parts.append(text.replace("\r", " ").replace("\n", " "))
    return " / ".join(parts)


def click_button(hwnd, text):
    """Click the button in `hwnd` whose label contains `text` (ignoring case
    and & accelerators), as a user would."""
    want = text.lower()
    for child in _children(hwnd):
        if _class(child).lower() == "button" and want in _text(child).replace("&", "").lower():
            user32.PostMessageW(child, BM_CLICK, 0, 0)
            return
    labels = [_text(c) for c in _children(hwnd) if _class(c).lower() == "button"]
    raise LookupError(f"no button like {text!r} in {_text(hwnd)!r}; buttons: {labels}")


def _command(hwnd, control_id):
    user32.PostMessageW(hwnd, WM_COMMAND, (BN_CLICKED << 16) | control_id, 0)


GWL_STYLE = -16
BS_TYPEMASK, BS_DEFPUSHBUTTON = 0x0F, 0x01
user32.GetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int]


def _click_default_button(hwnd):
    """Click the button Return would: the one drawn as the default. Its ID
    can't be relied on: a message box with only OK gives that button
    IDCANCEL (2) while DM_GETDEFID still reports IDOK (1)."""
    buttons = [c for c in _children(hwnd) if _class(c).lower() == "button"]
    for b in buttons:
        if user32.GetWindowLongW(b, GWL_STYLE) & BS_TYPEMASK == BS_DEFPUSHBUTTON:
            user32.PostMessageW(b, BM_CLICK, 0, 0)
            return
    res = user32.SendMessageW(hwnd, DM_GETDEFID, 0, 0)
    if (res >> 16) & 0xFFFF == DC_HASDEFID:
        for b in buttons:
            if user32.GetDlgCtrlID(b) == res & 0xFFFF:
                user32.PostMessageW(b, BM_CLICK, 0, 0)
                return
    if len(buttons) == 1:
        user32.PostMessageW(buttons[0], BM_CLICK, 0, 0)
        return
    _command(hwnd, IDOK)


# xdotool key names the scenarios use, as virtual-key codes.
_VK = {"return": 0x0D, "escape": 0x1B, "space": 0x20, "tab": 0x09, "backspace": 0x08,
       "delete": 0x2E, "up": 0x26, "down": 0x28, "left": 0x25, "right": 0x27,
       "home": 0x24, "end": 0x23, "ctrl": 0x11, "control": 0x11, "shift": 0x10,
       "alt": 0x12, "super": 0x5B}
for _i in range(1, 13):
    _VK[f"f{_i}"] = 0x6F + _i


def _vk(name):
    key = name.lower()
    if key in _VK:
        return _VK[key]
    if len(key) == 1 and key.isalnum():
        return ord(key.upper())
    raise ValueError(f"no virtual key for {name!r}")


INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002


class _KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class _INPUT(ctypes.Structure):
    class _U(ctypes.Union):
        _fields_ = [("ki", _KEYBDINPUT), ("pad", ctypes.c_byte * 32)]
    _anonymous_ = ("u",)
    _fields_ = [("type", wintypes.DWORD), ("u", _U)]


def _send_keys(vks):
    """Press `vks` in order, then release them in reverse (a chord)."""
    events = [(vk, 0) for vk in vks] + [(vk, KEYEVENTF_KEYUP) for vk in reversed(vks)]
    arr = (_INPUT * len(events))()
    for i, (vk, flags) in enumerate(events):
        arr[i].type = INPUT_KEYBOARD
        arr[i].ki = _KEYBDINPUT(vk, 0, flags, 0, 0)
    user32.SendInput(len(events), arr, ctypes.sizeof(_INPUT))


def press_window(hwnd, *keys):
    """Send xdotool-style keys ("Return", "Escape", "ctrl+s") to a window.
    In a dialog, Return and Escape are what they mean to a user: the default
    button and Cancel, pressed by message, which needs no focus. Anything
    else is typed into the window, which is brought to the front first; once
    something has been typed, Return and Escape are typed too, as typed keys
    arrive through the input queue and a message would overtake them (OK
    before the new value is in its field)."""
    is_dialog = _class(hwnd) == DIALOG_CLASS
    typed = False
    for key in keys:
        name = key.lower()
        if is_dialog and not typed and name == "return":
            _click_default_button(hwnd)
        elif is_dialog and not typed and name == "escape":
            _command(hwnd, IDCANCEL)
        else:
            user32.SetForegroundWindow(hwnd)
            _send_keys([_vk(part) for part in key.split("+")])
            typed = True


# --- screenshot ------------------------------------------------------------

SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN = 76, 77, 78, 79
SRCCOPY, CAPTUREBLT = 0x00CC0020, 0x40000000


class _BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
                ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD),
                ("biCompression", wintypes.DWORD), ("biSizeImage", wintypes.DWORD),
                ("biXPelsPerMeter", wintypes.LONG), ("biYPelsPerMeter", wintypes.LONG),
                ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD)]


def _png(width, height, rows):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))


def screenshot(path):
    """Save every monitor, as the user sees them, to `path` as a PNG."""
    x, y = user32.GetSystemMetrics(SM_XVIRTUALSCREEN), user32.GetSystemMetrics(SM_YVIRTUALSCREEN)
    w, h = user32.GetSystemMetrics(SM_CXVIRTUALSCREEN), user32.GetSystemMetrics(SM_CYVIRTUALSCREEN)
    screen = user32.GetDC(None)
    mem = gdi32.CreateCompatibleDC(screen)
    bmp = gdi32.CreateCompatibleBitmap(screen, w, h)
    old = gdi32.SelectObject(mem, bmp)
    try:
        if not gdi32.BitBlt(mem, 0, 0, w, h, screen, x, y, SRCCOPY | CAPTUREBLT):
            raise OSError(f"BitBlt failed: {ctypes.get_last_error()}")
        info = _BITMAPINFOHEADER(ctypes.sizeof(_BITMAPINFOHEADER), w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
        bgra = ctypes.create_string_buffer(w * h * 4)
        if gdi32.GetDIBits(mem, bmp, 0, h, bgra, ctypes.byref(info), 0) != h:
            raise OSError(f"GetDIBits failed: {ctypes.get_last_error()}")
    finally:
        gdi32.SelectObject(mem, old)
        gdi32.DeleteObject(bmp)
        gdi32.DeleteDC(mem)
        user32.ReleaseDC(None, screen)
    raw = bgra.raw
    rows = bytearray()
    for row in range(h):
        line = raw[row * w * 4:(row + 1) * w * 4]
        rgb = bytearray(w * 3)
        rgb[0::3], rgb[1::3], rgb[2::3] = line[2::4], line[1::4], line[0::4]
        rows += b"\x00" + rgb
    with open(path, "wb") as f:
        f.write(_png(w, h, bytes(rows)))
    return path
