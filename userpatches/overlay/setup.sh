#!/bin/bash
# ============================================================
# DJI Video Stream — Unified Setup
# ============================================================
# Supports: Raspberry Pi 4, Orange Pi 4B (RK3399), NanoPi R76S (RK3576), Orange Pi 5 (RK3588), Radxa Cubie A7Z (A733)
#
# Usage:
#   sudo bash setup.sh --dev     # Dev machine: install compiler + build
#   sudo bash setup.sh --prod    # Target board: install runtime only
#   sudo bash setup.sh           # Auto-detect (dev if gcc found)
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

LIBUSB_VER=1.0.27
LIBUSB_DIR="$SCRIPT_DIR/libusb-static"
BINARY="dji_stream"
SERVICE="dji_stream"

# ── Parse args ──

MODE=""
LICENSE_CHECK=""
for arg in "$@"; do
    case "$arg" in
        --dev)  MODE="dev"  ;;
        --prod) MODE="prod" ;;
        --license) LICENSE_CHECK="1" ;;
        --help|-h)
            echo "Usage: sudo bash setup.sh [--dev|--prod] [--license]"
            echo "  --dev      Install compiler, build binary"
            echo "  --prod     Install runtime dependencies only"
            echo "  --license  Build with hardware license check (Ed25519)"
            exit 0
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root (sudo bash setup.sh)"
    exit 1
fi

# ── Platform detection ──

detect_platform() {
    PLATFORM="unknown"
    PLATFORM_NAME="Unknown"

    if [ -f /proc/device-tree/compatible ]; then
        COMPAT=$(tr '\0' '\n' < /proc/device-tree/compatible | head -5 | tr '\n' ' ')
    else
        COMPAT=""
    fi

    if echo "$COMPAT" | grep -qi "a733\|sun55i"; then
        PLATFORM="a733"
        PLATFORM_NAME="Allwinner A733 (Radxa Cubie A7Z)"
    elif echo "$COMPAT" | grep -qi "bcm2711\|bcm2712\|bcm27"; then
        PLATFORM="pi"
        PLATFORM_NAME="Raspberry Pi"
    elif echo "$COMPAT" | grep -qi "rk3399"; then
        PLATFORM="rk3399"
        PLATFORM_NAME="RK3399 (Orange Pi 4B)"
    elif echo "$COMPAT" | grep -qi "rk3576"; then
        PLATFORM="rk3576"
        PLATFORM_NAME="RK3576 (NanoPi R76S)"
    elif echo "$COMPAT" | grep -qi "rk3588"; then
        PLATFORM="rk3588"
        PLATFORM_NAME="RK3588 (Orange Pi 5)"
    elif [ -f /proc/device-tree/model ]; then
        MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')
        if echo "$MODEL" | grep -qi "raspberry"; then
            PLATFORM="pi"
            PLATFORM_NAME="Raspberry Pi"
        fi
    fi
}

detect_platform

echo "========================================"
echo "  DJI Video Stream — Setup"
echo "========================================"
echo ""
echo "  Platform: $PLATFORM_NAME"
echo "  Mode:     ${MODE:-auto}"
echo ""

# Auto-detect mode
if [ -z "$MODE" ]; then
    if command -v gcc >/dev/null 2>&1; then
        MODE="dev"
        echo "  (gcc found — using dev mode)"
    else
        MODE="prod"
        echo "  (no gcc — using prod mode)"
    fi
    echo ""
fi

# ── Step 1: System packages ──

STEP=1
TOTAL=5

echo "[$STEP/$TOTAL] Installing system packages..."
apt-get update -qq

if [ "$MODE" = "dev" ]; then
    apt-get install -y gcc make wget tar xxd curl ca-certificates gnupg upx-ucl traceroute

    # Node.js — need >=18 for Vite. System repos on Debian 11 ship v12.
    NODE_VER=$(node --version 2>/dev/null | grep -oP '(?<=v)\d+' || echo "0")
    if [ "$NODE_VER" -lt 18 ]; then
        echo "  Node.js v${NODE_VER} too old (need >=18), installing from NodeSource..."
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
            > /etc/apt/sources.list.d/nodesource.list
        apt-get update -qq
        apt-get install -y nodejs
        echo "  Node.js $(node --version) installed"
    else
        echo "  Node.js v${NODE_VER} OK"
    fi
fi

# ffmpeg installed separately — Debian 11 repos sometimes have
# broken libav* version pinning that blocks a single apt-get call.
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "  Installing ffmpeg..."
    if ! apt-get install -y ffmpeg 2>/dev/null; then
        echo "  ffmpeg has broken deps — trying apt --fix-broken install..."
        apt --fix-broken install -y 2>/dev/null || true
        if ! apt-get install -y ffmpeg 2>/dev/null; then
            echo "  Retrying after upgrading libav* packages..."
            apt-get install -y --only-upgrade 'libav*' 'libsw*' 2>/dev/null || true
            apt-get install -y ffmpeg 2>/dev/null || {
                echo "  WARNING: Could not install ffmpeg automatically."
                echo "  Try manually: sudo apt-get upgrade && sudo apt-get install ffmpeg"
                echo "  The build will continue without ffmpeg."
            }
        fi
    fi
else
    echo "  ffmpeg already installed, skipping."
fi

