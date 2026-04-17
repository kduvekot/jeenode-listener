# jeenode-listener

A tiny, production-ready daemon that listens to a
[JeeLink](https://jeelabs.net/) running the stock `RF12demo` sketch, timestamps
every received packet, writes it to a daily-rotated log file on disk, and
(optionally) mirrors those files to any **S3-compatible** bucket — AWS S3,
MinIO / Ceph RGW, Cloudflare R2, Backblaze B2, Wasabi, etc.

Built to run 24x7 on a Raspberry Pi 1 (**Raspberry Pi OS Lite 32-bit**, which
is Debian Trixie / ARMv6) under systemd, using nothing more than `pyserial` +
`boto3` + the Python standard library, driven by
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
    [--s3-prefix logger] \
    [--s3-endpoint https://...] \
    [--s3-region us-east-1] \
    [--s3-addressing-style auto|path|virtual]
```

RF12 radio parameters (`node id`, `group`, `band`) are constants at the top of
the script — edit them there if you need to change them.

---

## Target platform

Fully tested / intended for **Raspberry Pi OS Lite 32-bit** (the headless
image, based on **Debian Trixie / ARMv6**) running on a **Raspberry Pi 1**
(or Zero W). Nothing in the script, the service file, or the install steps is
specific to a Pi 1 though; the same recipe works on a Pi 3/4/5 too.
Concretely, the target ships:

- kernel 6.12 LTS (supports all the `Protect*` systemd directives),
- systemd 257 (supports `ProtectProc`, `RestrictAddressFamilies`, etc.),
- Python 3.13 (we require `>= 3.9`),
- `dialout` as the standard group for USB serial devices.

`pyserial` is pure Python; `boto3` and its dependencies are pure Python too,
so there are no wheels to compile on ARMv6 — `uv` just downloads and caches
them. The first resolve uses ~50 MB of RAM for a minute; on a 512 MB Pi 1
that's fine but don't run it alongside other memory-hungry services.

## Install on a Raspberry Pi

These steps assume a stock **Raspberry Pi OS Lite 32-bit** image (Debian
Trixie, ARMv6) on a Pi 1 / Zero W.

### 1. Install `uv` system-wide

```bash
curl -LsSf https://astral.sh/uv/install.sh | sudo env UV_INSTALL_DIR=/usr/local/bin sh
```

That drops a single `uv` binary in `/usr/local/bin` so every user on the box
(including the locked-down service account we create next) can see it.

> **Heads up on ARMv6:** `uv self update` does not work on the musl builds
> shipped for ARMv6. To upgrade, just re-run the install script above. It will
> overwrite `/usr/local/bin/uv` with the latest release.

### 2. Create a dedicated `housemon` system user

The service runs as a purpose-built, non-login system user — no shell, no
privileges, only the `dialout` group so it can read `/dev/ttyUSB0`.

```bash
sudo useradd --system \
    --home-dir /var/lib/housemon \
    --create-home \
    --shell /usr/sbin/nologin \
    --groups dialout \
    --comment "HouseMon RF12demo logger" \
    housemon
```

`/var/lib/housemon` is the user's home. It will hold:

- `~/.cache/uv/` — uv's package cache
- `~/logger/YYYY/YYYYMMDD.txt` — the log tree

### 3. Drop the script in place

The script lives under `/opt/housemon/`, owned by `root` and only readable
(not writable) by the service user:

```bash
sudo mkdir -p /opt/housemon
sudo install -o root -g housemon -m 0644 housemon-logger.py /opt/housemon/
```

The first time the service starts, `uv` fetches `pyserial` and `boto3` into
`/var/lib/housemon/.cache/uv/`. That takes a minute on a Pi 1; subsequent runs
are instant.

### 4. Configure the S3 backend (optional)

Skip this section if you don't want S3 backup. Without a bucket the logger
happily runs local-only.

The uploader speaks plain S3, so **any S3-compatible object store works** —
it's not tied to AWS. You pick the backend by setting `S3_ENDPOINT` (and
usually `S3_ADDRESSING_STYLE`). The unit file passes those through to the
script as CLI flags.

Create `/etc/housemon/logger.env` owned by `root:housemon`, mode `0640`, so
the service can read it but no other users can. The shared bits:

```ini
# The bucket to upload to. Leave BUCKET="" to disable uploads entirely.
BUCKET=my-housemon-bucket

# Standard boto3 credentials. (Or drop a credentials file in
# /var/lib/housemon/.aws/credentials owned by housemon:housemon, mode 0600.)
AWS_ACCESS_KEY_ID=xxxxxxxxxxxxxxxxxxxx
AWS_SECRET_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Custom CA bundle (only needed for self-signed MinIO / internal CA setups).
# AWS_CA_BUNDLE=/etc/ssl/certs/my-internal-ca.pem
```

Plus **one** of these backend blocks:

**AWS S3 (original flavour):**
```ini
S3_ENDPOINT=
S3_REGION=eu-west-1
S3_ADDRESSING_STYLE=
```

**MinIO / Ceph RGW (self-hosted, typically path-style):**
```ini
S3_ENDPOINT=https://minio.lan:9000
S3_REGION=us-east-1
S3_ADDRESSING_STYLE=path
```

**Cloudflare R2:**
```ini
S3_ENDPOINT=https://<accountid>.r2.cloudflarestorage.com
S3_REGION=auto
S3_ADDRESSING_STYLE=virtual
```

**Backblaze B2 (S3-compatible API):**
```ini
S3_ENDPOINT=https://s3.<region>.backblazeb2.com
S3_REGION=<region>
S3_ADDRESSING_STYLE=virtual
```

**Wasabi:**
```ini
S3_ENDPOINT=https://s3.<region>.wasabisys.com
S3_REGION=<region>
S3_ADDRESSING_STYLE=virtual
```

Then install the file:

```bash
sudo mkdir -p /etc/housemon
sudo install -o root -g housemon -m 0640 logger.env /etc/housemon/logger.env
```

The credentials only need **`PutObject`** on
`<bucket>/logger/*`. On AWS that's the IAM action `s3:PutObject`; on MinIO
it's the equivalent `s3:PutObject` policy statement; on R2/B2 it's a bucket
key limited to write-only object creation under the `logger/` prefix.

### 5. Install and enable the systemd unit

```bash
sudo install -o root -g root -m 0644 housemon-logger.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now housemon-logger.service
```

The unit is `BindsTo=dev-ttyUSB0.device` and `WantedBy=dev-ttyUSB0.device`, so:

- it only runs while the JeeLink is plugged in,
- it starts automatically the moment the USB device appears,
- it stops (cleanly, with a final S3 sync) the moment the USB device is yanked.

It also runs with `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`,
an empty capability set and a read-write allow-list limited to
`/var/lib/housemon`. If the process dies for any other reason systemd
restarts it after 5 seconds.

### 6. Check logs

Follow the service:

```bash
journalctl -u housemon-logger.service -f
```

One-shot status:

```bash
systemctl status housemon-logger.service
```

### 7. Verify packets are arriving

Watch the current day's file grow in real time:

```bash
sudo tail -f /var/lib/housemon/logger/$(date -u +%Y)/$(date -u +%Y%m%d).txt
```

You should see one `L ...` line per received RF12 packet. If you don't:

- check `journalctl` for `serial error` or banner warnings,
- confirm the JeeLink enumerates as `/dev/ttyUSB0` (otherwise override with `--device`),
- confirm the `housemon` user is in the `dialout` group (`id housemon` should list it),
- confirm `RF12_NODE_ID` / `RF12_GROUP` / `RF12_BAND` at the top of the script match your network.

### 8. Confirm S3 uploads

Uploads fire every 60s, at every midnight rollover, and once more on clean
shutdown. Check with whichever CLI matches your backend, e.g.:

```bash
# AWS S3 / any S3-compatible store (aws-cli supports --endpoint-url)
aws s3 ls --endpoint-url "${S3_ENDPOINT:-https://s3.amazonaws.com}" \
    s3://my-housemon-bucket/logger/$(date -u +%Y)/

# MinIO
mc ls myminio/my-housemon-bucket/logger/$(date -u +%Y)/

# Cloudflare R2
rclone ls r2:my-housemon-bucket/logger/$(date -u +%Y)/
```

You should see today's `YYYYMMDD.txt` with a modification time within the last
minute.
