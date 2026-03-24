/*
 * LD_PRELOAD fix for Allwinner Cedar H.264 encoder.
 *
 * Intercepts two functions from libvencoder.so:
 *
 * 1. VideoEncSetParameter() - corrects level_idc from the hardcoded 10
 *    (Level 1.0) to 41 (Level 4.1) when the OMX wrapper sets H.264 params.
 *
 * 2. VideoEncGetParameter() - when the OMX wrapper requests the SPS/PPS
 *    header data (VENC_IndexParamH264SPSPPS), rewrites the SPS NAL in-place
 *    to correct level_idc for the actual resolution and strips the broken
 *    VUI parameters (which contain invalid cpb_count=33).
 *
 * This produces spec-compliant H.264 SPS directly from the encoder,
 * allowing h264parse and mp4mux to work in a single GStreamer pipeline.
 *
 * Build:  gcc -shared -fPIC -o libvenc_h264_fix.so venc_h264_level_fix.c -ldl
 * Usage:  LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libvenc_h264_fix.so gst-launch-1.0 ...
 *     or: add to /etc/ld.so.preload for system-wide fix
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#define VENC_IndexParamH264Param   0x100
#define VENC_IndexParamH264SPSPPS  0x101

typedef struct { int nProfile; int nLevel; } VencH264ProfileLevel;
typedef struct { unsigned char *pBuffer; unsigned int nLength; } VencHeaderData;

static int (*real_SetParam)(void *, int, void *) = NULL;
static int (*real_GetParam)(void *, int, void *) = NULL;

static void *load_real_lib(void) {
    static void *lib = NULL;
    if (!lib) lib = dlopen("libvencoder.so", RTLD_NOW);
    return lib;
}

/* ---- H.264 bitstream helpers ---- */

static unsigned int read_ue(const unsigned char *buf, int nbits, int *bp) {
    int zeros = 0;
    while (*bp < nbits && !((buf[*bp / 8] >> (7 - *bp % 8)) & 1)) {
        zeros++;
        (*bp)++;
    }
    (*bp)++;
    unsigned int val = 0;
    for (int i = 0; i < zeros && *bp < nbits; i++) {
        val = (val << 1) | ((buf[*bp / 8] >> (7 - *bp % 8)) & 1);
        (*bp)++;
    }
    return val + (1u << zeros) - 1;
}

static int read_se(const unsigned char *buf, int nbits, int *bp) {
    unsigned int v = read_ue(buf, nbits, bp);
    return (v & 1) ? (int)((v + 1) / 2) : -(int)(v / 2);
}

static int is_high_profile(unsigned char p) {
    return p == 100 || p == 110 || p == 122 || p == 244 || p == 44 ||
           p == 83  || p == 86  || p == 118 || p == 128 || p == 138 ||
           p == 139 || p == 134 || p == 135;
}

static void skip_scaling_list(const unsigned char *buf, int nbits, int *bp, int size) {
    int last = 8, next = 8;
    for (int j = 0; j < size; j++) {
        if (next != 0) {
            int delta = read_se(buf, nbits, bp);
            next = (last + delta + 256) % 256;
        }
        last = (next == 0) ? last : next;
    }
}

static int remove_ep(const unsigned char *s, int n, unsigned char *d) {
    int dp = 0;
    for (int i = 0; i < n; i++) {
        if (i + 2 < n && s[i] == 0 && s[i + 1] == 0 && s[i + 2] == 3) {
            d[dp++] = 0;
            d[dp++] = 0;
            i += 2;
        } else {
            d[dp++] = s[i];
        }
    }
    return dp;
}

static int add_ep(const unsigned char *s, int n, unsigned char *d) {
    int dp = 0;
    for (int i = 0; i < n; i++) {
        if (i + 1 < n && s[i] == 0 && s[i + 1] == 0 &&
            (i + 2 >= n || s[i + 2] <= 3)) {
            d[dp++] = 0;
            d[dp++] = 0;
            d[dp++] = 3;
            i++;
        } else {
            d[dp++] = s[i];
        }
    }
    return dp;
}

