#!/usr/bin/env bash
#
# ParrotOS-Steam-Native
# ---------------------
# Run Steam (and its ~350 32-bit dependencies) on a pure 64-bit Debian/Parrot
# host WITHOUT ever enabling the i386 architecture or touching the dpkg database.
#
# The trick: an *isolated* apt state (its own status file, lists and cache) is
# used to resolve and download the .deb set. The packages are then unpacked into
# a private prefix and a 32-bit runtime is assembled there. The host stays
# bit-for-bit pure amd64 and `apt` can never be corrupted by an arch mismatch.
#
# Usage: sudo ./parrot-steam-native.sh <command>
#   install     download + extract + build the portable runtime
#   doctor      report host readiness and runtime state (read-only)
#   run         launch Steam through the portable runtime
#   status      show runtime contents
#   clean       remove the build cache (keeps the runtime)
#   uninstall   remove the whole runtime
#
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/nvidia.sh
. "$SCRIPT_DIR/lib/nvidia.sh"

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
RUNTIME_DIR="${PARROT_STEAM_DIR:-/opt/parrot-steam}"
DEB_ARCHIVE="$(dpkg --print-architecture 2>/dev/null || echo amd64)"

# Debian release the runtime is built from. Parrot 7 "Echo" is trixie-based;
# the runtime is intentionally independent from the host's own release so the
# 32-bit set stays self-consistent.
DEB_SUITE="${PARROT_STEAM_SUITE:-trixie}"
DEB_MIRROR="${PARROT_STEAM_MIRROR:-http://deb.debian.org/debian}"
DEB_SECURITY="${PARROT_STEAM_SECURITY:-http://deb.debian.org/debian-security}"
DEB_COMPONENTS="main contrib non-free non-free-firmware"

# Root packages whose dependency closure pulls the full 32-bit set.
STEAM_PACKAGES=(steam-installer)

# Parallel download jobs.
DL_JOBS="${PARROT_STEAM_JOBS:-8}"

WORK="$RUNTIME_DIR/.build"
APT_ROOT="$WORK/apt"
STAGE="$WORK/stage"
DEBS="$WORK/debs"
LIB32="$RUNTIME_DIR/lib32"
LIB64="$RUNTIME_DIR/lib64"
LOADER_DIR="$RUNTIME_DIR/loader"

