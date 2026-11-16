[CmdletBinding()]
param(
    [string]$FlutterPath = 'flutter',
    [string]$ReleaseDate = '2026-11-16',
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$date = [DateTime]::ParseExact($ReleaseDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$root = (Resolve-Path -LiteralPath (Split-Path $PSScriptRoot -Parent)).Path
$release = Join-Path $root 'build\windows\x64\runner\Release'
$dist = Join-Path $root 'dist'
$archive = Join-Path $dist ('archive\windows\' + $date.ToString('yyyy-MM-dd'))
$zipPath = Join-Path $archive ('NetTest-windows-x64-' + $date.ToString('yyyyMMdd') + '.zip')
if ((Test-Path -LiteralPath $zipPath) -or (Test-Path -LiteralPath "$zipPath.sha256")) {
    throw "Refusing to overwrite an existing release: $zipPath"
}
Push-Location -LiteralPath $root
try {
    if (-not $SkipBuild) {
        Get-Command -Name $FlutterPath -ErrorAction Stop | Out-Null
        & $FlutterPath build windows --release
        if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed' }
    }
    $required = @('nettest.exe', 'flutter_windows.dll', 'libssl-3.dll', 'libcrypto-3.dll',
        'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/NOTICES.Z')
    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $release $name) -PathType Leaf)) {
            throw "Missing release runtime: $name"
        }
    }
    if (Test-Path -LiteralPath (Join-Path $release 'nettest.instance.json')) {
        throw 'Do not package a child-instance bundle as the main release'
    }
    $documents = @{
        '使用说明.md' = (Join-Path $root "docs\releases\$ReleaseDate.md")
        'CHANGELOG.md' = (Join-Path $root 'CHANGELOG.md')
        'THIRD_PARTY_NOTICES.md' = (Join-Path $root 'THIRD_PARTY_NOTICES.md')
        'OPENSSL_README.txt' = (Join-Path $root 'windows\openssl\README.txt')
        'OpenSSL-LICENSE.txt' = (Join-Path $root 'windows\openssl\LICENSE.txt')
    }
    foreach ($document in $documents.Values) {
        if (-not (Test-Path -LiteralPath $document -PathType Leaf)) { throw "Missing document: $document" }
    }
    New-Item -ItemType Directory -Path $archive -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($release, $zipPath,
        [IO.Compression.CompressionLevel]::Optimal, $false)
    $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Update)
    try {
        foreach ($name in $documents.Keys) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $documents[$name], $name) | Out-Null
        }
    }
    finally { $zip.Dispose() }
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($name in $required) {
            $entry = $zip.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq $name } | Select-Object -First 1
            if ($null -eq $entry) { throw "Missing ZIP entry: $name" }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $actual = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
            finally { $stream.Dispose(); $sha.Dispose() }
            $expected = (Get-FileHash -LiteralPath (Join-Path $release $name) -Algorithm SHA256).Hash
            if ($actual -ne $expected) { throw "Runtime differs in ZIP: $name" }
        }
    }
    finally { $zip.Dispose() }
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$zipPath.sha256", "$hash  $([IO.Path]::GetFileName($zipPath))`n",
        [Text.UTF8Encoding]::new($false))
    Write-Output "Created: $zipPath"
    Write-Output "SHA-256: $hash"
}
finally { Pop-Location }
