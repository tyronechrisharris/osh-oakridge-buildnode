[CmdletBinding()]
param(
    [ValidateSet('init', 'check', 'verify', 'start', 'stop', 'restart', 'status', 'logs', 'upgrade', 'backup', 'backup-verify', 'backup-prune', 'restore', 'archive', 'help')]
    [string]$Command = 'help',
    [string]$StorageAction,
    [string]$HoldAction,
    [string]$Hostname,
    [ValidateRange(1, 65535)]
    [int]$Port = 443,
    [ValidateSet('self-signed', 'import')]
    [string]$TlsMode = 'self-signed',
    [string]$CertificatePath,
    [string]$PrivateKeyPath,
    [switch]$AddHostsEntry,
    [switch]$SkipHostsEntry,
    [switch]$NonInteractive,
    [switch]$SkipStart,
    [switch]$AdoptLegacyVolumes,
    [switch]$AdoptLegacyStorageRoots,
    [ValidateSet('auto', 'existing', 'bundled')]
    [string]$Prerequisites = 'auto',
    [ValidateSet('all', 'oscar', 'postgres', 'gateway')]
    [string]$Service = 'all',
    [ValidateRange(1, 10000)]
    [int]$Tail = 200,
    [switch]$Follow,
    [string]$BackupId,
    [string]$Confirm,
    [string]$Before,
    [string]$RequestedBy,
    [string]$Plan,
    [string]$Token,
    [string]$Generation,
    [string]$Destination,
    [string]$Observation,
    [string]$StoreKey,
    [string]$IdScope,
    [string]$HoldId,
    [string]$Reason,
    [string]$CreatedBy,
    [string]$ReleasedBy,
    [ValidateRange(1, 10000)]
    [int]$Keep = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Heading([string]$Text) {
    Write-Host "`n== $Text ==" -ForegroundColor Cyan
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-Administrator)) {
        throw 'Run this command from an Administrator PowerShell window.'
    }
}

function Get-OfflineBundleManifestHash {
    $checksumPath = Join-Path $ScriptRoot 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $checksumPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-OfflineBundleVerificationStatus {
    $manifestHash = Get-OfflineBundleManifestHash
    if (-not $manifestHash) { return 'not an offline bundle' }
    $receiptPath = Join-Path $ScriptRoot '.bundle-verified'
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { return 'not verified' }
    $verifiedHash = [IO.File]::ReadAllText($receiptPath).Trim().ToLowerInvariant()
    if ($verifiedHash -ceq $manifestHash) { return 'verified' }
    return 'verification required (bundle changed)'
}

function Initialize-BundleReceiptMethods {
    if ('OscarBundleReceiptNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OscarBundleReceiptNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool MoveFileEx(string existingName, string newName, uint flags);
}
'@
}

function Write-DurableBundleReceipt([string]$ManifestHash) {
    $receiptPath = Join-Path $ScriptRoot '.bundle-verified'
    $temporaryReceipt = Join-Path $ScriptRoot ('.bundle-verified.tmp.' + [Guid]::NewGuid().ToString('N'))
    try {
        $bytes = $Utf8NoBom.GetBytes("$ManifestHash`n")
        $stream = [IO.FileStream]::new($temporaryReceipt, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        $existing = Get-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Offline verification receipt is not a regular, non-reparse-point file: $receiptPath"
            }
        }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            Initialize-BundleReceiptMethods
            $moveFlags = if ($existing) { 0x9 } else { 0x8 }
            if (-not [OscarBundleReceiptNative]::MoveFileEx($temporaryReceipt, $receiptPath, $moveFlags)) {
                $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "Durable offline-verification receipt publication failed (Win32 $code)."
            }
        } else {
            if ($existing) { [IO.File]::Move($temporaryReceipt, $receiptPath, $true) }
            else { [IO.File]::Move($temporaryReceipt, $receiptPath) }
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryReceipt) { Remove-Item -LiteralPath $temporaryReceipt -Force -ErrorAction SilentlyContinue }
    }
}

function Assert-OfflineBundleIntegrity([switch]$Force) {
    $manifestHash = Get-OfflineBundleManifestHash
    if (-not $manifestHash) { return }
    $receiptPath = Join-Path $ScriptRoot '.bundle-verified'
    Write-Heading 'Offline bundle integrity'
    $verifier = Join-Path $ScriptRoot 'verify-bundle.ps1'
    if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) { throw 'The offline bundle verifier is missing.' }
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $verifier
    if ($LASTEXITCODE -ne 0) { throw 'Offline bundle integrity verification failed.' }
    Write-DurableBundleReceipt $manifestHash
}

function Invoke-External([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program exited with code $LASTEXITCODE."
    }
}

function Invoke-ExternalProbe([scriptblock]$Action) {
    $previousErrorPreference = $ErrorActionPreference
    try {
        # Windows PowerShell can promote expected native stderr (such as an
        # image-inspect miss) into a terminating error when Stop is active.
        $ErrorActionPreference = 'SilentlyContinue'
        & $Action *> $null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $previousErrorPreference
    }
}

function Get-DockerOutput([string[]]$Arguments) {
    $previousErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& docker @Arguments 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "docker exited with code $LASTEXITCODE." }
        return (($output -join "`n").Trim())
    } finally {
        $ErrorActionPreference = $previousErrorPreference
    }
}

function Test-DockerReady {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Invoke-ExternalProbe { docker compose version })) { return $false }
    return (Invoke-ExternalProbe { docker info })
}

function Test-WslReady {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    return (Invoke-ExternalProbe { wsl.exe --status })
}