static int compute_level(unsigned int w, unsigned int h) {
    unsigned int mbs = ((w + 15) / 16) * ((h + 15) / 16);
    if (mbs <= 99)   return 10;
    if (mbs <= 396)  return 20;
    if (mbs <= 792)  return 21;
    if (mbs <= 1620) return 30;
    if (mbs <= 3600) return 31;
    if (mbs <= 5120) return 32;
    if (mbs <= 8192) return 40;
    if (mbs <= 8704) return 42;
    return 51;
}

/*
 * Fix a single SPS NAL unit: correct level_idc, strip broken VUI.
 * nal points to NAL data starting with nal_header byte.
 * Returns new NAL length written to out, or 0 on failure.
 */
static int fix_sps(const unsigned char *nal, int nlen, unsigned char *out) {
    if (nlen < 5) return 0;

    unsigned char profile_idc = nal[1];

    unsigned char rbsp[4096];
    int rlen = remove_ep(nal + 4, nlen - 4, rbsp);
    int rb = rlen * 8, bp = 0;

    read_ue(rbsp, rb, &bp); /* sps_id */

    if (is_high_profile(profile_idc)) {
        unsigned int cfi = read_ue(rbsp, rb, &bp); /* chroma_format_idc */
        if (cfi == 3) bp++; /* separate_colour_plane_flag */
        read_ue(rbsp, rb, &bp); /* bit_depth_luma_minus8 */
        read_ue(rbsp, rb, &bp); /* bit_depth_chroma_minus8 */
        bp++; /* qpprime_y_zero_transform_bypass_flag */
        int smpf = (rbsp[bp / 8] >> (7 - bp % 8)) & 1; bp++;
        if (smpf) {
            int cnt = (cfi != 3) ? 8 : 12;
            for (int i = 0; i < cnt; i++) {
                int present = (rbsp[bp / 8] >> (7 - bp % 8)) & 1; bp++;
                if (present)
                    skip_scaling_list(rbsp, rb, &bp, (i < 6) ? 16 : 64);
            }
        }
    }

    read_ue(rbsp, rb, &bp); /* log2_max_frame_num_minus4 */
    unsigned int poc_type = read_ue(rbsp, rb, &bp);
    if (poc_type == 0) {
        read_ue(rbsp, rb, &bp); /* log2_max_pic_order_cnt_lsb_minus4 */
    } else if (poc_type == 1) {
        bp++; /* delta_pic_order_always_zero_flag */
        read_se(rbsp, rb, &bp); /* offset_for_non_ref_pic */
        read_se(rbsp, rb, &bp); /* offset_for_top_to_bottom_field */
        unsigned int nrf = read_ue(rbsp, rb, &bp);
        for (unsigned int i = 0; i < nrf; i++)
            read_se(rbsp, rb, &bp);
    }
    read_ue(rbsp, rb, &bp); /* max_num_ref_frames */
    bp++; /* gaps_in_frame_num_value_allowed_flag */
    unsigned int w_mbs = read_ue(rbsp, rb, &bp);
    unsigned int h_mbs = read_ue(rbsp, rb, &bp);
    int fmo = (rbsp[bp / 8] >> (7 - bp % 8)) & 1; bp++;
    if (!fmo) bp++; /* mb_adaptive_frame_field_flag */
    bp++; /* direct_8x8_inference_flag */
    int crop = (rbsp[bp / 8] >> (7 - bp % 8)) & 1; bp++;
    if (crop) {
        read_ue(rbsp, rb, &bp);
        read_ue(rbsp, rb, &bp);
        read_ue(rbsp, rb, &bp);
        read_ue(rbsp, rb, &bp);
    }

    if (bp > rb) return 0;

    /* bp is at vui_parameters_present_flag.
     * Keep all RBSP bits before it, set vui_flag=0, add stop bit. */
    int new_bits = bp + 2;
    int new_bytes = (new_bits + 7) / 8;
    unsigned char new_rbsp[4096];
    memset(new_rbsp, 0, (unsigned)new_bytes);

    int full = bp / 8;
    if (full > 0) memcpy(new_rbsp, rbsp, (unsigned)full);
    int rem = bp % 8;
    if (rem > 0)
        new_rbsp[full] = rbsp[full] & (unsigned char)(0xFF << (8 - rem));

    int stop = bp + 1;
    new_rbsp[stop / 8] |= (unsigned char)(1 << (7 - stop % 8));

    unsigned char ep_buf[4096];
    int ep_len = add_ep(new_rbsp, new_bytes, ep_buf);

    unsigned int width  = (w_mbs + 1) * 16;
    unsigned int height = (h_mbs + 1) * 16;
    int lvl = compute_level(width, height);

    out[0] = nal[0];
    out[1] = nal[1];
    out[2] = nal[2];
    out[3] = (unsigned char)lvl;
    memcpy(out + 4, ep_buf, (unsigned)ep_len);
    return 4 + ep_len;
}

