#!/usr/bin/env python3
"""
GPIO application for Orange Pi 5.

Pin mapping (OPI5B 26-pin header, /dev/gpiochip4):
  line 4 = GPIO4_A4 = header pin 8  -> power button input
  line 3 = GPIO4_A3 = header pin 6  -> power cutoff output

Additional GPIO output:
  /dev/gpiochip1 line 14 = GPIO1_B6 -> dji_pwr_btn

PWM:
  pwm13_m2 -> servo controlling DJI power button

REST API (localhost only):
  POST /power_cycle_dji
  POST /pair_dji
  POST /cancel_pair_dji

Boot (config.yaml boot.power_cycle_dji): optional automatic power_cycle_dji on service start.
"""

import json
import logging
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import yaml

from gpioctl import GpioCtl, find_pwmchip

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

_DEFAULT_CONFIG = Path(__file__).parent / "config.yaml"

def _load_config(path: Path) -> dict:
    with open(path) as f:
        cfg = yaml.safe_load(f)
    log.info("loaded config from %s", path)
    return cfg


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    stream=sys.stdout,
)

log = logging.getLogger("app")

config_path = Path(sys.argv[1]) if len(sys.argv) > 1 else _DEFAULT_CONFIG
cfg = _load_config(config_path)

api_cfg = cfg.get("api", {})
boot_cfg = cfg.get("boot", {})
servo_cfg = cfg.get("servo", {})
dji_pwr_btn_cfg = cfg.get("dji_pwr_btn", {})

# ---------------------------------------------------------------------------
# GPIO + servo setup
# ---------------------------------------------------------------------------

ctl = GpioCtl(chip="/dev/gpiochip4")
dji_ctl = GpioCtl(chip=str(dji_pwr_btn_cfg.get("chip", "/dev/gpiochip1")))

power_cutoff = ctl.output(line=3, name="power_cutoff")
# Direct drive of the DJI button line; kept in sync with the servo and always used together.
dji_pwr_btn = dji_ctl.output(
    line=int(dji_pwr_btn_cfg.get("line", 14)),
    name="dji_pwr_btn",
    initial=False,
)

SERVO_PERIOD_NS = int(1_000_000_000 / float(servo_cfg.get("frequency_hz", 50)))
SERVO_PRESSED_US = float(servo_cfg.get("pressed_us", 2000.0))
SERVO_RELEASED_US = float(servo_cfg.get("released_us", 1900.0))

servo_chip = find_pwmchip(servo_cfg.get("pwm_device", "febf0010"))
servo = ctl.pwm(
    chip=servo_chip,
    channel=int(servo_cfg.get("pwm_channel", 0)),
    name="dji_servo",
)

# ---------------------------------------------------------------------------
# Servo actions
# ---------------------------------------------------------------------------

_servo_lock = threading.Lock()


def _servo_pressed() -> None:
    servo.set_duty_us(SERVO_PRESSED_US)


def _servo_released() -> None:
    servo.set_duty_us(SERVO_RELEASED_US)


def press_dji_pwr_btn() -> None:
    # Press the physical button with the servo and assert the direct button line together.
    _servo_pressed()
    dji_pwr_btn.set(True)


def release_dji_pwr_btn() -> None:
    # Release the physical button with the servo and deassert the direct button line together.
    _servo_released()
    dji_pwr_btn.set(False)


def power_cycle_dji() -> None:
    """Release, then press 0.1s, release, wait 0.5s, press 2s, release."""
    release_dji_pwr_btn()

    log.info("power_cycle_dji: press (0.1s)")
    press_dji_pwr_btn()
    time.sleep(0.1)

    log.info("power_cycle_dji: release, then wait 0.5s")
    release_dji_pwr_btn()
    time.sleep(0.5)

    log.info("power_cycle_dji: press (2s)")
    press_dji_pwr_btn()
    time.sleep(2)

    log.info("power_cycle_dji: release (done)")
    release_dji_pwr_btn()


