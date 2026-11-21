# recipes/airdcpp-windows/build.ps1 -- the AirDC++ Windows desktop client from upstream's source
# with MSVC, against cvcpkg's shared dependencies, plus the runtime files upstream's portable
# release ships beside AirDC.exe. See the recipe's notes for why each piece is where it is.
#
# Every input except the compiler is a cvcpkg package: the libraries, WTL, minizip and the Web UI
# from the dependency prefix, and cmake, ninja and python from cvcpkg's own packages in the build
# or dependency prefix (never the machine's). The compiler is MSVC: a Visual Studio developer
# environment, or a Visual Studio with the C++ workload that vswhere can find. Self-contained: it
# does not source cvcpkg's recipes/_common/env-windows.ps1, because this recipe lives outside
# cvcpkg's tree.
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

$AirdcppVersion = '4.30'

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @())
    Write-Host "+ $Exe $($Arguments -join ' ')"
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}

# CMake reads backslashes in a -D value as escapes once it lands in a list or a string.
function ConvertTo-CMakePath([string]$Path) { $Path -replace '\\', '/' }

# The cvcpkg prefixes: the build closure (host tools, build-only packages) and the runtime one.
$cvcRoots = @($env:CVC_BUILD_PREFIX, $env:CVC_DEPS_PREFIX) | Where-Object { $_ } |
    ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique

# A file from one of cvcpkg's packages, by its path under a prefix; never the machine's copy.
function Find-CvcFile([string]$RelPath, [string]$Package) {
    foreach ($root in $cvcRoots) {
        $p = Join-Path $root $RelPath
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw "$RelPath (cvcpkg package '$Package') is in neither the build nor the dependency prefix: run cvcpkg install-deps airdcpp-windows --include-host-tools"
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
$cmake  = Find-CvcFile 'bin\cmake.exe' 'cmake'
$ninja  = Find-CvcFile 'bin\ninja.exe' 'ninja'
# Upstream generates its version and string tables with python.
$python = Find-CvcFile 'python.exe' 'python312'
$wtlInclude = Find-CvcFile 'include\wtl' 'wtl'
$webUi  = Find-CvcFile 'share\airdcpp-webui' 'airdcpp-webui'
& $cmake --version | Select-Object -First 1
Write-Host "cmake  $cmake`nninja  $ninja`npython $python`nWTL    $wtlInclude`nWeb UI $webUi"

$src = $env:CVC_SOURCE_DIR
$prefixPath = ($cvcRoots | ForEach-Object { ConvertTo-CMakePath $_ }) -join ';'

# --- AirDC++ ------------------------------------------------------------------------------------
# cl.exe and rc.exe read INCLUDE: WTL (cvcpkg's wtl, include\wtl) for the GUI and its resource
# script (atlres.h), and the dependency prefix, as vcpkg's toolchain makes every installed header
# visible to upstream's build.
$env:INCLUDE = "$wtlInclude;$(Join-Path $env:CVC_DEPS_PREFIX 'include');$env:INCLUDE"
$airBuild = Join-Path $env:CVC_BUILD_DIR 'airdcpp'
Invoke-Checked $cmake @(
    '-G', 'Ninja', '-S', $src, '-B', $airBuild,
    "-DCMAKE_MAKE_PROGRAM=$(ConvertTo-CMakePath $ninja)",
    "-DCMAKE_BUILD_TYPE=$buildType",
    "-DCMAKE_INSTALL_PREFIX=$(ConvertTo-CMakePath $env:CVC_INSTALL_DIR)",
    "-DCMAKE_PREFIX_PATH=$prefixPath",
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=$msvcRuntime",
    '-DCMAKE_C_COMPILER=cl', '-DCMAKE_CXX_COMPILER=cl',
    # The core and the Web API are static libraries linked into AirDC.exe, as upstream builds them.
    '-DBUILD_SHARED_LIBS=OFF',
    "-DAIRDCPP_VERSION=$AirdcppVersion",
    "-DPYTHON_EXECUTABLE=$(ConvertTo-CMakePath $python)",
    '-DENABLE_NATPMP=OFF',
    '-DENABLE_TBB=OFF'
)
Invoke-Checked $cmake @('--build', $airBuild, '-j', "$jobs")
Invoke-Checked $cmake @('--install', $airBuild)

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

# The Web UI from cvcpkg's airdcpp-webui, where AirDC.exe's web server looks for it.
$resources = Join-Path $bin 'Web-resources'
if (Test-Path $resources) { Remove-Item -Recurse -Force $resources }
Copy-Item -Recurse -Force $webUi $resources
if (-not (Test-Path (Join-Path $resources 'index.html'))) { throw 'the Web UI has no index.html' }

# --- Licences -----------------------------------------------------------------------------------
$licenses = Join-Path $env:CVC_INSTALL_DIR 'share\licenses\airdcpp-windows'
New-Item -ItemType Directory -Force -Path $licenses | Out-Null
Copy-Item -Force (Join-Path $src 'LICENSE') (Join-Path $licenses 'LICENSE')
# The licences of what is compiled in or copied in, beside upstream's own.
Copy-Item -Force (Join-Path (Find-CvcFile 'share\licenses\wtl' 'wtl') 'LICENSE') (Join-Path $licenses 'WTL-LICENSE')
Copy-Item -Force (Join-Path (Find-CvcFile 'share\licenses\airdcpp-webui' 'airdcpp-webui') 'LICENSE') (Join-Path $licenses 'airdcpp-webui-LICENSE')
@"
AirDC++ $AirdcppVersion for Windows, built from https://github.com/airdcpp/airdcpp-windows (tag
$AirdcppVersion) by the cvcpkg recipe in https://github.com/cy-pca/airdcpp-windows.

AirDC++ is free software under the GNU General Public License, version 3 or (at your option) any
later version: LICENSE (upstream's copy of the GPL-3.0 text).

Compiled into AirDC.exe: WTL (cvcpkg's wtl, Microsoft Public License: WTL-LICENSE).

Shipped beside it:
- Web-resources\: the AirDC++ Web UI (cvcpkg's airdcpp-webui,
  https://github.com/airdcpp-web/airdcpp-webui), MIT: airdcpp-webui-LICENSE.
- EmoPacks\, Themes\, popup.bmp and dcppboot.xml, from upstream's installer\ directory.

Every DLL AirDC.exe loads comes from its own cvcpkg package (boost, openssl, zlib, bzip2,
miniupnpc, leveldb, snappy, libmaxminddb, minizip), with that package's licence under share\licenses\.
"@ | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $licenses 'README')

Write-Host "cvcpkg: airdcpp-windows -> $env:CVC_INSTALL_DIR (bin\AirDC.exe and its runtime files)"