function Get-BundledWslInstaller([string]$InstallerRoot) {
    $candidates = @(Get-ChildItem -LiteralPath $InstallerRoot -Filter 'wsl*.msi' -Force -ErrorAction SilentlyContinue)
    if ($candidates.Count -ne 1) {
        throw "Expected exactly one allowlisted WSL x64 MSI in $InstallerRoot; found $($candidates.Count)."
    }
    $candidate = $candidates[0]
    if ($candidate.PSIsContainer -or $candidate -isnot [IO.FileInfo] -or
        ($candidate.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $candidate.Name -notmatch '^wsl(?:[._-][A-Za-z0-9.-]+)?\.msi$') {
        throw "The WSL installer candidate must be one regular, non-reparse, allowlisted MSI directly in $InstallerRoot."
    }
    return $candidate
}

function Install-BundledPrerequisites {
    Write-Heading 'Docker and WSL prerequisites'
    $installerRoot = Join-Path $ScriptRoot 'installers\windows-x86_64'

    if (-not (Test-WslReady)) {
        # Resolve the single checksum-covered inventory member before enabling any
        # Windows feature. Never execute a lexically first wildcard match.
        $wslInstaller = Get-BundledWslInstaller $installerRoot
        foreach ($feature in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
            & dism.exe /Online /Enable-Feature "/FeatureName:$feature" /All /NoRestart | Out-Host
            if ($LASTEXITCODE -notin @(0, 3010)) { throw "Could not enable required Windows feature: $feature" }
        }
        Write-Host "Launching official WSL installer: $($wslInstaller.Name)"
        $process = Start-Process msiexec.exe -ArgumentList @('/i', "`"$($wslInstaller.FullName)`"", '/passive', '/norestart') -Wait -PassThru
        if ($process.ExitCode -notin @(0, 3010)) { throw "WSL installer exited with code $($process.ExitCode)." }
        if ($process.ExitCode -eq 3010 -or -not (Test-WslReady)) { throw 'WSL installation requires a restart. Restart Windows, then run this command again.' }
    }

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        $dockerInstaller = Join-Path $installerRoot 'Docker Desktop Installer.exe'
        if (-not (Test-Path -LiteralPath $dockerInstaller -PathType Leaf)) {
            throw "Docker is unavailable. Place the official Docker Desktop installer at '$dockerInstaller' and run setup again."
        }
        Write-Host 'Launching the official Docker Desktop installer. Setup will resume when it exits.'
        Write-Host 'The administrator must review and accept the Docker Desktop license in the official installer or application.'
        $process = Start-Process -FilePath $dockerInstaller -ArgumentList @('install', '--backend=wsl-2', '--no-windows-containers') -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Docker Desktop installer exited with code $($process.ExitCode)." }
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = "$machinePath;$userPath"
    }

    if (-not (Test-DockerReady)) {
        $dockerDesktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
        if (Test-Path -LiteralPath $dockerDesktop) {
            Write-Host 'Starting Docker Desktop and waiting for its engine...'
            Start-Process -FilePath $dockerDesktop | Out-Null
            for ($attempt = 0; $attempt -lt 60; $attempt++) {
                Start-Sleep -Seconds 2
                if (Test-DockerReady) { return }
            }
        }
        throw 'Docker is installed but its engine is not ready. Start Docker Desktop, then run setup again.'
    }
}

function Assert-Docker {
    if (Test-DockerReady) { return }
    if ($Prerequisites -eq 'existing') {
        throw "The existing Docker installation is unavailable or not ready. Start Docker and ensure 'docker compose' works, or rerun init with -Prerequisites auto."
    }
    Install-BundledPrerequisites
    if (-not (Test-DockerReady)) { throw 'Docker Engine and Docker Compose are required.' }
}

function Read-RequiredValue([string]$Prompt, [string]$Current) {
    if ($Current) { return $Current.Trim() }
    if ($NonInteractive) { throw "$Prompt is required in non-interactive mode." }
    do { $value = (Read-Host $Prompt).Trim() } until ($value)
    return $value
}

function Test-ValidHostname([string]$Value) {
    $parsedIp = $null
    if ([Net.IPAddress]::TryParse($Value, [ref]$parsedIp)) { return $true }
    return $Value -match '^(?=.{1,253}$)(?!-)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
}

function Set-EnvValue([string]$Name, [string]$Value) {
    $envPath = Join-Path $ScriptRoot '.env'
    $lines = if (Test-Path -LiteralPath $envPath) { [IO.File]::ReadAllLines($envPath) } else { [IO.File]::ReadAllLines((Join-Path $ScriptRoot '.env.example')) }
    $replacement = "$Name=$Value"
    $found = $false
    for ($index = 0; $index -lt $lines.Length; $index++) {
        if ($lines[$index] -match "^$([Regex]::Escape($Name))=") { $lines[$index] = $replacement; $found = $true }
    }
    if (-not $found) { $lines += $replacement }
    [IO.File]::WriteAllLines($envPath, $lines, $Utf8NoBom)
}

function Get-ConfiguredEnvValue([string]$Name) {
    $envPath = Join-Path $ScriptRoot '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) { return $null }
    foreach ($line in [IO.File]::ReadAllLines($envPath)) {
        if ($line -match "^$([Regex]::Escape($Name))=(.*)$") { return $Matches[1] }
    }
    return $null
}

function Test-FullyQualifiedDeploymentPath([string]$Value) {
    if (-not $Value -or -not [IO.Path]::IsPathRooted($Value)) { return $false }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        # The storage profile relies on local-volume durable rename/flush
        # semantics. Reject UNC roots before setup creates or mutates them.
        return $Value -cmatch '^[A-Za-z]:[\\/]'
    }
    return $Value.StartsWith('/', [StringComparison]::Ordinal)
}

function Assert-UniqueLiteralEnvironmentKeys {
    $envPath = Join-Path $ScriptRoot '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf) -or
        ((Get-Item -LiteralPath $envPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Deployment .env must be a regular, non-reparse-point file.'
    }
    $lines = [IO.File]::ReadAllLines($envPath)
    foreach ($name in @('OSCAR_VERSION', 'OSCAR_DEPLOYMENT_ID', 'OSCAR_ARCHIVE_DIR', 'OSCAR_BACKUP_DIR', 'OSCAR_WAL_ARCHIVE_DIR')) {
        $matches = @($lines | Where-Object { $_.StartsWith("$name=", [StringComparison]::Ordinal) })
        if ($matches.Count -ne 1) { throw "Deployment .env must contain exactly one literal $name binding." }
        $value = $matches[0].Substring($name.Length + 1)
        $interpreted = $value.IndexOfAny([char[]]@('$', '#', '"', "'")) -ge 0
        if (-not $value -or $interpreted -or @($value.ToCharArray() | Where-Object { [char]::IsWhiteSpace($_) }).Count -ne 0) {
            throw "Deployment .env contains a Compose-interpreted or nonliteral $name value."
        }
    }
}

function Assert-UpgradeableEnvironmentBindings {
    $envPath = Join-Path $ScriptRoot '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf) -or
        ((Get-Item -LiteralPath $envPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Deployment .env must be a regular, non-reparse-point file.'
    }
    $lines = [IO.File]::ReadAllLines($envPath)
    foreach ($name in @('OSCAR_VERSION', 'OSCAR_DEPLOYMENT_ID', 'OSCAR_ARCHIVE_DIR', 'OSCAR_BACKUP_DIR', 'OSCAR_WAL_ARCHIVE_DIR')) {
        $matches = @($lines | Where-Object { $_.StartsWith("$name=", [StringComparison]::Ordinal) })
        if ($name -ceq 'OSCAR_VERSION') {
            if ($matches.Count -ne 1) { throw 'Upgrade source .env must contain exactly one literal OSCAR_VERSION binding.' }
        } elseif ($matches.Count -gt 1) {
            throw "Upgrade source .env contains duplicate $name bindings."
        }
        if ($matches.Count -eq 1) {
            $value = $matches[0].Substring($name.Length + 1)
            $interpreted = $value.IndexOfAny([char[]]@('$', '#', '"', "'")) -ge 0
            if (-not $value -or $interpreted -or @($value.ToCharArray() | Where-Object { [char]::IsWhiteSpace($_) }).Count -ne 0) {
                throw "Upgrade source .env contains a Compose-interpreted or nonliteral $name value."
            }
        }
    }
}

function Assert-ManagedEnvironmentBindings {
    Assert-UniqueLiteralEnvironmentKeys
    Assert-CanonicalCredentialBindings
    foreach ($name in @('OSCAR_ARCHIVE_DIR', 'OSCAR_BACKUP_DIR', 'OSCAR_WAL_ARCHIVE_DIR')) {
        $value = Get-ConfiguredEnvValue $name
        if (-not (Test-FullyQualifiedDeploymentPath $value)) { throw "$name must be an absolute stable storage-root path." }
    }
}

function Initialize-LegacyBackupKeyBinding {
    $envPath = Join-Path $ScriptRoot '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf) -or
        ((Get-Item -LiteralPath $envPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Deployment .env must be a regular file.'
    }
    $lines = [IO.File]::ReadAllLines($envPath)
    $sourceVersionMatches = @($lines | Where-Object { $_ -match '^OSCAR_VERSION=' })
    if ($sourceVersionMatches.Count -ne 1) { return }
    $sourceVersionText = $sourceVersionMatches[0].Substring('OSCAR_VERSION='.Length)
    if ($sourceVersionText -notmatch '^\d+\.\d+\.\d+$') { return }
    $sourceVersion = [Version]$sourceVersionText
    if ($sourceVersion -ge [Version]'3.9.2') { return }

    $matches = @($lines | Where-Object { $_ -match '^OSCAR_BACKUP_KEY_FILE=' })
    if ($matches.Count -eq 0) {
        Set-EnvValue 'OSCAR_BACKUP_KEY_FILE' './secrets/backup-key.txt'
        Write-Host 'Added the canonical backup-key binding required for a pre-3.9.2 deployment upgrade.'
    }
}

function Assert-CanonicalCredentialBindings {
    $envPath = Join-Path $ScriptRoot '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf) -or
        ((Get-Item -LiteralPath $envPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Deployment .env must be a regular file.'
    }
    $lines = [IO.File]::ReadAllLines($envPath)
    $expectedBindings = [ordered]@{
        OSCAR_SECRETS_DIR = './secrets'
        OSCAR_TLS_DIR = './tls'
        OSCAR_BACKUP_KEY_FILE = './secrets/backup-key.txt'
    }
    foreach ($entry in $expectedBindings.GetEnumerator()) {
        $matches = @($lines | Where-Object { $_ -match "^$([Regex]::Escape($entry.Key))=" })
        $value = if ($matches.Count -eq 1) { $matches[0].Substring($entry.Key.Length + 1) } else { $null }
        if ($matches.Count -ne 1 -or $value -cne $entry.Value) {
            throw "$($entry.Key) must use the canonical supported binding $($entry.Value). Custom credential paths are not supported."
        }
    }
}

function Initialize-StoragePaths {
    # Storage must outlive a versioned release directory. Persist absolute
    # sibling paths in .env so moving to a clean release cannot silently attach
    # empty archive/WAL/backup directories.
    $stableRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ScriptRoot) 'oscar-storage'))
    $entries = @(
        @('OSCAR_ARCHIVE_DIR', 'archive', @('./data/archive', '../oscar-storage/archive')),
        @('OSCAR_WAL_ARCHIVE_DIR', 'wal-archive', @('./data/wal-archive', '../oscar-storage/wal-archive')),
        @('OSCAR_BACKUP_DIR', 'backups', @('./backups', '../oscar-storage/backups'))
    )
    foreach ($entry in $entries) {
        $name = [string]$entry[0]
        $suffix = [string]$entry[1]
        $defaults = @($entry[2])
        $value = Get-ConfiguredEnvValue $name
        $normalized = if ($value) { $value.Replace('\', '/') } else { '' }
        if (-not $value -or $defaults -contains $normalized) {
            Set-EnvValue $name ([IO.Path]::GetFullPath((Join-Path $stableRoot $suffix)))
        } elseif ([IO.Path]::IsPathRooted($value)) {
            Set-EnvValue $name ([IO.Path]::GetFullPath($value))
        } else {
            throw "$name must be an absolute path. Relative custom storage paths cannot be relocated safely during an upgrade: $value"
        }
    }
}

function Test-ValidDeploymentId([string]$Value) {
    return $Value -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

function Initialize-DeploymentIdentity {
    $deploymentId = Get-ConfiguredEnvValue 'OSCAR_DEPLOYMENT_ID'
    if (-not $deploymentId) {
        $deploymentId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
        Set-EnvValue 'OSCAR_DEPLOYMENT_ID' $deploymentId
    }
    if (-not (Test-ValidDeploymentId $deploymentId)) { throw 'OSCAR_DEPLOYMENT_ID in .env is missing or invalid.' }
    return $deploymentId
}

function Get-VolumeDeploymentLabel([string]$Volume) {
    $label = Get-DockerOutput @('volume', 'inspect', '--format', '{{ index .Labels "com.botts.oscar.deployment-id" }}', $Volume)
    if ($label -ceq '<no value>') { return '' }
    return $label
}

function Write-InitReceipt([string]$DeploymentId, [ValidateSet('INITIALIZING', 'COMPLETE')][string]$State) {
    $receiptPath = Join-Path $ScriptRoot '.oscar-init-state'
    $temporaryPath = "$receiptPath.tmp.$([Guid]::NewGuid().ToString('N'))"
    $content = @(
        'format=oscar-init-state',
        'version=1',
        "deployment_id=$DeploymentId",
        "state=$State"
    ) -join "`n"
    [IO.File]::WriteAllText($temporaryPath, "$content`n", $Utf8NoBom)
    Move-Item -LiteralPath $temporaryPath -Destination $receiptPath -Force
}

function Get-InitReceiptValue([string]$Name) {
    $receiptPath = Join-Path $ScriptRoot '.oscar-init-state'
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { return $null }
    $matches = @([IO.File]::ReadAllLines($receiptPath) | Where-Object { $_ -match "^$([Regex]::Escape($Name))=" })
    if ($matches.Count -ne 1) { return $null }
    return $matches[0].Substring($matches[0].IndexOf('=') + 1)
}

function Assert-InitReceipt {
    $receiptPath = Join-Path $ScriptRoot '.oscar-init-state'
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf) -or (Get-Item -LiteralPath $receiptPath -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        throw 'The OSCAR initialization receipt is missing, is not a regular file, or is a reparse point.'
    }
    $lines = @([IO.File]::ReadAllLines($receiptPath))
    if ($lines.Count -ne 4 -or @($lines | Where-Object { $_ -ceq 'format=oscar-init-state' }).Count -ne 1 -or
        @($lines | Where-Object { $_ -ceq 'version=1' }).Count -ne 1) {
        throw 'The OSCAR initialization receipt format or version is invalid.'
    }
    $deploymentId = Get-InitReceiptValue 'deployment_id'
    $state = Get-InitReceiptValue 'state'
    if (-not (Test-ValidDeploymentId $deploymentId) -or $state -notin @('INITIALIZING', 'COMPLETE')) {
        throw 'The OSCAR initialization receipt identity or state is invalid.'
    }
}

function Get-AdoptionReceiptValue([string]$Name) {
    $receiptPath = Join-Path $ScriptRoot '.oscar-volume-adoption'
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { return $null }
    $matches = @([IO.File]::ReadAllLines($receiptPath) | Where-Object { $_ -match "^$([Regex]::Escape($Name))=" })
    if ($matches.Count -ne 1) { return $null }
    return $matches[0].Substring($matches[0].IndexOf('=') + 1)
}

function Write-VolumeAdoptionReceipt([string]$DeploymentId) {
    $receiptPath = Join-Path $ScriptRoot '.oscar-volume-adoption'
    $temporaryPath = "$receiptPath.tmp.$([Guid]::NewGuid().ToString('N'))"
    $stateCreated = Get-DockerOutput @('volume', 'inspect', '--format', '{{.CreatedAt}}', 'oscar_oscar_state')
    $postgresCreated = Get-DockerOutput @('volume', 'inspect', '--format', '{{.CreatedAt}}', 'oscar_postgres_data')
    if (-not $stateCreated -or -not $postgresCreated) { throw 'Docker did not provide stable creation identities for the legacy volumes.' }
    $content = @(
        'format=oscar-volume-adoption',
        'version=1',
        "deployment_id=$DeploymentId",
        "oscar_state_created_at=$stateCreated",
        "postgres_data_created_at=$postgresCreated",
        "adopted_at=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    ) -join "`n"
    [IO.File]::WriteAllText($temporaryPath, "$content`n", $Utf8NoBom)
    Move-Item -LiteralPath $temporaryPath -Destination $receiptPath -Force
}

function Test-VolumeAdoptionReceipt([string]$DeploymentId) {
    $receiptPath = Join-Path $ScriptRoot '.oscar-volume-adoption'
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $receiptPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    $lines = @([IO.File]::ReadAllLines($receiptPath))
    if ($lines.Count -ne 6 -or @($lines | Where-Object { $_ -ceq 'format=oscar-volume-adoption' }).Count -ne 1 -or
        @($lines | Where-Object { $_ -ceq 'version=1' }).Count -ne 1 -or
        @($lines | Where-Object { $_ -match '^adopted_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' }).Count -ne 1) { return $false }
    if ((Get-AdoptionReceiptValue 'deployment_id') -cne $DeploymentId) { return $false }
    $stateCreated = Get-DockerOutput @('volume', 'inspect', '--format', '{{.CreatedAt}}', 'oscar_oscar_state')
    $postgresCreated = Get-DockerOutput @('volume', 'inspect', '--format', '{{.CreatedAt}}', 'oscar_postgres_data')
    return $stateCreated -and $postgresCreated -and
        (Get-AdoptionReceiptValue 'oscar_state_created_at') -ceq $stateCreated -and
        (Get-AdoptionReceiptValue 'postgres_data_created_at') -ceq $postgresCreated
}

function Assert-DeploymentVolumeOwnership([bool]$AllowAdoption) {
    $deploymentId = Get-ConfiguredEnvValue 'OSCAR_DEPLOYMENT_ID'
    if (-not (Test-ValidDeploymentId $deploymentId)) {
        if (-not $AllowAdoption) { throw 'OSCAR_DEPLOYMENT_ID is missing or invalid. Legacy volumes require the explicit -AdoptLegacyVolumes upgrade acknowledgment.' }
        $deploymentId = Initialize-DeploymentIdentity
    }
    foreach ($volume in @('oscar_oscar_state', 'oscar_postgres_data')) {
        if (-not (Invoke-ExternalProbe { docker volume inspect $volume })) { throw "Required Docker volume is missing: $volume." }
    }
    $stateLabel = Get-VolumeDeploymentLabel 'oscar_oscar_state'
    $postgresLabel = Get-VolumeDeploymentLabel 'oscar_postgres_data'
    if ($stateLabel -ceq $deploymentId -and $postgresLabel -ceq $deploymentId) { return }
    if ($stateLabel -cne $postgresLabel -or ($stateLabel -and $stateLabel -cne 'uninitialized')) {
        throw 'OSCAR named volumes have mixed or foreign deployment identities. Refusing to attach or mutate them.'
    }
    if (Test-VolumeAdoptionReceipt $deploymentId) { return }
    if (-not $AllowAdoption) {
        throw 'The existing volumes are unlabelled legacy state. Re-run upgrade once with -AdoptLegacyVolumes after verifying that both volumes belong to this deployment; preserve .oscar-volume-adoption with future clean-directory upgrades.'
    }
    Write-VolumeAdoptionReceipt $deploymentId
    Write-Host "Adopted legacy OSCAR volumes for deployment $deploymentId; audit receipt: $(Join-Path $ScriptRoot '.oscar-volume-adoption')" -ForegroundColor Yellow
}

function Invoke-FreshInitPreflight {
    $deploymentId = Initialize-DeploymentIdentity
    $stateExists = $false
    foreach ($volume in @('oscar_oscar_state', 'oscar_postgres_data')) {
        if (Invoke-ExternalProbe { docker volume inspect $volume }) { $stateExists = $true }
    }
    $containers = Get-DockerOutput @('ps', '-aq', '--filter', 'label=com.docker.compose.project=oscar')
    if ($containers) { $stateExists = $true }

    $receiptPath = Join-Path $ScriptRoot '.oscar-init-state'
    if (Test-Path -LiteralPath $receiptPath) {
        Assert-InitReceipt
        if ((Get-InitReceiptValue 'deployment_id') -cne $deploymentId) { throw 'The local OSCAR initialization receipt does not match .env.' }
    } elseif ($stateExists) {
        throw 'Existing Docker state for project oscar was found, but this directory did not initialize it. Use upgrade to retain that deployment. On an explicitly disposable test host, stop OSCAR and remove the old oscar project volumes before init.'
    } else {
        Write-InitReceipt $deploymentId 'INITIALIZING'
    }

    if ((Get-InitReceiptValue 'state') -ceq 'COMPLETE') {
        foreach ($volume in @('oscar_oscar_state', 'oscar_postgres_data')) {
            if (-not (Invoke-ExternalProbe { docker volume inspect $volume })) { throw "Initialized OSCAR volume is missing: $volume. Refusing to replace it silently." }
        }
    }
    foreach ($volume in @('oscar_oscar_state', 'oscar_postgres_data')) {
        if (Invoke-ExternalProbe { docker volume inspect $volume }) {
            $label = Get-VolumeDeploymentLabel $volume
            if ($label -cne $deploymentId) { throw "Docker volume $volume belongs to another or unlabelled deployment. Use upgrade, or explicitly reset this disposable test deployment." }
        }
    }
}

function Initialize-FreshDeploymentVolumes {
    Assert-InitReceipt
    $deploymentId = Initialize-DeploymentIdentity
    if ((Get-InitReceiptValue 'deployment_id') -cne $deploymentId) { throw 'The OSCAR initialization receipt does not match .env.' }
    $receiptState = Get-InitReceiptValue 'state'
    if ($receiptState -notin @('INITIALIZING', 'COMPLETE')) { throw 'The OSCAR initialization receipt state is invalid.' }
    foreach ($volume in @('oscar_oscar_state', 'oscar_postgres_data')) {
        if (-not (Invoke-ExternalProbe { docker volume inspect $volume })) {
            if ($receiptState -cne 'INITIALIZING') { throw "Initialized OSCAR volume is missing: $volume. Refusing to replace it silently." }
            Invoke-External 'docker' @('volume', 'create', '--label', "com.botts.oscar.deployment-id=$deploymentId", $volume)
        }
        if ((Get-VolumeDeploymentLabel $volume) -cne $deploymentId) {
            throw "Docker volume $volume does not belong to this OSCAR initialization."
        }
    }
}

function New-RandomPassword {
    $bytes = New-Object byte[] 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

function Read-AdminPassword {
    $fromEnvironment = [Environment]::GetEnvironmentVariable('OSCAR_SETUP_ADMIN_PASSWORD')
    if ($fromEnvironment) {
        if ($fromEnvironment.Length -lt 14) { throw 'OSCAR_SETUP_ADMIN_PASSWORD must contain at least 14 characters.' }
        return $fromEnvironment
    }
    if ($NonInteractive) { throw 'Set OSCAR_SETUP_ADMIN_PASSWORD for non-interactive initialization.' }
    Write-Host 'The administrator password must contain at least 14 characters. Input is hidden.'
    while ($true) {
        $first = Read-Host 'Initial OSCAR administrator password' -AsSecureString
        $second = Read-Host 'Confirm administrator password' -AsSecureString
        $firstPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($first)
        $secondPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($second)
        try {
            $firstText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstPtr)
            $secondText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secondPtr)
            if ($firstText.Length -lt 14) { Write-Warning 'Use at least 14 characters.'; continue }
            if ($firstText -cne $secondText) { Write-Warning 'Passwords do not match.'; continue }
            return $firstText
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstPtr)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondPtr)
        }
    }
}

