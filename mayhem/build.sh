#!/usr/bin/env bash
#
# mayhem/build.sh — build SnapRAID twice from the autotools tree, out of tree under obj/ (gitignored):
#   obj/san/snapraid   sanitized (ASan+UBSan, halting) — the fuzz target (`snapraid --gen-conf <file>`)
#   obj/test/*         normal flags — the real binary plus the upstream test helpers for mayhem/test.sh
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# configure and Makefile.in are not tracked upstream.
autoreconf -f -i

mkdir -p obj/san obj/test

# 1) Sanitized build: the project itself carries $SANITIZER_FLAGS and DWARF-3. LeakSanitizer is turned off
#    at build time by linking the __lsan_is_turned_off hook object.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o obj/lsan_off.o
(cd obj/san \
  && "$SRC/configure" CC="$CC" CFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS" LIBS="$SRC/obj/lsan_off.o" \
  && make -j"$MAYHEM_JOBS" snapraid)

# 2) Normal-flags build for the oracle (test.sh only runs it): the CLI plus the helpers `make check` needs.
(cd obj/test \
  && env -u CFLAGS -u LDFLAGS "$SRC/configure" CC="$CC" CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" \
  && make -j"$MAYHEM_JOBS" snapraid mktest mkstream checker)
