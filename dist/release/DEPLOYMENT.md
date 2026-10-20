# OSCAR Administrator Guide

OSCAR runs as three Docker Compose services: an HTTPS gateway, the non-root OSCAR application, and PostgreSQL/PostGIS. The selected HTTPS port is published to the host, and port 80 redirects requests to HTTPS. PostgreSQL has no host port.

Start with [QUICKSTART.md](QUICKSTART.md) for installation. This guide documents deployment choices and routine administration.

## Supported deployment and operation hosts

- Windows 11 x86-64 with Docker Desktop and WSL 2
- Ubuntu Server 24.04 x86-64 with Docker Engine and the Compose plugin

The 3.9.2 storage profile fails closed on macOS because Docker Desktop for Mac cannot satisfy this
release's tested bind-root ownership and recovery-media isolation contract. Use Ubuntu or Windows
for initialization and operation; a Mac may still be used for source inspection or non-deployment
development.

## Administrative CLI

Use `oscar.bat` on Windows and `oscar.sh` on Ubuntu. The Windows launcher invokes Windows
PowerShell 5.1 (`powershell.exe`); PowerShell 7 is not required.

Opening either launcher with no arguments starts a persistent `oscar>` administration menu. On Windows, double-clicking `oscar.bat` requests UAC elevation automatically; an Administrator Windows PowerShell 5.1 window does not need to be opened first. On graphical Ubuntu, opening the executable `oscar.sh` starts the menu in a terminal. Desktop file-execution policy varies, so direct terminal commands remain the supported fallback. Ubuntu Server has no graphical launcher and is administered from its terminal.

The menu accepts the same command and options shown below. For example, enter `init`, `status`, `logs -Service postgres -Follow` on Windows, or `logs --service postgres --follow` on Ubuntu. Enter `exit` to close the menu. Supplying arguments directly bypasses the menu, preserving automation compatibility.

| Action | Windows | Ubuntu |
| --- | --- | --- |
| Initialize | `oscar.bat init` | `sudo bash oscar.sh init` |
| Check prerequisites | `oscar.bat check` | `sudo bash oscar.sh check` |
| Verify offline media | `oscar.bat verify` | Site-prepared bundles only: `sudo bash oscar.sh verify` |
| Start | `oscar.bat start` | `sudo bash oscar.sh start` |
| Stop | `oscar.bat stop` | `sudo bash oscar.sh stop` |
| Restart | `oscar.bat restart` | `sudo bash oscar.sh restart` |
| Status | `oscar.bat status` | `sudo bash oscar.sh status` |
| Logs | `oscar.bat logs` | `sudo bash oscar.sh logs` |
| Upgrade | `oscar.bat upgrade` | `sudo bash oscar.sh upgrade` |
| Coordinated backup | `oscar.bat backup` | `sudo bash oscar.sh backup` |
| Verify backup | `oscar.bat backup-verify -BackupId ID` | `sudo bash oscar.sh backup-verify ID` |
| Prune verified backups/WAL | `oscar.bat backup-prune -Keep 14` | `sudo bash oscar.sh backup-prune --keep 14` |
| Archive status | `oscar.bat archive status` | `sudo bash oscar.sh archive status` |
| Archive integrity | `oscar.bat archive verify` | `sudo bash oscar.sh archive verify` |
| Retention holds | `oscar.bat archive hold list` | `sudo bash oscar.sh archive hold list` |

Directly invoked mutating commands require an elevated Windows PowerShell 5.1 window on Windows or root privileges on Ubuntu. The Windows menu obtains elevation through UAC, and the Ubuntu menu invokes `sudo` when a selected command requires it.

`start`, `stop`, and `restart` never build or download images. `init` and `upgrade` may prepare missing images for a connected release. After building the local OSCAR/PostGIS images, setup rechecks the complete inventory and pulls the gateway only if it is still absent; an already-cached pinned gateway therefore does not create an unnecessary registry or credential-helper dependency. If `offline-images.tar` is present, every mutating setup run re-verifies the exact bundle inventory against the co-packaged `SHA256SUMS` and loads that checksum-verified archive even when same-version tags already exist locally. It never substitutes a stale local image for the selected bundle and fails if any required image remains unavailable afterward. Because the manifest is bundled and unsigned, this is an integrity check, not publisher or release-origin authentication. Sites that require origin authentication must verify the outer ZIP against an independently trusted detached signature or provenance attestation before offline transfer.

