# Install RVFinePlank into a RV There Yet? installation (Windows).
#
#   .\tools\install.ps1                      # auto-detect Steam libraries
#   .\tools\install.ps1 -GameRoot "D:\Steam\steamapps\common\Ride"
#
# Copies the mod next to UE4SS. Does not install UE4SS itself.

[CmdletBinding()]
param([string]$GameRoot)

$ErrorActionPreference = 'Stop'

$ModName  = 'RVFinePlank'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Src      = Join-Path $RepoRoot $ModName

if (-not (Test-Path $Src)) { throw "error: $Src not found" }

function Get-SteamLibraries {
    $libs = @()
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        $steam = $steam -replace '/', '\'
        $libs += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libs += ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    $libs | Select-Object -Unique
}

$candidates = @()
if ($GameRoot) {
    $candidates += $GameRoot
} else {
    foreach ($lib in Get-SteamLibraries) {
        $candidates += (Join-Path $lib 'steamapps\common\Ride')
    }
}

$found = $null
foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c 'Ride\Binaries\Win64')) { $found = $c; break }
}

if (-not $found) {
    Write-Host 'error: could not find the game. Looked in:'
    $candidates | ForEach-Object { Write-Host "  $_" }
    Write-Host 'Pass it explicitly:  .\tools\install.ps1 -GameRoot "D:\...\common\Ride"'
    exit 1
}

$Win64 = Join-Path $found 'Ride\Binaries\Win64'
Write-Host "game:  $Win64"

if (-not (Test-Path (Join-Path $Win64 'dwmapi.dll'))) {
    Write-Host ''
    Write-Warning "dwmapi.dll is missing from $Win64 - UE4SS does not look installed."
    Write-Host '  Download UE4SS_v3.0.1-<build>.zip (v3.0.1-1181 or newer; first build with'
    Write-Host '  UE 5.6 support) from:'
    Write-Host '    https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest'
    Write-Host "  and unpack it into:`n    $Win64`n"
}

$Dest = Join-Path $Win64 "ue4ss\Mods\$ModName"
if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
New-Item -ItemType Directory -Path (Split-Path $Dest) -Force | Out-Null
Copy-Item $Src $Dest -Recurse -Force

Write-Host "installed: $Dest"
Get-ChildItem $Dest -Recurse -File | ForEach-Object {
    Write-Host ("  " + $_.FullName.Substring($Dest.Length + 1))
}

Write-Host ''
Write-Host 'In game: F3 fine mode, F4 probe, numpad to nudge, `rvfine` in the console.'
Write-Host "Log: $Win64\ue4ss\UE4SS.log"
