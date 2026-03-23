# gpio-service

GPIO service for the Orange Pi 5B. Manages physical button inputs, power cutoff output, and a servo-driven DJI power button via hardware PWM.

## Architecture

- **`gpioctl/`** -- reusable Python library for GPIO pin management (gpiod v2) and hardware PWM (sysfs). Not board-specific.
- **`app.py`** -- board-specific application: registers pins, defines handlers, runs the REST API.
- **`config.yaml`** -- tunables (API port, servo duty cycles, PWM device).
- **`gpio.service`** -- systemd unit.

## Pin mapping (OPI5B 26-pin header, `/dev/gpiochip4`)

| Function      | GPIO chip line | Header pin | Direction |
|---------------|----------------|------------|-----------|
| Power button  | 4 (GPIO4_A4)   | 8          | Input     |
| Power cutoff  | 3 (GPIO4_A3)   | 6          | Output    |

PWM: `pwm13_m2` (overlay `rockchip-rk3588-pwm13-m2`) drives a servo that presses the DJI power button.

## REST API

Listens on `127.0.0.1` only (not network-accessible). Port is set in `config.yaml`.

```
POST /power_cycle_dji   -- press 1s, release 2s, press 3s, release
POST /pair_dji          -- press 5s, release
GET  /health            -- returns {"status": "ok"}
```

Returns `409 Conflict` if another action is already in progress.

## Install

On the device:

```bash
sudo ./install.sh
```

This creates a venv at `/opt/gpio-service/`, installs dependencies, copies files, and enables the systemd unit.

The `pwm13-m2` device tree overlay must be enabled in `/boot/armbianEnv.txt`:

```
overlays=pwm13-m2
```

A reboot is required after adding the overlay.

## Development

From the dev machine, deploy to the board:

```bash
rsync -avz gpio-service/ root@<board-ip>:/tmp/gpio-service-staging/
ssh root@<board-ip> 'cd /tmp/gpio-service-staging && bash install.sh'
```

## Configuration

Edit `config.yaml` (installed at `/opt/gpio-service/config.yaml`):

```yaml
api:
  port: 9010

servo:
  pwm_device: "febf0010"
  pwm_channel: 0
  frequency_hz: 50
  pressed_us: 2000.0
  released_us: 1900.0
```

Restart the service after changes: `sudo systemctl restart gpio.service`

## Logs

```bash
journalctl -u gpio.service -f
```
