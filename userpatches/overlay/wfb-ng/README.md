# WFB-NG (WiFi Broadcast Next Generation)

Long-range packet radio link for FPV, based on raw WiFi injection.
Installed on this device with the **svpcom rtl8812au** driver for the
Alfa AWUS036ACH (RTL8812AU chipset).

---

## Quick reference

| Item | Path / value |
|------|-------------|
| Main config | `/etc/wifibroadcast.cfg` |
| Master (default) config | `/usr/lib/python3/dist-packages/wfb_ng/conf/master.cfg` |
| Interface env file | `/etc/default/wifibroadcast` |
| Key directory | `/etc` (`gs.key`, `drone.key`) |
| WiFi interface | `wfb0` (renamed via udev rule) |
| Systemd service (GS) | `wifibroadcast@gs` |
| Systemd service (drone) | `wifibroadcast@drone` |
| CLI stats tool | `wfb-cli gs` or `wfb-cli drone` |

---

## First-run setup

### 1. Generate encryption keys

Keys must be generated once and shared between the ground station and drone.
Run on the ground station:

```
cd /etc
wfb_keygen
```

This creates two files:

- `gs.key` — used by the ground station
- `drone.key` — used by the drone

Copy `drone.key` to the drone:

```
scp /etc/drone.key root@<drone-ip>:/etc/drone.key
```

Both devices must have matching key pairs or the link will not establish.

### 2. Choose a role

Each device runs as either **gs** (ground station) or **drone**.
Enable the appropriate service:

```
# Ground station
systemctl enable wifibroadcast@gs
systemctl start wifibroadcast@gs

# Drone
systemctl enable wifibroadcast@drone
systemctl start wifibroadcast@drone
```

### 3. Set the WiFi channel

Both sides **must** use the same channel. Edit `/etc/wifibroadcast.cfg`:

```ini
[common]
wifi_channel = 165
```

Common 5 GHz channels: 36, 40, 44, 48, 149, 153, 157, 161, **165**.
Channel 165 (5825 MHz, 20 MHz width) is the most common choice for FPV.

After changing, restart the service:

```
systemctl restart wifibroadcast@gs   # or @drone
```

---

## Configuration — `/etc/wifibroadcast.cfg`

This file overrides the defaults from the master config.
Only the sections and keys you include will override; everything else
falls back to the master defaults.

### `[common]` — shared settings

```ini
[common]
wifi_channel = 165        # radio channel (must match on both sides)
wifi_region = 'BO'        # regulatory domain (BO = Bolivia, allows all 5 GHz channels)
wifi_txpower = -1000      # TX power for 8812au: -dBm * 100 (see TX power section)
```

### Stream architecture

WFB-NG provides three built-in communication channels(serial is extra), each mapped to
a pair of radio stream IDs:

| Channel | Drone TX stream | GS TX stream | Type | Description |
|---------|-----------------|--------------|------|-------------|
| **video** | `0x00` (0) | — | `udp_direct_tx` | One-way, drone to GS |
| **mavlink** | `0x10` (16) | `0x90` (144) | `mavlink` | Two-way, validates mavlink framing |
| **tunnel** | `0x20` (32) | `0xa0` (160) | `tunnel` | Two-way, IP over WiFi Broadcast |
| **serial** | `0x30` (48) | `0xb0` (176) | `udp_proxy` | Two-way, raw bytes (no parsing) |

---

## Channels in detail

### Video (drone → GS only)

One-way UDP stream. The drone captures video and sends it; the GS receives it.

**Drone config:**

```ini
[drone_video]
peer = 'listen://0.0.0.0:5602'    # drone listens for video input on UDP 5602
```

Feed video into this port from a local camera/encoder, e.g. GStreamer or ffmpeg
piping H.264/H.265 to `udp://127.0.0.1:5602`.

**GS config:**

```ini
[gs_video]
peer = 'connect://127.0.0.1:5600' # GS sends received video to UDP 5600
```

Point your video player/decoder at `udp://127.0.0.1:5600`.

**FEC defaults:** K=8, N=12 (8 data + 4 parity packets per block).

### Mavlink (bidirectional)

Two-way mavlink telemetry and command link. Supports frame aggregation
and validates mavlink framing.

**Drone config:**

```ini
[drone_mavlink]
peer = 'listen://0.0.0.0:14560'        # flight controller connects here (UDP)
# peer = 'serial:/dev/ttyS2:115200'    # or use UART directly
```

**GS config:**

```ini
[gs_mavlink]
peer = 'connect://127.0.0.1:14550'     # GS sends telemetry to QGroundControl
# peer = 'listen://0.0.0.0:14550'      # alternative: QGC connects to this port
```

**Peer types:**

| Peer URI | Behavior |
|----------|----------|
| `listen://host:port` | Binds a UDP socket; waits for a client to send first |
| `connect://host:port` | Sends data to the given address |
| `serial:/dev/ttyXX:baud` | Direct UART connection (mavlink only) |

**FEC defaults:** K=1, N=2 (every packet is duplicated for redundancy).

