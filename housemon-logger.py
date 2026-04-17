#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = [
#     "pyserial>=3.5",
# ]
# ///
"""
housemon-logger: RF12demo serial listener with daily log rotation.

Reads raw lines from an RF12demo-running JeeLink (or similar) over a serial
port, filters for `OK` and `?` frames, timestamps them, and appends them to a
daily log file. Each log line has the form:

    L <iso-utc-timestamp> <device-path> <raw-rf12demo-line>

Log files live under `<logdir>/YYYY/YYYYMMDD.txt` (UTC) and rotate
automatically at midnight because the target path is recomputed on every
packet. Writes are append-mode and opened-closed per packet, so no data sits
in a buffer on crash.

This script intentionally does **only** the logging. Shipping files off to
S3 / MinIO / etc. is handled by a separate systemd timer that runs `rclone
sync` against `<logdir>`. Keeping the logger network-free makes it smaller,
more reliable, and easier to isolate from network problems.
"""

import argparse
import logging
import os
import signal
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import serial

# ---------------------------------------------------------------------------
# Configuration constants
# ---------------------------------------------------------------------------

# RF12demo radio parameters baked in at the top of the file (not CLI args).
RF12_NODE_ID = 31
RF12_GROUP = 125
RF12_BAND = 8  # 1=433, 2=868, 3=915 -- 8 is what this install uses

# Timing knobs.
RECONNECT_DELAY = 5.0       # seconds between serial reconnect attempts
BANNER_TIMEOUT = 3.0        # seconds to wait for the RF12demo banner
SERIAL_READ_TIMEOUT = 1.0   # seconds per readline() so we can check signals
POST_OPEN_SETTLE = 0.5      # give the JeeLink time to (re)boot after DTR reset

# Defaults for CLI overrides.
DEFAULT_DEVICE = "/dev/ttyUSB0"
DEFAULT_BAUD = 57600
DEFAULT_LOGDIR = "~/housemon/logger"

log = logging.getLogger("housemon-logger")


# ---------------------------------------------------------------------------
# File path helpers
# ---------------------------------------------------------------------------

def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso_stamp(now: datetime) -> str:
    # Millisecond precision ISO 8601 with explicit Z suffix.
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"


def daily_path(logdir: Path, now: datetime) -> Path:
    return logdir / now.strftime("%Y") / (now.strftime("%Y%m%d") + ".txt")


def append_line(logdir: Path, now: datetime, line: str) -> None:
    """Append one log line. Opens and closes the file each call (no buffering)."""
    path = daily_path(logdir, now)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(line)
        if not line.endswith("\n"):
            f.write("\n")


# ---------------------------------------------------------------------------
# Serial listener
# ---------------------------------------------------------------------------

class SerialListener:
    """Owns the serial port, handles (re)connection, configuration and logging."""

    def __init__(self, device: str, baud: int, logdir: Path):
        self.device = device
        self.baud = baud
        self.logdir = logdir
        self._stop = threading.Event()

    def stop(self) -> None:
        self._stop.set()

    # -- main loop ----------------------------------------------------------

    def run(self) -> None:
        while not self._stop.is_set():
            ser = None
            try:
                log.info("opening serial %s @ %d", self.device, self.baud)
                ser = serial.Serial(self.device, self.baud, timeout=SERIAL_READ_TIMEOUT)
                self._force_reset(ser)
                if not self._configure(ser):
                    log.warning(
                        "RF12demo banner not confirmed within %.1fs "
                        "(adapter may not wire DTR to reset); packets should "
                        "still flow",
                        BANNER_TIMEOUT,
                    )
                self._read_loop(ser)
            except (serial.SerialException, OSError) as e:
                log.warning("serial error on %s: %s", self.device, e)
            finally:
                if ser is not None:
                    try:
                        ser.close()
                    except Exception:
                        pass
            if self._stop.is_set():
                break
            log.info("reconnecting in %.0fs", RECONNECT_DELAY)
            if self._stop.wait(RECONNECT_DELAY):
                break

    # -- helpers ------------------------------------------------------------

    def _force_reset(self, ser: serial.Serial) -> None:
        """
        Pulse DTR to force the JeeLink to reset so RF12demo re-emits its
        boot banner. Many USB-serial bridges (PL2303, CH340, some FTDIs)
        don't toggle DTR on port open, so we have to do it ourselves.

        Harmless if the adapter doesn't honour DTR control at all, or if the
        JeeLink isn't wired for reset-on-DTR -- _configure() just won't see
        the banner and logs its warning.
        """
        try:
            ser.dtr = False
            time.sleep(0.1)
            ser.dtr = True
        except (OSError, IOError) as e:
            log.debug("DTR toggle not supported (%s); skipping reset pulse", e)
        # Let RF12demo boot and start writing its banner to the serial port.
        time.sleep(POST_OPEN_SETTLE)

    def _configure(self, ser: serial.Serial) -> bool:
        """
        Read the `[RF12demo...]` banner (emitted by the device after the DTR
        reset that opening the port triggers), then push our RF12 config.
        Returns True if the banner was seen within BANNER_TIMEOUT, else False.

        NB: we read the banner BEFORE sending commands. The banner is a
        boot-time string, not a response to anything we send -- so draining
        the input buffer first would throw it away.
        """
        saw_banner = False
        deadline = time.monotonic() + BANNER_TIMEOUT
        while time.monotonic() < deadline:
            raw = ser.readline()
            if not raw:
                continue
            text = raw.decode(errors="replace").strip()
            if not text:
                continue
            if text.startswith("[RF12demo"):
                log.info("RF12demo ready: %s", text)
                saw_banner = True
                break

        for cmd in (
            f"{RF12_BAND}b",
            f"{RF12_GROUP}g",
            f"{RF12_NODE_ID}i",
        ):
            ser.write(cmd.encode() + b"\r\n")
            ser.flush()
            time.sleep(0.05)

        return saw_banner

    def _read_loop(self, ser: serial.Serial) -> None:
        """Read packets until the port closes or we are told to stop."""
        while not self._stop.is_set():
            raw = ser.readline()
            if not raw:
                continue  # read timeout; loop round and re-check stop flag
            text = raw.decode(errors="replace").rstrip("\r\n")
            if not text:
                continue
            # Only log genuine packet frames from RF12demo.
            if not (text.startswith("OK") or text.startswith("?")):
                continue
            now = utc_now()
            append_line(self.logdir, now, f"L {iso_stamp(now)} {self.device} {text}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="RF12demo serial logger with daily log rotation",
    )
    p.add_argument("--device", default=DEFAULT_DEVICE,
                   help=f"serial device path (default: {DEFAULT_DEVICE})")
    p.add_argument("--baud", type=int, default=DEFAULT_BAUD,
                   help=f"baud rate (default: {DEFAULT_BAUD})")
    p.add_argument("--logdir", default=DEFAULT_LOGDIR,
                   help=f"local log directory (default: {DEFAULT_LOGDIR})")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    logdir = Path(os.path.expanduser(args.logdir)).resolve()
    logdir.mkdir(parents=True, exist_ok=True)
    log.info("logdir=%s device=%s baud=%d", logdir, args.device, args.baud)

    listener = SerialListener(args.device, args.baud, logdir)

    def handle_signal(signum, _frame):
        log.info("received signal %d, shutting down", signum)
        listener.stop()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    listener.run()
    log.info("exit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
