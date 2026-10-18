#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

script_path=${BASH_SOURCE[0]}
storage_original_args=("$@")
storage_test_mode=false
if [[ ${BASH_SOURCE[0]} != "$0" && ${OSCAR_STORAGE_TEST_MODE:-} == 1 ]]; then
    storage_test_mode=true
fi
case $script_path in */*) script_parent=${script_path%/*} ;; *) script_parent=. ;; esac
script_dir=$(CDPATH= cd -- "$script_parent" && pwd)
script_path="$script_dir/${script_path##*/}"
storage_command=${1:-help}
if (($#)); then shift; fi

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_supported_storage_host() {
    [[ $(uname -s) != Darwin ]] ||
        fail 'OSCAR 3.9.2 storage administration is not supported on macOS Docker Desktop; use Ubuntu 24.04 or Windows.'
}
heading() { printf '\n== %s ==\n' "$*"; }
compose() {
    (
        cd "$script_dir"
        env -u COMPOSE_FILE -u COMPOSE_PROJECT_NAME -u COMPOSE_ENV_FILES -u COMPOSE_PROFILES \
            -u OSCAR_VERSION -u OSCAR_DEPLOYMENT_ID -u OSCAR_ARCHIVE_DIR -u OSCAR_BACKUP_DIR \
            -u OSCAR_WAL_ARCHIVE_DIR -u OSCAR_SECRETS_DIR -u OSCAR_TLS_DIR -u OSCAR_BACKUP_KEY_FILE \
            -u OSCAR_HTTPS_PORT -u OSCAR_JAVA_OPTS -u OSCAR_POSTGIS_PLATFORM \
            docker compose --project-name oscar --env-file "$script_dir/.env" --file "$script_dir/compose.yaml" "$@"
    )
}
oscar_image() { printf 'oscar:%s' "$(env_value OSCAR_VERSION local)"; }

archive_object_helper() {
    local operation=$1 relative=$2 expected_sha=$3 archive_access=$4 export_root=${5:-}
    local image args=(run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges
        --user 10001:10001 --entrypoint /usr/local/bin/oscar-archive-object
        --volume "$archive_dir:/archive:$archive_access")
    image=$(oscar_image)
    [[ -z $export_root ]] || args+=(--volume "$export_root:/export")
    args+=("$image" "$operation" "$relative" "$expected_sha")
    docker "${args[@]}"
}

publish_export_directory() {
    local source=$1 destination=$2 parent source_name destination_name image owner group
    parent=${source%/*}
    [[ ${destination%/*} == "$parent" ]] || fail 'Archive export staging and destination must share one parent directory.'
    source_name=${source##*/}
    destination_name=${destination##*/}
    [[ $source_name != */* && $destination_name != */* && -n $source_name && -n $destination_name ]] ||
        fail 'Archive export publication names are invalid.'
    image=$(oscar_image)
    owner=$(file_owner_id "$parent") || fail "Cannot inspect archive export parent owner: $parent"
    group=$(file_group_id "$parent") || fail "Cannot inspect archive export parent group: $parent"
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user "$owner:$group" --entrypoint /usr/local/bin/oscar-atomic-publish \
        --volume "$parent:/publish" "$image" /publish "$source_name" "$destination_name"
}

env_value() {
    local name=$1 fallback=$2 source_file="$script_dir/.env"
    [[ -f $source_file ]] || source_file="$script_dir/.env.example"
    local value
    value=$(awk -F= -v name="$name" '$1 == name { print substr($0, index($0, "=") + 1); exit }' "$source_file")
    printf '%s' "${value:-$fallback}"
}

assert_managed_environment_bindings() {
    local environment_file="$script_dir/.env" name count value
    [[ -f $environment_file && ! -L $environment_file ]] || fail 'Deployment .env must be a regular, non-symlink file.'
    for name in OSCAR_VERSION OSCAR_DEPLOYMENT_ID OSCAR_ARCHIVE_DIR OSCAR_BACKUP_DIR \
        OSCAR_WAL_ARCHIVE_DIR OSCAR_SECRETS_DIR OSCAR_TLS_DIR OSCAR_BACKUP_KEY_FILE; do
        count=$(awk -F= -v name="$name" '$1 == name { count++ } END { print count+0 }' "$environment_file")
        ((count == 1)) || fail "Deployment .env must contain exactly one literal $name binding."
        value=$(awk -F= -v name="$name" '$1 == name { print substr($0, index($0, "=") + 1); exit }' "$environment_file")
        [[ -n $value && $value != *'$'* && $value != *'#'* && $value != *\"* && $value != *\'* &&
           $value != *[[:space:]]* ]] ||
            fail "Deployment .env contains a Compose-interpreted or nonliteral $name value."
        case $name in
            OSCAR_ARCHIVE_DIR|OSCAR_BACKUP_DIR|OSCAR_WAL_ARCHIVE_DIR)
                [[ $value == /* ]] || fail "$name must be an absolute stable storage-root path."
                ;;
        esac
    done
}

required_release_version=$(awk -F= '$1 == "OSCAR_VERSION" { print substr($0, index($0, "=") + 1); exit }' "$script_dir/.env.example")
[[ $required_release_version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] ||
    fail 'The packaged OSCAR release version is missing or invalid.'
readonly required_release_version
readonly max_backup_archive_generation_ids=1000000
readonly max_backup_archive_generation_inventory_bytes=37000000

valid_deployment_id() {
    [[ $1 =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

volume_deployment_label() {
    local label
    label=$(docker volume inspect --format '{{ index .Labels "com.botts.oscar.deployment-id" }}' "$1" 2>/dev/null || true)
    [[ $label == '<no value>' ]] && label=''
    printf '%s' "$label"
}

adoption_receipt_value() {
    local name=$1 receipt="$script_dir/.oscar-volume-adoption"
    [[ -f $receipt && ! -L $receipt ]] || return 0
    awk -F= -v name="$name" '$1 == name { print substr($0, index($0, "=") + 1); exit }' "$receipt"
}

valid_volume_adoption_receipt() {
    local deployment_id=$1 receipt="$script_dir/.oscar-volume-adoption" state_created postgres_created
    [[ -f $receipt && ! -L $receipt ]] || return 1
    [[ $(wc -l <"$receipt" | tr -d '[:space:]') == 6 &&
       $(grep -Fxc 'format=oscar-volume-adoption' "$receipt") == 1 &&
       $(grep -Fxc 'version=1' "$receipt") == 1 &&
       $(grep -Ec '^deployment_id=' "$receipt") == 1 &&
       $(grep -Ec '^oscar_state_created_at=' "$receipt") == 1 &&
       $(grep -Ec '^postgres_data_created_at=' "$receipt") == 1 &&
       $(grep -Ec '^adopted_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$receipt") == 1 &&
       $(adoption_receipt_value deployment_id) == "$deployment_id" ]] || return 1
    state_created=$(docker volume inspect --format '{{.CreatedAt}}' oscar_oscar_state 2>/dev/null || true)
    postgres_created=$(docker volume inspect --format '{{.CreatedAt}}' oscar_postgres_data 2>/dev/null || true)
    [[ -n $state_created && -n $postgres_created &&
       $(adoption_receipt_value oscar_state_created_at) == "$state_created" &&
       $(adoption_receipt_value postgres_data_created_at) == "$postgres_created" ]]
}

assert_deployment_volume_ownership() {
    local deployment_id state_label postgres_label
    deployment_id=$(env_value OSCAR_DEPLOYMENT_ID '')
    valid_deployment_id "$deployment_id" || fail 'OSCAR_DEPLOYMENT_ID is missing or invalid; run the release upgrade ownership preflight before storage administration.'
    docker volume inspect oscar_oscar_state >/dev/null 2>&1 || fail 'Required Docker volume is missing: oscar_oscar_state.'
    docker volume inspect oscar_postgres_data >/dev/null 2>&1 || fail 'Required Docker volume is missing: oscar_postgres_data.'
    state_label=$(volume_deployment_label oscar_oscar_state)
    postgres_label=$(volume_deployment_label oscar_postgres_data)
    if [[ $state_label == "$deployment_id" && $postgres_label == "$deployment_id" ]]; then return 0; fi
    if [[ $state_label == "$postgres_label" && ( -z $state_label || $state_label == uninitialized ) ]] &&
       valid_volume_adoption_receipt "$deployment_id"; then return 0; fi
    fail 'OSCAR named volumes do not match this deployment identity. No storage operation was performed.'
}

absolute_path() {
    local value=$1
    case $value in
        /*) printf '%s' "$value" ;;
        *) printf '%s/%s' "$script_dir" "${value#./}" ;;
    esac
}

archive_dir=$(env_value OSCAR_ARCHIVE_DIR ../oscar-storage/archive)
backup_dir=$(env_value OSCAR_BACKUP_DIR ../oscar-storage/backups)
wal_archive_dir=$(env_value OSCAR_WAL_ARCHIVE_DIR ../oscar-storage/wal-archive)
backup_key_file=$(env_value OSCAR_BACKUP_KEY_FILE ./secrets/backup-key.txt)
archive_dir=$(absolute_path "$archive_dir")
backup_dir=$(absolute_path "$backup_dir")
wal_archive_dir=$(absolute_path "$wal_archive_dir")
backup_key_file=$(absolute_path "$backup_key_file")

path_contains() {
    local parent=${1%/} child=${2%/}
    [[ $child == "$parent" || $child == "$parent"/* ]]
}

validate_storage_path_shape() {
    local label=$1 value=${2%/} trimmed
    [[ $value == /* && $value != *$'\n'* && $value != *$'\r'* &&
       "/$value/" != */../* && "/$value/" != */./* ]] ||
        fail "$label must be a normalized absolute path without control or parent-directory components: $value"
    trimmed=${value#/}
    [[ $value != / && $trimmed == */* ]] ||
        fail "$label is too broad; configure a dedicated directory at least two components below the filesystem root: $value"
    path_contains "$value" "$script_dir" &&
        fail "$label must not equal or contain the OSCAR release directory: $value"
    path_contains "$script_dir" "$value" &&
        fail "$label must not be located inside the versioned OSCAR release directory: $value"
    if [[ -n ${HOME:-} ]] && path_contains "$value" "$HOME"; then
        fail "$label must not equal or contain the administrator home directory: $value"
    fi
}

assert_no_symlink_components() {
    local value=$1 remainder=${1#/} current='' component
    IFS='/' read -r -a components <<<"$remainder"
    for component in "${components[@]}"; do
        [[ -n $component ]] || continue
        current="$current/$component"
        [[ ! -L $current ]] || fail "Privileged storage paths must not contain symbolic links: $current"
    done
}

assert_safe_creatable_directory_path() {
    local value=$1 remainder=${1#/} current='' component
    IFS='/' read -r -a components <<<"$remainder"
    for component in "${components[@]}"; do
        [[ -n $component ]] || continue
        current="$current/$component"
        [[ ! -L $current ]] || fail "Privileged storage paths must not contain symbolic links: $current"
        if [[ -e $current ]]; then
            [[ -d $current ]] || fail "Privileged storage path component is not a directory: $current"
        else
            # Only this missing suffix may be created. Revalidate the complete
            # path immediately after mkdir to catch a link substitution.
            return 0
        fi
    done
}

validate_storage_directories() {
    local archive_real backup_real wal_real
    validate_storage_path_shape OSCAR_ARCHIVE_DIR "$archive_dir"
    validate_storage_path_shape OSCAR_BACKUP_DIR "$backup_dir"
    validate_storage_path_shape OSCAR_WAL_ARCHIVE_DIR "$wal_archive_dir"
    [[ -d $archive_dir && -d $backup_dir && -d $wal_archive_dir ]] ||
        fail 'Configured storage directories are missing; run OSCAR init/upgrade preparation first.'
    assert_no_symlink_components "$archive_dir"
    assert_no_symlink_components "$backup_dir"
    assert_no_symlink_components "$wal_archive_dir"
    archive_real=$(realpath "$archive_dir") || fail "Cannot resolve archive directory: $archive_dir"
    backup_real=$(realpath "$backup_dir") || fail "Cannot resolve backup directory: $backup_dir"
    wal_real=$(realpath "$wal_archive_dir") || fail "Cannot resolve WAL archive directory: $wal_archive_dir"
    if path_contains "$archive_real" "$backup_real" || path_contains "$backup_real" "$archive_real" ||
       path_contains "$archive_real" "$wal_real" || path_contains "$wal_real" "$archive_real" ||
       path_contains "$backup_real" "$wal_real" || path_contains "$wal_real" "$backup_real"; then
        fail 'Archive, backup, and WAL archive directories must be distinct and must not contain one another.'
    fi
    archive_dir=$archive_real
    backup_dir=$backup_real
    wal_archive_dir=$wal_real
}

file_owner_id() {
    if stat -c %u "$1" >/dev/null 2>&1; then stat -c %u "$1"; else stat -f %u "$1"; fi
}

file_group_id() {
    if stat -c %g "$1" >/dev/null 2>&1; then stat -c %g "$1"; else stat -f %g "$1"; fi
}

file_mode() {
    local raw
    if stat -c %a "$1" >/dev/null 2>&1; then
        stat -c %a "$1"
    else
        # Darwin's %Lp omits the sticky/set-id bits.  %p includes both the
        # object type and permission bits, so mask it down to the latter.
        raw=$(stat -f %p "$1") || return
        printf '%o\n' "$((8#$raw & 07777))"
    fi
}

fsync_path() {
    sync -f "$1" 2>/dev/null || sync 2>/dev/null || fail "Could not durably flush storage metadata: $1"
}

durably_flush_tree() {
    local root=$1 path
    while IFS= read -r path; do fsync_path "$path"; done < <(find "$root" -type f -print)
    while IFS= read -r path; do fsync_path "$path"; done < <(find "$root" -depth -type d -print)
}

storage_identity_value() {
    local marker=$1 name=$2
    awk -F= -v name="$name" '$1 == name { print substr($0, index($0, "=") + 1); exit }' "$marker"
}

assert_storage_root_identity() {
    local root=$1 kind=$2 deployment_id marker="$1/.oscar-storage-root" owner group mode expected_group expected_mode
    deployment_id=$(env_value OSCAR_DEPLOYMENT_ID '')
    valid_deployment_id "$deployment_id" || fail 'OSCAR_DEPLOYMENT_ID is missing or invalid; storage roots cannot be authenticated.'
    [[ -f $marker && ! -L $marker ]] || fail "Storage root is unclaimed or its identity marker is unsafe: $root"
    owner=$(file_owner_id "$marker") || fail "Cannot inspect storage root identity owner: $marker"
    mode=$(file_mode "$marker") || fail "Cannot inspect storage root identity permissions: $marker"
    [[ $owner == ${EUID:-$(id -u)} && $mode =~ ^[0-7]?[0-7][0-7]$ && $((8#$mode & 022)) -eq 0 ]] ||
        fail "Storage root identity must be administrator-owned and not group/world writable: $marker"
    [[ $(wc -l <"$marker" | tr -d '[:space:]') == 8 &&
       $(grep -Fxc 'format=oscar-storage-root-identity' "$marker") == 1 &&
       $(grep -Fxc 'version=1' "$marker") == 1 &&
       $(grep -Ec '^deployment_id=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' "$marker") == 1 &&
       $(grep -Ec '^root_kind=(archive|backup|wal-archive)$' "$marker") == 1 &&
       $(grep -Ec '^adoption=(new|explicit-existing)$' "$marker") == 1 &&
       $(grep -Ec '^claimed_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$marker") == 1 &&
       $(grep -Ec '^adopted_at=(none|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$' "$marker") == 1 &&
       $(grep -Ec '^adopted_by=(none|[A-Za-z0-9_.@-]{1,128})$' "$marker") == 1 ]] ||
        fail "Storage root identity marker is malformed: $marker"
    [[ $(storage_identity_value "$marker" deployment_id) == "$deployment_id" ]] ||
        fail "Storage root belongs to another OSCAR deployment: $root"
    [[ $(storage_identity_value "$marker" root_kind) == "$kind" ]] ||
        fail "Storage roots were swapped or misconfigured; expected $kind identity at $root"
    owner=$(file_owner_id "$root") || fail "Cannot inspect storage root owner: $root"
    group=$(file_group_id "$root") || fail "Cannot inspect storage root group: $root"
    mode=$(file_mode "$root") || fail "Cannot inspect storage root permissions: $root"
    case $kind in
        archive) expected_group=10001; expected_mode=1770 ;;
        wal-archive) expected_group=999; expected_mode=1770 ;;
        backup) expected_group=0; expected_mode=700 ;;
        *) fail "Unknown storage root kind: $kind" ;;
    esac
    # A backup interrupted while pg_basebackup owns its staging tree can leave
    # only this documented transient root mode behind. The authenticated marker
    # has already bound the path/kind/deployment, so repair that exact state
    # before rejecting every other ownership or mode drift.
    if [[ $kind == backup && $owner == ${EUID:-$(id -u)} && $group == 999 && $mode == 710 ]]; then
        chown 0:0 "$root"
        chmod 0700 "$root"
        fsync_path "$root"
        group=$(file_group_id "$root")
        mode=$(file_mode "$root")
    fi
    [[ $owner == ${EUID:-$(id -u)} && $group == "$expected_group" && $mode == "$expected_mode" ]] ||
        fail "Storage root ownership or mode cannot protect its administrator-owned identity marker: $root (expected owner ${EUID:-$(id -u)}, group $expected_group, mode $expected_mode)"
    case $(storage_identity_value "$marker" adoption) in
        new)
            [[ $(storage_identity_value "$marker" adopted_at) == none &&
               $(storage_identity_value "$marker" adopted_by) == none ]] ||
                fail "New storage root has inconsistent adoption metadata: $marker"
            ;;
        explicit-existing)
            [[ $(storage_identity_value "$marker" adopted_at) != none &&
               $(storage_identity_value "$marker" adopted_by) != none ]] ||
                fail "Adopted storage root is missing audit metadata: $marker"
            ;;
    esac
}

assert_storage_root_identities() {
    assert_storage_root_identity "$archive_dir" archive
    assert_storage_root_identity "$backup_dir" backup
    assert_storage_root_identity "$wal_archive_dir" wal-archive
}

write_storage_root_identity() {
    local root=$1 kind=$2 adoption=$3 deployment_id actor=none now adopted_at=none marker temporary
    deployment_id=$(env_value OSCAR_DEPLOYMENT_ID '')
    valid_deployment_id "$deployment_id" || fail 'OSCAR_DEPLOYMENT_ID is missing or invalid; storage roots cannot be claimed.'
    marker="$root/.oscar-storage-root"
    [[ ! -e $marker && ! -L $marker ]] || fail "Refusing to replace an existing storage root identity: $marker"
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [[ $adoption == explicit-existing ]]; then
        actor=${SUDO_USER:-${USER:-root}}
        [[ $actor =~ ^[A-Za-z0-9_.@-]{1,128}$ ]] || actor=root
        adopted_at=$now
    fi
    temporary=$(mktemp "$root/.oscar-storage-root.tmp.XXXXXX")
    {
        printf 'format=oscar-storage-root-identity\n'
        printf 'version=1\n'
        printf 'deployment_id=%s\n' "$deployment_id"
        printf 'root_kind=%s\n' "$kind"
        printf 'adoption=%s\n' "$adoption"
        printf 'claimed_at=%s\n' "$now"
        printf 'adopted_at=%s\n' "$adopted_at"
        printf 'adopted_by=%s\n' "$actor"
    } >"$temporary"
    chown "${EUID:-$(id -u)}" "$temporary"
    chmod 0600 "$temporary"
    fsync_path "$temporary"
    if ! ln "$temporary" "$marker"; then
        rm -f -- "$temporary"
        fail "Storage root identity appeared concurrently; no identity was replaced: $marker"
    fi
    rm -f -- "$temporary"
    fsync_path "$root"
    assert_storage_root_identity "$root" "$kind"
}

claim_storage_root() {
    local root=$1 kind=$2 allow_adoption=$3 marker="$1/.oscar-storage-root"
    if [[ -e $marker || -L $marker ]]; then
        assert_storage_root_identity "$root" "$kind"
        return
    fi
    if [[ -n $(find "$root" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
        $allow_adoption || fail "Nonempty $kind storage root is unclaimed. Re-run setup with the explicit legacy-storage-root adoption option after verifying this path: $root"
        write_storage_root_identity "$root" "$kind" explicit-existing
        printf 'Adopted existing %s storage root for this deployment: %s\n' "$kind" "$root"
    else
        write_storage_root_identity "$root" "$kind" new
    fi
}

validate_offline_backup_directory() {
    validate_storage_path_shape OSCAR_BACKUP_DIR "$backup_dir"
    [[ -d $backup_dir && ! -L $backup_dir ]] || fail "Configured backup directory is missing or is a symbolic link: $backup_dir"
    assert_no_symlink_components "$backup_dir"
    backup_dir=$(realpath "$backup_dir") || fail "Cannot resolve backup directory: $backup_dir"
}

acquire_storage_admin_lock() {
    case $storage_command in help|-h|--help) return ;; esac
    local deployment_id lock_directory lock_file status owner mode
    deployment_id=$(env_value OSCAR_DEPLOYMENT_ID '')
    valid_deployment_id "$deployment_id" || fail 'OSCAR_DEPLOYMENT_ID is missing or invalid; a deployment-scoped storage lock cannot be acquired.'
    if $storage_test_mode && [[ -n ${OSCAR_STORAGE_LOCK_DIR:-} ]]; then
        lock_directory=$OSCAR_STORAGE_LOCK_DIR
    else
        case $(uname -s) in
            Linux) lock_directory=/run/lock/oscar-storage ;;
            Darwin) lock_directory=/private/var/run/oscar-storage ;;
            *) lock_directory=/var/run/oscar-storage ;;
        esac
    fi
    assert_safe_creatable_directory_path "$lock_directory"
    mkdir -p "$lock_directory" || fail "Cannot create stable storage lock directory: $lock_directory"
    [[ -d $lock_directory && ! -L $lock_directory ]] || fail "Storage lock directory is unsafe: $lock_directory"
    assert_no_symlink_components "$lock_directory"
    chmod 0700 "$lock_directory"
    owner=$(file_owner_id "$lock_directory") || fail "Cannot inspect storage lock directory owner: $lock_directory"
    [[ $owner == ${EUID:-$(id -u)} ]] || fail "Storage lock directory is not administrator-owned: $lock_directory"
    lock_file="$lock_directory/$deployment_id.lock"
    if [[ -e $lock_file || -L $lock_file ]]; then
        [[ -f $lock_file && ! -L $lock_file ]] || fail "Storage administration lock is not a regular file: $lock_file"
    else
        (umask 077; : >"$lock_file") || fail "Cannot create storage administration lock: $lock_file"
    fi
    chmod 0600 "$lock_file"
    owner=$(file_owner_id "$lock_file") || fail "Cannot inspect storage administration lock owner: $lock_file"
    mode=$(file_mode "$lock_file") || fail "Cannot inspect storage administration lock permissions: $lock_file"
    [[ $owner == ${EUID:-$(id -u)} && $((8#$mode & 022)) -eq 0 ]] ||
        fail "Storage administration lock is not administrator-owned and private: $lock_file"
    if command -v flock >/dev/null 2>&1; then
        exec 9>>"$lock_file"
        flock -n 9 || fail 'Another OSCAR storage administration command is already running.'
        return
    fi
    if command -v lockf >/dev/null 2>&1; then
        # BSD/macOS lockf locks the already-open descriptor inherited from this
        # shell. The lock therefore remains held by this process without an
        # environment-variable recursion bypass and is released on every exit.
        exec 9>>"$lock_file"
        set +e
        lockf -s -t 0 9
        status=$?
        set -e
        if ((status == 75)); then
            fail 'Another OSCAR storage administration command is already running.'
        fi
        ((status == 0)) || fail 'The OSCAR storage administration lock could not be acquired.'
        return
    fi
    fail 'Neither flock nor lockf is available; refusing to run storage administration without a crash-safe lock.'
}

require_admin() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Run this command as root (for example, with sudo).'; }
require_configured() {
    [[ -f $script_dir/.env ]] || fail 'Run OSCAR init first.'
    assert_managed_environment_bindings
}
require_backup_key() { [[ -s $backup_key_file ]] || fail "Backup key is missing: $backup_key_file"; }

psql_admin() {
    compose exec -T postgres sh -eu -c '
        PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
        PGOPTIONS=-csearch_path=oscar,public
        export PGPASSWORD PGOPTIONS
        exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
    ' psql-wrapper "$@"
}

valid_backup_id() { [[ $1 =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]; }
valid_uuid() { [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; }
valid_observation_id() { [[ $1 =~ ^[1-9][0-9]{0,18}$ ]]; }
valid_before() { [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; }
valid_store_key() { [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]]; }
valid_id_scope() {
    [[ $1 == 0 || $1 =~ ^-?[1-9][0-9]{0,9}$ ]] || return 1
    (($1 >= -2147483648 && $1 <= 2147483647)) 2>/dev/null
}
valid_relative_path() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._/+=-]*$ ]] &&
        [[ $1 != /* && $1 != *//* && "/$1/" != */../* ]]
}
valid_archive_directory_path() {
    [[ $1 == datasets || $1 == datasets/observations ||
       $1 =~ ^datasets/observations/date=[0-9]{4}-[0-9]{2}-[0-9]{2}$ ||
       $1 =~ ^datasets/observations/date=[0-9]{4}-[0-9]{2}-[0-9]{2}/profile=[A-Za-z0-9_-]+$ ]]
}
valid_archive_object_path() {
    [[ $1 =~ ^datasets/observations/date=[0-9]{4}-[0-9]{2}-[0-9]{2}/profile=[A-Za-z0-9_-]+/generation-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.(parquet|schemas\.json\.gz|manifest\.json)$ ]]
}
valid_archive_partial_path() {
    [[ $1 =~ ^datasets/observations/date=[0-9]{4}-[0-9]{2}-[0-9]{2}/profile=[A-Za-z0-9_-]+/generation-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.(parquet|schemas\.json\.gz|manifest\.json)\.partial.*$ ]]
}

release_template_version() {
    awk -F= '$1 == "OSCAR_VERSION" { print substr($0, index($0, "=") + 1); exit }' \
        "$script_dir/.env.example"
}

require_local_image() {
    local image=$1
    [[ -n $image ]] || fail 'Compose resolved an empty container image name.'
    docker image inspect "$image" >/dev/null 2>&1 ||
        fail "Required local container image is unavailable: $image"
}

postgres_image() {
    local image
    image=$(compose config --images | awk '/(^|\/)oscar-postgis:/ { print; exit }')
    [[ -n $image ]] || fail 'Could not resolve the PostgreSQL image from compose.yaml.'
    printf '%s' "$image"
}

resolve_release_images() {
    local image app='' postgres='' gateway=''
    while IFS= read -r image; do
        case $image in
            */oscar-postgis:*|oscar-postgis:*) [[ -z $postgres ]] || fail 'Compose resolves more than one OSCAR PostGIS image.'; postgres=$image ;;
            */oscar:*|oscar:*) [[ -z $app ]] || fail 'Compose resolves more than one OSCAR application image.'; app=$image ;;
            *nginx-unprivileged:*) [[ -z $gateway ]] || fail 'Compose resolves more than one OSCAR gateway image.'; gateway=$image ;;
        esac
    done < <(compose config --images | sort -u)
    [[ -n $app && -n $postgres && -n $gateway ]] || fail 'Could not resolve exactly one application, PostGIS, and gateway image from Compose.'
    printf '%s\n%s\n%s\n' "$app" "$postgres" "$gateway"
}

image_inspect_value() {
    docker image inspect "$1" --format "$2" 2>/dev/null || fail "Required local container image is unavailable: $1"
}

write_image_inventory() {
    local root=$1 images app postgres gateway app_id postgres_id gateway_id app_digests postgres_digests gateway_digests app_version postgres_version postgres_profile
    images=$(resolve_release_images)
    app=$(sed -n '1p' <<<"$images"); postgres=$(sed -n '2p' <<<"$images"); gateway=$(sed -n '3p' <<<"$images")
    app_id=$(image_inspect_value "$app" '{{.Id}}'); postgres_id=$(image_inspect_value "$postgres" '{{.Id}}'); gateway_id=$(image_inspect_value "$gateway" '{{.Id}}')
    app_digests=$(image_inspect_value "$app" '{{json .RepoDigests}}'); postgres_digests=$(image_inspect_value "$postgres" '{{json .RepoDigests}}'); gateway_digests=$(image_inspect_value "$gateway" '{{json .RepoDigests}}')
    app_version=$(image_inspect_value "$app" '{{ index .Config.Labels "org.opencontainers.image.version" }}')
    postgres_version=$(image_inspect_value "$postgres" '{{ index .Config.Labels "org.opencontainers.image.version" }}')
    postgres_profile=$(image_inspect_value "$postgres" '{{ index .Config.Labels "com.botts.oscar.storage-profile" }}')
    [[ $app_version == "$required_release_version" && $postgres_version == "$required_release_version" && $postgres_profile == "$required_release_version" ]] ||
        fail 'Release images do not carry the required OSCAR version/storage-profile labels.'
    {
        printf 'format=oscar-image-inventory\nversion=1\n'
        printf 'application_name=%s\napplication_id=%s\napplication_repo_digests=%s\napplication_version_label=%s\n' "$app" "$app_id" "$app_digests" "$app_version"
        printf 'postgres_name=%s\npostgres_id=%s\npostgres_repo_digests=%s\npostgres_version_label=%s\npostgres_storage_profile_label=%s\n' "$postgres" "$postgres_id" "$postgres_digests" "$postgres_version" "$postgres_profile"
        printf 'gateway_name=%s\ngateway_id=%s\ngateway_repo_digests=%s\n' "$gateway" "$gateway_id" "$gateway_digests"
        printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$root/image-inventory.txt"
}

image_inventory_value() {
    local root=$1 name=$2 file="$1/image-inventory.txt"
    awk -F= -v name="$name" '$1 == name { print substr($0, index($0, "=") + 1); exit }' "$file"
}

validate_image_inventory() {
    local root=$1 compare_current=${2:-false} file="$1/image-inventory.txt" key value images app postgres gateway role current_name current_id current_digests current_version current_profile
    local repo_digests_pattern='^(null|\[("[A-Za-z0-9._/@:+-]+"(,"[A-Za-z0-9._/@:+-]+")*)?\])$'
    local keys=(format version application_name application_id application_repo_digests application_version_label postgres_name postgres_id postgres_repo_digests postgres_version_label postgres_storage_profile_label gateway_name gateway_id gateway_repo_digests created_at)
    [[ -f $file && ! -L $file && $(wc -l <"$file" | tr -d '[:space:]') == 15 ]] || fail 'Authenticated image inventory is missing or malformed.'
    for key in "${keys[@]}"; do [[ $(grep -Ec "^${key}=" "$file") == 1 ]] || fail "Image inventory must contain exactly one $key field."; done
    [[ $(image_inventory_value "$root" format) == oscar-image-inventory && $(image_inventory_value "$root" version) == 1 ]] || fail 'Image inventory format/version is unsupported.'
    for key in application_name postgres_name gateway_name; do
        value=$(image_inventory_value "$root" "$key"); [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]*$ ]] || fail "Image inventory has an invalid $key."
    done
    for key in application_id postgres_id gateway_id; do
        value=$(image_inventory_value "$root" "$key"); [[ $value =~ ^sha256:[0-9a-f]{64}$ ]] || fail "Image inventory has an invalid $key."
    done
    for key in application_repo_digests postgres_repo_digests gateway_repo_digests; do
        value=$(image_inventory_value "$root" "$key"); [[ $value =~ $repo_digests_pattern ]] || fail "Image inventory has an invalid $key."
    done
    [[ $(image_inventory_value "$root" application_version_label) == "$required_release_version" &&
       $(image_inventory_value "$root" postgres_version_label) == "$required_release_version" &&
       $(image_inventory_value "$root" postgres_storage_profile_label) == "$required_release_version" ]] || fail 'Image inventory release labels do not match this OSCAR release.'
    [[ $(image_inventory_value "$root" created_at) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail 'Image inventory creation time is invalid.'
    [[ $compare_current == true ]] || return 0
    images=$(resolve_release_images); app=$(sed -n '1p' <<<"$images"); postgres=$(sed -n '2p' <<<"$images"); gateway=$(sed -n '3p' <<<"$images")
    for role in application postgres gateway; do
        case $role in application) current_name=$app ;; postgres) current_name=$postgres ;; gateway) current_name=$gateway ;; esac
        [[ $(image_inventory_value "$root" "${role}_name") == "$current_name" ]] || fail "Restore image name mismatch for $role."
        current_id=$(image_inspect_value "$current_name" '{{.Id}}'); current_digests=$(image_inspect_value "$current_name" '{{json .RepoDigests}}')
        [[ $(image_inventory_value "$root" "${role}_id") == "$current_id" ]] || fail "Restore image ID mismatch for $role."
        # RepoDigests are registry-transport provenance, not image content:
        # docker save/load commonly drops them while preserving the exact
        # content-addressed image ID, name, and labels required below.
        if [[ $(image_inventory_value "$root" "${role}_repo_digests") != "$current_digests" ]]; then
            printf 'WARNING: %s image repository-digest provenance differs after transport; exact image ID and required labels still match.\n' "$role" >&2
        fi
    done
    current_version=$(image_inspect_value "$app" '{{ index .Config.Labels "org.opencontainers.image.version" }}')
    [[ $current_version == $(image_inventory_value "$root" application_version_label) ]] || fail 'Restore application OCI version label mismatch.'
    current_version=$(image_inspect_value "$postgres" '{{ index .Config.Labels "org.opencontainers.image.version" }}')
    current_profile=$(image_inspect_value "$postgres" '{{ index .Config.Labels "com.botts.oscar.storage-profile" }}')
    [[ $current_version == $(image_inventory_value "$root" postgres_version_label) && $current_profile == $(image_inventory_value "$root" postgres_storage_profile_label) ]] || fail 'Restore PostGIS OCI label mismatch.'
}

validate_release_config_archive() {
    local root=$1 image=$2
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 0 --entrypoint sh \
        --volume "$root:/backup:ro" --volume "$script_dir:/validator:ro" "$image" -eu -c '
        sh /validator/validate-storage-archive.sh release-config /backup/release-config.tar.gz
    '
}

validate_backup_archive_members() {
    local root=$1 image=$2
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --tmpfs /tmp:rw,noexec,nosuid,nodev --user 0 --entrypoint sh \
        --volume "$root:/backup:ro" --volume "$backup_key_file:/backup-key.txt:ro" \
        --volume "$script_dir:/validator:ro" "$image" -eu -c '
        secret_archive=$(mktemp /tmp/oscar-secrets.XXXXXX.tar.gz)
        trap '\''rm -f -- "$secret_archive"'\'' EXIT HUP INT TERM
        openssl enc -d -aes-256-cbc -pbkdf2 -pass file:/backup-key.txt \
            -in /backup/deployment-secrets.tar.gz.enc -out "$secret_archive"
        sh /validator/validate-storage-archive.sh \
            oscar-state /backup/oscar-state.tar.gz \
            cold-archive /backup/archive.tar.gz \
            wal-archive /backup/wal-archive.tar.gz \
            release-config /backup/release-config.tar.gz \
            deployment-secrets "$secret_archive"
    '
}

write_verified_marker() (
    local root=$1 marker_temp marker="$1/VERIFIED"
    if [[ -e $marker || -L $marker ]]; then
        [[ -f $marker && ! -L $marker ]] || fail "VERIFIED marker is not a regular, non-symlink file: $marker"
    fi
    marker_temp=$(mktemp "$root/.VERIFIED.XXXXXX")
    trap 'rm -f -- "$marker_temp"' EXIT HUP INT TERM
    date -u +%Y-%m-%dT%H:%M:%SZ >"$marker_temp"
    chown "${EUID:-$(id -u)}" "$marker_temp"
    chmod 0600 "$marker_temp"
    fsync_path "$marker_temp"
    mv -f -- "$marker_temp" "$marker"
    fsync_path "$root"
    trap - EXIT HUP INT TERM
)

calculate_journal_confirmation_hmac() {
    local receipt=$1 image=$2 tag
    [[ -f $receipt && ! -L $receipt ]] || fail 'Journal-confirmation receipt payload is missing or unsafe.'
    tag=$(docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 0 --entrypoint sh --volume "$receipt:/journal-confirmation:ro" \
        --volume "$backup_key_file:/backup-key.txt:ro" "$image" -eu -c '
            key=$(cat /backup-key.txt)
            head -n 4 /journal-confirmation |
                openssl dgst -sha256 -hmac "$key" -binary | openssl base64 -A
        ')
    [[ $tag =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail 'Could not authenticate the journal-confirmation receipt.'
    printf '%s' "$tag"
}

write_journal_confirmation_receipt() (
    local root=$1 backup_id=$2 oscar_state_sha=$3 image=$4 temporary receipt="$1/JOURNAL_CONFIRMED" tag
    valid_backup_id "$backup_id" || fail 'Invalid backup ID for journal confirmation receipt.'
    [[ $oscar_state_sha =~ ^[0-9a-f]{64}$ ]] || fail 'Invalid OSCAR-state hash for journal confirmation receipt.'
    [[ ! -e $receipt && ! -L $receipt ]] || fail "Journal confirmation receipt already exists: $receipt"
    temporary=$(mktemp "$root/.JOURNAL_CONFIRMED.XXXXXX")
    trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
    {
        printf 'format=oscar-journal-backup-confirmation\n'
        printf 'version=2\n'
        printf 'backup_id=%s\n' "$backup_id"
        printf 'oscar_state_sha256=%s\n' "$oscar_state_sha"
    } >"$temporary"
    tag=$(calculate_journal_confirmation_hmac "$temporary" "$image")
    printf 'hmac_sha256=%s\n' "$tag" >>"$temporary"
    chown "${EUID:-$(id -u)}" "$temporary"
    chmod 0600 "$temporary"
    fsync_path "$temporary"
    mv -- "$temporary" "$receipt"
    fsync_path "$root"
    trap - EXIT HUP INT TERM
)

validate_journal_confirmation_receipt() {
    local root=$1 backup_id=$2 oscar_state_sha=$3 image=$4 receipt="$1/JOURNAL_CONFIRMED" expected actual
    [[ -f $receipt && ! -L $receipt ]] || fail 'Authenticated journal confirmation receipt is missing or unsafe.'
    [[ $(wc -l <"$receipt" | tr -d '[:space:]') == 5 &&
       $(grep -Fxc 'format=oscar-journal-backup-confirmation' "$receipt") == 1 &&
       $(grep -Fxc 'version=2' "$receipt") == 1 &&
       $(grep -Fxc "backup_id=$backup_id" "$receipt") == 1 &&
       $(grep -Fxc "oscar_state_sha256=$oscar_state_sha" "$receipt") == 1 &&
       $(grep -Ec '^hmac_sha256=[A-Za-z0-9+/]{43}=$' "$receipt") == 1 ]] ||
        fail 'Authenticated journal confirmation receipt does not match this recovery point.'
    expected=$(sed -n 's/^hmac_sha256=//p' "$receipt")
    actual=$(calculate_journal_confirmation_hmac "$receipt" "$image")
    [[ $actual == "$expected" ]] || fail 'Journal-confirmation receipt authentication failed.'
}

validate_archive_generation_inventory() {
    local root=$1 file="$1/archive-generation-ids.txt" bytes last_byte current count=0
    [[ -f $file && ! -L $file ]] ||
        fail 'Authenticated archive-generation inventory is missing or unsafe.'
    bytes=$(wc -c <"$file" | tr -d '[:space:]')
    [[ $bytes =~ ^[0-9]+$ && $bytes -le $max_backup_archive_generation_inventory_bytes ]] ||
        fail 'Authenticated archive-generation inventory exceeds its size limit.'
    if ((bytes > 0)); then
        last_byte=$(tail -c 1 -- "$file" | od -An -t x1 | tr -d '[:space:]')
        [[ $last_byte == 0a ]] ||
            fail 'Authenticated archive-generation inventory is not canonically newline terminated.'
    fi
    while IFS= read -r current || [[ -n $current ]]; do
        count=$((count + 1))
        ((count <= max_backup_archive_generation_ids)) ||
            fail 'Authenticated archive-generation inventory exceeds its entry limit.'
        [[ $current =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] ||
            fail 'Authenticated archive-generation inventory contains a noncanonical UUID.'
    done <"$file"
    LC_ALL=C sort -c -u "$file" >/dev/null 2>&1 ||
        fail 'Authenticated archive-generation inventory is unsorted or contains duplicates.'
}

archive_generation_ids_sql() {
    local root=$1 file="$1/archive-generation-ids.txt"
    validate_archive_generation_inventory "$root"
    awk '
        BEGIN { printf "\047{" }
        { if (count++) printf ","; printf "%s", $0 }
        END { printf "}\047::uuid[]" }
    ' "$file"
}

write_archive_generation_inventory() {
    local root=$1 file="$1/archive-generation-ids.txt"
    psql_admin --quiet --tuples-only --no-align --command \
        "SELECT id::text FROM oscar_archive_generation WHERE state IN ('ACTIVE','SEALED') ORDER BY id;" >"$file"
    validate_archive_generation_inventory "$root"
}

upsert_verified_backup_epoch() {
    local root=$1 backup_id=$2 epoch_id=$3 postgres_lsn=$4 epoch_sha generation_ids_sql receipt receipt_state
    valid_backup_id "$backup_id" && valid_uuid "$epoch_id" && [[ $postgres_lsn =~ ^[0-9A-F]+/[0-9A-F]+$ ]] ||
        fail 'Authenticated backup epoch fields are invalid for the live verification receipt.'
    epoch_sha=$(sha256_file "$root/epoch.json")
    generation_ids_sql=$(archive_generation_ids_sql "$root")
    assert_deployment_volume_ownership
    receipt=$(cat <<SQL | psql_admin --quiet --tuples-only --no-align | tr -d '[:space:]'
WITH upserted AS (
INSERT INTO oscar_backup_epoch(id,state,postgres_lsn,archive_generation_ids,manifest_path,sha256,verified_at)
VALUES ('$epoch_id','VERIFIED','$postgres_lsn',$generation_ids_sql,'$backup_id/epoch.json','$epoch_sha',now())
ON CONFLICT (id) DO UPDATE SET
 state='VERIFIED',
 verified_at=CASE WHEN oscar_backup_epoch.state='VERIFIED' THEN oscar_backup_epoch.verified_at ELSE now() END
WHERE oscar_backup_epoch.state IN ('CREATED','VERIFIED')
  AND oscar_backup_epoch.postgres_lsn IS NOT DISTINCT FROM EXCLUDED.postgres_lsn
  AND oscar_backup_epoch.archive_generation_ids IS NOT DISTINCT FROM EXCLUDED.archive_generation_ids
  AND oscar_backup_epoch.manifest_path IS NOT DISTINCT FROM EXCLUDED.manifest_path
  AND oscar_backup_epoch.sha256 IS NOT DISTINCT FROM EXCLUDED.sha256
RETURNING id::text||'|'||state
)
SELECT * FROM upserted;
SQL
    )
    receipt_state=${receipt#*|}
    [[ ${receipt%%|*} == "$epoch_id" && $receipt_state == VERIFIED ]] ||
        fail 'Backup epoch UUID already exists with a foreign identity/state; no catalog row was changed.'
}

release_config_version() {
    local root=$1 image=$2
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 0 --entrypoint sh --volume "$root:/backup:ro" "$image" -eu -c \
        'tar -xOzf /backup/release-config.tar.gz .env.example' |
        awk -F= '$1 == "OSCAR_VERSION" { print substr($0, index($0, "=") + 1); exit }'
}

backup_epoch_version() {
    awk -F'"' '/"oscarVersion"/ { print $4; exit }' "$1/epoch.json"
}

write_checksum_hmac() {
    local root=$1 image=$2 tag
    tag=$(docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 0 --entrypoint sh --volume "$root:/backup:ro" --volume "$backup_key_file:/backup-key.txt:ro" \
        "$image" -eu -c '
            key=$(cat /backup-key.txt)
            openssl dgst -sha256 -hmac "$key" -binary /backup/SHA256SUMS | openssl base64 -A
        ')
    [[ $tag =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail 'Could not create the backup authentication tag.'
    printf '%s\n' "$tag" >"$root/SHA256SUMS.hmac"
}

verify_checksum_hmac() {
    local root=$1 image=$2 expected actual
    [[ -f $root/SHA256SUMS && ! -L $root/SHA256SUMS ]] ||
        fail 'SHA256SUMS must be a regular, non-symlink file.'
    if [[ ! -s $root/SHA256SUMS.hmac ]]; then
        fail "Backup has no SHA256SUMS.hmac and cannot be accepted as an authenticated $required_release_version recovery point."
    fi
    [[ -f $root/SHA256SUMS.hmac && ! -L $root/SHA256SUMS.hmac ]] ||
        fail 'SHA256SUMS.hmac must be a regular, non-symlink file.'
    expected=$(tr -d '\r\n' <"$root/SHA256SUMS.hmac")
    [[ $expected =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail 'Backup authentication tag is malformed.'
    actual=$(docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 0 --entrypoint sh \
        --volume "$root:/backup:ro" --volume "$backup_key_file:/backup-key.txt:ro" \
        "$image" -eu -c '
            key=$(cat /backup-key.txt)
            openssl dgst -sha256 -hmac "$key" -binary /backup/SHA256SUMS | openssl base64 -A
        ')
    [[ $actual == "$expected" ]] || fail 'Backup authentication failed; SHA256SUMS or a backup payload may have been altered.'
}

backup_object_path() {
    local root=$1 relative=$2 root_real parent_relative parent_real candidate resolved
    valid_relative_path "$relative" || fail "Unsafe backup checksum path: $relative"
    root_real=$(realpath "$root") || fail "Backup root is unavailable: $root"
    case $relative in */*) parent_relative=${relative%/*} ;; *) parent_relative=. ;; esac
    parent_real=$(realpath "$root/$parent_relative") || fail "Backup object parent is unavailable: $relative"
    case "$parent_real/" in "$root_real/"|"$root_real"/*/) ;; *) fail "Backup object escapes its root: $relative" ;; esac
    candidate="$parent_real/${relative##*/}"
    [[ -f $candidate && ! -L $candidate ]] || fail "Backup object is missing or not a regular file: $relative"
    resolved=$(realpath "$candidate") || fail "Backup object cannot be resolved: $relative"
    case "$resolved" in "$root_real"/*) ;; *) fail "Backup object escapes its root: $relative" ;; esac
    printf '%s' "$resolved"
}

validate_backup_manifest_inventory() (
    local root=$1 scratch manifest_paths actual_paths line relative entry
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/oscar-backup-inventory.XXXXXX")
    trap 'case $scratch in "${TMPDIR:-/tmp}"/oscar-backup-inventory.*) rm -rf -- "$scratch" ;; esac' EXIT HUP INT TERM
    manifest_paths=$scratch/manifest
    actual_paths=$scratch/actual
    : >"$manifest_paths"
    : >"$actual_paths"
    while IFS= read -r line || [[ -n $line ]]; do
        [[ ${line:64:4} == '  ./' ]] || fail "Invalid checksum entry: $line"
        relative=${line:68}
        valid_relative_path "$relative" || fail "Unsafe backup checksum path: $relative"
        printf '%s\n' "$relative" >>"$manifest_paths"
    done <"$root/SHA256SUMS"
    [[ -z $(sort "$manifest_paths" | uniq -d) ]] || fail 'Authenticated checksum manifest contains duplicate paths.'
    while IFS= read -r -d '' entry; do
        if [[ -L $entry || (! -f $entry && ! -d $entry) ]]; then
            fail "Backup contains a symbolic link or non-regular entry: ${entry#"$root"/}"
        fi
        [[ -f $entry ]] || continue
        relative=${entry#"$root"/}
        case $relative in VERIFIED|JOURNAL_CONFIRMED|SHA256SUMS|SHA256SUMS.hmac) continue ;; esac
        valid_relative_path "$relative" || fail "Unsafe backup filesystem path: $relative"
        printf '%s\n' "$relative" >>"$actual_paths"
    done < <(find "$root" -mindepth 1 -print0)
    sort -u "$manifest_paths" -o "$manifest_paths"
    sort -u "$actual_paths" -o "$actual_paths"
    cmp -s "$manifest_paths" "$actual_paths" ||
        fail 'Authenticated checksum manifest does not exactly cover every backup payload file.'
)

archive_object_path() {
    local relative=$1 allow_missing=${2:-false} root_real parent_relative parent_real candidate resolved
    valid_relative_path "$relative" || fail "Catalog contains unsafe object path: $relative"
    root_real=$(realpath "$archive_dir") || fail "Archive root is unavailable: $archive_dir"
    case $relative in */*) parent_relative=${relative%/*} ;; *) parent_relative=. ;; esac
    parent_real=$(realpath "$archive_dir/$parent_relative") ||
        fail "Archive object parent is unavailable: $relative"
    case "$parent_real/" in "$root_real/"|"$root_real"/*/) ;; *) fail "Archive object escapes the configured root: $relative" ;; esac
    candidate="$parent_real/${relative##*/}"
    if [[ -e $candidate || -L $candidate ]]; then
        [[ -f $candidate && ! -L $candidate ]] || fail "Archive object is not a regular, non-symlink file: $relative"
        resolved=$(realpath "$candidate") || fail "Archive object cannot be resolved: $relative"
        case "$resolved" in "$root_real"/*) ;; *) fail "Archive object escapes the configured root: $relative" ;; esac
        printf '%s' "$resolved"
    elif [[ $allow_missing == true ]]; then
        printf '%s' "$candidate"
    else
        fail "Archive object is missing: $relative"
    fi
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
    else shasum --algorithm 256 "$1" | awk '{print $1}'; fi
}

file_mtime_epoch() {
    if stat -c %Y "$1" >/dev/null 2>&1; then stat -c %Y "$1"; else stat -f %m "$1"; fi
}

audit_archive_filesystem() (
    local reject_partials=${1:-false}
    local root_real entry relative modified now failures=0 fresh_partials=0
    local catalog_file scan_file find_file
    root_real=$(realpath "$archive_dir") || fail "Archive root is unavailable: $archive_dir"
    [[ -d $root_real && ! -L $archive_dir ]] || fail "Archive root is not a regular directory: $archive_dir"
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/oscar-archive-audit.XXXXXX")
    catalog_file=$scratch/catalog
    scan_file=$scratch/scan
    find_file=$scratch/find
    : >"$catalog_file"
    : >"$scan_file"
    : >"$find_file"
    trap 'case $scratch in "${TMPDIR:-/tmp}"/oscar-archive-audit.*) rm -rf -- "$scratch" ;; esac' EXIT HUP INT TERM

    load_catalog_paths() {
        local paths path
        paths=$(psql_admin --quiet --tuples-only --no-align --command \
            "SELECT relative_path FROM oscar_archive_object WHERE state IN ('ACTIVE','DELETING') ORDER BY relative_path;")
        while IFS= read -r path; do
            [[ -n $path ]] || continue
            valid_relative_path "$path" && valid_archive_object_path "$path" ||
                fail "Catalog contains an object path outside the approved archive layout: $path"
            printf '%s\n' "$path" >>"$catalog_file"
        done <<<"$paths"
    }

    load_catalog_paths
    now=$(date +%s)
    # Do not feed find through process substitution: failures in that producer are
    # otherwise invisible to set -e and could make an incomplete scan look clean.
    find "$root_real" -mindepth 1 -print0 >"$find_file"
    while IFS= read -r -d '' entry; do
        if [[ -L $entry || (! -f $entry && ! -d $entry) ]]; then
            printf 'Unsafe non-regular archive entry: %s\n' "$entry" >&2
            failures=$((failures + 1))
            continue
        fi
        relative=${entry#"$root_real"/}
        # The administrator-owned root identity is host metadata, not an
        # archive object. The command dispatcher authenticates it before any
        # live archive operation; recognize only this exact root-level name
        # here before applying the deliberately narrower object-path grammar.
        if [[ $relative == .oscar-storage-root ]]; then
            [[ -f $entry ]] || {
                printf 'Archive root identity marker is not a regular file: %s\n' "$entry" >&2
                failures=$((failures + 1))
            }
            continue
        fi
        valid_relative_path "$relative" || {
            printf 'Unsafe archive filesystem path: %s\n' "$entry" >&2
            failures=$((failures + 1))
            continue
        }
        if [[ -d $entry ]]; then
            valid_archive_directory_path "$relative" || {
                printf 'Archive directory is outside the approved datasets layout: %s\n' "$relative" >&2
                failures=$((failures + 1))
            }
            continue
        fi
        case ${entry##*/} in
            *.partial*)
                valid_archive_partial_path "$relative" || {
                    printf 'Archive partial is outside the approved generation-object layout: %s\n' "$relative" >&2
                    failures=$((failures + 1))
                    continue
                }
                if [[ $reject_partials == true ]]; then
                    printf 'Archive partial exists while writers are quiesced: %s\n' "$relative" >&2
                    failures=$((failures + 1))
                    continue
                fi
                modified=$(file_mtime_epoch "$entry") || fail "Cannot read archive partial modification time: $entry"
                if ((now - modified >= 7200)); then
                    printf 'Stale archive partial (at least two hours old): %s\n' "$relative" >&2
                    failures=$((failures + 1))
                else
                    printf 'Archive partial is still within the two-hour in-progress window: %s\n' "$relative" >&2
                    fresh_partials=$((fresh_partials + 1))
                fi
                continue
                ;;
        esac
        valid_archive_object_path "$relative" || {
            printf 'Archive file is outside the approved generation-object layout: %s\n' "$relative" >&2
            failures=$((failures + 1))
            continue
        }
        printf '%s\n' "$relative" >>"$scan_file"
    done <"$find_file"

    # A generation may commit between the first catalog read and the scan. Merge a
    # second read so a just-activated final object is not misreported as an orphan.
    load_catalog_paths
    sort -u "$catalog_file" -o "$catalog_file"
    while IFS= read -r relative; do
        grep -Fqx -- "$relative" "$catalog_file" || {
            printf 'Unregistered archive object: %s\n' "$relative" >&2
            failures=$((failures + 1))
        }
    done <"$scan_file"
    ((failures == 0)) || fail "$failures archive filesystem reconciliation failure(s); no files were changed"
    ((fresh_partials == 0)) || printf '%s recent archive partial(s) reported but not treated as stale.\n' "$fresh_partials"
)

prepare_storage_directories() {
    require_admin
    local allow_adoption=false
    while (($#)); do
        case $1 in
            --adopt-existing) allow_adoption=true; shift ;;
            *) fail "Unknown prepare-directories option: $1" ;;
        esac
    done
    validate_storage_path_shape OSCAR_ARCHIVE_DIR "$archive_dir"
    validate_storage_path_shape OSCAR_BACKUP_DIR "$backup_dir"
    validate_storage_path_shape OSCAR_WAL_ARCHIVE_DIR "$wal_archive_dir"
    assert_safe_creatable_directory_path "$archive_dir"
    assert_safe_creatable_directory_path "$backup_dir"
    assert_safe_creatable_directory_path "$wal_archive_dir"
    mkdir -p "$archive_dir" "$backup_dir" "$wal_archive_dir"
    validate_storage_directories
    local root kind marker
    # Reject every unsafe/foreign root before changing ownership or mode on any
    # path. This keeps a mistaken path or swapped volume from being mutated by
    # an adoption attempt.
    while IFS='|' read -r root kind; do
        marker="$root/.oscar-storage-root"
        if [[ -e $marker || -L $marker ]]; then
            assert_storage_root_identity "$root" "$kind"
        elif [[ -n $(find "$root" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
            $allow_adoption || fail "Nonempty $kind storage root is unclaimed. Re-run setup with the explicit legacy-storage-root adoption option after verifying this path: $root"
        fi
    done <<EOF
$archive_dir|archive
$backup_dir|backup
$wal_archive_dir|wal-archive
EOF
    # The release images use stable numeric IDs (OSCAR 10001, PostgreSQL 999).
    # Backup payloads include operational data. Only root may traverse the backup tree.
    chown 0:10001 "$archive_dir"
    chown 0:999 "$wal_archive_dir"
    chown 0:0 "$backup_dir"
    chmod 1770 "$archive_dir" "$wal_archive_dir"
    chmod 0700 "$backup_dir"
    claim_storage_root "$archive_dir" archive "$allow_adoption"
    claim_storage_root "$backup_dir" backup "$allow_adoption"
    claim_storage_root "$wal_archive_dir" wal-archive "$allow_adoption"
    assert_storage_root_identities
}

confirm_daily_journal_backup() (
    backup_id=$1; root=$2; image=$3; oscar_state_sha=$4
    resume_oscar=false; resume_gateway=false
    [[ $oscar_state_sha =~ ^[0-9a-f]{64}$ ]] || fail 'Authenticated oscar-state.tar.gz SHA-256 is missing.'
    snapshot=$(mktemp -d "$backup_dir/.journal-confirm-$backup_id.XXXXXX")
    chown 10001:10001 "$snapshot"
    chmod 0700 "$snapshot"
    cleanup_journal_confirmation() {
        local status=$?
        case $snapshot in "$backup_dir"/.journal-confirm-"$backup_id".*) rm -rf -- "$snapshot" ;; esac
        if $resume_oscar || $resume_gateway; then
            local services=()
            $resume_oscar && services+=(oscar)
            $resume_gateway && services+=(gateway)
            compose up --detach --no-build --pull never "${services[@]}" >/dev/null 2>&1 || true
        fi
        return "$status"
    }
    trap cleanup_journal_confirmation EXIT

    compose ps --status running --services | grep -Fxq gateway && resume_gateway=true || true
    compose ps --status running --services | grep -Fxq oscar && resume_oscar=true || true
    $resume_gateway && compose stop gateway >/dev/null
    $resume_oscar && compose stop oscar >/dev/null

    # Revalidate every member immediately before extraction even though the
    # immutable core has already passed full verification. This keeps the
    # retention bridge independently fail-closed against a swapped payload.
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 0 --entrypoint sh --volume "$root/oscar-state.tar.gz:/oscar-state.tar.gz:ro" \
        --volume "$script_dir/validate-storage-archive.sh:/validate-storage-archive.sh:ro" \
        "$image" -eu -c 'exec sh /validate-storage-archive.sh oscar-state /oscar-state.tar.gz'
    # Extract only that validated snapshot into a private disposable directory
    # for the offline journal receipt bridge.
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 10001:10001 --entrypoint sh \
        --volume "$root/oscar-state.tar.gz:/oscar-state.tar.gz:ro" --volume "$snapshot:/snapshot" "$image" -eu -c '
        umask 077
        tar --no-same-owner -C /snapshot -xzf /oscar-state.tar.gz
        find /snapshot -type d -exec chmod 0700 {} +
        find /snapshot -type f -exec chmod 0600 {} +
    '
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --tmpfs /tmp:rw,noexec,nosuid,nodev --user 10001:10001 --entrypoint java \
        --volume oscar_oscar_state:/var/lib/oscar --volume "$snapshot:/verified-snapshot:ro" "$image" \
        -cp '/opt/oscar/lib/*' com.botts.impl.service.dailyfile.DailyFileBackupConfirmationCli \
        /var/lib/oscar /verified-snapshot "$backup_id" "$oscar_state_sha"

    if $resume_oscar || $resume_gateway; then
        services=()
        $resume_oscar && services+=(oscar)
        $resume_gateway && services+=(gateway)
        compose up --detach --no-build --pull never --wait --wait-timeout 300 "${services[@]}"
        resume_oscar=false
        resume_gateway=false
    fi
)

accept_and_confirm_created_backup() {
    local backup_id=$1 root=$2 image=$3 oscar_state_sha=$4
    # Retention authorization is intentionally last: the immutable core must
    # first pass its HMAC, inventory, archive, pg_verifybackup, and image checks
    # and commit both VERIFIED acceptance records. The post-verification audit
    # receipt is outside SHA256SUMS and carries its own backup-key HMAC.
    verify_backup "$backup_id"
    confirm_daily_journal_backup "$backup_id" "$root" "$image" "$oscar_state_sha"
    write_journal_confirmation_receipt "$root" "$backup_id" "$oscar_state_sha" "$image"
    validate_journal_confirmation_receipt "$root" "$backup_id" "$oscar_state_sha" "$image"
}

create_backup() (
    require_admin; require_configured; require_canonical_credential_bindings "$script_dir/.env"
    require_backup_key; assert_deployment_volume_ownership; prepare_storage_directories
    local backup_id timestamp random work final lsn version template_version epoch_id image pg_image postgres_container generation_ids_sql
    local -a release_config_files
    resume_gateway=false; resume_oscar=false; resume_postgres=false
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    random=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
    backup_id="$timestamp-$random"
    work="$backup_dir/$backup_id.partial"
    final="$backup_dir/$backup_id"
    [[ ! -e $work && ! -e $final ]] || fail "Backup destination already exists: $backup_id"
    version=$(env_value OSCAR_VERSION unknown)
    template_version=$(release_template_version)
    [[ $version == "$required_release_version" && $template_version == "$required_release_version" ]] ||
        fail "Backup requires OSCAR $required_release_version in both .env and .env.example (current=$version, release-config=$template_version)."
    image="oscar:$version"
    pg_image=$(postgres_image)
    require_local_image "$image"
    require_local_image "$pg_image"
    mkdir -p "$work/postgres"
    chown 0:0 "$work"
    chmod 0700 "$work"
    chown 999:999 "$work/postgres"
    chmod 0700 "$work/postgres"
    : >"$work/wal-archive.tar.gz"
    : >"$work/oscar-state.tar.gz"
    : >"$work/archive.tar.gz"
    chown 999:999 "$work/wal-archive.tar.gz"
    chown 10001:10001 "$work/oscar-state.tar.gz" "$work/archive.tar.gz"
    chmod 0600 "$work/wal-archive.tar.gz"
    chmod 0600 "$work/oscar-state.tar.gz" "$work/archive.tar.gz"

    heading "Creating coordinated backup $backup_id"
    compose ps --status running --services | grep -Fxq gateway && resume_gateway=true || true
    compose ps --status running --services | grep -Fxq oscar && resume_oscar=true || true
    compose ps --status running --services | grep -Fxq postgres && resume_postgres=true ||
        fail 'PostgreSQL must be running to create a coordinated backup.'
    cleanup_backup_services() {
        local status=$?
        chown 0:0 "$backup_dir" >/dev/null 2>&1 || true
        chmod 0700 "$backup_dir" >/dev/null 2>&1 || true
        if $resume_postgres || $resume_oscar || $resume_gateway; then
            local services=()
            $resume_postgres && services+=(postgres)
            $resume_oscar && services+=(oscar)
            $resume_gateway && services+=(gateway)
            compose up --detach --no-build --pull never "${services[@]}" >/dev/null 2>&1 || true
        fi
        return "$status"
    }
    trap cleanup_backup_services EXIT
    $resume_gateway && compose stop gateway >/dev/null
    $resume_oscar && compose stop oscar >/dev/null

    # With OSCAR quiesced, prove that the catalog and immutable archive agree
    # before snapshotting either side. The authenticated backup checksums then
    # preserve this verified pair as one recovery point.
    archive_verify reject-partials
    write_archive_generation_inventory "$work"

    lsn=$(psql_admin --tuples-only --no-align --command "SELECT pg_current_wal_lsn();" | tr -d '[:space:]')
    epoch_id=$(psql_admin --tuples-only --no-align --command "SELECT gen_random_uuid();" | tr -d '[:space:]')
    psql_admin --command "SELECT pg_switch_wal();" >/dev/null

    # The long-running database never receives the backup root. A capability-free
    # one-shot client shares only PostgreSQL's network namespace and receives only
    # the fresh output directory plus the exact bootstrap password file.
    postgres_container=$(compose ps --quiet postgres | tr -d '[:space:]')
    [[ $postgres_container =~ ^[0-9a-f]{12,64}$ ]] || fail 'Could not resolve the running PostgreSQL container for pg_basebackup.'
    docker run --rm --network "container:$postgres_container" --read-only --cap-drop ALL \
        --security-opt no-new-privileges --tmpfs /tmp:rw,noexec,nosuid,nodev \
        --user 999:999 --entrypoint sh --volume "$work/postgres:/backup" \
        --volume "$script_dir/secrets/postgres-bootstrap-password.txt:/run/secrets/postgres_bootstrap_password:ro" \
        "$pg_image" -eu -c '
        PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
        export PGPASSWORD
        exec pg_basebackup --pgdata=/backup --username=oscar_bootstrap \
            --dbname="host=127.0.0.1 port=5432 dbname=gis" --format=plain \
            --wal-method=stream --checkpoint=fast
    '
    # pg_basebackup is self-contained. Stop PostgreSQL after it completes so
    # archive_command cannot add or rename a WAL object between the partial
    # scan and tar traversal.
    compose stop postgres >/dev/null
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 10001:10001 --entrypoint sh --volume oscar_oscar_state:/state:ro \
        --volume "$work/oscar-state.tar.gz:/output.tar.gz" "$image" -eu -c \
        'for entry in lib web rules documentation trusted_certificates config logback.xml; do
             if [ -L "/state/$entry" ]; then
                 [ "$(readlink "/state/$entry")" = "/opt/oscar/$entry" ] || {
                     echo "Unexpected OSCAR state symlink target: $entry" >&2; exit 1;
                 }
             elif [ -e "/state/$entry" ]; then
                 echo "Reserved OSCAR image-owned state path is not the expected symlink: $entry" >&2; exit 1
             fi
         done
         tar --exclude="./archive" --exclude="./backups" --exclude="./lib" --exclude="./web" \
             --exclude="./rules" --exclude="./documentation" --exclude="./trusted_certificates" \
             --exclude="./config" --exclude="./logback.xml" -C /state -czf /output.tar.gz .'
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 10001:10001 --entrypoint sh --volume "$archive_dir:/archive:ro" \
        --volume "$work/archive.tar.gz:/output.tar.gz" "$image" -eu -c \
        "tar --exclude='./.oscar-storage-root' -C /archive -czf /output.tar.gz ."
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 999:999 --entrypoint sh --volume "$wal_archive_dir:/wal-archive:ro" \
        --volume "$work/wal-archive.tar.gz:/output.tar.gz" "$pg_image" -eu -c \
        "if find /wal-archive -type f -name '*.partial*' -print -quit | grep -q .; then echo 'WAL archive contains a .partial file while backup writers are quiesced.' >&2; exit 1; fi; tar --exclude='./.oscar-storage-root' -C /wal-archive -czf /output.tar.gz ."

    : >"$work/deployment-secrets.tar.gz.enc"
    chmod 0600 "$work/deployment-secrets.tar.gz.enc"
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 0 --entrypoint sh --volume "$script_dir:/deployment:ro" \
        --volume "$work/deployment-secrets.tar.gz.enc:/deployment-secrets.tar.gz.enc" --volume "$backup_key_file:/backup-key.txt:ro" \
        "$image" -eu -c \
        'tar -C /deployment -czf - .env secrets tls | openssl enc -aes-256-cbc -pbkdf2 -salt -pass file:/backup-key.txt -out /deployment-secrets.tar.gz.enc'
    release_config_files=(
        .dockerignore .env.example DEPLOYMENT.md QUICKSTART.md compose.yaml
        docker/gateway/default.conf docker/oscar/archive-object-helper.sh docker/oscar/atomic-publish.c docker/oscar/Dockerfile docker/oscar/entrypoint.sh
        oscar-setup.ps1 oscar-setup.sh oscar-storage.ps1 oscar-storage.sh oscar.bat oscar.sh
        postgis/Dockerfile postgis/archive-wal.sh postgis/merge-wal-restore.sh postgis/prepare-restore.sh postgis/init-app-role.sh postgis/init-extensions.sql validate-storage-archive.sh
    )
    tar -C "$script_dir" -czf "$work/release-config.tar.gz" "${release_config_files[@]}"

    {
        printf '{\n'
        printf '  "format": "oscar-backup-epoch",\n'
        printf '  "version": 1,\n'
        printf '  "backupEpochId": "%s",\n' "$epoch_id"
        printf '  "backupId": "%s",\n' "$backup_id"
        printf '  "createdAt": "%s",\n' "${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2}T${timestamp:9:2}:${timestamp:11:2}:${timestamp:13:2}Z"
        printf '  "oscarVersion": "%s",\n' "$version"
        printf '  "postgresLsn": "%s",\n' "$lsn"
        printf '  "archiveRoot": "/var/lib/oscar/archive",\n'
        printf '  "secrets": "AES-256-CBC/PBKDF2 with HMAC-SHA-256 manifest authentication; key stored separately",\n'
        printf '  "state": "CREATED"\n'
        printf '}\n'
    } >"$work/epoch.json"

    write_image_inventory "$work"

    oscar_state_sha=$(sha256_file "$work/oscar-state.tar.gz")

    (
        cd "$work"
        find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.hmac -print0 | sort -z |
            while IFS= read -r -d '' file; do
                if command -v sha256sum >/dev/null 2>&1; then sha256sum "$file"; else shasum --algorithm 256 "$file"; fi
            done >SHA256SUMS
    )
    write_checksum_hmac "$work" "$image"
    chown -R 0:0 "$work"
    find "$work" -type d -exec chmod 0700 {} +
    find "$work" -type f -exec chmod 0600 {} +
    durably_flush_tree "$work"
    publish_export_directory "$work" "$final"
    fsync_path "$backup_dir"
    chown 0:0 "$backup_dir"
    chmod 0700 "$backup_dir"
    if $resume_postgres; then
        compose up --detach --no-deps --no-build --pull never --wait --wait-timeout 300 postgres
        resume_postgres=false
    fi
    generation_ids_sql=$(archive_generation_ids_sql "$final")
    assert_deployment_volume_ownership
    if ! cat <<SQL | psql_admin >/dev/null; then
INSERT INTO oscar_backup_epoch(id, state, postgres_lsn, archive_generation_ids, manifest_path, sha256)
VALUES ('$epoch_id', 'CREATED', '$lsn', $generation_ids_sql, '$backup_id/epoch.json', '$(sha256_file "$final/epoch.json")');
SQL
        printf 'WARNING: backup payload is complete, but its live catalog receipt could not be inserted. Verification will continue.\n' >&2
    fi
    printf 'Backup created: %s\n' "$final"
    printf 'Store %s separately from the backup media; it is required to restore encrypted credentials.\n' "$backup_key_file"
    accept_and_confirm_created_backup "$backup_id" "$final" "$image" "$oscar_state_sha"
    if $resume_oscar || $resume_gateway; then
        services=()
        $resume_oscar && services+=(oscar)
        $resume_gateway && services+=(gateway)
        compose up --detach --no-build --pull never --wait --wait-timeout 300 "${services[@]}"
        resume_oscar=false
        resume_gateway=false
    fi
    if [[ $(env_value OSCAR_BACKUP_AUTO_PRUNE true) == true ]]; then
        prune_backups --keep "$(env_value OSCAR_BACKUP_RETENTION_COUNT 14)"
    fi
    trap - EXIT
)

verify_backup() {
    require_admin; require_configured; require_backup_key
    local backup_id=${1:?backup id required} verification_mode=${2:-accept} root image pg_image epoch_id epoch_version epoch_backup_id epoch_format epoch_schema_version epoch_state epoch_lsn line expected_hash relative actual_hash object
    local oscar_state_sha='' oscar_state_entries=0 archive_entries=0 generation_entries=0 secret_entries=0 epoch_entries=0 image_entries=0 release_entries=0 wal_entries=0 epoch_key
    valid_backup_id "$backup_id" || fail 'Invalid backup ID.'
    root="$backup_dir/$backup_id"
    [[ -d $root && -s $root/SHA256SUMS ]] || fail "Backup is incomplete: $root"
    heading "Verifying backup $backup_id"
    image=$(oscar_image)
    pg_image=$(postgres_image)
    require_local_image "$image"
    require_local_image "$pg_image"
    verify_checksum_hmac "$root" "$image"
    validate_backup_manifest_inventory "$root"
    while IFS= read -r line || [[ -n $line ]]; do
        [[ ${line:64:4} == '  ./' ]] || fail "Invalid checksum entry: $line"
        expected_hash=${line:0:64}
        relative=${line:68}
        [[ $expected_hash =~ ^[0-9a-f]{64}$ && -n $relative ]] || fail "Invalid checksum entry: $line"
        object=$(backup_object_path "$root" "$relative")
        actual_hash=$(sha256_file "$object")
        [[ $actual_hash == "$expected_hash" ]] || fail "Backup checksum mismatch: $relative"
        if [[ $relative == oscar-state.tar.gz ]]; then
            oscar_state_sha=$expected_hash
            oscar_state_entries=$((oscar_state_entries + 1))
        fi
        case $relative in
            archive.tar.gz) archive_entries=$((archive_entries + 1)) ;;
            archive-generation-ids.txt) generation_entries=$((generation_entries + 1)) ;;
            deployment-secrets.tar.gz.enc) secret_entries=$((secret_entries + 1)) ;;
            epoch.json) epoch_entries=$((epoch_entries + 1)) ;;
            image-inventory.txt) image_entries=$((image_entries + 1)) ;;
            release-config.tar.gz) release_entries=$((release_entries + 1)) ;;
            wal-archive.tar.gz) wal_entries=$((wal_entries + 1)) ;;
        esac
    done <"$root/SHA256SUMS"
    ((oscar_state_entries == 1 && archive_entries == 1 && generation_entries == 1 && secret_entries == 1 && epoch_entries == 1 &&
      image_entries == 1 && release_entries == 1 && wal_entries == 1)) ||
        fail 'Authenticated checksum manifest must contain each required recovery payload exactly once.'
    validate_archive_generation_inventory "$root"
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 0 --entrypoint pg_verifybackup \
        --volume "$root/postgres:/backup:ro" "$pg_image" /backup
    validate_release_config_archive "$root" "$image"
    validate_backup_archive_members "$root" "$image"
    validate_image_inventory "$root" false
    epoch_id=$(awk -F'"' '/"backupEpochId"/ {print $4; exit}' "$root/epoch.json")
    epoch_version=$(backup_epoch_version "$root")
    epoch_backup_id=$(awk -F'"' '/"backupId"/ {print $4; exit}' "$root/epoch.json")
    epoch_format=$(awk -F'"' '/"format"/ {print $4; exit}' "$root/epoch.json")
    epoch_schema_version=$(awk -F'[: ,]+' '/"version"/ {print $3; exit}' "$root/epoch.json")
    epoch_state=$(awk -F'"' '/"state"/ {print $4; exit}' "$root/epoch.json")
    epoch_lsn=$(awk -F'"' '/"postgresLsn"/ {print $4; exit}' "$root/epoch.json")
    [[ $(wc -l <"$root/epoch.json" | tr -d '[:space:]') == 12 ]] || fail 'Backup epoch must contain exactly the version-1 field set.'
    for epoch_key in format version backupEpochId backupId createdAt oscarVersion postgresLsn archiveRoot secrets state; do
        [[ $(grep -Ec "^[[:space:]]*\"${epoch_key}\"[[:space:]]*:" "$root/epoch.json") == 1 ]] ||
            fail "Backup epoch must contain exactly one $epoch_key field."
    done
    valid_uuid "$epoch_id" || fail 'Backup epoch manifest is invalid.'
    [[ $epoch_format == oscar-backup-epoch && $epoch_schema_version == 1 &&
       $epoch_backup_id == "$backup_id" && $epoch_state == CREATED ]] ||
        fail 'Backup epoch identity, format version, or creation state does not match this recovery-point directory.'
    [[ $epoch_version == "$required_release_version" ]] || fail "Backup epoch must identify OSCAR $required_release_version."
    [[ $epoch_lsn =~ ^[0-9A-F]+/[0-9A-F]+$ ]] || fail 'Backup epoch PostgreSQL LSN is invalid.'
    if [[ -e $root/JOURNAL_CONFIRMED || -L $root/JOURNAL_CONFIRMED ]]; then
        if ! (validate_journal_confirmation_receipt "$root" "$backup_id" "$oscar_state_sha" "$image"); then
            printf 'WARNING: post-verification journal-confirmation audit sidecar is invalid; the authenticated recovery core remains usable.\n' >&2
        fi
    fi
    [[ $verification_mode =~ ^(accept|read-only)$ ]] ||
        fail "Unknown backup verification mode: $verification_mode"
    if [[ $verification_mode != read-only ]]; then
        local postgres_running=false
        if compose ps --status running --services 2>/dev/null | grep -Fxq postgres; then
            postgres_running=true
            # backup-verify remains usable with PostgreSQL fully offline, but a
            # discovered live fixed-name project is never allowed to receive a
            # catalog receipt until its named volumes match this deployment.
            assert_deployment_volume_ownership
        fi
        write_verified_marker "$root"
        if $postgres_running; then
            if ! upsert_verified_backup_epoch "$root" "$backup_id" "$epoch_id" "$epoch_lsn"; then
                rm -f -- "$root/VERIFIED"
                fsync_path "$root"
                fail 'The live backup-verification catalog receipt could not be committed; VERIFIED was removed.'
            fi
        fi
        printf 'Backup verified: %s\n' "$root"
    fi
}

require_restore_compatibility() {
    local root=$1 current_version backup_version config_version image images
    current_version=$(env_value OSCAR_VERSION unknown)
    backup_version=$(backup_epoch_version "$root")
    image="oscar:$current_version"
    require_local_image "$image"
    validate_release_config_archive "$root" "$image"
    config_version=$(release_config_version "$root" "$image")
    [[ $current_version == "$required_release_version" &&
       $backup_version == "$required_release_version" &&
       $config_version == "$required_release_version" ]] ||
        fail "Destructive restore requires exact $required_release_version identity (current=$current_version, backup=$backup_version, release-config=$config_version)."
    [[ -s $root/SHA256SUMS.hmac ]] ||
        fail "OSCAR $required_release_version restore requires SHA256SUMS.hmac; this backup is legacy or incomplete."
    images=$(compose config --images | sort -u)
    while IFS= read -r image; do
        [[ -n $image ]] && require_local_image "$image"
    done <<<"$images"
    validate_image_inventory "$root" true
}

authenticated_backup_label_boundary() {
    local root=$1 line count expected path actual boundary
    count=$(grep -Ec '^[0-9a-f]{64}  \./postgres/backup_label$' "$root/SHA256SUMS")
    [[ $count == 1 ]] || fail "Authenticated manifest must contain postgres/backup_label exactly once: $root"
    line=$(grep -E '^[0-9a-f]{64}  \./postgres/backup_label$' "$root/SHA256SUMS")
    expected=${line:0:64}
    path=$(backup_object_path "$root" postgres/backup_label)
    actual=$(sha256_file "$path")
    [[ $actual == "$expected" ]] || fail "Authenticated PostgreSQL backup_label checksum mismatch: $root"
    boundary=$(sed -n 's/.*(file \([0-9A-F]\{24\}\)).*/\1/p' "$path" | head -n 1)
    [[ $boundary =~ ^[0-9A-F]{24}$ ]] || fail "Could not determine the safe WAL boundary from authenticated backup_label: $root"
    printf '%s' "$boundary"
}

calculate_prune_intent_hmac() {
    local filename=$1 image=$2
    [[ $filename == .oscar-backup-prune-intent ]] || fail 'Unsafe backup prune intent filename.'
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 0 --entrypoint sh \
        --volume "$backup_dir/$filename:/prune-intent:ro" --volume "$backup_key_file:/backup-key.txt:ro" \
        "$image" -eu -c '
            key=$(cat /backup-key.txt)
            openssl dgst -sha256 -hmac "$key" -binary /prune-intent | openssl base64 -A
        '
}

verify_prune_intent() {
    local image=$1 intent="$backup_dir/.oscar-backup-prune-intent" tag_file="$backup_dir/.oscar-backup-prune-intent.hmac"
    local expected actual deployment_id
    [[ -f $intent && ! -L $intent && -f $tag_file && ! -L $tag_file ]] ||
        fail 'Backup prune recovery intent is incomplete or unsafe; no deletion was attempted.'
    [[ $(file_owner_id "$intent") == ${EUID:-$(id -u)} &&
       $(file_owner_id "$tag_file") == ${EUID:-$(id -u)} ]] ||
        fail 'Backup prune recovery intent is not administrator-owned; no deletion was attempted.'
    expected=$(tr -d '\r\n' <"$tag_file")
    [[ $expected =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail 'Backup prune recovery intent authentication tag is malformed.'
    actual=$(calculate_prune_intent_hmac .oscar-backup-prune-intent "$image")
    [[ $actual == "$expected" ]] || fail 'Backup prune recovery intent authentication failed; no deletion was attempted.'
    [[ $(grep -Fxc 'format=oscar-backup-prune-intent' "$intent") == 1 &&
       $(grep -Fxc 'version=1' "$intent") == 1 &&
       $(grep -Ec '^deployment_id=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' "$intent") == 1 &&
       $(grep -Ec '^retention=([1-9][0-9]{0,3}|10000)$' "$intent") == 1 &&
       $(grep -Ec '^oldest_retained=[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$' "$intent") == 1 &&
       $(grep -Ec '^wal_boundary=[0-9A-F]{24}$' "$intent") == 1 &&
       $(grep -Ec '^created_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$intent") == 1 &&
       $(grep -Evc '^(format=oscar-backup-prune-intent|version=1|deployment_id=[0-9a-f-]+|retention=[0-9]+|oldest_retained=[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}|wal_boundary=[0-9A-F]{24}|created_at=[0-9TZ:-]+|delete_backup=[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}|delete_wal=[0-9A-F]{24})$' "$intent") == 0 ]] ||
        fail 'Backup prune recovery intent is malformed; no deletion was attempted.'
    [[ -z $(grep -E '^(delete_backup|delete_wal)=' "$intent" | sort | uniq -d) ]] ||
        fail 'Backup prune recovery intent contains duplicate deletion entries.'
    deployment_id=$(env_value OSCAR_DEPLOYMENT_ID '')
    [[ $(storage_identity_value "$intent" deployment_id) == "$deployment_id" ]] ||
        fail 'Backup prune recovery intent belongs to another deployment; no deletion was attempted.'
}

write_prune_intent() {
    local source=$1 image=$2 intent="$backup_dir/.oscar-backup-prune-intent" tag_file="$backup_dir/.oscar-backup-prune-intent.hmac"
    local temporary tag_temporary tag
    [[ ! -e $intent && ! -L $intent && ! -e $tag_file && ! -L $tag_file ]] ||
        fail 'A backup prune recovery intent already exists and must be recovered before starting another prune.'
    temporary=$(mktemp "$backup_dir/.oscar-backup-prune-intent.tmp.XXXXXX")
    tag_temporary=$(mktemp "$backup_dir/.oscar-backup-prune-intent.hmac.tmp.XXXXXX")
    cp "$source" "$temporary"
    chown "${EUID:-$(id -u)}" "$temporary" "$tag_temporary"
    chmod 0600 "$temporary" "$tag_temporary"
    fsync_path "$temporary"
    mv "$temporary" "$intent"
    fsync_path "$backup_dir"
    tag=$(calculate_prune_intent_hmac .oscar-backup-prune-intent "$image")
    [[ $tag =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail 'Could not authenticate backup prune recovery intent.'
    printf '%s\n' "$tag" >"$tag_temporary"
    fsync_path "$tag_temporary"
    mv "$tag_temporary" "$tag_file"
    fsync_path "$backup_dir"
    verify_prune_intent "$image"
}

finish_prune_intent() {
    local image=$1 intent="$backup_dir/.oscar-backup-prune-intent" tag_file="$backup_dir/.oscar-backup-prune-intent.hmac"
    local oldest boundary id path deleting name actual_boundary
    verify_prune_intent "$image"
    oldest=$(storage_identity_value "$intent" oldest_retained)
    boundary=$(storage_identity_value "$intent" wal_boundary)
    [[ -d $backup_dir/$oldest && ! -L $backup_dir/$oldest ]] ||
        fail 'Oldest retained backup named by prune intent is missing; WAL was not touched.'
    verify_backup "$oldest" read-only
    actual_boundary=$(authenticated_backup_label_boundary "$backup_dir/$oldest")
    [[ $actual_boundary == "$boundary" ]] || fail 'Authenticated WAL boundary changed after prune intent was written.'

    # Validate every not-yet-renamed candidate before resuming. A .deleting tree
    # may be partially removed; the authenticated durable intent is the authority
    # for finishing only that previously validated deletion.
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        path="$backup_dir/$id"
        deleting="$backup_dir/.deleting-$id"
        [[ ! ( -e $path && -e $deleting ) ]] || fail "Both live and deleting backup paths exist for intent candidate: $id"
        if [[ -e $path || -L $path ]]; then
            [[ -d $path && ! -L $path ]] || fail "Prune candidate is not a regular directory: $path"
            verify_backup "$id" read-only
        fi
    done < <(sed -n 's/^delete_backup=//p' "$intent")

    # Revalidate every WAL candidate before deleting even the first backup.
    # Corruption anywhere in the authenticated plan must keep the entire prune
    # operation side-effect free on its initial pass.
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        path="$wal_archive_dir/$name"
        deleting="$wal_archive_dir/.deleting-$name"
        [[ ! (( -e $path || -L $path ) && ( -e $deleting || -L $deleting )) ]] ||
            fail "Both live and deleting WAL paths exist for intent candidate: $name"
        if [[ -e $path || -L $path ]]; then
            [[ -f $path && ! -L $path ]] || fail "WAL prune candidate is not a regular, non-symlink file: $path"
        fi
        if [[ -e $deleting || -L $deleting ]]; then
            [[ -f $deleting && ! -L $deleting ]] || fail "WAL prune recovery candidate is not a regular, non-symlink file: $deleting"
        fi
    done < <(sed -n 's/^delete_wal=//p' "$intent")

    while IFS= read -r id; do
        [[ -n $id ]] || continue
        path="$backup_dir/$id"
        deleting="$backup_dir/.deleting-$id"
        if [[ -e $path ]]; then mv "$path" "$deleting"; fsync_path "$backup_dir"; fi
        if [[ -e $deleting ]]; then rm -rf -- "$deleting"; fsync_path "$backup_dir"; fi
        printf '%s deleted authenticated backup %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" >>"$backup_dir/retention.log"
    done < <(sed -n 's/^delete_backup=//p' "$intent")

    verify_backup "$oldest" read-only
    actual_boundary=$(authenticated_backup_label_boundary "$backup_dir/$oldest")
    [[ $actual_boundary == "$boundary" ]] || fail 'Oldest retained backup failed revalidation; WAL was not touched.'
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        path="$wal_archive_dir/$name"
        deleting="$wal_archive_dir/.deleting-$name"
        if [[ -e $path ]]; then
            mv "$path" "$deleting"
            fsync_path "$wal_archive_dir"
        fi
        if [[ -e $deleting ]]; then
            rm -f -- "$deleting"
            fsync_path "$wal_archive_dir"
            printf '%s deleted archived WAL %s (oldest retained start WAL=%s)\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$boundary" >>"$backup_dir/retention.log"
        fi
    done < <(sed -n 's/^delete_wal=//p' "$intent")
    fsync_path "$wal_archive_dir"
    [[ ! -e $backup_dir/retention.log ]] || fsync_path "$backup_dir/retention.log"
    rm -f -- "$tag_file"
    fsync_path "$backup_dir"
    rm -f -- "$intent"
    fsync_path "$backup_dir"
}

recover_or_discard_prune_intent() {
    local image=$1 intent="$backup_dir/.oscar-backup-prune-intent" tag_file="$backup_dir/.oscar-backup-prune-intent.hmac" orphan
    local has_intent=false has_tag=false
    [[ -e $intent || -L $intent ]] && has_intent=true
    [[ -e $tag_file || -L $tag_file ]] && has_tag=true
    if $has_intent && $has_tag; then
        finish_prune_intent "$image"
        return
    fi
    if $has_intent || $has_tag; then
        $has_intent && orphan=$intent || orphan=$tag_file
        [[ -f $orphan && ! -L $orphan && $(file_owner_id "$orphan") == ${EUID:-$(id -u)} &&
           $(file_mode "$orphan") == 600 ]] ||
            fail 'Incomplete backup prune intent is unsafe; no deletion was attempted.'
        rm -f -- "$orphan"
        fsync_path "$backup_dir"
        printf 'Discarded an incomplete authenticated-prune publication; no backup or WAL payload was deleted.\n'
    fi
}

prune_backups() {
    require_admin; require_configured; require_backup_key
    local keep=$(env_value OSCAR_BACKUP_RETENTION_COUNT 14)
    while (($#)); do
        case $1 in --keep) keep=${2:?missing retention count}; shift 2 ;; *) fail "Unknown backup-prune option: $1" ;; esac
    done
    [[ $keep =~ ^[1-9][0-9]*$ && $keep -le 10000 ]] || fail 'Backup retention count must be between 1 and 10000.'
    local verified=() delete_ids=() wal_names=() path backup_id index earliest_id boundary name image intent_source
    local verified_count=0 delete_count=0 wal_count=0
    image=$(oscar_image)
    require_local_image "$image"
    recover_or_discard_prune_intent "$image"
    while IFS= read -r path; do
        backup_id=${path##*/}
        valid_backup_id "$backup_id" || continue
        if [[ -f $path/VERIFIED && ! -L $path/VERIFIED ]]; then
            verified+=("$path")
            verified_count=$((verified_count + 1))
        fi
    done < <(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -print | sort -r)

    # Read-only preflight: every recovery point participating in the retention
    # decision must authenticate and pass the complete offline verifier before
    # an intent is persisted or any path is renamed.
    if ((verified_count)); then
        for path in "${verified[@]}"; do verify_backup "${path##*/}" read-only; done
    else
        printf 'No authenticated, verified backups exist; WAL archive was not pruned.\n'
        return
    fi
    if ((verified_count > keep)); then
        for ((index=keep; index<verified_count; index++)); do
            delete_ids+=("${verified[index]##*/}")
            delete_count=$((delete_count + 1))
        done
    fi
    index=$(( verified_count < keep ? verified_count - 1 : keep - 1 ))
    earliest_id=${verified[index]##*/}
    boundary=$(authenticated_backup_label_boundary "$backup_dir/$earliest_id")
    while IFS= read -r path; do
        name=${path##*/}
        [[ $name =~ ^[0-9A-F]{24}$ ]] || continue
        [[ -f $path && ! -L $path ]] || fail "WAL prune candidate is not a regular, non-symlink file: $path"
        if [[ $name < $boundary ]]; then
            wal_names+=("$name")
            wal_count=$((wal_count + 1))
        fi
    done < <(find "$wal_archive_dir" -mindepth 1 -maxdepth 1 -print)
    if ((delete_count == 0 && wal_count == 0)); then
        printf 'Backup retention complete; %s authenticated recovery point(s) remain and no WAL was eligible.\n' "$verified_count"
        return
    fi
    intent_source=$(mktemp "${TMPDIR:-/tmp}/oscar-prune-intent.XXXXXX")
    {
        printf 'format=oscar-backup-prune-intent\nversion=1\n'
        printf 'deployment_id=%s\n' "$(env_value OSCAR_DEPLOYMENT_ID '')"
        printf 'retention=%s\noldest_retained=%s\nwal_boundary=%s\n' "$keep" "$earliest_id" "$boundary"
        printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if ((delete_count)); then
            for backup_id in "${delete_ids[@]}"; do printf 'delete_backup=%s\n' "$backup_id"; done
        fi
        if ((wal_count)); then
            for name in "${wal_names[@]}"; do printf 'delete_wal=%s\n' "$name"; done
        fi
    } >"$intent_source"
    write_prune_intent "$intent_source" "$image"
    rm -f -- "$intent_source"
    finish_prune_intent "$image"
    printf 'Backup retention complete; kept %s newest authenticated recovery point(s). WAL history required by the oldest retained backup was preserved.\n' "$keep"
}

restore_local_environment_keys() {
    printf '%s\n' \
        OSCAR_DEPLOYMENT_ID \
        OSCAR_POSTGIS_PLATFORM \
        OSCAR_HTTPS_PORT \
        OSCAR_HOSTNAME \
        OSCAR_SECRETS_DIR \
        OSCAR_TLS_DIR \
        OSCAR_ARCHIVE_DIR \
        OSCAR_WAL_ARCHIVE_DIR \
        OSCAR_BACKUP_DIR \
        OSCAR_BACKUP_KEY_FILE
}

require_canonical_credential_bindings() {
    local environment_file=$1 name expected count actual
    [[ -f $environment_file && ! -L $environment_file ]] ||
        fail "Deployment environment is not a regular file: $environment_file"
    while IFS=: read -r name expected; do
        count=$(awk -F= -v name="$name" '$1 == name { count++ } END { print count+0 }' "$environment_file")
        actual=$(awk -F= -v name="$name" '$1 == name { print substr($0, index($0, "=") + 1); exit }' "$environment_file")
        [[ $count == 1 && $actual == "$expected" ]] ||
            fail "$name must use the canonical supported binding $expected; no storage data or credentials were changed."
    done <<'EOF'
OSCAR_SECRETS_DIR:./secrets
OSCAR_TLS_DIR:./tls
OSCAR_BACKUP_KEY_FILE:./secrets/backup-key.txt
EOF
}

merge_restored_environment() {
    local restored=$1 target=$2 bindings temporary name count value
    [[ -f $restored && ! -L $restored ]] ||
        fail 'Restored credentials do not contain a regular .env file.'
    [[ -f $target && ! -L $target ]] ||
        fail 'The target deployment does not contain a regular .env file.'
    require_canonical_credential_bindings "$target"
    bindings=$(mktemp "${restored%/*}/.restore-local-bindings.XXXXXX")
    temporary=$(mktemp "${restored%/*}/.restore-environment.XXXXXX")
    chmod 0600 "$bindings" "$temporary"
    while IFS= read -r name; do
        count=$(awk -F= -v name="$name" '$1 == name { count++ } END { print count+0 }' "$target")
        [[ $count == 1 ]] || {
            rm -f -- "$bindings" "$temporary"
            fail "Target .env must contain exactly one $name binding before restore."
        }
        value=$(awk -F= -v name="$name" '$1 == name { print substr($0, index($0, "=") + 1); exit }' "$target")
        [[ -n $value ]] || {
            rm -f -- "$bindings" "$temporary"
            fail "Target .env has an empty $name binding; restore was not installed."
        }
        case $name in
            OSCAR_ARCHIVE_DIR|OSCAR_WAL_ARCHIVE_DIR|OSCAR_BACKUP_DIR)
                [[ $value == /* ]] || {
                    rm -f -- "$bindings" "$temporary"
                    fail "Target $name must be an absolute path before restore: $value"
                }
                ;;
        esac
        awk -F= -v name="$name" '$1 == name { print; exit }' "$target" >>"$bindings"
    done < <(restore_local_environment_keys)
    value=$(awk -F= '$1 == "OSCAR_DEPLOYMENT_ID" { print substr($0, index($0, "=") + 1); exit }' "$bindings")
    valid_deployment_id "$value" || {
        rm -f -- "$bindings" "$temporary"
        fail 'Target OSCAR_DEPLOYMENT_ID is invalid; restore was not installed.'
    }
    awk -F= '
        NR == FNR {
            name=$1
            local_value[name]=$0
            order[++count]=name
            next
        }
        {
            name=$1
            if (name in local_value) {
                if (!written[name]++) print local_value[name]
                next
            }
            print
        }
        END {
            for (item=1; item<=count; item++)
                if (!written[order[item]]) print local_value[order[item]]
        }
    ' "$bindings" "$restored" >"$temporary"
    mv -f -- "$temporary" "$restored"
    rm -f -- "$bindings"
    require_canonical_credential_bindings "$restored"
}

validate_restored_credentials_exact() {
    local source=$1 entry
    [[ -d $source && ! -L $source ]] ||
        fail "Restored credential staging directory is invalid: $source"
    [[ -f $source/.env && ! -L $source/.env ]] ||
        fail 'Restored credentials do not contain a regular .env file.'
    for entry in secrets tls; do
        [[ -d $source/$entry && ! -L $source/$entry ]] ||
            fail "Restored credentials do not contain a regular $entry directory."
    done
    if [[ -n $(find "$source/secrets" "$source/tls" \! -type d \! -type f -print -quit) ]]; then
        fail 'Restored credential trees contain a link or unsupported file type.'
    fi
}

prepare_restored_credentials_exact() {
    local source=$1 destination=${2:-$script_dir}
    [[ -d $destination && ! -L $destination ]] ||
        fail "Deployment directory is invalid: $destination"
    merge_restored_environment "$source/.env" "$destination/.env"
    validate_restored_credentials_exact "$source"
}

install_prepared_credentials_exact() {
    local source=$1 destination=${2:-$script_dir} stage
    [[ -d $destination && ! -L $destination ]] ||
        fail "Deployment directory is invalid: $destination"
    require_canonical_credential_bindings "$destination/.env"
    validate_restored_credentials_exact "$source"
    require_canonical_credential_bindings "$source/.env"

    # Move the already-validated replacement set beside the live paths before
    # removing anything. The source and destination are both below script_dir,
    # so these renames stay on one filesystem. On a failed install the private
    # staging directory is deliberately retained alongside the pre-restore copy.
    stage=$(mktemp -d "$destination/.credential-install.XXXXXX")
    chmod 0700 "$stage"
    mv -- "$source/.env" "$source/secrets" "$source/tls" "$stage/"
    rm -rf -- "$destination/.env" "$destination/secrets" "$destination/tls"
    mv -- "$stage/.env" "$stage/secrets" "$stage/tls" "$destination/"
    rmdir "$stage"
}

clear_restore_recovery_settings() {
    local setting
    for setting in restore_command recovery_target recovery_target_timeline recovery_target_action; do
        psql_admin --quiet --command "ALTER SYSTEM RESET $setting;" >/dev/null
    done
    psql_admin --quiet --command 'SELECT pg_reload_conf();' >/dev/null
}

assert_restore_settings_removed_from_data_volume() {
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 999:999 --entrypoint sh --volume oscar_postgres_data:/data:ro \
        "$(postgres_image)" -eu -c '
            test ! -e /data/recovery.signal
            test ! -e /data/standby.signal
            test ! -e /data/postgresql.auto.conf ||
                ! grep -Eq "^[[:space:]]*(restore_command|recovery_target|recovery_target_timeline|recovery_target_action)[[:space:]]*=" /data/postgresql.auto.conf
        '
}

confirm_clean_restored_postgres_runtime() {
    local expected_timeline=$1 expected_failed_count=$2 status recovery timeline settings stats failed recent_failure
    status=$(psql_admin --quiet --tuples-only --no-align --command \
        "SELECT CASE WHEN pg_is_in_recovery() THEN '1' ELSE '0' END||'|'||timeline_id FROM pg_control_checkpoint();")
    IFS='|' read -r recovery timeline <<<"$status"
    [[ $recovery == 0 && $timeline == "$expected_timeline" ]] ||
        fail "Restored PostgreSQL did not retain its promoted timeline across recovery cleanup (expected=$expected_timeline, status=$status)."

    settings=$(psql_admin --quiet --tuples-only --no-align --command \
        "SELECT count(*) FILTER (WHERE (name='restore_command' AND setting='') OR (name='recovery_target' AND setting='') OR (name='recovery_target_timeline' AND setting='latest') OR (name='recovery_target_action' AND setting='pause'))||'|'||CASE WHEN bool_and(NOT pending_restart) THEN '1' ELSE '0' END FROM pg_settings WHERE name IN ('restore_command','recovery_target','recovery_target_timeline','recovery_target_action');")
    [[ $settings == '4|1' ]] ||
        fail "Restored PostgreSQL retained recovery settings after its cleanup restart: $settings"

    stats=$(psql_admin --quiet --tuples-only --no-align --command \
        "SELECT failed_count||'|'||CASE WHEN coalesce(last_failed_time >= pg_postmaster_start_time(),false) THEN '1' ELSE '0' END FROM pg_stat_archiver;")
    IFS='|' read -r failed recent_failure <<<"$stats"
    [[ $failed == "$expected_failed_count" && $recent_failure == 0 ]] ||
        fail "PostgreSQL WAL archival health changed during the recovery-settings cleanup restart: $stats"
}

prove_restored_postgres_timeline() {
    local source_timeline=$1 root=$2 backup_id=$3 epoch_id=$4 postgres_lsn=$5
    local status recovery current stats archived_before failed_before failed_since_start
    local segment segment_timeline history stats_now archived_now failed_now failed_now_since_start attempt
    [[ $source_timeline =~ ^[1-9][0-9]{0,9}$ ]] || fail 'Restore helper returned an invalid source PostgreSQL timeline.'

    status=$(psql_admin --quiet --tuples-only --no-align --command \
        "SELECT CASE WHEN pg_is_in_recovery() THEN '1' ELSE '0' END||'|'||timeline_id FROM pg_control_checkpoint();")
    IFS='|' read -r recovery current <<<"$status"
    [[ $recovery == 0 && $current =~ ^[1-9][0-9]{0,9}$ && $current -gt $source_timeline ]] ||
        fail "Restored PostgreSQL did not promote onto a fresh timeline (source=$source_timeline, status=$status)."

    stats=$(psql_admin --quiet --tuples-only --no-align --command \
        "SELECT archived_count||'|'||failed_count||'|'||CASE WHEN coalesce(last_failed_time >= pg_postmaster_start_time(),false) THEN '1' ELSE '0' END FROM pg_stat_archiver;")
    IFS='|' read -r archived_before failed_before failed_since_start <<<"$stats"
    [[ $archived_before =~ ^[0-9]+$ && $failed_before =~ ^[0-9]+$ && $failed_since_start == 0 ]] ||
        fail 'PostgreSQL reported a WAL archival failure during restore promotion.'

    # Reconstruct the authenticated backup-verification catalog row that could
    # not be present in the base backup itself.  This semantic post-promotion
    # write is deliberately made before switching WAL so the archival proof
    # also proves the reconstructed receipt reached the new timeline.
    upsert_verified_backup_epoch "$root" "$backup_id" "$epoch_id" "$postgres_lsn"
    segment=$(psql_admin --quiet --tuples-only --no-align --command \
        'SELECT pg_walfile_name(pg_switch_wal());')
    [[ $segment =~ ^[0-9A-F]{24}$ ]] || fail "PostgreSQL returned an invalid post-restore WAL filename: $segment"
    segment_timeline=$((16#${segment:0:8}))
    [[ $segment_timeline -eq $current ]] ||
        fail "Post-restore WAL segment did not use the promoted timeline: $segment"
    psql_admin --quiet --command 'CHECKPOINT;' >/dev/null
    history=$(printf '%08X.history' "$current")

    for attempt in {1..30}; do
        stats_now=$(psql_admin --quiet --tuples-only --no-align --command \
            "SELECT archived_count||'|'||failed_count||'|'||CASE WHEN coalesce(last_failed_time >= pg_postmaster_start_time(),false) THEN '1' ELSE '0' END FROM pg_stat_archiver;")
        IFS='|' read -r archived_now failed_now failed_now_since_start <<<"$stats_now"
        [[ $failed_now == "$failed_before" && $failed_now_since_start == 0 ]] ||
            fail "PostgreSQL WAL archival failed after restore promotion (segment=$segment)."
        if [[ $archived_now =~ ^[0-9]+$ && $archived_now -gt $archived_before &&
              -f $wal_archive_dir/$segment && ! -L $wal_archive_dir/$segment &&
              -f $wal_archive_dir/$history && ! -L $wal_archive_dir/$history ]]; then
            clear_restore_recovery_settings
            restored_promoted_timeline=$current
            restored_archiver_failed_count=$failed_now
            return 0
        fi
        sleep 1
    done
    fail "PostgreSQL did not durably archive the promoted timeline history and test segment ($history, $segment)."
}

restore_backup() (
    require_admin; require_configured; require_backup_key
    local backup_id='' confirmation='' source_timeline restore_epoch_id restore_postgres_lsn restore_temp restore_stage
    local restored_promoted_timeline='' restored_archiver_failed_count=''
    while (($#)); do
        case $1 in
            --backup) backup_id=${2:?missing backup id}; shift 2 ;;
            --confirm) confirmation=${2:?missing confirmation}; shift 2 ;;
            *) fail "Unknown restore option: $1" ;;
        esac
    done
    valid_backup_id "$backup_id" || fail 'A valid --backup ID is required.'
    [[ $confirmation == "$backup_id" ]] || fail "Restore is destructive. Re-run with --confirm $backup_id"
    assert_deployment_volume_ownership
    local root="$backup_dir/$backup_id"
    [[ -d $root ]] || fail "Backup does not exist: $root"
    require_restore_compatibility "$root"
    verify_backup "$backup_id"
    require_restore_compatibility "$root"
    assert_deployment_volume_ownership

    restore_temp=$(mktemp -d "$script_dir/.restore-secrets.XXXXXX")
    restore_stage=$(mktemp -d "$backup_dir/.restore-payload-$backup_id.XXXXXX")
    restored_postgres_running=false
    chmod 0700 "$restore_temp" "$restore_stage"
    mkdir "$restore_stage/postgres" "$restore_stage/wal-merge"
    cp -a "$root/postgres/." "$restore_stage/postgres/"
    cp -a "$root/oscar-state.tar.gz" "$root/archive.tar.gz" "$root/wal-archive.tar.gz" "$restore_stage/"
    chown -R 999:999 "$restore_stage/postgres" "$restore_stage/wal-merge" "$restore_stage/wal-archive.tar.gz"
    chown 10001:10001 "$restore_stage/oscar-state.tar.gz" "$restore_stage/archive.tar.gz"
    find "$restore_stage" -type d -exec chmod 0700 {} +
    find "$restore_stage" -type f -exec chmod 0600 {} +
    cleanup_restore_staging() {
        local status=$?
        if $restored_postgres_running; then compose stop postgres >/dev/null 2>&1 || true; fi
        rm -rf -- "$restore_temp" "$restore_stage"
        return "$status"
    }
    trap cleanup_restore_staging EXIT
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 0:0 --entrypoint sh \
        --volume "$root:/backup:ro" --volume "$restore_temp:/restore" --volume "$backup_key_file:/backup-key.txt:ro" \
        "oscar:$required_release_version" -eu -c \
        'openssl enc -d -aes-256-cbc -pbkdf2 -pass file:/backup-key.txt -in /backup/deployment-secrets.tar.gz.enc | tar -C /restore -xzf -'
    prepare_restored_credentials_exact "$restore_temp" "$script_dir"

    # Merge the authenticated WAL snapshot before making a safety copy,
    # stopping services, or replacing any live state. The helper performs a
    # complete collision/type preflight before append-only publication, so a
    # mismatched live name aborts while all replaceable deployment data is
    # untouched.
    assert_storage_root_identities
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 999:999 --entrypoint /usr/local/bin/oscar-merge-wal-restore \
        --volume "$wal_archive_dir:/wal-archive" --volume "$restore_stage/wal-merge:/wal-merge" \
        --volume "$restore_stage/wal-archive.tar.gz:/restore-wal.tar.gz:ro" "$(postgres_image)" \
        /restore-wal.tar.gz /wal-archive /wal-merge
    assert_storage_root_identities

    local safety="$script_dir/pre-restore-$backup_id"
    heading "Restoring backup $backup_id"
    [[ ! -e $safety && ! -L $safety ]] ||
        fail "Pre-restore safety directory already exists; preserve or move it before retrying: $safety"
    mkdir "$safety"
    chmod 0700 "$safety"
    cp -a "$script_dir/.env" "$script_dir/secrets" "$script_dir/tls" "$safety/"
    assert_deployment_volume_ownership
    compose stop gateway oscar postgres
    source_timeline=$(docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 999:999 --entrypoint sh --volume oscar_postgres_data:/data \
        --volume "$restore_stage/postgres:/restore-source:ro" "$(postgres_image)" -eu -c \
        'find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; cp -a /restore-source/. /data/; exec /usr/local/bin/oscar-prepare-restore /data')
    [[ $source_timeline =~ ^[1-9][0-9]{0,9}$ ]] || fail 'PostgreSQL restore preparation did not emit the authenticated source timeline.'
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 10001:10001 --entrypoint sh --volume oscar_oscar_state:/state \
        --volume "$restore_stage/oscar-state.tar.gz:/restore-state.tar.gz:ro" "oscar:$required_release_version" -eu -c \
        "find /state -mindepth 1 -maxdepth 1 ! -name archive -exec rm -rf -- {} +; tar --no-same-owner -C /state -xzf /restore-state.tar.gz"
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 10001:10001 --entrypoint sh --volume "$archive_dir:/archive" \
        --volume "$restore_stage/archive.tar.gz:/restore-archive.tar.gz:ro" "oscar:$required_release_version" -eu -c \
        "find /archive -mindepth 1 -maxdepth 1 ! -name .oscar-storage-root -exec rm -rf -- {} +; tar --no-same-owner -C /archive -xzf /restore-archive.tar.gz"
    assert_storage_root_identities
    install_prepared_credentials_exact "$restore_temp" "$script_dir"
    assert_deployment_volume_ownership
    rm -rf -- "$restore_temp" "$restore_stage"
    compose up --detach --no-deps --no-build --pull never --wait --wait-timeout 300 postgres
    restored_postgres_running=true
    restore_epoch_id=$(awk -F'"' '/"backupEpochId"/ {print $4; exit}' "$root/epoch.json")
    restore_postgres_lsn=$(awk -F'"' '/"postgresLsn"/ {print $4; exit}' "$root/epoch.json")
    valid_uuid "$restore_epoch_id" && [[ $restore_postgres_lsn =~ ^[0-9A-F]+/[0-9A-F]+$ ]] ||
        fail 'Authenticated restore epoch fields are invalid.'
    prove_restored_postgres_timeline "$source_timeline" "$root" "$backup_id" "$restore_epoch_id" "$restore_postgres_lsn"
    compose stop postgres
    restored_postgres_running=false
    assert_restore_settings_removed_from_data_volume
    compose up --detach --no-deps --no-build --pull never --wait --wait-timeout 300 postgres
    restored_postgres_running=true
    confirm_clean_restored_postgres_runtime "$restored_promoted_timeline" "$restored_archiver_failed_count"
    restored_postgres_running=false
    compose up --detach --no-deps --no-build --pull never --wait --wait-timeout 300 oscar gateway
    trap - EXIT
    printf 'Restore complete. Pre-restore deployment credentials were preserved at %s\n' "$safety"
)

archive_status() {
    require_configured
    psql_admin --command "SELECT store_key, id_scope, state, profile, count(*) generations, coalesce(sum(row_count),0) rows, pg_size_pretty(coalesce(sum(o.bytes),0)) bytes FROM oscar_archive_generation g LEFT JOIN oscar_archive_object o ON o.generation_id=g.id AND o.kind='OBSERVATIONS_PARQUET' GROUP BY store_key, id_scope, state, profile ORDER BY store_key, id_scope, state, profile;"
    psql_admin --command "SELECT store_key, id_scope, count(*) active_holds FROM oscar_retention_hold WHERE released_at IS NULL GROUP BY store_key, id_scope ORDER BY store_key, id_scope;"
    audit_archive_filesystem
}

archive_hold() {
    require_admin; require_configured
    local action=${1:-list}; (($#)) && shift
    case $action in
        list)
            psql_admin --command "SELECT id, store_key, id_scope, subject_type, subject_id, reason, created_by, created_at, released_at, released_by FROM oscar_retention_hold ORDER BY (released_at IS NULL) DESC, store_key, id_scope, created_at DESC;"
            ;;
        create)
            local subject_type='' subject_id='' reason='' created_by=${SUDO_USER:-${USER:-administrator}} hold_id safe_reason numeric_subject=0 generation_subject=00000000-0000-4000-8000-000000000000
            local store_key='' id_scope=''
            while (($#)); do
                case $1 in
                    --generation) subject_type=ARCHIVE_GENERATION; subject_id=${2:?missing generation}; shift 2 ;;
                    --observation) subject_type=OBSERVATION; subject_id=${2:?missing observation ID}; shift 2 ;;
                    --store-key) store_key=${2:?missing store key}; shift 2 ;;
                    --id-scope) id_scope=${2:?missing ID scope}; shift 2 ;;
                    --reason) reason=${2:?missing reason}; shift 2 ;;
                    --created-by) created_by=${2:?missing creator}; shift 2 ;;
                    *) fail "Unknown hold create option: $1" ;;
                esac
            done
            if [[ $subject_type == ARCHIVE_GENERATION ]]; then
                valid_uuid "$subject_id" || fail 'Specify exactly one valid --generation UUID or --observation numeric ID.'
            elif [[ $subject_type == OBSERVATION ]]; then
                valid_observation_id "$subject_id" || fail 'Specify exactly one valid --generation UUID or --observation numeric ID.'
            else
                fail 'Specify exactly one valid --generation UUID or --observation numeric ID.'
            fi
            valid_store_key "$store_key" || fail '--store-key must be the archive store/table identifier shown by archive status.'
            valid_id_scope "$id_scope" || fail '--id-scope must be a signed 32-bit integer shown by archive status.'
            [[ $reason =~ ^[A-Za-z0-9][A-Za-z0-9[:space:]._,:/@+()=-]{0,255}$ ]] || fail 'Reason contains unsupported characters or exceeds 256 characters.'
            [[ $created_by =~ ^[A-Za-z0-9_.@-]{1,128}$ ]] || fail 'Invalid creator.'
            safe_reason=${reason//\'/\'\'}
            [[ $subject_type == OBSERVATION ]] && numeric_subject=$subject_id
            [[ $subject_type == ARCHIVE_GENERATION ]] && generation_subject=$subject_id
            hold_id=$(psql_admin --quiet --tuples-only --no-align --command "BEGIN;
                LOCK TABLE oscar_retention_hold IN SHARE ROW EXCLUSIVE MODE;
                WITH eligible AS (
                    SELECT 1 WHERE
                        ('$subject_type'='ARCHIVE_GENERATION' AND EXISTS (
                            SELECT 1 FROM oscar_archive_generation
                            WHERE id='$generation_subject' AND store_key='$store_key' AND id_scope=$id_scope
                              AND state IN ('ACTIVE','SEALED')
                        )) OR
                        ('$subject_type'='OBSERVATION' AND
                            (EXISTS (
                                SELECT 1 FROM "$store_key" observation_row
                                WHERE observation_row.id='$numeric_subject'::numeric
                                  AND (observation_row.archivegenerationid IS NULL OR EXISTS (
                                      SELECT 1 FROM oscar_archive_generation owner
                                      WHERE owner.id=observation_row.archivegenerationid
                                        AND owner.store_key='$store_key' AND owner.id_scope=$id_scope
                                        AND owner.state IN ('ACTIVE','SEALED')
                                  ))
                            ) OR EXISTS (
                                SELECT 1 FROM oscar_archive_id_block b
                                JOIN oscar_archive_generation g ON g.id=b.generation_id
                                WHERE '$numeric_subject'::numeric BETWEEN b.min_id AND b.max_id
                                  AND g.store_key='$store_key' AND g.id_scope=$id_scope
                                  AND g.state IN ('ACTIVE','SEALED')
                            )) AND
                            NOT EXISTS (
                                SELECT 1 FROM oscar_archive_id_block b
                                JOIN oscar_archive_generation g ON g.id=b.generation_id
                                WHERE '$numeric_subject'::numeric BETWEEN b.min_id AND b.max_id
                                  AND g.store_key='$store_key' AND g.id_scope=$id_scope
                                  AND g.state IN ('DELETING','PURGED')
                            ) AND NOT EXISTS (
                                SELECT 1 FROM oscar_tombstone
                                WHERE subject_type='OBSERVATION' AND store_key='$store_key' AND id_scope=$id_scope
                                  AND subject_id='$subject_id'
                            ))
                ), inserted AS (
                    INSERT INTO oscar_retention_hold(id,store_key,id_scope,subject_type,subject_id,reason,created_by)
                    SELECT gen_random_uuid(),'$store_key',$id_scope,'$subject_type','$subject_id','$safe_reason','$created_by' FROM eligible
                    RETURNING id
                )
                SELECT coalesce((SELECT id::text FROM inserted),'REJECTED');
                COMMIT;" | tr -d '[:space:]')
            [[ $hold_id != REJECTED ]] ||
                fail 'The hold target is unknown, already purged/tombstoned, or currently being deleted.'
            valid_uuid "$hold_id" || fail 'PostgreSQL did not return a valid hold ID.'
            printf 'Retention hold created: %s (store=%s, id-scope=%s)\n' "$hold_id" "$store_key" "$id_scope"
            ;;
        release)
            local hold_id='' released_by=${SUDO_USER:-${USER:-administrator}}
            while (($#)); do
                case $1 in
                    --id) hold_id=${2:?missing hold ID}; shift 2 ;;
                    --released-by) released_by=${2:?missing releaser}; shift 2 ;;
                    *) fail "Unknown hold release option: $1" ;;
                esac
            done
            valid_uuid "$hold_id" || fail 'A valid --id UUID is required.'
            [[ $released_by =~ ^[A-Za-z0-9_.@-]{1,128}$ ]] || fail 'Invalid releaser.'
            [[ $(psql_admin --quiet --tuples-only --no-align --command \
                "BEGIN; LOCK TABLE oscar_retention_hold IN SHARE ROW EXCLUSIVE MODE;
                 WITH changed AS (UPDATE oscar_retention_hold SET released_at=now(), released_by='$released_by' WHERE id='$hold_id' AND released_at IS NULL RETURNING 1) SELECT count(*) FROM changed;
                 COMMIT;" | tr -d '[:space:]') == 1 ]] ||
                fail 'Hold is unknown or already released.'
            printf 'Retention hold released: %s\n' "$hold_id"
            ;;
        *) fail "Unknown archive hold action: $action" ;;
    esac
}

archive_verify() {
    require_configured
    local partial_mode=${1:-allow-recent-partials} failures=0 relative expected actual path rows
    [[ $partial_mode == allow-recent-partials || $partial_mode == reject-partials ]] ||
        fail "Unknown archive verification partial mode: $partial_mode"
    rows=$(psql_admin --tuples-only --no-align --field-separator=$'\t' --command \
        "SELECT relative_path, sha256 FROM oscar_archive_object WHERE state='ACTIVE' ORDER BY relative_path;")
    while IFS=$'\t' read -r relative expected; do
        [[ -n $relative ]] || continue
        if ! path=$(archive_object_path "$relative" false); then failures=$((failures+1)); continue; fi
        actual=$(sha256_file "$path")
        if [[ $actual != "$expected" ]]; then printf 'Checksum mismatch: %s\n' "$relative" >&2; failures=$((failures+1)); fi
    done <<<"$rows"
    if [[ $partial_mode == reject-partials ]]; then
        audit_archive_filesystem true
    else
        audit_archive_filesystem false
    fi
    ((failures == 0)) || fail "$failures archive object verification failures"
    printf 'All cataloged active archive objects passed checksum verification.\n'
}

archive_dry_run() {
    require_admin; require_configured
    local before='' requested_by=${SUDO_USER:-${USER:-administrator}} store_key='' id_scope=''
    while (($#)); do
        case $1 in
            --before) before=${2:?missing UTC cutoff}; shift 2 ;;
            --store-key) store_key=${2:?missing store key}; shift 2 ;;
            --id-scope) id_scope=${2:?missing ID scope}; shift 2 ;;
            --requested-by) requested_by=${2:?missing requester}; shift 2 ;;
            *) fail "Unknown archive dry-run option: $1" ;;
        esac
    done
    valid_before "$before" || fail '--before must be UTC YYYY-MM-DDTHH:MM:SSZ.'
    valid_store_key "$store_key" || fail '--store-key must be the archive store/table identifier shown by archive status.'
    valid_id_scope "$id_scope" || fail '--id-scope must be a signed 32-bit integer shown by archive status.'
    [[ $requested_by =~ ^[A-Za-z0-9_.@-]{1,128}$ ]] || fail 'Invalid requester.'
    local plan token token_hash summary rows bytes holds
    plan=$(psql_admin --tuples-only --no-align --command "SELECT gen_random_uuid();" | tr -d '[:space:]')
    valid_uuid "$plan" || fail 'PostgreSQL did not return a valid deletion-plan ID.'
    token=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
    token_hash=$(printf '%s' "$token" | { if command -v sha256sum >/dev/null; then sha256sum; else shasum --algorithm 256; fi; } | awk '{print $1}')
    psql_admin --command "BEGIN;
        WITH candidate AS (
            SELECT g.id, g.row_count, coalesce(sum(o.bytes),0) AS bytes,
                   EXISTS (SELECT 1 FROM oscar_retention_hold h WHERE h.released_at IS NULL AND
                       h.store_key=g.store_key AND h.id_scope=g.id_scope AND
                       ((h.subject_type='ARCHIVE_GENERATION' AND h.subject_id=g.id::text) OR
                        (h.subject_type='OBSERVATION' AND h.subject_id ~ '^[0-9]+$' AND EXISTS (
                            SELECT 1 FROM oscar_archive_id_block held_block
                             WHERE held_block.generation_id=g.id
                               AND h.subject_id::numeric BETWEEN held_block.min_id AND held_block.max_id)))) AS held
            FROM oscar_archive_generation g
            LEFT JOIN oscar_archive_object o ON o.generation_id=g.id AND o.state='ACTIVE'
            WHERE g.store_key='$store_key' AND g.id_scope=$id_scope
              AND g.state='SEALED' AND g.window_end < '$before'::timestamptz
            GROUP BY g.id, g.store_key, g.id_scope, g.row_count
        ), inserted AS (
            INSERT INTO oscar_deletion_plan(id, store_key, id_scope, subject_type, subject_id, state, estimated_rows, estimated_bytes, hold_count, confirmation_hash, requested_by, expires_at)
            SELECT '$plan', '$store_key', $id_scope, 'ARCHIVE_BEFORE', '$before', 'PLANNED',
                   coalesce(sum(row_count) FILTER (WHERE NOT held),0),
                   coalesce(sum(bytes) FILTER (WHERE NOT held),0),
                   count(*) FILTER (WHERE held), '$token_hash', '$requested_by', now()+interval '24 hours'
            FROM candidate RETURNING id
        )
        INSERT INTO oscar_deletion_plan_item(plan_id, generation_id)
            SELECT inserted.id, candidate.id FROM inserted CROSS JOIN candidate WHERE NOT candidate.held;
        COMMIT;" >/dev/null
    summary=$(psql_admin --tuples-only --no-align --field-separator='|' --command \
        "SELECT estimated_rows, estimated_bytes, hold_count FROM oscar_deletion_plan WHERE id='$plan';")
    IFS='|' read -r rows bytes holds <<<"$summary"
    printf 'Deletion plan: %s\nStore: %s\nID scope: %s\nEligible rows: %s\nEligible bytes: %s\nHeld generations: %s\n' "$plan" "$store_key" "$id_scope" "$rows" "$bytes" "$holds"
    printf 'Confirmation token (shown once): %s\n' "$token"
    printf 'Review this plan, then run: archive purge --store-key %s --id-scope %s --plan %s --token <token>\n' "$store_key" "$id_scope" "$plan"
}

archive_purge() (
    require_admin; require_configured
    local plan='' token='' store_key='' id_scope=''
    while (($#)); do
        case $1 in
            --store-key) store_key=${2:?missing store key}; shift 2 ;;
            --id-scope) id_scope=${2:?missing ID scope}; shift 2 ;;
            --plan) plan=${2:?missing plan}; shift 2 ;;
            --token) token=${2:?missing token}; shift 2 ;;
            *) fail "Unknown purge option: $1" ;;
        esac
    done
    valid_store_key "$store_key" || fail '--store-key must be the archive store/table identifier shown by archive status.'
    valid_id_scope "$id_scope" || fail '--id-scope must be a signed 32-bit integer shown by archive status.'
    valid_uuid "$plan" || fail 'Invalid deletion plan ID.'
    [[ $token =~ ^[0-9a-f]{48}$ ]] || fail 'Invalid confirmation token.'
    local token_hash cutoff state expected confirmed_by plan_row preflight_rows delete_rows
    resume_oscar=false
    token_hash=$(printf '%s' "$token" | { if command -v sha256sum >/dev/null; then sha256sum; else shasum --algorithm 256; fi; } | awk '{print $1}')
    plan_row=$(psql_admin --tuples-only --no-align --field-separator='|' --command \
        "SELECT subject_id, state, confirmation_hash FROM oscar_deletion_plan WHERE id='$plan' AND store_key='$store_key' AND id_scope=$id_scope AND (state='CONFIRMED' OR expires_at>now());")
    IFS='|' read -r cutoff state expected <<<"$plan_row"
    [[ $state =~ ^(PLANNED|CONFIRMED)$ && $expected == "$token_hash" ]] || fail 'Plan is missing, expired, completed, or token does not match.'
    confirmed_by=${SUDO_USER:-administrator}
    [[ $confirmed_by =~ ^[A-Za-z0-9_.@-]{1,128}$ ]] || confirmed_by=administrator

    cleanup_archive_purge_services() {
        local status=$?
        if $resume_oscar; then
            compose up --detach --no-deps --no-build --pull never oscar >/dev/null 2>&1 || true
        fi
        return "$status"
    }
    resume_archive_purge_oscar() {
        if $resume_oscar; then
            compose up --detach --no-deps --no-build --pull never --wait --wait-timeout 300 oscar
            resume_oscar=false
        fi
    }
    compose ps --status running --services | grep -Fxq oscar && resume_oscar=true || true
    trap cleanup_archive_purge_services EXIT
    $resume_oscar && compose stop oscar >/dev/null

    # Preflight every file that is still ACTIVE before changing catalog visibility. A later
    # transaction rechecks holds under the same table lock used by hold creation, then makes the
    # whole generation non-queryable before any filesystem removal is attempted.
    local generation relative expected_sha object_state path delete_outcome
    preflight_rows=$(psql_admin --tuples-only --no-align --field-separator=$'\t' --command \
        "SELECT g.id, o.relative_path, o.sha256, o.state FROM oscar_deletion_plan_item i
         JOIN oscar_deletion_plan p ON p.id=i.plan_id
         JOIN oscar_archive_generation g ON g.id=i.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
         JOIN oscar_archive_object o ON o.generation_id=g.id
         WHERE i.plan_id='$plan' AND p.store_key='$store_key' AND p.id_scope=$id_scope
           AND i.state='PLANNED' AND o.state IN ('ACTIVE','DELETING')
         ORDER BY g.id,o.relative_path;")
    while IFS=$'\t' read -r generation relative expected_sha object_state; do
        [[ -n $generation && -n $relative && -n $expected_sha ]] || continue
        if [[ $object_state == ACTIVE ]]; then
            archive_object_helper verify "$relative" "$expected_sha" ro
        else
            path=$(archive_object_path "$relative" true)
            if [[ -e $path || -L $path ]]; then
                archive_object_helper verify "$relative" "$expected_sha" ro
            fi
        fi
    done <<<"$preflight_rows"

    psql_admin --quiet --command "BEGIN;
        LOCK TABLE oscar_retention_hold IN SHARE ROW EXCLUSIVE MODE;
        UPDATE oscar_deletion_plan
           SET state='CONFIRMED', confirmed_by='$confirmed_by', confirmed_at=coalesce(confirmed_at,now())
         WHERE id='$plan' AND store_key='$store_key' AND id_scope=$id_scope
           AND state='PLANNED' AND expires_at>now();
        SELECT 1 / CASE WHEN EXISTS (
            SELECT 1 FROM oscar_deletion_plan WHERE id='$plan' AND store_key='$store_key'
              AND id_scope=$id_scope AND state='CONFIRMED'
        ) THEN 1 ELSE 0 END;
        UPDATE oscar_deletion_plan_item i
           SET state='HELD', detail='A retention hold was active at purge time', updated_at=now()
          FROM oscar_archive_generation g, oscar_deletion_plan p
         WHERE i.plan_id='$plan' AND p.id=i.plan_id
           AND p.store_key='$store_key' AND p.id_scope=$id_scope
           AND i.generation_id=g.id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
           AND i.state='PLANNED' AND g.state='SEALED'
           AND EXISTS (SELECT 1 FROM oscar_retention_hold h WHERE h.released_at IS NULL AND
               h.store_key=g.store_key AND h.id_scope=g.id_scope AND
               ((h.subject_type='ARCHIVE_GENERATION' AND h.subject_id=g.id::text) OR
                (h.subject_type='OBSERVATION' AND h.subject_id ~ '^[0-9]+$' AND EXISTS (
                    SELECT 1 FROM oscar_archive_id_block held_block
                     WHERE held_block.generation_id=g.id
                       AND h.subject_id::numeric BETWEEN held_block.min_id AND held_block.max_id))));
        SELECT 1 / CASE WHEN EXISTS (
            SELECT 1 FROM oscar_deletion_plan_item i
            JOIN oscar_deletion_plan p ON p.id=i.plan_id
            JOIN oscar_archive_generation g ON g.id=i.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
            WHERE i.plan_id='$plan' AND p.store_key='$store_key' AND p.id_scope=$id_scope AND i.state='PLANNED'
              AND NOT (g.state='SEALED' OR (g.state='DELETING' AND EXISTS (
                  SELECT 1 FROM oscar_deletion_ledger l
                  WHERE l.plan_id='$plan' AND l.store_key=p.store_key AND l.id_scope=p.id_scope
                    AND l.subject_type='ARCHIVE_GENERATION'
                    AND l.subject_id=g.id::text AND l.object_path IS NULL AND l.outcome='DELETING'
              )))
        ) THEN 0 ELSE 1 END;
        WITH changed AS (
            UPDATE oscar_archive_generation g SET state='DELETING'
              FROM oscar_deletion_plan_item i, oscar_deletion_plan p
             WHERE i.plan_id='$plan' AND p.id=i.plan_id
               AND p.store_key='$store_key' AND p.id_scope=$id_scope
               AND i.state='PLANNED' AND i.generation_id=g.id
               AND g.store_key=p.store_key AND g.id_scope=p.id_scope AND g.state='SEALED'
             RETURNING g.id
        )
        INSERT INTO oscar_deletion_ledger(plan_id,store_key,id_scope,subject_type,subject_id,object_path,outcome,detail)
            SELECT '$plan','$store_key',$id_scope,'ARCHIVE_GENERATION',id::text,NULL,'DELETING','Generation made non-queryable before filesystem deletion' FROM changed;
        WITH changed AS (
            UPDATE oscar_archive_object o SET state='DELETING'
              FROM oscar_deletion_plan_item i
              JOIN oscar_deletion_plan p ON p.id=i.plan_id
              JOIN oscar_archive_generation g ON g.id=i.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
             WHERE i.plan_id='$plan' AND p.store_key='$store_key' AND p.id_scope=$id_scope
               AND i.state='PLANNED' AND o.generation_id=g.id
               AND g.state='DELETING' AND o.state='ACTIVE'
             RETURNING o.generation_id,o.relative_path
        )
        INSERT INTO oscar_deletion_ledger(plan_id,store_key,id_scope,subject_type,subject_id,object_path,outcome,detail)
            SELECT '$plan','$store_key',$id_scope,'ARCHIVE_GENERATION',generation_id::text,relative_path,'DELETING','Checksum verified; deletion intent persisted' FROM changed;
        COMMIT;" >/dev/null

    delete_rows=$(psql_admin --tuples-only --no-align --field-separator=$'\t' --command \
        "SELECT g.id, o.relative_path, o.sha256, o.state FROM oscar_deletion_plan_item i
         JOIN oscar_deletion_plan p ON p.id=i.plan_id
         JOIN oscar_archive_generation g ON g.id=i.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
         JOIN oscar_archive_object o ON o.generation_id=g.id
         WHERE i.plan_id='$plan' AND p.store_key='$store_key' AND p.id_scope=$id_scope
           AND i.state='PLANNED' AND g.state='DELETING' AND o.state='DELETING'
         ORDER BY g.id,o.relative_path;")
    while IFS=$'\t' read -r generation relative expected_sha object_state; do
        [[ -n $generation && -n $relative && -n $expected_sha ]] || continue
        delete_outcome=$(archive_object_helper delete "$relative" "$expected_sha" rw)
        [[ $delete_outcome == DELETED || $delete_outcome == ALREADY_ABSENT ]] ||
            fail "Archive deletion helper returned an invalid outcome for: $relative"
        psql_admin --command "WITH changed AS (
            UPDATE oscar_archive_object SET state='DELETED'
             WHERE generation_id='$generation' AND relative_path='$relative' AND state='DELETING'
             RETURNING 1
        ) INSERT INTO oscar_deletion_ledger(plan_id,store_key,id_scope,subject_type,subject_id,object_path,outcome)
            SELECT '$plan','$store_key',$id_scope,'ARCHIVE_GENERATION','$generation','$relative','$delete_outcome' FROM changed;" >/dev/null
    done <<<"$delete_rows"
    psql_admin --command "BEGIN;
        UPDATE oscar_deletion_plan_item i SET state='COMPLETED', updated_at=now()
         FROM oscar_deletion_plan p, oscar_archive_generation g
         WHERE i.plan_id='$plan' AND p.id=i.plan_id AND p.store_key='$store_key' AND p.id_scope=$id_scope
           AND g.id=i.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
           AND i.state='PLANNED' AND NOT EXISTS (SELECT 1 FROM oscar_archive_object o WHERE o.generation_id=i.generation_id AND o.state<>'DELETED');
        UPDATE oscar_archive_generation g SET state='PURGED'
         FROM oscar_deletion_plan_item i, oscar_deletion_plan p
         WHERE i.plan_id='$plan' AND p.id=i.plan_id AND p.store_key='$store_key' AND p.id_scope=$id_scope
           AND i.generation_id=g.id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
           AND i.state='COMPLETED' AND g.state='DELETING';
        INSERT INTO oscar_tombstone(store_key,id_scope,subject_type,subject_id,reason,policy,generation_id)
            SELECT p.store_key,p.id_scope,'ARCHIVE_GENERATION',i.generation_id::text,'Cold archive generation deleted through confirmed plan','RETENTION_POLICY',i.generation_id
            FROM oscar_deletion_plan_item i
            JOIN oscar_deletion_plan p ON p.id=i.plan_id
            JOIN oscar_archive_generation g ON g.id=i.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
            WHERE i.plan_id='$plan' AND p.store_key='$store_key' AND p.id_scope=$id_scope AND i.state='COMPLETED'
            ON CONFLICT (subject_type,store_key,id_scope,subject_id) DO NOTHING;
        DELETE FROM oscar_obs_overlay overlay_row
         USING oscar_deletion_plan_item item, oscar_deletion_plan p, oscar_archive_generation g
         WHERE item.plan_id='$plan' AND p.id=item.plan_id AND p.store_key='$store_key' AND p.id_scope=$id_scope
           AND g.id=item.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
           AND item.state='COMPLETED' AND overlay_row.store_key=p.store_key AND overlay_row.id_scope=p.id_scope
           AND overlay_row.generation_id=item.generation_id;
        DELETE FROM oscar_tombstone observation_tombstone
         USING oscar_deletion_plan_item item, oscar_deletion_plan p, oscar_archive_generation g
         WHERE item.plan_id='$plan' AND p.id=item.plan_id AND p.store_key='$store_key' AND p.id_scope=$id_scope
           AND g.id=item.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
           AND item.state='COMPLETED' AND observation_tombstone.store_key=p.store_key AND observation_tombstone.id_scope=p.id_scope
           AND observation_tombstone.subject_type='OBSERVATION'
           AND observation_tombstone.generation_id=item.generation_id;
        UPDATE oscar_deletion_plan SET state=CASE WHEN EXISTS (SELECT 1 FROM oscar_deletion_plan_item WHERE plan_id='$plan' AND state='HELD') THEN 'COMPLETED_WITH_HOLDS' ELSE 'COMPLETED' END
         WHERE id='$plan' AND store_key='$store_key' AND id_scope=$id_scope
           AND NOT EXISTS (SELECT 1 FROM oscar_deletion_plan_item WHERE plan_id='$plan' AND state='PLANNED');
        COMMIT;" >/dev/null
    state=$(psql_admin --tuples-only --no-align --command "SELECT state FROM oscar_deletion_plan WHERE id='$plan' AND store_key='$store_key' AND id_scope=$id_scope;" | tr -d '[:space:]')
    [[ $state =~ ^COMPLETED(_WITH_HOLDS)?$ ]] || fail "Deletion stopped with plan $plan in state $state; rerun the same plan and token after correcting the reported problem."
    resume_archive_purge_oscar
    trap - EXIT
    printf 'Archive deletion plan %s completed. Minimal catalog and deletion-ledger records were retained.\n' "$plan"
)

archive_export() (
    require_configured
    local generation='' destination='' store_key='' id_scope=''
    while (($#)); do
        case $1 in
            --store-key) store_key=${2:?missing store key}; shift 2 ;;
            --id-scope) id_scope=${2:?missing ID scope}; shift 2 ;;
            --generation) generation=${2:?missing generation}; shift 2 ;;
            --destination) destination=${2:?missing destination}; shift 2 ;;
            *) fail "Unknown export option: $1" ;;
        esac
    done
    valid_store_key "$store_key" || fail '--store-key must be the archive store/table identifier shown by archive status.'
    valid_id_scope "$id_scope" || fail '--id-scope must be a signed 32-bit integer shown by archive status.'
    valid_uuid "$generation" || fail 'Invalid generation ID.'
    [[ -n $destination ]] || fail '--destination is required.'
    destination_parent=''; destination_name=''; partial=''; relative=''; expected_sha=''; rows=''; copied=0
    resume_oscar=false
    case $destination in
        */*) destination_parent=${destination%/*}; destination_name=${destination##*/} ;;
        *) destination_parent=.; destination_name=$destination ;;
    esac
    [[ -n $destination_name && $destination_name != . && $destination_name != .. ]] ||
        fail 'The archive export destination must name a new directory.'
    case $destination_parent in
        .) destination_parent=$PWD ;;
        /*) ;;
        *) destination_parent="$PWD/$destination_parent" ;;
    esac
    [[ "/$destination_parent/" != */../* && "/$destination_parent/" != */./* &&
       $destination_parent != *$'\n'* && $destination_parent != *$'\r'* ]] ||
        fail "Archive export parent must be a normalized path: $destination_parent"
    assert_safe_creatable_directory_path "$destination_parent"
    mkdir -p "$destination_parent"
    assert_no_symlink_components "$destination_parent"
    destination_parent=$(CDPATH= cd -- "$destination_parent" && pwd -P)
    destination="$destination_parent/$destination_name"
    for managed_root in "$archive_dir" "$backup_dir" "$wal_archive_dir" "$script_dir"; do
        path_contains "$managed_root" "$destination" &&
            fail "Archive export destination must be outside OSCAR managed and release roots: $destination"
    done
    [[ ! -e $destination ]] || fail "Archive export destination already exists: $destination"
    partial=$(mktemp -d "$destination_parent/.${destination_name}.partial.XXXXXX")
    chown 10001:10001 "$partial"
    chmod 0700 "$partial"
    cleanup_archive_export() {
        local status=$?
        case $partial in "$destination_parent"/."$destination_name".partial.*) rm -rf -- "$partial" || true ;; esac
        if $resume_oscar; then
            compose up --detach --no-deps --no-build --pull never oscar >/dev/null 2>&1 || true
        fi
        return "$status"
    }
    resume_archive_export_oscar() {
        if $resume_oscar; then
            compose up --detach --no-deps --no-build --pull never --wait --wait-timeout 300 oscar
            resume_oscar=false
        fi
    }
    trap cleanup_archive_export EXIT
    compose ps --status running --services | grep -Fxq oscar && resume_oscar=true || true
    $resume_oscar && compose stop oscar >/dev/null

    rows=$(psql_admin --tuples-only --no-align --field-separator=$'\t' --command \
        "SELECT o.relative_path,o.sha256 FROM oscar_archive_object o
         JOIN oscar_archive_generation g ON g.id=o.generation_id
         WHERE o.generation_id='$generation' AND g.store_key='$store_key' AND g.id_scope=$id_scope
           AND g.state IN ('ACTIVE','SEALED') AND o.state='ACTIVE'
           AND NOT EXISTS (SELECT 1 FROM oscar_archive_object unsafe
                            WHERE unsafe.generation_id=g.id AND unsafe.state<>'ACTIVE')
         ORDER BY o.relative_path;")
    while IFS=$'\t' read -r relative expected_sha; do
        [[ -n $relative ]] || continue
        archive_object_helper copy "$relative" "$expected_sha" ro "$partial"
        copied=$((copied + 1))
    done <<<"$rows"
    ((copied > 0)) || fail "No active objects exist for archive generation $generation"

    # The helper runs as the archive writer so it can traverse service-owned
    # 0700 directories and read 0600 objects without a DAC capability. Revoke
    # that temporary staging ownership before restarting OSCAR or publishing.
    chown -R 0:0 "$partial"
    find "$partial" -type d -exec chmod 0700 {} +
    find "$partial" -type f -exec chmod 0600 {} +

    psql_admin --tuples-only --no-align --command \
        "SELECT row_to_json(g) FROM oscar_archive_generation g WHERE id='$generation' AND store_key='$store_key' AND id_scope=$id_scope AND state IN ('ACTIVE','SEALED');" \
        >"$partial/catalog-$generation.json"
    psql_admin --tuples-only --no-align --command \
        "SELECT coalesce(json_agg(row_to_json(o) ORDER BY relative_path),'[]'::json) FROM oscar_archive_object o JOIN oscar_archive_generation g ON g.id=o.generation_id WHERE o.generation_id='$generation' AND g.store_key='$store_key' AND g.id_scope=$id_scope;" \
        >"$partial/objects-$generation.json"
    resume_archive_export_oscar
    printf '%s\n' \
        '-- OSCAR portable observation archive (DuckDB)' \
        "SELECT * FROM read_parquet('datasets/observations/**/*.parquet', union_by_name=true)" \
        'ORDER BY datastream_id, phenomenon_time, result_time, id_value;' \
        >"$partial/query.sql"
    printf '%s\n' \
        '# OSCAR portable archive export' \
        '' \
        'This directory is self-contained. Verify every file with `sha256sum --check SHA256SUMS` (or an equivalent SHA-256 tool), then query the Parquet data with DuckDB by running `duckdb < query.sql` from this directory.' \
        '' \
        'The generation manifest defines column types, sort order, compression, row count, ID bounds, and the SHA-256 of each primary object. The gzip schema snapshot preserves the OSH datastream schema used to decode `result_json`. Catalog JSON is retained for provenance.' \
        >"$partial/README.md"
    (
        cd "$partial"
        find . -type f ! -name SHA256SUMS -print0 | sort -z |
            while IFS= read -r -d '' file; do
                if command -v sha256sum >/dev/null 2>&1; then sha256sum "$file"; else shasum --algorithm 256 "$file"; fi
            done >SHA256SUMS
    )
    durably_flush_tree "$partial"
    publish_export_directory "$partial" "$destination"
    trap - EXIT
    printf 'Portable archive generation exported to %s\n' "$destination"
)

usage() {
    cat <<'EOF'
OSCAR storage administration

  backup
  backup-verify <backup-id>
  backup-prune [--keep COUNT]
  restore --backup <backup-id> --confirm <backup-id>
  archive status
  archive verify
  archive hold list
  archive hold create --store-key KEY --id-scope INT (--generation UUID | --observation ID) --reason TEXT [--created-by NAME]
  archive hold release --id UUID [--released-by NAME]
  archive dry-run --store-key KEY --id-scope INT --before YYYY-MM-DDTHH:MM:SSZ [--requested-by NAME]
  archive purge --store-key KEY --id-scope INT --plan UUID --token TOKEN
  archive export --store-key KEY --id-scope INT --generation UUID --destination PATH

Restore and archive purge are destructive and require explicit confirmation.
EOF
}

case $storage_command in
    help|-h|--help) ;;
    *) require_supported_storage_host; require_admin; require_configured; acquire_storage_admin_lock ;;
esac

case $storage_command in
    help|-h|--help|prepare-directories) ;;
    backup-verify) validate_offline_backup_directory ;;
    *)
        validate_storage_directories
        assert_storage_root_identities
        assert_deployment_volume_ownership
        ;;
esac

case $storage_command in
    backup) create_backup ;;
    backup-verify) verify_backup "${1:-}" ;;
    backup-prune) prune_backups "$@" ;;
    restore) restore_backup "$@" ;;
    prepare-directories) prepare_storage_directories "$@" ;;
    archive)
        archive_subcommand=${1:-status}; (($#)) && shift
        case $archive_subcommand in
            status) archive_status ;;
            verify) archive_verify ;;
            hold) archive_hold "$@" ;;
            dry-run) archive_dry_run "$@" ;;
            purge) archive_purge "$@" ;;
            export) archive_export "$@" ;;
            *) fail "Unknown archive command: $archive_subcommand" ;;
        esac
        ;;
    help|-h|--help) usage ;;
    *) fail "Unknown storage command: $storage_command" ;;
esac
