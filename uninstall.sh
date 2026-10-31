#!/usr/bin/env bash
#
# uninstall.sh — revert a ParrotOS-Steam-Native installation.
#
# Thin wrapper around `parrot-steam-native.sh uninstall`: it removes the
# portable runtime and the one tracked system symlink
# (/usr/lib/ld-linux.so.2) created at install time. The host dpkg database and
# the host apt configuration are never touched, so nothing else needs undoing.
#
# Usage:
#   sudo ./uninstall.sh
#
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPT_DIR/parrot-steam-native.sh"

if [ ! -f "$ENGINE" ]; then
  printf '[x] %s introuvable — clonez le dépôt complet.\n' "$ENGINE" >&2
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  exec bash "$ENGINE" uninstall "$@"
fi
if command -v sudo >/dev/null 2>&1; then
  exec sudo bash "$ENGINE" uninstall "$@"
fi
printf '[x] root (ou sudo) est requis pour la désinstallation.\n' >&2
exit 1