def pair_dji() -> None:
    """Press, wait 5s, release."""
    release_dji_pwr_btn()

    log.info("pair_dji: press (5s)")
    press_dji_pwr_btn()
    time.sleep(5)

    log.info("pair_dji: release (done)")
    release_dji_pwr_btn()


def cancel_pair_dji() -> None:
    """Short press: press, wait 0.2s, release."""
    release_dji_pwr_btn()

    log.info("cancel_pair_dji: press (0.2s)")
    press_dji_pwr_btn()
    time.sleep(0.2)

    log.info("cancel_pair_dji: release (done)")
    release_dji_pwr_btn()


# ---------------------------------------------------------------------------
# REST API (localhost only)
# ---------------------------------------------------------------------------

_ACTIONS: dict[str, callable] = {
    "/power_cycle_dji": power_cycle_dji,
    "/pair_dji": pair_dji,
    "/cancel_pair_dji": cancel_pair_dji,
}


class _ApiHandler(BaseHTTPRequestHandler):

    def do_POST(self):
        action = _ACTIONS.get(self.path)
        if action is None:
            self._json(404, {"error": "not found"})
            return
        if not _servo_lock.acquire(blocking=False):
            self._json(409, {"error": "busy", "message": "another action is in progress"})
            return
        try:
            action()
            self._json(200, {"status": "done", "action": self.path.lstrip("/")})
        except Exception as exc:
            log.exception("action %s failed", self.path)
            self._json(500, {"error": str(exc)})
        finally:
            _servo_lock.release()

    def do_GET(self):
        if self.path == "/health":
            self._json(200, {"status": "ok"})
            return
        self._json(404, {"error": "not found"})

    def _json(self, code: int, body: dict) -> None:
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        log.info("api: " + fmt, *args)


def _start_api_server() -> None:
    port = int(api_cfg.get("port", 8080))
    server = ThreadingHTTPServer(("127.0.0.1", port), _ApiHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    log.info("REST API listening on 127.0.0.1:%d", port)


_BOOT_STAMP = Path("/tmp/gpio-service.booted")


def _start_boot_power_cycle() -> None:
    """Run power_cycle_dji once per boot (skipped on service restart)."""
    if not boot_cfg.get("power_cycle_dji", False):
        return
    if _BOOT_STAMP.exists():
        log.info("boot: stamp exists, skipping power_cycle_dji (service restart)")
        return
    _BOOT_STAMP.touch()

    delay = float(boot_cfg.get("delay_sec") or 0)

    def _job() -> None:
        if delay > 0:
            log.info("boot: delay %.1fs before power_cycle_dji", delay)
            time.sleep(delay)
        _servo_lock.acquire()
        try:
            log.info("boot: power_cycle_dji")
            power_cycle_dji()
        finally:
            _servo_lock.release()

    threading.Thread(target=_job, name="boot-power-cycle-dji", daemon=True).start()


# ---------------------------------------------------------------------------
# GPIO handlers
# ---------------------------------------------------------------------------

@ctl.input(line=4, name="power_button", bias="pull_up", edge="falling", debounce_ms=150)
def on_power_button(event):
    event.pin.logger.info("Power button pressed")
    power_cycle_dji()
    time.sleep(5)
    event.pin.logger.info("Power cutoff")
    power_cutoff.set(True)


def _shutdown(*_):
    ctl.stop()
    dji_ctl.stop()


def main() -> None:
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    dji_thread = threading.Thread(target=dji_ctl.run, daemon=True, name="dji-pwr-btn")
    dji_thread.start()
    time.sleep(0.1)

    servo.configure(SERVO_PERIOD_NS)
    servo.enable()
    release_dji_pwr_btn()

    try:
        _start_api_server()
        _start_boot_power_cycle()
        ctl.run()
    finally:
        dji_ctl.stop()
        dji_thread.join(timeout=1)


if __name__ == "__main__":
    main()
