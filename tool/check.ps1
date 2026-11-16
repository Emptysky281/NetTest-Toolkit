[CmdletBinding()]
param(
    [string]$FlutterPath = 'flutter',
    [switch]$IncludeExternalNetworkTests,
    [switch]$SkipPubGet,
    # Optional analyzer from the same Flutter SDK; useful for Flutter CLI LSP issues.
    [string]$DartPath = ''
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Split-Path $PSScriptRoot -Parent)).Path
$externalRoot = (Join-Path $root 'test\external') + [IO.Path]::DirectorySeparatorChar
$oldOpenSsl = [Environment]::GetEnvironmentVariable('NETTEST_OPENSSL_DIR', 'Process')
Get-Command -Name $FlutterPath -ErrorAction Stop | Out-Null
if ($DartPath) { Get-Command -Name $DartPath -ErrorAction Stop | Out-Null }
Push-Location -LiteralPath $root
try {
    if ($env:OS -eq 'Windows_NT') {
        $env:NETTEST_OPENSSL_DIR = Join-Path $root 'windows\openssl'
    }
    if (-not $SkipPubGet) {
        & $FlutterPath pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
    }
    if ($DartPath) {
        & $DartPath analyze --fatal-infos
    } else {
        & $FlutterPath analyze --no-pub
    }
    if ($LASTEXITCODE -ne 0) { throw 'Static analysis failed' }
    $tests = @(Get-ChildItem -LiteralPath (Join-Path $root 'test') -Filter '*_test.dart' -File -Recurse |
        Where-Object {
            $IncludeExternalNetworkTests -or
                -not $_.FullName.StartsWith($externalRoot, [StringComparison]::OrdinalIgnoreCase)
        } |
        Sort-Object FullName | ForEach-Object { $_.FullName })
    if ($tests.Count -eq 0) { throw 'No test files were discovered' }
    Write-Host "Running $($tests.Count) test files (include external network: $([bool]$IncludeExternalNetworkTests))."
    & $FlutterPath test --no-pub --reporter expanded @tests
    if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed' }
}
finally {
    [Environment]::SetEnvironmentVariable('NETTEST_OPENSSL_DIR', $oldOpenSsl, 'Process')
    Pop-Location
}