On Windows, connected setup builds the two release-local images with explicit
`docker build` contexts after validating the deployment paths. This avoids the
Docker Compose 5.6/Buildx 0.37 filesystem-entitlement regression that can
misclassify an in-tree Dockerfile and request an unavailable `fs.read` approval.
OSCAR does not disable Bake filesystem checks globally or grant wildcard host
filesystem access; the image tags, release version argument, and PostgreSQL
platform remain identical to `compose.yaml`.

Use the launchers for a complete stop or restart rather than issuing an unscoped multi-service
`docker compose stop` or `docker compose restart`. The supported launchers stop the gateway first,
wait for OSCAR to finish its bounded journal/module shutdown while PostgreSQL remains available,
and stop PostgreSQL last. Restore uses the same dependency-safe order before replacing state.

Offline releases are published in two Windows x86-64 profiles:

- `offline-full` contains OSCAR images plus the approved Docker Desktop and WSL installers.
- `offline-images` contains OSCAR images only and requires Docker Desktop, WSL 2, and Docker Compose to be installed and running already.

Initialization defaults to `-Prerequisites auto`, which uses a working existing Docker installation and only launches bundled installers when Docker is unavailable. Use `-Prerequisites existing` to prohibit prerequisite installation, or `-Prerequisites bundled` to explicitly permit the bundled fallback. Official offline release media and bundled prerequisites are Windows-only. Supported Ubuntu deployments use a connected release with Docker Engine/Compose already installed; Bash `--prerequisites bundled` support is only for a separately qualified, site-prepared `.deb` set and is not built, validated, or published by the release workflow.

## Initial setup options

The defaults are hostname `oscar.local`, HTTPS port `443`, and a self-signed certificate. Setup asks for an administrator password of at least 14 characters, generates unique database credentials, validates TLS, and starts the deployment. For a new self-signed installation, setup automatically adds active non-container LAN IPv4 addresses, active Tailscale IPv4/IPv6 addresses, and the connected Tailscale MagicDNS name (when discoverable) to the certificate. It prints every covered client URL when initialization completes. Ordinary SLAAC privacy IPv6 addresses are intentionally excluded because they rotate before the certificate expires; add a site-stable IPv6 address explicitly when required.

With the default HTTPS port, entering the configured hostname without a scheme is supported: the gateway redirects the browser from HTTP to HTTPS while preserving the requested path. Deployments using a nonstandard HTTPS port must include that port in the URL printed by setup.

Windows example with an imported certificate:

```powershell
.\oscar.bat init -Hostname oscar.example.org -Port 443 `
    -TlsMode import -CertificatePath C:\certs\server.crt `
    -PrivateKeyPath C:\certs\server.key
```

Windows self-signed LAN/Tailscale example with additional stable names:

```powershell
.\oscar.bat init -Hostname oscar-site.example.org -Port 443 `
    -TlsSan 192.168.0.61,oscar-site.example-tailnet.ts.net
```

Ubuntu equivalent:

```sh
sudo bash oscar.sh init --hostname oscar.example.org --port 443 \
    --tls-mode import --certificate /secure/server.crt \
    --private-key /secure/server.key
```

Ubuntu self-signed LAN/Tailscale example with additional stable names:

```sh
sudo bash oscar.sh init --hostname oscar-site.example.org --port 443 \
    --tls-san 192.168.0.57 \
    --tls-san oscar-site.example-tailnet.ts.net
