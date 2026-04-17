# jeenode-listener

A tiny, production-ready daemon that listens to a
[JeeLink](https://jeelabs.net/) running the stock `RF12demo` sketch, timestamps
every received packet, and writes it to a daily-rotated log file on disk.

A separate `systemd` timer-driven unit (`housemon-sync.timer`) pushes those
files off-box with [`rclone`](https://rclone.org/), so they can land in **any
S3-compatible bucket** — AWS S3, MinIO / Ceph RGW, Cloudflare R2, Backblaze
B2, Wasabi, etc. — or, equally, a WebDAV / SFTP / Google Drive / … remote.

Built to run 24x7 on a Raspberry Pi 1 (**Raspberry Pi OS Lite 32-bit**, which
is Debian Trixie / ARMv6) under systemd. Runtime dependencies are all
distro-packaged: `python3`, `python3-serial` and `rclone` from apt. No
PyPI, no `uv` at run time, no network needed at first start.

(The script keeps its PEP 723 inline metadata, so
`uv run --script housemon-logger.py` still works for interactive
development off-box.)

## Quick install

No `git` clone required — the installer pulls every file it needs from
GitHub raw URLs.

**Easy path (download, answer a few questions, run):**

```bash
curl -LsSfO https://raw.githubusercontent.com/kduvekot/jeenode-listener/main/install.sh
sudo bash install.sh
```

When run with a real terminal attached, the script prompts for the
site-specific values (serial device, baud, RF12 node id / group / band,
optional rclone remote) on a fresh install. Just press Enter to accept
each default.

**Non-interactive / automation (CLI flags):**

```bash
curl -LsSf https://raw.githubusercontent.com/kduvekot/jeenode-listener/main/install.sh \
    | sudo bash -s -- \
        --node-id 31 --group 125 --band 2 \
        --remote minio:housemon/logger
```

Any flag left off uses its current value from `/etc/housemon/housemon.conf`
(on re-installs) or the built-in default (on first install). Full list:
`--device`, `--baud`, `--node-id`, `--group`, `--band`, `--remote`, plus
`--yes` to skip prompts entirely and `--ref`/`--repo` for pinning.

**Accept-all-defaults (fastest, no prompts even on a TTY):**

```bash
curl -LsSf https://raw.githubusercontent.com/kduvekot/jeenode-listener/main/install.sh \
    | sudo bash
```

**Pin to a tag** (recommended for production — `main` moves):

```bash
curl -LsSf https://raw.githubusercontent.com/kduvekot/jeenode-listener/v0.2.0/install.sh \
    | sudo bash -s -- --ref v0.2.0
```

What [`install.sh`](install.sh) does, in order:

- apt-installs `python3-serial` + `rclone` + `curl` + `ca-certificates`,
- creates the `housemon` system user with `dialout` group membership,
- drops the logger under `/opt/housemon/` and the three systemd units under
  `/etc/systemd/system/`,
- writes `/etc/housemon/housemon.conf` with the resolved site-specific
  values, and creates `/etc/housemon/` to hold `rclone.conf` later,
- sanity-checks that `python3 housemon-logger.py --help` runs,
- prints the three commands left for you (rclone config, enable logger,
  enable sync timer).

Re-run it any time to pick up a new ref — every step checks for existing
state, so this is also the upgrade path.

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
python3 housemon-logger.py \
    [--device /dev/ttyUSB0] \
    [--baud 57600] \
    [--logdir ~/housemon/logger] \
    [--node-id 1] \
    [--group 212] \
    [--band 2]
```

Defaults match the stock JeeLabs `jeelib/RF12demo` sketch — real networks
nearly always diverge. The `b` command only accepts `1` (433 MHz), `2`
(868 MHz), or `3` (915 MHz); other values are ignored by the firmware.

Under systemd these are populated from `/etc/housemon/housemon.conf` so you
rarely call the script by hand — but the flags exist for testing and
automation. (`uv run --script housemon-logger.py ...` works too on a dev
box.)

The built-in defaults for RF12 `node id` / `group` / `band` are constants at
the top of the script, but production runs override them via CLI flags
populated from `/etc/housemon/housemon.conf` — you shouldn't need to edit
the `.py` file.

---

## Target platform

Fully tested / intended for **Raspberry Pi OS Lite 32-bit** (the headless
image, based on **Debian Trixie / ARMv6**) running on a **Raspberry Pi 1**
(or Zero W). Nothing here is specific to a Pi 1 though; the same recipe works
on a Pi 3/4/5. Concretely, the target ships:

- kernel 6.12 LTS (supports all the `Protect*` systemd directives),
- systemd 257 (supports `ProtectProc`, `RestrictAddressFamilies`, etc.),
- Python 3.13 + `python3-serial` in apt,
- `rclone` in apt,
- `dialout` as the standard group for USB serial devices.

No PyPI, no compile. The logger's resident set is a few MB; easily fits
alongside other services on a 512 MB Pi 1.

## Install on a Raspberry Pi

These steps assume a stock **Raspberry Pi OS Lite 32-bit** image (Debian
Trixie, ARMv6) on a Pi 1 / Zero W.

### 1. Install runtime dependencies from apt

```bash
sudo apt install -y --no-install-recommends python3-serial rclone curl ca-certificates
```

That's the only "install" step with a network requirement — from here on,
the logger never talks to PyPI.

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

- `~/logger/YYYY/YYYYMMDD.txt` — the log tree.

### 3. Drop the logger script in place

Owned by `root`, only readable (not writable) by the service user:

```bash
sudo mkdir -p /opt/housemon
sudo install -o root -g housemon -m 0644 housemon-logger.py /opt/housemon/
```

The service invokes `/usr/bin/python3 /opt/housemon/housemon-logger.py …`
using the apt-installed `python3-serial`. Nothing is downloaded at run time.

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

Set `REMOTE=` in `/etc/housemon/housemon.conf` (written by `install.sh`) to
the rclone destination. Easiest is to re-run the installer with `--remote`:

```bash
curl -LsSf https://raw.githubusercontent.com/kduvekot/jeenode-listener/main/install.sh \
    | sudo bash -s -- --remote minio:housemon/logger
```

Or hand-edit the file:

```bash
sudo sed -i 's|^REMOTE=.*|REMOTE=minio:housemon/logger|' /etc/housemon/housemon.conf
```

The sync service auto-skips (via `ExecCondition`) if `REMOTE` is empty or
`rclone.conf` is missing, so setting these up in either order is safe.

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
