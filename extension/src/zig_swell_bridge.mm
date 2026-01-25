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
