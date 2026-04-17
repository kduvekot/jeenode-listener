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
# With site-specific overrides (non-interactive / automation):
#     curl ... | sudo bash -s -- \
#         --node-id 42 --group 12 --band 8 \
#         --device /dev/ttyUSB0 --baud 57600 \
#         --remote minio:housemon/logger
#
# From a local checkout (interactive prompts if stdin is a TTY):
#     sudo ./install.sh
#
# Safe to re-run: every step checks for existing state before acting, so this
# is also the upgrade path -- point it at a newer ref and re-run.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
REPO="${REPO:-kduvekot/jeenode-listener}"
REF="${REF:-main}"

# RF12demo's own defaults (node 1, group 212=0xD4, band 2=868MHz). Real
# networks almost always diverge from these -- see the interactive prompts
# or the --node-id / --group / --band CLI flags to override.
DEFAULT_SERIAL_DEVICE=/dev/ttyUSB0
DEFAULT_SERIAL_BAUD=57600
DEFAULT_RF12_NODE_ID=1
DEFAULT_RF12_GROUP=212
DEFAULT_RF12_BAND=2
DEFAULT_REMOTE=

CONFIG=/etc/housemon/housemon.conf

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
# Each CLI override is tracked separately from the resolved value so we can
# tell "user explicitly asked" from "took an old conf/default".
CLI_DEVICE=""
CLI_BAUD=""
CLI_NODE_ID=""
CLI_GROUP=""
CLI_BAND=""
CLI_REMOTE=""
ASSUME_YES=false

usage() {
    cat <<EOF
Usage: install.sh [options]

Options (all optional):
  --ref <git-ref>        git ref to fetch files from (default: main)
  --repo <owner/repo>    repo on GitHub (default: kduvekot/jeenode-listener)

  --device <path>        serial device (default: /dev/ttyUSB0)
  --baud <int>           baud rate (default: 57600)
  --node-id <1..30>      RF12 node id (default: 1)
  --group <1..212>       RF12 network group (default: 212)
  --band <1|2|3>         RF12 band: 1=433MHz, 2=868MHz, 3=915MHz (default: 2)
  --remote <rclone>      rclone remote for sync, e.g. minio:housemon/logger
                         (default: empty = sync disabled)

  --yes                  don't prompt; use CLI/existing-conf/defaults

Examples:
  curl ... | sudo bash -s -- --node-id 42 --group 12 --remote minio:housemon
  sudo ./install.sh             # interactive prompts when stdin is a TTY
  sudo ./install.sh --yes       # no prompts, defaults + existing conf
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref)       REF="$2"; shift 2 ;;
        --ref=*)     REF="${1#--ref=}"; shift ;;
        --repo)      REPO="$2"; shift 2 ;;
        --repo=*)    REPO="${1#--repo=}"; shift ;;
        --device)    CLI_DEVICE="$2"; shift 2 ;;
        --device=*)  CLI_DEVICE="${1#--device=}"; shift ;;
        --baud)      CLI_BAUD="$2"; shift 2 ;;
        --baud=*)    CLI_BAUD="${1#--baud=}"; shift ;;
        --node-id)   CLI_NODE_ID="$2"; shift 2 ;;
        --node-id=*) CLI_NODE_ID="${1#--node-id=}"; shift ;;
        --group)     CLI_GROUP="$2"; shift 2 ;;
        --group=*)   CLI_GROUP="${1#--group=}"; shift ;;
        --band)      CLI_BAND="$2"; shift 2 ;;
        --band=*)    CLI_BAND="${1#--band=}"; shift ;;
        --remote)    CLI_REMOTE="$2"; shift 2 ;;
        --remote=*)  CLI_REMOTE="${1#--remote=}"; shift ;;
        --yes|-y)    ASSUME_YES=true; shift ;;
        -h|--help)   usage; exit 0 ;;
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
# Resolve configuration values
#   precedence: CLI flag > existing /etc/housemon/housemon.conf > default
# ---------------------------------------------------------------------------
SERIAL_DEVICE="$DEFAULT_SERIAL_DEVICE"
SERIAL_BAUD="$DEFAULT_SERIAL_BAUD"
RF12_NODE_ID="$DEFAULT_RF12_NODE_ID"
RF12_GROUP="$DEFAULT_RF12_GROUP"
RF12_BAND="$DEFAULT_RF12_BAND"
REMOTE="$DEFAULT_REMOTE"

CONFIG_EXISTS=false
if [[ -f "$CONFIG" ]]; then
    CONFIG_EXISTS=true
    # shellcheck disable=SC1090
    source "$CONFIG"
fi

# Migrate from the pre-housemon.conf era: the old sync.env used to own REMOTE.
if [[ -z "${REMOTE:-}" && -f /etc/housemon/sync.env ]]; then
    # shellcheck disable=SC1091
    source /etc/housemon/sync.env
fi

# CLI flags always win.
[[ -n "$CLI_DEVICE"  ]] && SERIAL_DEVICE="$CLI_DEVICE"
[[ -n "$CLI_BAUD"    ]] && SERIAL_BAUD="$CLI_BAUD"
[[ -n "$CLI_NODE_ID" ]] && RF12_NODE_ID="$CLI_NODE_ID"
[[ -n "$CLI_GROUP"   ]] && RF12_GROUP="$CLI_GROUP"
[[ -n "$CLI_BAND"    ]] && RF12_BAND="$CLI_BAND"
[[ -n "$CLI_REMOTE"  ]] && REMOTE="$CLI_REMOTE"

