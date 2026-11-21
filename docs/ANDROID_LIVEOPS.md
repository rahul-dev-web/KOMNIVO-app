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

## Reviewer-confirmed candidates and official result submission

Each Match ID can hold one canonical result candidate per Team ID. The operator maps on-device OCR text to the exact Match roster and links one or more source screenshot observations. Overlapping images add evidence provenance to the same candidate rather than creating another team row.

A candidate remains provisional/needs-review until an authorised referee or result reviewer accepts or rejects it. Review-confirmed placement and kills are stored separately from the original operator/OCR readings. When linked screenshots disagree, the reviewer must explicitly enter final values. Reopening a candidate clears stale reviewer-confirmed values; after official result rows exist, candidate edits are blocked and require the existing audited correction/dispute path.

The LiveOps operator can submit a Match only after every participant has one accepted candidate, reviewed placement and kills, unique placements, and at least one valid screenshot source. The submission RPC verifies the paused session, exact Lobby/Match binding, roster, reviewer decisions and still-present private Storage objects. It creates one `match_results` row per team and attaches only that team's candidate screenshot evidence to its `result_evidence` rows.

Submission is idempotent for the same LiveOps session and Match ID. It marks the Match as `review` and evidence batches as `submitted`. It does **not** approve results, calculate points or update the published leaderboard. The existing authorised `approve_match_result` / result-review workflow remains the only scoring and standings path.

The current slice has database migrations and contract tests for candidate provenance, reviewer confirmation, result-row materialisation, idempotent retry and candidate locking after official submission. Full signed-in Android/device acceptance, real Match data, result approval, scoring, public result publication and multi-Match LiveOps advancement remain separate release gates.

## Sequential multi-Match Lobby progression

The Lobby sequence is authoritative. Starting LiveOps resumes the operator's active session with its actual Match sequence and Match code; it does not accidentally label a resumed Match as sequence one. If the operator has no active session, recovery selects the first ordered Match that has no result submission and is not already active/closed.

After every team in the current Match has an accepted candidate, reviewer-confirmed placement/kills, and valid candidate-specific screenshot evidence, the operator submits the official result rows. Those rows enter the existing result-review queue in `match_results`; scoring and standings remain unchanged until an authorised result reviewer approves them.

Only then does the Next Match action call `start_next_liveops_lobby_session`. The server locks the previous session/Lobby/next Match, checks the exact same Lobby and increasing sequence number, verifies the previous Match has a complete official result submission from that exact LiveOps session, and creates one successor session. A unique predecessor link makes retries idempotent. The previous session is closed; the next one is prepared in `created` state. Android screen capture begins only when the operator presses Start.

A successor session stores its immutable `previous_session_id`; deleting a predecessor is restricted. If the last Match is complete, the server reports that no unsubmitted Match remains. A Match already containing official results is not selected again during Lobby recovery.

The live Supabase schema and RPC contracts have been checked. The live project currently has no Matches or LiveOps sessions, so real multi-Match execution still requires a populated Lobby and signed-in Android device smoke test.

## Reviewer-side screenshot inspection

The Organizer Event Operations candidate-review queue fetches the exact source captures linked to a candidate. Before opening Accept or Reject, it requests a 15-minute signed URL for every source image from the private `match-evidence` bucket and shows each screenshot alongside that screenshot's own OCR placement/kills.

The storage read policy authorises either the original uploader or a user with `match.results.review` permission for the exact Match ID. The bucket remains private; no public object URL is created. If any screenshot cannot be signed, the UI blocks both Accept and Reject and asks the reviewer to restore evidence access before making a decision.

## Match-scoped reviewer read access

The Event Operations OCR review queue is available to an authorised reviewer scoped only to the Match being reviewed. Candidate-row RLS and team name/tag RLS both accept `match.results.review` at that exact Match ID; the broader event-staff and operator paths remain intact. The reviewer can read the participant roster/candidate evidence and issue signed screenshot previews for the same Match without gaining access to unrelated team records.
