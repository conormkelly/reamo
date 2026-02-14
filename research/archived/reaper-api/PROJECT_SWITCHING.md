# REAPER C Extension API: Project Switch Detection Guide

**REAPER provides no direct callback for project tab switches.** The most reliable detection method combines a Control Surface `SetTrackListChange()` callback with timer-based polling of `EnumProjects(-1, ...)`. A critical caveat: `ReaProject*` pointers represent **project tabs**, not project files—the same pointer persists when opening a different project in the same tab.

## No native project change callback exists

REAPER's extension API lacks a direct registration pattern like `Register("projectchange", ...)`. The `plugin_register()` function supports `"hookcommand"` and `"hookcommand2"` for action hooks, but nothing specifically for project switches. Three mechanisms provide partial solutions:

**`project_config_extension_t`** registered with `"projectconfig"` fires on project load events:

```c
typedef struct project_config_extension_t {
    bool (*ProcessExtensionLine)(const char *line, ProjectStateContext *ctx, 
                                  bool isUndo, struct project_config_extension_t *reg);
    void (*SaveExtensionConfig)(ProjectStateContext *ctx, bool isUndo, 
                                 struct project_config_extension_t *reg);
    void (*BeginLoadProjectState)(bool isUndo, struct project_config_extension_t *reg);
    void *userData;
} project_config_extension_t;
```

The `BeginLoadProjectState` callback fires on project load, undo operations, and new project creation. **However, it does NOT fire when switching between already-open project tabs**—a critical limitation for your playlist engine use case.

**Control Surface** via `IReaperControlSurface` provides the most reliable tab-switch notification through `SetTrackListChange()`. SWS extension developers explicitly document this as "our ONLY notification of active project tab change." The `Run()` method (~30Hz) enables additional polling.

## Polling detection requires pointer AND path comparison

The recommended polling pattern combines `ReaProject*` pointer comparison with filename verification:

```c
static ReaProject* s_lastProject = NULL;
static char s_lastFilename[4096] = {0};

void OnTimer(void) {
    char filename[4096];
    ReaProject* currentProject = EnumProjects(-1, filename, sizeof(filename));
    
    bool projectChanged = (currentProject != s_lastProject) || 
                          (strcmp(filename, s_lastFilename) != 0);
    
    if (projectChanged) {
        s_lastProject = currentProject;
        strcpy(s_lastFilename, filename);
        OnProjectChanged(currentProject);
    }
}

// Registration
rec->Register("timer", (void*)OnTimer);
```

**Why both checks matter**: The `ReaProject*` pointer changes only when switching tabs, not when opening a different project file in the same tab. Comparing filenames catches the latter case.

## ReaProject pointer represents tabs, not project files

This is the most important gotcha: `ReaProject*` is stable per **project tab**, not per project file.

| Operation | Pointer Behavior |
|-----------|------------------|
| Open project in **new tab** | New pointer |
| Open project in **same tab** | Same pointer ⚠️ |
| "Save As" to different file | Same pointer |
| Undo/Redo operations | Same pointer |
| Project reload | Same pointer |

**Implications for your playlist engine**: You cannot use `ReaProject*` alone as a unique project identifier. When the user creates a new project or opens a different file in the same tab, your cached `ReaProject*` will still match, but your ProjExtState data will be different. Always combine pointer comparison with path verification, or use `GetProjectStateChangeCount()` to detect changes within the same tab.

## Fresh launch and no-project states

`EnumProjects(-1, NULL, 0)` **always returns a valid pointer**—REAPER maintains at least one project tab at all times, even if empty/untitled. For unsaved projects:

- `EnumProjects(-1, filename, size)` returns empty string `""` in filename buffer
- `GetProjectName(proj, buf, size)` returns empty string
- `GetProjectPathEx(proj, buf, size)` returns default project directory or empty
- `IsProjectDirty(proj)` returns non-zero if any changes exist

To detect an unsaved project:

```c
char filename[4096];
EnumProjects(-1, filename, sizeof(filename));
bool is_unsaved = (filename[0] == '\0');
```

## Project name and path function differences

**`GetProjectName(proj, buf, size)`** returns **filename only** (e.g., "MySong.rpp"). This is base REAPER API, not SWS. Recommended buffer size is **2048 characters**.

**`GetProjectPath(buf, size)`** returns **directory only**, operates on active project only (no project parameter), and has known bugs with RECORD_PATH concatenation.

**`GetProjectPathEx(proj, buf, size)`** is the preferred function—returns directory only but accepts a project parameter for querying any open tab.

**`EnumProjects(idx, projfn, size)`** returns the **full path including filename** in the `projfn` buffer—the most direct way to get complete path information.

For display purposes, combine functions:

```c
char name[256], path[2048], full_path[4096];
GetProjectName(proj, name, sizeof(name));
GetProjectPathEx(proj, path, sizeof(path));
// Or use EnumProjects directly for full path
EnumProjects(-1, full_path, sizeof(full_path));
```

## SWS extension uses Control Surface pattern

The SWS extension provides an excellent reference implementation. Their `SWSProjConfig<T>` template manages per-project state:

```cpp
template <class PTRTYPE>
class SWSProjConfig {
    WDL_PtrList<ReaProject> m_projects;
    WDL_PtrList_DOD<PTRTYPE> m_data;
    
    PTRTYPE* Get(ReaProject* pProj) {
        if (!pProj) pProj = EnumProjects(-1, NULL, 0);
        int i = m_projects.Find(pProj);
        if (i >= 0) return m_data.Get(i);
        m_projects.Add(pProj);
        return m_data.Add(new PTRTYPE);
    }
    
    void Cleanup() {
        // Remove entries for closed project tabs
        for (int i = m_projects.GetSize() - 1; i >= 0; i--) {
            ReaProject* pProj;
            int j = 0;
            while ((pProj = EnumProjects(j++, NULL, 0)))
                if (m_projects.Get(i) == pProj) break;
            if (!pProj) { m_projects.Delete(i); m_data.Delete(i, true); }
        }
    }
};
```

SWS explicitly comments in `sws_extension.cpp` that `SetTrackListChange()` is their **only notification of project tab changes**. They use `ScheduledJob` for deferred updates to handle multiple notifications during project switches.

## Recommended implementation pattern for Zig extension

For your playlist engine with in-memory state and ProjExtState persistence:

1. **Register a Control Surface** implementing `SetTrackListChange()` for immediate tab-switch notification

2. **Register a timer** for polling with combined pointer+path comparison as a safety net

3. **Track both pointer AND path**:

```c
typedef struct {
    ReaProject* project;
    char path[4096];
    int state_change_count;
} ProjectIdentity;
```

1. **On project change detection**:
   - Call `GetProjectStateChangeCount()` to get baseline
   - Clear in-memory engine state
   - Load fresh state from `GetProjExtState()`
   - Update your cached ProjectIdentity

2. **Handle NULL project parameter**: When passing to REAPER API functions, `NULL` means "current/active project"—equivalent to `EnumProjects(-1, ...)`. For multi-tab-aware code, always store and pass explicit `ReaProject*` pointers.

3. **Cleanup closed tabs periodically**: Like SWS, enumerate all open projects and remove cached state for tabs that no longer exist.

## Conclusion

Project switch detection in REAPER requires a hybrid approach: Control Surface `SetTrackListChange()` provides the fastest notification, while timer polling with path comparison catches edge cases like same-tab project changes. The critical insight is that `ReaProject*` identifies tabs rather than project files—always verify project identity using the path from `EnumProjects()`. For persistence, ProjExtState survives saves but in-memory state must be explicitly synchronized on each detected project change.
