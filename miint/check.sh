#!/usr/bin/env bash
# miint/check.sh: environment checks for the miint HMMER patches.
#
# Unit tests live in HMMER's (and Easel's) own test drivers and run with
# `make check`. These checks need something a test driver can't arrange
# for itself, such as a sanitizer build. Easel's own environment checks
# are in easel/miint/check.sh.
#
# Usage:  miint/check.sh [check ...]   (from any directory; no names = all)
# Builds in <repo>/build-miint-* (gitignored by build-*).
# Prints PASS / FAIL / SKIP per check; exits 1 if any check failed.
# A SKIP means a tool this host lacks; it is listed again at the end.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WANT=" $* "

npass=0; nfail=0; skipped=()
pass() { echo "PASS  $1"; npass=$((npass+1)); }
fail() { echo "FAIL  $1: $2"; nfail=$((nfail+1)); }
skip() { echo "SKIP  $1: $2"; skipped+=("$1 ($2)"); }
want() { [ "$WANT" = "  " ] || [[ "$WANT" == *" $1 "* ]]; }

# Run a build step, logging to $log; on failure show the log's tail.
step() { # log cmd...
  local log=$1; shift
  if "$@" > "$log" 2>&1; then return 0; fi
  echo "      command failed: $*  (log: $log)"; tail -n 15 "$log" | sed 's/^/      | /'
  return 1
}

# Configure (running autoconf first) and build HMMER in <dir> with extra
# configure arguments.
build() { # dir configure-args...
  local dir=$1; shift
  mkdir -p "$dir"
  step "$dir/autoconf.log" bash -c "cd '$ROOT' && autoconf" &&
  step "$dir/configure.log" bash -c 'cd "$1" && shift && "$@"' sh "$dir" "$ROOT/configure" "$@" &&
  step "$dir/make.log" make -C "$dir" -j8
}