```

`--tls-san` is repeatable on Ubuntu. `-TlsSan` accepts a comma-separated list on Windows. Automatic
network SAN discovery is enabled only for newly generated self-signed certificates. Use
`--no-auto-network-sans` or `-NoAutoNetworkSans` when a deliberately hostname-only certificate is
required. Container bridge, Docker, WSL, loopback, and link-local addresses are excluded. If
Tailscale is enabled after initialization, replace the certificate through the controlled
certificate-renewal process or initialize with the expected stable Tailscale IP/MagicDNS name
explicitly; do not edit a certificate in place.

By default, setup maps the hostname only on the OSCAR host. Use `-SkipHostsEntry` or `--skip-hosts-entry` to leave local host resolution unchanged. Site DNS or a hosts entry is still required on every workstation that connects to OSCAR.

`server.crt` must be a PEM certificate or chain. `server.key` must be its matching unencrypted PEM private key. The certificate subject alternative names must contain every DNS name or IP address used to reach OSCAR.

For an isolated deployment, administrators may use a deployment-specific certificate authority and install only its public certificate on workstations. Never place the certificate-authority private key in this release directory, a container, or a diagnostic bundle.

### LAN and Tailscale client trust

The generated `tls/server.crt` is public and may be copied to operator workstations. Verify its
SHA-256 fingerprint against the value obtained directly from the OSCAR host before trusting it.
Never copy `tls/server.key`. Installing the public certificate trusts only this deployment's
self-signed identity; it does not make an unlisted hostname or IP valid.

- Windows client, from an elevated PowerShell window:
  `certutil -addstore -f Root .\server.crt`
- Ubuntu client: copy it to `/usr/local/share/ca-certificates/oscar-site.crt`, then run
  `sudo update-ca-certificates`. A browser configured with a separate certificate store must also
  import the public certificate there.
- macOS client: use Keychain Access to add `server.crt` to the System keychain and mark it trusted,
  after verifying the fingerprint.

For ordinary LAN operation, create a site DNS record pointing the configured hostname at the
OSCAR host's static address. A per-workstation hosts entry is an acceptable isolated-test fallback,
but it does not scale and must map the same hostname that appears in the certificate. Direct access
such as `https://192.168.0.57/` requires that exact IP SAN; accepting a warning for a certificate
issued only to `oscar.local` is not a supported substitute.

For Tailscale access, prefer the stable MagicDNS name and include it explicitly when it is not
discoverable during setup. Direct Tailscale-IP access is supported when the printed certificate
URL contains that IP. Tailscale connectivity does not distribute OSCAR's certificate trust: each
client must still trust `server.crt`, or the deployment must import a certificate already trusted
by those clients. Restrict Tailscale ACLs separately so only authorized operators can reach the
OSCAR HTTPS port.

## Windows offline installation

Extract the offline ZIP into a local NTFS directory. From an Administrator Windows PowerShell 5.1
(`powershell.exe`) window:

```powershell
.\verify-bundle.ps1
.\oscar.bat init
```

The equivalent CLI command is `oscar.bat verify`. Verification requires the exact bundle inventory:
every allowed regular file appears once in `SHA256SUMS`, every listed digest matches, and no extra,
linked, reparse-point, aliased, or prefix-colliding path is accepted. OSCAR records a receipt for
audit, but every later mutating `init` or `upgrade` repeats the full pass before it can execute a
bundle payload. Routine non-setup commands do not perform full bundle verification; run `verify`
explicitly whenever post-installation tampering is suspected.

The full artifact can launch only the unique, allowlisted and checksum-covered installer paths named by its manifest
when WSL or Docker Desktop is missing. An extra wildcard-matching installer is rejected rather than
selected. The images-only artifact must be initialized with a working existing runtime:

```powershell
.\oscar.bat init -Prerequisites existing
```

If an installer requires a restart, restart Windows and run `oscar.bat init` again.

The offline CLI does not contact package repositories or container registries. Docker Desktop
licensing must be reviewed and accepted independently by the deploying organization; OSCAR does not
accept that agreement. A required installer restart is also an explicit administrator acceptance
step before setup is resumed.

## Logs

The default displays the last 200 lines from all services and exits:

```powershell
.\oscar.bat logs
```

Select a service and optionally follow it:

```powershell
.\oscar.bat logs -Service oscar -Tail 500
.\oscar.bat logs -Service postgres -Follow
.\oscar.bat logs -Service gateway
```

Ubuntu uses `--service`, `--tail`, and `--follow`.

## Persistent state and secrets

Initialization creates:

```text
.env
secrets/oscar-admin-password.txt
secrets/oscar-db-password.txt
secrets/postgres-bootstrap-password.txt
secrets/backup-key.txt
tls/server.crt
tls/server.key
```

