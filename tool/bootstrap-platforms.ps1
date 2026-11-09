# Generate Flutter Android and Web scaffolding, then install the KOMNIVO native module.
$ErrorActionPreference = "Stop"
$Root = (Get-Location).Path
if (-not (Test-Path (Join-Path $Root "pubspec.yaml"))) {
  throw "Run this script from the KOMNIVO repository root (pubspec.yaml not found)."
}
$Temp = Join-Path $env:TEMP ("komnivo-platforms-" + [guid]::NewGuid().ToString("N"))
try {
  flutter create --project-name app --org in.komnivo --platforms android,web $Temp
  if ($LASTEXITCODE -ne 0) { throw "flutter create failed." }

  Copy-Item (Join-Path $Temp "android") (Join-Path $Root "android") -Recurse -Force
  Copy-Item (Join-Path $Temp "web") (Join-Path $Root "web") -Recurse -Force

  $Native = Join-Path $Root "native/android/app/src/main"
  Copy-Item (Join-Path $Native "AndroidManifest.xml") (Join-Path $Root "android/app/src/main/AndroidManifest.xml") -Force
  $KotlinTarget = Join-Path $Root "android/app/src/main/kotlin/in/komnivo/app"
  New-Item -ItemType Directory -Path $KotlinTarget -Force | Out-Null
  Copy-Item (Join-Path $Native "kotlin/in/komnivo/app/*.kt") $KotlinTarget -Force

  $GradleFile = Join-Path $Root "android/app/build.gradle.kts"
  $Gradle = Get-Content $GradleFile -Raw
  $Gradle = [regex]::Replace($Gradle, 'namespace\s*=\s*".*?"', 'namespace = "in.komnivo.app"')
  $Gradle = [regex]::Replace($Gradle, 'applicationId\s*=\s*".*?"', 'applicationId = "in.komnivo.app"')
  if ($Gradle -notmatch 'com.google.mlkit:text-recognition') {
    $nl = [Environment]::NewLine
    $Gradle += $nl + $nl + 'dependencies {' + $nl + '    implementation("com.google.mlkit:text-recognition:16.0.1")' + $nl + '}' + $nl
  }
  Set-Content -Path $GradleFile -Value $Gradle -Encoding utf8
  Copy-Item (Join-Path $Root "native/web/index.html") (Join-Path $Root "web/index.html") -Force
  Write-Host "Android and Web platform folders are ready."
} finally {
  if (Test-Path $Temp) { Remove-Item $Temp -Recurse -Force }
}
