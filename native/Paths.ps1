function Resolve-GameBin {
    param([Parameter(Mandatory = $true)][string]$Directory)
    $resolved = (Resolve-Path -LiteralPath $Directory -ErrorAction Stop).Path
    foreach ($candidate in @($resolved, (Join-Path $resolved 'SparkingZERO\Binaries\Win64'))) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'SparkingZERO-Win64-Shipping.exe') -PathType Leaf) {
            return $candidate.TrimEnd('\')
        }
    }
    throw 'Select the installed game root or its SparkingZERO\Binaries\Win64 folder, not the ZIP archive.'
}

function Assert-GameStopped {
    param([Parameter(Mandatory = $true)][string]$Bin)
    # Installation changes are unsafe while any copy of the shipping game is open.
    if (Get-Process -Name 'SparkingZERO-Win64-Shipping' -ErrorAction SilentlyContinue) {
        throw 'Close Sparking ZERO before installing or uninstalling the mod.'
    }
}

function Read-Installation {
    param([Parameter(Mandatory = $true)][string]$Manifest)
    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
        throw 'No installation is recorded. Run native\Install-Mod.ps1 first; see native\INSTRUCTIONS.txt.'
    }
    $installation = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
    if ($installation.schema -ne 1) { throw 'Unsupported installation manifest.' }
    $bin = [IO.Path]::GetFullPath($installation.bin).TrimEnd('\')
    if ($installation.mod -ne (Join-Path $bin 'ue4ss\Mods\DezsMinion') -or
        $installation.executable -ne (Join-Path $bin 'SparkingZERO-Win64-Shipping.exe')) {
        throw 'Invalid installation paths.'
    }
    foreach ($file in $installation.files) {
        $path = [IO.Path]::GetFullPath((Join-Path $bin $file.relative))
        if (-not $path.StartsWith($bin + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Installation manifest contains a path outside the game directory.'
        }
    }
    return $installation
}
