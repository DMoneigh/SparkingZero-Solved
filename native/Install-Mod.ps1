[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$GameDirectory,
    [string]$LoaderArchive,
    [switch]$DownloadLoader
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path $PSScriptRoot 'Paths.ps1')
$bin = Resolve-GameBin $GameDirectory
Assert-GameStopped $bin
$mod = Join-Path $bin 'ue4ss\Mods\DezsMinion'
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'loader-lock.json') -Raw | ConvertFrom-Json
$manifestPath = Join-Path $PSScriptRoot 'installation.json'
if (Test-Path -LiteralPath $mod) {
    throw "A DezsMinion mod already exists at '$mod'. Uninstall that installation before replacing it."
}
if (Test-Path -LiteralPath $manifestPath) {
    throw 'This workspace already tracks an installation. Uninstall it before installing elsewhere.'
}
foreach ($name in @('dwmapi.dll', 'UE4SS.dll', 'UE4SS-settings.ini', 'xinput1_3.dll', 'version.dll', 'dinput8.dll', 'winmm.dll', 'winhttp.dll', 'dsound.dll')) {
    if (Test-Path -LiteralPath (Join-Path $bin $name)) {
        throw "Existing loader component '$name' detected. Nothing was changed. This installer requires a clean UE4SS installation; it never replaces other mods or loaders."
    }
}
$existingRuntime = Join-Path $bin 'ue4ss'
if (Test-Path -LiteralPath $existingRuntime) {
    if (-not (Test-Path -LiteralPath $existingRuntime -PathType Container)) { throw "'$existingRuntime' is not a directory." }
    $conflicts = @(Get-ChildItem -LiteralPath $existingRuntime -Force | Where-Object {
        $_.PSIsContainer -or $_.Name -notmatch '^UE4SS\.log(?:\.\d+)?$'
    })
    if ($conflicts.Count) {
        throw 'An existing ue4ss directory contains loader components or unknown files. Only residual UE4SS logs from an uninstall are accepted.'
    }
}
if ($LoaderArchive -and $DownloadLoader) { throw 'Choose either -LoaderArchive or -DownloadLoader.' }
if (-not $LoaderArchive -and -not $DownloadLoader) {
    throw 'Supply -DownloadLoader to fetch the pinned loader, or -LoaderArchive with the documented, hash-matching ZIP.'
}
if (-not $PSCmdlet.ShouldProcess($bin, 'Install pinned UE4SS launch-time loader and DezsMinion offline mod')) { return }

$cache = Join-Path $PSScriptRoot '.cache'
if ($DownloadLoader) {
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $LoaderArchive = Join-Path $cache 'ue4ss-tested-1152.zip'
    if (-not (Test-Path -LiteralPath $LoaderArchive)) {
        Write-Host "Downloading $($lock.name) from the pinned, third-party AccessForge bundle..."
        Invoke-WebRequest -Uri $lock.url -OutFile ($LoaderArchive + '.download') -UseBasicParsing
        Move-Item -LiteralPath ($LoaderArchive + '.download') -Destination $LoaderArchive
    }
}
$LoaderArchive = (Resolve-Path -LiteralPath $LoaderArchive).Path
$hash = (Get-FileHash -LiteralPath $LoaderArchive -Algorithm SHA256).Hash
if ($hash -ne $lock.archiveSha256) { throw 'Loader archive SHA-256 does not match loader-lock.json. Installation aborted.' }

$stage = Join-Path $cache ('s-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$created = [System.Collections.Generic.List[string]]::new()
$copied = [System.Collections.Generic.List[object]]::new()
$installed = $false
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($LoaderArchive)
    try {
        foreach ($entry in $zip.Entries) {
            if (-not $entry.Name) { continue }
            $relative = $entry.FullName.Replace('/', '\')
            $destination = [IO.Path]::GetFullPath((Join-Path $stage $relative))
            if (-not $destination.StartsWith($stage + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe archive entry: $relative"
            }
            if ($entry.Length -gt 100MB) { throw "Unexpected loader entry size: $relative" }
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination)
        }
    } finally { $zip.Dispose() }
    foreach ($required in @('dwmapi.dll', 'ue4ss\UE4SS.dll', 'ue4ss\UE4SS-settings.ini')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $required) -PathType Leaf)) {
            throw "Unexpected archive layout: missing $required"
        }
    }
    $runtimeHash = (Get-FileHash -LiteralPath (Join-Path $stage 'ue4ss\UE4SS.dll') -Algorithm SHA256).Hash
    if ($runtimeHash -ne $lock.runtimeSha256) { throw 'Runtime DLL hash mismatch.' }
    $settings = Get-Content -LiteralPath (Join-Path $stage 'ue4ss\UE4SS-settings.ini') -Raw
    if ($settings -notmatch '(?m)^\s*HookInitGameState\s*=\s*0\s*(?:;.*)?$') {
        throw 'Loader configuration does not disable the incompatible InitGameState hook.'
    }
    $stagedMod = Join-Path $stage 'ue4ss\Mods\DezsMinion'
    New-Item -ItemType Directory -Path (Join-Path $stagedMod 'Scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $stagedMod 'Bridge') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'DezsMinion\Scripts\main.lua') -Destination (Join-Path $stagedMod 'Scripts\main.lua')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'DezsMinion\Scripts\protocol.lua') -Destination (Join-Path $stagedMod 'Scripts\protocol.lua')
    [IO.File]::WriteAllText((Join-Path $stagedMod 'enabled.txt'), '')
    [IO.File]::WriteAllText((Join-Path $stage 'ue4ss\Mods\mods.txt'), "DezsMinion : 1`r`n")
    Assert-GameStopped $bin
    foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse) {
        $relative = $file.FullName.Substring($stage.Length + 1)
        $destination = Join-Path $bin $relative
        if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite '$destination'." }
    }
    foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse) {
        $relative = $file.FullName.Substring($stage.Length + 1)
        $destination = Join-Path $bin $relative
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
        [IO.File]::Copy($file.FullName, $destination, $false)
        $created.Add($destination)
        $copied.Add([PSCustomObject]@{ relative = $relative; sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash })
    }
    New-Item -ItemType Directory -Path (Join-Path $mod 'Bridge') -Force | Out-Null
    $manifest = [PSCustomObject]@{
        schema = 1
        bin = $bin
        mod = $mod
        executable = (Join-Path $bin 'SparkingZERO-Win64-Shipping.exe')
        loader = $lock.name
        installedUtc = [DateTime]::UtcNow.ToString('o')
        files = $copied.ToArray()
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $installed = $true
} finally {
    if (-not $installed) {
        foreach ($path in $created) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        $ue4ss = Join-Path $bin 'ue4ss'
        if (Test-Path -LiteralPath $ue4ss) {
            Get-ChildItem -LiteralPath $ue4ss -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
                if (-not (Get-ChildItem -LiteralPath $_.FullName -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $_.FullName }
            }
            if (-not (Get-ChildItem -LiteralPath $ue4ss -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $ue4ss }
        }
    }
    Remove-Item -LiteralPath $stage -Recurse -Force
}
Write-Host "Installed launch-time loader and offline mod at $mod"
Write-Host 'Launch the game normally, then run native\Start-ModMenu.ps1. Use borderless/windowed mode.'
Write-Host 'This installation is not a claim of compatibility with your executable. The runtime will report missing APIs or loader errors.'