function Write-SecretFile([string]$Path, [string]$Value) {
    if (Test-Path -LiteralPath $Path) { return }
    $bytes = $Utf8NoBom.GetBytes($Value)
    try {
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    } catch {
        throw "Could not create secret without replacing an existing path: $Path. $($_.Exception.Message)"
    }
}

function Assert-DeploymentPathsSafe {
    $paths = @($ScriptRoot, (Join-Path $ScriptRoot 'secrets'), (Join-Path $ScriptRoot 'tls'))
    foreach ($path in $paths) {
        $full = [IO.Path]::GetFullPath($path)
        $volume = [IO.Path]::GetPathRoot($full)
        $current = $volume
        foreach ($part in @($full.Substring($volume.Length) -split '[\\/]' | Where-Object { $_ })) {
            $current = Join-Path $current $part
            $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
            if (-not $item) { break }
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Deployment directory path is unsafe: $current"
            }
        }
    }
    foreach ($leaf in @(
        (Join-Path $ScriptRoot '.env'),
        (Join-Path $ScriptRoot 'secrets\oscar-admin-password.txt'),
        (Join-Path $ScriptRoot 'secrets\oscar-db-password.txt'),
        (Join-Path $ScriptRoot 'secrets\postgres-bootstrap-password.txt'),
        (Join-Path $ScriptRoot 'secrets\backup-key.txt'),
        (Join-Path $ScriptRoot 'tls\server.crt'),
        (Join-Path $ScriptRoot 'tls\server.key'))) {
        $item = Get-Item -LiteralPath $leaf -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Deployment credential file is unsafe: $leaf"
        }
    }
}