# GStreamer — needed for Rockchip hardware encode/decode (MPP)
if [ "$PLATFORM" = "rk3399" ] || [ "$PLATFORM" = "rk3576" ] || [ "$PLATFORM" = "rk3588" ]; then
    echo "  Installing GStreamer (Rockchip MPP pipeline)..."
    apt-get install -y \
        gstreamer1.0-tools \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-rtsp \
        libgstreamer1.0-dev 2>/dev/null || true

    # Rockchip MPP GStreamer plugin (package name varies by distro)
    MPP_PLUGIN_INSTALLED=0
    for pkg in gstreamer1.0-rockchip1 gstreamer1.0-rockchip; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            apt-get install -y "$pkg" 2>/dev/null && MPP_PLUGIN_INSTALLED=1 && break
        fi
    done

    # If apt package not available, install from pre-built or build from source
    if [ "$MPP_PLUGIN_INSTALLED" = "0" ] && ! gst-inspect-1.0 mpph265enc >/dev/null 2>&1; then
        GST_PLUGIN_DIR=$(pkg-config --variable=pluginsdir gstreamer-1.0 2>/dev/null || echo "/usr/lib/aarch64-linux-gnu/gstreamer-1.0")
        if [ -f "$SCRIPT_DIR/libgstrockchipmpp.so" ]; then
            echo "  Installing MPP plugin from package..."
            cp "$SCRIPT_DIR/libgstrockchipmpp.so" "$GST_PLUGIN_DIR/"
            rm -rf /root/.cache/gstreamer-1.0/ ~/.cache/gstreamer-1.0/
        elif [ "$MODE" = "dev" ] && pkg-config --exists rockchip_mpp 2>/dev/null; then
            echo "  Building GStreamer MPP plugin from source..."
            apt-get install -y libgstreamer-plugins-base1.0-dev meson ninja-build 2>/dev/null || true
            MPPBUILD=$(mktemp -d)
            git clone https://github.com/JeffyCN/mirrors.git --depth 1 -b gstreamer-rockchip "$MPPBUILD/gstreamer-rockchip" 2>/dev/null
            if [ -d "$MPPBUILD/gstreamer-rockchip" ]; then
                cd "$MPPBUILD/gstreamer-rockchip"
                meson setup builddir 2>/dev/null && ninja -C builddir 2>/dev/null
                if [ -f builddir/gst/rockchipmpp/libgstrockchipmpp.so ]; then
                    cp builddir/gst/rockchipmpp/libgstrockchipmpp.so "$GST_PLUGIN_DIR/"
                    rm -rf /root/.cache/gstreamer-1.0/ ~/.cache/gstreamer-1.0/
                    echo "  MPP plugin built and installed"
                else
                    echo "  WARNING: MPP plugin build failed"
                fi
                cd "$SCRIPT_DIR"
            fi
            rm -rf "$MPPBUILD"
        else
            echo "  WARNING: GStreamer MPP plugin not available"
        fi
    fi

    # Set /dev/mpp_service permissions (needed for encoder access)
    if [ -c /dev/mpp_service ]; then
        chmod 666 /dev/mpp_service
        echo "  /dev/mpp_service permissions set"
        # Make persistent via udev rule
        if [ ! -f /etc/udev/rules.d/99-mpp.rules ]; then
            echo 'KERNEL=="mpp_service", MODE="0666"' > /etc/udev/rules.d/99-mpp.rules
            echo "  udev rule for mpp_service created"
        fi
    fi

    # Verify key elements
    if command -v gst-inspect-1.0 >/dev/null 2>&1; then
        for elem in h264parse mppvideodec mpph265enc; do
            if gst-inspect-1.0 "$elem" >/dev/null 2>&1; then
                echo "  GStreamer element '$elem': OK"
            else
                echo "  WARNING: GStreamer element '$elem' not found"
            fi
        done
    fi
fi

