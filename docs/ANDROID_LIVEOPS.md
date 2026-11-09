# Android LiveOps implementation

The native module is intentionally kept under native/android so the generated Flutter Android project and Gradle wrapper stay compatible with the Flutter SDK installed on the developer machine.

Run tool/bootstrap-platforms.ps1 from PowerShell (Windows) or tool/bootstrap-platforms.sh from Bash (Linux/macOS/CI). The script generates Android and Web folders, applies the KOMNIVO package ID and overlays the native LiveOps source.

LiveOps uses Android MediaProjection after the user explicitly taps Start and grants the Android system prompt. The foreground service samples at most one useful frame per second and runs Google ML Kit text recognition on-device. It emits extracted text to Flutter. It does not retain or upload raw frames and it does not control the game client.

Android 13 uses full-display capture; advise users to hide notifications and stop capture before opening private applications. The organiser must still approve roster checks and match results. An OCR string is never an official result.
