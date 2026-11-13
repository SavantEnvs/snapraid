#!/usr/bin/env bash
# Regenerates the content-file seeds for mayhem/snapraid_gen_conf/testsuite/ with the real
# `snapraid sync` (normal-flags build). Usage: gen-seeds.sh <snapraid-binary> <outdir>
set -euo pipefail
SR=$(readlink -f "$1"); OUT=$(readlink -f "$2"); mkdir -p "$OUT"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
run() { "$SR" --test-skip-device --test-skip-self --no-warnings -q -c "$W/snap.conf" "$@" >/dev/null 2>&1 || true; }
fresh() { rm -rf "$W"; mkdir -p "$W"/{d1,d2,d3,d4,p1,p2,p3,c}; }
keep() { cp "$W/c/content" "$OUT/$1"; }
rand() { head -c "$2" /dev/urandom > "$1"; }

# 1. mixed tree: two parity levels, hardlink, symlink, empty file and dir, three data disks
fresh
mkdir "$W"/d1/sub "$W"/d1/empty "$W"/d2/sub
rand "$W/d1/big.bin" 300000; printf 'hello world\n' > "$W/d1/sub/hello.txt"; printf 'second\n' > "$W/d2/sub/second.txt"
: > "$W/d2/zero"; ln "$W/d1/sub/hello.txt" "$W/d1/hl"; ln -s hello.txt "$W/d1/sub/sl"; rand "$W/d3/x.dat" 70000
cat > "$W/snap.conf" <<C
blocksize 64
parity $W/p1/parity
2-parity $W/p2/2-parity
content $W/c/content
data d1 $W/d1
data d2 $W/d2
data d3 $W/d3
exclude *.tmp
C
run sync; keep mixed.content

# 2. same array after a scrub (adds the per-block scrub info) and a rename
mv "$W/d2/sub/second.txt" "$W/d2/sub/renamed.txt"
run sync; run scrub -p 100 -o 0; keep scrubbed.content

# 3. same array after deleting a file (deleted-block runs) and adding another
rm "$W/d1/big.bin"; rand "$W/d1/new.bin" 150000
run sync; keep deleted.content

# 4. one disk, one parity, default block size, a single tiny file
fresh
printf 'a\n' > "$W/d1/a.txt"
cat > "$W/snap.conf" <<C
parity $W/p1/parity
content $W/c/content
data d1 $W/d1
C
run sync; keep tiny.content

# 5. split parity files (comma separated), non-default hash size, many small files with nanosecond mtimes
fresh
for i in $(seq 1 60); do mkdir -p "$W/d$((i % 4 + 1))/dir$((i % 7))"; rand "$W/d$((i % 4 + 1))/dir$((i % 7))/f$i" $((i * 997)); done
cat > "$W/snap.conf" <<C
blocksize 32
hashsize 8
parity $W/p1/pa,$W/p1/pb,$W/p1/pc
2-parity $W/p2/2-parity
3-parity $W/p3/3-parity
content $W/c/content
data d1 $W/d1
data d2 $W/d2
data d3 $W/d3
data d4 $W/d4
C
run touch; run sync; keep split.content

# 6. an array that was never synced to completion (empty parity, all blocks new): scan only
fresh
rand "$W/d1/pending.bin" 100000
cat > "$W/snap.conf" <<C
parity $W/p1/parity
content $W/c/content
data d1 $W/d1
C
run sync; run --test-kill-after-resize sync; keep resized.content
ls -la "$OUT"
