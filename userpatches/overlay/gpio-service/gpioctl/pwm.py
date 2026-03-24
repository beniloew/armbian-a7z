"""Hardware PWM via Linux sysfs (/sys/class/pwm/)."""

from __future__ import annotations

import logging
import time
from pathlib import Path

_SYSFS = Path("/sys/class/pwm")


def find_pwmchip(device_address: str) -> int:
    """Find pwmchip number whose device path contains *device_address*.

    Example: ``find_pwmchip("fd8b0010")`` finds the chip backed by
    the RK3588 PWM13 controller.
    """
    for entry in sorted(_SYSFS.iterdir()):
        if not entry.name.startswith("pwmchip"):
            continue
        try:
            device_name = (entry / "device").resolve().name
        except OSError:
            continue
        if device_address in device_name:
            return int(entry.name.removeprefix("pwmchip"))
    raise RuntimeError(
        f"No pwmchip found matching device address {device_address!r}. "
        f"Is the device-tree overlay enabled?"
    )


class HwPwmPin:
    """A single hardware PWM channel controlled through sysfs.

    Typical servo usage::

        servo = HwPwmPin(chip=1, channel=0, name="servo")
        servo.configure(period_ns=20_000_000)   # 50 Hz
        servo.set_duty_us(1500)                  # neutral
        servo.enable()
        ...
        servo.set_duty_us(2000)                  # move
        ...
        servo.close()                            # disable + unexport
    """

    def __init__(self, chip: int, channel: int = 0, name: str | None = None) -> None:
        self.chip = chip
        self.channel = channel
        self.name = name or f"pwm{chip}_{channel}"
        self.logger = logging.getLogger(f"gpioctl.{self.name}")
        self._chip_path = _SYSFS / f"pwmchip{chip}"
        self._ch_path = self._chip_path / f"pwm{channel}"
        self._exported = False

    def _export(self) -> None:
        if self._ch_path.exists():
            self._exported = True
            return
        (self._chip_path / "export").write_text(str(self.channel))
        deadline = time.monotonic() + 1.0
        while not self._ch_path.exists():
            if time.monotonic() > deadline:
                raise RuntimeError(f"Timeout waiting for {self._ch_path} after export")
            time.sleep(0.01)
        self._exported = True
        self.logger.debug("exported %s", self._ch_path)

    def _unexport(self) -> None:
        if not self._exported:
            return
        try:
            self.disable()
        except OSError:
            pass
        try:
            (self._chip_path / "unexport").write_text(str(self.channel))
        except OSError:
            pass
        self._exported = False

    def configure(
        self, period_ns: int, duty_ns: int = 0, polarity: str = "normal"
    ) -> None:
        """Export the channel (if needed) and set polarity, period + duty cycle.

        *polarity* must be ``"normal"`` or ``"inversed"``.  Polarity can only
        be changed while the channel is disabled, so this method disables first.
        """
        if not self._exported:
            self._export()
        try:
            self._write("enable", 0)
        except OSError:
            pass
        self._write_str("polarity", polarity)
        self._write("duty_cycle", 0)
        self._write("period", period_ns)
        if duty_ns:
            self._write("duty_cycle", duty_ns)
        self.logger.debug(
            "configured polarity=%s period=%d ns, duty=%d ns",
            polarity, period_ns, duty_ns,
        )

    def set_duty_ns(self, ns: int) -> None:
        self._write("duty_cycle", ns)

    def set_duty_us(self, us: float) -> None:
        self.set_duty_ns(int(us * 1000))

    def enable(self) -> None:
        if not self._exported:
            self._export()
        self._write("enable", 1)
        self.logger.debug("enabled")

    def disable(self) -> None:
        self._write("enable", 0)
        self.logger.debug("disabled")

    def close(self) -> None:
        """Disable and unexport."""
        self._unexport()

    def _write(self, attr: str, value: int) -> None:
        (self._ch_path / attr).write_text(str(value))

    def _write_str(self, attr: str, value: str) -> None:
        (self._ch_path / attr).write_text(value)

    def __repr__(self) -> str:
        return f"HwPwmPin({self.name!r}, chip={self.chip}, channel={self.channel})"
