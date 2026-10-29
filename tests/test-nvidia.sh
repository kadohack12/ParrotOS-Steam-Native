#!/usr/bin/env bash
#
# test-nvidia.sh — validate the NVIDIA 32-bit mapping logic with a simulated
# driver, so it can run on a machine with no GPU.
#
# Builds a fake /proc/driver/nvidia/version and a fake set of 32-bit libraries
# (including one deliberately mismatched version) and asserts that:
#   - the kernel module version is parsed;
#   - matching libraries are mapped into lib32 with both soname aliases;
#   - the mismatched library is rejected;
#   - a Vulkan ICD manifest is generated for the mapped version.
#
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$(mktemp -d)"
trap 'rm -rf "$SIM"' EXIT

mkdir -p "$SIM/proc" "$SIM/host32" "$SIM/runtime"
printf 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  550.120  Fri Jan 10 00:00:00 UTC 2025\n' \
  > "$SIM/proc/version"
for f in libnvidia-glcore.so.550.120 libnvidia-tls.so.550.120 \
         libGLX_nvidia.so.550.120 libEGL_nvidia.so.550.120 \
         libnvidia-vulkan-producer.so.550.120; do
  printf 'fake-elf32 %s\n' "$f" > "$SIM/host32/$f"
done
printf 'fake-elf32 old\n' > "$SIM/host32/libnvidia-glsi.so.545.29"   # mismatch

pass=0; fail=0
ck() {
  if [ "$2" = "$3" ]; then
    printf '  \033[1;32mPASS\033[0m  %-42s %s\n' "$1" "$3"; pass=$((pass+1))
  else
    printf '  \033[1;31mFAIL\033[0m  %-42s got=%s want=%s\n' "$1" "$3" "$2"; fail=$((fail+1))
  fi
}

echo "== ParrotOS-Steam-Native — NVIDIA mapping tests (simulated) =="

out="$(
  PARROT_NVIDIA_PROC="$SIM/proc/version" bash -c '
    . "'"$ROOT"'/lib/common.sh"
    . "'"$ROOT"'/lib/nvidia.sh"
    RUNTIME_DIR="'"$SIM"'/runtime"
    LIB32="$RUNTIME_DIR/lib32"; LIB64="$RUNTIME_DIR/lib64"
    NVIDIA_LIB32_DIRS=("'"$SIM"'/host32")
    NVIDIA_FETCH_I386=0
    mkdir -p "$LIB32"
    nvidia_map_runtime
  ' 2>&1
)"

ck "kernel module version parsed" "550.120" "$(awk '/NVRM/{for(i=1;i<=NF;i++)if($i~/^[0-9]+\.[0-9]+/){print $i;exit}}' "$SIM/proc/version")"
ck "matching lib mapped"          "yes" "$([ -e "$SIM/runtime/lib32/libnvidia-glcore.so.550.120" ] && echo yes || echo no)"
ck "soname alias created"         "yes" "$([ -e "$SIM/runtime/lib32/libnvidia-glcore.so" ] && echo yes || echo no)"
ck "GLX_nvidia mapped"            "yes" "$([ -e "$SIM/runtime/lib32/libGLX_nvidia.so.550.120" ] && echo yes || echo no)"
ck "mismatched lib rejected"      "no"  "$([ -e "$SIM/runtime/lib32/libnvidia-glsi.so.545.29" ] && echo yes || echo no)"
ck "Vulkan ICD generated"         "yes" "$([ -f "$SIM/runtime/vulkan/nvidia_icd.json" ] && echo yes || echo no)"
ck "ICD points to mapped version" "yes" "$(grep -q 'libGLX_nvidia.so.550.120' "$SIM/runtime/vulkan/nvidia_icd.json" && echo yes || echo no)"
ck "rejection reported"           "yes" "$(printf '%s' "$out" | grep -q 'IGNORÉ.*545.29' && echo yes || echo no)"

echo
printf '== %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