Docker Compose mounts secrets read-only. On Ubuntu, the setup CLI makes `secrets` and `tls` mode `0700`, with contained files readable by the deliberately non-root services. On Windows, it restricts the directories to the installing administrator and `SYSTEM` while preserving container-readable, read-only mounts.

The application configuration is copied into the `oscar_state` volume on first startup. Runtime configuration saves update only that persistent copy. Application libraries and viewer assets remain read-only in the image. PostgreSQL data is stored in the `postgres_data` volume. OSCAR 3.9.2 uses long-lived host bind mounts configured in `.env` for the Parquet archive (`OSCAR_ARCHIVE_DIR`) and PostgreSQL WAL archive (`OSCAR_WAL_ARCHIVE_DIR`). `OSCAR_BACKUP_DIR` is a separate administrator-owned host root that is never mounted into a long-running service; the storage CLI exposes only a selected input or output to a narrowly scoped one-shot helper. Monitor and protect all five persistent locations; a Docker named-volume backup alone is incomplete.

The OSCAR service keeps the general-purpose `/tmp` tmpfs `noexec`. Embedded Java native libraries,
including DuckDB JDBC and JavaCPP/FFmpeg, are extracted instead to a separate 256 MiB tmpfs at
`/run/oscar-native`. That mount is executable only because the JVM must map shared objects; it is
still ephemeral, `nosuid`, `nodev`, owned by the non-root OSCAR user, and mode `0700`. The entrypoint
forces `java.io.tmpdir` to that path after `OSCAR_JAVA_OPTS` and refuses to start unless `/tmp` is a
dedicated `noexec` tmpfs and the native mount has the expected type, ownership, permissions, and
execution behavior. User-supplied multipart and spectrum-conversion temporary files remain on
`/tmp` through the separately managed `oscar.data.tmpdir` property, so they never enter the
executable native directory. Do not override either mount or add `-Djava.io.tmpdir` or
`-Dorg.bytedeco.javacpp.cachedir` or `-Doscar.data.tmpdir` to `OSCAR_JAVA_OPTS`. The entrypoint
also rejects `_JAVA_OPTIONS`, which OpenJDK applies after command-line options; custom launchers
must reproduce this two-mount contract.

DuckDB query scratch is separate from both temporary mounts and the immutable archive. Every
archive connection is limited by the persisted database-module settings (shipping defaults:
256 MiB memory, two threads, and 4 GiB spill) and gets a private child below
`/var/lib/oscar/duckdb-tmp` in `oscar_state`. Normal connection close removes the child; coordinated
backups exclude this scratch parent. The scratch and archive roots must be disjoint. In the Linux
container (on either Ubuntu or Windows hosts), OSCAR requires POSIX mode `0700` on the parent and
each operation child and rejects an existing broader parent; a non-container/non-POSIX embedding
must provide an equivalent owner-only ACL. If a hard process/container failure leaves a child
behind, stop OSCAR before removing only abandoned children from that configured parent.
The backup exclusion is intentionally limited to the reserved `/var/lib/oscar/duckdb-tmp` path.
OSCAR therefore rejects any other scratch path inside `/var/lib/oscar`; a custom path must be
outside that persistent state tree and disjoint from the archive.

The backup key encrypts `.env`, deployment secrets, and TLS private material inside coordinated backups. The encrypted `secrets/` payload contains a recovery copy of the key file, but there is no usable plaintext key in the backup: store an external protected copy in an independent secret escrow or failure domain.

The gateway gives content-hashed Viewer files under `/_next/static/` a private, one-year immutable browser cache policy, while `/sw.js` is always revalidated. This prevents repeated full-route navigations from downloading the same application bundles again without allowing a shared proxy to cache an authenticated response. HTML and API responses keep their normal revalidation behavior.

`oscar stop` retains containers, named data volumes, the archive/WAL bind mounts, and the external
backup root. Do not use `docker compose down --volumes` as a records-destruction procedure: Compose
skips OSCAR's external named volumes, and neither that command nor container removal deletes the
archive, WAL, or backup roots. Authorized permanent destruction therefore requires the documented,
explicit removal of every retained data location.

WebID is disabled by default. Failure to reach an optional configured WebID endpoint must not prevent OSCAR from starting.

## Security verification

After startup:

