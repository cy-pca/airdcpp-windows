# airdcpp-windows smoke test, run by cvcpkg on the staged tree before packing (through test.sh),
# and by cvcpkg-publish.yml on the bundle installed from cvcpkg.org.
#
# 1. The files: bin\AirDC.exe (an x64 GUI executable) and the runtime files beside it.
# 2. Its DLLs: every one AirDC.exe imports is in the bundle, in the dependency prefix, or a
#    Windows system DLL (dumpbin /dependents; skipped, with a note, if dumpbin is not on PATH).
# 3. A headless start: AirDC.exe runs from a temporary copy in LocalMode, with a settings
#    directory prepared so the setup wizard does not open and the built-in web server listens on
#    a free 127.0.0.1 port. Its Web API reports the client version, the Web UI's index is served
#    from the bundle's Web-resources, and the API's shutdown call ends the process with exit code
#    0. Nothing touches the user's own AirDC++ settings or Documents.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$wantVersion = '4.30'
$inst = [IO.Path]::GetFullPath($env:CVC_INSTALL_DIR)
$deps = [IO.Path]::GetFullPath($env:CVC_DEPS_PREFIX)
$bin = Join-Path $inst 'bin'
$depsBin = Join-Path $deps 'bin'
$exe = Join-Path $bin 'AirDC.exe'

function Fail([string]$msg) { Write-Host "FAIL: $msg"; exit 1 }

# --- 1. Files -----------------------------------------------------------------------------------
foreach ($f in 'AirDC.exe', 'dcppboot.xml', 'popup.bmp', 'Web-resources\index.html') {
    if (-not (Test-Path -LiteralPath (Join-Path $bin $f) -PathType Leaf)) { Fail "bin\$f is missing" }
}
foreach ($d in 'EmoPacks', 'Themes') {
    if (-not (Get-ChildItem -LiteralPath (Join-Path $bin $d) -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Fail "bin\$d is missing or empty"
    }
}
if ((Get-Content -Raw -LiteralPath (Join-Path $bin 'dcppboot.xml')) -notmatch '<LocalMode>0</LocalMode>') {
    Fail 'bin\dcppboot.xml is not the installed-mode (LocalMode 0) boot file'
}

$bytes = [IO.File]::ReadAllBytes($exe)
$pe = [BitConverter]::ToInt32($bytes, 0x3c)
if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x00004550) { Fail 'AirDC.exe has no PE signature' }
$machine = [BitConverter]::ToUInt16($bytes, $pe + 4)
$subsystem = [BitConverter]::ToUInt16($bytes, $pe + 24 + 68)
if ($machine -ne 0x8664) { Fail ('AirDC.exe is not x86-64 (machine 0x{0:x4})' -f $machine) }
if ($subsystem -ne 2) { Fail "AirDC.exe is not a Windows GUI executable (subsystem $subsystem)" }
Write-Host ('AirDC.exe: x86-64 GUI executable, {0:N1} MB' -f ($bytes.Length / 1MB))

# --- 2. DLLs ------------------------------------------------------------------------------------
$dumpbin = Get-Command dumpbin.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($dumpbin) {
    $out = & $dumpbin.Source /nologo /dependents $exe
    if ($LASTEXITCODE -ne 0) { Fail 'dumpbin /dependents failed' }
    $dlls = @($out | ForEach-Object { if ($_ -match '^\s+(\S+\.dll)\s*$') { $Matches[1] } })
    if ($dlls.Count -eq 0) { Fail 'dumpbin listed no DLLs' }
    $system32 = Join-Path $env:SystemRoot 'System32'
    $missing = @()
    foreach ($dll in $dlls) {
        if ($dll -match '^(api|ext)-ms-') { continue }   # API sets, resolved by the loader
        $where = if (Test-Path -LiteralPath (Join-Path $bin $dll)) { 'bundle' }
            elseif (Test-Path -LiteralPath (Join-Path $depsBin $dll)) { 'dependency prefix' }
            elseif (Test-Path -LiteralPath (Join-Path $system32 $dll)) { 'Windows' }
            else { $null }
        if ($where) { Write-Host ("  {0,-28} {1}" -f $dll, $where) } else { $missing += $dll }
    }
    if ($missing) { Fail "AirDC.exe imports DLLs found nowhere: $($missing -join ', ')" }
} else {
    Write-Host 'note: dumpbin.exe is not on PATH (no MSVC developer environment); DLL check skipped'
}

