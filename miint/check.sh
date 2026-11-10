#!/usr/bin/env bash
# miint/check.sh: environment checks for the miint HMMER patches.
#
# Unit tests live in HMMER's (and Easel's) own test drivers and run with
# `make check`. These checks need something a test driver can't arrange
# for itself, such as a sanitizer build. Easel's own environment checks
# are in easel/miint/check.sh.
#
# Usage:  miint/check.sh          (from any directory)
# Builds in <repo>/build-miint-* (gitignored by build-*).
# Prints PASS / FAIL / SKIP per check; exits 1 if any check failed.
# A SKIP means a tool this host lacks; it is listed again at the end.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)

npass=0; nfail=0; skipped=()
pass() { echo "PASS  $1"; npass=$((npass+1)); }
fail() { echo "FAIL  $1: $2"; nfail=$((nfail+1)); }
skip() { echo "SKIP  $1: $2"; skipped+=("$1 ($2)"); }

# Run a build step, logging to $log; on failure show the log's tail.
step() { # log cmd...
  local log=$1; shift
  if "$@" > "$log" 2>&1; then return 0; fi
  echo "      command failed: $*  (log: $log)"; tail -n 15 "$log" | sed 's/^/      | /'
  return 1
}

# Configure and build HMMER in <dir> with extra configure arguments.
build() { # dir configure-args...
  local dir=$1; shift
  mkdir -p "$dir"
  step "$dir/configure.log" bash -c 'cd "$1" && shift && "$@"' sh "$dir" "$ROOT/configure" "$@" &&
  step "$dir/make.log" make -C "$dir" -j8
}

if ! step "$ROOT/build-miint-autoconf.log" bash -c "cd '$ROOT' && autoconf"; then
  fail "autoconf" "autoconf failed"
fi

# --- ubsan-float-cast: no out-of-range float -> integer casts ------------
# A cast of a float outside the target type's range is undefined
# behaviour, and targets differ: x86 happens to wrap a negative float
# cast to uint8_t mod 256, while WebAssembly saturates it to 0. HMMER
# 3.4's biased_byteify() did exactly that (#339), so on wasm no target
# ever passed the MSV filter. gcc's -fsanitize=float-cast-overflow
# reports such casts; -fno-sanitize-recover makes the first one fatal.
UBSAN="$ROOT/build-miint-ubsan"
check_ubsan() {
  local flags="-fsanitize=float-cast-overflow -fno-sanitize-recover=float-cast-overflow"
  if ! echo 'int main(void){return 0;}' | ${CC:-cc} $flags -x c -o /dev/null - > /dev/null 2>&1; then
    skip "ubsan-float-cast" "${CC:-cc} lacks -fsanitize=float-cast-overflow"; return
  fi
  if ! build "$UBSAN" CFLAGS="-O2 -g $flags" LDFLAGS="$flags"; then
    fail "ubsan-float-cast" "sanitizer build failed"; return
  fi
  if step "$UBSAN/hmmsearch.log" "$UBSAN/src/hmmsearch" "$ROOT/tutorial/globins4.hmm" "$ROOT/tutorial/globins45.fa"; then
    pass "ubsan-float-cast"
  else
    fail "ubsan-float-cast" "$(grep -m1 'runtime error' "$UBSAN/hmmsearch.log" | sed 's|.*/src/||')"
  fi
}
check_ubsan

# --- summary ------------------------------------------------------------
echo "----"
echo "$npass passed, $nfail failed, ${#skipped[@]} skipped"
for s in "${skipped[@]+"${skipped[@]}"}"; do echo "  skipped: $s"; done
[ $nfail = 0 ]
