# OSCAR 3.9.2 backup, restore, and recovery

OSCAR 3.9.2 provides a coordinated backup of the PostgreSQL cluster, application state, cold
archive, archived WAL, release configuration, and encrypted deployment credentials. A checksum and
`pg_verifybackup` pass is required before the backup is accepted. With OSCAR quiesced, creation also
requires every active cold-archive object to exist, match its catalog checksum, and pass filesystem
reconciliation before PostgreSQL or archive snapshots begin.

This runbook uses only commands implemented by the release launchers. Read it completely and carry
out a restore drill on an isolated test host before relying on a deployment for production recovery.
Run it only on supported Ubuntu Server 24.04 x86-64 or Windows 11 x86-64 Docker Desktop/WSL 2
hosts; macOS deployment and storage operations fail closed.

## What a coordinated backup contains

Each backup is stored under `${OSCAR_BACKUP_DIR}/<backup-id>`, where the ID has the form
`YYYYMMDDTHHMMSSZ-<eight hex characters>`.

| Object | Contents |
| --- | --- |
| `postgres/` | Plain-format `pg_basebackup` of the complete PostgreSQL cluster, with required WAL streamed into the backup |
| `oscar-state.tar.gz` | Mutable `/var/lib/oscar` application state, including saved SensorHub configuration, journal, daily files, videos/JPEGs, reports, and adjudication artifacts; excludes the separately captured archive path, any legacy embedded backup mountpoint, and the verified image-owned links (`lib`, `web`, `rules`, `documentation`, `trusted_certificates`, `config`, and `logback.xml`) that the restored image recreates |
| `archive.tar.gz` | Complete configured `/var/lib/oscar/archive` data tree, excluding the host-local `.oscar-storage-root` identity |
| `wal-archive.tar.gz` | Snapshot of `/var/lib/postgresql/wal-archive`, excluding the host-local `.oscar-storage-root` identity |
| `deployment-secrets.tar.gz.enc` | `.env`, `secrets/`, and `tls/`, encrypted with AES-256-CBC and PBKDF2 using the external backup key |
| `release-config.tar.gz` | Non-secret Compose, image-build, sample environment, and release documentation files |
| `epoch.json` | Backup UUID, backup ID, UTC creation time, OSCAR version, PostgreSQL LSN, archive root, and creation state |
| `image-inventory.txt` | Exact Compose image names, immutable local image IDs, repository-digest provenance, and required OSCAR/PostGIS release labels used to create the recovery point |
| `SHA256SUMS` | SHA-256 of every backup payload file present before verification (excludes itself, its authentication tag, and the later `VERIFIED` marker) |
| `SHA256SUMS.hmac` | HMAC-SHA-256 authentication of `SHA256SUMS`, using the external backup key; this authenticates the complete checksum inventory and every payload it names |
| `VERIFIED` | Atomically replaced UTC marker written only after quiesced live archive/catalog reconciliation, authenticated checksums, `pg_verifybackup`, strict archive-member validation, and epoch validation establish a valid recovery point |

When PostgreSQL is available, its live catalog also receives an `oscar_backup_epoch` receipt after
the backup directory is finalized. It records the backup manifest path, epoch checksum, LSN, and the
set of archive generations that were active or sealed at that time. This receipt is deliberately
best-effort: backup verification and disaster recovery remain possible with the database offline.

### Items to protect separately

The backup is intentionally not self-decrypting. Protect these outside its failure domain:

- `${OSCAR_BACKUP_KEY_FILE}` (default `secrets/backup-key.txt`), needed to decrypt deployment
  credentials;
- the exact OSCAR release artifact, any independently retained publisher signature or provenance
  attestation required by site policy, and all three container images recorded by
  `image-inventory.txt`; an offline bundle's co-packaged unsigned `SHA256SUMS` verifies integrity
  relative to that manifest but does not authenticate release origin, and restore deliberately
  rejects a tag that was rebuilt or retagged to a different content-addressed image ID even when its
  visible name and version label match;
- host DNS/hosts-file configuration and workstation trust installation;
- Docker/Desktop/Engine configuration and any host-level firewall policy; and
- portable exports or other data stored outside the configured OSCAR state/archive paths.

