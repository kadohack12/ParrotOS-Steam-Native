#!/usr/bin/env bash
# ParrotOS-Steam-Native — NVIDIA 32-bit GL/Vulkan mapping.
#
# The proprietary NVIDIA driver installs its user-space libraries for the host
# architecture only (amd64). Steam, however, is 32-bit and needs the *32-bit*
# GL/Vulkan stack. On top of that the NVIDIA user-space libraries MUST match the
# kernel module version exactly, or every GL/Vulkan call fails with
# "Failed to initialize NVML: Driver/library version mismatch".
#
# This module detects the version of the *already loaded* kernel module and maps
# the matching 32-bit user-space libraries into the portable runtime, so the
# runtime and the kernel agree. Nothing is installed on the host.
#
# Sourced by parrot-steam-native.sh; never executed directly.

NVIDIA_PROC_VERSION="${PARROT_NVIDIA_PROC:-/proc/driver/nvidia/version}"

# Candidate directories holding 32-bit user-space libs (host or extracted).
NVIDIA_LIB32_DIRS=(
  "$LIB32"
  /usr/lib/i386-linux-gnu
  /usr/lib32
  /emul/ia32-linux/usr/lib
  /usr/lib/nvidia
)

nvidia_kernel_module_present() {
  [ -e "$NVIDIA_PROC_VERSION" ] || [ -e /dev/nvidiactl ] || [ -e /dev/nvidia0 ]
}

# Extract the upstream driver version from the loaded kernel module, e.g.
#   "NVRM version: NVIDIA UNIX x86_64 Kernel Module  550.120  Fri ..."
#   -> 550.120
nvidia_kernel_version() {
  [ -r "$NVIDIA_PROC_VERSION" ] || return 1
  awk '
    /NVRM version/ {
      for (i = 1; i <= NF; i++)
        if ($i ~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) { print $i; exit }
    }' "$NVIDIA_PROC_VERSION"
}

# Find a 32-bit user-space library by glob across the candidate dirs.
nvidia_find_lib32() {
  local pat="$1" d
  for d in "${NVIDIA_LIB32_DIRS[@]}"; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -name "$pat" 2>/dev/null | head -1
  done
}

# Pull the driver version encoded in a library filename
# (libnvidia-glcore.so.550.120 -> 550.120).
nvidia_lib_version() {
  local base
  base="$(basename "$1")"
  printf '%s\n' "$base" | sed -n 's/.*\.so\.\([0-9][0-9.]*\).*/\1/p'
}

# Libraries Steam needs for GL + Vulkan through the NVIDIA stack.
NVIDIA_REQUIRED_LIBS=(
  'libnvidia-glcore.so.*'
  'libnvidia-tls.so.*'
  'libnvidia-glsi.so.*'
  'libnvidia-eglcore.so.*'
  'libnvidia-egl-wayland.so.*'
  'libnvidia-allocator.so.*'
  'libnvidia-gpucomp.so.*'
  'libGLX_nvidia.so.*'
  'libEGL_nvidia.so.*'
  'libnvidia-vulkan-producer.so.*'
  'libnvoptix.so.*'
)

nvidia_report() {
  step "NVIDIA"
  if ! nvidia_kernel_module_present; then
    printf '  pilote NVIDIA        : absent (rien à mapper)\n'
    return 0
  fi
  local kver
  kver="$(nvidia_kernel_version)"
  printf '  module noyau chargé  : oui\n'
  printf '  version du module    : %s\n' "${kver:-inconnue}"

  local found=0 matched=0
  for pat in "${NVIDIA_REQUIRED_LIBS[@]}"; do
    local f
    f="$(nvidia_find_lib32 "$pat")"
    if [ -n "$f" ]; then
      found=$((found + 1))
      local lver
      lver="$(nvidia_lib_version "$f")"
      if [ -n "$kver" ] && [ "$lver" = "$kver" ]; then
        matched=$((matched + 1))
      fi
    fi
  done
  printf '  libs 32-bit trouvées : %s/%s\n' "$found" "${#NVIDIA_REQUIRED_LIBS[@]}"
  printf '  version concordante  : %s/%s\n' "$matched" "${#NVIDIA_REQUIRED_LIBS[@]}"
  if [ "$found" -gt 0 ] && [ "$matched" -lt "$found" ]; then
    warn "Désaccord de version détecté — les libs 32-bit ne correspondent pas au module noyau."
    warn "C'est la cause classique de 'Driver/library version mismatch'."
  fi
}

