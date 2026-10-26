[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Paths.ps1')
$manifestPath = Join-Path $PSScriptRoot 'installation.json'
$installation = Read-Installation $manifestPath
Assert-GameStopped $installation.bin
$mods = Join-Path $installation.bin 'ue4ss\Mods'
if (Test-Path -LiteralPath $mods) {
    $otherMods = @(Get-ChildItem -LiteralPath $mods -Directory | Where-Object { $_.Name -ne 'DezsMinion' })
    if ($otherMods.Count) {
        throw 'Other mods now share this loader. Automatic uninstall stopped to avoid disabling them. Remove only DezsMinion manually and retain the shared loader.'
    }
}
$panelLock = Join-Path $installation.mod 'Bridge\panel.lock'
if (Test-Path -LiteralPath $panelLock) {
    $probe = [IO.File]::Open($panelLock, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $probe.Dispose()
}
$modified = @()
foreach ($file in $installation.files) {
    $path = Join-Path $installation.bin $file.relative
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.sha256) {
        $modified += $file.relative
    }
}
if ($modified.Count) {
    throw "Installed files were modified. Nothing was removed. Preserve/review these files before manual removal: $($modified -join ', ')"
}
if (-not $PSCmdlet.ShouldProcess($installation.bin, 'Remove only the recorded loader and mod files')) { return }
foreach ($file in $installation.files) {
    $path = Join-Path $installation.bin $file.relative
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
}
$bridge = Join-Path $installation.mod 'Bridge'
foreach ($name in @('request.txt', 'status.txt', 'panel.lock')) {
    $path = Join-Path $bridge $name
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
}
if (Test-Path -LiteralPath $bridge -PathType Container) {
    Get-ChildItem -LiteralPath $bridge -File | Where-Object {
        $_.Name -match '^request-[a-f0-9]{32}\.tmp$'
    } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
}
$ue4ss = Join-Path $installation.bin 'ue4ss'
if (Test-Path -LiteralPath $ue4ss) {
    Get-ChildItem -LiteralPath $ue4ss -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
        if (-not (Get-ChildItem -LiteralPath $_.FullName -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $_.FullName }
    }
    if (-not (Get-ChildItem -LiteralPath $ue4ss -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $ue4ss }
}
Remove-Item -LiteralPath $manifestPath
Write-Host 'Removed the recorded mod and loader files. Unrecognized files, other mods, game files and saves were preserved.'
