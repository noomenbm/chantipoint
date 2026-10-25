# Normal-app attendance rehearsal — 2026-10-25

Normal `lib/main.dart` completed real fictional employee check-in/check-out on a
dedicated Android AVD against an isolated six-migration Supabase environment.
Two sessions were closed. Native enrollment, encrypted journal recovery,
receipt consumption, atomic final-note intent and closed-session History were
exercised together, including an actual lost-response/restart/replay case.

No successful location fix is claimed. All four submitted foreground attempts
timed out and were accurately recorded as unverified evidence without coordinates.

## Repository and scope

- Branch: `feature/attendance-live-integration`.
- HEAD: `dda972a5ee1a4f8751a73d5f8920c93e13492778`.
- Initial working tree clean; initial and final `git diff --check` passed.
- No application/native source, committed migration, staging, commit, push or
  branch changes. Repository changes are this report and `development-status.md`.
- No hosted requests, deployment, gate change or attendance writes.
- Existing Pixel_9 and the physical phone were not used, enrolled, reset or
  uninstalled. Retained `supabase_db_chantipoint` remained stopped throughout.

## Isolated environment

The new CLI project was `chantipoint_e2e_20261025`, in
`%TEMP%\ChantiPointE2E20261025`, with new project-specific Docker resources and
database volume. Only the repository's configuration and six migration files
were copied; linked-project metadata and retained database data were not copied.
Mount inspection verified the retained database volume was not attached.

API/DB ports were 55321/55322, distinct from the retained project's 54321/54322.
Actual GoTrue Auth, Kong and PostgREST ran with PostgreSQL using cached images.
All **52 strict gate-1 schema checks passed before activation** and migration
history matched all six repository files. The new server-generated epoch was
read independently through privileged local SQL and provisioned as trusted
configuration. Only this disposable backend was then changed to gate 2.
Authenticated capability returned contract version 1, the expected epoch,
`write_contract=2`, and `v2_available=true`.

The dedicated `ChantiPoint_E2E_20261025` AVD used the installed Android 37.2
Play Store / x86_64 / 16 KiB system image, with no copied Pixel_9 userdata or
snapshot. All device commands explicitly targeted `emulator-5560`; the driver
also checked its AVD name. Normal package `com.example.chantipoint` was used.
APK updates used `install -r`; no application data was removed.

The app's trusted origin was `http://127.0.0.1:55321`. ADB reverse forwarding
provided host connectivity without changing journal URL validation. The optional
lost-response proxy used host loopback port 55331 and forwarded to the same
backend. Device origin, epoch, account and enrollment binding remained unchanged.

## Native enrollment

The existing `tool/development_attendance_enrollment.dart` request/install
targets were exercised. A new AVD and new backend with no prior admitted clients
provided the independent fictional clean-install/maintenance evidence.

The native request created the installation key and durable retirement marker.
Its exact original bytes were checked against the independently provisioned full
binding, package, policy and fictional approval/maintenance references, then signed
externally using a test-only P-256 key and SHA-256/ECDSA DER signature. Native
installation verified the signature and initialized the revision-1 empty slot.
Normal main was then installed as an update under the same signing identity.

Private signing material, configuration, identities, credentials, request bytes,
signatures and raw runtime/build logs remain outside Git and the review ZIP.
This test signature certifies only this controlled fictional rehearsal; it is
not production or hosted-device certification.

## Functional acceptance

| Check | Actual result |
| --- | --- |
| Employee login and authorization | Passed through normal UI and real local Auth/profile/role reads. |
| Durable native enrollment | Request/sign/install succeeded; normal preflights and later process restarts retained approval. |
| Capability and epoch | Exact authenticated gate-2 capability matched the independent SQL/configuration epoch; real v2 writes passed server epoch guards. |
| Initial empty journal | Check-in initially disabled; explicit existing empty-record verification enabled a fresh canonical no-active-session read. |
| Foreground location | Actual permission dialog and native one-shot capture exercised. Four submitted attempts returned timeout with precise permission and enabled services. No successful fix or coordinate injection. |
| Check-in and description | Two normal UI check-ins persisted the exact fictional description; canonical active sessions displayed. |
| Confirmed restart recovery | First check-in's encrypted slot and signed approval were byte-identical across force-stop/restart before explicit recovery. Canonical confirmation was restored. |
| Receipt consumption | Existing UI consumption released each confirmed operation, followed by fresh canonical selection. No deletion/reset controls were used. |
| Checkout/final note | First checkout atomically replaced the note with exact fictional text. Second used preserve intent and kept null. Both closed manually. Clear intent was covered by focused host tests, not an additional device checkout. |
| Closed History | Both closed rows displayed; expanded details showed entry/exit, description and Montreal time label. History's default note/review projections remain disabled. Final-note persistence was verified canonically and in SQL. |
| Lost response and restart | Proxy forwarded one original check-in and suppressed its successful reply. App remained pending and disabled new check-in. Original encrypted slot/approval survived restart unchanged. Explicit replay recovered the original active session. |
| No replay duplication | Proxy counted one original and one replay for that case. Sessions/events/observations stayed at 2/3/3 across replay, then became 2/4/4 only after checkout. |
| Logout | Normal logout returned to the login screen; subsequent login/restoration and journal verification also passed. Final app state is signed out. |
| Runtime default denial | Normal debug main without the public trust anchor allowed login and History but denied attendance and empty-record recovery despite retained signed enrollment and gate 2. Idle refresh/restart preserved approval/slot bytes. |
| Standalone note Save | Remained disabled in active-session UI. No standalone note operation was created. |

