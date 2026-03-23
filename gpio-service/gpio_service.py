#!/usr/bin/env python3
"""
GPIO service: power-button input (rising edge) and power-cutoff output.

Extra buttons: open another GPIO, append a ``ButtonInput`` to ``inputs``, and add
``--other-line`` / env as needed. ``GPIO.poll_multiple`` waits on all inputs together.

More roles (PWM, etc.) can be added here as the project grows.

Deploy and run on the board (install deps there; GPIO devices are not available on a dev PC).

Line numbers are offsets on the given gpiochip (see `gpioinfo` on the device), not
header pin numbers unless you map them yourself.
"""

from __future__ import annotations

import argparse
import logging
import os
import signal
import sys
import time
from dataclasses import dataclass
from typing import Callable

from periphery import GPIO, GPIOError

_LOG = logging.getLogger("gpio-service")


class InputDebouncer:
    """Drop edges on an input line that occur too soon after the previous accepted edge."""

    __slots__ = ("_debounce_sec", "_last_accept")

    def __init__(self, debounce_sec: float) -> None:
        self._debounce_sec = max(0.0, debounce_sec)
        self._last_accept: float | None = None

    def accept(self) -> bool:
        if self._debounce_sec <= 0:
            return True
        now = time.monotonic()
        if self._last_accept is not None and (now - self._last_accept) < self._debounce_sec:
            return False
        self._last_accept = now
        return True


@dataclass(frozen=True)
class ButtonInput:
    """One digital input line (e.g. a button) with its own debouncer and callback."""

    name: str
    gpio: GPIO
    debouncer: InputDebouncer
    on_event: Callable[[], None]


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--chip",
        default=os.environ.get("GPIO_CHIP", "/dev/gpiochip0"),
        help="GPIO character device (default: %(default)s or env GPIO_CHIP)",
    )
    p.add_argument(
        "--power-button-line",
        type=int,
        default=int(os.environ.get("GPIO_POWER_BUTTON_LINE", "0")),
        metavar="N",
        help="Power button: input line offset (env GPIO_POWER_BUTTON_LINE)",
    )
    p.add_argument(
        "--power-cutoff-line",
        type=int,
        default=int(os.environ.get("GPIO_POWER_CUTOFF_LINE", "1")),
        metavar="N",
        help="Power cutoff: output line offset (env GPIO_POWER_CUTOFF_LINE)",
    )
    p.add_argument(
        "--poll-interval",
        type=float,
        default=1.0,
        metavar="SEC",
        help="Seconds for poll timeout (allows clean shutdown; default: %(default)s)",
    )
    p.add_argument(
        "--debounce-ms",
        type=float,
        default=float(os.environ.get("GPIO_DEBOUNCE_MS", "25")),
        metavar="MS",
        help="Ignore edges on an input < this many ms after the prior accepted edge "
        "(0 = off; env GPIO_DEBOUNCE_MS; default: %(default)s)",
    )
    return p.parse_args()


def _setup_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stdout,
    )


def _on_power_button_press(power_cutoff: GPIO) -> None:
    _LOG.info("power button: rising edge, running handler")
    time.sleep(5)
    power_cutoff.write(True)
    _LOG.info("power cutoff: line driven high")


def main() -> int:
    _setup_logging()
    args = _parse_args()

    stop = False

    def _stop(*_a: object) -> None:
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    debounce_sec = args.debounce_ms / 1000.0

    _LOG.info(
        "starting: chip=%s power_button_line=%s power_cutoff_line=%s debounce_ms=%s",
        args.chip,
        args.power_button_line,
        args.power_cutoff_line,
        args.debounce_ms,
    )

    power_button = None
    power_cutoff = None
    try:
        power_button = GPIO(args.chip, args.power_button_line, "in", edge="rising")
        power_cutoff = GPIO(args.chip, args.power_cutoff_line, "out")
    except GPIOError as e:
        _LOG.error("failed to open GPIO: %s", e)
        return 1

    # Add another ButtonInput (and GPIO) here for each extra button; all share debounce_ms.
    inputs: list[ButtonInput] = [
        ButtonInput(
            name="power_button",
            gpio=power_button,
            debouncer=InputDebouncer(debounce_sec),
            on_event=lambda: _on_power_button_press(power_cutoff),
        ),
    ]

    try:
        power_cutoff.write(False)

        while not stop:
            gpios = [inp.gpio for inp in inputs]
            ready = GPIO.poll_multiple(gpios, timeout=args.poll_interval)
            if not ready:
                continue
            for g in ready:
                inp = next((i for i in inputs if i.gpio is g), None)
                if inp is None:
                    continue
                try:
                    inp.gpio.read_event()
                except GPIOError as e:
                    _LOG.warning("read_event %s: %s", inp.name, e)
                    continue
                if not inp.debouncer.accept():
                    continue
                inp.on_event()
    except GPIOError as e:
        _LOG.error("GPIO error: %s", e)
        return 1
    finally:
        for inp in inputs:
            inp.gpio.close()
        if power_cutoff is not None:
            power_cutoff.close()

    _LOG.info("shutdown complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
