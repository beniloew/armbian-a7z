#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

typedef int OMX_ERRORTYPE;
typedef void* OMX_HANDLETYPE;
typedef void* OMX_PTR;
typedef unsigned int OMX_U32;
typedef unsigned char OMX_U8;

#define OMX_ErrorNone 0
#define OMX_ErrorComponentNotFound 0x80001018
#define OMX_ErrorInsufficientResources 0x80001000
#define OMX_ErrorNoMore 0x80001018

typedef struct OMX_CALLBACKTYPE {
    void* EventHandler;
    void* EmptyBufferDone;
    void* FillBufferDone;
} OMX_CALLBACKTYPE;

static void *real_core = NULL;
static OMX_ERRORTYPE (*real_OMX_Init)(void) = NULL;
static OMX_ERRORTYPE (*real_OMX_Deinit)(void) = NULL;
static OMX_ERRORTYPE (*real_OMX_GetHandle)(OMX_HANDLETYPE*, char*, OMX_PTR, OMX_CALLBACKTYPE*) = NULL;
static OMX_ERRORTYPE (*real_OMX_FreeHandle)(OMX_HANDLETYPE) = NULL;
static OMX_ERRORTYPE (*real_OMX_ComponentNameEnum)(char*, OMX_U32, OMX_U32) = NULL;
static OMX_ERRORTYPE (*real_OMX_GetComponentsOfRole)(char*, OMX_U32*, OMX_U8**) = NULL;
static OMX_ERRORTYPE (*real_OMX_GetRolesOfComponent)(char*, OMX_U32*, OMX_U8**) = NULL;

static OMX_ERRORTYPE (*core_AwOmxComponentInit)(OMX_HANDLETYPE, char*) = NULL;
static OMX_ERRORTYPE (*core_AwOmxComponentSetCallbacks)(OMX_HANDLETYPE, OMX_CALLBACKTYPE*, OMX_PTR) = NULL;
static OMX_ERRORTYPE (*core_AwOmxComponentDeinit)(OMX_HANDLETYPE) = NULL;

static int real_comp_count = -1;
static OMX_HANDLETYPE hevc_handle = NULL;

static void ensure_loaded(void) {
    if (real_core) return;
    real_core = dlopen("/usr/lib/aarch64-linux-gnu/libOmxCore.real.so", RTLD_NOW | RTLD_LOCAL);
    if (!real_core) {
        fprintf(stderr, "omx_wrapper: cannot load real libOmxCore: %s\n", dlerror());
        return;
    }
    real_OMX_Init = dlsym(real_core, "OMX_Init");
    real_OMX_Deinit = dlsym(real_core, "OMX_Deinit");
    real_OMX_GetHandle = dlsym(real_core, "OMX_GetHandle");
    real_OMX_FreeHandle = dlsym(real_core, "OMX_FreeHandle");
    real_OMX_ComponentNameEnum = dlsym(real_core, "OMX_ComponentNameEnum");
    real_OMX_GetComponentsOfRole = dlsym(real_core, "OMX_GetComponentsOfRole");
    real_OMX_GetRolesOfComponent = dlsym(real_core, "OMX_GetRolesOfComponent");
    core_AwOmxComponentInit = dlsym(real_core, "AwOmxComponentInit");
    core_AwOmxComponentSetCallbacks = dlsym(real_core, "AwOmxComponentSetCallbacks");
    core_AwOmxComponentDeinit = dlsym(real_core, "AwOmxComponentDeinit");
}

static int count_real_components(void) {
    if (real_comp_count >= 0) return real_comp_count;
    char buf[256];
    int n = 0;
    while (real_OMX_ComponentNameEnum(buf, sizeof(buf), n) == OMX_ErrorNone) n++;
    real_comp_count = n;
    return n;
}

OMX_ERRORTYPE OMX_Init(void) {
    ensure_loaded();
    return real_OMX_Init ? real_OMX_Init() : OMX_ErrorInsufficientResources;
}

OMX_ERRORTYPE OMX_Deinit(void) {
    return real_OMX_Deinit ? real_OMX_Deinit() : OMX_ErrorNone;
}