# GStreamer — needed for Allwinner CedarX OMX pipeline
if [ "$PLATFORM" = "a733" ]; then
    echo "  Installing GStreamer (Allwinner CedarX / OMX pipeline)..."
    apt-get install -y \
        gstreamer1.0-tools \
        gstreamer1.0-libav \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        libgstreamer1.0-dev 2>/dev/null || true

    # CedarX VPU device permissions
    if [ -c /dev/cedar_dev ]; then
        echo "  Setting /dev/cedar_dev permissions..."
        chmod 666 /dev/cedar_dev
    else
        echo "  WARNING: /dev/cedar_dev not found — CedarX VPU not available"
    fi

    # CedarX VE2 (encoder) device permissions
    if [ -c /dev/cedar_dev_ve2 ]; then
        echo "  Setting /dev/cedar_dev_ve2 permissions..."
        chmod 666 /dev/cedar_dev_ve2
    else
        echo "  WARNING: /dev/cedar_dev_ve2 not found — CedarX encoder may not work"
    fi

    # DMA heap permissions (required by CedarX encoder for buffer allocation)
    if [ -d /dev/dma_heap ]; then
        echo "  Setting /dev/dma_heap permissions..."
        chmod 666 /dev/dma_heap/* 2>/dev/null || true
    fi

    # Make persistent via udev rules
    UDEV_RULE="/etc/udev/rules.d/99-cedar.rules"
    if [ ! -f "$UDEV_RULE" ]; then
        cat > "$UDEV_RULE" << 'UREOF'
KERNEL=="cedar_dev", MODE="0666"
KERNEL=="cedar_dev_ve2", MODE="0666"
SUBSYSTEM=="dma_heap", MODE="0666"
UREOF
        echo "  Created udev rule: $UDEV_RULE"
    fi

    # Add user to video group
    REAL_USER="${SUDO_USER:-$(whoami)}"
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        usermod -aG video "$REAL_USER" 2>/dev/null || true
        echo "  Added $REAL_USER to video group"
    fi

    # Add H.265 encoder to gstomx.conf if missing
    GSTOMX_CONF="/etc/xdg/gstomx.conf"
    if [ -f "$GSTOMX_CONF" ]; then
        if ! grep -q "omxh265videoenc" "$GSTOMX_CONF"; then
            echo "  Adding H.265 encoder (omxh265videoenc) to $GSTOMX_CONF..."
            cat >> "$GSTOMX_CONF" << 'OMXEOF'

[omxh265videoenc]
type-name=GstOMXH265Enc
core-name=/usr/lib/aarch64-linux-gnu/libOmxCore.so
component-name=OMX.allwinner.video.encoder.hevc
rank=257
in-port-index=0
out-port-index=1
hacks=event-port-settings-changed-ndata-parameter-swap;video-framerate-integer;syncframe-flag-not-used;no-disable-outport
OMXEOF
            echo "  Done"
        else
            echo "  omxh265videoenc already in $GSTOMX_CONF"
        fi
    else
        echo "  WARNING: $GSTOMX_CONF not found — OMX H.265 encoder not configured"
    fi

    # Verify key elements
    if command -v gst-inspect-1.0 >/dev/null 2>&1; then
        for elem in h264parse omxh264dec omxh264videoenc; do
            if gst-inspect-1.0 "$elem" >/dev/null 2>&1; then
                echo "  GStreamer element '$elem': OK"
            else
                echo "  WARNING: GStreamer element '$elem' not found"
            fi
        done
    fi

    # Build cedar_enc — CedarX SDK H.265/H.264 encoder (low-latency, no OMX)
    CEDAR_ENC="/usr/local/bin/cedar_enc"
    if [ -f "$CEDAR_ENC" ]; then
        echo "  cedar_enc already built: $CEDAR_ENC"
    elif [ "$MODE" = "dev" ]; then
        echo "  Building cedar_enc (CedarX H.265 hardware encoder)..."
        if [ -f "$SCRIPT_DIR/cedar_enc.c" ]; then
            gcc -O2 -o "$CEDAR_ENC" "$SCRIPT_DIR/cedar_enc.c" \
                -I/usr/include/cedarx \
                -lvencoder -lcdc_base -lMemAdapter -lVE -lpthread 2>&1
            if [ -f "$CEDAR_ENC" ]; then
                chmod +x "$CEDAR_ENC"
                echo "  cedar_enc installed: $CEDAR_ENC"
            else
                echo "  WARNING: cedar_enc build failed"
            fi
        else
            echo "  WARNING: cedar_enc.c not found in $SCRIPT_DIR"
        fi
    elif [ -f "$SCRIPT_DIR/cedar_enc" ]; then
        cp "$SCRIPT_DIR/cedar_enc" "$CEDAR_ENC" && chmod +x "$CEDAR_ENC"
        echo "  cedar_enc installed: $CEDAR_ENC"
    else
        echo "  WARNING: cedar_enc not found. Build with --dev mode first."
    fi

    # Build cedar_transcode — combined HW decode + HW encode + direct RTP
    CEDAR_TRANSCODE="/usr/local/bin/cedar_transcode"
    if [ -f "$CEDAR_TRANSCODE" ]; then
        echo "  cedar_transcode already built: $CEDAR_TRANSCODE"
    elif [ "$MODE" = "dev" ]; then
        echo "  Building cedar_transcode (CedarX HW transcode + RTP)..."
        if [ -f "$SCRIPT_DIR/cedar_transcode.c" ]; then
            gcc -O2 -o "$CEDAR_TRANSCODE" "$SCRIPT_DIR/cedar_transcode.c" \
                -lvdecoder -lvencoder -lcdc_base -lMemAdapter -lVE -lvideoengine -lpthread 2>&1
            if [ -f "$CEDAR_TRANSCODE" ]; then
                chmod +x "$CEDAR_TRANSCODE"
                echo "  cedar_transcode installed: $CEDAR_TRANSCODE"
            else
                echo "  WARNING: cedar_transcode build failed"
            fi
        else
            echo "  WARNING: cedar_transcode.c not found in $SCRIPT_DIR"
        fi
    elif [ -f "$SCRIPT_DIR/cedar_transcode" ]; then
        cp "$SCRIPT_DIR/cedar_transcode" "$CEDAR_TRANSCODE" && chmod +x "$CEDAR_TRANSCODE"
        echo "  cedar_transcode installed: $CEDAR_TRANSCODE"
    else
        echo "  WARNING: cedar_transcode not found. Build with --dev mode first."
    fi

    # Build custom ffmpeg with Allwinner OMX encoder support (hevc_omx).
    # Stock ffmpeg rejects Allwinner's proprietary color format 0x7f000002.
    # We patch libavcodec/omx.c to accept it and skip SPS/PPS pre-extraction
    # (Cedar provides headers after the first frame, not before).
    FFMPEG_OMX="/usr/local/bin/ffmpeg_omx"
    if [ -f "$FFMPEG_OMX" ]; then
        echo "  Custom ffmpeg_omx already built: $FFMPEG_OMX"
    elif [ "$MODE" = "dev" ]; then
        echo "  Building custom ffmpeg with Allwinner OMX encoder..."
        FFMPEG_VER="4.3.9"
        FFMPEG_BUILD="/tmp/ffmpeg-${FFMPEG_VER}"

        # Install OMX headers if missing
        if ! find /usr/include -name "OMX_Core.h" 2>/dev/null | grep -q .; then
            apt-get install -y libomxil-bellagio-dev 2>/dev/null || true
        fi

        # Download fresh source (always clean to avoid double-patching)
        rm -rf "$FFMPEG_BUILD"
        echo "    Downloading ffmpeg ${FFMPEG_VER}..."
        cd /tmp
        wget -q "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz"
        tar xf "ffmpeg-${FFMPEG_VER}.tar.xz"
        rm -f "ffmpeg-${FFMPEG_VER}.tar.xz"

        # Patch omx.c: accept Allwinner color format 0x7f000002
        sed -i 's/video_port_format.eColorFormat == OMX_COLOR_FormatYUV420PackedPlanar)/video_port_format.eColorFormat == OMX_COLOR_FormatYUV420PackedPlanar || video_port_format.eColorFormat == 0x7f000002)/' \
            "$FFMPEG_BUILD/libavcodec/omx.c"

        # Patch omx.c: skip SPS/PPS extraction (Cedar provides after first frame)
        sed -i 's/if (avctx->flags & AV_CODEC_FLAG_GLOBAL_HEADER) {/if (0 \&\& avctx->flags \& AV_CODEC_FLAG_GLOBAL_HEADER) { \/* Cedar: skip *\//' \
            "$FFMPEG_BUILD/libavcodec/omx.c"

        # Patch omx.c: add HEVC/H.265 OMX encoder support
        OMX_C="$FFMPEG_BUILD/libavcodec/omx.c"

        # 1) Define OMX_VIDEO_CodingHEVC if not in headers (Allwinner uses value 7)
        sed -i '/#include <OMX_Component.h>/a \
#ifndef OMX_VIDEO_CodingHEVC\n#define OMX_VIDEO_CodingHEVC 7\n#endif' "$OMX_C"

        # 2) Add HEVC role in the codec switch
        sed -i '/case AV_CODEC_ID_H264:/{n;s|role = "video_encoder.avc";|role = "video_encoder.avc";\n        break;\n    case AV_CODEC_ID_HEVC:\n        role = "video_encoder.hevc";|;}' "$OMX_C"

        # 3) Add HEVC compression format for output port
        sed -i 's|out_port_params.format.video.eCompressionFormat = OMX_VIDEO_CodingAVC;|out_port_params.format.video.eCompressionFormat = OMX_VIDEO_CodingAVC;\n    else if (avctx->codec->id == AV_CODEC_ID_HEVC)\n        out_port_params.format.video.eCompressionFormat = OMX_VIDEO_CodingHEVC;|' "$OMX_C"

        # 4) Append HEVC encoder codec definition at end of omx.c
        cat >> "$OMX_C" << 'HEVC_EOF'

static const AVClass omx_hevcenc_class = {
    .class_name = "hevc_omx",
    .item_name  = av_default_item_name,
    .option     = options,
    .version    = LIBAVUTIL_VERSION_INT,
};
AVCodec ff_hevc_omx_encoder = {
    .name             = "hevc_omx",
    .long_name        = NULL_IF_CONFIG_SMALL("OpenMAX IL HEVC video encoder"),
    .type             = AVMEDIA_TYPE_VIDEO,
    .id               = AV_CODEC_ID_HEVC,
    .priv_data_size   = sizeof(OMXCodecContext),
    .init             = omx_encode_init,
    .encode2          = omx_encode_frame,
    .close            = omx_encode_end,
    .pix_fmts         = omx_encoder_pix_fmts,
    .capabilities     = AV_CODEC_CAP_DELAY,
    .caps_internal    = FF_CODEC_CAP_INIT_THREADSAFE | FF_CODEC_CAP_INIT_CLEANUP,
    .priv_class       = &omx_hevcenc_class,
};
HEVC_EOF

        # 5) Register HEVC encoder in allcodecs.c
        sed -i '/extern AVCodec ff_h264_omx_encoder;/a extern AVCodec ff_hevc_omx_encoder;' \
            "$FFMPEG_BUILD/libavcodec/allcodecs.c"

        # 6) Allwinner OMX core doesn't register video_encoder.hevc role,
        #    so find_component returns empty. Add direct fallback in find_component.
        sed -i '/static av_cold int find_component/,/GetComponentsOfRole.*role.*\&num/{
            /GetComponentsOfRole.*role.*\&num/i\
    /* Allwinner: HEVC encoder has no registered role */\
    if (!strcmp(role, "video_encoder.hevc")) {\
        av_strlcpy(str, "OMX.allwinner.video.encoder.hevc", str_size);\
        return 0;\
    }
        }' "$OMX_C"

        # Configure and build (static ffmpeg libs, dynamic glibc for dlopen/OMX)
        cd "$FFMPEG_BUILD"
        ./configure \
            --prefix=/usr/local \
            --enable-gpl --enable-omx \
            --enable-static --disable-shared \
            --disable-doc \
            --quiet 2>&1 | tail -3

        make -j"$(nproc)" 2>&1 | tail -3

        # Install as ffmpeg_omx (don't overwrite system ffmpeg)
        cp ffmpeg "$FFMPEG_OMX"
        chmod +x "$FFMPEG_OMX"

        # Cleanup
        cd "$SCRIPT_DIR"
        rm -rf "$FFMPEG_BUILD"

        echo "  Custom ffmpeg installed: $FFMPEG_OMX"
    elif [ -f "$SCRIPT_DIR/ffmpeg_omx" ]; then
        echo "  Installing ffmpeg_omx from package..."
        cp "$SCRIPT_DIR/ffmpeg_omx" "$FFMPEG_OMX"
        chmod +x "$FFMPEG_OMX"
        echo "  Custom ffmpeg installed: $FFMPEG_OMX"
    else
        echo "  WARNING: $FFMPEG_OMX not found. Build with --dev mode first."
    fi
