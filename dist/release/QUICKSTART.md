# OSCAR Quick Start

OSCAR 3.9.2 deployment and storage operation are supported only on Windows 11 x86-64 with Docker
Desktop/WSL 2 and Ubuntu Server 24.04 x86-64 with Docker Engine/Compose. macOS is limited to source
inspection and non-deployment development; initialization, start, restart, upgrade, and storage
operations fail closed there.

## Windows 11

1. Choose `offline-full` when Docker Desktop or WSL may need installation. Choose `offline-images` when compatible Docker Desktop, WSL 2, and Docker Compose are already installed and running.
2. Extract the OSCAR ZIP to a local NTFS directory.
3. Double-click `oscar.bat`, approve the Windows administrator prompt, and enter `init` at the `oscar>` prompt. The launcher uses Windows PowerShell 5.1 (`powershell.exe`).
4. Alternatively, for scripted or terminal-based setup, run:

```powershell
.\oscar.bat init
```

5. Enter the deployment hostname and an OSCAR administrator password of at least 14 characters.
   New self-signed installations automatically include the host's active, non-container LAN IPv4
   and Tailscale IPv4/IPv6 addresses in the certificate. If clients will use a stable site-DNS or Tailscale
   MagicDNS name other than the primary hostname, add it with `--tls-san` on Ubuntu or `-TlsSan`
   on Windows during initialization.
6. Open the URL printed by setup, normally `https://oscar.local/sensorhub/admin`.

Setup creates deployment-specific database credentials and a separate backup-encryption key,
persists absolute archive/WAL/backup paths under the sibling `oscar-storage` directory, prepares
those directories, writes administrator-protected `.oscar-storage-root` identities bound to the
deployment UUID and root kind, configures TLS, and starts OSCAR automatically. Keeping storage outside the
versioned release lets a clean-release upgrade reuse the same data when `.env` is copied. Do not
run a separate launch script after initialization. Protect `secrets/backup-key.txt` separately from
the backup media; it is required to restore the encrypted deployment credentials.

For offline media, verify it before initialization:

```powershell
.\verify-bundle.ps1
.\oscar.bat init
```

`init` and `upgrade` re-hash the exact bundle inventory on every mutating run before using any
payload; a prior receipt is audit evidence, not a cache that can authorize changed bytes. They also
load the checksum-verified image archive even if same-version tags already exist locally. This
integrity check proves agreement with the co-packaged `SHA256SUMS`, not publisher or release-origin
authenticity, because that manifest is bundled and unsigned. If origin authentication is required,
verify the outer ZIP against an independently trusted detached signature or provenance attestation
before offline transfer. You can run `oscar.bat verify` explicitly at any time. For the images-only
artifact, use `oscar.bat init -Prerequisites existing` to guarantee setup will not launch prerequisite
installers.

If a prerequisite installer requires a Windows restart, restart and run `oscar.bat init` again.
Docker Desktop license review and acceptance are administrator actions; OSCAR never accepts that
agreement on the organization's behalf.

## Ubuntu Server 24.04

Official offline bundles are Windows-only. Install Docker Engine and the Docker Compose plugin,
extract the connected Ubuntu release, and run:

```sh
sudo bash oscar.sh init
```

On a graphical Ubuntu installation, double-click the executable `oscar.sh` launcher to open the same interactive menu. Ubuntu Server administrators use the command above because the server has no desktop environment.

## Routine administration

Double-click/open `oscar.bat` or `oscar.sh` with no arguments to keep an administration window open. Enter commands such as `status`, `start`, `stop`, `restart`, `logs -Service oscar` (Windows), or `logs --service oscar` (Ubuntu). Enter `exit` to close it. Passing arguments directly continues to work for scripts and experienced administrators:

Windows:

```powershell
.\oscar.bat status
.\oscar.bat start
.\oscar.bat stop
.\oscar.bat restart
.\oscar.bat logs -Service oscar
```

Ubuntu:

```sh
sudo bash oscar.sh status
sudo bash oscar.sh start
sudo bash oscar.sh stop
sudo bash oscar.sh restart
sudo bash oscar.sh logs --service oscar
```

The launcher deliberately stops services in dependency order: gateway, OSCAR, then PostgreSQL.
This lets OSCAR finish its bounded journal and database-backed module shutdown before the database
is stopped. Do not replace the launcher command with a multi-service `docker compose restart`.

Create and verify a coordinated backup before an upgrade or retention change:

Windows:

```powershell
.\oscar.bat backup
.\oscar.bat backup-verify -BackupId <ID-printed-by-backup>
.\oscar.bat archive status
.\oscar.bat archive verify
```

Ubuntu:

```sh
sudo bash oscar.sh backup
sudo bash oscar.sh backup-verify <ID-printed-by-backup>
sudo bash oscar.sh archive status
sudo bash oscar.sh archive verify
```

Retention-hold creation prints and persists a resolution label. `GENERATION_EXACT` and `HOT_EXACT`
are exact catalog/row matches; `COLD_RANGE_CONSERVATIVE` protects candidate archive ranges but does
not prove that a possibly sparse observation ID exists. Confirm the event or hold its exact
generation when evidentiary certainty is required. A listed `LEGACY_UNKNOWN` mode is a protective
migration-only label for a pre-3.9.2 observation hold; it does not prove exact observation
existence. Active observation or generation holds also
block Viewer/API datastore removals: a single remove fails visibly and a bulk remove skips held
rows. See `documentation/STORAGE_OPERATIONS.md` before creating or releasing a hold.

