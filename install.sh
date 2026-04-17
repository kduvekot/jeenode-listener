#!/usr/bin/env bash
# install.sh -- idempotent installer for jeenode-listener on Raspberry Pi OS.
#
# Usage (from a clone of the repo):
#     sudo ./install.sh
#
# Safe to re-run: every step checks for existing state before acting, so you
# can use this to upgrade the script / units in place as well.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

if [[ ${EUID} -ne 0 ]]; then
    echo "install.sh must be run as root (try: sudo $0)" >&2
    exit 1
fi

# Sanity-check we're running from the repo, not some random cwd.
for f in housemon-logger.py housemon-logger.service \
         housemon-sync.service housemon-sync.timer; do
    if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
        echo "missing ${f} next to install.sh -- are you in the repo?" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# apt prerequisites
# ---------------------------------------------------------------------------
say "Installing apt prerequisites (rclone, curl, ca-certificates)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends rclone curl ca-certificates

# ---------------------------------------------------------------------------
# uv (system-wide)
# ---------------------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
    say "Installing uv into /usr/local/bin"
    curl -LsSf https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin UV_UNMANAGED_INSTALL=1 sh
else
    say "uv already installed ($(command -v uv))"
fi

# ---------------------------------------------------------------------------
# housemon system user
# ---------------------------------------------------------------------------
if ! getent passwd housemon >/dev/null; then
    say "Creating housemon system user"
    useradd --system \
        --home-dir /var/lib/housemon \
        --create-home \
        --shell /usr/sbin/nologin \
        --groups dialout \
        --comment "HouseMon RF12demo logger" \
        housemon
else
    say "housemon user already exists; ensuring dialout membership"
    usermod -aG dialout housemon
    # create-home isn't idempotent; make sure the dir exists for re-runs
    install -d -o housemon -g housemon -m 0755 /var/lib/housemon
fi

# ---------------------------------------------------------------------------
# files
# ---------------------------------------------------------------------------
say "Installing logger script to /opt/housemon/"
install -d -o root -g root -m 0755 /opt/housemon
install -o root -g housemon -m 0644 \
    "${SCRIPT_DIR}/housemon-logger.py" /opt/housemon/housemon-logger.py

say "Installing systemd units to /etc/systemd/system/"
install -o root -g root -m 0644 \
    "${SCRIPT_DIR}/housemon-logger.service" /etc/systemd/system/housemon-logger.service
install -o root -g root -m 0644 \
    "${SCRIPT_DIR}/housemon-sync.service"   /etc/systemd/system/housemon-sync.service
install -o root -g root -m 0644 \
    "${SCRIPT_DIR}/housemon-sync.timer"     /etc/systemd/system/housemon-sync.timer

say "Preparing /etc/housemon (for rclone.conf and sync.env)"
install -d -o root -g housemon -m 0750 /etc/housemon

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------
say "Reloading systemd"
systemctl daemon-reload

# Warm the uv cache as the housemon user so the first journal entry from the
# service isn't "resolving pyserial...". Harmless if it fails (e.g. no net).
if command -v uv >/dev/null 2>&1; then
    say "Warming uv cache for housemon (resolves pyserial)"
    if ! sudo -u housemon \
        HOME=/var/lib/housemon \
        /usr/local/bin/uv run --script /opt/housemon/housemon-logger.py --help \
        >/dev/null 2>&1; then
        warn "uv warm-up failed; first service start will fetch pyserial instead"
    fi
fi

cat <<'EOF'

==> Install complete.

The logger unit is NOT enabled yet -- review/configure the rclone side first
(or skip it for local-only operation).

Quick next steps:

  # --- Local-only (skip rclone) ---
  sudo systemctl enable --now housemon-logger.service

  # --- With rclone sync ---
  sudo -u housemon rclone config --config /tmp/rclone.conf
  sudo install -o root -g housemon -m 0640 /tmp/rclone.conf /etc/housemon/rclone.conf
  rm /tmp/rclone.conf
  echo 'REMOTE=minio:housemon/logger' \
      | sudo install -o root -g housemon -m 0640 /dev/stdin /etc/housemon/sync.env
  sudo systemctl enable --now housemon-logger.service
  sudo systemctl enable --now housemon-sync.timer

Watching logs:
  journalctl -u housemon-logger.service -f
  journalctl -u housemon-sync.service -f
EOF
