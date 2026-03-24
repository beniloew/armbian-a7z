/*
 * h264_sps_fix - Fix Allwinner Cedar H.264 encoder SPS headers.
 *
 * Reads raw H.264 bitstream from stdin, fixes SPS NAL units
 * (corrects level_idc for resolution, strips broken VUI parameters),
 * writes to stdout. Designed for pipe-based streaming with minimal latency.
 *
 * The Allwinner OMX H.264 encoder produces non-standard SPS headers:
 *   - level_idc hardcoded to 10 (Level 1.0, max 176x144)
 *   - Malformed VUI parameters (cpb_count 33 invalid)
 * This filter corrects both issues, producing spec-compliant H.264.
 *
 * Build:  gcc -O2 -o h264_sps_fix h264_sps_fix.c
 * Usage:  gst-launch-1.0 ... ! fdsink fd=1 | h264_sps_fix | ffmpeg -f h264 -i pipe:0 ...
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BUF_SIZE (4 * 1024 * 1024)

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
 * Fix SPS NAL: correct level_idc based on resolution, strip VUI.
 *
 * Parses through all SPS fields (including High profile extensions for
 * 1080p+ streams) to locate the vui_parameters_present_flag, sets it to 0,
 * and truncates. This avoids rebuilding individual fields and correctly
 * handles all H.264 profiles.
 *
 * Input: nal points to NAL data (starting with nal_header byte).
 * Output: fixed NAL written to out buffer.
 * Returns new NAL length, or 0 on failure.
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

    /* bp is now at vui_parameters_present_flag.
     * Copy all RBSP bits before it, set vui_flag=0, add stop bit. */
    int new_bits = bp + 2; /* existing + vui(0) + stop(1) */
    int new_bytes = (new_bits + 7) / 8;
    unsigned char new_rbsp[4096];
    memset(new_rbsp, 0, (unsigned)new_bytes);

    int full = bp / 8;
    if (full > 0) memcpy(new_rbsp, rbsp, (unsigned)full);
    int rem = bp % 8;
    if (rem > 0)
        new_rbsp[full] = rbsp[full] & (unsigned char)(0xFF << (8 - rem));
    /* vui_present_flag at bit bp is already 0 from memset */
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

int main(void) {
    unsigned char *buf = malloc(BUF_SIZE);
    if (!buf) { perror("malloc"); return 1; }

    int blen = 0, eof_flag = 0;

    while (!eof_flag || blen > 0) {
        if (!eof_flag) {
            int n = read(STDIN_FILENO, buf + blen, BUF_SIZE - blen);
            if (n <= 0) eof_flag = 1;
            else blen += n;
        }

        int pos = 0;
        while (pos < blen) {
            int sc = -1, scl = 0;
            for (int i = pos; i + 2 < blen; i++) {
                if (buf[i] == 0 && buf[i + 1] == 0) {
                    if (buf[i + 2] == 1) { sc = i; scl = 3; break; }
                    if (i + 3 < blen && buf[i + 2] == 0 && buf[i + 3] == 1) {
                        sc = i; scl = 4; break;
                    }
                }
            }
            if (sc < 0) {
                if (eof_flag && blen > pos) {
                    write(STDOUT_FILENO, buf + pos, blen - pos);
                    blen = 0;
                }
                break;
            }

            if (sc > pos)
                write(STDOUT_FILENO, buf + pos, sc - pos);

            int ns = sc + scl;
            int nsc = -1;
            for (int i = ns + 1; i + 2 < blen; i++) {
                if (buf[i] == 0 && buf[i + 1] == 0 &&
                    (buf[i + 2] == 1 ||
                     (i + 3 < blen && buf[i + 2] == 0 && buf[i + 3] == 1))) {
                    nsc = i;
                    break;
                }
            }

            if (nsc < 0 && !eof_flag) {
                if (sc > 0) {
                    memmove(buf, buf + sc, blen - sc);
                    blen -= sc;
                }
                break;
            }

            int ne = (nsc >= 0) ? nsc : blen;
            int nl = ne - ns;
            int nt = buf[ns] & 0x1f;

            if (nt == 7 && nl >= 5) {
                unsigned char fixed[4096];
                int newl = fix_sps(buf + ns, nl, fixed);
                if (newl > 0) {
                    unsigned char sc4[4] = {0, 0, 0, 1};
                    write(STDOUT_FILENO, sc4 + (4 - scl), scl);
                    write(STDOUT_FILENO, fixed, newl);
                    pos = ne;
                    continue;
                }
            }

            write(STDOUT_FILENO, buf + sc, scl + nl);
            pos = ne;
        }

        if (pos > 0 && pos < blen) {
            memmove(buf, buf + pos, blen - pos);
            blen -= pos;
        } else if (pos >= blen) {
            blen = 0;
        }
    }

    free(buf);
    return 0;
}
