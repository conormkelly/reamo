// C++ shim implementation for IReaperControlSurface
// Forwards all virtual calls to Zig-implemented function pointers

#include "zig_control_surface.h"
#include "reaper_csurf.h"

class ZigControlSurface : public IReaperControlSurface {
    ZigCSurfCallbacks m_cb;
public:
    ZigControlSurface(const ZigCSurfCallbacks* cb) : m_cb(*cb) {}
    virtual ~ZigControlSurface() {}

    const char* GetTypeString() override {
        if (m_cb.get_type_string) return m_cb.get_type_string(m_cb.user_context);
        return "zig_ws";
    }

    const char* GetDescString() override {
        if (m_cb.get_desc_string) return m_cb.get_desc_string(m_cb.user_context);
        return "Zig WebSocket Surface";
    }

    const char* GetConfigString() override {
        return "";  // No config for this surface
    }

    void Run() override {
        if (m_cb.run) m_cb.run(m_cb.user_context);
    }

    void SetPlayState(bool play, bool pause, bool rec) override {
        if (m_cb.set_play_state) m_cb.set_play_state(m_cb.user_context, play, pause, rec);
    }

    void SetRepeatState(bool rep) override {
        if (m_cb.set_repeat_state) m_cb.set_repeat_state(m_cb.user_context, rep);
    }

    void SetTrackListChange() override {
        if (m_cb.set_track_list_change) m_cb.set_track_list_change(m_cb.user_context);
    }

    void SetSurfaceVolume(MediaTrack* track, double vol) override {
        if (m_cb.set_surface_volume) m_cb.set_surface_volume(m_cb.user_context, track, vol);
    }

    void SetSurfacePan(MediaTrack* track, double pan) override {
        if (m_cb.set_surface_pan) m_cb.set_surface_pan(m_cb.user_context, track, pan);
    }

    void SetSurfaceMute(MediaTrack* track, bool mute) override {
        if (m_cb.set_surface_mute) m_cb.set_surface_mute(m_cb.user_context, track, mute);
    }

    void SetSurfaceSolo(MediaTrack* track, bool solo) override {
        if (m_cb.set_surface_solo) m_cb.set_surface_solo(m_cb.user_context, track, solo);
    }

    void SetSurfaceSelected(MediaTrack* track, bool sel) override {
        if (m_cb.set_surface_selected) m_cb.set_surface_selected(m_cb.user_context, track, sel);
    }

    void SetSurfaceRecArm(MediaTrack* track, bool arm) override {
        if (m_cb.set_surface_rec_arm) m_cb.set_surface_rec_arm(m_cb.user_context, track, arm);
    }

    void OnTrackSelection(MediaTrack* track) override {
        if (m_cb.on_track_selection) m_cb.on_track_selection(m_cb.user_context, track);
    }

    void SetAutoMode(int mode) override {
        if (m_cb.set_auto_mode) m_cb.set_auto_mode(m_cb.user_context, mode);
    }

    int Extended(int call, void* p1, void* p2, void* p3) override {
        if (m_cb.extended) return m_cb.extended(m_cb.user_context, call, p1, p2, p3);
        return 0;
    }
};

// C API implementation
extern "C" {

ZigCSurfHandle zig_csurf_create(const ZigCSurfCallbacks* cb) {
    return new ZigControlSurface(cb);
}

void zig_csurf_destroy(ZigCSurfHandle handle) {
    delete static_cast<ZigControlSurface*>(handle);
}

bool zig_csurf_register(ZigCSurfHandle handle, PluginRegisterFn plugin_register) {
    auto reg = reinterpret_cast<int(*)(const char*, void*)>(plugin_register);
    return reg("csurf_inst", handle) != 0;
}

void zig_csurf_unregister(ZigCSurfHandle handle, PluginRegisterFn plugin_register) {
    auto reg = reinterpret_cast<int(*)(const char*, void*)>(plugin_register);
    reg("-csurf_inst", handle);
}

}  // extern "C"
