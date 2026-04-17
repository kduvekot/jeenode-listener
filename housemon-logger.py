#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = [
#     "pyserial>=3.5",
#     "boto3>=1.26",
# ]
# ///
"""
housemon-logger: RF12demo serial listener with daily log rotation and S3 backup.

Reads raw lines from an RF12demo-running JeeLink (or similar) over a serial
port, filters for `OK` and `?` frames, timestamps them, and appends them to a
daily log file. Each log line has the form:

    L <iso-utc-timestamp> <device-path> <raw-rf12demo-line>

Log files live under `<logdir>/YYYY/YYYYMMDD.txt` (UTC) and rotate
automatically at midnight because the target path is recomputed on every
packet.

If an S3 bucket is configured, the current file is uploaded every 60 seconds
and on every rollover and clean shutdown. Without a bucket the S3 side is a
no-op.
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
from typing import Optional

import serial

# ---------------------------------------------------------------------------
# Configuration constants
# ---------------------------------------------------------------------------

# RF12demo radio parameters baked in at the top of the file (not CLI args).
RF12_NODE_ID = 31
RF12_GROUP = 125
RF12_BAND = 8  # 1=433, 2=868, 3=915 -- 8 is what this install uses

# Timing knobs.
S3_UPLOAD_INTERVAL = 60.0   # seconds between periodic uploads of current file
RECONNECT_DELAY = 5.0       # seconds between serial reconnect attempts
BANNER_TIMEOUT = 3.0        # seconds to wait for the RF12demo banner
SERIAL_READ_TIMEOUT = 1.0   # seconds per readline() so we can check signals

# Defaults for CLI overrides.
DEFAULT_DEVICE = "/dev/ttyUSB0"
DEFAULT_BAUD = 57600
DEFAULT_LOGDIR = "~/housemon/logger"
DEFAULT_BUCKET = ""          # empty string disables S3
DEFAULT_S3_PREFIX = "logger"

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


def append_line(logdir: Path, now: datetime, line: str) -> Path:
    """Append one log line. Opens and closes the file each call (no buffering)."""
    path = daily_path(logdir, now)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(line)
        if not line.endswith("\n"):
            f.write("\n")
    return path


# ---------------------------------------------------------------------------
# S3 uploader
# ---------------------------------------------------------------------------

class S3Uploader:
    """
    Periodic and event-driven uploader for the daily log file.

    Behaviour:
      * Periodic timer thread uploads the current in-progress file every
        `S3_UPLOAD_INTERVAL` seconds.
      * `note_write()` is called from the serial thread after every packet
        write; when it detects that the path has changed (midnight rollover)
        it synchronously uploads the previous day's completed file.
      * `final_sync()` stops the thread and does one last upload.

    If no bucket was configured this class is a no-op.
    """

    def __init__(self, bucket: str, prefix: str, logdir: Path):
        self.bucket = bucket
        self.prefix = prefix.strip("/")
        self.logdir = logdir
        self.enabled = bool(bucket)
        self.client = None
        self._stop = threading.Event()
        self._thread = None
        self._current_path: Optional[Path] = None
        self._lock = threading.Lock()

        if self.enabled:
            # Import boto3 lazily so that the script can run without AWS deps
            # resolved in S3-disabled mode (though with uv they always are).
            import boto3
            self.client = boto3.client("s3")

    # -- lifecycle ----------------------------------------------------------

    def start(self) -> None:
        if not self.enabled:
            log.info("S3 uploads disabled (no --bucket configured)")
            return
        self._thread = threading.Thread(
            target=self._run_periodic,
            name="s3-uploader",
            daemon=True,
        )
        self._thread.start()
        log.info("S3 uploader started (bucket=%s prefix=%s)", self.bucket, self.prefix)

    def final_sync(self) -> None:
        if not self.enabled:
            return
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5.0)
        with self._lock:
            path = self._current_path
        if path is not None and path.exists():
            self._upload(path)

    # -- event hooks --------------------------------------------------------

    def note_write(self, path: Path) -> None:
        """Called after each successful log append. Detects rollover."""
        if not self.enabled:
            return
        with self._lock:
            previous = self._current_path
            self._current_path = path
        if previous is not None and previous != path:
            # Midnight rollover: push the just-completed file right away.
            log.info("rollover detected, uploading completed %s", previous.name)
            self._upload(previous)

    # -- internals ----------------------------------------------------------

    def _run_periodic(self) -> None:
        # Event.wait returns True if the event was set, False on timeout.
        while not self._stop.wait(S3_UPLOAD_INTERVAL):
            with self._lock:
                path = self._current_path
            if path is not None and path.exists():
                self._upload(path)

    def _key_for(self, path: Path) -> str:
        rel = path.relative_to(self.logdir).as_posix()
        return f"{self.prefix}/{rel}" if self.prefix else rel

    def _upload(self, path: Path) -> None:
        key = self._key_for(path)
        try:
            self.client.upload_file(str(path), self.bucket, key)
            log.debug("uploaded %s -> s3://%s/%s", path, self.bucket, key)
        except Exception as e:  # pragma: no cover - we never want this to crash the logger
            log.warning("S3 upload failed for %s: %s", path, e)


# ---------------------------------------------------------------------------
# Serial listener
# ---------------------------------------------------------------------------

class SerialListener:
    """Owns the serial port, handles (re)connection, configuration and logging."""

    def __init__(self, device: str, baud: int, logdir: Path, uploader: S3Uploader):
        self.device = device
        self.baud = baud
        self.logdir = logdir
        self.uploader = uploader
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
                # Give the JeeLink a moment; opening often triggers a reset.
                time.sleep(0.5)
                if not self._configure(ser):
                    log.warning(
                        "RF12demo banner not confirmed within %.1fs, continuing anyway",
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

    def _configure(self, ser: serial.Serial) -> bool:
        """
        Push RF12demo config commands and wait for the `[RF12demo...]` banner.
        Returns True if the banner was seen within BANNER_TIMEOUT, else False.
        """
        # Drain anything already buffered from the device.
        try:
            ser.reset_input_buffer()
        except Exception:
            pass

        for cmd in (
            f"{RF12_NODE_ID}i",
            f"{RF12_BAND}b",
            f"{RF12_GROUP}g",
        ):
            ser.write(cmd.encode() + b"\r\n")
            ser.flush()
            # RF12demo parses single-character commands; a short pause is plenty.
            time.sleep(0.05)

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
                return True
        return False

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
            line = f"L {iso_stamp(now)} {self.device} {text}"
            path = append_line(self.logdir, now, line)
            self.uploader.note_write(path)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="RF12demo serial logger with daily rotation and optional S3 backup",
    )
    p.add_argument("--device", default=DEFAULT_DEVICE,
                   help=f"serial device path (default: {DEFAULT_DEVICE})")
    p.add_argument("--baud", type=int, default=DEFAULT_BAUD,
                   help=f"baud rate (default: {DEFAULT_BAUD})")
    p.add_argument("--logdir", default=DEFAULT_LOGDIR,
                   help=f"local log directory (default: {DEFAULT_LOGDIR})")
    p.add_argument("--bucket", default=DEFAULT_BUCKET,
                   help="S3 bucket for backups; empty disables S3")
    p.add_argument("--s3-prefix", default=DEFAULT_S3_PREFIX,
                   help=f"S3 key prefix (default: {DEFAULT_S3_PREFIX})")
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

    uploader = S3Uploader(args.bucket, args.s3_prefix, logdir)
    uploader.start()

    listener = SerialListener(args.device, args.baud, logdir, uploader)

    def handle_signal(signum, _frame):
        log.info("received signal %d, shutting down", signum)
        listener.stop()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    try:
        listener.run()
    finally:
        log.info("final S3 sync")
        uploader.final_sync()
        log.info("exit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
