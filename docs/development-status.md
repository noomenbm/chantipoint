# ChantiPoint Development Status

Current slice: **M2.3c.C6.2, note visibility with the authorized safe fallback**,
based on clean **`fbc5665d6d4761e457bf9f90443a12100347243c`** on the human-created
`feature/attendance-session-notes` branch. Changes remain unstaged/uncommitted.

The isolated employee screen now has a prominent canonical `Note de la session`,
a disabled `Enregistrer la note` action with availability guidance, and a
`Note à la sortie` section with current saved value, all three explicit radio
choices and a visible multiline final draft. Replacement alone enables/sends
that draft. Empty replacement, null/clear and preserve remain distinct. Worksite
description help separates it from session notes and server classification.

**Standalone active-session saving is NOT implemented.** This is the request's
explicit fallback, leaving that requirement incomplete. The current row-locked
note RPC lacks operation identity/replay receipts; a canonical read can overtake
a delayed write and matching text cannot identify its outcome. There is also no
separate durable note-operation store/shared checkout gate surviving restart.
Extending the settled attendance journal is outside the required separation.
A new server settlement contract plus separate verified durable storage and
coordination must be reviewed/tested before enabling Save. No weak success state,
unsafe retry or network-failure-as-rollback assumption was added.

REQ-EMP-013 / BL-033 now record own-session history for the preceding six months,
with times, worksite description, canonical note, classification and review state.
It is a future read-only paginated slice; no history UI or old-record deletion.

C6.2 host validation (2026-10-21 UTC):

- Focused serial suite: **147/147 passed** across note UI, existing screen,
  workflow, receipt consumption and action capture. **11 new widget tests**
  cover the disabled Save with no context/dispatch/journal/location activity,
  visible choices/field, exact French text, empty/unchanged replacement,
  preserve/clear excluding retained drafts, invalid inactive drafts, auth/session
  changes, duplicate checkout taps and a compact phone with keyboard inset.
  Existing combining-character boundary and correction/race tests still pass.
- Full `flutter test --no-pub --concurrency=1`: **1399/1399 passed**, zero failures
  or skips (1388 baseline plus 11), about 1m 34s of test output.
- `flutter analyze --no-pub`: **no issues**. `git diff --check` and the new file's
  whitespace/newline checks passed. An initial focused load failed on a misspelled
  fictional fixture constant; it was corrected before these passing runs.
- C:/E: before **23.47/22.68 GiB**, RAM **1.11 GiB** available; after host checks
  **23.46/22.68 GiB**, RAM **1.57 GiB**. Lowest sampled C: **23.36 GiB**. Commands
  ran sequentially, one test worker, proactive **5.5 GiB** guard above the
  documented **5 GiB** stop rule. No cleanup, downloads or service startups.

No standalone save/reconciliation exists to validate: lost note replies, delayed
note writes, cross-restart note gating and server/native guarantees remain
untested pending those contracts. No database, Android, emulator, Gradle, Docker
or hosted validation was run. There are no
SQL, native, auth, live-controller, coordinator, transport, dependencies or
navigation changes. Existing production composition/deployment, provenance and
durable writer-fencing, privacy/backup and actual location/runtime gates remain.