```sh
docker compose ps
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  export PGPASSWORD
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command "SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls FROM pg_roles WHERE rolname = 'oscar_app';"
```

Every reported privilege flag for `oscar_app` must be false. A host scan must show port `80` and the configured HTTPS port, and must not show ports `8282` or `5432`. Port `80` must return only an HTTPS redirect.

## Upgrade

For a 3.9.2-or-newer same-storage-profile upgrade, create and verify a coordinated backup first. A pre-3.9.2 release does not have that CLI; use that release's supported backup/export procedure and retain the old system read-only until the separately qualified migration is complete. Extract the new release into a clean sibling directory; do not overlay it on the previous release because files removed by the new version would otherwise remain in the image build context. Copy only `.env`, `secrets/`, and `tls/` from the existing deployment into the clean release directory. If the deployment has a `.oscar-volume-adoption` receipt, copy that file too; it is required to keep an intentionally adopted pair of unlabelled legacy volumes bound to the same deployment. Release archives do not contain these runtime files. Preserve the absolute `OSCAR_ARCHIVE_DIR`, `OSCAR_WAL_ARCHIVE_DIR`, and `OSCAR_BACKUP_DIR` values written by initialization; they deliberately point outside the versioned release and must continue to identify the existing storage. Custom relative storage paths are rejected because their meaning would change after relocation. Before starting services, use `docker compose config` to confirm the resolved archive and WAL bind sources, then inspect the single `OSCAR_BACKUP_DIR` entry in `.env` to confirm the external backup root. Compose uses the fixed `oscar` project name for containers, while `compose.yaml` attaches the exact external volumes `oscar_oscar_state` and `oscar_postgres_data`. Setup, not Compose, owns their creation and validates their deployment identity before start or upgrade. This prevents Compose from attempting to reconcile immutable volume labels or offering to recreate an adopted legacy volume. Then run:

```powershell
.\oscar.bat upgrade
```

```sh
sudo bash oscar.sh upgrade
```

The command preserves existing settings and data while normalizing the required 3.9.2 managed
bindings: deployment identity, absolute external storage roots, and the canonical backup-key
binding. A legacy deployment may also receive a generated backup key plus explicit volume/root
adoption metadata when the corresponding adoption options are supplied. After those guarded
normalizations it updates `OSCAR_VERSION`, validates Compose, prepares the versioned images,
force-recreates all service containers, waits for health checks, and retains the fixed `oscar_state`
and `postgres_data` volumes plus the exact external archive/WAL/backup roots. Recreating every
container is required even when an image and service model are unchanged: release-local secret,
certificate, and gateway-config bind sources and the Compose `working_dir`/`config_files` provenance
must point to the new clean release directory. It never removes volumes or external storage roots.
Confirm the result with `oscar.bat status`
(Windows) or `sudo bash oscar.sh status` (Ubuntu).

Retire the previous extracted release directory only after all upgraded services are healthy and
`docker inspect` confirms that every container's release-local bind sources and Compose
`working_dir`/`config_files` labels refer to the new directory. The absolute archive, WAL, and backup
roots intentionally continue to refer to the persistent paths copied in `.env`; do not remove a
previous release's parent or sibling storage directory merely because its service containers were
replaced.

Setup creates both named volumes with an `OSCAR_DEPLOYMENT_ID` label and refuses missing, mixed, or
foreign ownership. Compose treats those exact names as external resources and never creates or
relabels them. For a pre-label deployment only, first verify from the old release and Docker
metadata that **both** `oscar_oscar_state` and `oscar_postgres_data` belong together. Then acknowledge
that one-time adoption with `oscar.bat upgrade -AdoptLegacyVolumes` or
`sudo bash oscar.sh upgrade --adopt-legacy-volumes`. Setup records both immutable Docker volume
creation times and the deployment ID in `.oscar-volume-adoption`; later mismatches fail closed.
Never use this switch to combine volumes from different installations, and preserve the receipt on
every subsequent clean-directory upgrade.

