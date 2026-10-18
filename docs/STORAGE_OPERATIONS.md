# OSCAR 3.9.2 storage operations

This is the administrator runbook for OSCAR's PostgreSQL hot store, Parquet cold tier, direct daily
journal, retained media, WAL archive, and coordinated backups. Commands assume the extracted 3.9.2
release directory is the current directory.

For design rationale see [Storage architecture](STORAGE_ARCHITECTURE.md). For exact state
transitions see [Data lifecycle](DATA_LIFECYCLE.md). For recovery see
[Backup and restore](BACKUP_RESTORE.md).

Run these procedures only on the supported Ubuntu Server 24.04 x86-64 or Windows 11 x86-64 Docker
Desktop/WSL 2 hosts. macOS deployment and storage commands fail closed and are not an operational
fallback.

## Safety rules

1. Never use `docker compose down --volumes`, delete a named volume, or remove a cataloged archive
   object unless permanent data loss is explicitly authorized and a verified backup is retained.
2. Never edit `.open`/`.seg` journal files, published daily CSVs/manifests, retained-media internals,
   Parquet files, or generation manifests in place.
3. Run `archive verify` before enabling hot deletion, exporting evidence, or creating a cold purge
   plan.
4. Use `archive dry-run` and its one-time token for cold deletion. Do not substitute `rm`, Explorer,
   storage-array expiration, or a generic object-store lifecycle.
5. Treat a missing or checksum-mismatched object as an integrity incident. Restore or investigate;
   do not delete its catalog record to make the error disappear.
6. Keep the backup encryption key outside the only backup and restrict all archive/export/backup
   copies as sensitive operational records.
7. Do not start two storage-administration commands concurrently. The launcher enforces one
   crash-released, nonblocking deployment lock and reports the competing command; investigate a
   persistent lock-file error rather than deleting or bypassing it. Locks are keyed by
   `OSCAR_DEPLOYMENT_ID` in `/run/lock/oscar-storage` (Ubuntu) or
   `%ProgramData%\OSCAR\StorageLocks` (Windows), so a
   clean-release upgrade cannot evade an older process's lock.

## Standard 3.9.2 configuration

New installations receive these defaults from `dist/config/standard/config.json`:

| Setting | Default | Operational effect |
| --- | --- | --- |
| `dailyFileJournal.enabled` / `required` on RPM drivers | `true` / `true` | Lane driver fails closed if durable source capture is unavailable |
| Journal force limits | 1 s / 128 records / 1 MiB | Maximum time/count/bytes before a segment force |
| Journal segment limits | 64 MiB / 15 min | Bounds recovery scan and segment size |
| Journal `zoneId` | `UTC` | Defines immutable daily windows and local timestamp field |
| Journal observation mode | `LATEST` | Keeps the live `dailyFile` event required for lane occupancy processing, while hourly maintenance retains only the newest compatibility row; immutable journal/CSV data remains authoritative |
| Database `idProviderType` | `SEQUENTIAL` | Required for exact, race-free archive ownership |
| Database batch | 10,000 rows / 1 s | Bounded insert transaction and commit period |
| Archive hot retention | 30 days | Age before eligible detector streams are copied to cold storage |
| Archive interval | 60 min | Background cycle frequency |
| Archive catch-up bound | 24 generations / 15 min | Stops starting new generations at the first bound; in-progress publication completes safely |
| Maximum generation | 2,000,000 rows / 2 GiB estimated uncompressed bytes | A UTC window is halved down to one second while either cap is exceeded; an irreducible prefix fails closed with hot rows retained |
| Parquet compression | ZSTD level 6 | Cold-storage size/CPU tradeoff |
| Archive rollback grace | 7 days | Minimum active overlap after parity before hot deletion |
| `deleteHotAfterArchive` | `false` | Copy-only rollout; no archived hot rows are removed |
| Video retention age | 7 days | Age before source video is converted to retained evidence |
| Retained evidence | exactly 5 JPEGs, quality 85 | First, quarter, middle, three-quarter, and last decoded frames |
| Source-video rollback grace | 24 h | MP4 preserved after a successful five-frame publication |
| Storage pressure | trigger 85%, target 80% | Removes only eligible cataloged media sets |
| Pressure minimum age | 10 min | Prevents immediate removal of newly published sets |
| Verified local backup retention | 14 backups | A newly created and verified backup prunes older verified backups by count |
| Automatic backup pruning | `true` | Runs only after creating a new backup and also prunes WAL older than the oldest retained base-backup start boundary |