Final database aggregates: one fictional Auth user/profile, two manually closed
sessions, no active session, four attendance events, four unavailable location
observations, zero standalone note operations, six migrations, gate 2. Both
sessions retained `location_unverified` and `anomaly_open`. Every observation had
`permission=precise`, `services_enabled=true`, `location_result=timeout`,
`provider=unknown`, and no coordinates.

| Fictional cycle | Authoritative start UTC | Authoritative end UTC | Elapsed seconds |
| --- | --- | --- | --- |
| Replacement-note cycle | 2026-10-25 17:06:54.057887Z | 2026-10-25 17:09:21.916192Z | 147.858305 |
| Lost-response/preserve cycle | 2026-10-25 17:11:15.378148Z | 2026-10-25 17:13:49.603004Z | 154.224856 |

Device action timestamps were present for both ends of each session. Server
starts followed the captured check-in action instants; closures followed starts.
UTC storage and Montreal display were checked separately.

## Failures, corrections and limits

- **Local email provider disabled:** copied `[auth.email].enable_signup=false`
  produced `GOTRUE_EXTERNAL_EMAIL_ENABLED=false` and actual login HTTP 422
  `email_provider_disabled`. Only the disposable configuration was changed to
  `[auth.email].enable_signup=true`; global `[auth].enable_signup=false` stayed
  unchanged. Password login passed and actual public signup was repeatedly
  rejected with HTTP 422 `signup_disabled`. No authentication bypass was added.
  The fictional account was preserved and updated during setup, rather than
  deleting fixtures to obtain a clean retry. Repository config was not changed.
- **UI driver:** its initial Tab-based password targeting gave invalid credentials;
  explicit field selection/clearing succeeded with the same credentials. Later
  off-screen controls and an APK-update transition required scrolling or a cold
  start. These were driver/timing corrections, not application source fixes.
- **Initial AVD/build pressure:** startup System UI ANR cleared with Wait. Actual
  available RAM reached 47 MiB during concurrent cold Gradle/AVD work. Only new
  rehearsal services/AVD were paused with data retained; builds then completed,
  Gradle was stopped and the services resumed. No caches or volumes were cleared.
- **Permission lifecycle:** granting foreground permission caused existing auth
  resume revalidation and abandoned the unsubmitted draft. SQL confirmed zero
  attendance writes. A fresh explicit employee action succeeded; no automatic
  capture/submission retry was introduced.
- **GPS:** native capture timed out in all four submissions. The allowed
  unverified-location path worked. Successful native fix acquisition remains
  unproved and no physical-phone test was performed.
- **Fingerprint timing:** one snapshot was taken immediately after requesting
  final receipt consumption, before an idle baseline had been established. Its
  later comparison showed unchanged approval but different encrypted slot bytes;
  that comparison cannot attribute when the journal changed. It was preserved.
  New idle-baseline comparisons passed across no-anchor refresh/restart, restored
  signed main, explicit empty verification and logout. Final signed main confirmed
  the retained empty journal and canonical no-active-session state.
- **Transient local gateway failure:** one final normal login after restoring
  direct forwarding displayed service unavailable; Kong logged HTTP 504 on
  `/auth/v1/token`. Services remained healthy, stored attendance was unchanged,
  and explicit manual retry succeeded. The underlying timeout cause is
  unestablished. No product source change or reliability guarantee is inferred.

## Validation

All **137 focused Flutter tests passed**, using:

```powershell
flutter test --no-pub --concurrency=1 test/development_normal_attendance_integration_test.dart test/development_attendance_authority_test.dart test/normal_attendance_integration_test.dart test/employee_receipt_consumption_test.dart test/confirmed_record_recovery_test.dart
flutter analyze --no-pub
git diff --check
```

Analyzer: **No issues found**. Four debug APK builds passed: operator request,
operator install, configured `lib/main.dart`, and `lib/main.dart` without the
operator public anchor. The first cold build took 1200.4 seconds; subsequent
builds reused its outputs. No release APK, full Flutter suite, full pgTAP suite,
new instrumentation suite, physical phone, power-loss or hosted validation ran.
Actual native acceptance here came through the ordinary operator/normal apps,
not replacement fake storage/auth/location ports.

## Final state and remaining hosted boundary

Working configured normal APK was restored, final empty journal verified, and
employee logged out. Dedicated AVD and all four new backend containers were
stopped cleanly; the fault proxy was stopped. AVD userdata, app/Keystore evidence,
containers and volumes remain retained. Docker's engine was left running. The
retained original database remained stopped and its volume was never mounted
into this rehearsal. Hosted resources and both existing devices were untouched.

There is no remaining blocker to the completed fictional unverified-location
rehearsal. Hosted activation still requires separate authorization, trusted
operator configuration/key custody, certification or resolution of existing
device evidence, and supervised server fencing/drain of old writers and pending
legacy/note work. This new AVD's history cannot certify Pixel_9 or a hosted
deployment. Successful GPS fixes and the observed local gateway timeout remain
unresolved runtime limits. Standalone note Save, administrator UI and production
acceptance remain outside this completed slice.

## Review inventory

Repository files changed/new:

- Modified: `docs/development-status.md`.
- Added: `docs/normal-app-attendance-rehearsal.md`.

The external review ZIP preserves those repository-relative paths and includes
sanitized supplemental operator scripts under `rehearsal-support/`, focused-test
and analyzer output, the nonsecret isolated Supabase configuration, and aggregate
acceptance evidence. The scripts are records
of this specific owned test environment, not a general provisioning/reset tool.
No private configurations, keys, identities, request/signature files, APKs,
screenshots, raw service/build logs or app/database payloads are included.
`SHA256SUMS.txt` covers every review payload; a separate file contains the ZIP's
own SHA-256 digest. Review artifacts are outside the repository.