# --- 3. Headless start --------------------------------------------------------------------------
$T = Join-Path ([IO.Path]::GetTempPath()) ('airdcpp-smoke-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $T 'app'
$cfg = Join-Path $T 'cfg'
$tmp = Join-Path $T 'tmp'
New-Item -ItemType Directory -Force -Path $app, $cfg, $tmp | Out-Null
Copy-Item -LiteralPath $exe -Destination $app

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()

# LocalMode with every path pointed into $T; the resources (Web UI, emoticons, themes) are the
# bundle's own, read in place.
@"
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<Boot>
	<LocalMode>1</LocalMode>
	<ConfigPath>$cfg\</ConfigPath>
	<TempPath>$tmp\</TempPath>
	<ResourcePath>$bin\</ResourcePath>
</Boot>
"@ | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $app 'dcppboot.xml')
# No setup wizard, passive connectivity (no port mapping or connectivity probes), no exit prompt.
@"
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<DCPlusPlus>
	<Settings>
		<Nick>cvcpkg-smoke</Nick>
		<WizardRunNew>0</WizardRunNew>
		<IncomingConnections>2</IncomingConnections>
		<IncomingConnections6>-1</IncomingConnections6>
		<AutoDetectIncomingConnection>0</AutoDetectIncomingConnection>
		<AutoDetectIncomingConnection6>0</AutoDetectIncomingConnection6>
		<ConfirmExit>0</ConfirmExit>
	</Settings>
</DCPlusPlus>
"@ | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $cfg 'DCPlusPlus.xml')
@{ version = 1; settings = @{ web_plain_port = $port; web_plain_bind_address = '127.0.0.1'; web_tls_port = 0 } } |
    ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $cfg 'web-server.json')
@{ version = 1; settings = @{ users = @(@{ username = 'smoke'; password = 'smoke-pass'; last_login = 0; permissions = @('admin') }) } } |
    ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $cfg 'web-users.json')

$env:PATH = "$bin;$depsBin;$env:PATH"
$auth = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('smoke:smoke-pass')) }
$base = "http://127.0.0.1:$port"
$proc = $null
$ok = $false
try {
    $proc = Start-Process -FilePath (Join-Path $app 'AirDC.exe') -WorkingDirectory $app -PassThru
    $info = $null
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
        try { $info = Invoke-RestMethod -Uri "$base/api/v1/system/system_info" -Headers $auth -TimeoutSec 5; break }
        catch { Start-Sleep -Milliseconds 500 }
    }
    if ($proc.HasExited) { Fail "AirDC.exe exited during startup (exit code $($proc.ExitCode))" }
    if (-not $info) { Fail "AirDC.exe's Web API did not answer on port $port within 180 s" }
    Write-Host "system_info: client_version '$($info.client_version)', platform '$($info.platform)'"
    if ("$($info.client_version)" -notlike "AirDC++ $wantVersion*") {
        Fail "client_version is '$($info.client_version)', expected AirDC++ $wantVersion"
    }

    $index = Invoke-WebRequest -Uri "$base/" -Headers @{ Accept = 'text/html' } -TimeoutSec 10
    if ($index.Content -notmatch '(?i)<title') { Fail 'the Web UI index was not served' }
    Write-Host 'Web UI index served from the bundle''s Web-resources'

    Invoke-RestMethod -Method Post -Uri "$base/api/v1/system/shutdown" -Headers $auth -TimeoutSec 10 | Out-Null
    if (-not $proc.WaitForExit(90000)) { Fail 'AirDC.exe did not exit within 90 s of the shutdown call' }
    if ($proc.ExitCode -ne 0) { Fail ('AirDC.exe exited with code {0} (0x{0:x8}) after the shutdown call' -f $proc.ExitCode) }
    $ok = $true
    Write-Host "airdcpp-windows smoke test OK (AirDC++ $wantVersion, port $port)"
} finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    if (-not $ok) {
        Get-ChildItem -LiteralPath $cfg -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.log', '.txt' } |
            ForEach-Object { Write-Host "--- $($_.FullName)"; Get-Content -LiteralPath $_.FullName -Tail 50 }
    }
    Start-Sleep -Seconds 1
    Remove-Item -Recurse -Force -LiteralPath $T -ErrorAction SilentlyContinue
}
