[CmdletBinding()]
param([switch]$CompileOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell for the native control panel.' }
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run this script with Windows PowerShell (powershell.exe), not PowerShell Core (pwsh).'
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Start Windows PowerShell with -STA, or use Launch-ModMenu.cmd.'
}
if ('DezsMinion.ModMenu' -as [type]) {
    # Add-Type assemblies cannot be unloaded; a fresh process also picks up source updates.
    $launcher = Join-Path $PSHOME 'powershell.exe'
    $arguments = @('-NoProfile', '-STA', '-File', $PSCommandPath)
    if ($CompileOnly) { $arguments += '-CompileOnly' }
    Write-Host 'The menu type is already loaded. Starting a fresh PowerShell process.'
    & $launcher @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "The fresh control-panel process failed with exit code $LASTEXITCODE."
    }
    return
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'ModMenu.cs') -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing', 'System.Core'
if ($CompileOnly) { Write-Host 'Native control panel compiled.'; return }
. (Join-Path $PSScriptRoot 'Paths.ps1')
$installation = Read-Installation (Join-Path $PSScriptRoot 'installation.json')
if (-not (Test-Path -LiteralPath $installation.executable -PathType Leaf)) { throw 'The installed game executable is missing.' }
foreach ($file in $installation.files) {
    $path = Join-Path $installation.bin $file.relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Installed component is missing: $($file.relative)" }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.sha256) {
        throw "Installed component was changed: $($file.relative). Review the change and reinstall rather than launching an unverified runtime."
    }
}
[DezsMinion.ModMenu]::Run($installation.mod, $installation.executable)
