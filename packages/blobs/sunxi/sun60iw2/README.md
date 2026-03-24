# Allwinner A733 (Radxa Cubie A7Z) — Hardware Video Encoding

Custom fixes and wrappers for the Cedar VPU hardware encoder on the Allwinner A733 SoC,
integrated into the Armbian build via `sun60iw2.conf`.

## What's in this directory

| File | Purpose |
|---|---|
| `venc_h264_level_fix.c` | **LD_PRELOAD library** — fixes H.264 encoder SPS bugs at the API level. Installed system-wide via `/etc/ld.so.preload`. |
| `h264_sps_fix.c` | **Standalone pipe filter** — reads raw H.264 from stdin, fixes SPS, writes to stdout. Diagnostic/fallback tool. |
| `omx_core_hevc_wrapper.c` | **OMX Core wrapper** — adds H.265 encoder registration missing from `libOmxCore.so`. Replaces the original (saved as `libOmxCore.real.so`). |

## Bugs fixed

### H.264 encoder (`omxh264videoenc`)

The Allwinner OMX H.264 encoder produces non-standard SPS headers with two bugs:

1. **`level_idc` hardcoded to 10 (Level 1.0)** — valid only for 176x144. Standard decoders
   reject or misinterpret the stream for any higher resolution.

2. **Malformed VUI parameters (`cpb_count=33`)** — the VUI section of the SPS contains
   invalid values that cause parse errors in FFmpeg, VLC, and GStreamer's `h264parse`.

**`venc_h264_level_fix.c`** intercepts two Cedar API functions:

- `VideoEncSetParameter` — corrects `level_idc` from 10 to 41 (Level 4.1) when the OMX
  wrapper configures the encoder.
- `VideoEncGetParameter` — when the OMX wrapper requests SPS/PPS data
  (`VENC_IndexParamH264SPSPPS`), parses the SPS (including High profile extension fields
  for 1080p+), corrects `level_idc` based on actual resolution, and strips the broken VUI.

This produces spec-compliant H.264 directly from the encoder, enabling `h264parse` and
container muxers to work in a single GStreamer pipeline.

### H.265 encoder (`omxh265videoenc`)

`libOmxVenc.so` fully supports H.265 encoding (`OMX.allwinner.video.encoder.hevc`), but
`libOmxCore.so` has a hardcoded component table that only registers H.264 and MJPEG
encoders. GStreamer's `OMX_GetHandle()` fails with "component not found."

**`omx_core_hevc_wrapper.c`** replaces `libOmxCore.so`:
- Forwards all existing OMX calls to the original library (`libOmxCore.real.so`)
- Adds handling for the HEVC encoder component, properly initializing it through `libOmxVenc.so`
- The `gstomx.conf` entry for `[omxh265videoenc]` is also added at build time

## GStreamer pipelines

### Available hardware elements

| Element | Description |
|---|---|
| `omxh264dec` | H.264 hardware decoder |
| `omxh264videoenc` | H.264 hardware encoder |
| `omxh265videoenc` | H.265/HEVC hardware encoder |
| `omxhevcvideodec` | H.265/HEVC hardware decoder |
| `omxmjpegvideoenc` | MJPEG hardware encoder |

### Encode H.264

Transcode any video to H.264 at 2 Mbps:

```bash
gst-launch-1.0 -e \
  filesrc location=input.mp4 ! qtdemux ! h264parse ! \
  omxh264dec ! \
  queue max-size-buffers=16 max-size-time=0 max-size-bytes=0 ! \
  omxh264videoenc target-bitrate=2000000 control-rate=1 interval-intraframes=24 ! \
  h264parse config-interval=-1 ! \
  matroskamux ! filesink location=output.mkv
```

### Encode H.265

Transcode any video to H.265/HEVC at 2 Mbps:

```bash
gst-launch-1.0 -e \
  uridecodebin uri=file:///path/to/input.mp4 ! \
  queue max-size-buffers=16 max-size-time=0 max-size-bytes=0 ! \
  omxh265videoenc target-bitrate=2000000 control-rate=1 ! \
  h265parse ! \
  matroskamux ! filesink location=output.mkv
```

### Convert MKV to MP4

Zero-copy remux (no re-encoding, instant):

```bash
ffmpeg -i output.mkv -c copy output.mp4
```

### Encode from camera (V4L2)

```bash
gst-launch-1.0 -e \
  v4l2src device=/dev/video0 ! video/x-raw,width=1920,height=1080,framerate=30/1 ! \
  omxh264videoenc target-bitrate=4000000 control-rate=1 ! \
  h264parse config-interval=-1 ! \
  matroskamux ! filesink location=camera.mkv
```

### RTSP / network streaming

```bash
gst-launch-1.0 -e \
  v4l2src device=/dev/video0 ! video/x-raw,width=1920,height=1080,framerate=30/1 ! \
  omxh264videoenc target-bitrate=2000000 control-rate=1 ! \
  h264parse config-interval=-1 ! \
  rtph264pay ! udpsink host=192.168.1.100 port=5000
```

## Pipeline notes

- **`queue max-size-buffers=16`** between decoder and encoder is required when the source
  contains B-frames (Main/High profile H.264). Without it, frames arrive in decode order
  instead of display order, causing visual glitches.

- **`matroskamux`** is used instead of `mp4mux` because the OMX encoder emits an SEI NAL
  without PTS, which `mp4mux` rejects. MKV handles this correctly. Use `ffmpeg -c copy`
  to remux to MP4 if needed.

- **`h264parse config-interval=-1`** inserts SPS/PPS before every keyframe, which is
  useful for streaming and container compatibility.

- **`control-rate=1`** selects VBR (variable bitrate). The `target-bitrate` value is in
  bits per second.

## Performance (Allwinner A733)

Measured on 1080p 30fps Big Buck Bunny (10:34):

| Codec | Target bitrate | Encode FPS | Realtime | Output size |
|---|---|---|---|---|
| H.264 | 3 Mbps | ~99 fps | 3.3x | 232 MB |
| H.265 | 2 Mbps | ~99 fps | 3.3x | 146 MB |

## Build integration

All fixes are automatically compiled and installed by `post_family_tweaks__install_hw_encoding()`
in `config/sources/families/sun60iw2.conf`. The build:

1. Installs GStreamer and Radxa's `libcedarc-dev` + `libgstreamer-openmax-allwinner` packages
2. Adds the H.265 encoder entry to `gstomx.conf`
3. Compiles and installs the OMX Core HEVC wrapper
4. Compiles and installs the H.264 SPS fix (LD_PRELOAD library + standalone filter)