# --- fatal-audit: no process exits on paths miint runs in-process --------
# miint runs HMMER inside the DuckDB process, so a failure must come back
# as a status (and, for an exception, through Easel's handler), never
# exit() or abort() the host. p7_Fail()/p7_Die()/esl_fatal() exit; and a
# call whose failing status is dropped carries on with a NULL or stale
# result. This lists both in the functions listed below: the paths
# patched in M0 (each later milestone adds the functions it reaches).
#   <file>:<function>
AUDIT_FUNCS="
src/p7_domaindef.c:reparameterize_model
src/p7_domaindef.c:rescore_isolated_domain
src/p7_pipeline.c:p7_Pipeline
src/p7_pipeline.c:p7_pli_postViterbi_LongTarget
"
# Calls whose status must be checked; a bare statement drops it.
# reparameterize_model() can only fail when given a sequence (sq).
AUDIT_MUST_CHECK='^[[:space:]]*(p7_tophits_CreateNextHit[[:space:]]*\(|reparameterize_model[[:space:]]*\([^)]*[(,][[:space:]]*sq[[:space:]]*,)'
AUDIT_EXITS='(^|[^_a-zA-Z0-9])(p7_Fail|p7_Die|esl_fatal|exit|abort)[[:space:]]*\('
check_fatal_audit() {
  local entry file func body found=""
  for entry in $AUDIT_FUNCS; do
    file=${entry%%:*}; func=${entry#*:}
    # A function body runs from "<func>(" at column 0 to the next "}" at column 0.
    body=$(awk -v f="$func" '$0 ~ "^"f"[ \t]*\\(" {on=1} on {print FILENAME":"FNR": "$0} on && /^}/ {exit}' "$ROOT/$file" |
           sed -e 's|//.*||' -e 's|/\*.*\*/||g')   # ignore one-line comments
    if [ -z "$body" ]; then fail "fatal-audit" "function $func not found in $file"; return; fi
    found+=$(echo "$body" | grep -E -- "$AUDIT_EXITS" | sed "s|^|      exit call in $func: |")$'\n'
    found+=$(echo "$body" | grep -E -- "$(echo "$AUDIT_MUST_CHECK" | sed 's/^\^/^[^:]*:[0-9]*: /')" | sed "s|^|      unchecked in $func: |")$'\n'
  done
  found=$(echo "$found" | sed '/^$/d' | sed "s|$ROOT/||")
  if [ -z "$found" ]; then pass "fatal-audit"
  else echo "$found"; fail "fatal-audit" "$(echo "$found" | wc -l) site(s) above"
  fi
}
want fatal-audit      && check_fatal_audit

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
want ubsan-float-cast && check_ubsan

# --- emcc-build: HMMER's libraries compile for WebAssembly, SSE included -
# duckdb-wasm builds HMMER with Emscripten, through its emulation of SSE
# on wasm SIMD128 (-msimd128 -msse -msse2; minimap2 does the same).
# --enable-sse makes configure fail rather than quietly drop the SSE
# code, and the eslENABLE_SSE test confirms it. Builds the libraries a
# program links (Easel, libdivsufsort, libhmmer with impl_sse), not the
# programs.
EMCC_BUILD="$ROOT/build-miint-emcc"
check_emcc() {
  local errs name t ok=1
  if ! command -v emconfigure > /dev/null 2>&1; then
    skip "emcc-build" "emconfigure not on PATH (source emsdk_env.sh)"; return
  fi
  name="emcc-build (emcc $(emcc --version 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1))"
  mkdir -p "$EMCC_BUILD"
  if ! step "$EMCC_BUILD/autoconf.log" bash -c "cd '$ROOT' && autoconf" ||
     ! step "$EMCC_BUILD/configure.log" bash -c "cd '$EMCC_BUILD' && emconfigure '$ROOT/configure' \
         --enable-sse --disable-threads --disable-mpi CC=emcc CFLAGS='-O2 -msimd128 -msse -msse2'"; then
    fail "$name" "configure failed"; return
  fi
  if ! grep -q '^#define eslENABLE_SSE 1' "$EMCC_BUILD/src/p7_config.h"; then
    fail "$name" "configure did not enable the SSE code"; return
  fi
  : > "$EMCC_BUILD/make.log"
  for t in "easel libeasel.a" "libdivsufsort libdivsufsort.a" "src libhmmer.a"; do
    set -- $t
    emmake make -C "$EMCC_BUILD/$1" -j8 -k "$2" >> "$EMCC_BUILD/make.log" 2>&1 || ok=0
  done
  if [ $ok = 0 ]; then
    # Name the objects that failed, and where an error came in through an #include.
    errs=$(grep -oE '\*\*\* \[[^]]*: [^] ]+\.o\]' "$EMCC_BUILD/make.log" | grep -oE '[^ ]+\.o' | sort -u | tr '\n' ' ')
    errs+=$(grep -oE "^In file included from $ROOT/[^ ]+:[0-9]+" "$EMCC_BUILD/make.log" | sed "s|In file included from $ROOT/|; included from |" | sort -u | tr '\n' ' ')
    fail "$name" "${errs:-make failed} (log: $EMCC_BUILD/make.log)"; return
  fi
  pass "$name"
}
want emcc-build && check_emcc

# --- ftz-daz-off: impl_Init() leaves FTZ and DAZ off ---------------------
# FTZ (flush-to-zero) and DAZ (denormals-are-zero) are per-thread x86
# modes that change floating point results. miint never sets them, so
# the CLI it uses as its parity oracle must not either: miint/
# ftzdaz_check.c calls impl_Init() and reads MXCSR back. It is built
# with -msse3, the case where stock HMMER set DAZ regardless of
# configure. Needs only configure's headers, not a build.
NATIVE="$ROOT/build-miint-native"
check_ftz_daz() {
  local bin="$NATIVE/ftzdaz_check" out rc
  case $(uname -m) in
    x86_64|i?86) ;;
    *) skip "ftz-daz-off" "not an x86 host"; return ;;
  esac
  mkdir -p "$NATIVE"
  if ! step "$NATIVE/autoconf.log" bash -c "cd '$ROOT' && autoconf" ||
     ! step "$NATIVE/configure.log" bash -c "cd '$NATIVE' && '$ROOT/configure'"; then
    fail "ftz-daz-off" "configure failed"; return
  fi
  if ! step "$NATIVE/ftzdaz_check.log" ${CC:-cc} -O2 -msse3 -I"$NATIVE/src" -I"$NATIVE/easel" \
         -I"$ROOT/src" -I"$ROOT/src/impl_sse" -I"$ROOT/easel" -o "$bin" "$ROOT/miint/ftzdaz_check.c" -lm; then
    fail "ftz-daz-off" "could not build miint/ftzdaz_check.c"; return
  fi
  out=$("$bin"); rc=$?
  case $rc in
    0) pass "ftz-daz-off" ;;
    1) fail "ftz-daz-off" "$out" ;;
    *) fail "ftz-daz-off" "premise not met: $out" ;;
  esac
}
want ftz-daz-off && check_ftz_daz

# --- summary ------------------------------------------------------------
echo "----"
echo "$npass passed, $nfail failed, ${#skipped[@]} skipped"
for s in "${skipped[@]+"${skipped[@]}"}"; do echo "  skipped: $s"; done
[ $nfail = 0 ]
