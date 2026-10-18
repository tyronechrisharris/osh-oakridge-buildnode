[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'This gate must run under Windows PowerShell 5.1 (powershell.exe).'
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..'))
$storageScript = Join-Path $repoRoot 'dist\release\oscar-storage.ps1'
$setupScript = Join-Path $repoRoot 'dist\release\oscar-setup.ps1'
$verifyScript = Join-Path $repoRoot 'dist\release\verify-bundle.ps1'
$offlineBuilderScript = Join-Path $repoRoot 'tools\offline\build-offline-bundle.ps1'
$composeFile = Join-Path $repoRoot 'dist\release\compose.yaml'
$oscarDockerfile = Join-Path $repoRoot 'dist\release\docker\oscar\Dockerfile'
$oscarEntrypoint = Join-Path $repoRoot 'dist\release\docker\oscar\entrypoint.sh'
$releasePowerShellScripts = @($storageScript, $setupScript, $verifyScript, $offlineBuilderScript)
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('oscar-storage-ps5-' + [Guid]::NewGuid().ToString('N'))
$createdDockerGroup = $false

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-ScriptParses([string]$Path) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) {
        throw "PowerShell 5.1 parser rejected $Path`: $($errors[0].Message)"
    }
}

function Invoke-Verifier([string]$Root) {
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'verify-bundle.ps1')) -Wait -PassThru -WindowStyle Hidden
    return $process.ExitCode
}