See [Workflow safety assessment](employee-attendance-workflow.md#c62-notes-safe-fallback-and-visible-checkout-intent)
and [Architecture](architecture.md#c62-note-ui-and-explicit-standalone-save-fallback).

Previous committed slice: **M2.3c.C6.1, production-scoped v2 read and auth notification
adapters**, based on clean **`dff71224d21ea6a6779c8accead7f147044520e8`**, branch
`feature/attendance-v2-adapters`. The human created the branch; no branch or other
Git mutation was performed during that slice; it is included in the C6.2 baseline.

The existing C3.2 transport now supports an active SELECT with the exact C3.3
owner/authority, binding and generation. Its bounded, one-attempt, pinned-scope
HTTP behavior is reused. A single SELECT embeds the active owned profile,
employee role and active sessions using the existing composite foreign keys.
Only a valid authorized envelope with zero sessions yields null: RLS-hidden
profiles, missing roles, wrong owners, inactive/malformed/multiple rows, missing
v2 fields and HTTP/network/schema/staleness failures remain unavailable. No
legacy current-user shortcut, receipt reconstruction or auth mutation is added.

`ScopedAttendanceActiveSessionReader` implements C5's observation port. Reads do
not advance revision or notify; an explicit authorized `invalidateSession`
retires the checkout baseline, increments revision and requires refresh. Read
sequence/revision guards prevent delayed replies overwriting newer selections.
No independent production event source, subscription or polling is wired.

`AttendanceAuthOwner` is now the C5 authorization `Listenable` as well as the
context/credential authority. Existing controller boundaries and additive
synchronous repository initiation notifications cover logout, same-user login,
account changes and revalidation. Auth mutation queue order is reserved before
observer callbacks. Notifications publish complete transitions; proven same-login
refresh is quiet. Close revokes immediately, detaches source listeners and drains
issued contexts without cancelling submitted work or force-releasing ownership.
The application owns it and closes it before disposing AuthController; routes
only detach their own listeners. Legacy auth outcomes/queries are unchanged.

Supported auth mutations must continue through AuthController/the repository.
Raw SDK initiation cannot be universally intercepted: exact-session currency
guards reject replacements before stale use, and notifications follow the SDK
event. This slice does not add a global auth interceptor.

C6.1 validation (2026-10-20, host only):

- **289/289 focused tests passed** across eight files, including legacy auth and
  attendance regressions. **87 new tests**: 58 scoped-reader/HTTP cases, 15 auth
  notification cases and 14 isolated C5 integration cases. Identities, HTTP and
  auth responses are fictional/mocked; journal storage is a test fixture.
- Full `flutter test --no-pub --concurrency=1`: **1388/1388 passed**, zero failures
  or skips (1301 baseline plus 87 new), about 1m 29s of test output.
- `flutter analyze --no-pub`: **no issues**. `git diff --check` and changed-file
  whitespace/newline checks passed. No analyzer suppression or weakened tests.
- Initial C:/E: **28.23/22.68 GiB**, available RAM **0.33 GiB**. Final validated
  focused/full minima: **28.12/28.11 GiB C:**. After testing:
  **28.22/22.68 GiB**, available RAM **1.06 GiB**. Host commands ran sequentially
  with one test worker and a proactive **5.5 GiB C:** guard (above the documented
  5 GiB stop rule). No cleanup, downloads, emulator, Gradle or Docker startup.

The live main/AuthGate/controller/factory and hosted gate remain unchanged. No
demo fixtures/branding, SQL, native journal/storage, standalone note saves, GPS,
new dependencies or production navigation were introduced. No hosted request,
Android build, emulator, Docker, migration or legacy-file cleanup was performed.
Live PostgREST/RLS/schema-cache validation of the embedded query, trusted
composition, approved v2 deployment/activation, production provenance/assignment
and durable legacy-writer retirement/fencing, backup and privacy approval remain
pre-cutover gates. The host suite does not establish live cutover readiness.

See [Architecture](architecture.md#c61-scoped-active-reads-and-auth-notifications-not-composed)
and [Employee Workflow](employee-attendance-workflow.md#composition-and-ownership).

Previous slice: **M2.3c.C5.2, safe confirmed-receipt consumption**, based on clean
**`e800cee90d6a500065fe6c8c6d0a810701d81655`**, branch
`feature/manual-attendance`.

The isolated screen now offers `Terminer la vérification`. The shared coordinator
requires its own exact durable confirmation evidence, current owner/generation,
fresh scoped acknowledged-session read and full-record/revision/key guarded CAS
before replacing confirmed with an empty tombstone. A subsequent fresh authorized
active SELECT decides the next action. The fictional check-in -> consume ->
checkout -> consume cycle reaches revisions **3/4/7/8**, with two dispatches.
Consumption authority freezes before joining the queue; a duplicate cannot consume
a newer queued command. No UI booleans, direct deletion or new native API/schema.

Failed compaction may have committed. Complete original receipt evidence is kept
in memory, and readable empty state alone stays gated for both selection and new
submit. Explicit `recoverEmpty` requires the existing exact-record sync/readback
barrier and exact reread; after replacement/restart it proves current empty state,
not historical success of a failed attempt. Confirmed state lacking proof uses
confirmed recovery. Changed/ambiguous records and missing/failed verifiers remain
blocked. Known disappearance is blocked in-process; data/key/device loss, arbitrary
rollback and unknown deletion after restart remain outside existing guarantees.

C5.2 validation (2026-10-19):

- **247/247 focused tests passed** across six coordinator/recovery/workflow/UI
  files. **54 new tests:** 37 core fault/race tests and 17 workflow/widget tests.
- Full `flutter test --no-pub --concurrency=1`: **1301/1301 passed**, zero failures
  or skips, about 1m 15s (1247 baseline plus 54 new). Analysis: no issues.
- `git diff --check` and untracked-file whitespace/newline checks passed.
- Initial C:/E: **10.39/23.66 GiB**, available RAM **0.62 GiB**. During validation
  C: sampled at **10.28 GiB**; after validation **10.38/23.66 GiB**, RAM **2.50 GiB**.
  The existing 5 GiB stop rule was respected. Tests/analysis stayed sequential;
  emulator, Docker and Gradle remained stopped. No downloads or Android build.

This is host evidence only. No new Android runtime/instrumentation, power-loss,
successful native-fix or live auth/resume claim. The unchanged generic native
barrier supports format-2 empty records by source inspection; the new composition
was not runtime-tested. Cross-isolate/process ownership, durable production
provenance/legacy-writer retirement and fencing, backup policy, active-session and
auth-notification production composition, client/privacy approvals and hosted v2
deployment/activation remain pre-cutover gates. Standalone note saves remain
deferred. No preview/demo APK, live-controller change or production route was added.

All changes remain unstaged/uncommitted for review. See
[Employee Workflow](employee-attendance-workflow.md) and
[Secure Command Journal](secure-command-journal.md#c52-serialized-confirmation-consumption).

Previous slice: **M2.3c.C5.1, isolated French employee workflow and screen**,
based on clean **`fb765edc015bceead730fb90240508a4a5c8721b`**, branch
`feature/manual-attendance`.

An injectable presentation workflow now connects C4 action capture to the C3
coordinator. The isolated French screen supports one check-in action, canonical
session/classification/review/saved-note display, Montréal timestamps and manual
checkout with explicit preserve/replace/clear final-note intent. It has no
production route, credential/active-reader composition or live-controller change.
Hosted v2 remains inactive. No Android, backend or dependency changes were needed.

The developer explicitly selected retention/gating of confirmed records for this
slice: verified sessions can be displayed, but another command over that receipt
waits for reviewed serialized confirmation consumption/compaction. Pending,
ambiguous and blocked commands are never replaced. Recovery uses C3's exact replay
or durable confirmed-record path. Route disposal leaves submitted work running to
normal settlement, including late receipts; stale auth/session results are hidden.
Standalone note saving waits for owner-scoped uncertain-save reconciliation.

Integration review added a narrowly scoped C4 cleanup method: result-level
abandonment releases an unsubmitted capture even when its current-action getter
already hides stale intent. C5 awaits that cleanup in finally; handed-off contexts
stay owned by C3 until settlement. Two regressions cover both boundaries.

C5.1 input-validation review follow-up (2026-10-19):

- Screen counters and frozen-input validation now use C4's shared 500/1,000
  Unicode-code-point limits and exact text contract. No truncation, trimming or
  normalization. Specific French input feedback preserves the draft/canonical
  session for correction, without issuing a context, key or location request for
  invalid text. Defensive C4 invalidInput feedback is also distinct from refresh
  failures; its rejected context is released before a fresh attempt.
- **119/119 focused tests passed**, including 20 added review regressions:
  combining-character text below/at/above both limits, ordinary French unchanged,
  unsupported Unicode, no truncation, correction followed by a successful fresh
  action, no dispatch/journal writes or retained context on invalid input, and C4
  invalidInput fallback. Final full serial suite: **1247/1247 passed**, zero
  failures/skips, about 1m 13s. Analysis and git diff --check passed; untracked-file
  whitespace/final-newline checks also passed.
- Existing architecture, confirmation-retention gate, isolated navigation and
  production restrictions are preserved. No Android build/runtime, hosted
  operation, migration or Git mutation. Review archive and SHA-256 manifest were
  regenerated; successful native fix validation remains open.

Original C5.1 validation (2026-10-18):

- Focused serial tests (capture, workflow, screen): **99/99 passed**. This includes
  43 new workflow tests, 23 new widget tests, two new capture regressions and 31
  retained capture tests.
- Final full `flutter test --no-pub --concurrency=1`: **1227/1227 passed**, zero
  failures/skips, about 1m 15s (1159 baseline plus 68 new tests).
- `flutter analyze --no-pub`: **passed**, no issues. `git diff --check` and
  whitespace/final-newline checks of untracked files passed.
- Initial C:/E: free space **10.68/23.66 GiB**, available RAM **1.65 GiB**.
  Sampled C: free space stayed at least **10.48 GiB**, above the existing 5 GiB
  stop rule. After validation: **10.58/23.66 GiB**, available RAM **1.54 GiB**.
  Host tests and analysis were sequential; no emulator, Gradle or Docker startup,
  build, downloads, cache cleanup or pagefile changes. RAM reached **0.87 GiB**
  during the final suite. An optional Android UI smoke run was omitted: the
  existing image requires a 4 GiB guest, and no additional runtime harness/build
  was justified under these resources. Host UI results do not establish Android
  permission/fix or live auth-resume behavior.
- Bounded read-only fsck checks, with and without reflogs, both reported 103
  unreachable trees and 53 blobs, with no commits, tags or other diagnostics.
  All 53 blobs were scanned within the limits; no credential-pattern candidates
  or sensitive filename matches were found. This does not prove historical
  remote absence or constitute an exhaustive secret audit.

All changes remain unstaged/uncommitted for review on the original branch/HEAD.

See [Employee Attendance Workflow](employee-attendance-workflow.md) for the exact
dependency contracts, resource-controlled validation, bounded read-only Git audit
and remaining work. Successful native location fixes and live auth/resume
composition remain unvalidated; C4's grant/approximate timeouts are not GPS-fix
success. No C5 Android UI smoke test or Android build was run.

Previous slice: **M2.3c.C4, foreground location and v2 action capture**, based on
clean **`89ee90b6d0971c46b115231cb83d49ee69d521d7`**, branch
`feature/manual-attendance`.

The one-shot evidence service and immutable check-in/out action capture are
implemented as isolated modules. Exact auth generation/binding and original
checkout-session observations gate capture/handoff. The capture retains one
key/time/input snapshot and keeps ownership until abandoned acquisition or
submitted work settles. No live controller/screen, RPC, journal, migration or
hosted-gate activation is added. Standalone note saves stay outside the outbox.

The cached geolocator 14.1.1 / Android 5.1.1+1 timeout sends an unawaited cancel
and automatically binds a service. Instead, a narrow native channel uses the
already cached AndroidX Core 1.17.0 cancellable single-fix API. No new Dart package,
fork/cache patch or upgrade is introduced. Coarse/fine foreground permission is
declared; no background permission, tracking service, position stream or polling.
MainActivity registers the channel but the live legacy GPS-free path never calls
it. See [Foreground Location](foreground-location.md) for the exact contract.

C4 validation (2026-10-18):

- Focused host tests: **95/95 passed**. Full serial Flutter suite:
  **1159/1159 passed**, zero failures/skips (1064 retained plus 95 new),
  final run about 1m 30s. `flutter analyze --no-pub`: passed, no issues.
- The final source review fixed a malformed-context cleanup edge: if identity
  access and release both fail, busy/drain state now clears in finally and the
  result is contextUnavailable. Two regressions verify release once, no key/fix
  and a non-hanging close. This fix is included in the final host suite and APK.
- Normal Android app debug build: **offline passed**, 1m 33s. Packaged manifest
  inspection found coarse/fine foreground permission, no background-location
  permission and no tracking service. The normal app was not launched.
- Isolated location-validation app/test APKs: **offline passed**; final rebuild
  after the cleanup guard: **1m 9s**. Existing SDK/dependencies/caches and the
  one-worker/1 GiB Gradle configuration were reused; no package/SDK downloads.

Actual emulator observations on API 37 x86_64, 16 KiB pages:

| Scenario | Observed permission | Observed acquisition | System dialog click |
| --- | --- | --- | --- |
| Grant | precise | timeout, no fix | Yes |
| Denial | denied | permission_denied, no fix | Yes |
| Coarse only | approximate | timeout, no fix | No prompt/escalation |
| Services disabled | approximate | location_services_disabled, no fix | No prompt |

All **four scenarios passed again on the final APK**, each
`INSTRUMENTATION_CODE: -1`; each produced
an immutable captured command rather than dispatching attendance. No fix was
returned despite fictional coordinate injection. Do not claim native successful
fix/coordinate/timestamp/accuracy mapping was runtime-tested; those cases passed
host mocks only. Real provider errors, denied-forever, cancellation exceptions,
older Android/OEM hardware and physical devices remain untested on Android.

The first runtime attempt was obstructed by an emulator System UI ANR and failed
with no reply. A test-harness teardown defect also destroyed its cached engine
before Activity/FlutterView teardown, causing a FlutterJNI-detached exception.
The harness now transfers engine destruction to the Activity and uses observed
system permission controls; one final grant run selected Wait once for System
UI. An initial protected engine-access compile error was resolved using a
public cached-engine builder. All these controls remain in androidTest. No
production-only test accessor or auth behavior change was introduced.

The first four device observations preceded the final malformed-context cleanup
guard. After resources were freed, the final app/test APKs were reinstalled and
all four scenarios above passed again, including an actual system-dialog click
for grant and denial. Grant selected Wait once for a System UI ANR; the other
three scenarios needed no System UI wait. The final APK is now runtime-tested;
the malformed-context failure itself remains covered by host regression tests.

C4 restores the **5 GiB C: stop rule**, with a proactive 5.5 GiB guard. Initial
C:/E: free space was **10.88/23.68 GiB**, available RAM **1.47 GiB**. Before the
first emulator start, available RAM was **2.67 GiB**. The earlier runtime disk
checks stayed above **7.19 GiB**; its successful scenario samples were at least
**7.20 GiB**. The requested 1536 MiB guest was raised to **4096 MiB** by the image.
Host testing, builds and emulator work were sequential. That run's original enabled
location-services state was restored, then the emulator was stopped. No unrelated
cache/data deletion, pagefile changes, Docker, hosted requests or Git mutations.
`git diff --check` passed. All source changes remain unstaged for review.
Before the final-APK rerun, C:/E: free space was **10.70/23.68 GiB**, available
RAM **2.95 GiB**. The minimum sampled C: free space during that rerun was
**7.03 GiB**, above the stop threshold. Available RAM reached **0.25 GiB** during
installation; no parallel build or host test was started. On this boot, location
services were initially disabled and that original state was restored afterward.
The emulator was stopped after validation. No new source fix or rebuild was
needed for this rerun; the existing final host/build results above still apply.
After shutdown (2026-10-18 23:09 UTC), C:/E: free space was **10.57/23.68 GiB**,
available RAM **3.18 GiB**; no emulator or Gradle JVM remained and ADB listed no
device. Tested APK SHA-256 values:

- Isolated app: `32F3EA5B554E300BEEA1C08D70E7A10670EDF6CBC2C81AF537E144738685E19B`
- Instrumentation: `2746222A0DAF74DA40B4C0419943D9B76E861969729D2C7480553F7FA2546F8B`

Live auth/resume integration is not tested by the fictional probe. A permission
dialog can trigger unchanged resume revalidation and invalidate a real C3.3
context; C4 must abandon rather than retarget it. Future UI permission setup or
an explicit fresh action after reauthorization requires coordinated composition.
Real employee collection, actual successful device fixes, production privacy
approval, app composition, backup/migration/fencing and approved backend cutover
remain gated. The live legacy attendance path remains unchanged.

Previous slice: **M2.3c.C3.4, durable confirmed-record recovery**, based on clean
**`99d6ea73100acdeab333ddc04739d047a460c107`** on `feature/manual-attendance`.

The opt-in `verifyRecordV1` native barrier authenticates and compares the entire
expected record, synchronizes its file and directory under the existing native
locks, and authenticates/compares complete readback. The separate injected
`AndroidJournalVerifier` validates full Dart schema and exact returned bytes.
Migration barriers and their isolated deletion guard are unchanged.

`recoverConfirmed` is an explicit coordinator attempt for a stored confirmed v2
receipt after restart/replacement or a reported confirmation CAS failure that
actually committed. It checks captured generation/full binding and complete
record bytes around verification, then permits only canonical session refresh.
Canonical failure retains the receipt for later explicit refresh. Missing
verifier, failed barrier, changed/unverifiable record, legacy command, pending
migration and blocked states never grant recovery. Existing successful-CAS,
late-receipt, one-attempt ownership and prepared/uncertain behavior are retained.

C3.4 validation results (2026-10-18):

- Focused recovery/channel/existing coordinator tests: **136/136 passed**.
- Final `flutter analyze --no-pub`: **passed, no issues**.
- Final `flutter test --no-pub --concurrency=1`: **1064/1064 passed**, zero
  failures/skips (1004 retained plus 60 new), rerun after the runtime-fixture fix
  in approximately 1 minute 10 seconds.
- Isolated app and instrumentation APKs: **offline compilation passed** using
  the documented one-worker, 1 GiB Gradle configuration. Final rebuild: 1m 10s.
  Existing Gradle/Kotlin deprecation warnings remain; no dependency upgrade.
- **Actual Android C3.4 instrumentation passed:** API 37 x86_64, 16 KiB pages,
  Pixel_9; **fresh 55/55 and restart 11/11**, zero failures, both reporting
  `INSTRUMENTATION_CODE: -1`. These retain the earlier 44 fresh/9 restart checks
  and add 11 fresh/2 restart checks. Only the isolated validation app was
  force-stopped between phases; its data and Keystore key were retained.
- Initial runtime retry: **54 passed, 1 failed**, in the altered-readback fixture.
  An androidTest `AtomicReference.compareAndSet` used a literal string reference,
  so channel-decoded text did not trigger tampering. The fix consumes the exact
  observed reference after value comparison. The Dart assertion additionally
  proves ciphertext fingerprint change before requiring authentication failure
  and evidence preservation. Both final phases passed after rebuilding. No
  production verification behavior or test expectation was weakened.
- Resource retry authorized after the developer freed RAM/disk and changed the
  C: stop threshold from 5 GiB to **3 GiB**. Earlier startup attempts under the
  proactive 5.5 GiB threshold had been stopped without running instrumentation.
  This retry began with C: **9.63 GiB**, E: **23.68 GiB**, available RAM
  **2.66 GiB**. The lowest sampled installation/phase free space was **4.92 GiB**
  in the initial run; final successful installation/fresh/restart checks stayed
  at or above **8.34 GiB**. The emulator still raises requested 1536 MiB RAM to
  **4096 MiB**. Builds, host suites and emulator work were sequential. No
  downloads, unrelated cache/data deletion, pagefile changes or Docker startup.
- Final shutdown confirmed emulator/Gradle/Docker stopped: C: **10.89 GiB**,
  E: **23.68 GiB**, available RAM **2.12 GiB**.
- `git diff --check`: passed. Branch/HEAD retained; no staging or commits.

The focused native runtime validation blocker is resolved. New checks cover
exact bytes, missing and changed targets, authenticated corruption/wrong binding, ambiguous sidecar
preservation, synchronization-boundary failure injection, altered readback,
force-stop persistence and native-verifier-backed coordinator refresh without
dispatch. Injected checkpoint failures do not test real kernel fsync failures.
Native duplicate-sidecar cleanup fault injection, older Android/AtomicFile,
permanent key invalidation, multi-process mutation, power interruption,
OEM hardware and backup/transfer remain untested here.

This remains isolated from main/screens/live attendance. No hosted requests,
SQL deployment, v2 activation, actual legacy migration, GPS/UI, provenance approval
or durable global fencing is introduced.
Production composition, backup policy, writer/source ownership, receipt
consumption/compaction and approved backend cutover remain gated. File/directory
synchronization and authenticated readback do not establish arbitrary power-loss,
device-loss or storage-rollback recovery.

Previous slice: **M2.3c.C3.3, combined auth ownership and credential authority**,
based on clean **`2ae472a`** on `feature/manual-attendance`.

`AttendanceAuthOwner` now observes the real controller/repository lifecycle,
issues C3.1 operation contexts and implements C3.2 credential authority from the
same in-memory generation. It is not instantiated by main or a screen, and live
check-in/out remains on the unchanged legacy controller. No new hosted requests,
SQL, gate/v2 activation, migration, Android/native storage or GPS/UI work.

Read-only auth hooks expose controller disposal/pairing, repository operation
number, exact SDK session evidence and an attendance-only successful profile/role
attestation. Logout/login invalidate at their synchronous initiation boundaries,
including queued SDK logout; resume checks and authorization loss invalidate old
attempts too. Auth decisions, queries and existing UI behavior are unchanged.
Exact session-object guards block replacement before public event delivery.
Same-login token refresh preserves the generation and existing scopes' tokens;
the SDK refresh event PLUS matching approved server `session_id`/subject are
required, since `setSession` can report refresh for another login.

Credential acquisition awaits SDK refresh settlement and rechecks original
generation/session evidence; it never adopts the current account as fallback.
The complete binding is derived from trusted deployment configuration and the
approved profile. Contexts survive screen/caller timeout and auth invalidation
until normal release. Application owner close detaches listeners and waits for
outstanding contexts rather than cancelling work or releasing ownership early.
Real-owner + mocked-HTTP tests retain late receipts without stale refresh.

C3.3 host validation:

- `flutter test --no-pub --concurrency=1 test/attendance_auth_owner_test.dart`:
  **40/40 passed**, zero failures/skips. Uses real AuthController/repository/SDK
  with fictional mocked HTTP: initiation while credentials refresh, logout after
  submission, relogin/switch, token refresh continuity, different-login
  `setSession`, pre-event replacement, stale refresh results/events, authorization
  loss, ambiguous profile lookup, late attachment, delayed bodies, context
  release/close, concurrent attempts/acquisitions and caller timeout.
- `flutter analyze --no-pub`: passed, no issues.
- `flutter test --no-pub --concurrency=1`: **1004/1004 passed**, zero failures/skips
  (964 retained plus 40 new), in approximately 1 minute 7 seconds. Five duplicate
  test registrations found during review were removed before final validation.
- `git diff --check` and source/test UTF-8/whitespace/newline/format checks passed.
- C: **9.93 GiB** initially and **9.35 GiB** before/after the final full suite; E:
  **23.68 GiB** free. Final available RAM: **1.63 GiB**. All measurements exceeded
  the 5 GiB C: stop rule. Existing
  caches/dependencies were reused; no SDK/package downloads, Android build,
  emulator, Docker, destructive cleanup or pagefile changes.

Missing/ambiguous login evidence fails closed for attendance only. An owner
attached after an unobserved refresh requires fresh validation; attach before
startup auth in future composition. All application-initiated auth mutations
must use the controller/repository boundary; arbitrary direct SDK mutation
initiation cannot be universally intercepted. Only in-isolate ownership is
implemented. Root composition, trusted environment provisioning, durable global
writer/source assignment/fencing, migration provenance, native recovery, backup
review, receipt consumption/compaction and approved backend deployment/cutover
remain gated. No Android, hosted auth/RLS or power-loss validation is claimed.
See [Secure Command Journal](secure-command-journal.md#c33-combined-auth-owner-and-credential-authority).

Previous slice: **M2.3c.C3.2, isolated v2 HTTP transport and canonical reader**,
based on clean reviewed **`622c762`** on `feature/manual-attendance`.

`AttendanceRequestAuthority` and its memory-only request scope supply the trust
boundary for the exact five-field binding, captured authorization generation,
trusted project endpoint/key and pinned access token. Only a fictional issuer is
supplied. `SupabaseAttendanceOperationTransport` implements both existing C3.1
ports directly through injected `http.Client`, without using the live repository,
global auth, production configuration or application wiring. C3.1 code/sequencing,
the legacy controller/repository, migration coordinator, Android storage, SQL,
hosted Supabase and the deployment gate are unchanged.

Each operation makes one HTTP send with redirects disabled, no implicit retry or
internal timeout. Initial request JSON and complete successful receipt text are
retained exactly; replay changes only the operational flag via the existing map
contract without altering journal bytes. Credentials are pinned to the original
scope, with currency/binding checks after acquisition and immediately before send.
Late dispatch responses still reach C3.1 for original-slot receipt finalization;
canonical reads additionally recheck authorization after consuming their response.

Bodies are bounded to 16 KiB of retained bytes, with strict UTF-8 and explicit BOM
rejection. Oversized/error bodies and stream errors are drained through termination;
an endless response remains outstanding rather than detaching local work. No raw
backend errors, response bodies or credentials appear in exception text/logs.
Only an exact duplicate-free successful replay-only miss becomes `replayMiss`.
Canonical queries filter session/company/employee IDs without an active-only
restriction, validate returned ownership and parse existing `WorkSession` fields.
Unavailable canonical reads preserve the confirmed receipt for refresh-only retry.

C3.2 host validation:

- `flutter test --no-pub --concurrency=1 test/supabase_attendance_operation_transport_test.dart test/attendance_operation_coordinator_test.dart`:
  **172/172 passed** (96 new HTTP tests plus all 76 unchanged C3.1 tests), zero
  failures/skips. Covers raw JSON/offset fidelity, frozen request/final-note
  preservation, strict replay misses, one-attempt/redirect/error handling,
  bounded stream draining/UTF-8/BOM/length checks, delayed acquisition, all
  binding/generation mismatches, relogin/invalidation, late receipts without
  stale refresh, caller timeout/queue lifetime and active/closed canonical reads.
- `flutter analyze --no-pub`: passed, no issues.
- `flutter test --no-pub --concurrency=1`: **964/964 passed** (868 retained plus
  96 new), zero failures/skips, in approximately 1 minute.
- `git diff --check` and new-file UTF-8/whitespace/newline checks passed.
- C: **9.94 GiB** before work/full validation and **9.93 GiB** after; E:
  **23.68 GiB** before/after. Final available RAM: **1.41 GiB**. C: remained
  above the 5 GiB stop rule. Existing SDK/cache/dependencies were reused, without
  package upgrades, dependency downloads, cleanup or pagefile changes.

Production credential issuance must share C3.1 context epochs, including logout
intent and same-user relogin; client ownership/lifetime must cover submitted local
work through settlement. These trusted dependencies, global ownership/fencing,
migration provenance/source assignment, generic native recovery, backup review,
backend deployment/cutover, receipt consumption/compaction and app integration
remain gated. No real requests/data, Android/Gradle/emulator, Docker or hosted
operations are part of this slice; no native or power-loss guarantees are added.
See [Secure Command Journal](secure-command-journal.md#c32-isolated-http-transport-and-canonical-reader).

Previous slice: **M2.3c.C3.1, isolated attendance operation coordinator core**,
based on clean reviewed **`9d74ed4`** on `feature/manual-attendance`.

The opt-in core reuses format-2 `JournalCommand`, `JournalConfirmation`,
`CommandJournal` and `JournalStorage` without changing their schema/CAS rules.
It defines injectable owner/generation contexts, frozen-command/full-receipt
transport and canonical session reads; only fictional host fakes are supplied.
No main/controller/screen/auth wiring, production Supabase transport, Android
composition, migration execution, hosted/backend activation, GPS/UI, backup-policy
or standalone-note-outbox work is included. Live legacy attendance is unchanged.

Fresh v2 commands persist prepared and transmission phases before dispatch.
Complete original acknowledgement JSON is validated and confirmed before any
canonical read. Refresh failure retains the receipt and can retry refresh without
resending attendance. Lost replies, replay-only misses, malformed responses,
conflicts and storage uncertainty retain original commands/keys/request bytes.
The core never compacts, clears, dispatches legacy commands, processes pending
migration metadata or automatically retries a mutating RPC.

The approved invalidation exception finalizes only a valid receipt for an already
submitted operation, into its exact original binding/command/revision. Full prior
record/replacement checks prevent key-only equivalence or retargeting. Old
generations cannot initiate dispatch/refresh or expose employee snapshots;
same-user relogin invalidates them too. Receipt persistence uncertainty stays
unresolved; matching readable bytes are never promoted to durability proof.

Full-binding queues serialize instances within one Dart isolate and outlive
caller timeout/disposal, awaiting all submitted work and context release. They
do not provide cross-binding, engine/process/restart or durable global ownership.
Each context object is consumed once; in-flight/completed reuse is rejected
without releasing the original attempt's ownership again.
Volatile per-instance successful-confirmation evidence permits refresh retries;
restored/other-instance confirmed records without that evidence require further
recovery. No generic native durability barrier or restart guarantee is added.
Interfaces, all outcomes and production prerequisites are documented in
[Secure Command Journal](secure-command-journal.md#c31-isolated-attendance-operation-core)
and [Android Journal Storage](android-journal-storage.md#c31-remains-host-only).

C3.1 host validation:

- `flutter test --no-pub --concurrency=1 test/attendance_operation_coordinator_test.dart`:
  **76/76 passed**, zero failures/skips. Fictional tests cover frozen evidence,
  timestamp/note/request/receipt JSON preservation; before/after-commit and
  readback failures at all three persistence boundaries; refresh-only retries;
  lost/timeout/malformed responses and replay misses; CAS/full-record conflicts;
  current/queued/late invalidation and same-user relogin; timeout/disposal during
  submitted persistence/transport; context reuse/release and unavailable storage;
  cross-instance queue scope; legacy/migration gates and note-save exclusion.
- `flutter analyze --no-pub`: passed, no issues. Initial style findings were
  fixed. Original-command assertions compare complete frozen values rather than
  object identity, since the existing record codec revalidates/decodes objects.
- `flutter test --no-pub --concurrency=1`: **868/868 passed**, zero failures/skips
  (792 retained plus 76 new), in approximately 1 minute 9 seconds.
- `git diff --check` and new-file UTF-8/whitespace/newline checks passed.
- C: initially **9.05 GiB**, E: **23.68 GiB** free. C: was **10.26 GiB** before
  and after the final full suite; E: remained **23.68 GiB**. All measured
  C: values stayed above the 5 GiB stop rule. Existing SDK/caches were reused;
  no dependency resolution/download, Android build/emulator, Docker, hosted
  operation, destructive cleanup or pagefile change was performed.

These are host simulations, not actual durable/encrypted writes or new Android
results. Real auth/credential adapters, provenance/source assignment, writer
retirement/fencing, generic native recovery, reviewed backup handling, backend
deployment, consumption/compaction and production activation remain gated.

Previous slice: **M2.3c.C2c.3, isolated migration coordinator**, based on clean
committed **`4fe2ab1`** on `feature/manual-attendance`.

The opt-in coordinator composes the existing planner, journal import/completion
transitions and native migration primitives. Native namespace preflight runs
before context acquisition, reads or import. Normal-app execution is rejected;
the independent cleanup gate remains validation-package-only. No production
provider, actual migration, live writer/controller/auth/startup/resume wiring,
RPC, v2 activation, GPS/UI, backup-policy or journal-format change is included.

Each attempt acquires a fresh external context for the exact approved source,
full destination binding, exclusive global assignment and writer fencing. Only
fictional harness contexts are supplied. Context validity is checked across
async steps, internal read/CAS and channel recovery calls, including errors.
Queues serialize the derived source filename across coordinator instances and
different bindings within one Dart isolate; durable global and cross-isolate/
engine/process ownership remains an external integration duty.

Import/retry compares complete records, preserves original legacy command/key/
timestamp strings, and never selects a higher revision merely as success proof.
Cleanup establishes a fresh target barrier and checked durable source absence
before completion CAS. The new native completed-record barrier is verification
only; pending cleanup eligibility is unchanged. Readable bytes following a failed
CAS do not prove durability. Unexplained differences block; transient failures
do not persist terminal blocked phase. Uncertain commands remain uncertain,
confirmed receipts are retained, and no command is dispatched/compacted.

Source queues/contexts outlive submitted work. Caller timeout/disposal does not
cancel native IO or release fencing. An indefinitely lost reply stays unresolved;
external restart/worker-drain/ownership policy is required. See
[Secure Command Journal](secure-command-journal.md#c2c3-isolated-migration-coordinator)
for interfaces, outcomes and the exact persistence/restart sequence, and
[Android Journal Storage](android-journal-storage.md#c2c3-coordinator-extensions)
for the two narrow native extensions.

C2c.3 validation (2026-10-18):

- `flutter analyze --no-pub`: passed, no issues after fixing eight brace-style
  findings. Early focused tests exposed masked context-invalidation reporting;
  the coordinator now rechecks validity on adapter error paths too. Two test
  fixtures were corrected without changing settled planner/legacy rules: an
  absent unrelated source is noAction, and the legacy decoder requires UTC `Z`.
- Final `flutter test --no-pub --concurrency=1`: **792/792 passed**, zero failures
  or skips (739 retained + 45 coordinator + 8 adapter-contract tests). This
  includes the final source recheck after an already-completed record's barrier.
  Host channel/storage failures and lost replies are simulations, not Android IO.
- Both isolated app/test APKs built offline in **1 minute 28 seconds**, reusing
  SDK/Gradle caches, one worker and the unchanged 1 GiB heap. Existing Java/Gradle/
  Kotlin deprecation warnings were non-fatal. Package/instrumentation target
  inspection confirmed only the isolated validation namespace before install.
- Actual Android 17/API 37 x86_64, 16 KiB pages: **fresh 44/44; restart 9/9**,
  zero failures, both `INSTRUMENTATION_CODE: -1`. All prior 36 fresh/6 restart
  checks remain, including descriptor regression and conservative recovery.
  Eight new fresh cases exercise actual coordinator composition, original
  check-in/checkout records, independently validated fictional receipt,
  source reappearance, namespace guard, and injected pending/completed failures.
  Three new restart cases reestablish fictional external prerequisites for
  source-present pending import, already-deleted pending import, and readable
  completed metadata following a reported committed CAS failure plus failed
  completed-record barrier. Complete original records are compared throughout.
- Only the isolated app was force-stopped between phases, without data/key
  clearing or reinstall. The original fictional key-loss check ran last. The
  emulator was stopped after validation; no Gradle JVM or Docker remained.
- Execution was sequential: host tests, offline build, then existing headless
  Pixel_9/two cores/software graphics/no snapshots/no wipe. The image enforced
  4 GiB guest RAM despite a 1.5 GiB request (MemTotal 4,007,032 KiB). Initial free
  space: **11.28 GiB C: / 23.68 GiB E:**; pre-emulator RAM: **3.22 GiB**.
  Monitored startup minimum was **8.73 GiB C:**; all later measured values stayed
  at or above **8.60 GiB**, above the 5 GiB stop rule. Final: **11.14 GiB C: /
  23.68 GiB E:** free, **3.45 GiB available RAM**. No downloads, destructive
  cleanup, pagefile changes, Docker or hosted operations were needed.
- `git diff --check` and new-file UTF-8/whitespace/newline checks passed.

Staged boundaries, injected errors and force-stop between phases do not test
termination during IO or kernel synchronization failures. Native close-failure
injection, older AtomicFile behavior, multi-process stress, permanent key
invalidation, OS reboot/power loss, physical/OEM devices and backup/device
transfer remain unvalidated. No power-loss durability or production readiness
is claimed. Production approval authority/reverification, durable source binding,
writer retirement/fencing, cross-engine ownership/lost-reply recovery, reviewed
backup exclusions and separately approved C3/activation remain outstanding.

Previous slice: **M2.3c.C2c.2, isolated Android migration primitives**, based on
clean committed `6bd7235`. Versioned inspection derives only the bound legacy
filename in Android filesDir, returns bounded immutable observations and content
snapshot identity, and rejects links/non-regular/unreadable/ambiguous sources.
Fresh target verification reuses encrypted storage locks, authentication,
descriptor/directory synchronization and full-record readback. Checked source
cleanup is natively rejected outside `com.example.chantipoint.journalvalidation`;
no Dart boolean bypass exists. Pending metadata/commands/phases/revisions/receipts
are retained. The later coordinator still owns cleanup-completion CAS.

The live legacy writer/controller/startup, format/state machine, GPS/UI, backup
rules and hosted Supabase are unchanged. Native locking does not fence the legacy
writer. Trusted provenance approval, global source binding, writer retirement,
restart coordination, backup policy and C3 activation remain pending. See
[Android Journal Storage](android-journal-storage.md) and
[Secure Command Journal](secure-command-journal.md).

**Descriptor ownership review fix (2026-10-18):** `LegacySourceFiles.inspect`
now explicitly closes each `Os.open` descriptor in `finally`. Android's borrowed
`FileInputStream(FileDescriptor)` does not own that descriptor. Construction,
fstat, bounded reads and post-read checks are all covered. A close-only error
becomes typed `journal_unreadable`; an earlier failure is preserved with a safe
typed close failure suppressed. No-follow, identity, bounds and snapshot checks
are retained. Production deletion remains disabled.

Test-only fixture-specific `/proc/self/fd` counts include unlinked descriptors.
Positive controls verify detection after a borrowed stream closes and after a
sidecar is unlinked. Four new fresh checks repeatedly exercise finalized reads,
source-plus-sidecar reads, oversized source/artifact failure after open, and
cleanup failures/retries/already-absent cleanup. Existing restart checks also
repeat absent cleanup, assert no fixture descriptors remain, and compare the
complete original encrypted records. No private paths/content are reported.

Review-fix host validation: analysis passed with no issues; all **739/739**
Flutter tests passed serially. Both isolated APKs rebuilt offline successfully
in **2 minutes 32 seconds**, with one worker, the unchanged 1 GiB Gradle heap and
existing SDK/caches. Compilation is separate from actual runtime validation:
Android 17/API 37 x86_64, 16 KiB pages passed **fresh 36/36; restart 6/6**, zero
failures, both `INSTRUMENTATION_CODE: -1`. Only the isolated app was force-stopped
between phases; no data/key clearing or reinstall occurred between them. The
fictional key-loss check remains last. The task emulator was stopped afterward.

The first emulator startup hit the **below-5-GiB C: stop rule** and was stopped
before installation or instrumentation. No cleanup or pagefile change was made.
After resources recovered to **11.33 GiB C: / 3.02 GiB available RAM**, one retry
succeeded. The retry's monitored startup minimum was **8.81 GiB C:**; subsequent
measurements through runtime/shutdown stayed at or above **8.75 GiB**. The image
enforced a 4 GiB guest despite the smaller request. Final measurements after
shutdown: **11.28 GiB C: / 23.68 GiB E:** free, **3.70 GiB available RAM**; no
emulator, Gradle JVM or Docker process remained. No downloads were required.

`git diff --check` and new-file whitespace checks passed. Native close-failure
injection remains untested. The older AtomicFile, kernel-fault, multi-process,
mid-operation termination, power-loss, device/OEM and backup/transfer limitations
below remain. These results do not establish power-loss durability or activate
migration, the live controller or hosted v2.

**Initial C2c.2 validation (before the descriptor review fix):**

C2c.2 host validation: `flutter analyze --no-pub` passed after two brace-style
findings were fixed; `flutter test --no-pub --concurrency=1` passed **739/739**,
zero failures/skips (704 retained plus 35 new adapter tests).

Both isolated app/test APKs built successfully offline with existing SDK/Gradle
caches, one worker and the existing 1 GiB heap. The first invocation stopped
before compilation because PowerShell split an unquoted target property into a
`.dart` task; quoted argument strings fixed the command. The successful build
took 1 minute 8 seconds; existing Java/Gradle/Kotlin warnings were non-fatal.
APK package and instrumentation-target inspection confirmed only the isolated
validation namespace before installation.

Actual Android 17 / API 37 x86_64, 16 KiB page results: **fresh 32/32; restart
6/6**, zero failures, each with `INSTRUMENTATION_CODE: -1`. These retain all prior
15 fresh/4 restart checks and add 17 fresh/2 restart migration checks. Coverage
includes exact source bytes/hashes, absence/unrelated files, malformed/oversized/
unreadable inputs, temporary/unexpected artifacts, links/non-regular files,
path-request rejection, target/source relationships, stale snapshots/targets,
blocked states, existing encrypted-sidecar policy and native normal-namespace
cleanup rejection. The namespace-negative test uses a native Context wrapper;
the normal app was not installed/launched.

All three deterministic native injections passed: target barrier failure before
deletion, false unlink result, and failure after unlink before source-directory
sync. Encrypted evidence stayed unchanged; source remained present for the first
two and absent for the third. Subsequent retries succeeded, exercising lock
release and fresh durable-absence verification. Complete expected records retain
original commands/keys/binding, phase/revision, confirmed receipt and pending
migration metadata. After force-stopping only the isolated app, source-present
and already-deleted fixtures resumed successfully without data/key clearing or
reinstallation between phases. The original fictional key-loss check remained
last, intentionally leaving fixture ciphertext retained without its fixture key.

Execution was sequential: host tests, build, then the existing headless Pixel_9
emulator with two cores/software graphics/no snapshots/no wipe. Its image again
enforced 4 GiB guest RAM despite a 1.5 GiB request (guest MemTotal 4,007,032 KiB).
C: initially had 8.53 GiB free; all measured values stayed above the 5 GiB stop
threshold. The user closed unneeded applications after a low-memory check.
The task emulator was stopped afterward. No SDK/package downloads, destructive
cleanup, pagefile changes, Docker startup, hosted operations or real migration
occurred. `git diff --check` and new-file whitespace checks passed.
After emulator shutdown: **11.40 GiB C: / 23.68 GiB E:** free, **3.49 GiB available
RAM**, and no emulator, Gradle JVM or Docker process in the resource check.

The injected failures are not real kernel IO faults, and staged/force-stop
boundaries are not a process kill during an operation. Sudden power loss/reboot,
older AtomicFile implementations, multi-process stress, permanent key invalidation,
physical devices/OEM behavior, backup/transfer and C2b.1 duplicate-cleanup native
failure injection remain unvalidated. These results do not establish power-loss
durability, device-loss recovery or production readiness.

Previous slice: **M2.3c.C2c.1, isolated host-side legacy migration planner**, based
on committed `4225fcd`. Bounded immutable source snapshots now compute actual
SHA-256 using cached `crypto` 3.0.7, promoted from transitive to direct dependency
without a version upgrade. Strict C2a parsing/approval/schema/transitions are reused.
Plans distinguish no action, binding required, import proposal, cleanup resumption
and blocking. Original legacy command/key/timestamps remain unchanged; resumed
records retain complete phase/revision/receipt state. Approved imports propose
`uncertain` with plaintext cleanup pending and cannot dispatch.

External approval authority/provenance is a caller trust obligation, defaulting
to unverified. Plans explicitly list outstanding writer-fencing, global binding,
snapshot/CAS, native durable verification and checked cleanup/absence obligations;
they perform or authorize none of those operations. One-source/one-destination
enforcement, approval/restart policy, backup exclusions, writer retirement and C3
activation remain pending. See [Secure Command Journal](secure-command-journal.md).
The live legacy store/controller/startup and native implementation are unchanged;
no real migration, Android work, RPC or hosted operation occurred.

C2c.1 host validation: `flutter analyze --no-pub` passed with no issues after
correcting one new test's brace-style finding. The full
`flutter test --no-pub --concurrency=1` suite passed **704/704**, zero failures or
skips: 583 retained tests plus 121 planner/source-verification tests. Coverage
includes known empty/abc SHA-256 vectors, false digests, exact byte/whitespace
changes, full binding conflicts, both legacy operations, uncertain/confirmed
resumption with present/absent source, receipts/revisions, completed metadata,
artifacts, malformed/oversized input, storage failures and immutable inputs.
`flutter pub get --offline` reused cached packages; `git diff --check` and checks
of the new files passed. No Android/native durability validation was performed.

Previous slice: **M2.3c.C2b.1, limited duplicate-artifact recovery**. C2b is
committed at `69095c7`. Recovery is isolated from the live controller: only main
plus one fully validated, byte-identical .new/.bak can normalize. Ambiguous,
orphan, invalid and three-artifact histories remain preserved and blocked.
Snapshot rechecks, reauthentication, retained-main synchronization, checked
cleanup and full readback run under native locks; original intent/phase/revision
and blocked states remain unchanged. A separate fictional Android runtime
harness is provided. See [Android Journal Storage](android-journal-storage.md).

C2b.1 validation continuation: analysis passed and the full serial Flutter suite
passed **583/583**, zero failures/skips, superseding the earlier resource-stopped
570-test run. The isolated app and test APKs built offline against API 36 with
one worker, a 1 GiB JVM heap and existing caches. Actual Android 17/API 37 x86_64
runtime results: **fresh 15/15; restart 4/4**, both zero failures. The existing
API-37.2 Pixel_9 image uses 16 KiB pages and overrides a 1.5 GiB RAM request to
4 GiB; two cores/headless execution and sequential host/build/emulator work were
used. An initial low-memory process kill was not a journal result. A fixture-only
raw/canonical-parent path check was diagnosed and corrected; production recovery
logic and policy were unchanged. Restart checks now compare the entire expected
original record, including binding, idempotency key, complete command, phase and
revision. Only the isolated app was force-stopped between phases, preserving
data/key; the final missing-key test intentionally removes only its fictional key.

C: started at 13.37 GiB free and remained above the 5 GiB gate; E: started at
23.68 GiB. The task emulator was stopped after validation. No downloads, cleanup,
pagefile changes, hosted operations, live activation or C2c migration occurred.
Final measurements: **11.63 GiB C: / 23.68 GiB E:** free and **2.99 GiB available
RAM**; emulator/Gradle/Docker were stopped.
Actual native cleanup/synchronization failure injection, older AtomicFile writers,
multi-process contention, mid-write process kill, reboot/power loss, permanent
key invalidation, physical-device/OEM and backup/device-transfer checks remain
pending. Host mocks and .bak fixtures on API 37 do not establish those guarantees
or production readiness. Details and reproducible commands are in
[Android Journal Storage](android-journal-storage.md).

Earlier C2b/C2a baseline: C1 v2
support is committed at `6e38bbc`; C2a is committed at `c5505cd`. C2a adds format-2 serialization,
identity binding, revision/key compare-and-swap transitions, confirmation
retention, blocked recovery, and legacy import preparation. See
[Secure Command Journal](secure-command-journal.md) for the exact schema and
recovery contract.

C2b adds the opt-in Dart MethodChannel adapter and native Keystore AES-256-GCM /
AtomicFile backend. Native CAS, locking, synchronization and readback are
implemented; Android runtime validation was pending at that baseline. Focused
C2b.1 runtime results and remaining durability/platform checks are recorded above.
See [Android Journal Storage](android-journal-storage.md).

C2b host validation: analysis passed; all **538 Flutter tests passed** (469
existing and 69 new), with zero failures/skips. A cached, 256 MiB Kotlin compile
check passed the native journal and MainActivity against API 36 without Gradle.
`git diff --check` passed. No Android runtime/security/durability tests were run.

C2a local validation: `flutter analyze --no-pub` passed; the full
`flutter test --no-pub --concurrency=1` suite passed **469 tests** (227 existing
and 242 new), with zero failures or skips. `git diff --check` passed.

The live controller still uses the unchanged legacy version-1 file store.
Actual legacy migration (C2c), coordinator activation (C3), remaining Android
runtime validation, and hosted v2 deployment/cutover remain pending. Host simulation
does not validate Android disk durability, encryption or process-death recovery.

## Earlier Implementation and Validation Records

M2.3b.2b backend employee-note implementation on `feature/manual-attendance`, starting from committed M2.3b.2a `4c5ab75`. The developer reports that factory check-in and checkout succeeded against hosted `chantipoint-dev`. The business-timezone refactor has not been retested on Android; the earlier manual authentication checks below remain developer-reported.

## Completed Slices

| Slice | Result | Verification |
| --- | --- | --- |
| M2.1 - Supabase backend foundation | Initial migration deployed to hosted `chantipoint-dev`; profiles, roles, RLS, attendance RPCs, idempotency, single-active-session protection, and administrative audit safeguards are implemented. | 70 local pgTAP tests passed. |
| M2.2 - Flutter authentication | French password login, active-profile/role authorization, session restoration, resume revalidation, auth-event handling, safe retry states, stale-response protection, and reliable logout are implemented. Android's main manifest includes INTERNET permission. | 62 Flutter automated tests passed; `flutter analyze` passed; developer-reported Android and hosted checks below succeeded. |
| M2.3a - Manual factory attendance | French employee-only active-session, check-in and manual checkout workflow using existing RPCs and RLS reads; configured America/Montreal business time; durable pending-command recovery. | 118 Flutter tests passed, including all 62 authentication tests, RPC response-shape compatibility, and business-timezone coverage; static analysis passed. The developer verified hosted factory check-in and checkout before this timezone refactor. |

M2 as a whole still needs the revised client workflow; attendance classification and employee-note backend operations are implemented locally, with v2 attendance behind its legacy gate. No production geofencing or automatic checkout is implemented.

## M2.3b.1 Locally Validated Database Foundations

New forward-only migration: `20261016000100_attendance_location_foundations.sql`. It adds nullable all-or-none factory coordinates/radius with range/positive-radius constraints, adds location_unverified to the session context check, adds nullable employee_note text with a 1,000-character limit, and removes the external-only observation guard while preserving active-session/identity checks and all existing coordinate/evidence relationships. No configuration values are seeded. The initial migration, RLS/grants, event types, public RPC signatures/responses, and Flutter files remain unchanged. checkout_reason_code is retained pending a historical data/closure-event audit before later removal.

The approved target is foreground arrival/departure evidence, automatic server classification (factory/external_worksite/location_unverified), non-blocking unavailable GPS with technical event reasons and review, independent outcomes, and a general employee note editable while active/read-only after checkout with overwrite-only saves, a final edit atomic with manual checkout, and no note edit history. This latest note decision supersedes earlier revision/audit proposals. Those revised workflows were not implemented by M2.3b.1. Gated attendance backend operations are now implemented in M2.3b.2a below; note writes are now implemented in M2.3b.2b; Flutter acquisition/note UI remain pending. The current Flutter client rejects location_unverified; do not expose new-context records before a coordinated upgrade. Legacy contexts are not retroactively verified location evidence.

Final review applied the migration successfully to the existing local database using `supabase migration up --local`, after confirming only the initial migration was recorded. `supabase test db` passed both suites: M2.1 70/70 and M2.3b.1 71/71, 141 total with zero failures; separate suite runs confirmed each count. The cached PostgreSQL 17.11 and pg_prove images and existing volume were used without reset, data/volume replacement, or downloads. All seven application tables and auth.users were empty before and after validation; test fixtures rolled back. Both migrations remain recorded locally, the database stopped cleanly, and Docker Desktop is stopped. Hosted development was not changed. No SQL, Flutter, or Android changes were made during final review; Flutter/Android integration was not retested. See [Backend Setup](backend-setup.md#m23b1-foundations-and-compatibility) for compatibility and test details.

## M2.3b.2a Implemented and Locally Validated

New forward-only migration: `20261017000100_attendance_v2_contract.sql`. Adds bounded event metadata, development-policy classification, semantic request hashing, v2 check-in/checkout, and guarded legacy wrappers. The original implementation bodies remain private with client execution revoked. Arrival/departure outcomes are independent, location failures permit authorized attendance with review, and replay returns original outcomes without reacquiring evidence. No note editing, note versions/history, Flutter, monitoring or automatic-closure changes.

`supabase migration up --local` succeeded. Final `supabase test db`: 568 assertions passed, zero failures (70 + 71 unchanged, plus 427 new). Four real concurrent same/different-key check-in/checkout scenarios passed 26 assertions. The initial harness cleanup failed with SQLSTATE 42601 due to a missing semicolon after pg_get_functiondef output; it was fixed, only its verified fictional fixtures were removed, and complete reruns passed. No migration or pgTAP assertion failed.

At the end of M2.3b.2a, three migrations were recorded locally. The gate remained legacy mode 1; all eight checked tables remain empty, temporary pgTAP is removed, and PostgreSQL/Docker are stopped with the existing volume preserved. No image pulls, resets, hosted operations or Android/Flutter retesting occurred. [Attendance Backend Contract](attendance-backend-contract.md) records signatures, provenance, limitations and validation. Hosted deployment still requires separate approval and M2.3b.1-before-M2.3b.2a ordering.

## M2.3b.2b Implemented and Locally Validated

Forward-only migration `20261017000200_employee_session_notes.sql` reuses the existing employee_note column, adds owner-only active-session overwrite/clear saves, and finalizes check_out_v2 with preserve/replace/clear and exact text in its command hash. The final note and closure are atomic. Prior migrations, RLS/direct-write restrictions, legacy hashes and GPS evaluation are unchanged. No note history, versions, edit/audit/correction events, Flutter or hosted changes.

The migration applied successfully without a reset. Final local pgTAP: **664 passed, zero failures** (70 + 71 + 427 retained, 96 new). One existing assertion now expects the new dedicated note RPC; the preserve-note test description is current. An initial new-suite test SQL missing quote was fixed after 39 passing assertions; dedicated/full reruns passed. Existing attendance concurrency passed 4 scenarios/26 assertions; note concurrency passed 5 scenarios/28 assertions, with real overlapping transactions and verified lock waiting.

Final local state is four recorded migrations, gate 1, all eight checked tables empty, pgTAP removed, database/Docker stopped with the original container/volume retained. All final function bodies match sources. Standalone note saves have no independent command journal or version check: last serialized active save wins and an uncertain response needs reconciliation before retry. Final-note checkout retains hash-checked attendance idempotency. See [Attendance Backend Contract](attendance-backend-contract.md) for exact signatures and limitations.

## Manual Authentication Verification

The developer verified the following using a fictional development account:

- The app launched successfully on the Android emulator.
- Real login against hosted `chantipoint-dev` succeeded and recognized the active employee profile and role.
- Logout succeeded.
- The session survived Android app task removal and Force stop, and was restored when the app reopened.
- Disabling the employee profile removed application access when the app resumed.
- Re-enabling the profile allowed login again.

These checks cover development authentication. Production release and real-device background location reliability remain unvalidated.

## Accounts and Session Boundaries

Public signup is disabled. V1 account policy is administrator invitation only. The current hosted-development account used for testing is fictional and was provisioned through trusted backend administration. Application workflows for initial administrator provisioning, inviting employees, and managing account activation are still to be implemented. No account identifiers or credentials belong in this document.

Application access requires an active profile and at least one active recognized role. Authorization is checked after login, during session restoration, on resume, and on relevant authentication events. Definitive profile/role denial removes access and clears the session. Temporary network, backend, or query-permission failures hide authenticated content and preserve an otherwise valid session for retry. Logout prevents repeated actions and distinguishes a retained session from local logout whose server confirmation failed.

Revocations are rechecked on resume and relevant events; this is not continuous role monitoring. The app does not introduce polling, GPS collection, or background tracking through authentication.

## Factory Attendance Reliability

M2.3a uses server acknowledgements and RLS-protected session reads. The app persists a single pending command per employee in app support storage before sending its RPC, including the original idempotency key and device-observed timestamp. Retries and restart recovery reconcile that intent against server state and reuse its exact payload. An unresolved outcome blocks new commands; it is not full offline synchronization.

The journal contains no auth credentials or GPS data. App-data deletion/uninstall removes it. A corrupt record or an unresolved key conflict blocks new pointages and may require operator assistance; do not clear an uncertain record merely to bypass recovery. Storage access and timezone conversion use the focused `path_provider` and `timezone` dependencies.

The developer verified hosted factory check-in and checkout. Real process-kill recovery on a device remains unverified; local tests include a new controller and file store reading the persisted intent. Android integration was not repeated for the business-timezone refactor.

## Business Timezone

JMService's application configuration now uses `America/Montreal` and the separate French label `heure de Montréal`. The shared business-time module accepts an explicit IANA identifier and optional display label for future regions. The installed `timezone` 0.11.2 default database excludes the Montréal alias; `latest_all.dart` resolves it successfully without a package upgrade. Tests verified alias resolution, winter/summer offsets, spring-forward and fall-back behavior, distinguishable repeated local times, differing UTC/local dates, Vancouver formatting, and preservation of UTC session timestamps and elapsed time.

UTC remains authoritative for stored session timestamps and pending-command payloads. Conversion occurs only for display/calendar interpretation and follows IANA DST rules. Future monthly reports must derive local calendar-month boundaries in the configured business timezone, convert those boundaries to UTC, and use elapsed UTC intervals for totals. Monthly reporting, a timezone settings UI, database timezone configuration, and multi-company timezone workflows are not implemented.

M2.3a validation (historical): `flutter analyze --no-pub`, `flutter test --no-pub --concurrency=1` (118 tests), and `git diff --check` passed. Android integration was not retested.

## Next Implementation Slice

Review and approve M2.3b.2b code and validation. Next integrate the revised Flutter/journal contract, including active-note save coordination and immutable final-note checkout intent/text. Obtain separate authorization before hosted deployment and coordinated v2 cutover. The legacy external check-in still raises external_worksite_location_required_pending_policy without coordinates; the gated v2 implementation supports the approved non-blocking target and awaits client cutover. Factory coordinates/radius remain unconfigured until trusted approval. Android business-time display and real process-kill recovery remain separate unverified checks.

After the full manual attendance slice, M3 covers administrator account management, session review, and maps where approved coordinates exist. See [Backlog](backlog.md).

## Outstanding Work and Decisions

- Administrator bootstrap, invitations, account management, and their audit requirements; review/closure of active sessions when an employee is disabled.
- Integrate the gated v2 backend into Flutter with immutable evidence/diagnostic payloads, protected versioned journals, all contexts and recovery support. Integrate the implemented overwrite-only note RPC and atomic final checkout note, with no history and explicit uncertain-save reconciliation. Production thresholds and collection approval remain pending.
- Audit historical checkout_reason_code values and closure-event consistency before removal.
- Corrections, notifications, monthly attendance reports, and CSV exports; break rules and monthly approval requirements remain open. Separate provisional location-failure, geofence-exit, and configurable 16-hour duration policies are documented in Requirements; client, privacy, and technical approval and implementation remain pending. GPS failure/silence alone never triggers checkout. No notification, timer, geofence, or automatic checkout is implemented in M2.3b.1.
- Real-device location feasibility, approved geofence/evidence rules, automatic-checkout policy, and Android/iOS delivery decisions.
- Formal client scope approval, privacy/EFVP review, employee notice, BYOD expectations, retention by data category, and operational/release validation.

The draft planning documents describe a larger target product than the implemented subset. Completion of M2.1 and M2.2 does not mark these remaining features or production release gates complete.

## Related Documentation

- [Run Flutter with build-time configuration](../README.md#run-the-flutter-app)
- [Backend setup and deployed migration](backend-setup.md)
- [Requirements](requirements.md)
- [Security and Privacy](security-privacy.md)
