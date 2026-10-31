#!/usr/bin/env bash
#
# install.sh — one-command entry point for ParrotOS-Steam-Native.
#
# This is a thin wrapper around parrot-steam-native.sh: it forwards every
# argument to the real engine and, called with no argument, runs the default
# `install` action. The `install` action is elevated through sudo when the
# caller is not root; read-only and launch commands (doctor, status, run, smoke)
# are forwarded unchanged.
#
# The heavy lifting — isolated apt state, download-only resolution, portable
# 32-bit runtime — lives in parrot-steam-native.sh. Keeping this wrapper thin
# means a single source of truth for the install logic.
#
# Usage:
#   sudo ./install.sh              # default action: install
#        ./install.sh doctor       # host + runtime report (read-only)
#        ./install.sh run          # launch Steam through the runtime
#        ./install.sh smoke        # headless validation under Xvfb
#        ./install.sh status
#        ./install.sh clean
#        ./install.sh uninstall
#
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPT_DIR/parrot-steam-native.sh"

if [ ! -f "$ENGINE" ]; then
  printf '[x] %s introuvable — clonez le dépôt complet.\n' "$ENGINE" >&2
  exit 1
fi

# Run the engine as root, transparently using sudo when available.
run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    exec bash "$ENGINE" "$@"
  fi
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$ENGINE" "$@"
  fi
  printf '[x] root (ou sudo) est requis pour cette action.\n' >&2
  exit 1
}

# No argument -> default to `install`.
if [ "$#" -eq 0 ]; then
  run_as_root install
fi

# `install` always needs root; elevate it so `./install.sh install` and
# `./install.sh` behave identically.
if [ "$1" = "install" ]; then
  run_as_root "$@"
fi

# Everything else is forwarded verbatim; the engine enforces root where needed.
exec bash "$ENGINE" "$@"