function Write-TestManifest([string]$Root) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('payload.txt', 'verify-bundle.ps1')) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $Root $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines.Add("$hash *$name")
    }
    [IO.File]::WriteAllLines((Join-Path $Root 'SHA256SUMS'), $lines, (New-Object Text.UTF8Encoding($false)))
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

    foreach ($script in $releasePowerShellScripts) { Assert-ScriptParses $script }
    foreach ($forbidden in @('Path]::GetRelativePath', 'Path]::IsPathFullyQualified')) {
        foreach ($script in $releasePowerShellScripts) {
            Assert-True (-not ([IO.File]::ReadAllText($script).Contains($forbidden))) "$script uses a .NET API absent from Windows PowerShell 5.1: $forbidden"
        }
    }

    # Windows packaging consumes the same Linux Compose contract. Validate it
    # here as plain text so PowerShell release builds cannot silently weaken it.
    $compose = [IO.File]::ReadAllText($composeFile)
    $oscarService = [Text.RegularExpressions.Regex]::Match(
        $compose, '^  oscar:\r?\n.*?(?=^  postgres:)',
        [Text.RegularExpressions.RegexOptions]::Multiline -bor [Text.RegularExpressions.RegexOptions]::Singleline).Value
    $nativeTmpfs = '/run/oscar-native:rw,exec,nosuid,nodev,size=256m,mode=0700,uid=10001,gid=10001'
    Assert-True ($oscarService.Contains('- /tmp:rw,noexec,nosuid,nodev')) 'Compose does not keep OSCAR /tmp noexec.'
    Assert-True ($oscarService.Contains("- $nativeTmpfs")) 'Compose is missing the bounded owner-only executable native tmpfs.'
    Assert-True (([Text.RegularExpressions.Regex]::Matches($compose, [Text.RegularExpressions.Regex]::Escape($nativeTmpfs))).Count -eq 1) 'The executable native tmpfs must be scoped to OSCAR only.'

    $dockerfile = [IO.File]::ReadAllText($oscarDockerfile)
    Assert-True ($dockerfile.Contains('/var/lib/oscar /run/oscar-native')) 'The OSCAR image is missing its private native-tmpfs mount point.'
    $entrypoint = [IO.File]::ReadAllText($oscarEntrypoint)
    $javaOptionsIndex = $entrypoint.IndexOf('exec java ${JAVA_OPTS:-}')
    Assert-True ($javaOptionsIndex -ge 0) 'The OSCAR entrypoint is missing its managed Java launch.'
    foreach ($managedProperty in @(
        '-Djava.io.tmpdir="${NATIVE_TMP_DIR}"',
        '-Dorg.bytedeco.javacpp.cachedir="${NATIVE_TMP_DIR}/javacpp"',
        '-Doscar.data.tmpdir=/tmp')) {
        Assert-True ($entrypoint.IndexOf($managedProperty) -gt $javaOptionsIndex) "Managed JVM property must follow JAVA_OPTS: $managedProperty"
    }
    Assert-True ($entrypoint.Contains('if [ -n "${_JAVA_OPTIONS:-}" ]')) 'The OSCAR entrypoint must reject late _JAVA_OPTIONS overrides.'

    $bundle = Join-Path $temporaryRoot 'bundle'
    New-Item -ItemType Directory -Path $bundle | Out-Null
    Copy-Item -LiteralPath $verifyScript -Destination (Join-Path $bundle 'verify-bundle.ps1')
    [IO.File]::WriteAllText((Join-Path $bundle 'payload.txt'), "verified payload`n", (New-Object Text.UTF8Encoding($false)))
    Write-TestManifest $bundle
    Assert-True ((Invoke-Verifier $bundle) -eq 0) 'The exact bundle inventory failed verification under Windows PowerShell 5.1.'
    [IO.File]::WriteAllText((Join-Path $bundle 'payload.txt'), "modified after receipt`n", (New-Object Text.UTF8Encoding($false)))
    Assert-True ((Invoke-Verifier $bundle) -ne 0) 'The Windows verifier trusted a stale receipt after payload mutation.'
    [IO.File]::WriteAllText((Join-Path $bundle 'payload.txt'), "verified payload`n", (New-Object Text.UTF8Encoding($false)))
    Write-TestManifest $bundle
    [IO.File]::WriteAllText((Join-Path $bundle 'extra.msi'), 'unmanifested', (New-Object Text.UTF8Encoding($false)))
    Assert-True ((Invoke-Verifier $bundle) -ne 0) 'The Windows verifier accepted an unmanifested installer.'
    Remove-Item -LiteralPath (Join-Path $bundle 'extra.msi') -Force
    Add-Content -LiteralPath (Join-Path $bundle 'SHA256SUMS') -Value ([IO.File]::ReadAllLines((Join-Path $bundle 'SHA256SUMS'))[0])
    Assert-True ((Invoke-Verifier $bundle) -ne 0) 'The Windows verifier accepted a duplicate manifest path.'

    $env:OSCAR_STORAGE_TEST_MODE = '1'
    . $storageScript -Command help | Out-Null
    Assert-True (-not (Test-FullyQualifiedDeploymentPath '\\server\share\archive')) 'UNC storage roots must be rejected before mutation.'
    Assert-True (Test-FullyQualifiedDeploymentPath 'D:\oscar-storage\archive') 'A local drive-rooted storage path was rejected.'

    $envFixture = Join-Path $temporaryRoot 'unc-preflight'
    New-Item -ItemType Directory -Path $envFixture | Out-Null
    [IO.File]::WriteAllLines((Join-Path $envFixture '.env'), @(
        'OSCAR_VERSION=3.9.2',
        'OSCAR_DEPLOYMENT_ID=11111111-2222-4333-8444-555555555555',
        'OSCAR_ARCHIVE_DIR=\\server\share\archive',
        'OSCAR_BACKUP_DIR=D:\oscar-storage\backups',
        'OSCAR_WAL_ARCHIVE_DIR=D:\oscar-storage\wal-archive',
        'OSCAR_SECRETS_DIR=.\secrets',
        'OSCAR_TLS_DIR=.\tls',
        'OSCAR_BACKUP_KEY_FILE=.\secrets\backup-key.txt'
    ), (New-Object Text.UTF8Encoding($false)))
    $originalScriptRoot = $ScriptRoot
    $ScriptRoot = $envFixture
    $rejectedUnc = $false
    try { Assert-ManagedEnvironmentBindings } catch { $rejectedUnc = $true }
    $ScriptRoot = $originalScriptRoot
    Assert-True $rejectedUnc 'Managed-environment preflight accepted a UNC storage root.'

    & net.exe localgroup docker-users *> $null
    if ($LASTEXITCODE -ne 0) {
        & net.exe localgroup docker-users /add *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the temporary docker-users group for ACL validation.' }
        $createdDockerGroup = $true
    }

    Assert-Administrator
    $aclRoot = Join-Path $temporaryRoot 'acl-root'
    New-Item -ItemType Directory -Path $aclRoot | Out-Null
    Protect-DockerStorageDirectory $aclRoot 'ReadWrite'
    Assert-DockerStorageDirectory $aclRoot 'test storage root' 'ReadWrite'
    $acl = Get-Acl -LiteralPath $aclRoot
    $everyone = [Security.Principal.SecurityIdentifier]::new('S-1-1-0')
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $everyone,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $aclRoot -AclObject $acl
    $rejectedEveryone = $false
    try { Assert-DockerStorageDirectory $aclRoot 'test storage root' 'ReadWrite' } catch { $rejectedEveryone = $true }
    Assert-True $rejectedEveryone 'Storage ACL validation accepted Everyone:FullControl.'

    Protect-DockerStorageDirectory $aclRoot 'ReadOnly'
    Assert-DockerStorageDirectory $aclRoot 'test backup root' 'ReadOnly'
    $source = Join-Path $aclRoot 'durable-source'
    $destination = Join-Path $aclRoot 'durable-destination'
    [IO.File]::WriteAllText($source, 'durable', (New-Object Text.UTF8Encoding($false)))
    Move-DurableNoReplace $source $destination
    Assert-True (Test-Path -LiteralPath $destination -PathType Leaf) 'Win32 durable no-replace move did not publish the file.'
    [IO.File]::WriteAllText($source, 'collision', (New-Object Text.UTF8Encoding($false)))
    $rejectedCollision = $false
    try { Move-DurableNoReplace $source $destination } catch { $rejectedCollision = $true }
    Assert-True $rejectedCollision 'Win32 durable no-replace move overwrote an existing destination.'

    $catalogRoot = Join-Path $temporaryRoot 'catalog-receipt'
    New-Item -ItemType Directory -Path $catalogRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $catalogRoot 'epoch.json'), "{}`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $catalogRoot 'archive-generation-ids.txt'),
        "11111111-1111-4111-8111-111111111111`n22222222-2222-4222-8222-222222222222`n",
        (New-Object Text.UTF8Encoding($false)))
    $catalogId = '12345678-1234-4234-8234-123456789abc'
    $catalogBackup = '20261017T120000Z-1234abcd'
    $script:CapturedCatalogSql = ''
    function Assert-DeploymentVolumeOwnership {}
    function Invoke-PsqlScript([string]$Sql) {
        $script:CapturedCatalogSql = $Sql
        return "$catalogId|VERIFIED"
    }
    Set-VerifiedBackupEpochReceipt $catalogRoot $catalogBackup $catalogId '0/12345678'
    Assert-True ($script:CapturedCatalogSql.Contains("oscar_backup_epoch.state IN ('CREATED','VERIFIED')") -and
        $script:CapturedCatalogSql.Contains('postgres_lsn IS NOT DISTINCT FROM EXCLUDED.postgres_lsn') -and
        $script:CapturedCatalogSql.Contains('archive_generation_ids IS NOT DISTINCT FROM EXCLUDED.archive_generation_ids') -and
        $script:CapturedCatalogSql.Contains("'{11111111-1111-4111-8111-111111111111,22222222-2222-4222-8222-222222222222}'::uuid[]") -and
        -not $script:CapturedCatalogSql.Contains('FROM oscar_archive_generation') -and
        $script:CapturedCatalogSql.Contains('sha256 IS NOT DISTINCT FROM EXCLUDED.sha256')) 'PowerShell VERIFIED epoch upsert is not bound to the authenticated backup-time generation set.'
    function Invoke-PsqlScript([string]$Sql) { return '' }
    $rejectedForeignEpoch = $false
    try { Set-VerifiedBackupEpochReceipt $catalogRoot $catalogBackup $catalogId '0/12345678' } catch { $rejectedForeignEpoch = $true }
    Assert-True $rejectedForeignEpoch 'PowerShell accepted a foreign same-UUID backup epoch collision.'

    . $setupScript -Command help | Out-Null
    Assert-True (-not (Test-FullyQualifiedDeploymentPath '\\server\share\archive')) 'Setup accepted a UNC storage root.'

    $wslCandidates = Join-Path $temporaryRoot 'wsl-candidates'
    New-Item -ItemType Directory -Path $wslCandidates | Out-Null
    $rejectedZero = $false
    try { [void](Get-BundledWslInstaller $wslCandidates) } catch { $rejectedZero = $true }
    Assert-True $rejectedZero 'Setup accepted zero WSL installer candidates.'
    $wslOne = Join-Path $wslCandidates 'wsl.2.4.0.x64.msi'
    [IO.File]::WriteAllText($wslOne, 'fixture', (New-Object Text.UTF8Encoding($false)))
    Assert-True ((Get-BundledWslInstaller $wslCandidates).FullName -ceq $wslOne) 'Setup rejected the one regular allowlisted WSL MSI.'
    $wslTwo = Join-Path $wslCandidates 'wsl.2.4.1.x64.msi'
    [IO.File]::WriteAllText($wslTwo, 'fixture', (New-Object Text.UTF8Encoding($false)))
    $rejectedMultiple = $false
    try { [void](Get-BundledWslInstaller $wslCandidates) } catch { $rejectedMultiple = $true }
    Assert-True $rejectedMultiple 'Setup selected one of multiple WSL installer candidates.'
    Remove-Item -LiteralPath $wslOne, $wslTwo -Force
    $junctionTarget = Join-Path $temporaryRoot 'wsl-junction-target'
    New-Item -ItemType Directory -Path $junctionTarget | Out-Null
    $junction = Join-Path $wslCandidates 'wsl-linked.msi'
    New-Item -ItemType Junction -Path $junction -Target $junctionTarget | Out-Null
    $rejectedLinked = $false
    try { [void](Get-BundledWslInstaller $wslCandidates) } catch { $rejectedLinked = $true }
    Assert-True $rejectedLinked 'Setup accepted a linked/reparse WSL installer candidate.'

    Write-Host 'OSCAR Windows PowerShell 5.1 storage safety tests passed.' -ForegroundColor Green
} finally {
    Remove-Item Env:OSCAR_STORAGE_TEST_MODE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if ($createdDockerGroup) { & net.exe localgroup docker-users /delete *> $null }
}
