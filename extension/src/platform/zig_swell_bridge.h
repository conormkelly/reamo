/*
 * SWELL Bridge for Zig
 *
 * Provides access to SWELL (Simple Windows Emulation Layer) functions
 * from Zig code. SWELL is provided by REAPER on macOS/Linux.
 *
 * On Windows, this bridge is not used - Zig calls Win32 APIs directly.
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque types matching SWELL */
typedef void* SwellHWND;
typedef void* SwellHDC;

/* PAINTSTRUCT - sized to match SWELL's definition */
typedef struct {
    SwellHDC hdc;
    int fErase;
    int rcPaint[4];  /* RECT as 4 ints: left, top, right, bottom */
    int fRestore;
    int fIncUpdate;
    char rgbReserved[32];
} SwellPAINTSTRUCT;

/* Dialog procedure type */
typedef intptr_t (*SwellDlgProc)(SwellHWND, unsigned int, uintptr_t, intptr_t);

/* Function pointer types for SWELL functions */
typedef SwellHWND (*CreateDialogParamFn)(void* hInst, const char* resid, SwellHWND parent, SwellDlgProc dlgproc, intptr_t param);
typedef SwellHDC (*BeginPaintFn)(SwellHWND hwnd, SwellPAINTSTRUCT* ps);
typedef int (*EndPaintFn)(SwellHWND hwnd, SwellPAINTSTRUCT* ps);
typedef void (*StretchBltFromMemFn)(SwellHDC hdcOut, int x, int y, int w, int h, const void* bits, int srcw, int srch, int srcspan);
typedef void (*DestroyWindowFn)(SwellHWND hwnd);
typedef int (*SWELL_SetWindowLevelFn)(SwellHWND hwnd, int level);
typedef void (*InvalidateRectFn)(SwellHWND hwnd, void* rect, int erase);
typedef void (*ShowWindowFn)(SwellHWND hwnd, int cmd);
typedef int (*SetDlgItemTextFn)(SwellHWND hwnd, int idx, const char* text);
typedef int (*SetWindowPosFn)(SwellHWND hwnd, SwellHWND insertAfter, int x, int y, int cx, int cy, unsigned int flags);
typedef intptr_t (*DefWindowProcFn)(SwellHWND hwnd, unsigned int msg, uintptr_t wParam, intptr_t lParam);

/* Additional drawing functions for testing */
typedef void* (*CreateSolidBrushFn)(int color);
typedef int (*FillRectFn)(SwellHDC hdc, const int* rect, void* brush);
typedef void (*DeleteObjectFn)(void* obj);
typedef int (*SetBkModeFn)(SwellHDC hdc, int mode);
typedef unsigned int (*SetTextColorFn)(SwellHDC hdc, unsigned int color);
typedef int (*DrawTextFn)(SwellHDC hdc, const char* text, int len, int* rect, unsigned int format);

/* Memory DC functions for bitmap blitting */
typedef SwellHDC (*SWELL_CreateMemContextFn)(SwellHDC hdc, int w, int h);
typedef void (*SWELL_DeleteGfxContextFn)(SwellHDC ctx);
typedef void* (*SWELL_GetCtxFrameBufferFn)(SwellHDC ctx);
typedef void (*BitBltFn)(SwellHDC hdcOut, int x, int y, int w, int h, SwellHDC hdcIn, int xin, int yin, int mode);

/* Menu functions */
typedef void* SwellHMENU;
typedef void* (*CreatePopupMenuFn)(void);
typedef void (*DestroyMenuFn)(SwellHMENU menu);
typedef void (*SWELL_InsertMenuFn)(SwellHMENU menu, int pos, unsigned int flags, uintptr_t idx, const char* text);
typedef int (*GetMenuItemCountFn)(SwellHMENU menu);
typedef SwellHMENU (*GetSubMenuFn)(SwellHMENU menu, int pos);
typedef int (*GetMenuItemIDFn)(SwellHMENU menu, int pos);
typedef bool (*CheckMenuItemFn)(SwellHMENU menu, int idx, int chk);
typedef bool (*EnableMenuItemFn)(SwellHMENU menu, int idx, int en);

