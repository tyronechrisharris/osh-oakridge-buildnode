#!/bin/sh
set -eu

# Merge one already-authenticated and structurally validated OSCAR WAL snapshot
# into the host-local archive without ever deleting or replacing an existing
# name. The caller may run this preflight/append phase while PostgreSQL is
# active: a concurrent valid publication is accepted only when byte-identical,
# and the normal no-replace archive publisher fails hard on any mismatch.
snapshot=${1:?missing WAL snapshot archive}
archive_root=${2:-/var/lib/postgresql/wal-archive}
stage=${3:?missing private merge staging directory}
publisher=${OSCAR_WAL_PUBLISHER:-/usr/local/bin/oscar-archive-wal}
case $publisher in /*) ;; *) echo 'ERROR: WAL publisher path must be absolute' >&2; exit 1 ;; esac
[ -x "$publisher" ] || { echo "ERROR: WAL publisher is unavailable: $publisher" >&2; exit 1; }

[ -f "$snapshot" ] && [ ! -L "$snapshot" ] || {
    echo 'ERROR: WAL restore snapshot is not a regular file' >&2; exit 1;
}
for directory in "$archive_root" "$stage"; do
    [ -d "$directory" ] && [ ! -L "$directory" ] || {
        echo "ERROR: WAL restore directory is missing or unsafe: $directory" >&2; exit 1;
    }
    [ -z "$(find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
        [ "$directory" = "$archive_root" ] || {
            echo 'ERROR: private WAL merge staging directory is not empty' >&2; exit 1;
        }
    }
done

is_wal_name() {
    case $1 in
        [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F].history) return 0 ;;
        [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]) return 0 ;;
        [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F].[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F].backup) return 0 ;;
        *) return 1 ;;
    esac
}

umask 077
listing=$stage/.listing
members=$stage/.members
: >"$members"
tar -tzf "$snapshot" >"$listing"
while IFS= read -r member; do
    case $member in
        .|./) continue ;;
        */) echo "ERROR: unexpected WAL snapshot directory member: $member" >&2; exit 1 ;;
        ./*) name=${member#./} ;;
        *) echo "ERROR: noncanonical WAL snapshot member: $member" >&2; exit 1 ;;
    esac
    is_wal_name "$name" || { echo "ERROR: unsafe WAL snapshot member: $member" >&2; exit 1; }
    grep -Fqx "$name" "$members" && { echo "ERROR: duplicate WAL snapshot member: $member" >&2; exit 1; }
    [ "$(tar -tvzf "$snapshot" "$member" | cut -c1)" = - ] || {
        echo "ERROR: WAL snapshot member is not a regular file: $member" >&2; exit 1;
    }
    printf '%s\n' "$name" >>"$members"
    tar -xOzf "$snapshot" "$member" >"$stage/$name"
    chmod 0600 "$stage/$name"
    sync -d "$stage/$name"
done <"$listing"
rm -f -- "$listing"

# Fail before publishing even one name if any existing collision is unsafe or
# has different bytes. Also reject unrelated unsafe live-root entries here;
# the administrator-side root audit performs the same check before invocation.
find "$archive_root" -mindepth 1 -maxdepth 1 -print | while IFS= read -r existing; do
    name=${existing##*/}
    [ "$name" = .oscar-storage-root ] && continue
    is_wal_name "$name" || { echo "ERROR: unsafe existing WAL archive entry: $name" >&2; exit 1; }
    [ -f "$existing" ] && [ ! -L "$existing" ] || {
        echo "ERROR: existing WAL archive entry is not a regular file: $name" >&2; exit 1;
    }
done
while IFS= read -r name; do
    destination=$archive_root/$name
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        [ -f "$destination" ] && [ ! -L "$destination" ] && cmp -s "$stage/$name" "$destination" || {
            echo "ERROR: restored WAL name collides with different or unsafe live content: $name" >&2
            exit 1
        }
    fi
done <"$members"

while IFS= read -r name; do
    "$publisher" "$stage/$name" "$name" "$archive_root"
done <"$members"
sync -f "$archive_root" 2>/dev/null || sync
