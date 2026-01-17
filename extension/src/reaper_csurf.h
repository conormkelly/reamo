// Minimal IReaperControlSurface definition for Zig shim
// Extracted from REAPER SDK reaper_plugin.h to avoid SWELL dependency

#ifndef REAPER_CSURF_H
#define REAPER_CSURF_H

// Forward declarations - we only need opaque pointers
class MediaTrack;

// IReaperControlSurface interface
// REAPER calls these virtual methods as push notifications when state changes
class IReaperControlSurface {
public:
    IReaperControlSurface() {}
    virtual ~IReaperControlSurface() {}

    // Identity (not callbacks - configuration methods)
    virtual const char *GetTypeString() = 0;  // Unique ID (A-Z, 0-9)
    virtual const char *GetDescString() = 0;  // Human-readable name
    virtual const char *GetConfigString() = 0; // Saved configuration

    virtual void CloseNoReset() {}

    // PERIODIC CALLBACK - called ~30Hz for polling
    virtual void Run() {}

    // TRANSPORT CALLBACKS
    virtual void SetPlayState(bool play, bool pause, bool rec) {}
    virtual void SetRepeatState(bool rep) {}

    // TRACK LIST CALLBACK - fires on add/remove/reorder
    virtual void SetTrackListChange() {}

    // PER-TRACK STATE CALLBACKS
    virtual void SetSurfaceVolume(MediaTrack *trackid, double volume) {}
    virtual void SetSurfacePan(MediaTrack *trackid, double pan) {}
    virtual void SetSurfaceMute(MediaTrack *trackid, bool mute) {}
    virtual void SetSurfaceSelected(MediaTrack *trackid, bool selected) {}
    virtual void SetSurfaceSolo(MediaTrack *trackid, bool solo) {}
    virtual void SetSurfaceRecArm(MediaTrack *trackid, bool recarm) {}
    virtual void SetTrackTitle(MediaTrack *trackid, const char *title) {}

    // STATE QUERIES (REAPER asks surface)
    virtual bool GetTouchState(MediaTrack *trackid, int isPan) { return false; }

    // AUTOMATION AND SELECTION
    virtual void SetAutoMode(int mode) {}
    virtual void OnTrackSelection(MediaTrack *trackid) {}

    virtual bool IsKeyDown(int key) { return false; }

    // CACHE MANAGEMENT
    virtual void ResetCachedVolPanStates() {}

    // EXTENDED NOTIFICATIONS - handles many additional events
    virtual int Extended(int call, void *parm1, void *parm2, void *parm3) { return 0; }
};

// CSURF_EXT_* notification codes for Extended()
#define CSURF_EXT_RESET 0x0001FFFF
#define CSURF_EXT_SETINPUTMONITOR 0x00010001
#define CSURF_EXT_SETMETRONOME 0x00010002
#define CSURF_EXT_SETAUTORECARM 0x00010003
#define CSURF_EXT_SETRECMODE 0x00010004
#define CSURF_EXT_SETSENDVOLUME 0x00010005
#define CSURF_EXT_SETSENDPAN 0x00010006
#define CSURF_EXT_SETFXENABLED 0x00010007
#define CSURF_EXT_SETFXPARAM 0x00010008
#define CSURF_EXT_SETFXPARAM_RECFX 0x00010018
#define CSURF_EXT_SETBPMANDPLAYRATE 0x00010009
#define CSURF_EXT_SETLASTTOUCHEDFX 0x0001000A
#define CSURF_EXT_SETFOCUSEDFX 0x0001000B
#define CSURF_EXT_SETLASTTOUCHEDTRACK 0x0001000C
#define CSURF_EXT_SETMIXERSCROLL 0x0001000D
#define CSURF_EXT_SETPAN_EX 0x0001000E
#define CSURF_EXT_SETRECVVOLUME 0x00010010
#define CSURF_EXT_SETRECVPAN 0x00010011
#define CSURF_EXT_SETFXOPEN 0x00010012
#define CSURF_EXT_SETFXCHANGE 0x00010013
#define CSURF_EXT_SETPROJECTMARKERCHANGE 0x00010014
#define CSURF_EXT_TRACKFX_PRESET_CHANGED 0x00010015

#endif // REAPER_CSURF_H