fi

# mediamtx — lightweight RTSP server (needed for RTSP output mode)
MEDIAMTX="/usr/local/bin/mediamtx"
if [ -f "$MEDIAMTX" ]; then
    echo "  mediamtx already installed: $MEDIAMTX"
elif [ "$MODE" = "dev" ]; then
    echo "  Downloading mediamtx (RTSP server)..."
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64) MTX_ARCH="arm64v8" ;;
        armv7l)  MTX_ARCH="armv7" ;;
        x86_64)  MTX_ARCH="amd64" ;;
        *)       MTX_ARCH="$ARCH" ;;
    esac
    MTX_VER="1.11.3"
    MTX_URL="https://github.com/bluenviron/mediamtx/releases/download/v${MTX_VER}/mediamtx_v${MTX_VER}_linux_${MTX_ARCH}.tar.gz"
    if curl -sL "$MTX_URL" | tar xz -C /tmp mediamtx 2>/dev/null && [ -f /tmp/mediamtx ]; then
        cp /tmp/mediamtx "$MEDIAMTX"
        chmod +x "$MEDIAMTX"
        rm -f /tmp/mediamtx
        echo "  mediamtx installed: $MEDIAMTX"
    else
        echo "  WARNING: mediamtx download failed (RTSP output won't work)"
    fi
elif [ -f "$SCRIPT_DIR/mediamtx" ]; then
    echo "  Installing mediamtx from package..."
    cp "$SCRIPT_DIR/mediamtx" "$MEDIAMTX"
    chmod +x "$MEDIAMTX"
    echo "  mediamtx installed: $MEDIAMTX"
else
    echo "  NOTE: mediamtx not found (optional — needed for RTSP output)"
fi

echo "  Done."

# ── Step 2: Platform-specific configuration ──

STEP=2
NEED_REBOOT=0

echo ""
echo "[$STEP/$TOTAL] Platform-specific configuration..."

if [ "$PLATFORM" = "pi" ]; then
    # Pi: check dwc2 overlay
    CONFIG_FILE=""
    for f in /boot/firmware/config.txt /boot/config.txt; do
        [ -f "$f" ] && CONFIG_FILE="$f" && break
    done

    if [ -n "$CONFIG_FILE" ]; then
        ALL_HAS_DWC2=0
        in_all=0
        while IFS= read -r line; do
            case "$line" in
                \[all\]*) in_all=1 ;;
                \[*\]*)   in_all=0 ;;
                dtoverlay=dwc2*)
                    if [ $in_all -eq 1 ]; then ALL_HAS_DWC2=1; fi
                    ;;
            esac
        done < "$CONFIG_FILE"
        while IFS= read -r line; do
            case "$line" in
                \[*\]*) break ;;
                dtoverlay=dwc2*) ALL_HAS_DWC2=1 ;;
            esac
        done < "$CONFIG_FILE"

        if [ $ALL_HAS_DWC2 -eq 1 ]; then
            echo "  dtoverlay=dwc2 already configured"
        else
            echo "  Adding dtoverlay=dwc2 to $CONFIG_FILE"
            echo "" >> "$CONFIG_FILE"
            echo "# DJI Goggles — OTG mode switch" >> "$CONFIG_FILE"
            echo "dtoverlay=dwc2" >> "$CONFIG_FILE"
            NEED_REBOOT=1
        fi
    else
        echo "  WARNING: config.txt not found. Add dtoverlay=dwc2 manually."
    fi

