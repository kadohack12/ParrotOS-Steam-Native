#!/usr/bin/env bash
# ParrotOS-Steam-Native — shared helpers (logging, privileges, tool checks).
# Sourced by parrot-steam-native.sh; never executed directly.

C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'
C_YEL=$'\033[1;33m'; C_BLU=$'\033[1;34m'; C_CYN=$'\033[1;36m'

log()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$C_CYN" "$*" "$C_RESET"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Run a command as root, transparently using passwordless sudo when needed.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

need_root() {
  if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    die "root (ou sudo sans mot de passe) est requis."
  fi
}

# Assert we are on a 64-bit-only host — the whole point of the project.
assert_pure_amd64() {
  local host_arch foreign
  host_arch="$(dpkg --print-architecture)"
  [ "$host_arch" = "amd64" ] || die "Architecture hôte inattendue: $host_arch (amd64 attendu)."
  foreign="$(dpkg --print-foreign-architectures)"
  if [ -n "$foreign" ]; then
    warn "Architectures étrangères déjà activées: $foreign"
    warn "Ce projet n'en a pas besoin — il ne les activera jamais lui-même."
  fi
}

# Verify a file is a 32-bit (i386) ELF object.
is_elf32() {
  local f="$1" magic
  [ -f "$f" ] || return 1
  magic="$(head -c 5 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ "$magic" = "7f454c4601" ]
}

human_size() {
  du -sh "$1" 2>/dev/null | cut -f1
}