/* Timer functions (SWELL - may not be available) */
typedef void (*SwellTIMERPROC)(SwellHWND hwnd, unsigned int msg, uintptr_t id, unsigned int time);
typedef uintptr_t (*SetTimerFn)(SwellHWND hwnd, uintptr_t nIDEvent, unsigned int uElapse, SwellTIMERPROC lpTimerFunc);
typedef int (*KillTimerFn)(SwellHWND hwnd, uintptr_t uIDEvent);

/* Native fast timer (macOS: dispatch_source, Linux: SWELL SetTimer) */
typedef void (*FastTimerCallback)(void);
bool zig_fast_timer_start(unsigned int interval_ms, FastTimerCallback callback);
void zig_fast_timer_stop(void);
bool zig_fast_timer_is_running(void);

/*
 * Initialize the SWELL bridge.
 * Must be called before any other bridge functions.
 * Returns true if SWELL functions were loaded successfully.
 *
 * On macOS: Obtains SWELLAPI_GetFunc from NSApp delegate
 * On Linux: Uses SWELL_dllMain (called by REAPER before plugin entry)
 */
bool zig_swell_init(void);

/*
 * Check if running on macOS (for SetWindowLevel calls)
 */
bool zig_swell_is_macos(void);

/* Function pointer getters - valid after zig_swell_init() returns true */
CreateDialogParamFn zig_swell_get_CreateDialogParam(void);
BeginPaintFn zig_swell_get_BeginPaint(void);
EndPaintFn zig_swell_get_EndPaint(void);
StretchBltFromMemFn zig_swell_get_StretchBltFromMem(void);
DestroyWindowFn zig_swell_get_DestroyWindow(void);
SWELL_SetWindowLevelFn zig_swell_get_SetWindowLevel(void);
InvalidateRectFn zig_swell_get_InvalidateRect(void);
ShowWindowFn zig_swell_get_ShowWindow(void);
SetDlgItemTextFn zig_swell_get_SetDlgItemText(void);
SetWindowPosFn zig_swell_get_SetWindowPos(void);
DefWindowProcFn zig_swell_get_DefWindowProc(void);
CreateSolidBrushFn zig_swell_get_CreateSolidBrush(void);
FillRectFn zig_swell_get_FillRect(void);
DeleteObjectFn zig_swell_get_DeleteObject(void);
SetBkModeFn zig_swell_get_SetBkMode(void);
SetTextColorFn zig_swell_get_SetTextColor(void);
DrawTextFn zig_swell_get_DrawText(void);
SWELL_CreateMemContextFn zig_swell_get_SWELL_CreateMemContext(void);
SWELL_DeleteGfxContextFn zig_swell_get_SWELL_DeleteGfxContext(void);
SWELL_GetCtxFrameBufferFn zig_swell_get_SWELL_GetCtxFrameBuffer(void);
BitBltFn zig_swell_get_BitBlt(void);
SetTimerFn zig_swell_get_SetTimer(void);
KillTimerFn zig_swell_get_KillTimer(void);
CreatePopupMenuFn zig_swell_get_CreatePopupMenu(void);
DestroyMenuFn zig_swell_get_DestroyMenu(void);
SWELL_InsertMenuFn zig_swell_get_SWELL_InsertMenu(void);
GetMenuItemCountFn zig_swell_get_GetMenuItemCount(void);
GetSubMenuFn zig_swell_get_GetSubMenu(void);
GetMenuItemIDFn zig_swell_get_GetMenuItemID(void);
CheckMenuItemFn zig_swell_get_CheckMenuItem(void);
EnableMenuItemFn zig_swell_get_EnableMenuItem(void);

#ifdef __cplusplus
}
#endif
