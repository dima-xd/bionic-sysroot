<#
.SYNOPSIS
Downloads the Android 7.0 armeabi-v7a system image and rebuilds this bionic
sysroot from it.

.DESCRIPTION
The sysroot is the real 32-bit bionic userspace: the dynamic linker, libc,
libm, libdl, libstdc++, libz and libc++. They are taken unmodified from an
official AOSP system image, so the guest ABI is exactly what a real ARMv7
device exposes.

This script:
  1. finds the Android SDK,
  2. installs system-images;android-24;default;armeabi-v7a if needed,
  3. verifies the archive SHA-1,
  4. extracts system.img,
  5. pulls the libraries out of the ext4 image with debugfs (WSL),
  6. rewrites CHECKSUMS.txt.

Requires: Android SDK command line tools (sdkmanager) and WSL with debugfs,
which ships in the e2fsprogs package of every common distribution.

.EXAMPLE
  pwsh tools/fetch-sysroot.ps1
#>
[CmdletBinding()]
param(
    [string]$Sdk,
    [string]$Destination = (Join-Path $PSScriptRoot '..\armeabi-v7a')
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

# Both values are pinned: a different system image means a different libc, and
# the whole point of shipping the sysroot is that the guest ABI is reproducible.
$ImagePackage = 'system-images;android-24;default;armeabi-v7a'
$ImageZip = 'armeabi-v7a-24_r07.zip'
$ImageSha1 = '3454546b4eed2d6c3dd06d47757d6da9f4176033'
$ImageRelative = 'system-images\android-24\default\armeabi-v7a'

# Guest path inside system.img -> path inside the sysroot directory.
$Files = [ordered]@{
    '/system/bin/linker'       = 'bin\linker'
    '/system/lib/libc.so'      = 'lib\libc.so'
    '/system/lib/libm.so'      = 'lib\libm.so'
    '/system/lib/libdl.so'     = 'lib\libdl.so'
    '/system/lib/libstdc++.so' = 'lib\libstdc++.so'
    '/system/lib/libz.so'      = 'lib\libz.so'
    '/system/lib/libc++.so'    = 'lib\libc++.so'
}

function Find-Sdk {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }
    if ($env:ANDROID_SDK_ROOT) { return $env:ANDROID_SDK_ROOT }
    if ($env:ANDROID_HOME) { return $env:ANDROID_HOME }
    $properties = Join-Path $root 'local.properties'
    if (Test-Path $properties) {
        foreach ($line in Get-Content $properties) {
            if ($line -match '^\s*sdk\.dir\s*=\s*(.+)$') {
                return $Matches[1].Replace('\\', '\').Trim()
            }
        }
    }
    throw 'Android SDK not found. Pass -Sdk or set ANDROID_SDK_ROOT.'
}

function Get-WslPath {
    param([string]$WindowsPath)
    $converted = (& wsl.exe wslpath -a ($WindowsPath -replace '\\', '/')) 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $converted) {
        throw "wslpath failed for $WindowsPath. Is WSL installed?"
    }
    return $converted.Trim()
}

$Sdk = Find-Sdk -Explicit $Sdk
$archive = Join-Path $Sdk "$ImageRelative\$ImageZip"

if (-not (Test-Path $archive)) {
    $sdkManager = Join-Path $Sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
    if (-not (Test-Path $sdkManager)) {
        throw "Missing $archive and no sdkmanager at $sdkManager."
    }
    Write-Host "Installing $ImagePackage ..."
    & $sdkManager $ImagePackage
    if ($LASTEXITCODE -ne 0) { throw 'sdkmanager failed.' }
}

$actual = (Get-FileHash $archive -Algorithm SHA1).Hash.ToLower()
if ($actual -ne $ImageSha1) {
    throw "Unexpected system image: $archive has SHA-1 $actual, expected $ImageSha1."
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) 'bionic-sysroot'
New-Item -ItemType Directory -Force -Path $work | Out-Null
Write-Host "Extracting $ImageZip ..."
Expand-Archive -Path $archive -DestinationPath $work -Force
$image = Get-ChildItem $work -Recurse -Filter 'system.img' | Select-Object -First 1
if (-not $image) { throw "system.img not found inside $archive." }

$imageWsl = Get-WslPath $image.FullName
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

foreach ($guest in $Files.Keys) {
    $relative = $Files[$guest]
    $target = Join-Path $Destination $relative
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    $targetWsl = Get-WslPath $target
    Write-Host "debugfs $guest -> $relative"
    # debugfs prints its prompts on stderr and still exits 0; the file check
    # below is what decides whether the extraction worked.
    & wsl.exe debugfs -R "dump $guest $targetWsl" $imageWsl 2>$null | Out-Null
    if (-not (Test-Path $target) -or (Get-Item $target).Length -eq 0) {
        throw "Failed to extract $guest from $($image.Name)."
    }
}

Write-Host "Sysroot written to $Destination"
$report = Get-ChildItem $Destination -Recurse -File |
    Sort-Object FullName |
    ForEach-Object {
        '{0}  {1,9}  {2}' -f (Get-FileHash $_.FullName -Algorithm SHA1).Hash.ToLower(),
            $_.Length, $_.FullName.Substring($Destination.Length + 1).Replace('\', '/')
    }
$report | ForEach-Object { Write-Host $_ }
$checksums = Join-Path $root 'CHECKSUMS.txt'
Set-Content -Path $checksums -Value $report -Encoding UTF8
Write-Host "Checksums written to $checksums"
Write-Host 'Commit armeabi-v7a and CHECKSUMS.txt if any hash changed.'