function Test-DockerUsersGroup {
    return (Invoke-ExternalProbe { net.exe localgroup docker-users })
}

function Set-DeploymentDirectoryAccess([string]$DockerUsersPermission) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    foreach ($directory in @((Join-Path $ScriptRoot 'secrets'), (Join-Path $ScriptRoot 'tls'))) {
        $grants = @($directory, '/inheritance:r', '/grant:r', "${identity}:(OI)(CI)F", 'SYSTEM:(OI)(CI)F')
        if (Test-DockerUsersGroup) {
            # Docker Desktop may run as the signed-in user even when OSCAR setup
            # was elevated with a different administrator account. Members of
            # docker-users already control Docker, so this does not grant Docker
            # capability to an otherwise unprivileged account.
            $grants += "docker-users:(OI)(CI)$DockerUsersPermission"
        }
        $grants += '/Q'
        Invoke-External 'icacls.exe' $grants
    }
}

function Enable-SetupDockerFileAccess {
    # Certificate generation writes through a Docker bind mount. Allow the
    # Docker Desktop group to write only while the administrator runs setup;
    # Protect-DeploymentFiles reduces this to read/execute before startup.
    Set-DeploymentDirectoryAccess 'F'
}

function Protect-DeploymentFiles {
    Set-DeploymentDirectoryAccess 'RX'
}