Losing the backup key makes the encrypted `.env`, application/database passwords, and TLS private
key unrecoverable. Storing the key beside the only backup defeats the separation. Use a managed
secret system, offline escrow, or two independently controlled encrypted copies.

## Recovery objectives and consistency

The backup command briefly stops the HTTPS gateway and OSCAR application, leaving PostgreSQL online
for `pg_basebackup`. It captures the current LSN, switches WAL, and takes the self-contained database
base backup. PostgreSQL is then stopped while the command rejects partial WAL and snapshots the
now-stable WAL archive alongside application state and the cold archive. PostgreSQL resumes before
the best-effort catalog receipt and structural verification; the gateway and application remain
stopped through acceptance. After atomically accepting the recovery point with `VERIFIED`, it
records backup protection only for immutable
daily-file lane/days whose CSV, manifest, and exact sealed-segment inventory are present in the
authenticated snapshot. Services that were running are restarted only after that gate succeeds.
This creates a coordinated application quiescence point without an unsafe copy of a live PostgreSQL
data directory.

Every live or mutating storage-administration invocation takes one nonblocking deployment-wide
lock. A second backup, prune, restore, archive purge/verification, hold change, or export fails
clearly instead of racing the first operation. Read-only `backup-verify` is deliberately able to
run against a selected recovery point while the deployment is offline and is the sole exemption.
Ubuntu uses a crash-released kernel `flock`; Windows holds a `FileStream` with
`FileShare.None` for the process lifetime. The lock is keyed by `OSCAR_DEPLOYMENT_ID` in an administrator-owned location outside a versioned release:
`/run/lock/oscar-storage` on Ubuntu and `%ProgramData%\OSCAR\StorageLocks` on Windows. Never relocate it into an extracted release tree or
bypass a busy lock.

The outage duration depends mostly on application-state and archive size. Measure it at production
scale. The automated restore returns PostgreSQL to the consistent endpoint included by
`pg_basebackup` and restores the matching captured files/configuration.

Compose also enables PostgreSQL data checksums for **new** clusters, continuous WAL archiving, a
five-minute `archive_timeout`, and WAL compression. WAL publication byte-compares an existing name,
uses a flushed temporary inode plus atomic no-replace hard-link publication, fsyncs the published
file and directory, and fails hard on any mismatch. A quiesced backup rejects every WAL helper
`.partial` artifact rather than omitting it. Archived WAL supports a database specialist's
point-in-time recovery strategy, but the 3.9.2 launcher does not accept a recovery timestamp or
automatically configure PostgreSQL `restore_command`/`recovery.signal`. Do not claim arbitrary PITR
has been tested merely because WAL files exist. Validate the site-specific PITR procedure on an
isolated copy if recovery between coordinated backup endpoints is required.

Verification requires exactly one authenticated checksum entry for every top-level recovery
payload, including `epoch.json` and `image-inventory.txt`. The epoch must identify exactly OSCAR
3.9.2, not merely any semantic version. Before destructive restore, OSCAR also compares the current
application, PostgreSQL, and gateway image names, immutable IDs, and required release labels with
the authenticated inventory. Exact names, content-addressed IDs, and required labels are hard
gates. Repository digests are recorded as registry provenance, but a difference is only warned
because `docker save`/`docker load` may discard that transport metadata while preserving the exact
image ID and contents. Keep the original offline bundle or exported image archive with the backup
so those exact images can be reloaded after a host loss.

## Before the first backup

Initialization/upgrade creates the backup encryption key and prepares the three configured host
roots. Archive and WAL are long-lived service binds; the administrator-owned backup root is not
mounted into a long-running service. Confirm all services are healthy and that the paths point to
durable storage:

```sh
sudo bash oscar.sh status
grep -E '^(OSCAR_ARCHIVE_DIR|OSCAR_WAL_ARCHIVE_DIR|OSCAR_BACKUP_DIR|OSCAR_BACKUP_KEY_FILE)=' .env
```

Windows:

```powershell
.\oscar.bat status
Get-Content .env | Select-String '^OSCAR_(ARCHIVE|WAL_ARCHIVE|BACKUP|BACKUP_KEY_FILE)'
```

