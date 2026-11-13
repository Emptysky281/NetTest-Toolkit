[CmdletBinding()]
param(
    [string]$FlutterPath = 'flutter',
    [switch]$IncludeExternalNetworkTests,
    [switch]$SkipPubGet
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Split-Path $PSScriptRoot -Parent)).Path
$oldOpenSsl = [Environment]::GetEnvironmentVariable('NETTEST_OPENSSL_DIR', 'Process')
Get-Command -Name $FlutterPath -ErrorAction Stop | Out-Null
Push-Location -LiteralPath $root
try {
    if ($env:OS -eq 'Windows_NT') {
        $env:NETTEST_OPENSSL_DIR = Join-Path $root 'windows\openssl'
    }
    if (-not $SkipPubGet) {
        & $FlutterPath pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
    }
    & $FlutterPath analyze --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Static analysis failed' }
    $tests = if ($IncludeExternalNetworkTests) { @('test') } else {
        @(Get-ChildItem -LiteralPath (Join-Path $root 'test') -Filter '*_test.dart' -File |
            Where-Object { $_.Name -ne 'core_test.dart' } |
            Sort-Object Name | ForEach-Object { $_.FullName })
    }
    & $FlutterPath test --no-pub --reporter expanded @tests
    if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed' }
}
finally {
    [Environment]::SetEnvironmentVariable('NETTEST_OPENSSL_DIR', $oldOpenSsl, 'Process')
    Pop-Location
}
