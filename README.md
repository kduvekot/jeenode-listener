# jeenode-listener

A tiny, production-ready daemon that listens to a
[JeeLink](https://jeelabs.net/) running the stock `RF12demo` sketch, timestamps
every received packet, writes it to a daily-rotated log file on disk, and
(optionally) mirrors those files to an S3 bucket.

Built to run 24x7 on a Raspberry Pi 1 under systemd, using nothing more than
`pyserial` + `boto3` + the Python standard library, driven by
[`uv`](https://github.com/astral-sh/uv) and PEP 723 inline script metadata.

## Log format

Each received `OK` / `?` line from RF12demo becomes one line in the log:

```
L 2026-04-17T09:14:27.318Z /dev/ttyUSB0 OK 9 127 0 98 201 14 0
```

- `L` — literal prefix
- ISO 8601 UTC timestamp with millisecond precision
- Source device path (`--device`)
- The raw RF12demo line, verbatim

Files live at `<logdir>/YYYY/YYYYMMDD.txt` and roll over automatically at
00:00 UTC. Any line that isn't `OK ...` or `? ...` is dropped. Writes are
append-mode and open-close per packet, so nothing sits in a buffer on crash.

## CLI

```
uv run housemon-logger.py \
    [--device /dev/ttyUSB0] \
    [--baud 57600] \
    [--logdir ~/housemon/logger] \
    [--bucket MYBUCKET] \
    [--s3-prefix logger]
```

RF12 radio parameters (`node id`, `group`, `band`) are constants at the top of
the script — edit them there if you need to change them.

---

## Install on a Raspberry Pi

These steps assume a stock Raspberry Pi OS (Debian Bookworm, 32-bit, ARMv6 on a
Pi 1 / Zero W).

### 1. Install `uv` system-wide

```bash
curl -LsSf https://astral.sh/uv/install.sh | sudo env UV_INSTALL_DIR=/usr/local/bin sh
```

That drops a single `uv` binary in `/usr/local/bin` so both your user and the
systemd service (which runs as `pi`) can see it.

> **Heads up on ARMv6:** `uv self update` does not work on the musl builds
> shipped for ARMv6. To upgrade, just re-run the install script above. It will
> overwrite `/usr/local/bin/uv` with the latest release.

### 2. Drop the script in place

```bash
sudo mkdir -p /opt/housemon
sudo cp housemon-logger.py /opt/housemon/
sudo chown -R pi:pi /opt/housemon
```

The first time the service starts, `uv` will fetch `pyserial` and `boto3` into
`~pi/.cache/uv`. That takes a minute on a Pi 1; subsequent runs are instant.

### 3. Configure AWS credentials (optional)

Skip this section if you don't want S3 backup. Without a bucket the logger
happily runs local-only.

Create `/etc/housemon/logger.env` with mode `0640`, owned by `root:pi`:

```ini
# S3 bucket; leave BUCKET="" to disable uploads entirely.
BUCKET=my-housemon-bucket

# Standard boto3 env vars. Alternatively drop a ~pi/.aws/credentials file.
AWS_DEFAULT_REGION=eu-west-1
AWS_ACCESS_KEY_ID=AKIAxxxxxxxxxxxxxxxx
AWS_SECRET_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

```bash
sudo mkdir -p /etc/housemon
sudo install -o root -g pi -m 0640 logger.env /etc/housemon/logger.env
```

The IAM principal only needs `s3:PutObject` on
`arn:aws:s3:::my-housemon-bucket/logger/*`.

### 4. Install and enable the systemd unit

```bash
sudo cp housemon-logger.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now housemon-logger.service
```

The unit is `BindsTo=dev-ttyUSB0.device` and `WantedBy=dev-ttyUSB0.device`, so:

- it only runs while the JeeLink is plugged in,
- it starts automatically the moment the USB device appears,
- it stops (cleanly, with a final S3 sync) the moment the USB device is yanked.

If the process dies for any other reason systemd restarts it after 5 seconds.

### 5. Check logs

Follow the service:

```bash
journalctl -u housemon-logger.service -f
```

One-shot status:

```bash
systemctl status housemon-logger.service
```

### 6. Verify packets are arriving

Watch the current day's file grow in real time:

```bash
tail -f ~pi/housemon/logger/$(date -u +%Y)/$(date -u +%Y%m%d).txt
```

You should see one `L ...` line per received RF12 packet. If you don't:

- check `journalctl` for `serial error` or banner warnings,
- confirm the JeeLink enumerates as `/dev/ttyUSB0` (otherwise override with `--device`),
- confirm `RF12_NODE_ID` / `RF12_GROUP` / `RF12_BAND` at the top of the script match your network.

### 7. Confirm S3 uploads

Uploads fire every 60s, at every midnight rollover, and once more on clean
shutdown. Check with:

```bash
aws s3 ls s3://my-housemon-bucket/logger/$(date -u +%Y)/
```

You should see today's `YYYYMMDD.txt` with a modification time within the last
minute.
