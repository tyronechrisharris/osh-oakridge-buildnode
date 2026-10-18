#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
helper=$repo_root/dist/release/postgis/merge-wal-restore.sh
publisher=$repo_root/dist/release/postgis/archive-wal.sh
test_root=$(mktemp -d "${TMPDIR:-/tmp}/oscar-wal-restore.XXXXXX")
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT HUP INT TERM

# macOS sync lacks GNU -d/-f; the helpers' ordering is covered statically and
# the Linux Docker drill exercises the real durability syscalls.
mkdir "$test_root/bin"
cat >"$test_root/bin/sync" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "$test_root/bin/sync"
export PATH="$test_root/bin:$PATH"
export OSCAR_WAL_PUBLISHER=$publisher
sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
    else shasum --algorithm 256 "$1" | awk '{print $1}'; fi
}

duplicate=000000010000000000000001
missing=000000010000000000000002
future=000000010000000000000003
new_before_conflict=000000010000000000000004
mkdir "$test_root/live" "$test_root/input" "$test_root/stage"
printf 'identical backup WAL\n' >"$test_root/input/$duplicate"
printf 'missing backup WAL\n' >"$test_root/input/$missing"
cp "$test_root/input/$duplicate" "$test_root/live/$duplicate"
printf 'future live WAL\n' >"$test_root/live/$future"
future_hash=$(sha256_file "$test_root/live/$future")
tar -C "$test_root/input" -czf "$test_root/good.tar.gz" .
sh "$helper" "$test_root/good.tar.gz" "$test_root/live" "$test_root/stage"
cmp "$test_root/input/$duplicate" "$test_root/live/$duplicate"
cmp "$test_root/input/$missing" "$test_root/live/$missing"
[[ $(sha256_file "$test_root/live/$future") == "$future_hash" ]] || {
    printf 'WAL merge changed a post-backup live object.\n' >&2; exit 1;
}

find "$test_root/stage" -mindepth 1 -delete
mkdir "$test_root/conflict-input"
printf 'would be new\n' >"$test_root/conflict-input/$new_before_conflict"
printf 'different collision\n' >"$test_root/conflict-input/$duplicate"
tar -C "$test_root/conflict-input" -czf "$test_root/conflict.tar.gz" .
if sh "$helper" "$test_root/conflict.tar.gz" "$test_root/live" "$test_root/stage" >/dev/null 2>&1; then
    printf 'WAL merge accepted a different-byte collision.\n' >&2; exit 1;
fi
[[ ! -e $test_root/live/$new_before_conflict ]] || {
    printf 'WAL merge published before completing collision preflight.\n' >&2; exit 1;
}

find "$test_root/stage" -mindepth 1 -delete
printf 'unsafe\n' >"$test_root/live/not-a-wal-name"
if sh "$helper" "$test_root/good.tar.gz" "$test_root/live" "$test_root/stage" >/dev/null 2>&1; then
    printf 'WAL merge accepted an unsafe existing root entry.\n' >&2; exit 1;
fi
[[ $(sha256_file "$test_root/live/$future") == "$future_hash" ]] || {
    printf 'Failed WAL merge changed a preserved live object.\n' >&2; exit 1;
}

printf 'WAL restore merge tests passed.\n'