# Main mapping: link the matching 32-bit libs into the runtime lib32 and
# generate a Vulkan ICD manifest pointing at the 32-bit driver.
nvidia_map_runtime() {
  nvidia_kernel_module_present || return 0

  local kver
  kver="$(nvidia_kernel_version)"
  [ -n "$kver" ] || { warn "Version du module NVIDIA illisible — mapping ignoré."; return 0; }

  step "NVIDIA : mappage du pilote chargé (v$kver)"
  mkdir -p "$LIB32" "$RUNTIME_DIR/vulkan"
  local linked=0 mismatched=0 missing=()

  for pat in "${NVIDIA_REQUIRED_LIBS[@]}"; do
    local src
    src="$(nvidia_find_lib32 "$pat")"
    if [ -z "$src" ]; then
      missing+=("$pat")
      continue
    fi

    local lver
    lver="$(nvidia_lib_version "$src")"
    if [ -n "$lver" ] && [ "$lver" != "$kver" ]; then
      warn "IGNORÉ $pat : version $lver != module $kver (incompatibilité noyau/userspace)"
      mismatched=$((mismatched + 1))
      continue
    fi

    # Copy the real object into lib32 (skip when already there), then add the
    # unversioned alias the loader asks for.
    local base soname_major
    base="$(basename "$src")"
    if [ "$(readlink -f "$src")" != "$(readlink -f "$LIB32/$base" 2>/dev/null)" ]; then
      cp -a "$src" "$LIB32/$base"
    fi
    soname_major="$(printf '%s\n' "$base" | sed -n 's/\(.*\.so\)\.[0-9].*/\1/p')"
    if [ -n "$soname_major" ]; then
      local alias="${soname_major##*/}"
      [ -e "$LIB32/$alias" ] || ln -sf "$base" "$LIB32/$alias" 2>/dev/null || true
    fi
    linked=$((linked + 1))
  done

  ok "$linked lib(s) NVIDIA 32-bit mappée(s) sur le module v$kver"
  [ "$mismatched" -gt 0 ] && warn "$mismatched lib(s) ignorée(s) pour cause de version."
  if [ "${#missing[@]}" -gt 0 ]; then
    warn "Libs 32-bit absentes de l'hôte (${#missing[@]}):"
    printf '      %s\n' "${missing[@]}"
    if [ "${NVIDIA_FETCH_I386:-1}" = "1" ] && declare -F apt_iso >/dev/null 2>&1; then
      nvidia_fetch_i386 "$kver" || warn "Récupération automatique i386 indisponible."
    else
      warn "→ Extraire ces objets via l'état apt isolé (voir README, section NVIDIA)."
    fi
  fi

  nvidia_write_vulkan_icd "$kver"
}

# Fetch the 32-bit NVIDIA user-space libraries from the host's own repositories
# through the project's isolated apt state (never registered in the host dpkg),
# then unpack them straight into the runtime lib32.
nvidia_fetch_i386() {
  local kver="$1"
  step "NVIDIA : récupération des libs 32-bit via apt isolé"

  # nvidia-driver-libs:i386 is the meta-package that ships the 32-bit GL/Vulkan
  # objects on Debian/Parrot; the version must match the loaded kernel module.
  local pkgs=(nvidia-driver-libs:i386)

  local dl="$WORK/nvidia-i386"
  rm -rf "$dl"; mkdir -p "$dl"

  apt_iso install -y --download-only --no-install-recommends "${pkgs[@]}" >/dev/null 2>&1 || true

  local got
  got="$(find "$DEBS" -name 'nvidia-*.deb' -o -name 'libnvidia-*.deb' 2>/dev/null | wc -l)"
  if [ "$got" -eq 0 ]; then
    warn "Aucun .deb NVIDIA i386 trouvé dans les dépôts configurés."
    warn "Le runtime NVIDIA de l'hôte peut ne pas fournir les objets 32-bit."
    return 1
  fi

  local n=0
  for d in $(find "$DEBS" -name 'nvidia-*.deb' -o -name 'libnvidia-*.deb' 2>/dev/null); do
    dpkg-deb -x "$d" "$dl/" 2>/dev/null || continue
    n=$((n + 1))
  done

  find "$dl" -type d -name 'i386-linux-gnu' -print0 2>/dev/null |
    while IFS= read -r -d '' d; do
      find "$d" -maxdepth 1 \( -name 'libnvidia*.so*' -o -name 'libGLX_nvidia.so*' \
        -o -name 'libEGL_nvidia.so*' \) -exec cp -a {} "$LIB32/" \;
    done

  ok "$n .deb NVIDIA extraits → lib32"
  nvidia_link_aliases
  return 0
}

# Re-create unversioned .so.N aliases for every versioned NVIDIA object in lib32.
nvidia_link_aliases() {
  local f base alias
  for f in "$LIB32"/libnvidia*.so.* "$LIB32"/libGLX_nvidia.so.* "$LIB32"/libEGL_nvidia.so.*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    alias="$(printf '%s\n' "$base" | sed -n 's/\(.*\.so\)\.[0-9].*/\1/p')"
    [ -n "$alias" ] && [ ! -e "$LIB32/$alias" ] && ln -sf "$base" "$LIB32/$alias" 2>/dev/null || true
  done
}

nvidia_write_vulkan_icd() {
  local kver="$1"
  local icd
  icd="$(nvidia_find_lib32 'libGLX_nvidia.so.*')"
  # Prefer the dedicated Vulkan ICD if present.
  local vk
  vk="$(nvidia_find_lib32 'libnvidia-vulkan-producer.so.*')"

  mkdir -p "$RUNTIME_DIR/vulkan"
  cat > "$RUNTIME_DIR/vulkan/nvidia_icd.json" <<EOF
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "$LIB32/libGLX_nvidia.so.$kver",
    "api_version": "1.3.0"
  }
}
EOF
  ok "manifeste Vulkan 32-bit écrit (nvidia_icd.json, v$kver)"
  if [ -n "$vk" ]; then
    printf '  producteur Vulkan    : %s\n' "$(basename "$vk")"
  fi
}
