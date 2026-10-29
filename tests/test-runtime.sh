#!/usr/bin/env bash
#
# test-runtime.sh — validate a built ParrotOS-Steam-Native runtime.
# Read-only: it never modifies the host or the runtime.
#
# Exit code 0 = all checks passed.
set -o pipefail

RUNTIME_DIR="${PARROT_STEAM_DIR:-/opt/parrot-steam}"
LOADER="$RUNTIME_DIR/loader/ld-linux.so.2"
LIB32="$RUNTIME_DIR/lib32"
STAGE="$RUNTIME_DIR/.build/stage"

pass=0; fail=0
ck() { # ck "label" "expected" "actual"
  if [ "$2" = "$3" ]; then
    printf '  \033[1;32mPASS\033[0m  %-42s %s\n' "$1" "$3"; pass=$((pass+1))
  else
    printf '  \033[1;31mFAIL\033[0m  %-42s got=%s want=%s\n' "$1" "$3" "$2"; fail=$((fail+1))
  fi
}

echo "== ParrotOS-Steam-Native — runtime tests =="

# 1. Host must remain pure amd64.
ck "no foreign architectures" "" "$(dpkg --print-foreign-architectures | tr -d '\n')"
ck "zero i386 packages in host dpkg" "0" "$(dpkg -l 2>/dev/null | grep -c ':i386')"

# 2. Runtime artifacts present.
ck "loader present" "yes" "$([ -x "$LOADER" ] && echo yes || echo no)"
ck "lib32 non-empty" "yes" "$([ -n "$(ls -A "$LIB32" 2>/dev/null)" ] && echo yes || echo no)"
ck "launcher present" "yes" "$([ -x "$RUNTIME_DIR/steam.sh" ] && echo yes || echo no)"

# 3. Loader is 32-bit and runs.
magic="$(head -c 5 "$LOADER" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
ck "loader is ELF 32-bit" "7f454c4601" "$magic"
if "$LOADER" --version >/dev/null 2>&1; then
  ck "loader executes" "yes" "yes"
else
  ck "loader executes" "yes" "no"
fi

# 4. Dependency resolution of a representative 32-bit library.
if [ -e "$LIB32/libgtk-3.so.0" ]; then
  out="$("$LOADER" --library-path "$LIB32" --list "$LIB32/libgtk-3.so.0" 2>&1)"
  missing="$(printf '%s\n' "$out" | grep -c 'not found')"
  ck "libgtk-3.so.0 missing deps" "0" "$missing"
fi

# 5. A real i386 executable actually runs (linkage succeeds, no loader error).
BIN="$(find "$STAGE" -type f -path '*i386*' -name 'gio-querymodules' 2>/dev/null | head -1)"
if [ -n "$BIN" ]; then
  out="$("$LOADER" --library-path "$LIB32" "$BIN" 2>&1)"
  if printf '%s' "$out" | grep -qE 'error while loading shared libraries|cannot open shared object'; then
    ck "i386 binary executes" "no loader error" "loader error"
  else
    ck "i386 binary executes" "no loader error" "no loader error"
  fi
else
  echo "  SKIP  i386 test binary not found (stage cleaned?)"
fi

# 6. Compatibility shims.
ck "libudev.so.0 shim" "yes" "$([ -e "$LIB32/libudev.so.0" ] && echo yes || echo no)"

echo
printf '== %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
