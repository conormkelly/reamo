/*
 * SWELL Bridge Implementation
 *
 * Loads SWELL functions from REAPER at runtime.
 *
 * macOS: Uses Objective-C to get SWELLAPI_GetFunc from NSApp delegate
 * Linux: SWELL_dllMain is called by REAPER before ReaperPluginEntry
 */

#include "zig_swell_bridge.h"

#ifdef __APPLE__
#import <Cocoa/Cocoa.h>
#import <dispatch/dispatch.h>
#endif

/* Global function pointer to SWELL's API lookup function */
static void* (*SWELLAPI_GetFunc)(const char* name) = nullptr;

/* Cached function pointers */
static CreateDialogParamFn s_SWELL_CreateDialog = nullptr;
static BeginPaintFn s_BeginPaint = nullptr;
static EndPaintFn s_EndPaint = nullptr;
static StretchBltFromMemFn s_StretchBltFromMem = nullptr;
static DestroyWindowFn s_DestroyWindow = nullptr;
static SWELL_SetWindowLevelFn s_SWELL_SetWindowLevel = nullptr;
static InvalidateRectFn s_InvalidateRect = nullptr;
static ShowWindowFn s_ShowWindow = nullptr;
static SetDlgItemTextFn s_SetDlgItemText = nullptr;
static SetWindowPosFn s_SetWindowPos = nullptr;
static DefWindowProcFn s_DefWindowProc = nullptr;
static CreateSolidBrushFn s_CreateSolidBrush = nullptr;
static FillRectFn s_SWELL_FillRect = nullptr;
static DeleteObjectFn s_DeleteObject = nullptr;
static SetBkModeFn s_SetBkMode = nullptr;
static SetTextColorFn s_SetTextColor = nullptr;
static DrawTextFn s_DrawText = nullptr;
static SWELL_CreateMemContextFn s_SWELL_CreateMemContext = nullptr;
static SWELL_DeleteGfxContextFn s_SWELL_DeleteGfxContext = nullptr;
static SWELL_GetCtxFrameBufferFn s_SWELL_GetCtxFrameBuffer = nullptr;
static BitBltFn s_BitBlt = nullptr;
static SetTimerFn s_SetTimer = nullptr;
static KillTimerFn s_KillTimer = nullptr;
static GetWindowRectFn s_GetWindowRect = nullptr;
static CreatePopupMenuFn s_CreatePopupMenu = nullptr;
static DestroyMenuFn s_DestroyMenu = nullptr;
static SWELL_InsertMenuFn s_SWELL_InsertMenu = nullptr;
static GetMenuItemCountFn s_GetMenuItemCount = nullptr;
static GetSubMenuFn s_GetSubMenu = nullptr;
static GetMenuItemIDFn s_GetMenuItemID = nullptr;
static CheckMenuItemFn s_CheckMenuItem = nullptr;
static EnableMenuItemFn s_EnableMenuItem = nullptr;

#ifdef __APPLE__

/*
 * macOS: Get SWELLAPI_GetFunc from NSApp delegate
 *
 * REAPER's app delegate implements swellGetAPPAPIFunc which returns
 * the function pointer for looking up SWELL functions.
 */
bool zig_swell_init(void) {
    if (SWELLAPI_GetFunc) return true;  /* Already initialized */

    @autoreleasepool {
        id del = [NSApp delegate];
        if (del && [del respondsToSelector:@selector(swellGetAPPAPIFunc)]) {
            SWELLAPI_GetFunc = (void*(*)(const char*))[del performSelector:@selector(swellGetAPPAPIFunc)];
        }
    }

    return SWELLAPI_GetFunc != nullptr;
}

bool zig_swell_is_macos(void) {
    return true;
}

#else /* Linux */

/*
 * Linux: SWELL_dllMain is called by REAPER before ReaperPluginEntry
 *
 * REAPER's plugin loader calls this function to provide the SWELL API
 * function pointer before calling the plugin's entry point.
 */
extern "C" void SWELL_dllMain(void* hInst, void* apiFunc) {
    (void)hInst;
    SWELLAPI_GetFunc = (void*(*)(const char*))apiFunc;
}

