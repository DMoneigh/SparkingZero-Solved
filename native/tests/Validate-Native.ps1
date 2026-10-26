[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$native = Split-Path $PSScriptRoot -Parent
$root = Join-Path $native ('.cache\v-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$tools = Join-Path $root 'tools'
$game = Join-Path $root 'game'
$bin = Join-Path $game 'SparkingZERO\Binaries\Win64'
$archive = Join-Path $native '.cache\ue4ss-tested-1152.zip'
if (-not (Test-Path -LiteralPath $archive)) { throw 'Download the checksum-pinned loader to native\.cache before running installer checks.' }
$script:assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-True $threw $Message
}

New-Item -ItemType Directory -Path $tools, $bin -Force | Out-Null
$form = $null
try {
    foreach ($name in @('Install-Mod.ps1', 'Uninstall-Mod.ps1', 'Paths.ps1', 'loader-lock.json')) {
        Copy-Item -LiteralPath (Join-Path $native $name) -Destination $tools
    }
    Copy-Item -LiteralPath (Join-Path $native 'DezsMinion') -Destination $tools -Recurse
    # A non-executable marker exercises path selection; this fixture is never launched.
    [IO.File]::WriteAllText((Join-Path $bin 'SparkingZERO-Win64-Shipping.exe'), 'TEST FIXTURE - NOT AN EXECUTABLE')
    $installer = Join-Path $tools 'Install-Mod.ps1'
    $uninstaller = Join-Path $tools 'Uninstall-Mod.ps1'
    & $installer -GameDirectory $game -LoaderArchive $archive -WhatIf
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bin 'dwmapi.dll'))) '-WhatIf wrote files'
    [IO.File]::WriteAllText((Join-Path $bin 'version.dll'), 'DO NOT OVERWRITE')
    Assert-Throws { & $installer -GameDirectory $game -LoaderArchive $archive } 'Conflicting proxy was accepted'
    Assert-True (([IO.File]::ReadAllText((Join-Path $bin 'version.dll'))) -eq 'DO NOT OVERWRITE') 'Conflicting proxy was changed'
    Remove-Item -LiteralPath (Join-Path $bin 'version.dll')
    $badArchive = Join-Path $root 'invalid.zip'
    [IO.File]::WriteAllText($badArchive, 'INVALID')
    Assert-Throws { & $installer -GameDirectory $game -LoaderArchive $badArchive } 'Invalid archive hash was accepted'
    & $installer -GameDirectory $game -LoaderArchive $archive
    Assert-True (Test-Path -LiteralPath (Join-Path $bin 'dwmapi.dll')) 'Loader was not installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $bin 'ue4ss\Mods\DezsMinion\Scripts\main.lua')) 'Runtime was not installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $bin 'ue4ss\Mods\DezsMinion\enabled.txt')) 'Mod was not enabled'
    Assert-True (Test-Path -LiteralPath (Join-Path $tools 'installation.json')) 'Manifest was not recorded'
    Assert-Throws { & $installer -GameDirectory $game -LoaderArchive $archive } 'Reinstallation did not reject overwrites'

    & (Join-Path $native 'Start-ModMenu.ps1') -CompileOnly
    $mod = Join-Path $bin 'ue4ss\Mods\DezsMinion'
    $binding = [Reflection.BindingFlags]'Instance,NonPublic'
    $constructor = [DezsMinion.ModMenu].GetConstructor($binding, $null, [type[]]@([string], [string]), $null)
    $form = $constructor.Invoke([object[]]@([string]$mod, [string](Join-Path $bin 'SparkingZERO-Win64-Shipping.exe')))
    $type = $form.GetType()
    $publish = $type.GetMethod('Publish', $binding)
    $publish.Invoke($form, @()) | Out-Null
    $request = [IO.File]::ReadAllText((Join-Path $mod 'Bridge\request.txt'))
    Assert-True ($request -match '(?m)^armed=0\r?$') 'Panel did not start disarmed'
    Assert-True ($request -match '(?m)^session=[a-f0-9]{32}\r?$') 'Session ID is invalid'
    Assert-True ($request -match '(?m)^health=0\r?$') 'Health unexpectedly enabled'
    $armed = $type.GetField('armed', $binding).GetValue($form)
    $toggles = $type.GetField('toggles', $binding).GetValue($form)
    $armed.Checked = $true
    $toggles['health'].Checked = $true
    $request = [IO.File]::ReadAllText((Join-Path $mod 'Bridge\request.txt'))
    Assert-True ($request -match '(?m)^health=1\r?$') 'Panel failed to publish health toggle'
    $busyRequest = [IO.File]::Open((Join-Path $mod 'Bridge\request.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $publish.Invoke($form, @()) | Out-Null
        Assert-True $armed.Checked 'Brief Lua-style read contention disarmed the panel'
        Assert-True $toggles['health'].Checked 'Brief Lua-style read contention cleared health'
        $type.GetField('ioFailureSince', $binding).SetValue($form, [long]1)
        $publish.Invoke($form, @()) | Out-Null
        Assert-True (-not $armed.Checked) 'Sustained IPC failure did not disarm panel'
    } finally { $busyRequest.Dispose() }
    $publish.Invoke($form, @()) | Out-Null
    Assert-True ($type.GetField('lastIoError', $binding).GetValue($form) -eq '') 'Panel did not recover from released file lock'
    $armed.Checked = $true
    $toggles['health'].Checked = $true
    $type.GetField('lastRuntimeResponse', $binding).SetValue($form, [long]0)
    $type.GetMethod('Poll', $binding).Invoke($form, [object[]]@($null, [EventArgs]::Empty)) | Out-Null
    Assert-True (-not $armed.Checked) 'Missing runtime acknowledgement did not disarm panel'
    Assert-True (-not $toggles['health'].Checked) 'Missing runtime acknowledgement left health enabled'
    Assert-Throws { & $uninstaller } 'Uninstaller did not reject active panel lock'
    $type.GetField('ownership', $binding).GetValue($form).Dispose()
    $type.GetField('tray', $binding).GetValue($form).Dispose()
    $form.Dispose()
    $form = $null

    $other = Join-Path $bin 'ue4ss\Mods\OtherMod'
    New-Item -ItemType Directory -Path $other | Out-Null
    Assert-Throws { & $uninstaller } 'Uninstaller removed a shared loader'
    Remove-Item -LiteralPath $other
    $script = Join-Path $mod 'Scripts\main.lua'
    $original = [IO.File]::ReadAllText($script)
    [IO.File]::AppendAllText($script, '-- changed')
    Assert-Throws { & $uninstaller } 'Uninstaller deleted edited code'
    Assert-True (Test-Path -LiteralPath (Join-Path $bin 'dwmapi.dll')) 'Uninstall preflight removed loader before reporting changes'
    [IO.File]::WriteAllText($script, $original, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $bin 'unrelated.txt'), 'KEEP')
    [IO.File]::WriteAllText((Join-Path $mod ('Bridge\request-' + ('a' * 32) + '.tmp')), 'ABANDONED REQUEST')
    $log = Join-Path $bin 'ue4ss\UE4SS.log'
    [IO.File]::WriteAllText($log, 'RETAIN DIAGNOSTICS')
    & $uninstaller -WhatIf
    Assert-True (Test-Path -LiteralPath (Join-Path $bin 'dwmapi.dll')) 'Uninstall -WhatIf removed loader'
    & $uninstaller
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bin 'dwmapi.dll'))) 'Loader was not removed'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $tools 'installation.json'))) 'Manifest was not removed'
    Assert-True (Test-Path -LiteralPath (Join-Path $bin 'unrelated.txt')) 'Unrelated file was removed'
    Assert-True (Test-Path -LiteralPath (Join-Path $bin 'SparkingZERO-Win64-Shipping.exe')) 'Game marker was removed'
    Assert-True (([IO.File]::ReadAllText($log)) -eq 'RETAIN DIAGNOSTICS') 'Runtime log was not preserved'
    & $installer -GameDirectory $game -LoaderArchive $archive
    Assert-True (Test-Path -LiteralPath (Join-Path $bin 'dwmapi.dll')) 'Residual runtime log prevented reinstallation'
    Assert-True (([IO.File]::ReadAllText($log)) -eq 'RETAIN DIAGNOSTICS') 'Reinstallation changed old diagnostics'
    & $uninstaller
    Write-Host "Passed $script:assertions native panel and isolated installer assertions. No game or loader was executed."
} finally {
    if ($form) {
        $binding = [Reflection.BindingFlags]'Instance,NonPublic'
        $form.GetType().GetField('ownership', $binding).GetValue($form).Dispose()
        $form.GetType().GetField('tray', $binding).GetValue($form).Dispose()
        $form.Dispose()
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}