`delegateObservationLifecycleToDatabase=true` disables the old occupancy-gated high-volume purge so
the tiered database owns gamma/neutron lifecycle. It does not disable connection-status maintenance
or manifest-gated daily-file compatibility cleanup.

An upgraded deployment keeps its persisted `/var/lib/oscar/config.json`; the release does not
silently replace site configuration. Always inspect the running module settings rather than assume
the file shipped in the ZIP became active.

## New installation and storage paths

For a new 3.9.2 production system, put these `.env` paths on durable filesystems with monitoring and
backup:

```dotenv
OSCAR_ARCHIVE_DIR=/absolute/path/to/oscar-storage/archive
OSCAR_WAL_ARCHIVE_DIR=/absolute/path/to/oscar-storage/wal-archive
OSCAR_BACKUP_DIR=/absolute/path/to/oscar-storage/backups
OSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt
```

The three absolute storage roots are managed host paths, not backup payload placement instructions.
Archive and WAL are long-lived service bind mounts. The administrator-owned backup root is never
mounted into a long-running service and is exposed only to narrowly scoped one-shot helpers.
During either same-host or cross-host restore, OSCAR preserves those target roots along with the
target deployment ID, platform, and HTTPS endpoint while it restores source data, credentials, TLS
material, and portable configuration. A backup created under another host's archive/WAL/backup
roots therefore cannot redirect the target after restore.