bool zig_swell_init(void) {
    /* On Linux, SWELLAPI_GetFunc is set by SWELL_dllMain before plugin init */
    return SWELLAPI_GetFunc != nullptr;
}

bool zig_swell_is_macos(void) {
    return false;
}

#endif

/* Helper macro for lazy-loading function pointers */
#define GET_SWELL_FUNC(name, type) \
    if (!s_##name && SWELLAPI_GetFunc) { \
        s_##name = (type)SWELLAPI_GetFunc(#name); \
    } \
    return s_##name

/* Function pointer getters */

CreateDialogParamFn zig_swell_get_CreateDialogParam(void) {
    // Note: SWELL exports SWELL_CreateDialog, not CreateDialogParam
    // The CreateDialogParam macro just wraps SWELL_CreateDialog
    GET_SWELL_FUNC(SWELL_CreateDialog, CreateDialogParamFn);
}

BeginPaintFn zig_swell_get_BeginPaint(void) {
    GET_SWELL_FUNC(BeginPaint, BeginPaintFn);
}

EndPaintFn zig_swell_get_EndPaint(void) {
    GET_SWELL_FUNC(EndPaint, EndPaintFn);
}

StretchBltFromMemFn zig_swell_get_StretchBltFromMem(void) {
    GET_SWELL_FUNC(StretchBltFromMem, StretchBltFromMemFn);
}

DestroyWindowFn zig_swell_get_DestroyWindow(void) {
    GET_SWELL_FUNC(DestroyWindow, DestroyWindowFn);
}

SWELL_SetWindowLevelFn zig_swell_get_SetWindowLevel(void) {
    GET_SWELL_FUNC(SWELL_SetWindowLevel, SWELL_SetWindowLevelFn);
}

InvalidateRectFn zig_swell_get_InvalidateRect(void) {
    GET_SWELL_FUNC(InvalidateRect, InvalidateRectFn);
}

ShowWindowFn zig_swell_get_ShowWindow(void) {
    GET_SWELL_FUNC(ShowWindow, ShowWindowFn);
}

SetDlgItemTextFn zig_swell_get_SetDlgItemText(void) {
    GET_SWELL_FUNC(SetDlgItemText, SetDlgItemTextFn);
}

SetWindowPosFn zig_swell_get_SetWindowPos(void) {
    GET_SWELL_FUNC(SetWindowPos, SetWindowPosFn);
}

DefWindowProcFn zig_swell_get_DefWindowProc(void) {
    GET_SWELL_FUNC(DefWindowProc, DefWindowProcFn);
}

CreateSolidBrushFn zig_swell_get_CreateSolidBrush(void) {
    GET_SWELL_FUNC(CreateSolidBrush, CreateSolidBrushFn);
}

FillRectFn zig_swell_get_FillRect(void) {
    // SWELL remaps FillRect to SWELL_FillRect
    GET_SWELL_FUNC(SWELL_FillRect, FillRectFn);
}

DeleteObjectFn zig_swell_get_DeleteObject(void) {
    GET_SWELL_FUNC(DeleteObject, DeleteObjectFn);
}

SetBkModeFn zig_swell_get_SetBkMode(void) {
    GET_SWELL_FUNC(SetBkMode, SetBkModeFn);
}

SetTextColorFn zig_swell_get_SetTextColor(void) {
    GET_SWELL_FUNC(SetTextColor, SetTextColorFn);
}

DrawTextFn zig_swell_get_DrawText(void) {
    GET_SWELL_FUNC(DrawText, DrawTextFn);
}

SWELL_CreateMemContextFn zig_swell_get_SWELL_CreateMemContext(void) {
    GET_SWELL_FUNC(SWELL_CreateMemContext, SWELL_CreateMemContextFn);
}

SWELL_DeleteGfxContextFn zig_swell_get_SWELL_DeleteGfxContext(void) {
    GET_SWELL_FUNC(SWELL_DeleteGfxContext, SWELL_DeleteGfxContextFn);
}

SWELL_GetCtxFrameBufferFn zig_swell_get_SWELL_GetCtxFrameBuffer(void) {
    GET_SWELL_FUNC(SWELL_GetCtxFrameBuffer, SWELL_GetCtxFrameBufferFn);
}