**OSD mirroring:** To mirror mavlink to an OSD application, add to `[gs_mavlink]`:

```ini
osd = 'connect://127.0.0.1:14551'
```

### Raw serial / UDP proxy (bidirectional)

A raw bidirectional UDP pipe with no protocol parsing. Use this for
serial-over-Ethernet bridges or any data that is not mavlink-formatted.
Unlike the mavlink channel, this passes all bytes unmodified.

To add a raw serial channel, append a stream to the `[drone]` and `[gs]`
top-level profiles in `/etc/wifibroadcast.cfg`:

**Drone config:**

```ini
[drone]
streams = [...,
           {'name': 'serial', 'stream_rx': 0xb0, 'stream_tx': 0x30,
            'service_type': 'udp_proxy',
            'profiles': ['base', 'drone_base', 'radio_base'],
            'peer': 'listen://0.0.0.0:7000'}]
```

The drone listens on UDP 7000. Your serial-to-Ethernet bridge sends data here.

**GS config:**

```ini
[gs]
streams = [...,
           {'name': 'serial', 'stream_rx': 0x30, 'stream_tx': 0xb0,
            'service_type': 'udp_proxy',
            'profiles': ['base', 'gs_base', 'radio_base'],
            'peer': 'connect://127.0.0.1:7001'}]
```

The GS forwards received serial data to UDP 7001, and sends data received
from port 7001 back over the air to the drone.

**Important:** You cannot simply add these to `wifibroadcast.cfg` as
separate sections — they must be appended to the existing `streams` list
in the `[drone]` and `[gs]` top-level profiles. To do this, override the
full `[drone]` or `[gs]` section in your config (copy from the master
config and add the new stream entry).

**FEC defaults (from `radio_base`):** K=1, N=2 (every packet duplicated).

**Why not use the mavlink channel?** The mavlink channel uses
`MavlinkUDPProxyProtocol` which parses and validates mavlink framing. Raw
serial bytes that are not valid mavlink frames are silently discarded.

### IP tunnel (bidirectional)

Creates a virtual network interface for arbitrary IP traffic over the radio link.

**Drone:**

```ini
[drone_tunnel]
ifname = 'drone-wfb'
ifaddr = '10.5.0.2/24'
```

**GS:**

```ini
[gs_tunnel]
ifname = 'gs-wfb'
ifaddr = '10.5.0.1/24'
```

Once the link is up, `ping 10.5.0.2` from GS (or vice versa) works.
You can SSH, transfer files, or run any IP-based protocol over this tunnel.

---

## TX power

The svpcom rtl8812au driver uses a special convention for TX power values.

### Setting TX power

In `/etc/wifibroadcast.cfg`:

```ini
[common]
wifi_txpower = -1000   # 10 dBm
```

**Formula for 8812au:** value = **-(dBm × 100)**

| Desired power | Config value | Approx. mW |
|---------------|-------------|-------------|
| 1 dBm | `-100` | ~1 mW |
| 5 dBm | `-500` | ~3 mW |
| 10 dBm | `-1000` | ~10 mW |
| 18 dBm | `-1800` | ~63 mW |
| 20 dBm | `-2000` | ~100 mW |
| 25 dBm | `-2500` | ~316 mW |
| 27 dBm | `-2700` | ~500 mW |

> **Note:** The AWUS036ACH maxes out around 27 dBm (~500 mW).
> Use a heatsink at power levels above 20 dBm for sustained operation.

### Runtime override (not persistent)

```
iw dev wfb0 set txpower fixed 1000   # 10 dBm in mBm (1000 mBm)
```

### Per-card TX power

```ini
wifi_txpower = {'wfb0': -1000, 'wlan1': 'off'}   # 'off' = RX-only card
```

### Thermal guidelines

| Chip temp | Status |
|-----------|--------|
| < 50 °C | Normal |
| 50–65 °C | Warm, fine for sustained use |
| 65–75 °C | Add passive heatsink recommended |
| > 75 °C | Active cooling recommended |
| > 85 °C | Risk of throttling / damage |

---

## Video stream

The video channel is a raw UDP pipe — WFB-NG is codec-agnostic. You send
UDP packets to port 5602 on the drone, and they come out on port 5600 on the GS.

**Supported formats (anything you can push over UDP):**

| Format | Notes |
|--------|-------|
| H.264 (RTP) | Most common for FPV. Use `tune=zerolatency` for low latency. |
| H.265 / HEVC (RTP) | ~50% less bandwidth for same quality, slightly higher encode latency |
| MJPEG | High bandwidth, but zero inter-frame dependency |
| Raw RTP | Anything GStreamer/ffmpeg can produce |
| MPEG-TS | More resilient to packet loss than bare RTP |

**Bandwidth budget:** With defaults (MCS 1, 20 MHz, FEC 8/12), usable video
bandwidth is roughly **8–9 Mbps**. Comfortable for:

- H.264 1080p 30fps (~4–6 Mbps)
- H.264 720p 60fps (~3–5 Mbps)
- H.265 1080p 30fps (~2–4 Mbps)