Storage-root ownership is a separate gate. New roots receive an administrator-owned
`.oscar-storage-root` version-1 identity bound to `OSCAR_DEPLOYMENT_ID` and the exact root kind. A
nonempty pre-3.9.2 archive, WAL, or backup root without that marker requires a one-time, reviewed
`oscar.bat upgrade -AdoptLegacyStorageRoots` or
`sudo bash oscar.sh upgrade --adopt-legacy-storage-roots`. The marker records the adoption time and
actor. Setup rejects a foreign UUID, swapped kind, unsafe marker, or unacknowledged nonempty root
before claiming any path. Backups exclude these host-local markers, and restore preserves and
revalidates the target markers instead of accepting identities from backup media.

The OSCAR application libraries and exported Viewer are part of the `oscar:<version>` image. A restart does not rebuild that image. To test OSCAR 3.9.2 from a connected release artifact, prepare the clean release directory as described above. Use `init` and fresh state for the complete 3.9.2 storage profile; use `upgrade` only when intentionally retaining the existing storage/configuration profile. Confirm that `docker compose images` reports `oscar:3.9.2` before accepting the test result.

Release image tags are immutable once published. If developers rebuild 3.9.2 repeatedly before the release is published, explicitly build the intended tag before `upgrade`. On Ubuntu, use `OSCAR_VERSION=3.9.2 docker compose build oscar`; in PowerShell, run `docker build --build-arg OSCAR_VERSION=3.9.2 --tag oscar:3.9.2 --file docker/oscar/Dockerfile .` from the extracted release. The explicit Windows build avoids Docker Compose 5.6's in-tree Dockerfile entitlement regression without granting wildcard filesystem access. Building without the explicit version before `upgrade` can reuse the previous tag and produce the wrong image. To force a connected rebuild or same-tag offline import instead, run `docker compose down` without `--volumes`, remove only the cached test image with `docker image rm oscar:3.9.2`, and then run `upgrade`. Never replace a published `oscar:3.9.2` image with different contents.

The default configuration for a new installation is labeled `OSCAR 3.9.2`. An upgrade preserves `/var/lib/oscar/config.json`, including a customized deployment name, so the Admin UI may continue to display the prior or site-specific label. Do not overwrite that value merely to display a version number. Use `OSCAR_VERSION` in `.env` and `docker compose images` to verify the running release. The OSCAR image also stamps that value into the OCI `org.opencontainers.image.version` label; inspect it on PowerShell or a POSIX shell with `docker image inspect oscar:3.9.2 --format '{{json .Config.Labels}}'` and require the label value `3.9.2` before accepting the image.

On Windows, setup and storage administration stream every bounded shell body and direct `psql`
statement into the one-shot container over UTF-8 standard input. The direct `docker run` adapter owns
the required `--interactive` attachment, while Compose execution remains non-TTY with `exec -T`.
Setup relays storage-command parameters to its child PowerShell process through a bounded,
allowlisted Base64/JSON environment envelope and a fixed encoded command; operator text is never
forwarded as native executable arguments. These rules preserve multiline checks, SQL, paths, and
quoted values exactly under Windows PowerShell 5.1 native argument handling. A failed initialization
check leaves the receipt in `INITIALIZING`; correct the reported problem and rerun `oscar.bat init`
from the same release and protected runtime state rather than deleting the volumes.

### 3.9.2 storage migration boundary

OSCAR 3.9.2 changes the default database module, write path, daily-file source capture, media-retention format, and PostgreSQL initialization. `upgrade` deliberately does not overwrite the saved module configuration or recreate the PostgreSQL cluster, so an upgraded pre-3.9.2 system does not automatically gain the complete 3.9.2 storage profile or data checksums.

Initialize the current test systems and new production systems with a fresh 3.9.2 database/configuration. If existing production history must be retained, keep the old system read-only after a verified backup and use a separately designed and tested migration. Do not delete production volumes merely to make the new module start. Follow the staged copy-only, parity, restore-drill, and hot-deletion rollout in [`../../docs/STORAGE_OPERATIONS.md`](../../docs/STORAGE_OPERATIONS.md).

The OSCAR container keeps `/var/lib/oscar/config.json` readable and writable only by the OSCAR runtime user (`0600`) and repairs older read-only copies during startup. After importing a lane CSV, wait for every lane to appear under **Sensors**, select the global **Save** action, restart OSCAR, and confirm that the same lanes reload. Historical systems in PostgreSQL are not proof that runtime sensor modules were saved; an empty **Sensors** tree after restart indicates that the module configuration was not persisted.