function Get-ReleaseVersion {
    $templatePath = Join-Path $ScriptRoot '.env.example'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw 'The release version file .env.example is missing.' }
    $match = [IO.File]::ReadAllLines($templatePath) | Where-Object { $_ -match '^OSCAR_VERSION=' } | Select-Object -First 1
    if (-not $match -or -not $match.Substring('OSCAR_VERSION='.Length).Trim()) { throw 'OSCAR_VERSION is missing from .env.example.' }
    return $match.Substring('OSCAR_VERSION='.Length).Trim()
}

function Get-OscarImage {
    $envPath = Join-Path $ScriptRoot '.env'
    $version = 'local'
    if (Test-Path -LiteralPath $envPath) {
        $match = [IO.File]::ReadAllLines($envPath) | Where-Object { $_ -match '^OSCAR_VERSION=' } | Select-Object -First 1
        if ($match) { $version = $match.Substring('OSCAR_VERSION='.Length) }
    }
    return "oscar:$version"
}

function Test-ContainerImage([string]$Image) {
    return (Invoke-ExternalProbe { docker image inspect $Image })
}

function Get-RequiredImages {
    return @(Get-ComposeOutput @('config', '--images') | Where-Object { $_ } | Select-Object -Unique)
}

function Assert-DeploymentImagesAvailable {
    $missingImages = @(Get-RequiredImages | Where-Object { -not (Test-ContainerImage $_) })
    if ($missingImages.Count -gt 0) {
        throw "Required container images are unavailable: $($missingImages -join ', '). Run 'oscar init' or 'oscar upgrade'."
    }
}

function Prepare-DeploymentImages {
    $requiredImages = @(Get-RequiredImages)
    $offlineArchive = Join-Path $ScriptRoot 'offline-images.tar'
    if (Test-Path -LiteralPath $offlineArchive -PathType Leaf) {
        # A local tag does not authenticate its image bytes. The bundle was
        # checksum-verified for this mutating setup run, so always load its
        # image archive before checking the required inventory.
        Write-Heading 'Importing offline container images'
        Invoke-External 'docker' @('load', '--input', $offlineArchive)
    } else {
        $missingImages = @($requiredImages | Where-Object { -not (Test-ContainerImage $_) })
        if ($missingImages.Count -eq 0) { return }
        Write-Heading 'Building deployment images'
        Invoke-Compose @('build', 'oscar', 'postgres')
        Invoke-Compose @('pull', 'gateway')
    }

    $missingImages = @($requiredImages | Where-Object { -not (Test-ContainerImage $_) })
    if ($missingImages.Count -gt 0) { throw "Required container images are unavailable: $($missingImages -join ', ')" }
}

function Initialize-Tls([string]$Name) {
    $tlsDirectory = Join-Path $ScriptRoot 'tls'
    $certificate = Join-Path $tlsDirectory 'server.crt'
    $privateKey = Join-Path $tlsDirectory 'server.key'
    $hasCertificate = Test-Path -LiteralPath $certificate
    $hasPrivateKey = Test-Path -LiteralPath $privateKey
    if ($hasCertificate -xor $hasPrivateKey) {
        throw 'TLS setup is incomplete. Remove the partial certificate/key pair or provide both files.'
    }

    if (-not $hasCertificate) {
        if ($TlsMode -eq 'import') {
            $sourceCertificate = Read-RequiredValue 'Certificate PEM path' $CertificatePath
            $sourceKey = Read-RequiredValue 'Unencrypted private-key PEM path' $PrivateKeyPath
            Copy-Item -LiteralPath $sourceCertificate -Destination $certificate
            Copy-Item -LiteralPath $sourceKey -Destination $privateKey
        } else {
            $parsedIp = $null
            $sanType = if ([Net.IPAddress]::TryParse($Name, [ref]$parsedIp)) { 'IP' } else { 'DNS' }
            $image = Get-OscarImage
            Invoke-External 'docker' @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--tmpfs', '/tmp:rw,noexec,nosuid,nodev', '--user', '0:0', '--entrypoint', 'openssl', '--volume', "${tlsDirectory}:/out", $image,
                'req', '-x509', '-newkey', 'rsa:3072', '-sha256', '-nodes', '-days', '365', '-subj', "/CN=$Name", '-addext', "subjectAltName=${sanType}:$Name", '-keyout', '/out/server.key', '-out', '/out/server.crt')
        }
    }

    $image = Get-OscarImage
    # OpenSSL creates private keys as root with mode 0600. Docker Compose file
    # secrets are consumed by deliberately non-root services, so normalize the
    # container-visible mode after generation or import. The protected Windows
    # parent-directory ACL still limits host access to the administrator and
    # Docker service.
    Invoke-External 'docker' @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--tmpfs', '/tmp:rw,noexec,nosuid,nodev', '--user', '0:0', '--entrypoint', 'chmod', '--volume', "${tlsDirectory}:/tls", $image,
        '0444', '/tls/server.crt', '/tls/server.key')
    Invoke-External 'docker' @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--tmpfs', '/tmp:rw,noexec,nosuid,nodev', '--user', '0:0', '--entrypoint', 'sh', '--volume', "${tlsDirectory}:/tls:ro", $image, '-c',
        'openssl x509 -in /tls/server.crt -pubkey -noout >/tmp/cert.pub && openssl pkey -in /tls/server.key -pubout >/tmp/key.pub && cmp -s /tmp/cert.pub /tmp/key.pub')
    $parsedIp = $null
    $nameCheck = if ([Net.IPAddress]::TryParse($Name, [ref]$parsedIp)) { '-checkip' } else { '-checkhost' }
    # openssl x509 -checkhost/-checkip exits zero even when its text reports a
    # mismatch, so the shell must explicitly classify the result.
    $nameCommand = 'output=$(openssl x509 -in /tls/server.crt -noout "$1" "$2"); printf "%s\n" "$output"; case $output in *" does match certificate") ;; *) exit 1 ;; esac'
    Invoke-External 'docker' @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--tmpfs', '/tmp:rw,noexec,nosuid,nodev', '--user', '0:0', '--entrypoint', 'sh', '--volume', "${tlsDirectory}:/tls:ro", $image,
        '-eu', '-c', $nameCommand, 'tls-name-check', $nameCheck, $Name)
}

