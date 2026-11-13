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

  # These platform folders are generated/ignored build scaffolding. Replace
  # them so old launcher resources or stale files cannot survive a bootstrap.
  $AndroidTarget = Join-Path $Root "android"
  $WebTarget = Join-Path $Root "web"
  foreach ($Target in @($AndroidTarget, $WebTarget)) {
    if (Test-Path $Target) {
      Remove-Item -Path $Target -Recurse -Force
    }
  }
  Copy-Item (Join-Path $Temp "android") $AndroidTarget -Recurse -Force
  Copy-Item (Join-Path $Temp "web") $WebTarget -Recurse -Force

  $Native = Join-Path $Root "native/android/app/src/main"
  Copy-Item (Join-Path $Native "AndroidManifest.xml") (Join-Path $Root "android/app/src/main/AndroidManifest.xml") -Force
  $NativeResources = Join-Path $Native "res"
  $ResourceTarget = Join-Path $Root "android/app/src/main/res"
  New-Item -ItemType Directory -Path $ResourceTarget -Force | Out-Null

  # flutter create ships a stock Flutter launcher image in density-specific mipmap
  # folders. Android prefers those over our density-independent KOMNIVO XML icon,
  # so remove only the generated launcher files before overlaying native resources.
  foreach ($Density in @("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi")) {
    $GeneratedMipmap = Join-Path $ResourceTarget ("mipmap-" + $Density)
    if (Test-Path $GeneratedMipmap) {
      Get-ChildItem -Path $GeneratedMipmap -File -Filter "ic_launcher*" |
        Remove-Item -Force
    }
  }

  Get-ChildItem $NativeResources -Force | Copy-Item -Destination $ResourceTarget -Recurse -Force
  $KotlinTarget = Join-Path $Root "android/app/src/main/kotlin/in/komnivo/app"
  New-Item -ItemType Directory -Path $KotlinTarget -Force | Out-Null
  Copy-Item (Join-Path $Native "kotlin/in/komnivo/app/*.kt") $KotlinTarget -Force

  $GradleFile = Join-Path $Root "android/app/build.gradle.kts"
  $Gradle = Get-Content $GradleFile -Raw
  $AndroidPlugin = '    id("com.android.application")'
  if ($Gradle -notmatch 'id\("org\.jetbrains\.kotlin\.android"\)') {
    if (-not $Gradle.Contains($AndroidPlugin)) {
      throw "Could not find the Android application plugin in build.gradle.kts."
    }
    $Gradle = $Gradle.Replace($AndroidPlugin, $AndroidPlugin + [Environment]::NewLine + '    id("org.jetbrains.kotlin.android")')
  }
  $Gradle = [regex]::Replace($Gradle, 'namespace\s*=\s*".*?"', 'namespace = "in.komnivo.app"')
  $Gradle = [regex]::Replace($Gradle, 'applicationId\s*=\s*".*?"', 'applicationId = "in.komnivo.app"')
  if ($Gradle -notmatch 'com.google.mlkit:text-recognition') {
    $nl = [Environment]::NewLine
    $Gradle += $nl + $nl + 'dependencies {' + $nl + '    implementation("com.google.mlkit:text-recognition:16.0.1")' + $nl + '}' + $nl
  }
  Set-Content -Path $GradleFile -Value $Gradle -Encoding utf8
  Copy-Item (Join-Path $Root "native/web/index.html") (Join-Path $Root "web/index.html") -Force
  Copy-Item (Join-Path $Root "native/web/manifest.json") (Join-Path $Root "web/manifest.json") -Force

  # Copy public product, policy and isolated Firebase Messaging worker files.
  $IconTarget = Join-Path $Root "web/icons"
  New-Item -ItemType Directory -Path $IconTarget -Force | Out-Null
  Copy-Item (Join-Path $Root "native/web/icons/*.png") $IconTarget -Force

  $BrandTarget = Join-Path $Root "web/brand"
  New-Item -ItemType Directory -Path $BrandTarget -Force | Out-Null
  Copy-Item (Join-Path $Root "native/web/brand/komnivo-mark.svg") (Join-Path $BrandTarget "komnivo-mark.svg") -Force
  foreach ($Page in @("about", "privacy", "terms")) {
    $PageTarget = Join-Path $Root ("web/" + $Page)
    New-Item -ItemType Directory -Path $PageTarget -Force | Out-Null
    Copy-Item (Join-Path $Root ("native/web/" + $Page + "/index.html")) (Join-Path $PageTarget "index.html") -Force
  }
  $WorkerFolder = Join-Path $Root "web/firebase-cloud-messaging-push-scope"
  New-Item -ItemType Directory -Path $WorkerFolder -Force | Out-Null
  Copy-Item (Join-Path $Root "native/web/firebase-cloud-messaging-push-scope/firebase-messaging-sw.js") (Join-Path $WorkerFolder "firebase-messaging-sw.js") -Force

  # Firebase Web identifiers are public client configuration; no server keys here.
  $WorkerFile = Join-Path $WorkerFolder "firebase-messaging-sw.js"
  $Worker = Get-Content $WorkerFile -Raw
  $FirebaseValues = @{
    FIREBASE_API_KEY = $env:FIREBASE_API_KEY
    FIREBASE_AUTH_DOMAIN = $env:FIREBASE_AUTH_DOMAIN
    FIREBASE_PROJECT_ID = $env:FIREBASE_PROJECT_ID
    FIREBASE_STORAGE_BUCKET = $env:FIREBASE_STORAGE_BUCKET
    FIREBASE_MESSAGING_SENDER_ID = $env:FIREBASE_MESSAGING_SENDER_ID
    FIREBASE_APP_ID = $env:FIREBASE_APP_ID
  }
  foreach ($Name in $FirebaseValues.Keys) {
    $Value = [string]$FirebaseValues[$Name]
    $Replacement = ConvertTo-Json -InputObject $Value -Compress
    $Worker = $Worker.Replace(('"' + "__" + $Name + "__" + '"'), $Replacement)
  }
  Set-Content -Path $WorkerFile -Value $Worker -Encoding utf8

  Write-Host "Android, Web app, public pages and isolated FCM worker are ready."
} finally {
  if (Test-Path $Temp) { Remove-Item $Temp -Recurse -Force }
}
