"""GpioCtl -- register GPIO pins and run an event loop dispatching edge callbacks."""

from __future__ import annotations

import logging
import select
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import timedelta
from typing import Callable

import gpiod
from gpiod.line import Bias, Direction, Edge, Value

from gpioctl.pins import InputPin, OutputPin, PinEvent
from gpioctl.pwm import HwPwmPin

_LOG = logging.getLogger("gpioctl")

_BIAS_MAP: dict[str, Bias] = {
    "as_is": Bias.AS_IS,
    "pull_up": Bias.PULL_UP,
    "pull_down": Bias.PULL_DOWN,
    "disabled": Bias.DISABLED,
}

_EDGE_MAP: dict[str, Edge] = {
    "rising": Edge.RISING,
    "falling": Edge.FALLING,
    "both": Edge.BOTH,
}


@dataclass
class _InputCfg:
    pin: InputPin
    bias: str
    edge: str
    debounce_ms: int
    handler: Callable[[PinEvent], None]


@dataclass
class _OutputCfg:
    pin: OutputPin
    initial: bool


class GpioCtl:
    """Register GPIO pins and run an event loop dispatching edge callbacks.

    Usage::

        ctl = GpioCtl(chip="/dev/gpiochip4")
        led = ctl.output(line=3, name="led")

        @ctl.input(line=4, bias="pull_down", edge="rising", debounce_ms=150)
        def on_button(event):
            led.toggle()

        ctl.run()
    """

    def __init__(
        self,
        chip: str = "/dev/gpiochip0",
        consumer: str = "gpioctl",
        max_workers: int = 4,
    ) -> None:
        self._chip = chip
        self._consumer = consumer
        self._max_workers = max_workers
        self._inputs: dict[int, _InputCfg] = {}
        self._outputs: dict[int, _OutputCfg] = {}
        self._pwms: list[HwPwmPin] = []
        self._stop = threading.Event()

    # -- registration (call before run) ----------------------------------------

    def output(
        self, line: int, name: str | None = None, initial: bool = False
    ) -> OutputPin:
        """Register an output pin. Returns an :class:`OutputPin` handle."""
        name = name or f"out_{line}"
        self._check_line_free(line)
        pin = OutputPin(name=name, line=line)
        self._outputs[line] = _OutputCfg(pin=pin, initial=initial)
        return pin

    def input(
        self,
        line: int,
        name: str | None = None,
        bias: str = "as_is",
        edge: str = "rising",
        debounce_ms: int = 0,
    ) -> Callable:
        """Decorator: register an input pin with an edge handler.

        The decorated function receives a :class:`PinEvent` and runs in a
        worker thread so it may block freely.
        """
        if bias not in _BIAS_MAP:
            raise ValueError(f"Invalid bias {bias!r}, expected one of {list(_BIAS_MAP)}")
        if edge not in _EDGE_MAP:
            raise ValueError(f"Invalid edge {edge!r}, expected one of {list(_EDGE_MAP)}")

        def decorator(handler: Callable[[PinEvent], None]) -> Callable[[PinEvent], None]:
            pin_name = name or handler.__name__
            self._check_line_free(line)
            pin = InputPin(name=pin_name, line=line)
            self._inputs[line] = _InputCfg(
                pin=pin,
                bias=bias,
                edge=edge,
                debounce_ms=debounce_ms,
                handler=handler,
            )
            return handler

        return decorator

    def pwm(
        self, chip: int, channel: int = 0, name: str | None = None
    ) -> HwPwmPin:
        """Register a hardware PWM channel (sysfs). Returns an :class:`HwPwmPin` handle."""
        pin = HwPwmPin(chip=chip, channel=channel, name=name)
        self._pwms.append(pin)
        return pin

    # -- lifecycle -------------------------------------------------------------

    def run(self) -> None:
        """Build the gpiod request and enter the event loop. Blocks until stop."""
        if not self._inputs and not self._outputs:
            raise RuntimeError("No pins registered")

        config = self._build_line_config()

        _LOG.info(
            "starting: chip=%s inputs=[%s] outputs=[%s]",
            self._chip,
            ", ".join(f"{c.pin.name}(line={ln})" for ln, c in self._inputs.items()),
            ", ".join(f"{c.pin.name}(line={ln})" for ln, c in self._outputs.items()),
        )

        try:
            with gpiod.request_lines(
                self._chip, consumer=self._consumer, config=config
            ) as request:
                self._bind_all(request)
                self._event_loop(request)
        finally:
            for p in self._pwms:
                p.close()
            self._unbind_all()

        _LOG.info("shutdown complete")

    def stop(self) -> None:
        """Signal the event loop to exit."""
        _LOG.info("stop requested")
        self._stop.set()

    # -- internals -------------------------------------------------------------

    def _check_line_free(self, line: int) -> None:
        if line in self._inputs or line in self._outputs:
            raise ValueError(f"Line {line} already registered")

    def _build_line_config(self) -> dict[int, gpiod.LineSettings]:
        config: dict[int, gpiod.LineSettings] = {}

        for line, cfg in self._outputs.items():
            config[line] = gpiod.LineSettings(
                direction=Direction.OUTPUT,
                output_value=Value.ACTIVE if cfg.initial else Value.INACTIVE,
            )

        for line, cfg in self._inputs.items():
            kwargs: dict = dict(
                direction=Direction.INPUT,
                edge_detection=_EDGE_MAP[cfg.edge],
                bias=_BIAS_MAP[cfg.bias],
            )
            if cfg.debounce_ms > 0:
                kwargs["debounce_period"] = timedelta(milliseconds=cfg.debounce_ms)
            config[line] = gpiod.LineSettings(**kwargs)

        return config

    def _bind_all(self, request: gpiod.LineRequest) -> None:
        for cfg in self._outputs.values():
            cfg.pin._bind(request)
        for cfg in self._inputs.values():
            cfg.pin._bind(request)

    def _unbind_all(self) -> None:
        for cfg in self._outputs.values():
            cfg.pin._request = None
        for cfg in self._inputs.values():
            cfg.pin._request = None

    def _event_loop(self, request: gpiod.LineRequest) -> None:
        poller = select.poll()
        poller.register(request.fd, select.POLLIN)

        with ThreadPoolExecutor(max_workers=self._max_workers) as pool:
            while not self._stop.is_set():
                ready = poller.poll(1000)
                if not ready:
                    continue
                for event in request.read_edge_events():
                    cfg = self._inputs.get(event.line_offset)
                    if cfg is None:
                        continue
                    edge_str = (
                        "rising"
                        if event.event_type == gpiod.EdgeEvent.Type.RISING_EDGE
                        else "falling"
                    )
                    pin_event = PinEvent(
                        pin=cfg.pin,
                        edge=edge_str,
                        timestamp_ns=event.timestamp_ns,
                    )
                    cfg.pin.logger.debug("edge: %s", edge_str)
                    pool.submit(self._run_handler, cfg.handler, pin_event)

    @staticmethod
    def _run_handler(handler: Callable, event: PinEvent) -> None:
        try:
            handler(event)
        except Exception:
            event.pin.logger.exception("handler %r failed", handler.__name__)