BitBltFn zig_swell_get_BitBlt(void) {
    GET_SWELL_FUNC(BitBlt, BitBltFn);
}

SetTimerFn zig_swell_get_SetTimer(void) {
    GET_SWELL_FUNC(SetTimer, SetTimerFn);
}

KillTimerFn zig_swell_get_KillTimer(void) {
    GET_SWELL_FUNC(KillTimer, KillTimerFn);
}

GetWindowRectFn zig_swell_get_GetWindowRect(void) {
    GET_SWELL_FUNC(GetWindowRect, GetWindowRectFn);
}

/* Menu function getters */

CreatePopupMenuFn zig_swell_get_CreatePopupMenu(void) {
    GET_SWELL_FUNC(CreatePopupMenu, CreatePopupMenuFn);
}

DestroyMenuFn zig_swell_get_DestroyMenu(void) {
    GET_SWELL_FUNC(DestroyMenu, DestroyMenuFn);
}

SWELL_InsertMenuFn zig_swell_get_SWELL_InsertMenu(void) {
    GET_SWELL_FUNC(SWELL_InsertMenu, SWELL_InsertMenuFn);
}

GetMenuItemCountFn zig_swell_get_GetMenuItemCount(void) {
    GET_SWELL_FUNC(GetMenuItemCount, GetMenuItemCountFn);
}

GetSubMenuFn zig_swell_get_GetSubMenu(void) {
    GET_SWELL_FUNC(GetSubMenu, GetSubMenuFn);
}

GetMenuItemIDFn zig_swell_get_GetMenuItemID(void) {
    GET_SWELL_FUNC(GetMenuItemID, GetMenuItemIDFn);
}

CheckMenuItemFn zig_swell_get_CheckMenuItem(void) {
    GET_SWELL_FUNC(CheckMenuItem, CheckMenuItemFn);
}

EnableMenuItemFn zig_swell_get_EnableMenuItem(void) {
    GET_SWELL_FUNC(EnableMenuItem, EnableMenuItemFn);
}

// =============================================================================
// Native Fast Timer Implementation
// macOS: Uses dispatch_source for precise timing with main thread callback
// Linux: Falls back to SWELL SetTimer (if available)
// =============================================================================

#ifdef __APPLE__

static dispatch_source_t s_fast_timer = nullptr;
static FastTimerCallback s_fast_timer_callback = nullptr;

bool zig_fast_timer_start(unsigned int interval_ms, FastTimerCallback callback) {
    if (s_fast_timer) return true;  // Already running
    if (!callback) return false;

    s_fast_timer_callback = callback;

    // Create timer on main queue (main thread)
    s_fast_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!s_fast_timer) return false;

    // Set interval (converting ms to nanoseconds)
    // Use 0 leeway for strictest timing (no coalescing with other timers)
    uint64_t interval_ns = (uint64_t)interval_ms * NSEC_PER_MSEC;
    dispatch_source_set_timer(s_fast_timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval_ns, 0);

    // Set event handler
    dispatch_source_set_event_handler(s_fast_timer, ^{
        if (s_fast_timer_callback) {
            s_fast_timer_callback();
        }
    });

    dispatch_resume(s_fast_timer);
    return true;
}

void zig_fast_timer_stop(void) {
    if (s_fast_timer) {
        dispatch_source_cancel(s_fast_timer);
        s_fast_timer = nullptr;
    }
    s_fast_timer_callback = nullptr;
}

bool zig_fast_timer_is_running(void) {
    return s_fast_timer != nullptr;
}

#else /* Linux */

// Linux: Use SWELL SetTimer with WM_TIMER if available
// For now, return false to use fallback 30Hz timer
static bool s_linux_timer_running = false;
static FastTimerCallback s_fast_timer_callback = nullptr;

bool zig_fast_timer_start(unsigned int interval_ms, FastTimerCallback callback) {
    (void)interval_ms;
    (void)callback;
    // TODO: Implement Linux timer via SWELL + hidden window + WM_TIMER
    // For now, fall back to 30Hz REAPER timer
    return false;
}

void zig_fast_timer_stop(void) {
    s_linux_timer_running = false;
    s_fast_timer_callback = nullptr;
}

bool zig_fast_timer_is_running(void) {
    return s_linux_timer_running;
}

#endif