The Ubuntu storage commands require root; Windows storage commands require Administrator Windows
PowerShell 5.1 (`powershell.exe`) or the elevated OSCAR menu. Ensure the backup filesystem has room for the PostgreSQL
base backup, application state, cold archive, and WAL snapshot at the same time. A backup on the
same physical disk protects against logical/operator failure, not loss of that disk.

Each archive, WAL, and backup root contains an administrator-owned, no-follow
`.oscar-storage-root` identity. Its exact version-1 fields bind the root kind and
`OSCAR_DEPLOYMENT_ID` and record whether setup created the root or explicitly adopted existing
data. On Ubuntu the archive and WAL root directories are root-owned, use their service group (10001
or 999), and mode `1770`; the sticky bit prevents the service from unlinking the root-owned marker.
The backup root is root-owned mode `0700`. Windows rejects reparse points and protects the marker
with non-inherited administrator/SYSTEM/Administrators ACLs. Every live database/archive command
and backup prune validates all three identities and both deployment-owned Docker volumes first.
Only `backup-verify` is exempt because it is an intentionally offline, read-only operation against
the selected backup directory.

Neither long-running service mounts the backup root. During creation, a network-scoped one-shot
PostgreSQL client receives only the newly created `postgres/` staging directory, and every other
utility receives only the exact input or output it needs. This matters on Docker Desktop, where a
container mount must not rely on a Linux numeric UID to protect unrelated recovery points.

## Create a backup

Ubuntu:

```sh
sudo bash oscar.sh backup
```

Windows:

```powershell
.\oscar.bat backup
```

The command prints the final path and backup ID. A working directory ending in `.partial` is not a
complete backup. A finalized directory without `VERIFIED` also failed acceptance. Do not rename or
mark either one into service; preserve the error, correct the cause, and run `backup-verify` or a new
backup as appropriate.

Before publication, the launcher flushes every staged payload and directory, then invokes the
image's compiled `renameat2(RENAME_NOREPLACE)` publisher against two names in the same parent.
Publication therefore cannot replace a pre-existing backup ID, even across a race. The image also
contains a root-owned SHA-256 stamp of the packaged C source; release regression compares that
provenance and behavior-tests successful publication plus collision preservation.

Expected stages are:

1. gateway/OSCAR quiesce if they were running;
2. active archive-object checksum verification and catalog/filesystem reconciliation while writers
   remain quiesced;
3. PostgreSQL LSN and WAL switch;
4. streamed `pg_basebackup`;
5. PostgreSQL stop followed by application-state, archive, and stable WAL snapshots;
6. encrypted configuration/secrets and release metadata;
7. checksum generation, HMAC authentication, private-permission enforcement, and atomic directory
   finalization;
8. PostgreSQL resume, best-effort backup-epoch catalog insertion, and full structural verification;
9. atomic `VERIFIED` acceptance, then offline confirmation of only the published journal lane/days
   and exact sealed segments captured by this accepted authenticated snapshot; and
10. service resume and health wait.

With the default `OSCAR_BACKUP_AUTO_PRUNE=true`, successful verification of this newly created backup then retains the newest
`OSCAR_BACKUP_RETENTION_COUNT=14` verified local backups and prunes archived WAL older than the
starting WAL of the oldest retained one. Unverified and `.partial` directories are never counted as
safe recovery points and are not automatically removed.

The cleanup trap attempts to resume services if a stage fails. Always run `status` after a failed
backup and inspect both OSCAR and PostgreSQL logs. If structural verification succeeds but the
journal-confirmation bridge fails, the backup remains a legitimate `VERIFIED` recovery point; the
command still fails, services are resumed, automatic backup/WAL pruning is skipped, and no
unconfirmed lane/day becomes segment-deletion eligible. Correct the journal inconsistency or let a
later successful backup establish the missing protection rather than fabricating a receipt.

## Verify or re-verify a backup

`backup` performs this verification automatically. Use `backup-verify` to re-check a backup before
copy, restore, audit, or after moving it back into the configured backup directory. Supply the ID
printed by `backup`.

Ubuntu:

```sh
sudo bash oscar.sh backup-verify 20261017T153000Z-1a2b3c4d
```

