#!/usr/bin/env python3
"""
GPIO application for Orange Pi 5.

Pin mapping (OPI5B 26-pin header, /dev/gpiochip4):
  line 4 = GPIO4_A4 = header pin 8  -> power button input
  line 3 = GPIO4_A3 = header pin 6  -> power cutoff output

PWM:
  pwm13_m2 -> servo controlling DJI power button

REST API (localhost only):
  POST /power_cycle_dji
  POST /pair_dji
"""

import json
import logging
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
servo_cfg = cfg.get("servo", {})

# ---------------------------------------------------------------------------
# GPIO + servo setup
# ---------------------------------------------------------------------------

ctl = GpioCtl(chip="/dev/gpiochip4")

power_cutoff = ctl.output(line=3, name="power_cutoff")

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


def power_cycle_dji() -> None:
    """Press, wait 1s, release, wait 2s, press 3s, release."""
    servo.configure(SERVO_PERIOD_NS)
    _servo_released()
    servo.enable()

    log.info("power_cycle_dji: press (1s)")
    _servo_pressed()
    time.sleep(1)

    log.info("power_cycle_dji: release (2s)")
    _servo_released()
    time.sleep(2)

    log.info("power_cycle_dji: press (3s)")
    _servo_pressed()
    time.sleep(3)

    log.info("power_cycle_dji: release (done)")
    _servo_released()


def pair_dji() -> None:
    """Press, wait 5s, release."""
    servo.configure(SERVO_PERIOD_NS)
    _servo_released()
    servo.enable()

    log.info("pair_dji: press (5s)")
    _servo_pressed()
    time.sleep(5)

    log.info("pair_dji: release (done)")
    _servo_released()


# ---------------------------------------------------------------------------
# REST API (localhost only)
# ---------------------------------------------------------------------------

_ACTIONS: dict[str, callable] = {
    "/power_cycle_dji": power_cycle_dji,
    "/pair_dji": pair_dji,
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


# ---------------------------------------------------------------------------
# GPIO handlers
# ---------------------------------------------------------------------------

@ctl.input(line=4, name="power_button", bias="as_is", edge="rising", debounce_ms=150)
def on_power_button(event):
    event.pin.logger.info("Power button pressed")
    power_cycle_dji()
    time.sleep(5)
    event.pin.logger.info("Power cutoff")
    power_cutoff.set(True)


if __name__ == "__main__":
    _start_api_server()
    ctl.run()