/*
 * Scan SPS+PPS buffer for SPS NAL (type 7), fix it in-place.
 * The fixed SPS is always <= original size (VUI stripped), so the
 * buffer is large enough. Adjusts *len accordingly.
 */
static void fix_sps_buffer(unsigned char *buf, unsigned int *len) {
    unsigned int n = *len;
    unsigned int i = 0;

    while (i + 4 < n) {
        int sc_len = 0;
        if (buf[i] == 0 && buf[i+1] == 0 && buf[i+2] == 0 && buf[i+3] == 1)
            sc_len = 4;
        else if (buf[i] == 0 && buf[i+1] == 0 && buf[i+2] == 1)
            sc_len = 3;

        if (sc_len == 0) { i++; continue; }

        unsigned int nal_start = i + (unsigned)sc_len;
        if (nal_start >= n) break;

        /* Find end of this NAL (next start code or end of buffer) */
        unsigned int nal_end = n;
        for (unsigned int j = nal_start + 1; j + 2 < n; j++) {
            if (buf[j] == 0 && buf[j+1] == 0 &&
                (buf[j+2] == 1 ||
                 (j + 3 < n && buf[j+2] == 0 && buf[j+3] == 1))) {
                nal_end = j;
                break;
            }
        }

        int nal_type = buf[nal_start] & 0x1f;
        unsigned int nal_len = nal_end - nal_start;

        if (nal_type == 7 && nal_len >= 5) {
            unsigned char fixed[4096];
            int new_len = fix_sps(buf + nal_start, (int)nal_len, fixed);
            if (new_len > 0) {
                int diff = (int)nal_len - new_len;
                if (diff != 0 && nal_end < n)
                    memmove(buf + nal_start + new_len,
                            buf + nal_end, n - nal_end);
                memcpy(buf + nal_start, fixed, (unsigned)new_len);
                *len = n - (unsigned)diff;
                fprintf(stderr, "venc_fix: SPS rewritten (%u -> %d bytes)\n",
                        nal_len, new_len);
            }
            return;
        }

        i = nal_end;
    }
}

/* ---- Intercepted API functions ---- */

int VideoEncSetParameter(void *pEncoder, int indexType, void *paramData) {
    if (!real_SetParam) {
        void *lib = load_real_lib();
        if (lib) real_SetParam = dlsym(lib, "VideoEncSetParameter");
    }
    if (!real_SetParam) return -1;

    if (indexType == VENC_IndexParamH264Param && paramData) {
        VencH264ProfileLevel *pl = (VencH264ProfileLevel *)paramData;
        if (pl->nLevel <= 10) {
            pl->nLevel = 41;
        }
    }

    return real_SetParam(pEncoder, indexType, paramData);
}

int VideoEncGetParameter(void *pEncoder, int indexType, void *paramData) {
    if (!real_GetParam) {
        void *lib = load_real_lib();
        if (lib) real_GetParam = dlsym(lib, "VideoEncGetParameter");
    }
    if (!real_GetParam) return -1;

    int ret = real_GetParam(pEncoder, indexType, paramData);

    if (ret == 0 && indexType == VENC_IndexParamH264SPSPPS && paramData) {
        VencHeaderData *hdr = (VencHeaderData *)paramData;
        if (hdr->pBuffer && hdr->nLength > 0)
            fix_sps_buffer(hdr->pBuffer, &hdr->nLength);
    }

    return ret;
}
