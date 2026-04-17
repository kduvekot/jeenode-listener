# jeenode-listener

A tiny, production-ready daemon that listens to a
[JeeLink](https://jeelabs.net/) running the stock `RF12demo` sketch, timestamps
every received packet, and writes it to a daily-rotated log file on disk.

A separate `systemd` timer-driven unit (`housemon-sync.timer`) pushes those
files off-box with [`rclone`](https://rclone.org/), so they can land in **any
S3-compatible bucket** — AWS S3, MinIO / Ceph RGW, Cloudflare R2, Backblaze
B2, Wasabi, etc. — or, equally, a WebDAV / SFTP / Google Drive / … remote.

Built to run 24x7 on a Raspberry Pi 1 (**Raspberry Pi OS Lite 32-bit**, which
is Debian Trixie / ARMv6) under systemd, using nothing more than `pyserial` +
the Python standard library in the logger itself (driven by
[`uv`](https://github.com/astral-sh/uv) and PEP 723 inline script metadata),
plus the distro-packaged `rclone` for the sync side.

## Quick install

```bash
git clone https://github.com/kduvekot/jeenode-listener.git
cd jeenode-listener
sudo ./install.sh
```

That runs the idempotent [`install.sh`](install.sh), which:

- apt-installs `rclone` + `curl` + `ca-certificates`,
- installs `uv` into `/usr/local/bin` if not already present,
- creates the `housemon` system user (with `dialout` group membership),
- drops the logger under `/opt/housemon/` and the three unit files under
  `/etc/systemd/system/`,
- prepares `/etc/housemon/` (for the rclone config + sync env),
- warms the `uv` cache so the first service start is instant,
- prints the three commands left for you (rclone config, enable logger,
  enable sync timer).

Re-run it any time to pick up new commits — every step checks for existing
state.

If you'd rather understand what each step does before running a script, the
[step-by-step instructions](#install-on-a-raspberry-pi) below do the same
thing by hand.

## Architecture

Two cleanly separated units:

| unit                       | job                                          | network? |
| -------------------------- | -------------------------------------------- | -------- |
| `housemon-logger.service`  | read `/dev/ttyUSB0`, append log lines        | **no**   |
| `housemon-sync.timer` / .service | every 60s, `rclone copy` log tree → remote | yes      |

The logger is deliberately network-free: failures in MinIO / the LAN / the
upstream bucket **cannot** affect packet capture. The sync side uses `rclone
copy` (not `sync`) so the remote is an append-only mirror — locally-pruned
files are never deleted remotely.

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

## Logger CLI

```
uv run housemon-logger.py \
    [--device /dev/ttyUSB0] \
    [--baud 57600] \
    [--logdir ~/housemon/logger]
```

RF12 radio parameters (`node id`, `group`, `band`) are constants at the top of
the script — edit them there if you need to change them.

---

## Target platform

Fully tested / intended for **Raspberry Pi OS Lite 32-bit** (the headless
image, based on **Debian Trixie / ARMv6**) running on a **Raspberry Pi 1**
(or Zero W). Nothing here is specific to a Pi 1 though; the same recipe works
on a Pi 3/4/5. Concretely, the target ships:

- kernel 6.12 LTS (supports all the `Protect*` systemd directives),
- systemd 257 (supports `ProtectProc`, `RestrictAddressFamilies`, etc.),
- Python 3.13 (we require `>= 3.9`),
- `rclone` in apt (`sudo apt install rclone`),
- `dialout` as the standard group for USB serial devices.

`pyserial` is pure Python, so there are no wheels to compile on ARMv6 — `uv`
just downloads and caches it. The logger's resident set is a few MB; easily
fits alongside other services on a 512 MB Pi 1.

## Install on a Raspberry Pi

These steps assume a stock **Raspberry Pi OS Lite 32-bit** image (Debian
Trixie, ARMv6) on a Pi 1 / Zero W.

### 1. Install `uv` system-wide and `rclone`

```bash
curl -LsSf https://astral.sh/uv/install.sh | sudo env UV_INSTALL_DIR=/usr/local/bin sh
sudo apt install -y rclone
```

`uv` goes to `/usr/local/bin/uv` so every user (including the locked-down
service account below) can reach it.

> **Heads up on ARMv6:** `uv self update` does not work on the musl builds
> shipped for ARMv6. To upgrade, just re-run the install script above; it
> overwrites `/usr/local/bin/uv` with the latest release.

### 2. Create a dedicated `housemon` system user

Non-login, no shell, only the `dialout` group so it can read `/dev/ttyUSB0`:

```bash
sudo useradd --system \
    --home-dir /var/lib/housemon \
    --create-home \
    --shell /usr/sbin/nologin \
    --groups dialout \
    --comment "HouseMon RF12demo logger" \
    housemon
```

`/var/lib/housemon` is the user's home and will hold:

- `~/.cache/uv/` — uv's package cache
- `~/logger/YYYY/YYYYMMDD.txt` — the log tree

### 3. Drop the logger script in place

Owned by `root`, only readable (not writable) by the service user:

```bash
sudo mkdir -p /opt/housemon
sudo install -o root -g housemon -m 0644 housemon-logger.py /opt/housemon/
```

First start will resolve `pyserial` into `/var/lib/housemon/.cache/uv/` — a
few seconds on a Pi 1, then instant forever after.

### 4. Install and enable the logger service

```bash
sudo install -o root -g root -m 0644 housemon-logger.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now housemon-logger.service
```

The unit is `BindsTo=dev-ttyUSB0.device` and `WantedBy=dev-ttyUSB0.device`:

- it only runs while the JeeLink is plugged in,
- it starts automatically the moment the USB device appears,
- it stops the moment the USB device is yanked,
- `IPAddressDeny=any` + `RestrictAddressFamilies=AF_UNIX` means it has
  literally zero network access.

Verify: one `L ...` line per packet should start appearing at
`/var/lib/housemon/logger/<year>/<date>.txt`:

```bash
sudo -u housemon tail -f /var/lib/housemon/logger/$(date -u +%Y)/$(date -u +%Y%m%d).txt
journalctl -u housemon-logger.service -f
```

### 5. Configure the S3 / rclone remote (optional)

Skip this whole section to run local-only.

`rclone` stores remote definitions in a config file; we keep ours in
`/etc/housemon/rclone.conf` so it's system-owned and readable by the service
account.

The easiest way to build one is to run `rclone config` interactively **as the
housemon user** against a scratch file, then move it into place:

```bash
sudo -u housemon rclone config --config /tmp/rclone.conf
# ...follow the prompts: "n" for new remote, pick "Amazon S3 compliant",
# choose "Other" for provider, enter endpoint + keys + region...
sudo install -o root -g housemon -m 0640 /tmp/rclone.conf /etc/housemon/rclone.conf
rm /tmp/rclone.conf
```

A typical MinIO-flavoured remote block looks like:

```ini
[minio]
type = s3
provider = Other
access_key_id = <minio access key>
secret_access_key = <minio secret key>
endpoint = http://minio.incus.lan:9000
region = us-east-1
force_path_style = true
```

For other backends the block changes shape (`provider = AWS`,
`provider = Cloudflare`, `provider = Backblaze`, ...); `rclone config` walks
you through each.

Sanity-check the remote from the service user before enabling the timer:

```bash
sudo -u housemon rclone --config /etc/housemon/rclone.conf \
    lsd minio:
sudo -u housemon rclone --config /etc/housemon/rclone.conf \
    mkdir minio:housemon
```

### 6. Point `housemon-sync` at the remote

```bash
sudo mkdir -p /etc/housemon
sudo tee /etc/housemon/sync.env >/dev/null <<'EOF'
# Destination for `rclone copy`. Format: <remote>:<bucket>[/<prefix>]
REMOTE=minio:housemon/logger
EOF
sudo chown root:housemon /etc/housemon/sync.env
sudo chmod 0640 /etc/housemon/sync.env
```

Then install and enable the timer+service:

```bash
sudo install -o root -g root -m 0644 housemon-sync.service /etc/systemd/system/
sudo install -o root -g root -m 0644 housemon-sync.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now housemon-sync.timer
```

The timer fires every minute (plus once at boot) and runs
`housemon-sync.service`, which is a one-shot `rclone copy` of the log tree.
Because it's `copy` and not `sync`, remote files are never deleted even if the
local copy rotates away.

### 7. Check logs

```bash
# the logger
journalctl -u housemon-logger.service -f

# the sync side (one line per timer tick)
journalctl -u housemon-sync.service -f

# the timer schedule
systemctl list-timers housemon-sync.timer
```

### 8. Confirm remote uploads

Any rclone-supported lister works, e.g.:

```bash
sudo -u housemon rclone --config /etc/housemon/rclone.conf \
    ls minio:housemon/logger/$(date -u +%Y)/
```

You should see today's `YYYYMMDD.txt` with a modification time within the last
minute.

## Testing tips (first real run)

- `id housemon` should list `dialout`.
- `journalctl -u housemon-logger.service -b` should show
  `RF12demo ready: [RF12demo.…]`; "banner not confirmed" every time means
  the USB-serial adapter isn't triggering a DTR reset on open — harmless,
  packets still flow.
- Unplug the JeeLink → `housemon-logger.service` stops cleanly via
  `BindsTo`; replug and it comes back.
- `sudo systemctl stop housemon-sync.timer && sudo systemctl start housemon-sync.service`
  runs one sync on demand, handy while debugging the rclone config.
- Block the remote (`iptables -I OUTPUT -d <minio ip> -j REJECT`) →
  `housemon-sync.service` fails in the journal, `housemon-logger.service`
  is untouched; unblock and the next tick catches up.