elif [ "$PLATFORM" = "a733" ]; then
    # Allwinner A733: check dwc3 / MUSB + usb_role_switch
    if [ -d /sys/class/usb_role ]; then
        ROLE_DIR=$(ls -d /sys/class/usb_role/*-role-switch 2>/dev/null | head -1)
        if [ -n "$ROLE_DIR" ]; then
            echo "  USB role switch found: $ROLE_DIR"
        else
            echo "  WARNING: No usb_role_switch device found."
            echo "  Check your device tree configuration."
        fi
    else
        echo "  WARNING: /sys/class/usb_role not found."
        echo "  Ensure USB OTG and usb_role_switch are enabled in device tree."
    fi

    # Check for DWC3 or MUSB driver
    if [ -d /sys/bus/platform/drivers/dwc3 ]; then
        echo "  DWC3 driver loaded"
    elif [ -d /sys/bus/platform/drivers/musb-sunxi ]; then
        echo "  MUSB (sunxi) driver loaded"
    else
        echo "  WARNING: No USB OTG driver (dwc3/musb) found"
    fi

    # Blacklist android_usb gadget (same issue as Rockchip)
    BLACKLIST="/etc/modprobe.d/blacklist-android-usb.conf"
    if [ ! -f "$BLACKLIST" ]; then
        echo "  Blacklisting android_usb module (causes kernel crash with configfs)..."
        cat > "$BLACKLIST" << 'BEOF'
# DJI Video Stream: android_usb conflicts with configfs gadget
blacklist g_android
blacklist android_usb
BEOF
        rmmod g_android 2>/dev/null || true
        rmmod android_usb 2>/dev/null || true
        echo "  Done"
    else
        echo "  android_usb already blacklisted"
    fi

    # Enable SPI1 spidev overlay
    SPI_DTBO="/boot/dtbo/sun60iw2p1-spi1-spidev.dtbo"
    if [ -c /dev/spidev1.0 ]; then
        echo "  SPI1 already enabled (/dev/spidev1.0)"
    else
        # Rename .disabled overlay if needed
        if [ ! -f "$SPI_DTBO" ] && [ -f "${SPI_DTBO}.disabled" ]; then
            echo "  Enabling SPI1 overlay (renaming .disabled)..."
            mv "${SPI_DTBO}.disabled" "$SPI_DTBO"
        fi
        if [ -f "$SPI_DTBO" ]; then
            echo "  Running u-boot-update to apply SPI1 overlay..."
            u-boot-update
            echo "  SPI1 overlay enabled (reboot required)"
            NEED_REBOOT=1
        else
            echo "  WARNING: SPI1 overlay not found at $SPI_DTBO"
            echo "  Run 'sudo rsetup' -> Overlays to enable SPI1 manually"
        fi
    fi

    # Enable USB 2.0 Type-C host mode overlay (for USB Ethernet adapter)
    USB2_DTBO="/boot/dtbo/cubie-a7z-usb2-host-mode.dtbo"
    USB2_DTS="$SCRIPT_DIR/usb0-setup/cubie-a7z-usb2-host-mode.dts"
    if [ -f "$USB2_DTBO" ]; then
        echo "  USB2 host mode overlay already installed"
    elif [ -f "${USB2_DTBO}.disabled" ]; then
        echo "  Enabling USB2 host mode overlay (renaming .disabled)..."
        mv "${USB2_DTBO}.disabled" "$USB2_DTBO"
        echo "  Running u-boot-update to apply USB2 host mode overlay..."
        u-boot-update
        echo "  USB2 host mode overlay enabled (reboot required)"
        NEED_REBOOT=1
    elif [ -f "$USB2_DTS" ]; then
        echo "  Compiling USB2 host mode overlay from source..."
        TMP_PRE=$(mktemp)
        TMP_DTBO=$(mktemp)
        cpp -nostdinc -undef -x assembler-with-cpp -E \
            -I "/usr/src/linux-headers-$(uname -r)/include" \
            -I "/usr/lib/modules/$(uname -r)/build/include" \
            "$USB2_DTS" "$TMP_PRE" 2>/dev/null || cp "$USB2_DTS" "$TMP_PRE"
        if dtc -q -@ -I dts -O dtb -o "$TMP_DTBO" "$TMP_PRE" 2>/dev/null; then
            cp "$TMP_DTBO" "$USB2_DTBO"
            chmod 644 "$USB2_DTBO"
            echo "  Running u-boot-update to apply USB2 host mode overlay..."
            u-boot-update
            echo "  USB2 host mode overlay enabled (reboot required)"
            NEED_REBOOT=1
        else
            echo "  WARNING: Failed to compile USB2 host mode overlay (dtc not found?)"
        fi
        rm -f "$TMP_PRE" "$TMP_DTBO"
    else
        echo "  WARNING: USB2 host mode overlay not found"
        echo "  Copy usb0-setup/ directory or install manually via rsetup"
    fi

    # Enable PD 9V source overlay (ET7304 TCPC — adds 9V PDO to source-pdos)
    PD9V_DTBO="/boot/dtbo/cubie-a7z-pd-9v-source.dtbo"
    PD9V_DTS="$SCRIPT_DIR/usb0-setup/cubie-a7z-pd-9v-source.dts"
    if [ -f "$PD9V_DTBO" ]; then
        echo "  PD 9V source overlay already installed"
    elif [ -f "${PD9V_DTBO}.disabled" ]; then
        echo "  Enabling PD 9V source overlay (renaming .disabled)..."
        mv "${PD9V_DTBO}.disabled" "$PD9V_DTBO"
        echo "  Running u-boot-update to apply PD 9V overlay..."
        u-boot-update
        echo "  PD 9V source overlay enabled (reboot required)"
        NEED_REBOOT=1
    elif [ -f "$PD9V_DTS" ]; then
        echo "  Compiling PD 9V source overlay from source..."
        TMP_PRE=$(mktemp)
        TMP_DTBO=$(mktemp)
        cpp -nostdinc -undef -x assembler-with-cpp -E \
            -I "/usr/src/linux-headers-$(uname -r)/include" \
            -I "/usr/lib/modules/$(uname -r)/build/include" \
            "$PD9V_DTS" "$TMP_PRE" 2>/dev/null || cp "$PD9V_DTS" "$TMP_PRE"
        if dtc -q -@ -I dts -O dtb -o "$TMP_DTBO" "$TMP_PRE" 2>/dev/null; then
            cp "$TMP_DTBO" "$PD9V_DTBO"
            chmod 644 "$PD9V_DTBO"
            echo "  Running u-boot-update to apply PD 9V overlay..."
            u-boot-update
            echo "  PD 9V source overlay enabled (reboot required)"
            NEED_REBOOT=1
        else
            echo "  WARNING: Failed to compile PD 9V overlay (dtc not found?)"
        fi
        rm -f "$TMP_PRE" "$TMP_DTBO"
    else
        echo "  WARNING: PD 9V source overlay not found"
        echo "  Copy usb0-setup/cubie-a7z-pd-9v-source.dts to build it"
    fi

elif [ "$PLATFORM" = "rk3399" ] || [ "$PLATFORM" = "rk3576" ] || [ "$PLATFORM" = "rk3588" ]; then
    # Rockchip: check dwc3 + usb_role_switch
    if [ -d /sys/class/usb_role ]; then
        ROLE_DIR=$(ls -d /sys/class/usb_role/*-role-switch 2>/dev/null | head -1)
        if [ -n "$ROLE_DIR" ]; then
            echo "  USB role switch found: $ROLE_DIR"
        else
            echo "  WARNING: No usb_role_switch device found."
            echo "  Check your device tree configuration."
        fi
    else
        echo "  WARNING: /sys/class/usb_role not found."
        echo "  Ensure dwc3 driver and usb_role_switch are enabled in device tree."
    fi

    # Check for DWC3 driver
    if [ -d /sys/bus/platform/drivers/dwc3 ]; then
        echo "  DWC3 driver loaded"
    else
        echo "  WARNING: DWC3 driver not found"
    fi

    # FUSB302 PD source overlay (RK3588 — Orange Pi 5/5+)
    # Sets try-power-role=source so the FUSB302 driver presents Rp on CC,
    # allowing DJI goggles to charge from an external VBUS supply.
    if [ "$PLATFORM" = "rk3588" ]; then
        FUSB_DTBO="/boot/dtb/rockchip/overlay/rockchip-rk3588-fusb302-source.dtbo"
        FUSB_OVERLAY_NAME="fusb302-source"

        if [ -f "$FUSB_DTBO" ]; then
            echo "  FUSB302 source overlay already installed"
        else
            # Find FUSB302 node in device tree
            # /proc/device-tree find doesn't always work, so also check
            # dmesg and known paths for RK3588
            FUSB_NODE=""
            for try_path in \
                /proc/device-tree/i2c@fec80000/fusb302@22 \
                /proc/device-tree/i2c@feac0000/fusb302@22 \
                /proc/device-tree/i2c@fea90000/fusb302@22; do
                if [ -d "$try_path" ]; then
                    FUSB_NODE="$try_path"
                    break
                fi
            done
            # Fallback: extract path from dmesg
            if [ -z "$FUSB_NODE" ]; then
                DMESG_PATH=$(dmesg 2>/dev/null | grep -o '/i2c@[^/]*/fusb302@22' | head -1)
                if [ -n "$DMESG_PATH" ] && [ -d "/proc/device-tree${DMESG_PATH}" ]; then
                    FUSB_NODE="/proc/device-tree${DMESG_PATH}"
                fi
            fi
            if [ -n "$FUSB_NODE" ]; then
                DT_PATH=$(echo "$FUSB_NODE" | sed 's|/proc/device-tree||')
                echo "  FUSB302 found at DT path: $DT_PATH"
                echo "  Generating PD source overlay (try-power-role=source)..."

                TMP_DTS=$(mktemp --suffix=.dts)
                TMP_DTBO=$(mktemp --suffix=.dtbo)
                cat > "$TMP_DTS" << FDTS
/dts-v1/;
/plugin/;

/ {
	fragment@0 {
		target-path = "${DT_PATH}/connector";
		__overlay__ {
			source-pdos = <0x2201912C 0x0002D12C>;
			try-power-role = "source";
		};
	};
};
FDTS
                if dtc -q -@ -I dts -O dtb -o "$TMP_DTBO" "$TMP_DTS" 2>/dev/null; then
                    mkdir -p "$(dirname "$FUSB_DTBO")"
                    cp "$TMP_DTBO" "$FUSB_DTBO"
                    chmod 644 "$FUSB_DTBO"
                    echo "  Compiled overlay to $FUSB_DTBO"

                    # Add to armbianEnv.txt overlays
                    ARMBIAN_ENV_CHECK="/boot/armbianEnv.txt"
                    if [ -f "$ARMBIAN_ENV_CHECK" ]; then
                        if ! grep -q "$FUSB_OVERLAY_NAME" "$ARMBIAN_ENV_CHECK"; then
                            if grep -q "^overlays=" "$ARMBIAN_ENV_CHECK"; then
                                sed -i "s|^overlays=\(.*\)|overlays=\1 ${FUSB_OVERLAY_NAME}|" "$ARMBIAN_ENV_CHECK"
                            else
                                echo "overlays=$FUSB_OVERLAY_NAME" >> "$ARMBIAN_ENV_CHECK"
                            fi
                            echo "  Added $FUSB_OVERLAY_NAME to armbianEnv.txt"
                        fi
                    fi
                    NEED_REBOOT=1
                    echo "  FUSB302 source overlay enabled (reboot required)"
                else
                    echo "  WARNING: Failed to compile FUSB302 overlay (dtc not found?)"
                fi
                rm -f "$TMP_DTS" "$TMP_DTBO"
            else
                echo "  FUSB302 not found in device tree — skipping PD overlay"
            fi
        fi
    fi

    # Blacklist android_usb gadget — its ep0 delegate (android_setup)
    # races with FunctionFS and crashes the kernel on DWC3 controllers
    BLACKLIST="/etc/modprobe.d/blacklist-android-usb.conf"
    if [ ! -f "$BLACKLIST" ]; then
        echo "  Blacklisting android_usb module (causes kernel crash with configfs)..."
        cat > "$BLACKLIST" << 'BEOF'
# DJI Video Stream: android_usb conflicts with configfs gadget on DWC3
blacklist g_android
blacklist android_usb
BEOF
        # Unload if currently loaded
        rmmod g_android 2>/dev/null || true
        rmmod android_usb 2>/dev/null || true
        echo "  Done"
    else
        echo "  android_usb already blacklisted"
    fi

    # Platform-specific SPI overlay
    ARMBIAN_ENV="/boot/armbianEnv.txt"
    SPI_OVERLAY_NAME=""
    SPI_DTS_CONTENT=""

    if [ "$PLATFORM" = "rk3588" ]; then
        MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')
        if echo "$MODEL" | grep -qi "orange pi 5 plus"; then
            SPI_OVERLAY_NAME="spi4-m2-cs0-spidev"
            SPI_DTS_CONTENT="/dts-v1/;
/plugin/;

/ {
	fragment@0 {
		target-path = \"/spi@fecb0000\";
		__overlay__ {
			status = \"okay\";
			#address-cells = <1>;
			#size-cells = <0>;
			pinctrl-names = \"default\";
			pinctrl-0 = <&spi4m2_pins &spi4m2_cs0>;

			spidev@0 {
				compatible = \"armbian,spi-dev\";
				reg = <0>;
				spi-max-frequency = <10000000>;
			};
		};
	};
};"
        else
            SPI_OVERLAY_NAME="spi4-m0-cs1-spidev"
            SPI_DTS_CONTENT="/dts-v1/;
/plugin/;

/ {
	fragment@0 {
		target-path = \"/spi@fecb0000\";
		__overlay__ {
			status = \"okay\";
			#address-cells = <1>;
			#size-cells = <0>;
			pinctrl-names = \"default\";
			pinctrl-0 = <&spi4m0_pins &spi4m0_cs1>;

			spidev@1 {
				compatible = \"armbian,spi-dev\";
				reg = <1>;
				spi-max-frequency = <10000000>;
			};
		};
	};
};"
        fi
    elif [ "$PLATFORM" = "rk3399" ]; then
        SPI_OVERLAY_NAME="spi-spidev"
    fi

    if [ -n "$SPI_OVERLAY_NAME" ] && [ -f "$ARMBIAN_ENV" ]; then
        OVERLAY_PREFIX=$(grep "^overlay_prefix=" "$ARMBIAN_ENV" 2>/dev/null | cut -d= -f2)
        if [ -n "$OVERLAY_PREFIX" ]; then
            SPI_DTBO_FILE="${OVERLAY_PREFIX}-${SPI_OVERLAY_NAME}.dtbo"
        else
            SPI_DTBO_FILE="${SPI_OVERLAY_NAME}.dtbo"
        fi
        SPI_DTBO_PATH="/boot/dtb/rockchip/overlay/${SPI_DTBO_FILE}"

        if grep -q "$SPI_OVERLAY_NAME" "$ARMBIAN_ENV"; then
            echo "  SPI overlay ($SPI_OVERLAY_NAME) already in $ARMBIAN_ENV"
        else
            # Check if dtbo exists on disk
            if [ ! -f "$SPI_DTBO_PATH" ] && [ -n "$SPI_DTS_CONTENT" ]; then
                echo "  Compiling SPI overlay ($SPI_OVERLAY_NAME)..."
                TMP_DTS=$(mktemp --suffix=.dts)
                TMP_DTBO=$(mktemp --suffix=.dtbo)
                echo "$SPI_DTS_CONTENT" > "$TMP_DTS"
                if dtc -q -@ -I dts -O dtb -o "$TMP_DTBO" "$TMP_DTS" 2>/dev/null; then
                    mkdir -p "$(dirname "$SPI_DTBO_PATH")"
                    cp "$TMP_DTBO" "$SPI_DTBO_PATH"
                    chmod 644 "$SPI_DTBO_PATH"
                    echo "  Compiled overlay to $SPI_DTBO_PATH"
                else
                    echo "  WARNING: Failed to compile SPI overlay (dtc not found?)"
                fi
                rm -f "$TMP_DTS" "$TMP_DTBO"
            fi

            if [ -f "$SPI_DTBO_PATH" ]; then
                if grep -q "^overlays=" "$ARMBIAN_ENV"; then
                    sed -i "s|^overlays=\(.*\)|overlays=\1 ${SPI_OVERLAY_NAME}|" "$ARMBIAN_ENV"
                    echo "  Added $SPI_OVERLAY_NAME to existing overlays line"
                else
                    echo "overlays=$SPI_OVERLAY_NAME" >> "$ARMBIAN_ENV"
                    echo "  Added overlays=$SPI_OVERLAY_NAME to $ARMBIAN_ENV"
                fi
                NEED_REBOOT=1
            else
                echo "  WARNING: ${SPI_DTBO_FILE} not found — skipping"
            fi
        fi
    elif [ -n "$SPI_OVERLAY_NAME" ]; then
        echo "  WARNING: $ARMBIAN_ENV not found — skipping SPI overlay"
    fi
else
    echo "  WARNING: Unknown platform. Manual USB configuration may be needed."
fi

echo "  Done."

# ── Step 3: Build libusb (dev mode only) ──

STEP=3
echo ""
echo "[$STEP/$TOTAL] libusb..."

if [ "$MODE" = "dev" ]; then
    if [ -f "$LIBUSB_DIR/lib/libusb-1.0.a" ]; then
        echo "  Already built, skipping."
    else
        echo "  Building libusb $LIBUSB_VER (static, no udev)..."
        cd /tmp
        wget -q "https://github.com/libusb/libusb/releases/download/v${LIBUSB_VER}/libusb-${LIBUSB_VER}.tar.bz2"
        tar xf "libusb-${LIBUSB_VER}.tar.bz2"
        cd "libusb-${LIBUSB_VER}"
        ./configure --enable-static --disable-shared --disable-udev \
            --prefix="$LIBUSB_DIR" --quiet
        make -j"$(nproc)" --quiet
        make install --quiet
        cd "$SCRIPT_DIR"
        rm -rf "/tmp/libusb-${LIBUSB_VER}" "/tmp/libusb-${LIBUSB_VER}.tar.bz2"
        echo "  Installed to $LIBUSB_DIR"
    fi
else
    echo "  Skipped (prod mode)"
fi

# ── Step 4: Build binary (dev mode) / Verify binary (prod mode) ──

STEP=4
echo ""
echo "[$STEP/$TOTAL] Binary..."

if [ "$MODE" = "dev" ]; then
    # Replace Makefile if Makefile.new exists
    if [ -f "$SCRIPT_DIR/Makefile.new" ]; then
        cp "$SCRIPT_DIR/Makefile.new" "$SCRIPT_DIR/Makefile"
        echo "  Updated Makefile"
    fi

    MAKE_ARGS=""
    if [ "$LICENSE_CHECK" = "1" ]; then
        MAKE_ARGS="LICENSE_CHECK=1"
        echo "  Building $BINARY with LICENSE CHECK (web + embed + static)..."
    else
        echo "  Building $BINARY (web + embed + static binary)..."
    fi
    make -f Makefile.new clean 2>/dev/null || true
    make -f Makefile.new full $MAKE_ARGS
    echo ""
    file "$BINARY"
    ls -lh "$BINARY"

    if ldd "$BINARY" 2>&1 | grep -q "not a dynamic"; then
        echo "  OK: Binary is fully static"
    else
        echo "  Note: Binary has dynamic dependencies"
    fi
else
    if [ -f "$SCRIPT_DIR/$BINARY" ]; then
        echo "  Binary found: $BINARY"
        chmod +x "$SCRIPT_DIR/$BINARY"
    else
        echo "  ERROR: $BINARY not found!"
        echo "  Build it first with: sudo bash setup.sh --dev"
        echo "  Or copy the binary from a dev machine."
        exit 1
    fi
fi

# ── Step 5: systemd service ──

STEP=5
echo ""
echo "[$STEP/$TOTAL] systemd service..."

INSTALL_DIR="/opt/dji_stream"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"

# Stop existing service before overwriting binary (avoids "Text file busy")
if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    echo "  Stopping existing $SERVICE..."
    systemctl stop "$SERVICE"
    sleep 1
    killall -9 "$BINARY" cedar_enc ffmpeg 2>/dev/null || true
    sleep 1
fi

# Install binary
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/$BINARY" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/$BINARY"

# Write service file
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=DJI Video Stream
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/$BINARY
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=5
StartLimitIntervalSec=0
TimeoutStopSec=10
KillMode=mixed
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
echo "  Service installed, enabled and started: $SERVICE"
echo "  View logs:         journalctl -u $SERVICE -f"

# ── Create install package for deploying to other boards ──

if [ "$MODE" = "dev" ]; then
    ARCH=$(uname -m)
    PKG_DIR="$SCRIPT_DIR/install-package"
    rm -rf "$PKG_DIR"
    mkdir -p "$PKG_DIR"

    # Core binary (static, includes embedded web UI)
    cp "$SCRIPT_DIR/$BINARY" "$PKG_DIR/"

    # Custom ffmpeg_omx if built (A733 only)
    if [ -f /usr/local/bin/ffmpeg_omx ]; then
        cp /usr/local/bin/ffmpeg_omx "$PKG_DIR/"
    fi

    # CedarX native encoder (A733 only)
    if [ -f /usr/local/bin/cedar_enc ]; then
        cp /usr/local/bin/cedar_enc "$PKG_DIR/"
    fi

    # GStreamer MPP plugin (RK3588/RK3576 — for boards without apt package)
    GST_PLUGIN_DIR=$(pkg-config --variable=pluginsdir gstreamer-1.0 2>/dev/null || echo "/usr/lib/aarch64-linux-gnu/gstreamer-1.0")
    if [ -f "$GST_PLUGIN_DIR/libgstrockchipmpp.so" ]; then
        cp "$GST_PLUGIN_DIR/libgstrockchipmpp.so" "$PKG_DIR/"
    fi

    # CedarX HW transcoder (A733 only)
    if [ -f /usr/local/bin/cedar_transcode ]; then
        cp /usr/local/bin/cedar_transcode "$PKG_DIR/"
    fi

    # mediamtx RTSP server
    if [ -f /usr/local/bin/mediamtx ]; then
        cp /usr/local/bin/mediamtx "$PKG_DIR/"
    fi

    # Setup script and install guide
    cp "$SCRIPT_DIR/setup.sh" "$PKG_DIR/"
    # Include quick start guide (renamed to README for visibility)
    if [ -f "$SCRIPT_DIR/QUICKSTART.md" ]; then
        cp "$SCRIPT_DIR/QUICKSTART.md" "$PKG_DIR/README.md"
    elif [ -f "$SCRIPT_DIR/INSTALL.md" ]; then
        cp "$SCRIPT_DIR/INSTALL.md" "$PKG_DIR/README.md"
    fi

    # One-line installer
    cat > "$PKG_DIR/install.sh" << 'IEOF'
#!/bin/bash
set -e
cd "$(dirname "$0")"
if [ "$(id -u)" -ne 0 ]; then echo "Run as root: sudo bash install.sh"; exit 1; fi
exec bash setup.sh --prod
IEOF
    chmod +x "$PKG_DIR/install.sh"

    # Create tarball
    PKG_TAR="$SCRIPT_DIR/dji_stream-${ARCH}.tar.gz"
    tar czf "$PKG_TAR" -C "$SCRIPT_DIR" install-package/
    rm -rf "$PKG_DIR"

    PKG_SIZE=$(du -h "$PKG_TAR" | cut -f1)
    echo ""
    echo "  Install package: $PKG_TAR ($PKG_SIZE)"
    echo "  Deploy to another board:"
    echo "    scp $PKG_TAR user@board:/tmp/"
    echo "    ssh user@board 'cd /tmp && tar xzf dji_stream-${ARCH}.tar.gz && cd install-package && sudo bash setup.sh --prod'"
fi

# ── Done ──

echo ""
echo "========================================"
echo "  Setup complete!"
echo "========================================"

if [ $NEED_REBOOT -eq 1 ]; then
    echo ""
    echo "  *** REBOOT REQUIRED for overlay changes! ***"
    echo "  Run: sudo reboot"
fi

echo ""
echo "  Binary: $INSTALL_DIR/$BINARY"
echo ""
echo "  Usage:"
echo "    sudo $INSTALL_DIR/$BINARY                    # Start with web UI on :8080"
echo "    sudo $INSTALL_DIR/$BINARY --no-web           # Stream to stdout (pipe to ffmpeg)"
echo "    sudo $INSTALL_DIR/$BINARY --port 9090        # Custom web port"
echo ""
echo "  Web UI: http://<board-ip>:8080"
echo ""