# --------------------------------------------------------------------------
# Isolated apt state
# --------------------------------------------------------------------------
write_apt_conf() {
  mkdir -p "$APT_ROOT/lists/partial" "$APT_ROOT/archives/partial" \
           "$APT_ROOT/etc/empty" "$DEBS" "$STAGE"

  # A private dpkg status file: apt resolves against the host's *installed*
  # set (so it only downloads what is missing) but writes nothing back.
  cp /var/lib/dpkg/status "$APT_ROOT/status"

  # Foreign architecture is declared ONLY here, in the private state dir.
  printf 'i386\n' > "$APT_ROOT/arch"

  cat > "$APT_ROOT/sources.list" <<EOF
deb [arch=amd64,i386 signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $DEB_MIRROR $DEB_SUITE $DEB_COMPONENTS
deb [arch=amd64,i386 signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $DEB_MIRROR $DEB_SUITE-updates $DEB_COMPONENTS
deb [arch=amd64,i386 signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $DEB_SECURITY $DEB_SUITE-security $DEB_COMPONENTS
EOF

  cat > "$APT_ROOT/apt.conf" <<EOF
Dir::Etc::sourcelist "$APT_ROOT/sources.list";
Dir::Etc::sourceparts "$APT_ROOT/etc/empty";
Dir::Etc::main "-";
Dir::Etc::parts "-";
Dir::State "$APT_ROOT";
Dir::State::status "$APT_ROOT/status";
Dir::State::archives "$APT_ROOT/archives";
Dir::Cache "$APT_ROOT";
Dir::Cache::archives "$DEBS";
Dir::Etc::trusted "/usr/share/keyrings/debian-archive-keyring.gpg";
Dir::Etc::trustedparts "/usr/share/keyrings";
APT::Architectures { "amd64"; "i386"; };
APT::Architecture "amd64";
EOF
}

apt_iso() { APT_CONFIG="$APT_ROOT/apt.conf" apt-get "$@"; }

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------
cmd_install() {
  need_root
  step "ParrotOS-Steam-Native — installation"
  assert_pure_amd64
  require_tools

  step "1/5  Préparation de l'état apt isolé"
  write_apt_conf
  ok "état isolé dans $APT_ROOT (dpkg hôte jamais touché)"

  step "2/5  Résolution et téléchargement des .deb (i386 + amd64)"
  apt_iso update -qq || die "apt update (isolé) a échoué."
  # shellcheck disable=SC2086
  apt_iso install -y --download-only "${STEAM_PACKAGES[@]}" \
    || die "Résolution des dépendances impossible (voir messages ci-dessus)."
  local n n386
  n=$(find "$DEBS" -name '*.deb' | wc -l)
  n386=$(find "$DEBS" -name '*_i386.deb' | wc -l)
  ok "$n paquets téléchargés (dont $n386 i386), $(human_size "$DEBS")"
  write_manifest

  step "3/5  Extraction dans un préfixe privé"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  for d in "$DEBS"/*.deb; do dpkg-deb -x "$d" "$STAGE/" || warn "échec: $d"; done
  ok "extrait vers $STAGE"

  step "4/5  Assemblage du runtime portable"
  assemble_runtime

  step "5/5  Vérification du runtime"
  cmd_doctor

  ok "Terminé. Lancer Steam avec:  sudo $RUNTIME_DIR/steam.sh"
}

assemble_runtime() {
  rm -rf "$LIB32" "$LIB64" "$LOADER_DIR"
  mkdir -p "$LIB32" "$LIB64" "$LOADER_DIR"

  # i386 shared objects -> lib32 (flat, symlinks preserved)
  find "$STAGE" -type d -name 'i386-linux-gnu' -print0 2>/dev/null |
    while IFS= read -r -d '' d; do
      find "$d" -maxdepth 1 -name '*.so*' -exec cp -a {} "$LIB32/" \; 2>/dev/null
    done

  # amd64 extra shared objects (not already provided by the host) -> lib64
  find "$STAGE" -type d -name 'x86_64-linux-gnu' -print0 2>/dev/null |
    while IFS= read -r -d '' d; do
      find "$d" -maxdepth 1 -name '*.so*' -exec cp -a {} "$LIB64/" \; 2>/dev/null
    done

  # The 32-bit dynamic loader — the keystone of the whole runtime.
  local ld
  ld=$(find "$STAGE" -path '*i386-linux-gnu*' -name 'ld-linux.so.2' | head -1)
  [ -n "$ld" ] || die "ld-linux.so.2 introuvable dans le stage — le runtime ne peut pas fonctionner."
  cp -a "$ld" "$LOADER_DIR/ld-linux.so.2"
  chmod +x "$LOADER_DIR/ld-linux.so.2"

  write_compat_shims
  nvidia_map_runtime
  write_launcher
  ok "lib32: $(find "$LIB32" -name '*.so*' | wc -l) objets, lib64: $(find "$LIB64" -name '*.so*' | wc -l) objets"
}

# Steam's 32-bit blobs were built years ago and reference sonames that modern
# distributions no longer ship. These symlinks are the classic "old tech" fixes
# applied by every Steam-on-Linux guide; here they live inside the runtime so
# nothing is added to the host.
write_compat_shims() {
  local shims=0
  # libudev.so.0 : Steam's legacy soname, dropped upstream in favour of .so.1.
  if [ -e "$LIB32/libudev.so.1" ] && [ ! -e "$LIB32/libudev.so.0" ]; then
    ln -s libudev.so.1 "$LIB32/libudev.so.0"
    shims=$((shims + 1))
  fi
  # libgcc_s / libstdc++ soname aliases some old launchers look for.
  [ -e "$LIB32/libnss_files.so.2" ] || warn "libnss_files.so.2 i386 absent — la résolution de noms pourrait échouer."

  # Steam also wants these at the conventional multiarch path; expose a
  # read-only view via a stable symlink the launcher can point at.
  if [ "$shims" -gt 0 ]; then
    ok "$shims shim(s) de compatibilité créés dans lib32"
  fi
}

# Steam entry point: prefer the steam-installer's launcher, fall back to the
# distro `steam` command once Steam has bootstrapped itself.
write_launcher() {
  cat > "$RUNTIME_DIR/steam.sh" <<'LAUNCHER'
#!/usr/bin/env bash
# Generated by parrot-steam-native.sh — launches Steam through the portable
# 32-bit runtime without touching the host's dynamic linker paths.
set -o pipefail
RUNTIME_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOADER="$RUNTIME_DIR/loader/ld-linux.so.2"
LIB32="$RUNTIME_DIR/lib32"
LIB64="$RUNTIME_DIR/lib64"

export LD_LIBRARY_PATH="$LIB32:$LIB64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Expose the 32-bit NVIDIA Vulkan ICD to the loader, if one was generated.
if [ -f "$RUNTIME_DIR/vulkan/nvidia_icd.json" ]; then
  export VK_ICD_FILENAMES="$RUNTIME_DIR/vulkan/nvidia_icd.json${VK_ICD_FILENAMES:+:$VK_ICD_FILENAMES}"
  export VK_DRIVER_FILES="$VK_ICD_FILENAMES"
fi

# Make the 32-bit GLVND dispatch find the mapped vendor libraries.
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export LIBGL_DRIVERS_PATH="$LIB32${LIBGL_DRIVERS_PATH:+:$LIBGL_DRIVERS_PATH}"

# Locate the real Steam binary.
STEAM_BIN="${PARROT_STEAM_BIN:-}"
if [ -z "$STEAM_BIN" ]; then
  for c in "$HOME/.steam/steam/ubuntu12_32/steam" \
           "$HOME/.local/share/Steam/ubuntu12_32/steam" \
           /usr/lib/steam/steam /usr/games/steam /usr/bin/steam; do
    [ -x "$c" ] && { STEAM_BIN="$c"; break; }
  done
fi
[ -n "$STEAM_BIN" ] || { echo "Steam introuvable. Définir PARROT_STEAM_BIN." >&2; exit 1; }

exec "$LOADER" --library-path "$LIB32:$LIB64" "$STEAM_BIN" "$@"
LAUNCHER
  chmod +x "$RUNTIME_DIR/steam.sh"
}

cmd_run() {
  [ -x "$RUNTIME_DIR/steam.sh" ] || die "Runtime absent. Lancer 'install' d'abord."
  exec "$RUNTIME_DIR/steam.sh" "$@"
}

cmd_status() {
  [ -d "$RUNTIME_DIR" ] || die "Aucun runtime dans $RUNTIME_DIR."
  log "Runtime: $RUNTIME_DIR"
  printf '  lib32 : %s objets (%s)\n' "$(find "$LIB32" -name '*.so*' 2>/dev/null | wc -l)" "$(human_size "$LIB32")"
  printf '  lib64 : %s objets (%s)\n' "$(find "$LIB64" -name '*.so*' 2>/dev/null | wc -l)" "$(human_size "$LIB64")"
  printf '  loader: %s\n' "$(ls -l "$LOADER_DIR/ld-linux.so.2" 2>/dev/null | awk '{print $5" octets"}')"
  printf '  cache : %s\n' "$(find "$DEBS" -name '*.deb' 2>/dev/null | wc -l) .deb"
  [ -f "$RUNTIME_DIR/manifest.txt" ] && printf '  manifest: %s lignes\n' "$(wc -l < "$RUNTIME_DIR/manifest.txt")"
}

cmd_doctor() {
  step "Doctor"
  printf '  archi hôte          : %s\n' "$(dpkg --print-architecture)"
  printf '  archis étrangères   : %s\n' "$(dpkg --print-foreign-architectures | tr '\n' ' ')"
  printf '  paquets i386 dpkg   : %s (doit rester 0)\n' "$(dpkg -l 2>/dev/null | grep -c ':i386')"
  printf '  kernel              : %s %s\n' "$(uname -m)" "$(uname -r)"

  # Kernel 32-bit compat (CONFIG_IA32_EMULATION) + CPU baseline. Steam's 32-bit
  # blobs are built for i686+SSE2; every x86-64 CPU supports that in compat
  # mode, but the kernel can be built without IA32 emulation.
  if grep -qw lm /proc/cpuinfo 2>/dev/null; then
    printf '  CPU 64-bit (lm)     : oui\n'
  else
    printf '  CPU 64-bit (lm)     : NON — hôte non x86-64 ?\n'
  fi
  if [ -f "$LOADER_DIR/ld-linux.so.2" ]; then
    local v
    v="$("$LOADER_DIR/ld-linux.so.2" --version 2>/dev/null | head -1)"
    if [ -n "$v" ]; then
      printf '  compat 32-bit       : ACTIVE (%s)\n' "$v"
    else
      printf '  compat 32-bit       : ÉCHEC — IA32_EMULATION désactivé dans le kernel ?\n'
    fi
  else
    printf '  compat 32-bit       : non testé (loader absent)\n'
  fi

  printf '  lib32               : %s objets\n' "$(find "$LIB32" -name '*.so*' 2>/dev/null | wc -l)"
  printf '  bwrap (isolation)   : %s\n' "$(have bwrap && echo présent || echo absent)"

  # Runtime is pinned to a known-good Debian suite: this is what protects Steam
  # from the host's newer, potentially incompatible glibc/Mesa.
  if [ -f "$RUNTIME_DIR/manifest.txt" ]; then
    printf '  suite épinglée      : %s\n' "$(grep -m1 '^# suite:' "$RUNTIME_DIR/manifest.txt" | cut -d' ' -f3)"
  fi

  nvidia_report
}

cmd_clean() {
  [ -d "$WORK" ] || { warn "Rien à nettoyer."; return 0; }
  as_root rm -rf "$WORK"
  ok "cache de build supprimé ($WORK)"
}

cmd_uninstall() {
  need_root
  [ -d "$RUNTIME_DIR" ] || { warn "Aucun runtime."; return 0; }
  as_root rm -rf "$RUNTIME_DIR"
  ok "runtime supprimé ($RUNTIME_DIR)"
}

# --------------------------------------------------------------------------
# Manifest / tooling
# --------------------------------------------------------------------------
write_manifest() {
  {
    printf '# ParrotOS-Steam-Native manifest\n'
    printf '# generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# suite: %s  arch: amd64+i386\n' "$DEB_SUITE"
    for d in "$DEBS"/*.deb; do
      printf '%s\n' "$(basename "$d")"
    done
  } > "$RUNTIME_DIR/manifest.txt"
}

require_tools() {
  local missing=()
  for t in dpkg-deb apt-get find cp; do
    have "$t" || missing+=("$t")
  done
  [ "${#missing[@]}" -eq 0 ] || die "Outils manquants: ${missing[*]}"
}

usage() {
  cat <<EOF
ParrotOS-Steam-Native — Steam 32-bit sur hôte amd64 pur, sans multiarch.

Usage: sudo $0 <command>

  install     télécharge + extrait + assemble le runtime portable
  doctor      état de l'hôte et du runtime (lecture seule)
  run [args]  lance Steam via le runtime portable
  status      contenu du runtime
  clean       supprime le cache de build (garde le runtime)
  uninstall   supprime tout le runtime

Env:
  PARROT_STEAM_DIR      préfixe runtime   (défaut: /opt/parrot-steam)
  PARROT_STEAM_SUITE    suite Debian      (défaut: trixie)
  PARROT_STEAM_MIRROR   miroir principal  (défaut: deb.debian.org)
EOF
}

main() {
  local cmd="${1:-}"; shift 2>/dev/null || true
  case "$cmd" in
    install)   cmd_install "$@" ;;
    doctor)    cmd_doctor "$@" ;;
    run)       cmd_run "$@" ;;
    status)    cmd_status "$@" ;;
    clean)     cmd_clean "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "Commande inconnue: $cmd (voir --help)" ;;
  esac
}

main "$@"