function Remove-LegacyEmbeddedBackupDirectory {
    Invoke-Compose @('stop', 'gateway', 'oscar')
    $script = 'if [ -e /state/backups ] || [ -L /state/backups ]; then [ -d /state/backups ] && [ ! -L /state/backups ] || { echo "Legacy embedded backup path is not a regular directory." >&2; exit 1; }; rmdir -- /state/backups || { echo "Legacy embedded /var/lib/oscar/backups is nonempty. Preserve or export its contents, explicitly empty that non-authoritative volume path, then retry upgrade." >&2; exit 1; }; fi'
    Invoke-External 'docker' @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--user', '10001:10001', '--entrypoint', 'sh', '--volume', 'oscar_oscar_state:/state', (Get-OscarImage), '-eu', '-c', $script)
}

function Add-LocalHostsMapping([string]$Name) {
    $parsedIp = $null
    if ([Net.IPAddress]::TryParse($Name, [ref]$parsedIp)) { return }
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $existing = [IO.File]::ReadAllText($hostsPath)
    if ($existing -match "(?m)^\s*127\.0\.0\.1\s+.*\b$([Regex]::Escape($Name))\b") { return }
    [IO.File]::AppendAllText($hostsPath, "`r`n127.0.0.1`t$Name`t# OSCAR setup`r`n", $Utf8NoBom)
}

function Assert-BaseConfigured {
    foreach ($relativePath in @('secrets\oscar-admin-password.txt', 'secrets\oscar-db-password.txt', 'secrets\postgres-bootstrap-password.txt', 'tls\server.crt', 'tls\server.key', '.env')) {
        $path = Join-Path $ScriptRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) { throw "Missing required setup file: $relativePath" }
    }
}

function Assert-Configured {
    Assert-BaseConfigured
    $backupKey = Join-Path $ScriptRoot 'secrets\backup-key.txt'
    if (-not (Test-Path -LiteralPath $backupKey -PathType Leaf) -or (Get-Item -LiteralPath $backupKey).Length -eq 0) {
        throw "Missing required setup file: secrets\backup-key.txt. Run upgrade to initialize $(Get-ReleaseVersion) storage protection."
    }
}

function Invoke-StorageCommand([string]$StorageCommand, [string]$StorageSubcommand) {
    $storageScript = Join-Path $ScriptRoot 'oscar-storage.ps1'
    if (-not (Test-Path -LiteralPath $storageScript -PathType Leaf)) { throw 'The OSCAR storage administration script is missing.' }
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $storageScript, '-Command', $StorageCommand)
    if ($StorageCommand -eq 'archive') {
        $arguments += @('-Action', $(if ($StorageSubcommand) { $StorageSubcommand } else { 'status' }))
        if ($HoldAction) { $arguments += @('-HoldAction', $HoldAction) }
    }
    if ($StorageCommand -eq 'prepare-directories' -and $Command -eq 'upgrade' -and $AdoptLegacyStorageRoots) {
        $arguments += '-AdoptExistingStorageRoots'
    }
    foreach ($pair in @(
        @('BackupId', $BackupId), @('Confirm', $Confirm), @('Before', $Before), @('RequestedBy', $RequestedBy),
        @('Plan', $Plan), @('Token', $Token), @('Generation', $Generation), @('Destination', $Destination),
        @('Observation', $Observation), @('StoreKey', $StoreKey), @('IdScope', $IdScope),
        @('HoldId', $HoldId), @('Reason', $Reason), @('CreatedBy', $CreatedBy),
        @('ReleasedBy', $ReleasedBy), @('Keep', $(if ($Keep -gt 0) { "$Keep" } else { $null })))) {
        if ($pair[1]) { $arguments += @("-$($pair[0])", $pair[1]) }
    }
    Invoke-External 'powershell.exe' $arguments
}

function Clear-ComposeOverrideEnvironment {
    $saved = @{}
    foreach ($name in @(
        'COMPOSE_FILE', 'COMPOSE_PROJECT_NAME', 'COMPOSE_ENV_FILES', 'COMPOSE_PROFILES',
        'OSCAR_VERSION', 'OSCAR_DEPLOYMENT_ID', 'OSCAR_ARCHIVE_DIR', 'OSCAR_BACKUP_DIR',
        'OSCAR_WAL_ARCHIVE_DIR', 'OSCAR_SECRETS_DIR', 'OSCAR_TLS_DIR', 'OSCAR_BACKUP_KEY_FILE',
        'OSCAR_HTTPS_PORT', 'OSCAR_JAVA_OPTS', 'OSCAR_POSTGIS_PLATFORM')) {
        if (Test-Path -LiteralPath "Env:$name") {
            $saved[$name] = (Get-Item -LiteralPath "Env:$name").Value
            Remove-Item -LiteralPath "Env:$name"
        }
    }
    return $saved
}

function Restore-ComposeOverrideEnvironment([hashtable]$Saved) {
    foreach ($name in $Saved.Keys) { Set-Item -LiteralPath "Env:$name" -Value $Saved[$name] }
}

function Invoke-Compose([string[]]$Arguments) {
    Assert-DeploymentPathsSafe
    Assert-ManagedEnvironmentBindings
    Push-Location $ScriptRoot
    $saved = Clear-ComposeOverrideEnvironment
    try {
        Invoke-External 'docker' (@(
            'compose', '--project-name', 'oscar', '--env-file', (Join-Path $ScriptRoot '.env'),
            '--file', (Join-Path $ScriptRoot 'compose.yaml')) + $Arguments)
    } finally {
        Restore-ComposeOverrideEnvironment $saved
        Pop-Location
    }
}

function Get-ComposeOutput([string[]]$Arguments) {
    Assert-DeploymentPathsSafe
    Assert-ManagedEnvironmentBindings
    Push-Location $ScriptRoot
    $saved = Clear-ComposeOverrideEnvironment
    try {
        $pinned = @(
            'compose', '--project-name', 'oscar', '--env-file', (Join-Path $ScriptRoot '.env'),
            '--file', (Join-Path $ScriptRoot 'compose.yaml')) + $Arguments
        $output = @(& docker @pinned)
        if ($LASTEXITCODE -ne 0) { throw "docker compose exited with code $LASTEXITCODE." }
        return $output
    } finally {
        Restore-ComposeOverrideEnvironment $saved
        Pop-Location
    }
}

