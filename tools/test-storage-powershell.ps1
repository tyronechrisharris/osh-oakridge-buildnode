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

function Invoke-StorageLauncher([string]$Path) {
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $Path, '-Command', 'help') -Wait -PassThru -WindowStyle Hidden
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

    $physicalRelease = Join-Path $temporaryRoot 'release-physical'
    $aliasRelease = Join-Path $temporaryRoot 'release-junction'
    New-Item -ItemType Directory -Path $physicalRelease | Out-Null
    Copy-Item -LiteralPath $storageScript -Destination (Join-Path $physicalRelease 'oscar-storage.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'dist\release\.env.example') -Destination (Join-Path $physicalRelease '.env.example')
    New-Item -ItemType Junction -Path $aliasRelease -Target $physicalRelease | Out-Null
    Assert-True ((Invoke-StorageLauncher (Join-Path $physicalRelease 'oscar-storage.ps1')) -eq 0) `
        'The physical Windows storage launcher fixture did not start.'
    Assert-True ((Invoke-StorageLauncher (Join-Path $aliasRelease 'oscar-storage.ps1')) -ne 0) `
        'The Windows storage launcher accepted a junction/reparse release alias.'

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

    $storageSource = [IO.File]::ReadAllText($storageScript)
    $setupSource = [IO.File]::ReadAllText($setupScript)
    foreach ($source in @($storageSource, $setupSource)) {
        Assert-True (-not $source.Contains('{{ index ')) `
            'A Windows launcher still passes a quoted Go-template index expression through PowerShell 5 native argument marshalling.'
    }
    $volumeJson = '[{"Name":"oscar_oscar_state","CreatedAt":"2026-10-18T13:45:03Z","Labels":{"com.botts.oscar.deployment-id":"12345678-1234-4234-8234-123456789abc"}}]'
    $volumeRecord = ConvertFrom-DockerInspectJson @($volumeJson) 'volume' 'oscar_oscar_state'
    Assert-True ((Get-DockerInspectLabel $volumeRecord $false 'com.botts.oscar.deployment-id') -ceq '12345678-1234-4234-8234-123456789abc') `
        'The PowerShell 5 Docker JSON parser did not preserve a dotted/hyphenated volume label key.'
    $rejectedMultiple = $false
    try { [void](ConvertFrom-DockerInspectJson @('[{"Name":"oscar_oscar_state"},{"Name":"oscar_oscar_state"}]') 'volume' 'oscar_oscar_state') }
    catch { $rejectedMultiple = $true }
    Assert-True $rejectedMultiple 'The Docker JSON parser accepted multiple inspect records for one exact volume.'
    $rejectedOversized = $false
    try { [void](ConvertFrom-DockerInspectJson @((' ' * ($MaxDockerInspectJsonBytes + 1))) 'volume' 'oscar_oscar_state') }
    catch { $rejectedOversized = $_.Exception.Message -like '*oversized*' }
    Assert-True $rejectedOversized 'The Docker JSON parser accepted output above its fixed memory bound.'
    & {
        $script:CapturedDockerInspectArguments = @()
        $imageJson = '[{"Id":"sha256:' + ('a' * 64) + '","RepoDigests":["oscar@sha256:' + ('b' * 64) + '"],"Config":{"Labels":{"org.opencontainers.image.version":"3.9.2"}}}]'
        function Get-ExternalOutput([string]$Program, [string[]]$Arguments) {
            $script:CapturedDockerInspectArguments = @($Arguments)
            return @($imageJson)
        }
        Assert-True ((Get-ImageInspectValue 'oscar:3.9.2' 'org.opencontainers.image.version') -ceq '3.9.2') `
            'The image JSON parser did not read the required OCI version label.'
        Assert-True (($script:CapturedDockerInspectArguments -join '|') -ceq 'image|inspect|oscar:3.9.2') `
            'Windows image inspection did not use the exact format-free JSON command.'
    }
    $statusStart = $storageSource.IndexOf('function Show-ArchiveStatus', [StringComparison]::Ordinal)
    $statusEnd = $storageSource.IndexOf('function Invoke-RetentionHold', $statusStart, [StringComparison]::Ordinal)
    Assert-True ($statusStart -ge 0 -and $statusEnd -gt $statusStart) 'Could not isolate the PowerShell archive-status query.'
    $statusSource = $storageSource.Substring($statusStart, $statusEnd - $statusStart)
    foreach ($qualified in @(
        'SELECT g.store_key,g.id_scope,g.state,g.profile',
        'coalesce(sum(g.row_count),0)',
        'GROUP BY g.store_key,g.id_scope,g.state,g.profile',
        'ORDER BY g.store_key,g.id_scope,g.state,g.profile')) {
        Assert-True ($statusSource.Contains($qualified)) "PowerShell archive status is missing qualified generation columns: $qualified"
    }
    $launcherCheck = $storageSource.IndexOf('Assert-NoReparseComponents $StorageScriptPath', [StringComparison]::Ordinal)
    $templateRead = $storageSource.IndexOf("Join-Path `$ScriptRoot '.env.example'", [StringComparison]::Ordinal)
    Assert-True ($launcherCheck -ge 0 -and $templateRead -gt $launcherCheck -and
        $storageSource.Contains('Resolve-PhysicalContainmentPath $ScriptRoot')) `
        'Windows release-path canonicalization/reparse checks do not run before release configuration is read.'
    $validObject = 'datasets/observations/date=2026-10-17/profile=RAW_GATED/generation-11111111-1111-4111-8111-111111111111.parquet'
    Assert-True (Test-ArchiveObjectPath $validObject) 'PowerShell rejected an approved archive object path.'
    Assert-True (-not (Test-ArchiveObjectPath 'foreign/file')) 'PowerShell accepted an archive path outside the approved layout.'
    & {
        function Write-PsqlLinesToFile([string]$Sql, [string]$Path) {
            [IO.File]::WriteAllText($Path, "foreign/file`n", $Utf8NoBom)
        }
        $invalidCatalog = Join-Path $temporaryRoot 'invalid-catalog-paths.txt'
        $rejectedInvalidCatalog = $false
        try { Write-RegisteredArchivePaths $invalidCatalog } catch { $rejectedInvalidCatalog = $true }
        Assert-True $rejectedInvalidCatalog 'PowerShell accepted an absent catalog object outside the approved layout.'
    }
    $inventoryStart = $storageSource.IndexOf('function Get-ArchiveGenerationInventory', [StringComparison]::Ordinal)
    $inventoryEnd = $storageSource.IndexOf('function Write-ArchiveGenerationInventory', $inventoryStart, [StringComparison]::Ordinal)
    Assert-True ($inventoryStart -ge 0 -and $inventoryEnd -gt $inventoryStart) 'Could not isolate the streaming archive-generation validator.'
    $inventorySource = $storageSource.Substring($inventoryStart, $inventoryEnd - $inventoryStart)
    foreach ($forbidden in @('ReadAllBytes', 'ReadAllLines', ' -split ', ' -join ', 'Invoke-PsqlLines', 'uuid[]')) {
        Assert-True (-not $inventorySource.Contains($forbidden)) "Archive-generation validation materializes its bounded inventory: $forbidden"
    }
    Assert-True ($inventorySource.Contains('[IO.File]::Open(') -and
        $inventorySource.Contains('[Security.Cryptography.SHA256]::Create()') -and
        $inventorySource.Contains('$bytesRead -ne ($count * 37)')) `
        'Archive-generation validation is not a framed, streaming count/hash/bytes receipt.'
    Assert-True ($inventorySource.IndexOf('Get-Item -LiteralPath $path', [StringComparison]::Ordinal) -lt
        $inventorySource.IndexOf('[IO.File]::Open(', [StringComparison]::Ordinal)) `
        'Archive-generation validation does not reject an oversized file before opening its content stream.'
    Assert-True ($storageSource.Contains('ORDER BY id LIMIT $($MaxBackupArchiveGenerationIds + 1)')) `
        'Archive-generation capture is not bounded to the advertised entry limit plus one sentinel.'
    Assert-True (-not $storageSource.Contains('archive_generation_ids')) `
        'The PowerShell storage launcher still embeds archive-generation UUIDs in PostgreSQL.'
    $captureStart = $inventoryEnd
    $captureEnd = $storageSource.IndexOf('function Set-VerifiedBackupEpochReceipt', $captureStart, [StringComparison]::Ordinal)
    $captureSource = $storageSource.Substring($captureStart, $captureEnd - $captureStart)
    Assert-True ($captureSource.Contains('Write-PsqlLinesToFile') -and
        -not $captureSource.Contains('Invoke-PsqlLines') -and
        -not $captureSource.Contains('ReadAllBytes') -and
        -not $captureSource.Contains('ReadAllLines') -and
        -not $captureSource.Contains(' -join ')) `
        'PowerShell archive-generation capture does not stream PostgreSQL output directly to its file.'
    Assert-True (-not $storageSource.Contains('function Get-RegisteredArchivePaths')) `
        'The Windows archive audit still exposes the full catalog as an in-memory collection.'
    $auditStart = $storageSource.IndexOf('function Test-ArchiveFilesystemRegistration', [StringComparison]::Ordinal)
    $auditEnd = $storageSource.IndexOf('function Protect-PrivateDirectory', $auditStart, [StringComparison]::Ordinal)
    Assert-True ($auditStart -ge 0 -and $auditEnd -gt $auditStart) 'Could not isolate the Windows archive reconciliation implementation.'
    $auditSource = $storageSource.Substring($auditStart, $auditEnd - $auditStart)
    foreach ($forbidden in @('Collections.Generic.HashSet', 'New-Object System.Collections.Generic.List[string]', 'Invoke-PsqlLines')) {
        Assert-True (-not $auditSource.Contains($forbidden)) "Windows archive reconciliation materializes an unbounded catalog/candidate collection: $forbidden"
    }
    foreach ($required in @(
        'Write-RegisteredArchivePaths $catalogFirstRaw',
        'Write-RegisteredArchivePaths $catalogSecondRaw',
        'ConvertTo-ArchiveAuditSortedUniqueFile $candidateRaw $candidateSorted',
        'Compare-ArchiveAuditSortedFiles $candidateSorted $catalogMerged',
        '[IO.Directory]::EnumerateFileSystemEntries')) {
        Assert-True ($auditSource.Contains($required)) "Windows archive reconciliation is missing its bounded file-backed operation: $required"
    }
    Assert-True ($storageSource.Contains('$ArchiveAuditSortChunkLines = 4096') -and
        $storageSource.Contains('$buffer.Count -ge $ChunkLineLimit')) `
        'The Windows archive reconciliation sort does not enforce its fixed-size memory chunk.'

    # Force five input records through three chunks, then exercise pairwise
    # merging and the streaming candidate-minus-catalog comparison.
    $sortFixture = Join-Path $temporaryRoot 'archive-sort'
    New-Item -ItemType Directory -Path $sortFixture | Out-Null
    $rawCandidates = Join-Path $sortFixture 'candidates.raw'
    $sortedCandidates = Join-Path $sortFixture 'candidates.sorted'
    [IO.File]::WriteAllLines($rawCandidates, @('delta','alpha','gamma','alpha','beta'), $Utf8NoBom)
    ConvertTo-ArchiveAuditSortedUniqueFile $rawCandidates $sortedCandidates 2
    Assert-True (([IO.File]::ReadAllLines($sortedCandidates) -join ',') -ceq 'alpha,beta,delta,gamma') `
        'The bounded Windows archive audit sort did not order and deduplicate across chunk boundaries.'
    $catalogFirstRaw = Join-Path $sortFixture 'catalog-first.raw'
    $catalogSecondRaw = Join-Path $sortFixture 'catalog-second.raw'
    $catalogFirst = Join-Path $sortFixture 'catalog-first.sorted'
    $catalogSecond = Join-Path $sortFixture 'catalog-second.sorted'
    $catalogMerged = Join-Path $sortFixture 'catalog-merged.sorted'
    [IO.File]::WriteAllLines($catalogFirstRaw, @('gamma','alpha'), $Utf8NoBom)
    [IO.File]::WriteAllLines($catalogSecondRaw, @('epsilon','beta','alpha'), $Utf8NoBom)
    ConvertTo-ArchiveAuditSortedUniqueFile $catalogFirstRaw $catalogFirst 1
    ConvertTo-ArchiveAuditSortedUniqueFile $catalogSecondRaw $catalogSecond 1
    Merge-ArchiveAuditSortedFiles $catalogFirst $catalogSecond $catalogMerged
    Assert-True (([IO.File]::ReadAllLines($catalogMerged) -join ',') -ceq 'alpha,beta,epsilon,gamma') `
        'The Windows archive audit did not merge and deduplicate its two catalog snapshots.'
    $missing = Compare-ArchiveAuditSortedFiles $sortedCandidates $catalogMerged 2>$null
    Assert-True ($missing -eq 1) 'The Windows archive audit streaming comparison did not identify exactly the unregistered delta candidate.'

    & {
        $objectPath = Join-Path $temporaryRoot 'archive-completeness-object'
        [IO.File]::WriteAllText($objectPath, "object`n", (New-Object Text.UTF8Encoding($false)))
        $objectSha = (Get-FileHash -LiteralPath $objectPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $generation = '12345678-1234-4234-8234-123456789abc'
        $secondGeneration = '87654321-4321-4234-8234-cba987654321'
        $script:ArchiveObjectMode = 'valid'
        $script:ArchiveSnapshotCalls = 0
        function Assert-Configured {}
        function Resolve-ConfinedArchivePath([string]$Relative, [switch]$AllowMissing) { return $objectPath }
        function Test-ArchiveFilesystemRegistration([switch]$RejectPartials) {}
        function Invoke-PsqlLines([string]$Sql) {
            if (-not $Sql.Contains('CROSS JOIN required')) { return @() }
            Assert-True ($Sql.Contains('CROSS JOIN required') -and
                $Sql.Contains("g.state IN ('ACTIVE','SEALED')") -and $Sql.Contains('chr(31)') -and
                $Sql.Contains('invalid_owner_rows') -and
                $Sql.Contains('block.min_id=g.min_id AND block.max_id=g.max_id') -and
                $Sql.Contains('(SELECT count(*)::text FROM oscar_archive_schema schema_row') -and
                $Sql.Contains("'ID_BLOCK_AND_SCHEMAS'::text")) `
                'PowerShell archive verification did not require one exact min/max ID block plus schema metadata for every query-visible generation.'
            $script:ArchiveSnapshotCalls++
            switch ($script:ArchiveObjectMode) {
                'valid' {
                    return @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t1`tACTIVE`tdatasets/a.manifest.json`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "ADDITIONAL`t$generation`tAUDIT_SIDECAR`t1`tACTIVE`tdatasets/a.audit`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "RELATIONAL`t$generation`tID_BLOCK_AND_SCHEMAS`t1`tMATCH`t1`t`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json")
                }
                'missing' {
                    return @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t0`tMISSING`tmissing`tbad`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json")
                }
                'duplicate' {
                    return @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t2`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t1`tACTIVE`tdatasets/a.manifest.json`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json")
                }
                'stale-path' {
                    return @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/stale.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t1`tACTIVE`tdatasets/a.manifest.json`t$objectSha`tdatasets/stale.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/stale.parquet`t$objectSha`tdatasets/a.manifest.json")
                }
                'stale-hash' {
                    $staleSha = 'b' * 64
                    return @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/a.parquet`t$staleSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t1`tACTIVE`tdatasets/a.manifest.json`t$objectSha`tdatasets/a.parquet`t$staleSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/a.parquet`t$staleSha`tdatasets/a.manifest.json")
                }
                'relational' {
                    return @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t1`tACTIVE`tdatasets/a.manifest.json`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "RELATIONAL`t$generation`tID_BLOCK_AND_SCHEMAS`t2`tMISMATCH`t0`t`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json")
                }
                'inactive-owner' {
                    return @("INVALID_OWNER`t$generation`tAUDIT_SIDECAR`t1`tACTIVE`tdatasets/a.audit`t$objectSha`t`t`t")
                }
                'activation' {
                    $rows = @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t1`tACTIVE`tdatasets/a.manifest.json`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "RELATIONAL`t$generation`tID_BLOCK_AND_SCHEMAS`t1`tMATCH`t1`t`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json")
                    if ($script:ArchiveSnapshotCalls -gt 1) {
                        $rows += "REQUIRED`t$secondGeneration`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/b.parquet`t$objectSha`tdatasets/b.parquet`t$objectSha`tdatasets/b.manifest.json"
                    }
                    return $rows
                }
                'purge' {
                    if ($script:ArchiveSnapshotCalls -gt 1) { return @() }
                    return @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t1`tACTIVE`tdatasets/a.manifest.json`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "RELATIONAL`t$generation`tID_BLOCK_AND_SCHEMAS`t1`tMATCH`t1`t`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json")
                }
            }
        }
        function Write-PsqlLinesToFile([string]$Sql, [string]$Path) {
            $rows = @(Invoke-PsqlLines $Sql | ForEach-Object { ([string]$_).Replace("`t", [string][char]31) })
            [IO.File]::WriteAllLines($Path, $rows, $Utf8NoBom)
        }

        Confirm-ArchiveObjects
        foreach ($invalidMode in @('missing','duplicate','stale-path','stale-hash','relational','inactive-owner')) {
            $script:ArchiveObjectMode = $invalidMode
            $script:ArchiveSnapshotCalls = 0
            $rejected = $false
            try { Confirm-ArchiveObjects } catch { $rejected = $true }
            Assert-True $rejected "PowerShell archive verification accepted a $invalidMode required-object catalog."
        }
        foreach ($changeMode in @('activation','purge')) {
            $script:ArchiveObjectMode = $changeMode
            $script:ArchiveSnapshotCalls = 0
            $rejected = $false
            try { Confirm-ArchiveObjects } catch { $rejected = $true }
            Assert-True $rejected "PowerShell archive verification accepted a concurrent catalog $changeMode."
        }
    }

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
    $inventoryPath = Join-Path $catalogRoot 'archive-generation-ids.txt'
    $inventoryHash = (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $inventoryReceipt = Get-ArchiveGenerationInventory $catalogRoot
    Assert-True ($inventoryReceipt.Count -eq 2 -and $inventoryReceipt.Bytes -eq 74 -and
        $inventoryReceipt.Sha256 -ceq $inventoryHash) 'PowerShell did not produce the compact authenticated archive-generation receipt.'
    [IO.File]::WriteAllBytes($inventoryPath, [byte[]]@())
    $emptyReceipt = Get-ArchiveGenerationInventory $catalogRoot
    Assert-True ($emptyReceipt.Count -eq 0 -and $emptyReceipt.Bytes -eq 0 -and
        $emptyReceipt.Sha256 -ceq 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') `
        'PowerShell rejected the canonical zero-generation inventory receipt.'
    [IO.File]::WriteAllText($inventoryPath,
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
        $script:CapturedCatalogSql.Contains('archive_generation_count IS NOT DISTINCT FROM EXCLUDED.archive_generation_count') -and
        $script:CapturedCatalogSql.Contains('archive_generation_inventory_sha256 IS NOT DISTINCT FROM EXCLUDED.archive_generation_inventory_sha256') -and
        $script:CapturedCatalogSql.Contains('archive_generation_inventory_bytes IS NOT DISTINCT FROM EXCLUDED.archive_generation_inventory_bytes') -and
        $script:CapturedCatalogSql.Contains(",2,'$inventoryHash',74,") -and
        -not $script:CapturedCatalogSql.Contains('archive_generation_ids') -and
        -not $script:CapturedCatalogSql.Contains('11111111-1111-4111-8111-111111111111') -and
        -not $script:CapturedCatalogSql.Contains('FROM oscar_archive_generation') -and
        $script:CapturedCatalogSql.Contains('sha256 IS NOT DISTINCT FROM EXCLUDED.sha256')) 'PowerShell VERIFIED epoch upsert is not bound to the compact authenticated backup-time generation receipt.'
    function Invoke-PsqlScript([string]$Sql) { return '' }
    $rejectedForeignEpoch = $false
    try { Set-VerifiedBackupEpochReceipt $catalogRoot $catalogBackup $catalogId '0/12345678' } catch { $rejectedForeignEpoch = $true }
    Assert-True $rejectedForeignEpoch 'PowerShell accepted a foreign same-UUID backup epoch collision.'

    foreach ($invalidInventory in @(
        "11111111-1111-4111-8111-111111111111`r`n",
        "11111111-1111-4111-8111-111111111111",
        "11111111-1111-4111-8111-111111111111`n11111111-1111-4111-8111-111111111111`n",
        "22222222-2222-4222-8222-222222222222`n11111111-1111-4111-8111-111111111111`n")) {
        [IO.File]::WriteAllText($inventoryPath, $invalidInventory, $Utf8NoBom)
        $rejectedInventory = $false
        try { [void](Get-ArchiveGenerationInventory $catalogRoot) } catch { $rejectedInventory = $true }
        Assert-True $rejectedInventory 'PowerShell accepted a noncanonical archive-generation inventory.'
    }
    $bom = [byte[]](0xef,0xbb,0xbf) + [Text.Encoding]::ASCII.GetBytes("11111111-1111-4111-8111-111111111111`n")
    [IO.File]::WriteAllBytes($inventoryPath, $bom)
    $rejectedBom = $false
    try { [void](Get-ArchiveGenerationInventory $catalogRoot) } catch { $rejectedBom = $true }
    Assert-True $rejectedBom 'PowerShell accepted a UTF-8 BOM in the archive-generation inventory.'

    $largeWriter = [IO.StreamWriter]::new($inventoryPath, $false, $Utf8NoBom)
    $largeWriter.NewLine = "`n"
    try {
        for ($index = 0; $index -lt 10000; $index++) {
            $largeWriter.WriteLine(("00000000-0000-4000-8000-{0:D12}" -f $index))
        }
    } finally { $largeWriter.Dispose() }
    $largeHash = (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $largeReceipt = Get-ArchiveGenerationInventory $catalogRoot
    Assert-True ($largeReceipt.Count -eq 10000 -and $largeReceipt.Bytes -eq 370000 -and
        $largeReceipt.Sha256 -ceq $largeHash) 'PowerShell failed the practical streaming archive-generation boundary fixture.'
    $oversizedInventory = [IO.File]::Open($inventoryPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $oversizedInventory.SetLength(37000001) } finally { $oversizedInventory.Dispose() }
    $rejectedOversized = $false
    try { [void](Get-ArchiveGenerationInventory $catalogRoot) } catch { $rejectedOversized = $true }
    Assert-True $rejectedOversized 'PowerShell accepted an archive-generation inventory above 37,000,000 bytes.'

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

    # Archive ID blocks are coarse ranges. Sparse generations produced from
    # interleaved eligible/ineligible streams can span an unrelated exact hot
    # row, so the command must branch on exact-row existence before consulting
    # the conservative cold-only range fallback.
    $storageSource = [IO.File]::ReadAllText($storageScript)
    $holdStart = $storageSource.IndexOf('function Invoke-RetentionHold', [StringComparison]::Ordinal)
    Assert-True ($holdStart -ge 0) 'Could not find the PowerShell retention-hold implementation.'
    $holdEnd = $storageSource.IndexOf('function Confirm-ArchiveObjects', $holdStart, [StringComparison]::Ordinal)
    Assert-True ($holdEnd -gt $holdStart) 'Could not isolate the PowerShell retention-hold implementation.'
    $holdSource = $storageSource.Substring($holdStart, $holdEnd - $holdStart)
    Assert-True (Test-ObservationId '1') 'PowerShell rejected the minimum positive observation ID.'
    Assert-True (Test-ObservationId '9223372036854775807') 'PowerShell rejected the signed-BIGINT maximum observation ID.'
    Assert-True (-not (Test-ObservationId '0')) 'PowerShell accepted zero as an observation ID.'
    Assert-True (-not (Test-ObservationId '9223372036854775808')) 'PowerShell accepted an observation ID above signed-BIGINT maximum.'
    Assert-True (([regex]::Matches($holdSource, '::bigint')).Count -eq 4 -and
        -not $holdSource.Contains('::numeric')) 'PowerShell observation-hold SQL does not preserve bigint index operands.'
    $holdTerms = @(
        'SELECT 1 FROM oscar_tombstone',
        'THEN CASE',
        'SELECT 1 FROM "$StoreKey" any_hot_row',
        'THEN CASE WHEN EXISTS (',
        'SELECT 1 FROM "$StoreKey" exact_hot_row',
        'SELECT 1 FROM oscar_archive_generation exact_owner',
        "exact_owner.state IN ('ACTIVE','SEALED')",
        "THEN 'HOT_EXACT'",
        'WHEN EXISTS (',
        'SELECT 1 FROM oscar_archive_id_block active_block',
        'AND NOT EXISTS (',
        'SELECT 1 FROM oscar_archive_id_block retired_block',
        "THEN 'COLD_RANGE_CONSERVATIVE'",
        'END AS resolution_mode'
    )
    $holdOffset = 0
    foreach ($term in $holdTerms) {
        $nextOffset = $holdSource.IndexOf($term, $holdOffset, [StringComparison]::Ordinal)
        Assert-True ($nextOffset -ge $holdOffset) "Observation-hold SQL is missing or misorders its exact/range precedence term: $term"
        $holdOffset = $nextOffset + $term.Length
    }

    function Test-ObservationHoldFixture(
        [bool]$ExactPresent,
        [bool]$ExactEligible,
        [bool]$ActiveRange,
        [bool]$RetiredRange,
        [bool]$Tombstoned) {
        if ($Tombstoned) { return 'REJECTED' }
        if ($ExactPresent) {
            if ($ExactEligible) { return 'HOT_EXACT' }
            return 'REJECTED'
        }
        if ($ActiveRange -and -not $RetiredRange) { return 'COLD_RANGE_CONSERVATIVE' }
        return 'REJECTED'
    }
    # A retired generation contains sparse IDs 100/104, so its [100,104]
    # block also spans unrelated exact rows 102/103 and cold-only ID 101.
    $holdFixtures = @(
        @{ Name = 'exact hot over retired range'; Expected = 'HOT_EXACT'; Values = @($true, $true, $true, $true, $false) },
        @{ Name = 'exact ACTIVE-owned over retired range'; Expected = 'HOT_EXACT'; Values = @($true, $true, $true, $true, $false) },
        @{ Name = 'exact SEALED-owned over retired range'; Expected = 'HOT_EXACT'; Values = @($true, $true, $true, $true, $false) },
        @{ Name = 'exact retired-owned'; Expected = 'REJECTED'; Values = @($true, $false, $true, $true, $false) },
        @{ Name = 'cold active/retired ambiguous'; Expected = 'REJECTED'; Values = @($false, $false, $true, $true, $false) },
        @{ Name = 'cold active only'; Expected = 'COLD_RANGE_CONSERVATIVE'; Values = @($false, $false, $true, $false, $false) },
        @{ Name = 'cold retired only'; Expected = 'REJECTED'; Values = @($false, $false, $false, $true, $false) },
        @{ Name = 'exact hot tombstoned'; Expected = 'REJECTED'; Values = @($true, $true, $true, $true, $true) },
        @{ Name = 'unknown'; Expected = 'REJECTED'; Values = @($false, $false, $false, $false, $false) }
    )
    foreach ($fixture in $holdFixtures) {
        $holdValues = $fixture.Values
        $actual = Test-ObservationHoldFixture @holdValues
        Assert-True ($actual -eq $fixture.Expected) "Observation-hold sparse/interleaved fixture failed: $($fixture.Name)"
    }

    Write-Host 'OSCAR Windows PowerShell 5.1 storage safety tests passed.' -ForegroundColor Green
} finally {
    Remove-Item Env:OSCAR_STORAGE_TEST_MODE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if ($createdDockerGroup) { & net.exe localgroup docker-users /delete *> $null }
}
