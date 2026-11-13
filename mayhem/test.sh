#!/usr/bin/env bash
#
# mayhem/test.sh — behavioral oracle for SnapRAID (runs the normal-flags build made by mayhem/build.sh).
# exit 0 = pass. Asserts known-input -> known-output values; runs only pre-built binaries.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN="$SRC/obj/test/snapraid"
[ -x "$BIN" ] || { echo "missing $BIN — mayhem/build.sh must build it" >&2; emit_ctrf "snapraid-kat" 0 1 0; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1" >&2; }
# expect <name> <condition-command...>
expect() { local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cd "$W"; mkdir d1 d2 p c
printf 'hello world\n' > d1/a.txt
seq 1 5000 > d2/b.txt
cat > snap.conf <<CONF
blocksize 32
parity $W/p/parity
content $W/c/content
data d1 $W/d1
data d2 $W/d2
CONF
SR() { "$BIN" --test-skip-device --test-skip-self --no-warnings -c "$W/snap.conf" "$@"; }

HELLO_SHA=a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447
SEQ_SHA=23f90f8b2c3a4b5f3b5e156339994afd5c2718b378aca6f0e17111f80a70d4ec

SR sync > sync.out 2>&1; rc=$?
expect "sync exits 0" test "$rc" -eq 0
expect "sync reports Everything OK" grep -qx 'Everything OK' sync.out
expect "sync wrote the content file" test -s c/content
expect "sync wrote the parity file" test -s p/parity

SR list > list.out 2>&1
expect "list shows a.txt with its size (12)" grep -Eq '^ +12 [0-9/]+ [0-9:]+ a\.txt$' list.out
expect "list shows b.txt with its size (23893)" grep -Eq '^ +23893 [0-9/]+ [0-9:]+ b\.txt$' list.out
expect "list counts 2 files" grep -Eq '^ +2 files,' list.out

SR check > check.out 2>&1; rc=$?
expect "check of an intact array exits 0" test "$rc" -eq 0
expect "check of an intact array reports Everything OK" grep -qx 'Everything OK' check.out

SR status > status.out 2>&1; rc=$?
expect "status exits 0" test "$rc" -eq 0
expect "status reports no error" grep -qx 'No error detected.' status.out

rm d2/b.txt
SR check > check-missing.out 2>&1; rc=$?
expect "check detects a missing file (exit 1)" test "$rc" -eq 1
expect "check flags the missing file as recoverable" grep -qx 'recoverable b.txt' check-missing.out
SR fix > fix-missing.out 2>&1; rc=$?
expect "fix exits 0" test "$rc" -eq 0
expect "fix restored b.txt byte for byte" test "$(sha256sum < d2/b.txt | cut -d' ' -f1)" = "$SEQ_SHA"

printf 'XXXXXXXXXXXX' | dd of=d1/a.txt conv=notrunc 2>/dev/null
SR check > check-corrupt.out 2>&1; rc=$?
expect "check detects silent corruption (exit 1)" test "$rc" -eq 1
expect "check reports one data error" grep -Eq '^ +1 data errors$' check-corrupt.out
SR fix > fix-corrupt.out 2>&1; rc=$?
expect "fix of corrupted data exits 0" test "$rc" -eq 0
expect "fix reports a.txt recovered" grep -qx 'recovered a.txt' fix-corrupt.out
expect "fix restored a.txt byte for byte" test "$(sha256sum < d1/a.txt | cut -d' ' -f1)" = "$HELLO_SHA"

"$BIN" --test-skip-device --gen-conf c/content > genconf.out 2>&1; rc=$?
expect "gen-conf exits 0" test "$rc" -eq 0
expect "gen-conf recovers the block size" grep -qx 'blocksize 32' genconf.out
expect "gen-conf recovers disk d1 and its file" grep -qxF -e '# and containing: a.txt' genconf.out
expect "gen-conf recovers disk d2 and its file" grep -qxF -e '# and containing: b.txt' genconf.out
expect "gen-conf lists both data disks" test "$(grep -Ec '^data d[12] ' genconf.out)" -eq 2

# Upstream's own regression suite (RAID math self-test, then end-to-end sync/check/fix scenarios on 6 disks).
cd "$SRC/obj/test"
make check SHORTCHECK=1 > "$W/make-check.out" 2>&1; rc=$?
expect "upstream make check SHORTCHECK=1 exits 0" test "$rc" -eq 0
expect "upstream make check ends with SUCCESS" grep -qxF '===== Regression test completed with SUCCESS!' "$W/make-check.out"
expect "upstream make check ran its scenarios (checker output)" test "$(grep -cx 'Everything OK' "$W/make-check.out")" -ge 10

cd "$SRC"
emit_ctrf "snapraid-kat+make-check" "$PASS" "$FAIL" 0
