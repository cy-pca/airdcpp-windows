# recipes/airdcpp-windows/build.ps1 -- the AirDC++ Windows desktop client from upstream's source
# with MSVC, against cvcpkg's shared dependencies, plus the runtime files upstream's portable
# release ships beside AirDC.exe. See the recipe's notes for why each piece is where it is.
#
# Self-contained: it does not source cvcpkg's recipes/_common/env-windows.ps1, because this recipe
# lives outside cvcpkg's tree. It needs cl.exe (a Visual Studio developer environment, or a Visual
# Studio with the C++ workload that vswhere can find), cmake, ninja, python and tar.exe.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

foreach ($name in 'CVC_SOURCE_DIR', 'CVC_BUILD_DIR', 'CVC_INSTALL_DIR', 'CVC_DEPS_PREFIX') {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name must be set" }
}
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$jobs = if ($env:CVC_JOBS) { $env:CVC_JOBS } else { [Environment]::ProcessorCount }
$buildType = if ("$env:CVC_BUILD_TYPE".ToLower() -eq 'debug') { 'Debug' } else { 'Release' }
# cvcpkg's Windows dependencies are DLLs built against the dynamic CRT (/MD), and C++ objects
# cross those DLL boundaries (Boost, LevelDB), so AirDC.exe uses the dynamic CRT too.
$msvcRuntime = if ($buildType -eq 'Debug') { 'MultiThreadedDebugDLL' } else { 'MultiThreadedDLL' }

# Pins. The Web UI is the release AirDC++ 4.30 shipped with (and the one airdcpp-webclient 2.14.0
# bundles); WTL is the version upstream's vcpkg baseline resolves to; zlib is the release cvcpkg's
# zlib is built from, whose contrib/minizip is the "minizip" upstream links.
$AirdcppVersion = '4.30'
$WebUiVersion   = '2.14.0'
$WebUiUrl       = "https://registry.npmjs.org/airdcpp-webui/-/airdcpp-webui-$WebUiVersion.tgz"
$WebUiSha256    = '5240dc788f5b6988d0766e084b572652b4495402b7bc3516cc14651dc81a84a7'
$WtlVersion     = '10.0.10320'
$WtlUrl         = "https://api.nuget.org/v3-flatcontainer/wtl/$WtlVersion/wtl.$WtlVersion.nupkg"
$WtlSha256      = '28670adb25c05772a4b5d7c598c98b1567587b377d689a792845b026768f4d3a'
$ZlibVersion    = '1.3.1'
$ZlibUrl        = "https://github.com/madler/zlib/releases/download/v$ZlibVersion/zlib-$ZlibVersion.tar.gz"
$ZlibSha256     = '9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23'

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @())
    Write-Host "+ $Exe $($Arguments -join ' ')"
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}

# CMake reads backslashes in a -D value as escapes once it lands in a list or a string.
function ConvertTo-CMakePath([string]$Path) { $Path -replace '\\', '/' }

function Get-Pinned {
    param([string]$Url, [string]$Sha256, [string]$OutFile)
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -MaximumRetryCount 3 -RetryIntervalSec 5
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutFile).Hash.ToLower()
    if ($got -ne $Sha256) { throw "sha256 mismatch for ${Url}: got $got, want $Sha256" }
}

