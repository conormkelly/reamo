/*
 * SWELL Modstub Wrapper
 *
 * Compiles WDL's swell-modstub-generic.cpp logic for REAPER plugin use on Linux.
 * Provides SWELL_dllMain + doinit() which resolves all SWELL function pointers
 * at plugin load time.
 *
 * We need this wrapper because the upstream modstub includes swell.h inside
 * extern "C" { }, and swell-types.h pulls in <cstddef> which contains C++
 * templates incompatible with extern "C" linkage under Zig's Clang.
 */

#ifdef SWELL_PROVIDED_BY_APP

/* Include swell.h with proper C++ linkage first */
#define SWELL_API_DEFPARM(x)
#define SWELL_API_DEFINE(ret,func,parms) ret (*func) parms ;
#include "swell.h"

/* Resource list heads (declared in swell-types.h, defined here) */
struct SWELL_CursorResourceIndex *SWELL_curmodule_cursorresource_head;
struct SWELL_DialogResourceIndex *SWELL_curmodule_dialogresource_head;
struct SWELL_MenuResourceIndex *SWELL_curmodule_menuresource_head;

/* Build api_tab from swell-functions.h for bulk resolution */
static struct {
    const char *name;
    void **func;
} api_tab[] = {
#undef _WDL_SWELL_H_API_DEFINED_
#undef SWELL_API_DEFINE
#define SWELL_API_DEFINE(ret, func, parms) {#func, (void **)&func },
#include "swell-functions.h"
};

static int dummyFunc() { return 0; }

/* Saved GetFunc pointer — exposed to bridge via zig_swell_modstub_getfunc() */
static void *(*s_saved_GetFunc)(const char *name) = nullptr;

static int doinit(void *(*GetFunc)(const char *name))
{
    int errcnt = 0;
    for (int x = 0; x < (int)(sizeof(api_tab)/sizeof(api_tab[0])); x++) {
        *api_tab[x].func = GetFunc(api_tab[x].name);
        if (!*api_tab[x].func) {
            errcnt++;
            *api_tab[x].func = (void*)&dummyFunc;
        }
    }
    return errcnt;
}

extern "C" __attribute__ ((visibility ("default")))
int SWELL_dllMain(HINSTANCE hInst, DWORD callMode, LPVOID _GetFunc)
{
    (void)hInst;
    if (callMode == DLL_PROCESS_ATTACH) {
        if (!_GetFunc) return 0;
        s_saved_GetFunc = (void *(*)(const char *))_GetFunc;
        doinit(s_saved_GetFunc);
    }
    return 1;
}

/*
 * Accessor for the bridge — returns SWELLAPI_GetFunc saved during SWELL_dllMain.
 * The bridge uses this for lazy function resolution, same as the macOS path.
 */
extern "C" __attribute__ ((visibility ("default")))
void *zig_swell_modstub_getfunc(const char *name)
{
    return s_saved_GetFunc ? s_saved_GetFunc(name) : nullptr;
}

#endif // SWELL_PROVIDED_BY_APP