OMX_ERRORTYPE OMX_GetHandle(OMX_HANDLETYPE *pHandle, char *cComponentName,
                            OMX_PTR pAppData, OMX_CALLBACKTYPE *pCallBacks) {
    ensure_loaded();

    if (strcmp(cComponentName, "OMX.allwinner.video.encoder.hevc") == 0) {
        void *venc = dlopen("libOmxVenc.so", RTLD_NOW | RTLD_GLOBAL);
        if (!venc) {
            fprintf(stderr, "omx_wrapper: cannot load libOmxVenc.so: %s\n", dlerror());
            return OMX_ErrorComponentNotFound;
        }

        void* (*create_fn)(void) = dlsym(venc, "AwOmxComponentCreate");
        if (!create_fn) {
            fprintf(stderr, "omx_wrapper: AwOmxComponentCreate not found\n");
            return OMX_ErrorComponentNotFound;
        }

        void *comp = create_fn();
        if (!comp) {
            fprintf(stderr, "omx_wrapper: AwOmxComponentCreate returned NULL\n");
            return OMX_ErrorInsufficientResources;
        }

        if (core_AwOmxComponentInit) {
            OMX_ERRORTYPE err = core_AwOmxComponentInit(comp, cComponentName);
            if (err != OMX_ErrorNone) {
                fprintf(stderr, "omx_wrapper: AwOmxComponentInit failed: 0x%x\n", err);
                return err;
            }
        }

        if (core_AwOmxComponentSetCallbacks) {
            core_AwOmxComponentSetCallbacks(comp, pCallBacks, pAppData);
        }

        hevc_handle = comp;
        *pHandle = comp;
        return OMX_ErrorNone;
    }

    return real_OMX_GetHandle ? real_OMX_GetHandle(pHandle, cComponentName, pAppData, pCallBacks) : OMX_ErrorComponentNotFound;
}

OMX_ERRORTYPE OMX_FreeHandle(OMX_HANDLETYPE hComponent) {
    ensure_loaded();
    if (hComponent == hevc_handle && hevc_handle != NULL) {
        OMX_ERRORTYPE ret = OMX_ErrorNone;
        if (core_AwOmxComponentDeinit)
            ret = core_AwOmxComponentDeinit(hComponent);
        hevc_handle = NULL;
        return ret;
    }
    return real_OMX_FreeHandle ? real_OMX_FreeHandle(hComponent) : OMX_ErrorNone;
}

OMX_ERRORTYPE OMX_ComponentNameEnum(char *cComponentName, OMX_U32 nNameLength, OMX_U32 nIndex) {
    ensure_loaded();
    int n = count_real_components();
    if ((int)nIndex < n) {
        return real_OMX_ComponentNameEnum(cComponentName, nNameLength, nIndex);
    } else if ((int)nIndex == n) {
        strncpy(cComponentName, "OMX.allwinner.video.encoder.hevc", nNameLength);
        return OMX_ErrorNone;
    }
    return OMX_ErrorNoMore;
}

OMX_ERRORTYPE OMX_GetComponentsOfRole(char *role, OMX_U32 *pNumComps, OMX_U8 **compNames) {
    ensure_loaded();
    OMX_ERRORTYPE ret = real_OMX_GetComponentsOfRole ?
        real_OMX_GetComponentsOfRole(role, pNumComps, compNames) : OMX_ErrorNone;
    if (strcmp(role, "video_encoder.hevc") == 0) {
        if (compNames == NULL) {
            *pNumComps = 1;
        } else if (*pNumComps >= 1) {
            strcpy((char*)compNames[0], "OMX.allwinner.video.encoder.hevc");
        }
        return OMX_ErrorNone;
    }
    return ret;
}

OMX_ERRORTYPE OMX_GetRolesOfComponent(char *compName, OMX_U32 *pNumRoles, OMX_U8 **roles) {
    ensure_loaded();
    if (strcmp(compName, "OMX.allwinner.video.encoder.hevc") == 0) {
        if (roles == NULL) {
            *pNumRoles = 1;
        } else if (*pNumRoles >= 1) {
            strcpy((char*)roles[0], "video_encoder.hevc");
        }
        return OMX_ErrorNone;
    }
    return real_OMX_GetRolesOfComponent ?
        real_OMX_GetRolesOfComponent(compName, pNumRoles, roles) : OMX_ErrorNone;
}

/* Forward remaining OMX API functions */
static OMX_ERRORTYPE (*real_OMX_SetupTunnel)(OMX_HANDLETYPE, OMX_U32, OMX_HANDLETYPE, OMX_U32) = NULL;
static OMX_ERRORTYPE (*real_OMX_GetContentPipe)(void**, char*) = NULL;

OMX_ERRORTYPE OMX_SetupTunnel(OMX_HANDLETYPE hOutput, OMX_U32 nPortOutput,
                               OMX_HANDLETYPE hInput, OMX_U32 nPortInput) {
    ensure_loaded();
    if (!real_OMX_SetupTunnel)
        real_OMX_SetupTunnel = dlsym(real_core, "OMX_SetupTunnel");
    return real_OMX_SetupTunnel ? real_OMX_SetupTunnel(hOutput, nPortOutput, hInput, nPortInput) : OMX_ErrorNone;
}

OMX_ERRORTYPE OMX_GetContentPipe(void **hPipe, char *szURI) {
    ensure_loaded();
    if (!real_OMX_GetContentPipe)
        real_OMX_GetContentPipe = dlsym(real_core, "OMX_GetContentPipe");
    return real_OMX_GetContentPipe ? real_OMX_GetContentPipe(hPipe, szURI) : OMX_ErrorNone;
}