On Windows, OSCAR grants the local `docker-users` group read-only access to the protected `secrets` and `tls` directories so Docker Desktop can mount them. This is required when setup is elevated with a different administrator account than the signed-in account running Docker Desktop. The group receives temporary write access only while `init` generates or imports the certificate.

## Storage administration

The release implements coordinated backup/verification/restore, verified-backup/WAL pruning,
retention holds, and archive status, integrity, portable export, and restartable tokenized deletion
commands. The full procedures are in:

- [`../../docs/STORAGE_ARCHITECTURE.md`](../../docs/STORAGE_ARCHITECTURE.md)
- [`../../docs/DATA_LIFECYCLE.md`](../../docs/DATA_LIFECYCLE.md)
- [`../../docs/ARCHIVE_FORMAT.md`](../../docs/ARCHIVE_FORMAT.md)
- [`../../docs/BACKUP_RESTORE.md`](../../docs/BACKUP_RESTORE.md)
- [`../../docs/STORAGE_OPERATIONS.md`](../../docs/STORAGE_OPERATIONS.md)

The hold list and creation result include `resolution_mode`. A
`COLD_RANGE_CONSERVATIVE` observation hold protects matching generation ranges but is not proof that
the exact ID exists in sparse Parquet; verify the event or use an exact generation hold for legal
certainty. `LEGACY_UNKNOWN` is a protective migration-only label for pre-3.9.2 observation holds
whose exact-vs-range provenance cannot be reconstructed; the CLI never creates it. Active
observation and generation holds are enforced inside the same transaction as
hot/cold logical removal and tombstone creation. Single removal fails on a hold; filtered bulk
removal skips protected rows and counts only rows actually removed.

The same files are under `documentation/` in the packaged release. `backup` verifies the newly
created backup automatically and authenticates its checksum inventory with the separately stored
backup key. It rejects unsafe tar members, atomically marks the recovery point `VERIFIED`, and,
while OSCAR remains stopped, confirms only exact published daily-file/segment sets captured by the
accepted authenticated snapshot. Confirmation failure preserves that valid recovery point but
fails the command and skips automatic pruning. PostgreSQL remains online for `pg_basebackup`, is
stopped for the final stable WAL-archive snapshot, and resumes before catalog receipt and
verification. `backup-verify` runs `pg_verifybackup` in a dependency-free utility container, so the
live database and its catalog receipt are not recovery dependencies. Use `backup-verify` to recheck
it before every upgrade or retention reduction. The standard environment retains the newest 14 verified local backups and, only after a
new backup is created and verified, automatically prunes older verified backups plus WAL before the
oldest retained start boundary. Manual verification and restore do not prune the recovery target.
All storage-administration commands share one nonblocking, crash-released deployment lock; a
concurrent invocation fails rather than racing backup/archive state. The lock is keyed by
`OSCAR_DEPLOYMENT_ID` in `/run/lock/oscar-storage` on Ubuntu or
`%ProgramData%\OSCAR\StorageLocks` on Windows, so it
continues to coordinate old and new extracted releases. Live commands validate every root identity
and both named-volume ownership identities; only offline-capable `backup-verify` is exempt from
those live dependencies. Verification is still an acceptance mutation: it publishes/replaces
`VERIFIED` and normalizes backup permissions, and may update the live catalog only after proving
volume ownership.
Backup prune HMAC-authenticates and fully re-verifies every usable candidate before persisting a
durable recovery intent or deleting anything, and authenticates the oldest retained
`postgres/backup_label` again before pruning WAL. Review those settings against
site recovery policy. Keep `deleteHotAfterArchive=false` during initial rollout;
enable it only after mixed-tier parity and an isolated restore drill pass. Cold archive deletion
always requires a reviewed `archive dry-run` plan and its one-time token.

Certificate renewal and a site-specific migration of retained pre-3.9.2 history remain controlled administrator operations and must be validated before an upgrade is declared production-ready.

## Compatibility scripts

`setup.*`, `launch-all.*`, and `stop-all.*` remain as compatibility wrappers. New documentation and automation should use only `oscar.bat` or `oscar.sh`.

Offline map layers are not currently required. The CLI retains an explicit MBTiles import TODO for a future milestone.
