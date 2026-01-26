// C++ shim for IReaperControlSurface - enables Zig to receive push callbacks
//
// Zig cannot directly implement C++ virtual classes due to vtable incompatibility.
// This shim inherits from IReaperControlSurface and forwards all virtual calls
// through C function pointers that Zig can implement.
//
// See: research/ZIG_CONTROL_SURFACE.md

#ifndef ZIG_CONTROL_SURFACE_H
#define ZIG_CONTROL_SURFACE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stdint.h>

// Opaque handles
typedef void* ZigCSurfHandle;
typedef void* MediaTrackHandle;
typedef void* PluginRegisterFn;

// Callback function pointer types
typedef const char* (*ZigGetStringCb)(void* ctx);
typedef void (*ZigRunCb)(void* ctx);
typedef void (*ZigSetPlayStateCb)(void* ctx, bool play, bool pause, bool rec);
typedef void (*ZigSetRepeatStateCb)(void* ctx, bool rep);
typedef void (*ZigSetTrackListChangeCb)(void* ctx);
typedef void (*ZigSetSurfaceVolumeCb)(void* ctx, MediaTrackHandle track, double vol);
typedef void (*ZigSetSurfacePanCb)(void* ctx, MediaTrackHandle track, double pan);
typedef void (*ZigSetSurfaceMuteCb)(void* ctx, MediaTrackHandle track, bool mute);
typedef void (*ZigSetSurfaceSoloCb)(void* ctx, MediaTrackHandle track, bool solo);
typedef void (*ZigSetSurfaceSelectedCb)(void* ctx, MediaTrackHandle track, bool sel);
typedef void (*ZigSetSurfaceRecArmCb)(void* ctx, MediaTrackHandle track, bool arm);
typedef void (*ZigOnTrackSelectionCb)(void* ctx, MediaTrackHandle track);
typedef void (*ZigSetAutoModeCb)(void* ctx, int mode);
typedef int  (*ZigExtendedCb)(void* ctx, int call, void* p1, void* p2, void* p3);
typedef void (*ZigResetCachedVolPanStatesCb)(void* ctx);

// Callback struct - Zig populates this and passes to zig_csurf_create
typedef struct {
    void* user_context;  // Passed to all callbacks (your Zig struct pointer)

    ZigGetStringCb      get_type_string;
    ZigGetStringCb      get_desc_string;
    ZigRunCb            run;
    ZigSetPlayStateCb   set_play_state;
    ZigSetRepeatStateCb set_repeat_state;
    ZigSetTrackListChangeCb set_track_list_change;
    ZigSetSurfaceVolumeCb   set_surface_volume;
    ZigSetSurfacePanCb      set_surface_pan;
    ZigSetSurfaceMuteCb     set_surface_mute;
    ZigSetSurfaceSoloCb     set_surface_solo;
    ZigSetSurfaceSelectedCb set_surface_selected;
    ZigSetSurfaceRecArmCb   set_surface_rec_arm;
    ZigOnTrackSelectionCb   on_track_selection;
    ZigSetAutoModeCb        set_auto_mode;
    ZigExtendedCb           extended;
    ZigResetCachedVolPanStatesCb reset_cached_vol_pan_states;
} ZigCSurfCallbacks;

// C API for Zig
ZigCSurfHandle zig_csurf_create(const ZigCSurfCallbacks* callbacks);
void zig_csurf_destroy(ZigCSurfHandle handle);
bool zig_csurf_register(ZigCSurfHandle handle, PluginRegisterFn plugin_register);
void zig_csurf_unregister(ZigCSurfHandle handle, PluginRegisterFn plugin_register);

#ifdef __cplusplus
}
#endif
#endif // ZIG_CONTROL_SURFACE_H