Windows:

```powershell
.\oscar.bat backup-verify -BackupId 20261017T153000Z-1a2b3c4d
```

Verification:

- requires and authenticates `SHA256SUMS.hmac` before trusting checksum file names or digests;
  checksum-only legacy directories are rejected and never receive a `VERIFIED` marker or count
  toward retention;
- checks every `SHA256SUMS` entry;
- starts a one-shot, dependency-free PostgreSQL utility container and runs `pg_verifybackup`
  against the base backup; no live database container is required;
- decrypts the secret/configuration archive into a disposable utility-container path;
- validates every tar payload without extracting it into the deployment: member names cannot be
  absolute, contain `..`, use backslash traversal, contain control characters, alias another path,
  repeat a name, or create file/directory prefix collisions, and only regular files/directories are
  allowed (links, devices, FIFOs, sockets, and unknown types are rejected);
- requires the exact top-level payload inventory and exactly one copy of every mandatory
  release-config file;
- validates the epoch UUID, format/version, immutable `CREATED` state, and exact backup-directory ID; and
- durably writes and fsyncs a UTC `VERIFIED` marker without requiring or updating a live database.

Manual `backup-verify` and the verification performed before `restore` deliberately do **not** add
new live daily-journal backup confirmations or run retention. This prevents inspection or
restoration of an older recovery point from mutating current journal eligibility or deleting that
target. Only creation of a new backup runs the confirmation bridge and automatic pruning; use
`backup-prune` for an explicit reviewed retention pass. Re-verification proves the authenticated
snapshot has not changed; the quiesced archive/catalog reconciliation is a mandatory invariant of
creating that authenticated 3.9.2 snapshot, not a comparison against the current live deployment.

For a newly created 3.9.2 backup, successful verification proves authenticated structural integrity
at that time and confirms the locally configured OSCAR/PostgreSQL utility images can read it. A
directory without `SHA256SUMS.hmac` is rejected rather than promoted into the verified retention
set. Verification does not prove that an operator can recover the separately escrowed key after an incident, that
every Compose service image remains available, or that application workflows pass after restore.
Only a restore drill proves those dependencies.

After verification, copy the complete backup directory to at least one encrypted medium or system
outside the OSCAR host and verify the checksums again at the destination. Restrict the copy because
it contains operational records and encrypted—not anonymized—credentials.

## Restore a coordinated backup

Restore is destructive to the current PostgreSQL cluster, OSCAR state, cold archive, WAL archive,
and active deployment credentials. The configured backup root remains the read-only recovery source
and is not replaced. Before stopping or replacing anything,
the command requires the same valid backup ID twice, authenticates/verifies the backup, validates the
release-configuration archive, and proves that the current `.env`, backup epoch, and backed-up
`.env.example` all identify exactly OSCAR 3.9.2. It also requires every exact image resolved by the
current Compose configuration to exist locally; restore never substitutes or pulls a different tag.

A restore attempt does not change the recovery point's lifecycle state. An accepted recovery point
remains `VERIFIED` after either a successful or failed restore attempt; command output and site
recovery records document the attempt rather than inventing a second backup-state transition.

Before restoring:

1. Confirm the exact target host and backup ID.
2. Preserve any incident evidence or newer data needed for investigation.
3. Make the required `oscar:<version>` and PostGIS images available without changing their content.
4. Confirm the external backup key is present and readable only by the administrator.
5. Stop external RPM/camera/emulator producers or otherwise prevent duplicate replay during the
   recovery window.

Ubuntu:

```sh
sudo bash oscar.sh restore \
  --backup 20261017T153000Z-1a2b3c4d \
  --confirm 20261017T153000Z-1a2b3c4d
```

Windows:

```powershell
.\oscar.bat restore `
  -BackupId 20261017T153000Z-1a2b3c4d `
  -Confirm 20261017T153000Z-1a2b3c4d
```

The restore workflow:

1. verifies the backup again;
2. validates exact 3.9.2 release identity and local image availability again after verification;
3. decrypts the backed-up `.env`, `secrets/`, and `tls/` into a private staging directory, merges
   the target-local environment bindings, and validates the entire staged replacement set;
