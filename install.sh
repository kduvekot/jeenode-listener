#!/usr/bin/env bash
# install.sh -- idempotent installer for jeenode-listener on Raspberry Pi OS.
#
# Usage (no git clone required):
#     curl -LsSf https://raw.githubusercontent.com/kduvekot/jeenode-listener/main/install.sh \
#         | sudo bash
#
# Pin to a tag / branch / commit:
#     curl -LsSf https://raw.githubusercontent.com/kduvekot/jeenode-listener/v0.2.0/install.sh \
#         | sudo bash -s -- --ref v0.2.0
#
# From a local checkout:
#     sudo ./install.sh
#
# Safe to re-run: every step checks for existing state before acting, so this
# is also the upgrade path -- point it at a newer ref and re-run.

set -euo pipefail

# ---------------------------------------------------------------------------
# Args / config
# ---------------------------------------------------------------------------
REPO="${REPO:-kduvekot/jeenode-listener}"
REF="${REF:-main}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref)     REF="$2"; shift 2 ;;
        --ref=*)   REF="${1#--ref=}"; shift ;;
        --repo)    REPO="$2"; shift 2 ;;
        --repo=*)  REPO="${1#--repo=}"; shift ;;
        -h|--help)
            cat <<EOF
Usage: install.sh [--ref <git-ref>] [--repo <owner/repo>]

Options:
  --ref   git ref (branch, tag, or commit) to fetch files from; default: main
  --repo  owner/repo on GitHub; default: kduvekot/jeenode-listener

If run from a repo checkout (files present next to install.sh), the local
files are used instead of fetching from GitHub.
EOF
            exit 0 ;;
        *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done

BASE_URL="https://raw.githubusercontent.com/${REPO}/${REF}"

say()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

if [[ ${EUID} -ne 0 ]]; then
    echo "install.sh must be run as root (e.g. piped into 'sudo bash')" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Staging: either copy from the local checkout, or fetch from GitHub raw.
# ---------------------------------------------------------------------------
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

fetch() {
    local rel="$1" dst="${STAGE}/${1}"
    mkdir -p "$(dirname "${dst}")"
    if [[ -n "${SCRIPT_DIR}" && -f "${SCRIPT_DIR}/${rel}" ]]; then
        cp "${SCRIPT_DIR}/${rel}" "${dst}"
    else
        printf '    curl %s\n' "${BASE_URL}/${rel}"
        curl -LsSf --retry 3 --retry-delay 2 "${BASE_URL}/${rel}" -o "${dst}"
    fi
}

if [[ -n "${SCRIPT_DIR}" && -f "${SCRIPT_DIR}/housemon-logger.py" ]]; then
    say "Using local files from ${SCRIPT_DIR}"
else
    say "Fetching files from ${BASE_URL}"
fi

fetch housemon-logger.py
fetch housemon-logger.service
fetch housemon-sync.service
fetch housemon-sync.timer

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
    install -d -o housemon -g housemon -m 0755 /var/lib/housemon
fi

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------
say "Installing logger script to /opt/housemon/"
install -d -o root -g root -m 0755 /opt/housemon
install -o root -g housemon -m 0644 \
    "${STAGE}/housemon-logger.py" /opt/housemon/housemon-logger.py

say "Installing systemd units to /etc/systemd/system/"
install -o root -g root -m 0644 \
    "${STAGE}/housemon-logger.service" /etc/systemd/system/housemon-logger.service
install -o root -g root -m 0644 \
    "${STAGE}/housemon-sync.service"   /etc/systemd/system/housemon-sync.service
install -o root -g root -m 0644 \
    "${STAGE}/housemon-sync.timer"     /etc/systemd/system/housemon-sync.timer

say "Preparing /etc/housemon (for rclone.conf and sync.env)"
install -d -o root -g housemon -m 0750 /etc/housemon

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------
say "Reloading systemd"
systemctl daemon-reload

# Warm the uv cache as the housemon user so the first service start doesn't
# stall on pyserial resolution. Harmless if it fails (e.g. no net).
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

The logger is NOT enabled yet -- configure the rclone side first (or skip it
for local-only operation).

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