# The MSVC developer environment: already there (a Developer prompt, ilammy/msvc-dev-cmd), else
# the newest Visual Studio with the C++ workload, through vswhere and vcvars64.bat.
function Import-MsvcEnv {
    if (Get-Command cl.exe -ErrorAction SilentlyContinue) { return }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'cl.exe is not on PATH and vswhere.exe was not found' }
    $vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsRoot) { throw 'vswhere found no Visual Studio with the C++ workload' }
    $vcvars = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvars64.bat'
    $lines = & cmd.exe /d /s /c "`"$vcvars`" >nul 2>&1 && set"
    if ($LASTEXITCODE -ne 0) { throw "$vcvars failed" }
    foreach ($line in $lines) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { [Environment]::SetEnvironmentVariable($line.Substring(0, $i), $line.Substring($i + 1)) }
    }
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { throw 'vcvars64.bat ran but cl.exe is still not on PATH' }
}
Import-MsvcEnv

# Git for Windows puts its coreutils link.exe on PATH; MSVC's must come first.
$clDir = Split-Path -Parent (Get-Command cl.exe -CommandType Application | Select-Object -First 1).Source
$env:PATH = "$clDir;$env:PATH"
$python = (Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $python) { throw 'python.exe must be on PATH (upstream generates its version and string tables with it)' }

$src     = $env:CVC_SOURCE_DIR
$work    = Join-Path $env:CVC_BUILD_DIR 'cvcpkg'
$private = Join-Path $work 'prefix'   # minizip and WTL: build-only, linked or compiled in, not shipped
$dl      = Join-Path $work 'downloads'
New-Item -ItemType Directory -Force -Path $work, $private, $dl | Out-Null
$prefixPath = (@($env:CVC_DEPS_PREFIX, $env:CVC_BUILD_PREFIX, $private) |
    Where-Object { $_ } | ForEach-Object { $_ -replace '\\', '/' } | Select-Object -Unique) -join ';'

# --- WTL (header-only; nuget.org's package of the SourceForge release) -------------------------
$wtlPkg = Join-Path $dl "wtl.$WtlVersion.zip"
Get-Pinned $WtlUrl $WtlSha256 $wtlPkg
$wtlDir = Join-Path $work 'wtl'
if (Test-Path $wtlDir) { Remove-Item -Recurse -Force $wtlDir }
Expand-Archive -LiteralPath $wtlPkg -DestinationPath $wtlDir
$wtlInclude = Join-Path $wtlDir 'lib\native\include'
if (-not (Test-Path (Join-Path $wtlInclude 'atlapp.h'))) { throw 'WTL: atlapp.h not found in the package' }

# --- minizip (zlib's contrib/minizip, static) ---------------------------------------------------
$zlibTgz = Join-Path $dl "zlib-$ZlibVersion.tar.gz"
Get-Pinned $ZlibUrl $ZlibSha256 $zlibTgz
$zlibSrc = Join-Path $work "zlib-$ZlibVersion"
if (Test-Path $zlibSrc) { Remove-Item -Recurse -Force $zlibSrc }
Invoke-Checked "$env:SystemRoot\System32\tar.exe" @('-xzf', $zlibTgz, '-C', $work)
$mzBuild = Join-Path $work 'minizip-build'
Invoke-Checked cmake @(
    '-G', 'Ninja', '-S', (Join-Path $scriptDir 'minizip'), '-B', $mzBuild,
    "-DCMAKE_BUILD_TYPE=$buildType",
    "-DCMAKE_INSTALL_PREFIX=$(ConvertTo-CMakePath $private)",
    "-DCMAKE_PREFIX_PATH=$prefixPath",
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=$msvcRuntime",
    '-DCMAKE_C_COMPILER=cl',
    "-DZLIB_SOURCE_DIR=$(ConvertTo-CMakePath $zlibSrc)"
)
Invoke-Checked cmake @('--build', $mzBuild, '-j', "$jobs")
Invoke-Checked cmake @('--install', $mzBuild)

# --- AirDC++ ------------------------------------------------------------------------------------
# cl.exe and rc.exe read INCLUDE: WTL for the GUI and its resource script (atlres.h), and the
# dependency prefix, as vcpkg's toolchain makes every installed header visible to upstream's build.
$env:INCLUDE = "$wtlInclude;$(Join-Path $env:CVC_DEPS_PREFIX 'include');$env:INCLUDE"
$airBuild = Join-Path $env:CVC_BUILD_DIR 'airdcpp'
Invoke-Checked cmake @(
    '-G', 'Ninja', '-S', $src, '-B', $airBuild,
    "-DCMAKE_BUILD_TYPE=$buildType",
    "-DCMAKE_INSTALL_PREFIX=$(ConvertTo-CMakePath $env:CVC_INSTALL_DIR)",
    "-DCMAKE_PREFIX_PATH=$prefixPath",
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=$msvcRuntime",
    '-DCMAKE_C_COMPILER=cl', '-DCMAKE_CXX_COMPILER=cl',
    # The core and the Web API are static libraries linked into AirDC.exe, as upstream builds them.
    '-DBUILD_SHARED_LIBS=OFF',
    "-DAIRDCPP_VERSION=$AirdcppVersion",
    "-DPYTHON_EXECUTABLE=$(ConvertTo-CMakePath $python.Source)",
    '-DENABLE_NATPMP=OFF',
    '-DENABLE_TBB=OFF'
)
Invoke-Checked cmake @('--build', $airBuild, '-j', "$jobs")
Invoke-Checked cmake @('--install', $airBuild)

$bin = Join-Path $env:CVC_INSTALL_DIR 'bin'
if (-not (Test-Path (Join-Path $bin 'AirDC.exe'))) { throw 'bin\AirDC.exe was not installed' }
Get-ChildItem $bin -Filter '*.pdb' | Remove-Item -Force

# --- Runtime files, laid out as upstream's portable release (scripts\make_release.bat) ----------
$installer = Join-Path $src 'installer'
foreach ($dir in 'EmoPacks', 'Themes') {
    Copy-Item -Recurse -Force (Join-Path $installer $dir) (Join-Path $bin $dir)
}
Copy-Item -Force (Join-Path $installer 'popup.bmp') $bin
# The installed (not portable) boot file: settings under Documents\AirDC++ and
# %LOCALAPPDATA%\AirDC++, not inside the prefix. See the recipe's notes for portable use.
Copy-Item -Force (Join-Path $installer 'dcppboot.nonlocal.xml') (Join-Path $bin 'dcppboot.xml')

$webTgz = Join-Path $dl "airdcpp-webui-$WebUiVersion.tgz"
Get-Pinned $WebUiUrl $WebUiSha256 $webTgz
$webDir = Join-Path $work 'airdcpp-webui'
if (Test-Path $webDir) { Remove-Item -Recurse -Force $webDir }
New-Item -ItemType Directory -Force -Path $webDir | Out-Null
Invoke-Checked "$env:SystemRoot\System32\tar.exe" @('-xzf', $webTgz, '-C', $webDir)
$resources = Join-Path $bin 'Web-resources'
if (Test-Path $resources) { Remove-Item -Recurse -Force $resources }
Copy-Item -Recurse -Force (Join-Path $webDir 'package\dist') $resources
if (-not (Test-Path (Join-Path $resources 'index.html'))) { throw 'the Web UI has no index.html' }

# --- Licences -----------------------------------------------------------------------------------
$licenses = Join-Path $env:CVC_INSTALL_DIR 'share\licenses\airdcpp-windows'
New-Item -ItemType Directory -Force -Path $licenses | Out-Null
Copy-Item -Force (Join-Path $src 'LICENSE') (Join-Path $licenses 'LICENSE')
Copy-Item -Force (Join-Path $webDir 'package\LICENSE') (Join-Path $licenses 'airdcpp-webui-LICENSE')
Copy-Item -Force (Join-Path $wtlDir 'license\license.txt') (Join-Path $licenses 'WTL-MS-PL.txt')
# minizip's licence is the zlib licence, stated at the top of each of its sources.
$unzip = Get-Content -LiteralPath (Join-Path $zlibSrc 'contrib\minizip\unzip.h') -TotalCount 60
($unzip -join "`n") | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $licenses 'minizip-unzip.h-header.txt')
@"
AirDC++ $AirdcppVersion for Windows, built from https://github.com/airdcpp/airdcpp-windows (tag
$AirdcppVersion) by the cvcpkg recipe in https://github.com/cy-pca/airdcpp-windows.

AirDC++ is free software under the GNU General Public License, version 3 or (at your option) any
later version: LICENSE (upstream's copy of the GPL-3.0 text).

Compiled into AirDC.exe:
- WTL $WtlVersion (Windows Template Library), Microsoft Public License: WTL-MS-PL.txt.
- minizip from zlib $ZlibVersion (contrib/minizip), zlib licence: minizip-unzip.h-header.txt.

Shipped beside it:
- Web-resources\: the AirDC++ Web UI $WebUiVersion (https://github.com/airdcpp-web/airdcpp-webui),
  MIT: airdcpp-webui-LICENSE.
- EmoPacks\, Themes\, popup.bmp and dcppboot.xml, from upstream's installer\ directory.

Every DLL AirDC.exe loads comes from its own cvcpkg package (boost, openssl, zlib, bzip2,
miniupnpc, leveldb, libmaxminddb), with that package's licence under share\licenses\.
"@ | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $licenses 'README')

Write-Host "cvcpkg: airdcpp-windows -> $env:CVC_INSTALL_DIR (bin\AirDC.exe and its runtime files)"