function Invoke-BootstrapSql([string]$Sql) {
    $wrapper = 'PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password); export PGPASSWORD; exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"'
    $output = Get-ComposeOutput @('exec', '-T', 'postgres', 'sh', '-eu', '-c', $wrapper, 'psql-wrapper', '--tuples-only', '--no-align', '--command', $Sql)
    return (($output -join "`n").Trim())
}

function Enable-StorageDatabaseFeatures {
    Invoke-BootstrapSql 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;' | Out-Null
    $checksums = Invoke-BootstrapSql 'SHOW data_checksums;'
    if ($checksums -cne 'on') {
        Write-Warning "PostgreSQL data checksums are disabled. OSCAR $(Get-ReleaseVersion) enables them on fresh databases; rebuild this test/production database before relying on checksum protection."
    }
}

function Complete-PendingFreshInit {
    $receiptPath = Join-Path $ScriptRoot '.oscar-init-state'
    if (-not (Test-Path -LiteralPath $receiptPath)) { return }
    Assert-InitReceipt
    $deploymentId = Initialize-DeploymentIdentity
    if ((Get-InitReceiptValue 'deployment_id') -cne $deploymentId) { throw 'The OSCAR initialization receipt does not match .env.' }
    if ((Get-InitReceiptValue 'state') -cne 'INITIALIZING') { return }

    foreach ($volume in @('oscar_oscar_state', 'oscar_postgres_data')) {
        if (-not (Invoke-ExternalProbe { docker volume inspect $volume })) { throw "Fresh initialization did not create required Docker volume: $volume" }
        $label = Get-VolumeDeploymentLabel $volume
        if ($label -cne $deploymentId) { throw "Docker volume $volume does not belong to this OSCAR initialization." }
    }

    $expectedVersion = Get-ReleaseVersion
    if ((Invoke-BootstrapSql 'SHOW data_checksums;') -cne 'on') { throw "Fresh OSCAR $expectedVersion initialization requires PostgreSQL data checksums." }
    $markerCheck = @'
marker=/var/lib/postgresql/data/.oscar-data-checksum-init
test -f "$marker" && test ! -L "$marker"
test "$(wc -l <"$marker" | tr -d "[:space:]")" = 4
test "$(grep -Fxc format=oscar-storage-profile "$marker")" = 1
test "$(grep -Fxc "version=$1" "$marker")" = 1
test "$(grep -Fxc data_checksums=on "$marker")" = 1
test "$(grep -Ec '^initialized_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$marker")" = 1
'@
    Invoke-Compose @('exec', '-T', 'postgres', 'sh', '-eu', '-c', $markerCheck, 'profile-check', $expectedVersion)
    $configCheck = @'
config=/var/lib/oscar/config.json
test -f "$config" && test ! -L "$config"
grep -Fq '"objClass": "com.botts.impl.service.dailyfile.DailyFileJournalServiceConfig"' "$config"
grep -Fq '"objClass": "org.sensorhub.impl.datastore.postgis.database.OscarTieredObsSystemDatabaseConfig"' "$config"
grep -Fq '"frameRetentionCount": 5' "$config"
'@
    $configReady = $false
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            Invoke-Compose @('exec', '-T', 'oscar', 'sh', '-eu', '-c', $configCheck) *> $null
            $configReady = $true
        } catch { $configReady = $false }
        if ($configReady) { break }
        if ($attempt -lt 30) { Start-Sleep -Seconds 1 }
    }
    if (-not $configReady) { throw "The saved OSCAR configuration does not contain the complete $expectedVersion storage profile after 30 seconds." }
    $imageLabel = Get-DockerOutput @('image', 'inspect', (Get-OscarImage), '--format', '{{ index .Config.Labels "org.opencontainers.image.version" }}')
    if ($imageLabel -cne $expectedVersion) { throw "The selected OSCAR image is not labeled $expectedVersion (received: $(if ($imageLabel) { $imageLabel } else { 'missing' }))." }
    $postgresImage = @(Get-RequiredImages | Where-Object { $_ -match '(^|/)oscar-postgis:' } | Select-Object -First 1)
    if ($postgresImage.Count -ne 1) { throw 'The Compose model does not identify exactly one OSCAR PostGIS image.' }
    $postgresLabel = Get-DockerOutput @('image', 'inspect', $postgresImage[0], '--format', '{{ index .Config.Labels "org.opencontainers.image.version" }}')
    $postgresProfile = Get-DockerOutput @('image', 'inspect', $postgresImage[0], '--format', '{{ index .Config.Labels "com.botts.oscar.storage-profile" }}')
    if ($postgresLabel -cne $expectedVersion -or $postgresProfile -cne $expectedVersion) { throw "The selected PostGIS image does not carry the OSCAR $expectedVersion storage-profile labels." }
    Write-InitReceipt $deploymentId 'COMPLETE'
}

function Get-ConfiguredEndpoint {
    $hostnameValue = 'oscar.local'
    $portValue = '443'
    $envPath = Join-Path $ScriptRoot '.env'
    if (Test-Path -LiteralPath $envPath -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($envPath)) {
            if ($line -match '^OSCAR_HOSTNAME=(.*)$' -and $Matches[1]) { $hostnameValue = $Matches[1] }
            if ($line -match '^OSCAR_HTTPS_PORT=(.*)$' -and $Matches[1]) { $portValue = $Matches[1] }
        }
    }
    return "https://${hostnameValue}:$portValue/sensorhub/admin"
}

function Show-Help {
    @'
OSCAR deployment administration

  .\oscar.bat init [-Hostname oscar.local] [-Port 443]
      [-TlsMode self-signed|import] [-CertificatePath FILE -PrivateKeyPath FILE]
      [-AddHostsEntry] [-SkipHostsEntry] [-SkipStart]
      [-Prerequisites auto|existing|bundled]
  .\oscar.bat check|verify|start|stop|restart|status
  .\oscar.bat upgrade [-AdoptLegacyVolumes] [-AdoptLegacyStorageRoots]
  .\oscar.bat logs [-Service all|oscar|postgres|gateway] [-Tail 200] [-Follow]
  .\oscar.bat backup
  .\oscar.bat backup-verify -BackupId ID
  .\oscar.bat backup-prune [-Keep COUNT]
  .\oscar.bat restore -BackupId ID -Confirm ID
  .\oscar.bat archive status|verify
  .\oscar.bat archive hold list
  .\oscar.bat archive hold create -StoreKey KEY -IdScope INT (-Generation UUID | -Observation ID) -Reason TEXT
  .\oscar.bat archive hold release -HoldId UUID
  .\oscar.bat archive dry-run -StoreKey KEY -IdScope INT -Before YYYY-MM-DDTHH:MM:SSZ
  .\oscar.bat archive purge -StoreKey KEY -IdScope INT -Plan UUID -Token TOKEN
  .\oscar.bat archive export -StoreKey KEY -IdScope INT -Generation UUID -Destination PATH

Double-click oscar.bat with no arguments for the elevated interactive menu.
Direct mutating commands require an Administrator PowerShell window. For automated
setup, use -NonInteractive and provide OSCAR_SETUP_ADMIN_PASSWORD in the environment.
'@ | Write-Host
}

