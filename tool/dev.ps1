# Dev helper: build / install / tap / screenshot on the connected Android device or emulator.
# usage: .\tool\dev.ps1 build | install | tap X Y | shot NAME | text "string" | key CODE
param([string]$cmd, [string]$a, [string]$b)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
# Target only the emulator so a phone plugged in for testing is never touched.
$env:ANDROID_SERIAL = if ($env:NETTEST_ADB_SERIAL) { $env:NETTEST_ADB_SERIAL } else { "emulator-5554" }
switch ($cmd) {
  "build" {
    $env:PATH = "$env:USERPROFILE\dev\flutter\bin;$env:PATH"
    if (-not $env:JAVA_HOME) { $env:JAVA_HOME = "C:\Program Files\Microsoft\jdk-21.0.12.101-hotspot" }
    # JDK 21 on Windows needs a long-path tmpdir for AF_UNIX pipes (Gradle/sdkmanager)
    $env:JAVA_TOOL_OPTIONS = "-Djdk.net.unixdomain.tmpdir=$env:USERPROFILE\dev\jtmp"
    $env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"; $env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
    $extra = if ($a) { $a -split " " } else { @("--debug") }
    Push-Location $root; flutter build apk @extra 2>&1 | Select-String "Built|FAIL|error" | ForEach-Object Line; Pop-Location
  }
  "install" {
    & $adb install -r "$root\build\app\outputs\flutter-apk\app-debug.apk" 2>&1 | Select-Object -Last 1
    & $adb shell am start -W -n com.nettest.nettest/.MainActivity 2>&1 | Select-Object -Last 1
  }
  "tap" { & $adb shell input tap $a $b }
  "text" { & $adb shell input text $a }
  "key" { & $adb shell input keyevent $a }
  "shot" {
    & $adb shell screencap -p /sdcard/s.png
    & $adb pull /sdcard/s.png "$root\build\shot_$a.png" 2>&1 | Select-Object -Last 1
  }
}