**Example drone-side pipeline (camera → H.264 → wfb-ng):**

```bash
gst-launch-1.0 v4l2src device=/dev/video0 ! \
  video/x-raw,width=1920,height=1080,framerate=30/1 ! \
  v4l2h264enc extra-controls="controls,repeat_sequence_header=1" ! \
  'video/x-h264,level=(string)4' ! \
  rtph264pay ! udpsink host=127.0.0.1 port=5602
```

**Example GS-side pipeline (wfb-ng → decode → display):**

```bash
gst-launch-1.0 udpsrc port=5600 ! application/x-rtp ! \
  rtph264depay ! avdec_h264 ! autovideosink sync=false
```

---

## Radio settings

Configured in `/etc/wifibroadcast.cfg`. Defaults are in the `[base]` profile
and apply to all streams. Override per-stream by adding the key to a specific
section (e.g. `[drone_video]`).

```ini
[base]
bandwidth = 20       # 20 or 40 MHz (20 MHz minimum, no narrower)
mcs_index = 1        # MCS rate index (higher = more throughput, less range)
stbc = 1             # space-time block coding streams (0–3)
ldpc = 1             # low-density parity check FEC (0 or 1)
short_gi = False     # short guard interval
```

To override MCS only for video (leaving mavlink/tunnel at the default):

```ini
[drone_video]
mcs_index = 3
```

**MCS index vs. throughput (20 MHz, long GI, 1 spatial stream):**

| MCS | Modulation | Data rate | Range |
|-----|-----------|-----------|-------|
| 0 | BPSK 1/2 | 6.5 Mbps | Best |
| 1 | QPSK 1/2 | 13 Mbps | Good (default) |
| 2 | QPSK 3/4 | 19.5 Mbps | Moderate |
| 3 | 16-QAM 1/2 | 26 Mbps | Reduced |
| 4 | 16-QAM 3/4 | 39 Mbps | Short |

Lower MCS = more range and reliability. MCS 1 is a good default for FPV.

---

## FEC (Forward Error Correction)

Each stream has independent FEC settings. Defaults are in the per-stream
profile sections of the master config. Override them in `/etc/wifibroadcast.cfg`
by adding the same section and keys — your values replace the defaults.

```ini
fec_k = 8    # data packets per FEC block
fec_n = 12   # total packets per FEC block (data + parity)
```

**Defaults:**

| Stream | K | N | Parity | Effect |
|--------|---|---|--------|--------|
| Video | 8 | 12 | 4 | Can lose 4 of 12 packets per block |
| Mavlink | 1 | 2 | 1 | Every packet sent twice |
| Tunnel | 1 | 2 | 1 | Every packet sent twice |

**Override example** — increase video redundancy:

```ini
[video]
fec_k = 4
fec_n = 8
```

Higher N/K ratio = more redundancy = more bandwidth used = less usable throughput.

---

## Useful commands

```bash
# Check link status and statistics
wfb-cli gs
wfb-cli drone

# Service management
systemctl status wifibroadcast@gs
systemctl restart wifibroadcast@drone
journalctl -u wifibroadcast@gs -f       # live logs

# Check WiFi interface
iw dev wfb0 info                         # channel, txpower, type
iw dev wfb0 station dump                 # connected stations (empty in monitor mode)

# Generate new keys
cd /etc && wfb_keygen
```

---

## Installed components

| Component | Description |
|-----------|-------------|
| `wfb-ng` package | Core wfb-ng server, CLI, and tools from `apt.wfb-ng.org` |
| `88XXau_wfb` kernel module | svpcom patched rtl8812au driver (DKMS) |
| `/etc/udev/rules.d/70-wfb-ng.rules` | Renames WiFi interface to `wfb0` |
| `/etc/modprobe.d/wfb.conf` | Blacklists conflicting drivers (rtw88, etc.) |
| `/etc/sysctl.d/90-wfb-ng.conf` | Enables BPF JIT for performance |
| `/etc/NetworkManager/conf.d/wfb-unmanaged.conf` | Excludes `wfb0` from NetworkManager |
| `/etc/default/wifibroadcast` | Sets `WFB_NICS="wfb0"` |

---

## Troubleshooting

**Interface not found:**
Check that the USB adapter is connected and the driver loaded:
```
lsmod | grep 88XXau
ip link show wfb0
```

**Link not establishing:**
- Both sides must use the same `wifi_channel` and `link_domain`
- Both sides must have matching key pairs (`gs.key` / `drone.key`)
- Check logs: `journalctl -u wifibroadcast@gs -f`

**"Message too long" errors:**
The svpcom driver supports MTU 4052. If you see this error, ensure the
in-kernel `rtw88_8812au` driver is not loaded instead:
```
lsmod | grep rtw88
```
It should return nothing. If loaded, check `/etc/modprobe.d/wfb.conf`.

**High packet loss:**
- Reduce `mcs_index` for more range
- Increase FEC redundancy (raise `fec_n` relative to `fec_k`)
- Check for interference on the selected channel
- Increase TX power if within thermal limits
