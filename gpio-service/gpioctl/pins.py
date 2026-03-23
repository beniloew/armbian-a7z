"""Pin abstractions wrapping a gpiod v2 LineRequest."""

from __future__ import annotations

import logging
import threading
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import gpiod

from gpiod.line import Value


@dataclass(frozen=True)
class PinEvent:
    """Delivered to input handlers on a debounced edge."""

    pin: InputPin
    edge: str  # "rising" or "falling"
    timestamp_ns: int


class InputPin:
    """Read-only GPIO input pin."""

    __slots__ = ("name", "line", "logger", "_request")

    def __init__(self, name: str, line: int) -> None:
        self.name = name
        self.line = line
        self.logger = logging.getLogger(f"gpioctl.{name}")
        self._request: gpiod.LineRequest | None = None

    def _bind(self, request: gpiod.LineRequest) -> None:
        self._request = request

    def get(self) -> bool:
        """Current logic level (True = active/high)."""
        if self._request is None:
            raise RuntimeError(f"Pin {self.name!r} not bound (service not running)")
        return self._request.get_value(self.line) == Value.ACTIVE

    def __repr__(self) -> str:
        return f"InputPin({self.name!r}, line={self.line})"


class OutputPin:
    """Writable GPIO output pin. Thread-safe. PWM-ready."""

    __slots__ = ("name", "line", "logger", "_request", "_lock")

    def __init__(self, name: str, line: int) -> None:
        self.name = name
        self.line = line
        self.logger = logging.getLogger(f"gpioctl.{name}")
        self._request: gpiod.LineRequest | None = None
        self._lock = threading.Lock()

    def _bind(self, request: gpiod.LineRequest) -> None:
        self._request = request

    def _require_bound(self) -> gpiod.LineRequest:
        if self._request is None:
            raise RuntimeError(f"Pin {self.name!r} not bound (service not running)")
        return self._request

    def set(self, value: bool) -> None:
        """Set output level. Thread-safe."""
        req = self._require_bound()
        with self._lock:
            req.set_value(self.line, Value.ACTIVE if value else Value.INACTIVE)

    def get(self) -> bool:
        """Current output level (True = active/high)."""
        req = self._require_bound()
        return req.get_value(self.line) == Value.ACTIVE

    def toggle(self) -> bool:
        """Invert output and return new level. Thread-safe."""
        req = self._require_bound()
        with self._lock:
            cur = req.get_value(self.line)
            new = Value.INACTIVE if cur == Value.ACTIVE else Value.ACTIVE
            req.set_value(self.line, new)
            return new == Value.ACTIVE

    def __repr__(self) -> str:
        return f"OutputPin({self.name!r}, line={self.line})"