# ---------------------------------------------------------------------------
# Interactive prompts -- only when stdin is a real TTY, user didn't ask to
# skip them, and we don't already have a config on disk. On re-install we
# trust the existing conf + any CLI overrides.
# ---------------------------------------------------------------------------
prompt_if_unset() {
    local cli="$1" varname="$2" prompt="$3"
    # Skip entirely if the user gave it on the command line.
    [[ -n "$cli" ]] && return 0
    local current="${!varname}"
    local answer
    read -r -p "$prompt [$current]: " answer || return 0
    [[ -n "$answer" ]] && printf -v "$varname" '%s' "$answer"
}

if [[ "$ASSUME_YES" == false && -t 0 && "$CONFIG_EXISTS" == false ]]; then
    say "Interactive config (press Enter to accept each default)"
    echo
    prompt_if_unset "$CLI_DEVICE"  SERIAL_DEVICE "Serial device"
    prompt_if_unset "$CLI_BAUD"    SERIAL_BAUD   "Baud rate"
    prompt_if_unset "$CLI_NODE_ID" RF12_NODE_ID  "RF12 node id (1..30)"
    prompt_if_unset "$CLI_GROUP"   RF12_GROUP    "RF12 group (1..212)"
    prompt_if_unset "$CLI_BAND"    RF12_BAND     "RF12 band (1=433MHz, 2=868MHz, 3=915MHz)"
    prompt_if_unset "$CLI_REMOTE"  REMOTE        "rclone remote for sync (empty to skip)"
    echo
elif [[ "$CONFIG_EXISTS" == true ]]; then
    say "Existing $CONFIG found; keeping its values (CLI flags still win)"
fi

say "Resolved settings:"
printf '    %-18s %s\n' \
    "SERIAL_DEVICE"  "$SERIAL_DEVICE" \
    "SERIAL_BAUD"    "$SERIAL_BAUD" \
    "RF12_NODE_ID"   "$RF12_NODE_ID" \
    "RF12_GROUP"     "$RF12_GROUP" \
    "RF12_BAND"      "$RF12_BAND" \
    "REMOTE"         "${REMOTE:-(sync disabled)}"

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
say "Installing apt prerequisites (python3-serial, rclone, curl, ca-certificates)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    python3 python3-serial rclone curl ca-certificates

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

say "Writing $CONFIG"
install -d -o root -g housemon -m 0750 /etc/housemon
TMPCONF="$(mktemp)"
cat > "$TMPCONF" <<EOF
# /etc/housemon/housemon.conf
#
# Site-specific configuration for jeenode-listener.
# Generated by install.sh; safe to hand-edit (then 'systemctl restart
# housemon-logger.service' to pick up changes).

# Serial device + baud for the JeeLink / RFM12B gateway.
SERIAL_DEVICE=${SERIAL_DEVICE}
SERIAL_BAUD=${SERIAL_BAUD}

# RF12 radio settings -- must match the transmitters in your network.
# BAND: 1=433MHz, 2=868MHz, 3=915MHz.
RF12_NODE_ID=${RF12_NODE_ID}
RF12_GROUP=${RF12_GROUP}
RF12_BAND=${RF12_BAND}

# rclone remote for off-box sync. Format: <remote>:<bucket>[/<prefix>]
# Leave empty to disable sync (the timer will then no-op every tick).
REMOTE=${REMOTE}
EOF
install -o root -g housemon -m 0640 "$TMPCONF" "$CONFIG"
rm -f "$TMPCONF"

# One-time migration: old installs had these in /etc/housemon/sync.env.
if [[ -f /etc/housemon/sync.env ]]; then
    say "Removing deprecated /etc/housemon/sync.env (merged into $CONFIG)"
    rm -f /etc/housemon/sync.env
fi

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------
say "Reloading systemd"
systemctl daemon-reload

# Sanity-check: the logger should at least print --help with the just-installed
# apt-packaged pyserial. Any ImportError here means the system python3 can't
# import `serial` and the service will fail -- fail early and loud instead.
say "Checking that python3 can import pyserial"
if ! /usr/bin/python3 /opt/housemon/housemon-logger.py --help >/dev/null; then
    warn "housemon-logger.py --help failed -- check python3-serial install"
fi

cat <<EOF

==> Install complete.

Resolved config written to $CONFIG:
  device ${SERIAL_DEVICE} @ ${SERIAL_BAUD} baud
  RF12  node=${RF12_NODE_ID}  group=${RF12_GROUP}  band=${RF12_BAND}
  rclone remote: ${REMOTE:-(unset -- sync disabled)}

Next steps:

  # Start / restart the logger
  sudo systemctl enable --now housemon-logger.service
  sudo systemctl restart housemon-logger.service   # if already running

EOF

if [[ -z "${REMOTE}" ]]; then
    cat <<'EOF'
  # To enable off-box sync later:
  #   sudo -u housemon rclone config --config /tmp/rclone.conf
  #   sudo install -o root -g housemon -m 0640 /tmp/rclone.conf /etc/housemon/rclone.conf
  #   rm /tmp/rclone.conf
  #   # Re-run this installer with --remote <your-remote>, or hand-edit
  #   # REMOTE= in /etc/housemon/housemon.conf, then:
  #   sudo systemctl enable --now housemon-sync.timer

EOF
else
    cat <<'EOF'
  # Enable the sync timer (expects /etc/housemon/rclone.conf to be set up):
  sudo systemctl enable --now housemon-sync.timer

EOF
fi

cat <<'EOF'
Watching logs:
  journalctl -u housemon-logger.service -f
  journalctl -u housemon-sync.service -f
EOF