4. copies the current `.env`, `secrets/`, and `tls/` into
   `pre-restore-<backup-id>` under the release directory;
5. stops gateway, OSCAR, and PostgreSQL;
6. replaces the named PostgreSQL volume contents with the base backup;
7. replaces OSCAR application state and the configured archive tree;
8. replaces the WAL archive snapshot;
9. preserves and revalidates the target host's archive/WAL root identities rather than extracting,
   trusting, or chowning a marker from the source backup;
10. installs the already validated credential set from same-filesystem staging; and
11. starts the complete Compose deployment and waits for health.

Decryption, environment merge, and credential-tree validation all finish before the safety copy is
created, services are stopped, or database/archive/WAL data is changed. A malformed encrypted set,
unsupported file type, link, or unsafe target environment therefore aborts without entering the
destructive phase.

### Same-host and cross-host environment policy

A restore recovers source data and credentials, but it does not turn the target host into the source
host. Before installing the decrypted files, the command takes the following bindings from the
target's current `.env` and writes them into the restored `.env`:

- `OSCAR_DEPLOYMENT_ID`;
- `OSCAR_POSTGIS_PLATFORM`, `OSCAR_HTTPS_PORT`, and `OSCAR_HOSTNAME`;
- the canonical credential bindings described below; and
- `OSCAR_ARCHIVE_DIR`, `OSCAR_WAL_ARCHIVE_DIR`, and `OSCAR_BACKUP_DIR`.

The three storage roots must already be absolute target paths. Every listed binding must occur
exactly once and be non-empty, and the target deployment ID must be valid. Restore fails before
changing the live credential set if those conditions are not met. Other backed-up settings, such as
backup-retention policy and JVM tuning, travel with the source environment. The release version is
already required to match exactly.

This release intentionally supports only these credential locations:

```dotenv
OSCAR_SECRETS_DIR=./secrets
OSCAR_TLS_DIR=./tls
OSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt
```

Setup/upgrade, backup, and restore fail closed if the target `.env` uses any other values. The
encrypted backup, pre-restore safety copy, and installer all operate on these release-relative
directories; custom credential paths are not claimed to work. A backed-up source `.env` may contain
different values from an older deployment, but restore replaces them with the target's validated
canonical bindings before accepting the staged set.

This merge keeps named-volume ownership labels aligned with `OSCAR_DEPLOYMENT_ID`, keeps Compose
bound to the target archive and WAL directories, and retains the target's external backup root.
Restore checks volume ownership again
after installing the merged environment and before starting services. On a same-host restore, the
source and target local bindings are normally identical, so behavior is unchanged. On a cross-host
restore, review endpoint and TLS acceptance carefully: source TLS and application credentials are
restored, while the target hostname and port remain authoritative.

The `pre-restore-*` directory is a safety copy of credentials, not a data rollback. It contains
sensitive plaintext files; protect it and remove it under the site's credential-retention policy
after the recovery is accepted. A retry refuses to overwrite an existing safety directory for the
same backup ID; preserve or move that directory deliberately before retrying.

On Ubuntu, backup directories are finalized as root-owned `0700` directories with `0600` payloads
under a `umask 077`. On Windows, inheritance is removed and access is limited to the invoking
administrator, SYSTEM, and the local Administrators group. Preserve equivalent controls on copied
backup media.

## Post-restore acceptance

Do not reconnect producers until the restored system passes all relevant checks:

```sh
sudo bash oscar.sh status
sudo bash oscar.sh archive status
sudo bash oscar.sh archive verify
```

Also verify:

- login and role enforcement over HTTPS;
- the target hostname/port and the certificate presented for that endpoint;
- `OSCAR_DEPLOYMENT_ID` still matches both named-volume labels;
- archive, WAL, backup, secret, TLS, and backup-key bindings still name the intended target paths;
- SensorHub module/driver status and the expected lane inventory;
- a recent event lookup by UUID and Event Details rendering;
- a legacy source video and an exact-five retained JPEG set, where present;
- daily-file journal startup with no CRC or immutable-publication mismatch;
- one representative query that spans hot and cold observations;
- reports and adjudication artifacts;
- backup epoch/manifest identity and the expected restore endpoint; and
- database/application logs for checksum, WAL, archive, permission, or missing-object errors.

