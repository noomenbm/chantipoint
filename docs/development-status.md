# ChantiPoint Development Status

Current slice: **M2.3c.C3.3, combined auth ownership and credential authority**,
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
