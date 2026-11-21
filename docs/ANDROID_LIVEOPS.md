# Android LiveOps implementation

The native module is intentionally kept under native/android so the generated Flutter Android project and Gradle wrapper stay compatible with the Flutter SDK installed on the developer machine.

Run tool/bootstrap-platforms.ps1 from PowerShell (Windows) or tool/bootstrap-platforms.sh from Bash (Linux/macOS/CI). The script generates Android and Web folders, applies the KOMNIVO package ID and overlays the native LiveOps source.

LiveOps uses Android MediaProjection after the user explicitly taps Start and grants the Android system prompt. The foreground service samples at most one useful frame per second and runs Google ML Kit text recognition on-device. It emits extracted text to Flutter. It does not retain or upload raw frames and it does not control the game client.

Android 13 uses full-display capture; advise users to hide notifications and stop capture before opening private applications. The organiser must still approve roster checks and match results. An OCR string is never an official result.

## Selected screenshot evidence batches

LiveOps can pause the MediaProjection session and let the operator choose 1–8 standing-result screenshots from the Android gallery. Supported formats are JPEG, PNG and WebP, with the private `match-evidence` bucket's 10 MiB per-object limit.

The selected image bytes are passed to a separate Android ML Kit still-image OCR method. The app calculates SHA-256 and shows the local OCR preview before upload. Continuous screen frames remain local; only the screenshots the operator explicitly confirms are uploaded.

Each registered batch is bound server-side to the authenticated operator, the current LiveOps session, the Lobby ID and the active Match ID. The batch stores ordered capture records and one OCR observation per screenshot. Exact duplicate image hashes are rejected within the same session + Match ID; the same image hash remains valid for another Match ID.

Files are stored in the private `match-evidence` bucket. Database registration is atomic and idempotent. An upload that fails before registration is eligible for uploader-only cleanup; once a file is linked to a capture row, the Storage delete policy blocks removal.

OCR text is provisional source material, not an official result. Team identity/placement/kill reconciliation, overlap merging by canonical team ID, reviewer corrections and the evidence-gated Next Match action remain separate steps. Operators should hide notifications and unrelated private content before selecting screenshots.