`backup` keeps OSCAR quiesced, proves that every query-visible generation has exactly one active
Parquet, manifest, and schema object, verifies each against its catalog checksum,
requires the Parquet object path/checksum and manifest path to match the generation's authoritative
pointers, and rejects a catalog snapshot changed by concurrent activation or purge,
reconciles the archive filesystem, then verifies and HMAC-authenticates the new backup, rejects
unsafe tar members, atomically marks the recovery point `VERIFIED`, and then records protection for
only the exact published daily-file segments present in that accepted snapshot. A confirmation
failure leaves the recovery point verified but fails the command and skips automatic pruning.
PostgreSQL stays online for the streamed base backup, stops for the stable archived-WAL snapshot,
and resumes before receipt/verification while OSCAR remains stopped. The explicit
`backup-verify` command can run with PostgreSQL stopped: it uses a one-shot utility container and
treats the live catalog receipt as optional. Restore additionally requires matching 3.9.2 backup,
current-release, and backed-up release-config identities plus every exact local Compose image.
Use `backup-verify` before an audit, copy, or restore. By default OSCAR keeps the newest 14 verified
local backups and prunes older verified backups plus WAL older than the oldest retained base-backup
boundary after a new backup is created and verified. Before any deletion it HMAC-authenticates and
fully re-verifies every recovery point in the decision, authenticates the oldest retained
`backup_label`, and durably records a resumable deployment-bound intent; any corruption means
nothing is deleted. Manual verification and restore do not prune. Review
`OSCAR_BACKUP_RETENTION_COUNT` and
`OSCAR_BACKUP_AUTO_PRUNE` in `.env` before production use.

Storage commands are mutually exclusive per deployment. A concurrent backup, verify, prune,
restore, archive mutation, verification, or export fails immediately with a clear lock message;
wait for the active command rather than bypassing its crash-released, deployment-ID-keyed lock in
the host's administrator-owned runtime/program-data directory. Live commands also reject missing,
foreign, swapped, or unsafe archive/WAL/backup identities and mismatched Docker volumes. The sole
exception is offline-capable `backup-verify`, which does not depend on a running deployment or its
live roots. It is an acceptance operation, not a read-only command: it atomically publishes or
replaces the selected backup's `VERIFIED` marker and normalizes permissions. An optional live
catalog update occurs only after deployment-volume ownership is proven.

OSCAR 3.9.2's full storage profile is initialized with a new database and standard configuration.
An upgrade preserves the old `config.json` and PostgreSQL volume, so it does not silently convert a
pre-3.9.2 system to the tiered archive or enable PostgreSQL data checksums. Use a fresh deployment
for the 3.9.2 test systems. Preserve and separately migrate any production history that policy
requires.

If a deliberately retained pre-label deployment uses unlabelled Docker volumes, follow the
one-time `-AdoptLegacyVolumes` (Windows) or `--adopt-legacy-volumes` (Ubuntu) procedure in the
Administrator Guide. Preserve its `.oscar-volume-adoption` receipt with `.env`, `secrets`, and
`tls` during later clean-directory upgrades; never use adoption to join unrelated volumes. Run
upgrades through `oscar.bat` or `oscar.sh`, not a direct `docker compose up`: setup validates the
exact external named volumes before Compose attaches them and force-recreates every service so no
container retains a secret/config bind or Compose provenance from the prior extracted release.
Delete the prior extracted release only after health and container-mount verification, and never
delete a persistent archive, WAL, or backup root preserved by `.env`.
If verified pre-3.9.2 archive/WAL/backup roots are nonempty and have no root marker, the upgrade
also requires the separate one-time `-AdoptLegacyStorageRoots` (Windows) or
`--adopt-legacy-storage-roots` (Ubuntu) switch. It records audited adoption metadata in each
root; it must never be used to claim foreign data or silence a mismatched existing marker.

The default deployment uses HTTPS port `443`. Setup maps `oscar.local` on the OSCAR host and prints
all LAN/Tailscale URLs covered by a newly generated certificate. Other connecting workstations must
either use one of the printed IP URLs or resolve a printed hostname through DNS/their own hosts
entry. Every workstation must trust the public `tls/server.crt` certificate before login; never
copy `tls/server.key` to a client. See [DEPLOYMENT.md](DEPLOYMENT.md) for certificate trust, DNS,
Tailscale, scoped host-firewall access, log filtering, security verification, and upgrades.
Entering the hostname without `https://` is supported on the default port; the gateway redirects port 80 to HTTPS.

The release's `documentation` directory contains the current deployment guide, operational-view and
Status of Health guides, storage architecture/data-lifecycle/archive/backup/operations guides, and
all four localized operator manuals. Read `documentation/STORAGE_OPERATIONS.md` before enabling hot
deletion or removing old cold generations. Official GitHub release artifacts also include the
generated, version-labeled PDF manuals.