Run the full emulator-backed OSCAR regression suite before declaring a production recovery
successful. Record the backup ID, recovery start/end times, accepted data endpoint, checks performed,
and approver.

## Point-in-time recovery with archived WAL

The release stores WAL segment copies in `${OSCAR_WAL_ARCHIVE_DIR}` and includes a snapshot in each
coordinated backup. For recovery to a timestamp or LSN after a base backup, PostgreSQL must be
started from a verified base backup with an appropriate `restore_command`, `recovery.signal`, and
optional `recovery_target_time` or `recovery_target_lsn`.

That is a PostgreSQL recovery operation, not the normal OSCAR `restore` command. Perform it only by
a database administrator in an isolated recovery deployment. The administrator must:

1. preserve the original incident system;
2. verify the base backup and every required WAL segment;
3. use the PostgreSQL major version shipped by that OSCAR release;
4. keep the archive and OSCAR state from the coordinated epoch available;
5. select a target that does not split an externally coordinated application operation; and
6. run the full post-restore acceptance suite before cutover.

If a required WAL segment is missing, stop. Do not skip it and present the resulting database as a
complete point-in-time recovery.

## Backup retention, off-site copies, and WAL pruning

The standard `.env` enables count-based pruning after every successful backup verification:

```dotenv
OSCAR_BACKUP_RETENTION_COUNT=14
OSCAR_BACKUP_AUTO_PRUNE=true
```

The retention pass considers only complete directories with a valid backup ID and `VERIFIED`
marker. Before deleting anything, it HMAC-authenticates and fully re-runs the offline verifier for
every candidate in the retention decision. Any corruption aborts with no deletion. It keeps the
newest configured number of usable recovery points, requires exactly one authenticated
`postgres/backup_label` checksum entry in the oldest retained backup, verifies that file again, and
derives the start-WAL boundary from it. The exact backup/WAL deletion set is written and fsynced as
an HMAC-authenticated, deployment-bound prune intent. Selected backups are renamed to
`.deleting-*` before removal; a retry resumes only that authenticated set after revalidating every
still-complete candidate and the retained boundary. WAL is touched only after the oldest retained
backup passes another full verification. Only regular 24-character WAL segment files older than
that boundary are removed. Unverified/partial/unknown backups, unknown WAL names, and WAL at or
after the boundary are never deleted.

Run the same procedure explicitly after a policy change:

```sh
sudo bash oscar.sh backup-prune --keep 14
```

```powershell
.\oscar.bat backup-prune -Keep 14
```

`--keep`/`-Keep` must be between 1 and 10,000. To suspend automatic deletion while investigating or
changing policy, set `OSCAR_BACKUP_AUTO_PRUNE=false`; continue monitoring capacity and run an
explicit reviewed prune later.

Define a policy that retains enough **verified, off-host** coordinated backups to meet recovery
objectives. The local count is not an off-site policy. If an off-site base backup is expected to
support PITR later than the WAL snapshot inside its own backup, copy the continuing WAL stream to
that off-site recovery domain before local pruning can remove it. Do not prune WAL by modification
date or with generic filesystem lifecycle rules.

At minimum:

- create (and therefore automatically verify) a coordinated backup on a documented schedule and
  before upgrades/policy changes;
- alert on backup, WAL, archive, OSCAR-state, and PostgreSQL-volume capacity separately;
- copy verified backups and the external key into independent failure domains;
- perform a full isolated restore at least quarterly and after a storage-format or PostgreSQL major
  change; and
- document who can authorize retention reduction and backup destruction.

Deleting the oldest cold archive from the live system does not delete it from existing backups or
portable exports. Include those copies in privacy requests and records-destruction audits.

## Disaster-recovery boundary

Within its configured paths, OSCAR is fully backupable: database, OSH/app state, daily journal and
files, media, reports, cold archive, WAL snapshot, configuration, credentials, and TLS material are
included. Recovery still depends on external infrastructure and operational evidence. Preserve the
release artifact/images, encryption key, host build documentation, DNS/certificate trust plan, and
restore-test records alongside—but not all in the same failure domain as—the coordinated backup.
