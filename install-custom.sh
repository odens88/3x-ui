#!/usr/bin/env bash

set -Eeuo pipefail

CURRENT_BINARY="/usr/local/x-ui/x-ui"
DATABASE="/etc/x-ui/x-ui.db"
BACKUP_DIR="/root/3x-ui-backup"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    die "Run this script as root."
fi

if ! command -v git >/dev/null 2>&1; then
    die "git is required."
fi

if ! command -v curl >/dev/null 2>&1; then
    die "curl is required."
fi

if ! command -v sha256sum >/dev/null 2>&1; then
    die "sha256sum is required."
fi

if [ ! -d ".git" ]; then
    die "Run this script from the root of the cloned GitHub repository."
fi

REMOTE_URL="$(git remote get-url origin)"

case "$REMOTE_URL" in
    https://github.com/*)
        REPOSITORY="${REMOTE_URL#https://github.com/}"
        ;;
    git@github.com:*)
        REPOSITORY="${REMOTE_URL#git@github.com:}"
        ;;
    ssh://git@github.com/*)
        REPOSITORY="${REMOTE_URL#ssh://git@github.com/}"
        ;;
    *)
        die "Unable to determine GitHub repository from origin: $REMOTE_URL"
        ;;
esac

REPOSITORY="${REPOSITORY%.git}"
REPOSITORY="${REPOSITORY%/}"

case "$(uname -m)" in
    x86_64|amd64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    *)
        die "Unsupported architecture: $(uname -m)"
        ;;
esac

ASSET="x-ui-custom-linux-${ARCH}"
CHECKSUM="${ASSET}.sha256"

BASE_URL="https://github.com/${REPOSITORY}/releases/latest/download"

TMP_DIR="$(mktemp -d)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

echo
echo "Repository:   $REPOSITORY"
echo "Architecture: $ARCH"
echo

echo "Downloading latest custom release..."

curl \
    --fail \
    --location \
    --show-error \
    --silent \
    "${BASE_URL}/${ASSET}" \
    --output "${TMP_DIR}/${ASSET}"

curl \
    --fail \
    --location \
    --show-error \
    --silent \
    "${BASE_URL}/${CHECKSUM}" \
    --output "${TMP_DIR}/${CHECKSUM}"

cd "$TMP_DIR"

echo "Checking SHA256..."

sha256sum --check "$CHECKSUM"

chmod 755 "$ASSET"

echo
echo "Testing downloaded binary..."

"./${ASSET}" -v

echo

if [ ! -f "$CURRENT_BINARY" ]; then
    die "Existing 3x-ui installation not found at ${CURRENT_BINARY}."
fi

mkdir -p "$BACKUP_DIR"

BACKUP_BINARY="${BACKUP_DIR}/x-ui-${TIMESTAMP}"
BACKUP_DATABASE="${BACKUP_DIR}/x-ui-${TIMESTAMP}.db"

echo "Current version:"

"$CURRENT_BINARY" -v || true

echo
echo "Backing up current binary..."

cp -a \
    "$CURRENT_BINARY" \
    "$BACKUP_BINARY"

if [ -f "$DATABASE" ]; then
    echo "Backing up database..."

    cp -a \
        "$DATABASE" \
        "$BACKUP_DATABASE"
fi

rollback() {
    echo
    echo "Installation failed. Rolling back..."

    systemctl stop x-ui || true

    if [ -f "$BACKUP_BINARY" ]; then
        cp -a \
            "$BACKUP_BINARY" \
            "$CURRENT_BINARY"

        chmod 755 "$CURRENT_BINARY"
    fi

    systemctl start x-ui || true

    if systemctl is-active --quiet x-ui; then
        echo "Rollback successful."
    else
        echo "Rollback failed. Check x-ui manually."
    fi

    exit 1
}

trap rollback ERR

echo
echo "Stopping x-ui..."

systemctl stop x-ui

echo "Installing custom x-ui..."

install \
    -m 755 \
    "$ASSET" \
    "$CURRENT_BINARY"

echo "Starting x-ui..."

systemctl start x-ui

sleep 3

if ! systemctl is-active --quiet x-ui; then
    echo "x-ui did not start."
    journalctl -u x-ui -n 50 --no-pager || true
    false
fi

echo
echo "Installed version:"

"$CURRENT_BINARY" -v

echo
echo "Service status:"

systemctl status \
    x-ui \
    --no-pager \
    --lines=10

trap - ERR

echo
echo "Custom 3x-ui installed successfully."
echo
echo "Binary backup:"
echo "$BACKUP_BINARY"

if [ -f "$BACKUP_DATABASE" ]; then
    echo
    echo "Database backup:"
    echo "$BACKUP_DATABASE"
fi
