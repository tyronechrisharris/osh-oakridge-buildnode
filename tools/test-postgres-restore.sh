#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
docker info >/dev/null 2>&1 || {
    printf 'Docker is required for the PostgreSQL restore drill.\n' >&2
    exit 1
}

suffix="$$-$(date -u +%Y%m%d%H%M%S)"
image="oscar-postgis:restore-test-$suffix"
source_container="oscar-restore-source-$suffix"
restored_container="oscar-restore-target-$suffix"
data_volume="oscar_restore_data_$suffix"
backup_volume="oscar_restore_backup_$suffix"
wal_volume="oscar_restore_wal_$suffix"
wal_snapshot_volume="oscar_restore_wal_snapshot_$suffix"
wal_merge_stage_volume="oscar_restore_wal_merge_stage_$suffix"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/oscar-postgres-restore.XXXXXX")
password='oscar-restore-test-password'
epoch_id='12345678-1234-4234-8234-123456789abc'
backup_id='20261017T120000Z-1234abcd'
epoch_sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

cleanup() {
    docker rm -f "$source_container" "$restored_container" >/dev/null 2>&1 || true
    docker volume rm "$data_volume" "$backup_volume" "$wal_volume" "$wal_snapshot_volume" "$wal_merge_stage_volume" >/dev/null 2>&1 || true
    docker image rm "$image" >/dev/null 2>&1 || true
    rm -rf -- "$scratch"
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' "$password" >"$scratch/oscar-db-password.txt"
chmod 0600 "$scratch/oscar-db-password.txt"

docker build --quiet --platform linux/amd64 --build-arg OSCAR_VERSION=3.9.2 --tag "$image" \
    "$repo_root/dist/release/postgis" >/dev/null
docker volume create "$data_volume" >/dev/null
docker volume create "$backup_volume" >/dev/null
docker volume create "$wal_volume" >/dev/null
docker volume create "$wal_snapshot_volume" >/dev/null
docker volume create "$wal_merge_stage_volume" >/dev/null

# Named volumes start root-owned.  This is a test-only bootstrap step; both the
# production archive writer and every restore utility below run capability-free
# as PostgreSQL UID/GID 999 after the exact volumes are prepared.
for volume in "$backup_volume" "$wal_volume" "$wal_snapshot_volume" "$wal_merge_stage_volume"; do
    docker run --rm --network none --user 0:0 --cap-drop ALL --cap-add CHOWN \
        --security-opt no-new-privileges --entrypoint chown --volume "$volume:/target" \
        "$image" 999:999 /target
    docker run --rm --network none --user 999:999 --cap-drop ALL \
        --security-opt no-new-privileges --entrypoint chmod --volume "$volume:/target" \
        "$image" 0700 /target
done

postgres_arguments=(
    postgres
    -c password_encryption=scram-sha-256
    -c archive_mode=on
    -c archive_timeout=1s
    -c 'archive_command=/usr/local/bin/oscar-archive-wal "%p" "%f" /var/lib/postgresql/wal-archive'
)

docker run --detach --name "$source_container" --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev \
    --env POSTGRES_PASSWORD="$password" --env POSTGRES_USER=postgres --env POSTGRES_DB=gis \
    --env OSCAR_DB_PASSWORD_FILE=/run/secrets/oscar_db_password \
    --volume "$scratch/oscar-db-password.txt:/run/secrets/oscar_db_password:ro" \
    --volume "$data_volume:/var/lib/postgresql/data" \
    --volume "$wal_volume:/var/lib/postgresql/wal-archive" \
    "$image" "${postgres_arguments[@]}" >/dev/null

wait_ready() {
    local container=$1 attempt first_start second_start
    for attempt in {1..90}; do
        if docker exec "$container" test -f /var/lib/postgresql/data/.oscar-data-checksum-init >/dev/null 2>&1 &&
           docker exec --env PGPASSWORD="$password" "$container" \
            pg_isready --username postgres --dbname gis >/dev/null 2>&1; then
            # During first initialization pg_isready briefly succeeds for the
            # temporary bootstrap postmaster. Require one stable postmaster
            # start timestamp across a delay so the test never races its
            # intentional shutdown before the final server starts.
            first_start=$(docker exec --env PGPASSWORD="$password" "$container" \
                psql --set=ON_ERROR_STOP=1 --quiet --tuples-only --no-align \
                --username postgres --dbname gis --command 'SELECT pg_postmaster_start_time();' 2>/dev/null || true)
            sleep 2
            second_start=$(docker exec --env PGPASSWORD="$password" "$container" \
                psql --set=ON_ERROR_STOP=1 --quiet --tuples-only --no-align \
                --username postgres --dbname gis --command 'SELECT pg_postmaster_start_time();' 2>/dev/null || true)
            if [[ -n $first_start && $first_start == "$second_start" ]]; then
                return 0
            fi
        fi
        sleep 1
    done
    docker logs "$container" >&2 || true
    printf 'PostgreSQL container did not become ready: %s\n' "$container" >&2
    return 1
}

psql_value() {
    local container=$1 sql=$2
    docker exec --env PGPASSWORD="$password" "$container" \
        psql --set=ON_ERROR_STOP=1 --quiet --tuples-only --no-align \
        --username postgres --dbname gis --command "$sql" | tr -d '[:space:]'
}

wait_ready "$source_container"
psql_value "$source_container" "
CREATE TABLE public.restore_probe(id integer PRIMARY KEY);
INSERT INTO public.restore_probe VALUES (1);
CREATE TABLE oscar.oscar_backup_epoch (
 id uuid PRIMARY KEY, state text NOT NULL, postgres_lsn pg_lsn,
 archive_generation_ids uuid[] NOT NULL DEFAULT '{}', manifest_path text,
 sha256 text, created_at timestamptz NOT NULL DEFAULT now(), verified_at timestamptz);
SELECT pg_switch_wal();" >/dev/null
source_timeline=$(psql_value "$source_container" 'SELECT timeline_id FROM pg_control_checkpoint();')
backup_lsn=$(psql_value "$source_container" 'SELECT pg_current_wal_lsn();')

docker run --rm --network "container:$source_container" --read-only --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs /tmp:rw,noexec,nosuid,nodev \
    --user 999:999 --entrypoint sh --volume "$backup_volume:/backup" \
    "$image" -eu -c "PGPASSWORD='$password'; export PGPASSWORD; exec pg_basebackup --pgdata=/backup --username=postgres --dbname='host=127.0.0.1 port=5432 dbname=gis' --format=plain --wal-method=stream --checkpoint=fast"

# Capture the backup-time WAL set before creating divergent future WAL. The
# production restore merge must later accept its identical collisions while
# preserving every newer live-root object byte-for-byte.
snapshot_segment=$(psql_value "$source_container" 'SELECT pg_walfile_name(pg_switch_wal());')
for _ in {1..45}; do
    if docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 999:999 --entrypoint test --volume "$wal_volume:/wal:ro" "$image" \
        -f "/wal/$snapshot_segment"; then
        break
    fi
    sleep 1
done
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user 999:999 --entrypoint tar --volume "$wal_volume:/wal:ro" \
    --volume "$wal_snapshot_volume:/snapshot" "$image" -C /wal -czf /snapshot/wal-archive.tar.gz .

# Produce divergent future WAL on the original timeline and retain it.  Restore
# must not replay row 2 and must not overwrite any of these published names.
future_segment=$(psql_value "$source_container" "INSERT INTO public.restore_probe VALUES (2); SELECT pg_walfile_name(pg_switch_wal());")
for _ in {1..45}; do
    if docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 999:999 --entrypoint test --volume "$wal_volume:/wal:ro" "$image" \
        -f "/wal/$future_segment"; then
        break
    fi
    sleep 1
done
[[ $(psql_value "$source_container" 'SELECT failed_count FROM pg_stat_archiver;') == 0 ]] || {
    printf 'Source PostgreSQL archiver failed before the restore drill.\n' >&2
    exit 1
}
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user 999:999 --entrypoint sh --volume "$wal_volume:/wal:ro" "$image" -eu -c \
    'find /wal -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum' >"$scratch/pre-restore-wal.sha256"
grep -Fq "/wal/$future_segment" "$scratch/pre-restore-wal.sha256" || {
    printf 'Divergent future WAL was not archived before restore.\n' >&2
    exit 1
}

docker rm -f "$source_container" >/dev/null

# Exercise the packaged production merge helper before replacing PGDATA, just
# as both storage CLIs do. This is a full-flow proof that retained post-backup
# WAL survives a merge of the authenticated older snapshot.
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user 999:999 --entrypoint /usr/local/bin/oscar-merge-wal-restore \
    --volume "$wal_volume:/wal" --volume "$wal_merge_stage_volume:/merge" \
    --volume "$wal_snapshot_volume:/snapshot:ro" "$image" \
    /snapshot/wal-archive.tar.gz /wal /merge
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user 999:999 --entrypoint sh --volume "$data_volume:/data" \
    --volume "$backup_volume:/backup:ro" "$image" -eu -c \
    'find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; cp -a /backup/. /data/'
prepared_timeline=$(docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges --user 999:999 --entrypoint /usr/local/bin/oscar-prepare-restore \
    --volume "$data_volume:/data" "$image" /data | tr -d '[:space:]')
[[ $prepared_timeline == "$source_timeline" ]] || {
    printf 'Restore helper emitted timeline %s, expected %s.\n' "$prepared_timeline" "$source_timeline" >&2
    exit 1
}

docker run --detach --name "$restored_container" --read-only --cap-drop ALL \
    --security-opt no-new-privileges --user 999:999 \
    --tmpfs /tmp:rw,noexec,nosuid,nodev --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,uid=999,gid=999,mode=0770 \
    --volume "$data_volume:/var/lib/postgresql/data" \
    --volume "$wal_volume:/var/lib/postgresql/wal-archive" \
    "$image" "${postgres_arguments[@]}" >/dev/null
wait_ready "$restored_container"

restored_timeline=$(psql_value "$restored_container" 'SELECT timeline_id FROM pg_control_checkpoint();')
[[ $restored_timeline =~ ^[1-9][0-9]*$ && $restored_timeline -gt $source_timeline ]] || {
    printf 'Restore did not promote from timeline %s (current %s).\n' "$source_timeline" "$restored_timeline" >&2
    exit 1
}
[[ $(psql_value "$restored_container" "SELECT count(*)||'|'||min(id)||'|'||max(id) FROM public.restore_probe;") == '1|1|1' ]] || {
    printf 'Restore replayed data written after the base-backup recovery target.\n' >&2
    exit 1
}
failed_before=$(psql_value "$restored_container" 'SELECT failed_count FROM pg_stat_archiver;')
receipt=$(psql_value "$restored_container" "
WITH upserted AS (
 INSERT INTO oscar.oscar_backup_epoch(id,state,postgres_lsn,archive_generation_ids,manifest_path,sha256,verified_at)
 VALUES ('$epoch_id','VERIFIED','$backup_lsn','{}','$backup_id/epoch.json','$epoch_sha',now())
 ON CONFLICT (id) DO UPDATE SET state='VERIFIED',
  verified_at=CASE WHEN oscar.oscar_backup_epoch.state='VERIFIED' THEN oscar.oscar_backup_epoch.verified_at ELSE now() END
 WHERE oscar.oscar_backup_epoch.state IN ('CREATED','VERIFIED')
   AND oscar.oscar_backup_epoch.postgres_lsn IS NOT DISTINCT FROM EXCLUDED.postgres_lsn
   AND oscar.oscar_backup_epoch.archive_generation_ids IS NOT DISTINCT FROM EXCLUDED.archive_generation_ids
   AND oscar.oscar_backup_epoch.manifest_path IS NOT DISTINCT FROM EXCLUDED.manifest_path
   AND oscar.oscar_backup_epoch.sha256 IS NOT DISTINCT FROM EXCLUDED.sha256
 RETURNING id::text||'|'||state)
SELECT * FROM upserted;")
[[ $receipt == "$epoch_id|VERIFIED" ]] || { printf 'Restored VERIFIED epoch receipt was not committed.\n' >&2; exit 1; }
segment=$(psql_value "$restored_container" "INSERT INTO public.restore_probe VALUES (3); SELECT pg_walfile_name(pg_switch_wal());")
psql_value "$restored_container" 'CHECKPOINT;' >/dev/null
history=$(printf '%08X.history' "$restored_timeline")

archived=false
for _ in {1..45}; do
    failed_now=$(psql_value "$restored_container" 'SELECT failed_count FROM pg_stat_archiver;')
    [[ $failed_now == "$failed_before" ]] || {
        printf 'Post-restore WAL archival failed (failed_count %s -> %s).\n' "$failed_before" "$failed_now" >&2
        exit 1
    }
    if docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 999:999 --entrypoint sh --volume "$wal_volume:/wal:ro" "$image" -eu -c \
        "test -f /wal/$history && test -f /wal/$segment"; then
        archived=true
        break
    fi
    sleep 1
done
$archived || { printf 'Promoted history/new-timeline WAL did not reach the archive.\n' >&2; exit 1; }

docker run --rm --interactive --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user 999:999 --entrypoint sha256sum --volume "$wal_volume:/wal:ro" "$image" \
    --check --strict - <"$scratch/pre-restore-wal.sha256" >/dev/null
[[ $(psql_value "$restored_container" "SELECT state||'|'||postgres_lsn::text||'|'||manifest_path||'|'||sha256 FROM oscar.oscar_backup_epoch WHERE id='$epoch_id';") == "VERIFIED|$backup_lsn|$backup_id/epoch.json|$epoch_sha" ]] || {
    printf 'Restored epoch receipt identity changed.\n' >&2
    exit 1
}

# Recovery GUCs are startup settings. RESET+reload removes their durable source,
# but a clean restart is required before declaring the restored runtime free of
# pending recovery configuration.
psql_value "$restored_container" 'ALTER SYSTEM RESET restore_command;' >/dev/null
psql_value "$restored_container" 'ALTER SYSTEM RESET recovery_target;' >/dev/null
psql_value "$restored_container" 'ALTER SYSTEM RESET recovery_target_timeline;' >/dev/null
psql_value "$restored_container" 'ALTER SYSTEM RESET recovery_target_action;' >/dev/null
psql_value "$restored_container" 'SELECT pg_reload_conf();' >/dev/null
failed_after_archive=$(psql_value "$restored_container" 'SELECT failed_count FROM pg_stat_archiver;')
docker stop "$restored_container" >/dev/null
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user 999:999 --entrypoint sh --volume "$data_volume:/data:ro" "$image" -eu -c '
        test ! -e /data/recovery.signal
        test ! -e /data/standby.signal
        test ! -e /data/postgresql.auto.conf ||
            ! grep -Eq "^[[:space:]]*(restore_command|recovery_target|recovery_target_timeline|recovery_target_action)[[:space:]]*=" /data/postgresql.auto.conf
    '
docker start "$restored_container" >/dev/null
wait_ready "$restored_container"
cleanup_status=$(psql_value "$restored_container" "SELECT CASE WHEN pg_is_in_recovery() THEN '1' ELSE '0' END||'|'||timeline_id FROM pg_control_checkpoint();")
[[ $cleanup_status == "0|$restored_timeline" ]] || {
    printf 'Cleanup restart did not retain the promoted non-recovery timeline (expected 0|%s, got %s).\n' "$restored_timeline" "$cleanup_status" >&2
    exit 1
}
[[ $(psql_value "$restored_container" "SELECT count(*) FILTER (WHERE (name='restore_command' AND setting='') OR (name='recovery_target' AND setting='') OR (name='recovery_target_timeline' AND setting='latest') OR (name='recovery_target_action' AND setting='pause'))||'|'||CASE WHEN bool_and(NOT pending_restart) THEN '1' ELSE '0' END FROM pg_settings WHERE name IN ('restore_command','recovery_target','recovery_target_timeline','recovery_target_action');") == '4|1' ]] || {
    printf 'Cleanup restart retained a recovery setting or pending_restart flag.\n' >&2
    exit 1
}
[[ $(psql_value "$restored_container" "SELECT failed_count||'|'||CASE WHEN coalesce(last_failed_time >= pg_postmaster_start_time(),false) THEN '1' ELSE '0' END FROM pg_stat_archiver;") == "$failed_after_archive|0" ]] || {
    printf 'Archiver health changed across the recovery-settings cleanup restart.\n' >&2
    exit 1
}

printf 'PostgreSQL restore/WAL-merge/cleanup drill passed (timeline %s -> %s, segment %s).\n' \
    "$source_timeline" "$restored_timeline" "$segment"