try {
    switch ($Command) {
        'help' { Show-Help }
        'check' {
            Write-Heading 'Prerequisite check'
            Write-Host "Administrator: $(Test-Administrator)"
            Write-Host "Docker CLI: $([bool](Get-Command docker -ErrorAction SilentlyContinue))"
            Write-Host "Docker ready: $(Test-DockerReady)"
            Write-Host "WSL ready: $(Test-WslReady)"
            Write-Host "Offline bundle: $(Test-Path -LiteralPath (Join-Path $ScriptRoot 'offline-images.tar') -PathType Leaf)"
            Write-Host "Bundle verification: $(Get-OfflineBundleVerificationStatus)"
            Write-Host "Configured: $(try { Assert-Configured; $true } catch { $false })"
            # TODO(offline-maps): add MBTiles validation/import after deployment requirements are defined.
        }
        'verify' {
            Assert-Administrator
            Assert-DeploymentPathsSafe
            if (-not (Get-OfflineBundleManifestHash)) { throw 'SHA256SUMS is missing. This is not a complete offline bundle.' }
            Assert-OfflineBundleIntegrity -Force
        }
        'init' {
            Assert-Administrator
            Assert-DeploymentPathsSafe
            Assert-OfflineBundleIntegrity
            Assert-Docker
            if (-not $Hostname) {
                if ($NonInteractive) { throw 'Hostname is required in non-interactive mode.' }
                $Hostname = (Read-Host 'Hostname or IP address [oscar.local]').Trim()
                if (-not $Hostname) { $Hostname = 'oscar.local' }
            }
            if (-not (Test-ValidHostname $Hostname)) { throw "Invalid hostname or IP address: $Hostname" }
            if ($Port -eq 80) { throw 'Port 80 is reserved for the HTTP-to-HTTPS redirect.' }
            New-Item -ItemType Directory -Force -Path (Join-Path $ScriptRoot 'secrets'), (Join-Path $ScriptRoot 'tls') | Out-Null
            Set-EnvValue 'OSCAR_VERSION' (Get-ReleaseVersion)
            Set-EnvValue 'OSCAR_HTTPS_PORT' $Port
            Set-EnvValue 'OSCAR_HOSTNAME' $Hostname
            Assert-CanonicalCredentialBindings
            Initialize-StoragePaths
            Invoke-FreshInitPreflight
            Initialize-FreshDeploymentVolumes
            Assert-ManagedEnvironmentBindings
            $adminSecretPath = Join-Path $ScriptRoot 'secrets\oscar-admin-password.txt'
            $databaseSecretPath = Join-Path $ScriptRoot 'secrets\oscar-db-password.txt'
            $bootstrapSecretPath = Join-Path $ScriptRoot 'secrets\postgres-bootstrap-password.txt'
            $backupKeyPath = Join-Path $ScriptRoot 'secrets\backup-key.txt'
            if (-not (Test-Path -LiteralPath $adminSecretPath)) { Write-SecretFile $adminSecretPath (Read-AdminPassword) }
            if (-not (Test-Path -LiteralPath $databaseSecretPath)) { Write-SecretFile $databaseSecretPath (New-RandomPassword) }
            if (-not (Test-Path -LiteralPath $bootstrapSecretPath)) { Write-SecretFile $bootstrapSecretPath (New-RandomPassword) }
            if (-not (Test-Path -LiteralPath $backupKeyPath)) { Write-SecretFile $backupKeyPath "$(New-RandomPassword)$(New-RandomPassword)" }
            Enable-SetupDockerFileAccess
            Prepare-DeploymentImages
            Invoke-StorageCommand 'prepare-directories' $null
            Initialize-Tls $Hostname
            Protect-DeploymentFiles
            if (-not $SkipHostsEntry) { Add-LocalHostsMapping $Hostname }
            Assert-Configured
            if (-not $SkipStart) {
                Invoke-Compose @('up', '--detach', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '240')
                Enable-StorageDatabaseFeatures
                Complete-PendingFreshInit
            }
            Write-Host "`nOSCAR setup complete: https://${Hostname}:$Port/sensorhub/admin" -ForegroundColor Green
        }
        'start' {
            Assert-Administrator; Assert-Docker; Assert-Configured
            Assert-DeploymentVolumeOwnership $false
            Assert-DeploymentImagesAvailable
            Invoke-Compose @('up', '--detach', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '240')
            Enable-StorageDatabaseFeatures
            Complete-PendingFreshInit
        }
        'stop' {
            Assert-Administrator; Assert-Docker; Assert-Configured
            Invoke-Compose @('stop')
            Write-Host 'OSCAR stopped. Persistent application and database data were retained.' -ForegroundColor Green
        }
        'restart' {
            Assert-Administrator; Assert-Docker; Assert-Configured; Assert-DeploymentImagesAvailable
            Assert-DeploymentVolumeOwnership $false
            Invoke-Compose @('restart')
            Invoke-Compose @('up', '--detach', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '240')
            Enable-StorageDatabaseFeatures
            Complete-PendingFreshInit
        }
        'status' {
            Assert-Docker
            Invoke-Compose @('ps')
            $isConfigured = $true
            try { Assert-Configured } catch { $isConfigured = $false }
            if ($isConfigured) { Write-Host "OSCAR URL: $(Get-ConfiguredEndpoint)" }
        }
        'logs' {
            Assert-Docker; Assert-Configured
            $logArguments = @('logs', '--tail', "$Tail")
            if ($Follow) { $logArguments += '--follow' }
            if ($Service -ne 'all') { $logArguments += $Service }
            Invoke-Compose $logArguments
        }
        'upgrade' {
            Assert-Administrator
            Assert-DeploymentPathsSafe
            Assert-OfflineBundleIntegrity
            Assert-Docker; Assert-BaseConfigured
            Assert-UpgradeableEnvironmentBindings
            Write-Heading 'Upgrade preflight'
            Initialize-LegacyBackupKeyBinding
            Assert-CanonicalCredentialBindings
            Assert-DeploymentVolumeOwnership ([bool]$AdoptLegacyVolumes)
            Initialize-StoragePaths
            Assert-UniqueLiteralEnvironmentKeys
            $releaseVersion = Get-ReleaseVersion
            Set-EnvValue 'OSCAR_VERSION' $releaseVersion
            Assert-ManagedEnvironmentBindings
            $backupKeyPath = Join-Path $ScriptRoot 'secrets\backup-key.txt'
            if (-not (Test-Path -LiteralPath $backupKeyPath)) { Write-SecretFile $backupKeyPath "$(New-RandomPassword)$(New-RandomPassword)" }
            Protect-DeploymentFiles
            Write-Host "Preparing OSCAR $releaseVersion"
            Prepare-DeploymentImages
            Invoke-StorageCommand 'prepare-directories' $null
            Remove-LegacyEmbeddedBackupDirectory
            Invoke-Compose @('config', '--quiet')
            Invoke-Compose @('up', '--detach', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '240')
            Enable-StorageDatabaseFeatures
            Complete-PendingFreshInit
            Write-Host 'Upgrade deployment completed. Persistent OSCAR and PostgreSQL volumes were retained.' -ForegroundColor Green
        }
        'backup' { Invoke-StorageCommand 'backup' $null }
        'backup-prune' { Invoke-StorageCommand 'backup-prune' $null }
        'backup-verify' {
            if (-not $BackupId -and $StorageAction) { $BackupId = $StorageAction }
            Invoke-StorageCommand 'backup-verify' $null
        }
        'restore' { Invoke-StorageCommand 'restore' $null }
        'archive' { Invoke-StorageCommand 'archive' $StorageAction }
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