The credential settings shown above are different: `./secrets`, `./tls`, and
`./secrets/backup-key.txt` are the only supported bindings because backup, safety-copy, and atomic
install operations use those release-relative locations. Setup/upgrade, backup, and restore reject
custom values before starting services or changing data. See [Backup and restore](BACKUP_RESTORE.md#same-host-and-cross-host-environment-policy).

Initialization converts the shipped sibling defaults into absolute paths under an `oscar-storage`
directory next to the versioned release directory, persists those absolute values in `.env`, creates
the directories, assigns the stable container UIDs used by the release, creates an external backup
key, initializes a new PostgreSQL cluster with data checksums, and starts the services. A site may
set different absolute paths before initialization. Custom relative paths are rejected because they
would resolve against a different directory after a clean-release upgrade.

When moving to a later release, copy the existing `.env`; do not replace its three absolute storage
roots with the new `.env.example` values. The new release will therefore mount the same archive and
WAL paths and continue using the same external backup root even when it is extracted into a
different sibling directory. Confirm the archive/WAL sources with `docker compose config`, then
confirm the backup root directly from the single `OSCAR_BACKUP_DIR` entry in `.env` before starting
the upgrade.

Each configured storage root must be a dedicated directory at least two path components below its
filesystem/volume root. The archive, backup, and WAL roots must not equal, contain, or overlap one
another; none may be inside or broad enough to contain the versioned release directory, and none
may contain the administrator's home/profile directory. Existing path components must not be
symbolic links, junctions, or reparse points. Both
launchers enforce these rules before privileged storage work and again after initialization creates
the directories. This protects purge and restore operations from a typo such as `/`, `C:\`, a parent
mount, or a redirected path.

Each root also has an administrator-owned `.oscar-storage-root` identity with format
`oscar-storage-root-identity`, version `1`, the deployment UUID, root kind (`archive`, `backup`, or
`wal-archive`), claim time, and explicit-adoption audit fields. A missing marker on a nonempty root,
a foreign deployment UUID, a swapped root kind, unsafe ownership/ACL, or a symlink/reparse-point
marker is a hard failure. Ubuntu archive and WAL roots are root-owned service-group directories mode
`1770`, keeping service writes possible while the sticky bit protects the root-owned marker; the
backup root is root-only mode `0700`. Windows uses a protected administrator ACL; `docker-users`
has the read/execute access required by the confined Docker helper and must be treated as a
Docker-engine-equivalent privileged group. Every live database/archive command and `backup-prune`
validates all root and Docker-volume identities. `backup-verify` alone may run offline without
them. It is an acceptance mutation that publishes/replaces `VERIFIED` and normalizes backup
permissions; any optional live-catalog write is separately volume-ownership-gated.

An upgrade may adopt a verified, nonempty legacy root exactly once with
`--adopt-legacy-storage-roots` on Ubuntu or `-AdoptLegacyStorageRoots` on Windows. Setup records
`adoption=explicit-existing`, UTC time, and actor in each marker. Do not use adoption for an empty
replacement path or a root from another deployment. Empty new roots are claimed automatically.

Ubuntu:

```sh
sudo bash oscar.sh init
```

Windows (Administrator Windows PowerShell 5.1 or the elevated launcher menu):

```powershell
.\oscar.bat init
```

Use local NTFS for a Windows release directory; do not put live database or journal state in a
cloud-synchronization folder. On Ubuntu, avoid network filesystems that cannot provide the required
rename, force, ownership, and PostgreSQL semantics.

### Existing pre-3.9.2 deployments

The complete 3.9.2 storage profile is not an automatic in-place conversion. `oscar upgrade` preserves
the existing application configuration and database volume, and PostgreSQL data checksums are an
initial-cluster property.

The 3.9.2 observation schema also installs a corrected natural-key unique index that treats null
feature, phenomenon-time, and result-time fields as equal. This is important because a null result
time is normal for OSCAR observations. If an older database already contains duplicates under that
corrected key, PostgreSQL deliberately refuses to create the index instead of choosing a row or
silently retaining ambiguity. Audit and resolve those duplicates under an approved migration before
attempting an in-place database upgrade. A fresh 3.9.2 database has no such cleanup requirement.

For the disposable test systems, initialize a clean 3.9.2 deployment and new database. For a
production pre-3.9.2 system whose history must remain available:

1. freeze retention/deletion changes;
2. take and verify the existing system's supported backup/export;
3. retain the old deployment read-only for policy lookup;
4. initialize 3.9.2 on clean state;
5. validate lane configuration and workflows;
6. migrate only records required by an approved, tested migration procedure; and
7. preserve the pre-3.9.2 system until retention and audit owners accept the transition.

Do not erase an old production volume simply to make the 3.9.2 module start.

## Production rollout

### Phase 1: copy-only archive

Keep `deleteHotAfterArchive=false`, which is the shipping default. Run long enough to create
multiple generations across representative lane/output rates. Check:

```sh
sudo bash oscar.sh archive status
sudo bash oscar.sh archive verify
```

Windows:

```powershell
.\oscar.bat archive status
.\oscar.bat archive verify
```

Exercise queries that are hot-only, cold-only, and cross the retention boundary. Confirm event UUID
lookup, Event Details, charts, adjudication, report generation, and newest/latest observations.
Review parity receipts and failed archive jobs with the queries below.

### Phase 2: recovery acceptance

Create and verify a coordinated backup, copy it off-host, restore it on an isolated test deployment,
and run the full OSCAR regression suite. Confirm that the restored archive, journal, daily files,
media, and mixed-tier queries match the source system. See
[Backup and restore](BACKUP_RESTORE.md).

### Phase 3: controlled hot deletion

Only after Phases 1 and 2 pass, change the running **PostGIS Hot/Cold Database** module's nested
archive setting to `deleteHotAfterArchive=true` through SensorHub Admin, save the global
configuration, and restart in a planned window. Preserve `requireParityReceipt=true` and a rollback
grace suitable for the site.

The next lifecycle cycles delete only exact generation-owned IDs with a successful parity receipt,
in bounded batches, after grace. Watch PostgreSQL row count, WAL, database size, archive receipts,
query latency, and logs. PostgreSQL may not immediately return deleted heap space to the filesystem;
normal autovacuum reuses it. Do not run an unplanned `VACUUM FULL`, which takes strong locks and can
cause a major outage.

### Phase 4: cold retention

After the archive has accumulated beyond the site's cold-retention period, use the reviewed,
tokenized deletion workflow below. Keep at least one tested backup chain and apply the same policy to
portable/off-site copies.

## Routine command reference

| Task | Ubuntu | Windows |
| --- | --- | --- |
| Service status | `sudo bash oscar.sh status` | `.\oscar.bat status` |
| OSCAR logs | `sudo bash oscar.sh logs --service oscar --tail 500` | `.\oscar.bat logs -Service oscar -Tail 500` |
| PostgreSQL logs | `sudo bash oscar.sh logs --service postgres --tail 500` | `.\oscar.bat logs -Service postgres -Tail 500` |
| Archive summary/holds | `sudo bash oscar.sh archive status` | `.\oscar.bat archive status` |
| Verify all active archive objects | `sudo bash oscar.sh archive verify` | `.\oscar.bat archive verify` |
| Coordinated backup | `sudo bash oscar.sh backup` | `.\oscar.bat backup` |
| Verify backup | `sudo bash oscar.sh backup-verify ID` | `.\oscar.bat backup-verify -BackupId ID` |
| Prune verified backups/WAL | `sudo bash oscar.sh backup-prune --keep 14` | `.\oscar.bat backup-prune -Keep 14` |
| List retention holds | `sudo bash oscar.sh archive hold list` | `.\oscar.bat archive hold list` |

The archive and backup commands require a configured deployment. Mutating commands also require
root/Administrator privileges.

## Archive health inspection

`archive status` reports generation counts, rows, and Parquet bytes grouped by state/profile, then
the number of active holds. `archive verify` hashes every cataloged object whose object state is
`ACTIVE` and compares it with PostgreSQL. Both commands also reconcile the complete physical
archive root without changing it. The administrator-owned `.oscar-storage-root` is the only
top-level exemption; all archive data must have the approved `datasets/...` shape. An unexpected
top-level object, empty/unapproved directory, absent `datasets` tree accompanied by other content,
unregistered final file, or still-present `DELETED` object fails the command before backup.
Symlinks/reparse points and non-regular entries also fail. A `.partial` younger than the archive
job's two-hour stale window is reported as possible in-progress work; at or beyond two hours it
fails as stale. Investigate ownership and job state—these commands never auto-delete an orphan.

For deeper inspection, use the bootstrap account inside the private PostgreSQL container. This does
not expose port 5432 on the host.

```sh
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  PGOPTIONS=-csearch_path=oscar,public
  export PGPASSWORD PGOPTIONS
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command \
  "SELECT state, count(*) FROM oscar_archive_job GROUP BY state ORDER BY state;"
```

Recent failures:

```sh
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  PGOPTIONS=-csearch_path=oscar,public
  export PGPASSWORD PGOPTIONS
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command \
  "SELECT id, profile, window_start, window_end, attempt, updated_at, left(error, 200) AS error
     FROM oscar_archive_job
    WHERE state = 'FAILED'
    ORDER BY updated_at DESC
    LIMIT 20;"
```

Parity and deletion receipts:

```sh
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  PGOPTIONS=-csearch_path=oscar,public
  export PGPASSWORD PGOPTIONS
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command \
  "SELECT generation_id, verification_type, status, expected_rows, actual_rows, verified_at, detail
     FROM oscar_archive_verification
    ORDER BY verified_at DESC
    LIMIT 30;"
```

Active/unverified generations and their age:

```sh
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  PGOPTIONS=-csearch_path=oscar,public
  export PGPASSWORD PGOPTIONS
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command \
  "SELECT id, state, parity_verified, window_start, window_end, row_count, activated_at
     FROM oscar_archive_generation
    WHERE state IN ('ACTIVE','SEALED')
    ORDER BY window_start
    LIMIT 50;"
```

Active holds (read-only SQL inspection):

```sh
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  PGOPTIONS=-csearch_path=oscar,public
  export PGPASSWORD PGOPTIONS
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command \
  "SELECT id, subject_type, subject_id, reason, created_by, created_at
     FROM oscar_retention_hold
    WHERE released_at IS NULL
    ORDER BY created_at;"
```

## Manage retention holds

Place a hold before a generation or exact observation could become eligible for hot or cold
deletion. Run `archive status` first and copy the exact `store_key` and `id_scope` shown for the
target generation. These two values are mandatory isolation boundaries: numeric observation IDs
may repeat in a different OSH store, and OSCAR refuses a hold, plan, purge, or export without the
explicit namespace. Listing includes active and released history:

```sh
sudo bash oscar.sh archive hold list
sudo bash oscar.sh archive hold create \
  --store-key <store-key> \
  --id-scope <id-scope> \
  --generation <generation-uuid> \
  --reason "investigation 2026-1042" \
  --created-by records-admin
```

For one observation, use its positive numeric internal ID:

```sh
sudo bash oscar.sh archive hold create \
  --store-key <store-key> \
  --id-scope <id-scope> \
  --observation 123456789 \
  --reason "case 2026-1042"
```

Windows equivalents:

```powershell
.\oscar.bat archive hold list
.\oscar.bat archive hold create `
  -StoreKey <store-key> `
  -IdScope <id-scope> `
  -Generation <generation-uuid> `
  -Reason "investigation 2026-1042" `
  -CreatedBy records-admin
.\oscar.bat archive hold create -StoreKey <store-key> -IdScope <id-scope> -Observation 123456789 -Reason "case 2026-1042"
```

The CLI verifies that a generation exists, validates identifiers/reason/actor fields, and returns a
hold UUID. Record that UUID with the controlling case. Generation holds block lifecycle eligibility;
observation holds preserve that exact hot row and conservatively block a cold-generation purge when
the ID falls within its generation range.

Release only after the legal/records owner authorizes it. Release records the actor/time and retains
the row:

```sh
sudo bash oscar.sh archive hold release --id <hold-uuid> --released-by records-admin
```

```powershell
.\oscar.bat archive hold release -HoldId <hold-uuid> -ReleasedBy records-admin
```

The release CLI is the supported hold interface. Do not update hold rows directly.
Hold creation is serialized with purge confirmation. Generation holds are accepted only while the
generation is `ACTIVE` or `SEALED`; a hold targeting a `DELETING`/`PURGED` generation, or an exact
observation already covered by such a generation/tombstone, is rejected rather than presenting a
false assurance after deletion has started.

## Delete old cold generations

Use a UTC cutoff that reflects approved policy. Only `SEALED` generations whose `window_end` is
before the cutoff can enter the plan.

### 1. Verify

```sh
sudo bash oscar.sh archive verify
```

### 2. Create and review a dry-run plan

```sh
sudo bash oscar.sh archive dry-run \
  --store-key <store-key> \
  --id-scope <id-scope> \
  --before 2026-01-01T00:00:00Z \
  --requested-by records-admin
```

Windows:

```powershell
.\oscar.bat archive dry-run `
  -StoreKey <store-key> `
  -IdScope <id-scope> `
  -Before 2026-01-01T00:00:00Z `
  -RequestedBy records-admin
```

The output includes the plan UUID, eligible rows/bytes, held-generation count, and a random
48-hex-character token. The token is shown once. The plan freezes the selected generation IDs and
expires after 24 hours; a later generation does not enter an already reviewed plan.

Review the plan against retention approval, active holds, current verified backups, and any open
incident. Do not proceed if counts are unexpected.

### 3. Purge the approved plan

```sh
sudo bash oscar.sh archive purge --store-key <store-key> --id-scope <id-scope> --plan <uuid> --token <token>
```

Windows:

```powershell
.\oscar.bat archive purge -StoreKey <store-key> -IdScope <id-scope> -Plan <uuid> -Token <token>
```

Purge briefly stops only OSCAR if it was running and always attempts to restore that prior state;
PostgreSQL and the gateway are not stopped. It preflights paths and hashes through a locked-down,
networkless, read-only-rootfs one-shot OSCAR-image helper that receives only the archive root
(read-only for verification, writable only for deletion). It then rechecks holds while holding the
same PostgreSQL lock used by hold creation. In one transaction it changes every selected generation
to `DELETING` (which
removes the whole generation from hot/cold query planning), persists generation/object deletion
intent, and only then starts filesystem removal. Catalog paths are resolved canonically beneath the
configured archive root; every helper path component is rechecked and symlink/reparse-point escapes
are rejected. If the process is interrupted, rerun the **same** plan and token; a confirmed plan
remains resumable, validates any still-present `DELETING` object, and records whether the helper
deleted it or found the transactionally authorized leaf already absent. Held items finish as
`COMPLETED_WITH_HOLDS`; create a new plan after the hold is formally released. Plan tokens are
hashed in PostgreSQL and cannot be used after completion; an unconfirmed plan expires after 24
hours. Finalization preserves the generation tombstone/catalog/deletion ledger but transactionally
removes observation overlays and observation tombstones that carry the exact now-`PURGED`
generation ID. Legacy unowned mutation rows require a separately reviewed migration.

Afterward, run `archive status`, `archive verify`, a cold-range query, and a backup. Retain the
approval, dry-run output, deletion ledger, and verification result with records-management evidence.

## Export a generation for independent review

Find the generation UUID with `archive status` plus the catalog query above, verify the archive, then
export it.

```sh
sudo bash oscar.sh archive export \
  --store-key <store-key> \
  --id-scope <id-scope> \
  --generation <uuid> \
  --destination /secure/review/oscar-archive
```

```powershell
.\oscar.bat archive export `
  -StoreKey <store-key> `
  -IdScope <id-scope> `
  -Generation <uuid> `
  -Destination D:\secure-review\oscar-archive
```

The destination must not already exist. The command briefly stops only OSCAR if it was running and
always attempts to resume it. Each object is checksum-verified and copied by the same locked-down
one-shot helper with only the archive mounted read-only and a newly created hidden export partial
mounted writable. The helper rechecks every component and rejects symlink/reparse-point objects.
The command preserves relative paths, adds generation and object
catalog JSON, `README.md`, a ready-to-run DuckDB `query.sql`, and `SHA256SUMS`, then renames the
complete package into place with the same compiled atomic no-replace publisher used by backups.
The staged tree and parent receive durability barriers first; a racing destination is never
overwritten and both trees remain available for diagnosis. The package is independently queryable
with DuckDB, but it is not added to OSCAR's live query plan and is not a replacement for a
coordinated OSCAR backup. See
[Archive format](ARCHIVE_FORMAT.md#querying-a-portable-copy-with-duckdb) for DuckDB examples.

## Daily-file checks

After UTC midnight (or local midnight if the configured journal `zoneId` was deliberately changed),
confirm for each active lane:

1. a prior-day `files/dailyfiles/<lane>_YYYY-MM-DD.csv` exists;
2. the matching `.csv.manifest.v1.json` exists;
3. CSV SHA-256 matches the manifest;
4. `recordCount` and `byteCount` are plausible;
5. the private ledger is `PUBLISHED` with the exact same half-open window; and
6. OSCAR logs have no journal force, CRC, atomic-rename, or immutable-publication error.

Private sealed segments become retention-eligible only after a newly created coordinated backup
has passed HMAC/checksum, strict tar-member, and PostgreSQL verification and has recorded a receipt
for the exact lane/day CSV, manifest, and sealed-segment inventory captured in that snapshot. The
receipt is bound to the backup ID and authenticated application-state SHA-256. Manual
`backup-verify` does not create these receipts. An old-day segment arriving after the snapshot is
therefore not covered and must not be removed by the journal sweep.

Journal internals live under `files/.dailyfile-journal`. They are private recovery state, not a
bucket for users to edit or download. Published CSVs are available in the authenticated
`dailyfiles` bucket according to configured permissions.

If the log reports a truncated final frame at startup, the journal has already truncated only the
incomplete tail and forced the repair. A CRC mismatch or a conflict with an existing immutable CSV
is different: stop the affected driver, preserve the lane/day segment directory, ledger, CSV, and
manifest, and investigate. Do not delete the conflicting artifact merely to start the driver.

## Retained-media checks

For an event older than the configured seven-day retention age:

- Event Details should show five labeled still frames per successfully retained camera;
- each frame endpoint should return `image/jpeg` only to an authenticated user with `videos` GET
  permission;
- the manifest should report five distinct `sourceFrameOrdinal` values and the positions `FIRST`,
  `QUARTER`, `MIDDLE`, `THREE_QUARTERS`, and `LAST`;
- the source MP4 should remain during the 24-hour rollback grace; and
- after grace and a later successful retention pass, the manifest should report source state
  `DELETED` while the five frames remain viewable.

A `404` from the retained-media event endpoint is a compatibility signal: the Viewer must fall back
to the occupancy's legacy `videoPaths`. It is normal for legacy/pre-3.9.2 events. A manifest whose
referenced frame is missing or corrupt is not normal; the API withholds that asset, and the source
or backup should be used for recovery.

Release acceptance must include both a clip that publishes exactly five distinct JPEG positions and
a clip with fewer than five decoded frames. The latter must retain its MP4, record a failed
conversion, publish no partial media set, and continue through the Viewer's `404` legacy-video
fallback.

When storage reaches 85 percent, OSCAR logs a pressure-cleanup warning and removes only complete,
eligible media sets until 80 percent is reached. If it reports that storage remains above target,
add capacity or perform approved retention work. Do not expect pressure cleanup to remove daily
files, arbitrary legacy videos, reports, adjudications, or cold Parquet.

## Capacity and performance monitoring

There is no single safe capacity number for every site. Measure actual lanes, message frequency,
camera bitrate, alarm rate, retention, and query concurrency.

Container CPU and memory snapshot:

```sh
docker stats --no-stream
```

Confirm the effective archive and WAL bind sources first. `init` persists absolute paths in `.env`;
the `source:` entries printed here are authoritative for those two long-lived mounts and must not
point inside the versioned release directory. `OSCAR_BACKUP_DIR` does not appear as a long-lived
Compose mount; confirm its single absolute `.env` value separately.

```sh
docker compose config
```

Measure the actual mounted bind paths and named volumes through the running containers. These
POSIX-shell examples avoid accidentally inspecting obsolete
`data/` or `backups/` directories in the release tree:

```sh
docker compose exec -T oscar sh -c \
  'du -sh /var/lib/oscar/archive /var/lib/oscar/files /var/lib/oscar/db; df -h /var/lib/oscar/archive /var/lib/oscar'
docker compose exec -T postgres sh -c \
  'du -sh /var/lib/postgresql/data /var/lib/postgresql/wal-archive; df -h /var/lib/postgresql/data /var/lib/postgresql/wal-archive'
sudo du -sh -- \
  "$(awk -F= '$1=="OSCAR_ARCHIVE_DIR" {print substr($0,index($0,"=")+1)}' .env)" \
  "$(awk -F= '$1=="OSCAR_WAL_ARCHIVE_DIR" {print substr($0,index($0,"=")+1)}' .env)" \
  "$(awk -F= '$1=="OSCAR_BACKUP_DIR" {print substr($0,index($0,"=")+1)}' .env)"
```

PostgreSQL database and major relations:

```sh
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  PGOPTIONS=-csearch_path=oscar,public
  export PGPASSWORD PGOPTIONS
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command \
  "SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size;
   SELECT relname,
          pg_size_pretty(pg_total_relation_size(relid)) AS total,
          n_live_tup, n_dead_tup
     FROM pg_stat_user_tables
    ORDER BY pg_total_relation_size(relid) DESC
    LIMIT 20;"
```

WAL, checkpoints, temporary I/O, and query work should be trended rather than judged from one
sample. PostgreSQL 16 exposes useful fields in `pg_stat_wal`, `pg_stat_bgwriter`, and
`pg_stat_database`; `pg_stat_statements` is preloaded and created for new deployments.

```sh
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  PGOPTIONS=-csearch_path=oscar,public
  export PGPASSWORD PGOPTIONS
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command \
  "SELECT wal_records, wal_fpi, pg_size_pretty(wal_bytes) AS wal_bytes
     FROM pg_stat_wal;
   SELECT datname, temp_files, pg_size_pretty(temp_bytes) AS temp_bytes,
          blk_read_time, blk_write_time
     FROM pg_stat_database
    WHERE datname = current_database();"
```

Expected behavior after rollout is lower PostgreSQL transaction/trigger/WAL overhead per telemetry
row and bounded long-term hot-table growth. Expect temporary CPU and sequential I/O during a
DuckDB export/parity pass, and CPU during FFmpeg JPEG extraction. Each generation is bounded; during
backlog catch-up, one cycle may start up to 24 generations over its 15-minute start window. Health/status UI polling remains independently bounded. Treat a
sustained regression—not a brief background spike—as the alert condition.

Track at least:

- hot database total/index/table size and dead tuples;
- archive bytes, generation backlog, export duration/failures, and parity latency;
- WAL archive growth and archive-command failures;
- journal force/publication errors and time since last daily manifest per lane;
- media conversion success/failure, source-grace backlog, and pressure-deletion results;
- OSCAR/PostgreSQL CPU, resident memory, disk latency, and filesystem saturation;
- backup age, verification age, off-site-copy age, and last successful restore drill; and
- query p50/p95/p99 for current events, UUID lookup, reports, and cross-tier history.

## Failure modes and recovery

| Symptom | Safety behavior | Operator action |
| --- | --- | --- |
| Required daily journal unavailable at driver startup | Driver fails closed | Restore service ordering, writable space/ownership, and atomic-rename-capable filesystem; restart journal then driver |
| Journal append/force fails | Required reader stops; record is not reported as accepted | Preserve logs/files, restore capacity/permissions, restart and verify lane publication |
| Truncated `.open` tail after crash | Only incomplete final frame is truncated | Confirm warning and next successful append/publication |
| Complete-frame CRC or immutable CSV mismatch | Initialization/publication fails visibly | Preserve all evidence; investigate storage/hardware; recover from verified copy |
| Observation batch commit fails | Snapshots stay queued for a later in-process retry | Fix PostgreSQL/network/disk immediately; restart only after assessing uncommitted-memory exposure |
| Archive export fails | Hot rows remain; job records `FAILED` | Check database, archive space/permissions, DuckDB error, stale partials; allow controlled retry |
| Parity fails | Hot rows remain; generation is not sealable | Compare receipt details and source/object hashes; do not enable/bypass deletion |
| Observation hold defers hot deletion | Held exact IDs remain hot; generation stays `ACTIVE` | No emergency action; review/release hold only through approved workflow |
| Cataloged archive object missing or hash mismatch | Reader/verify/purge fails | Stop destructive work, preserve evidence, restore exact object from coordinated backup, verify again |
| Unregistered/`DELETED` archive file or stale `.partial` | Archive status/verify fails without changing the file | Correlate UUID/path with export jobs and logs; reconcile under an approved recovery procedure, never delete merely to clear the check |
| Source video has fewer than five decodable frames | No retained manifest; MP4 preserved | Correct camera/recording health; keep source under legacy playback and investigate |
| Media publication fails | Partial set stays invisible; source preserved; retry ledger records failure | Check FFmpeg, source integrity, filesystem/rename/space; allow idempotent retry |
| Pressure cleanup cannot reach target | Protected data stays; error is logged | Add capacity or perform approved cold/media retention; never remove journal/adjudication files ad hoc |
| WAL archive path full/unwritable | PostgreSQL retries archiving and local `pg_wal` can grow | Restore archive path immediately, verify PostgreSQL logs and backup chain; use verified-backup pruning rather than deleting WAL blindly |
| Backup fails | `.partial` or finalized-but-unverified directory remains; services are resumed where possible | Check `status`, preserve diagnostics, correct the cause, then re-verify or run a new backup |
| Restore fails | Deployment may remain stopped/partial | Keep producers disconnected; preserve `pre-restore-*`; repair cause and repeat from the same verified backup or escalate |

## Monthly storage audit

At least monthly, and before changing retention:

1. Record filesystem and PostgreSQL sizes by data class.
2. Compare archive generation rows/bytes with hot-row reduction and policy cutoffs.
3. Review failed/stale jobs, parity failures, active holds, and deletion ledgers.
4. Verify all active archive objects.
5. Sample daily CSV manifest checks across lanes and daylight-saving boundaries where applicable.
6. Sample retained media across cameras, including source deletion after grace and legacy fallback.
7. Review orphaned partials/unregistered files without deleting them until ownership is established.
8. Verify the newest backup, off-site copy, and encryption-key escrow.
9. Review WAL/archive/backup growth and the tested recovery chain.
10. Compare CPU, memory, disk latency, WAL, and query latency with the prior baseline.
11. Record findings, corrective actions, owner, and deadline in the site's operations system.

The regression suite validates functional storage workflows, but it does not replace production
capacity trending, records governance, security review, or real restore drills.

## Privacy and incident handling

Access to OSH APIs does not automatically authorize access to host archive/backup files. Limit host
administration and portable export rights separately. Log who created, copied, reviewed, and
destroyed an export. Use encrypted transport/media and never email raw alarm imagery or daily files
unless an approved secure channel and business purpose exist.

If integrity or unauthorized access is suspected, stop retention/deletion, preserve logs and
catalog state, take a forensic copy under incident procedure, and rotate affected credentials. Do
not run cleanup commands to conceal symptoms before evidence is captured.
