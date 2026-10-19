# Secure Command Journal — C2a Core and C2b Android Storage

C2a implements the platform-independent format-2 codec, immutable command and
confirmation models, state transitions, asynchronous persistence contract, and
legacy import preparation. It is isolated from the live application. The
existing version-1 plaintext store, attendance controller, authentication,
repository and employee UI remain unchanged.

C2b implements an opt-in MethodChannel adapter and Android Keystore/AtomicFile
storage. MainActivity registers the channel, but no live controller instantiates
the adapter. Registration creates no journal files or encryption keys. Native
encryption, durability, process-death recovery and backup behavior still require
actual Android testing. The test memory backend and MethodChannel mocks verify
host contracts only; their bytes are plaintext RAM simulations.

## Format 2

The decrypted record is UTF-8 JSON with exactly these required fields. Optional
content is represented by explicit JSON NULL, not by omitting fields.

| Field | Content |
| --- | --- |
| `journal_format` | Integer 2. |
| `revision` | Positive integer, incremented by every committed change. Zero represents absent storage in memory only. |
| `binding` | `environment_id`, `supabase_base_url`, `auth_user_id`, `company_id`, `employee_profile_id`. |
| `phase` | `empty`, `prepared`, `may_have_sent`, `uncertain`, `confirmed`, `blocked`. |
| `command` | NULL in `empty`; otherwise the immutable command below. |
| `write_may_have_started` | Boolean derived from phase/previous phase, checked during decoding. |
| `confirmation` | NULL until confirmed; retained if confirmed recovery is subsequently blocked. |
| `block` | NULL except in `blocked`; contains `code` and `previous_phase`. |
| `migration` | NULL or verified-source/approval and cleanup metadata. |

Binding identifiers are explicit inputs. UUIDs use canonical lowercase syntax.
The environment ID identifies a deployment instance, including the generation
of a recreated local backend; it is not inferred from UUIDs or a label such as
"development". The base URL is an explicit project origin without a trailing
slash, `/rest/v1/`, user information, query or fragment. HTTPS is required except
for explicit HTTP loopback development origins. No origin aliases are inferred.
Publishable keys, access/refresh tokens, emails and passwords are not stored.

The command has exactly `protocol`, `operation`, `idempotency_key`, and
`parameters_json`. Protocol is `legacy-v1` or `attendance-v2-final-notes`;
operation is `check_in` or `check_out`. The endpoint is derived from that pair.

`parameters_json` freezes the complete original request as a JSON string:

- Legacy check-in: four parameters; legacy checkout: three.
- V2 check-in: all twelve parameters; finalized v2 checkout: all fourteen.
- V2 stores `p_replay_only: false`; a replay map changes only this operational flag.
- Checkout note action is explicit preserve/replace/clear. Preserve/clear require
  NULL text; replace requires non-NULL text, including the distinct empty string.
- NULL diagnostics remain NULL; unknown enum values are rejected. No default
  diagnostic, location fix, timestamp, note or classification is invented.

The original JSON string survives record serialization exactly. Decoded request
maps are immutable and contain only validated primitives. Frozen timestamps and
note text are not trimmed, normalized or reconstructed through clock calls.
Finite partial, out-of-range, stale and low-quality measurements remain intact;
location quality/classification belongs to the backend. No location is acquired.

Numbers must survive Dart parsing without decimal-value loss relative to Dart's
round-trip representation. Integer tokens are limited to +/-9,007,199,254,740,991;
finite floating-point tokens may use exponent notation. NaN, infinity, overflow,
nonzero underflow, excess decimal precision and sign-losing integer `-0` are
rejected. Floating `-0.0` is preserved. Insignificant decimal scale/exponent
spelling is accepted and retained in the frozen JSON. Duplicate-command checks
are conservative about numeric type/sign and exact timestamp/text values.

Confirmation has exactly `source` and `data_json`. Sources are `rpcV1`, `rpcV2`
and `legacySelect`. RPC data must match the actual six-field legacy or ten-field
v2 acknowledgement, including nested outcome fields and operation/session
consistency. `not_found`, hash conflicts and error objects cannot confirm work.
The confirmation object is also bound to its original immutable command.

`legacySelect` is separately tagged evidence, not an invented RPC acknowledgement.
Its data is `{matched_key, session}`. The session has exactly the eight columns
selected by the legacy repository: identity/context/lifecycle, start/end,
description, and both device-observed timestamps. Validation checks the matched
key, original action instant, factory context and checkout target/closure.
C3 must obtain this proof from the correctly scoped repository operation; these
structural checks do not establish server provenance or authorization by themselves.

## Validation bounds

- Decrypted record: 64 KiB; request and confirmation JSON: 16 KiB each.
- Employee note: 1,000 Unicode code points; site description: 500.
- JSON nesting: 12; object/array entries: 64; value nodes: 2,048.
- Number token: 128 characters; bounded exponent representation.
- Invalid UTF-8, unpaired surrogates, duplicate keys (including escaped aliases),
  unknown/missing fields, invalid types and unsupported versions are rejected.
- NUL in textual fields is rejected because PostgreSQL text cannot represent it.
- Instants require an explicit offset, valid calendar components and at most
  microsecond precision. DateTime overflow normalization is not accepted.
- Revisions cannot overflow or reset; decoded positive revisions are bounded by
  the same safe-integer maximum.

An existing invalid record returns blocked recovery, never absence. Public
errors contain codes rather than payloads, paths, employee data or backend text.

## State transitions

| Current phase | Allowed phase-changing actions |
| --- | --- |
| `empty` | Prepare -> `prepared`; approved legacy import -> `uncertain`. |
| `prepared` | Mark transmission -> `may_have_sent`; block -> `blocked`. |
| `may_have_sent` | Mark retry -> `may_have_sent`; uncertainty -> `uncertain`; confirm -> `confirmed`; block -> `blocked`. |
| `uncertain` | Mark retry -> `may_have_sent`; confirm -> `confirmed`; block -> `blocked`. |
| `confirmed` | Safe cleanup -> `empty`; block -> `blocked`, retaining confirmation. |
| `blocked` | Terminal in C2a; explicit authorized resolution belongs to a later milestone. |

The identical pending command may be prepared again as a no-op: it preserves the
first frozen JSON, revision, phase and receipt. A different key or payload cannot
replace an unresolved command. The caller must still supply the current expected
revision/key. Equality does not authorize dispatch or unblock recovery.

The original command/key survives every non-cleanup transition. Confirmation is
allowed only after possible transmission or uncertain legacy import. A replay
miss supplies no confirmation. Hash conflict can be retained as a durable
`hashConflict` block, never converted into successful attendance or an empty slot.

Cleanup requires all of: confirmed acknowledgement, expected revision/key,
canonical server state verified, acknowledgement consumed by the coordinator,
and completed legacy plaintext cleanup where applicable. It atomically writes
an empty tombstone rather than deleting a file. The tombstone retains revision,
binding and minimal migration metadata; request/receipt content is removed.

## Persistence interface and recovery

`JournalStorage` exposes asynchronous `read(binding)` and
`compareAndSwap(binding, expectedRevision, expectedKey, replacement)` only. It
does not expose delete-all, network calls, timers or arbitrary file paths.
`CommandJournal` owns validation and transitions; `JournalCodec` handles bounded
record encoding/decoding. `JournalReadResult` distinguishes absence, a stored
record (including an empty tombstone), and a blocked error. A stored `blocked`
record retains its own recovery reason and evidence.

Codes distinguish corrupt, unreadable, missing key, unsupported format, identity
mismatch, revision conflict, storage failure, command conflict, illegal transition
and missing provenance approval. Other-account/environment records are never
returned to the caller. An absent record under another binding provides no right
to act on the original binding.

A successful CAS must mean committed, synchronized, independently reopened and
verified replacement under the backend's shared lock. It must atomically check
both revision and original key and reject unreadable existing storage. Multiple
backend instances must coordinate. Core-side checking alone cannot replace this
native requirement. Backend exceptions become storage failures, never absence.

A reported write failure may occur **after commit**. Reread before deciding the
next action; do not assume rollback, regenerate a key, or overwrite the slot.
Failure injection tests cover before-write, after-commit and readback failure.

Future dispatch must wait for verified `prepared`, then verified `may_have_sent`
before invoking a mutation. Failure to persist either transition blocks sending.
A crash during sending or after server commit retains the original request/key.
Timeout does not prove failure or cancel an in-flight server operation.

Persist validated confirmation before a later SELECT. A failed SELECT leaves
`confirmed` and prohibits resending the mutation. A confirmation write failure
leaves either the older recoverable command or the complete confirmed record.
Cleanup interruption similarly leaves confirmation or an empty tombstone, never
a new attendance intent. Revision/key checks reject late callbacks.

## Legacy preparation and C2c boundary

`LegacyJournalImport.prepare` parses a bounded finalized version-1 file, including
its owner, using strict validation while leaving the existing decoder/store
unchanged. It performs no filesystem access or actual migration.

Without `LegacyBindingApproval`, valid legacy content returns `bindingRequired`
and no executable command. The approval is an explicit external attestation,
not proof discovered from current configuration, matching UUIDs or login state.
C2c must establish the originating backend and Auth/profile/company relationship,
compute/verify the source SHA-256 using an established implementation, and only
then create that approval. C2a implements no cryptographic hashing or approval UI.

Approval pins exact source bytes, expected finalized filename, full binding and
an approval reference. Metadata contains `source_basename`, `source_sha256`,
`legacy_owner`, `binding_approval_ref`, and `plaintext_cleanup` pending/complete.
No temporary file is auto-promoted; malformed/conflicting input stays blocked.

Approved import starts `uncertain`, preserving all legacy parameters and the
original key. It cannot overwrite an existing command. Mutating retry is blocked
while plaintext cleanup is pending. A matching-digest cleanup attestation only
changes metadata; C2c must verify real deletion and synchronization first.
Confirmation may be retained during migration, but compaction requires cleanup.
Completed metadata remains across later operations to prevent reimporting an
old source as a new migration. Later v2 commands remain supported.

C2c must stop every legacy writer, durably verify encrypted replacement before
deleting an original, handle interrupted migrations and both-copy conflicts,
retain unknown outcomes, and preserve wrong-account records. File deletion
cannot guarantee erasure of flash remnants or previously created backups.

## C2c.1 isolated migration planner

`legacy_journal_migration.dart` adds host-side planning only. It imports no
filesystem, native channel, auth client or attendance repository and is not wired
into application startup. The legacy writer/controller, native recovery policy,
format 2 and journal transitions are unchanged. No actual source is migrated.

Public interfaces:

- `LegacySourceSnapshot.file` copies at most 64 KiB of valid bytes into an
  immutable snapshot and computes actual SHA-256. Invalid byte values or oversized
  snapshots throw a data-free `JournalException(corrupt)` before hashing; callers
  must retain those sources and block. `absent` is only a supplied observation;
  `unreadable` and temporary/unexpected artifact observations cannot mean absence.
- `LegacyApprovalTrust` defaults to `unverified`. `established` is the eventual
  caller's assertion that an external attestation's authority and originating
  deployment/Auth/company/profile relationship have been independently verified.
  It is not an issuer, approval mechanism, or proof discovered by this component.
- `LegacyJournalMigration.evaluate` accepts an explicit expected full binding,
  snapshot, `JournalReadResult`, and optional existing `LegacyBindingApproval`.
  It checks computed digest, exact approved bytes, actual/expected basename and
  all five binding fields, reusing `LegacyJournalImport.prepare` for parsing.
- `LegacyMigrationPlan` reports a step/issue, an existing record when applicable,
  an in-memory `importRecord` only for an import proposal, and immutable
  `requiredChecks`. It has no execute, delete, dispatch or cleanup-attestation API.

`crypto` 3.0.7 is now a direct, pinned dependency for SHA-256; it was already
locked transitively and cached. No package version was upgraded. Approval remains
external: a plausible digest, current configuration/login, matching UUIDs or keys,
and server absence/`not_found` cannot establish origin. Unverified/missing approval
reveals no executable import or resumable record. A digest authenticates neither
the issuer nor the historical binding.

| Supplied observations | Planner outcome |
| --- | --- |
| Source absent, no migration metadata, valid/absent target | `noAction`; preserve any unrelated valid target. |
| Valid source but no established approval | `bindingRequired`; no import candidate. |
| Approved unchanged finalized source; absent/eligible empty target without migration history | `importLegacy`; existing transition proposes `uncertain`, cleanup pending, no confirmation. |
| Exact pending import with source present | `resumeCleanup`; retain original record, not a second import. |
| Exact pending import with source absent | `resumeCleanup`; explicitly require durable target and source-absence verification. |
| Completed migration, source absent | `noAction`; retain tombstone, receipt or later command. No fresh approval is required for this non-action; any supplied approval must be established and match migration identity. |
| Completed migration, source present again | `blocked`; no deletion or reimport. |
| Conflicting binding, command, frozen parameters or migration identity | `blocked`; preserve evidence. |
| Temporary/unexpected artifacts, malformed source, unreadable storage, missing/invalidated key or blocked target | `blocked`; never reset or overwrite. |

An absent source with a pending target requires externally approved original bytes;
the planner rehashes/reparses them, never reconstructing an approval from the
target. Pending equivalence checks protocol, operation, key, every parameter and
the exact frozen `parameters_json`, plus source basename/digest, legacy owner and
approval reference. Timestamp strings are never normalized. Differently formatted
frozen JSON is conservatively blocked, not rewritten to fit; C2a's general
semantic duplicate-prepare behavior is unchanged. Valid later revisions/phases and
confirmed receipts are returned in the original record without modification.
Completed migration metadata can accompany a later v2 command and is not compared
as if that later command were the original legacy intent.

Required future checks are explicit enum values: writer fencing, global source
binding, source snapshot revalidation, target CAS, durable target verification,
checked plaintext cleanup, durable source-absence verification, and cleanup
completion CAS. Import plans list all eight. Resume plans omit import CAS;
source-absent resume also omits source revalidation/deletion. These are outstanding
obligations, not completed checks or permission to delete. `noAction` is not
attendance confirmation, durable-cleanup certification or activation permission.

Integration must retire/fence all legacy writers across restart and account/auth
changes; disposal and an instance-local queue are insufficient. Verify the complete
authenticated encrypted record and synchronize it and its directories before
checked deletion; then synchronize/verify plaintext absence before attesting
completion with the existing CAS. A readable record after a reported failed write
does not prove the failed synchronization succeeded. C2c.1 supplies no native
durability barrier, lost-response handling or restart coordination. C2c.2 below
adds isolated mechanical barriers; production coordination is still required. Planner
failures never move a record into the terminal blocked journal phase.

A per-slot planner cannot enforce one-source/one-destination uniqueness. Durable
cross-binding enforcement and external approval authority/reverification remain
integration decisions. Legacy files still sit at the root of Android `filesDir`
without reviewed backup/device-transfer exclusions; encrypted storage remains in
`noBackupFilesDir`. Backup XML paths do not support filename wildcards, so dynamic
legacy filenames need a reviewed exclusion strategy. Previously created backups,
restored-source handling, writer retirement, native fault-injection validation,
activation and C3 receipt-preserving coordination remain open. No v2 activation
or power-loss/device-loss recovery guarantee is implied.

Host validation results are recorded in Development Status. C2c.1 performs no
Android build/runtime, native cleanup, migration execution or hosted operation.

## C2c.2 native migration boundary

`AndroidLegacyMigration` now supplies versioned source inspection, fresh durable
target verification and checked cleanup primitives. This is separate from the
pure C2c.1 planner and is not a complete coordinator. Exact native contracts,
source snapshot framing/bounds, lock scope and retry behavior are documented in
[Android Journal Storage](android-journal-storage.md).

Plaintext cleanup is hard-gated to the fixed isolated validation-app namespace
by native Context checks, before mutation. No caller boolean enables normal-app
deletion. Native locks coordinate secure storage operations, not the unchanged
legacy writer. Production writer retirement/fencing, trusted historical binding,
global source uniqueness and coordinated activation remain unimplemented.

Both target operations require a fully Dart-validated pending legacy record and
exact native authenticated readback, explicit synchronization and a second full
readback. Existing C2b.1 recovery alone handles eligible encrypted duplicates.
Cleanup rechecks source/artifacts and the exact target/source relationship before
checked unlink, directory sync and absence verification. It never calls the
cleanup-completion CAS or changes a record's command, phase, revision or receipt.
Failures after deletion stay failures; a fresh inspection and target/absence
barriers are required on retry. Successful mechanical verification proves neither
backend origin, attendance confirmation nor global binding exclusivity.

Only fictional instrumentation fixtures exercise deletion and fault injection.
The test-only control state injects pre-barrier, false-delete and post-unlink sync
failures; staged boundaries and force-stop recovery remain distinct from a kill
during IO and from sudden power loss. Backup rules remain unchanged. Actual
validation and remaining platform limits are recorded in Development Status.

## C2c.3 isolated migration coordinator

`LegacyMigrationCoordinator` composes the existing planner, `CommandJournal`
transitions and `AndroidLegacyMigrationBackend`. It is opt-in and has no caller
in main, auth, the live controller, startup/resume or account switching. Only
fictional host/runtime fixtures implement its external context provider. Actual
legacy migration and production activation remain disabled; this is not C3.

The native `requireMigrationValidationV1` preflight accepts only `api_version`
and checks the real Context package before context acquisition, journal reads
(which can normalize duplicates), import or other migration mutation. Only
`com.example.chantipoint.journalvalidation` succeeds. Neither a Dart boolean nor
a request field enables normal-app execution. The separate native cleanup guard
is retained. Host tests verify coordinator rejection before any IO/context; the
Android harness tests the shared native guard against a normal-package Context
wrapper and the actual preflight/composition in the isolated namespace. The
normal application is not installed or launched for this validation.

`LegacyMigrationContexts.acquire(binding, sourceBasename)` must obtain an external
lease for the exact source and complete destination. The lease exposes immutable
approval/trust and a synchronous `checkValid`: the provider must independently
establish historical source approval, exclusive global source assignment and
writer quiescence/fencing throughout the operation. Missing prerequisites return
`prerequisitesRequired`; missing/unverified approval produces `bindingRequired`
through the planner. Conflicting identities block; invalidation stops further
mutations. An encrypted command, matching UUID/current project or server miss
does not establish provenance. Every attempt/restart reacquires the context;
approval is never reconstructed from persisted command metadata.

| Outcome | Meaning |
| --- | --- |
| `noAction` | Planner found no import/cleanup work; no attendance confirmation or activation permission. Existing completed metadata gets a fresh exact-record barrier and source recheck. |
| `bindingRequired` | External approval is missing or unverified; no import/cleanup. |
| `prerequisitesRequired` | No operation lease with the required assignment/fencing was acquired. |
| `invalidated` | Context ceased to be valid; submitted work is retained and must be reinspected. |
| `blocked` | Conflicting/ambiguous/invalid evidence or CAS state; no terminal blocked-phase write is performed. |
| `retryable` | IO/synchronization/lost-response uncertainty or context release failure; no durability attestation. Reestablish prerequisites and replan on retry. |
| `completed` | Exact expected cleanup-completion record verified with a fresh native durability barrier and final observed source absence. Attendance phase is unchanged. |

The bounded execution/restart sequence is:

1. Native preflight, then queue by the derived SOURCE filename, then acquire the
   external context. A static queue shares that filename across coordinator
   instances/different environment, URL or Auth bindings in one Dart isolate.
   It does not provide durable global assignment or cross-isolate/engine/process
   fencing; those remain external provider obligations.
2. Inspect source, read target and run the existing planner. Source observations
   include exact snapshot identity. No-action/binding-required/blocked decisions
   create no command and do not change journal phase.
3. Import only via existing `importLegacy`, expected revision/key, original
   approved command and metadata. Resume uses the complete existing record,
   including later revision/independently validated confirmation. No RPC,
   replacement key, timestamp conversion, compaction or confirmation is created.
4. A reported failed import is reread once and compared against the COMPLETE
   expected record. Exact readability alone is not durability: native cleanup
   must establish its own fresh target barrier before deletion. Unchanged prior
   state returns a failure; unexplained differences block. No blind repeat import
   or highest-revision selection occurs inside the attempt.
5. Existing checked cleanup freshly authenticates/synchronizes the exact pending
   target, verifies snapshot/source relationship, checks unlink, synchronizes
   directories and verifies absence. It also handles an already-deleted source.
   Failed cleanup never permits cleanup-completion CAS in that attempt.
6. Only after cleanup success, `markLegacyCleanupComplete` uses the pending
   digest/revision/key. Reread once and compare the full expected completed
   record. A reported failed completion CAS may already have committed; matching
   readable bytes still require `verifyCompletedMigrationV1`. A failed barrier
   returns retryable even if metadata is readable as complete. A new attempt can
   reverify that completed record without importing/deleting again.
7. The completed-record barrier is verification-only; pending cleanup eligibility
   remains unchanged. A final source inspection rejects reappearing plaintext or
   artifacts. Return the complete record, then release the operation context.

The scoped Android channel checks context validity before and after EACH native
call, including errors and internal duplicate-recovery calls. The storage wrapper
also checks between `CommandJournal`'s internal read and CAS. Native work already
submitted cannot be cancelled by a Dart timeout, disposal or channel detachment.
The coordinator has no internal timeout/cancellation shortcut: it retains the
source queue/context until every submitted future settles, then awaits release.
A permanently lost reply leaves the attempt outstanding. Providers/callers must
not release fencing because a caller-facing timeout elapsed; detached-engine or
process-death recovery needs external worker-drain/durable ownership policy.
Release errors remain unresolved; the external authority must prevent a new
conflicting lease while prior ownership is uncertain.

The supplied contexts only assert these conditions for fictional tests; they do
not fence the unchanged legacy writer or implement production approval/global
binding. Backup policy, approval issuance/reverification, multi-engine/process
ownership and activation remain pending. Host simulations, staged boundaries,
injected replies/errors and force-stop BETWEEN phases are distinct from process
termination DURING native IO, kernel faults and power loss. Actual validation is
recorded in Development Status; no power-loss durability is claimed.

## C3.1 isolated attendance operation core

`AttendanceOperationCoordinator` composes the existing format-2 commands,
confirmations, `CommandJournal` and `JournalStorage`. It has no default adapters
and no caller in main, auth, the live controller/screens or Android composition.
Only fictional host implementations exercise it. The live legacy flow, hosted
Supabase, journal format/state machine and migration coordinator are unchanged.

`attendance_operation_transport.dart` defines three injectable boundaries:

- `AttendanceOperationContext`: immutable full binding/generation identity,
  current authorized-employee observation and asynchronous attempt release. The
  issuer must distinguish same-user logout/relogin from the original generation.
  Current UUID/session presence alone is insufficient. No production issuer,
  durable ownership or legacy-writer fencing is supplied.
- `AttendanceOperationTransport.dispatch(identity, command, replayOnly: ...)`:
  original frozen command plus complete acknowledgement JSON or an explicit
  validated replay-only miss. No typed-request reconstruction, receipt rebuilding
  from WorkSession/AttendanceReceipt, automatic retry, key/clock/evidence
  generation or standalone note save. A future adapter must bind credentials to
  the submitted identity, not whichever account happens to be current later.
  The returned future must represent local submitted work settling, not hide
  continuing work behind an internal timeout. A settled error still does not
  establish the server's outcome.
- `AttendanceCanonicalReader.readSession(identity, sessionId)`: scoped current
  server state of the acknowledged session, including closed sessions. It cannot
  substitute an active-session-only lookup or fabricate state from the receipt.

`submit` accepts only a fresh v2 intent in an absent/empty eligible slot. It
persists `prepared`, then `may_have_sent`, through existing CAS before dispatch.
An existing command is never overwritten. Exact duplicates cannot redispatch:
pending ones return unresolved; confirmed ones may refresh only if this instance
has matching verification evidence. A different command, including differing
frozen request bytes, conflicts. Completed migration metadata can accompany an
eligible v2 slot; pending metadata and all legacy commands remain gated.

Dispatch uses the stored original command value: protocol, operation, key,
`parameters_json`, all timestamp strings/evidence and final checkout note action/
text survive unchanged. A validated complete `rpcV2` confirmation is persisted
before any canonical read. The confirmation's original `data_json` string,
including timestamp representations and JSON formatting, is retained. A canonical
session may subsequently advance independently; it does not rewrite the receipt.

`replay` is explicitly read-only against `may_have_sent`/`uncertain` v2 records.
Only the outgoing replay flag changes. A miss does not clear the command,
authorize a new key or initiate a mutating retry. Transport/malformed-response
failures leave the existing transmission/uncertain phase intact; the core adds
no terminal blocked phase or extra uncertainty CAS. `refresh` never dispatches.
No method compacts, deletes, imports, marks migration cleanup or saves standalone
employee notes. Final checkout note intent remains inside the frozen command.

| Outcome/problem | Meaning and retained state |
| --- | --- |
| `confirmed` | Successful confirmation CAS, matching complete reread, then a canonical read of the correct session. Receipt stays confirmed; no compaction. |
| `confirmedNeedsRefresh` / `canonicalUnavailable` | Confirmation is retained, but canonical read failed, returned null or the wrong session. Later explicit refresh can retry without resending attendance. |
| `invalidated` | Stop further dispatch/refresh/publication. An already submitted valid receipt may still be finalized under the exception below. |
| `gated` / `legacyCommand`, `migrationPending`, `blockedRecord` | Preserve the record; do not migrate, dispatch or replace it. |
| `unresolved` / `pendingCommand` | Matching pending intent already exists; submit is not a retry API. |
| `unresolved` / `commandConflict` | Existing frozen command differs; original evidence is retained. |
| `unresolved` / `journalUnavailable` | Read/identity/codec failure, changed full target before refresh, or an unexpected contract failure. No absence/success is inferred; safe JournalIssue is retained where available. |
| `unresolved` / `persistenceUncertain` | Prepare/transmission/confirmation persistence failed, returned a conflict or lacked successful CAS evidence. It may already have committed. No dispatch follows failed pre-send persistence; no refresh follows failed receipt persistence. |
| `unresolved` / `recoveryRequired` | No eligible recovery state, restored prepared state, or confirmed state without this instance's matching successful-CAS evidence. No fresh durability claim, resend or compaction. |
| `unresolved` / `transportUncertain` | Lost reply, timeout or other transport error; original command/key remain. |
| `unresolved` / `replayMiss` | Explicit replay-only not_found; the original request may still commit. No confirmation/clear/new command follows. |
| `unresolved` / `malformedAcknowledgement` | Invalid/incomplete/inconsistent receipt, unexpected mode/status, or an explicit miss on an initial mutation. No confirmation or canonical read. |
| `unresolved` / `contextUnavailable` | Context identity could not be obtained, release failed, or the same context object was reused. No employee snapshot is exposed; external ownership may need resolution. Reuse cannot release the original attempt's ownership. |

The approved post-invalidation exception is PRIVATE receipt-only finalization
of a call submitted while its captured context was valid. The core validates the
complete reply against that submitted command, then allows one exact confirmation
CAS into that original slot. Its storage wrapper checks the COMPLETE prior record
and replacement, binding, revision and key across CommandJournal's internal
read/CAS gap. Even semantically equal but differently frozen parameters reject.
It cannot dispatch/retry/refresh, change owner, or finalize another command.
Reported receipt persistence failure remains unresolved, including matching
readable confirmed bytes. Successful late finalization returns invalidated with
no employee snapshot; no canonical read follows.

All other async boundaries recheck the captured context, including internal
pre-send read/CAS. Results expose snapshots only while that original generation
is current; confirmed outcomes become invalidated when accessed after a change.
Consumers must check at publication time and not cache a snapshot across epochs.
This core contains no UI publisher or production auth listener.

The full-binding queue is static across coordinator instances in ONE Dart
isolate. It spans persistence, transport, receipt-only finalization, refresh and
context release. Different full bindings do not share this queue. Caller timeout
or disposal cannot cancel submitted work or release the queue/context early.
An indefinitely unsettled future remains outstanding. Release failure is reported,
but the core cannot establish external ownership release. Cross-isolate/engine/
process/restart exclusion and durable global assignment remain unimplemented.
Each context object is consumed once across instances in this isolate; in-flight
or completed reuse is rejected without a second release. Weak tracking avoids
retaining completed contexts. Auth currency remains observable for result checks;
later explicit attempts require newly issued contexts.

Successful CAS is trusted only under the existing JournalStorage contract.
Per-instance volatile confirmation evidence permits bounded refresh retry after
a successful CAS, always comparing the complete reread record. Reads alone never
populate that evidence; failed transitions and mismatching refresh readbacks
invalidate it. Canonical read failures retain it for refresh retry. A matching read after
failed CAS is not durability proof. Restored or another-instance confirmed
records without evidence remain recovery-required. There is no new native
barrier, Android composition, restart or power-loss claim in C3.1.

C3.2 below supplies an isolated HTTP transport/canonical reader. Future
production composition still needs trusted auth-generation and credential issuance,
generic durable recovery, global ownership/fencing, approved migration provenance,
deployment identity, backup policy, backend deployment and separate cutover
approval. C2c.3's validation-only migration barriers are not generic C3 barriers.
Actual host validation is recorded in Development Status; no Android validation
was rerun for this slice.

## C3.2 isolated HTTP transport and canonical reader

`SupabaseAttendanceOperationTransport` implements the unchanged C3.1 transport
and canonical-reader ports. It does not call `SupabaseAttendanceRepository` or
use global Supabase auth. No default client, production credential issuer or
main/controller/auth/Android composition is supplied. Tests use fictional
identities, an injected request authority and `MockClient.streaming` exclusively;
no hosted requests, gate changes, migrations or native journal writes are made.

`AttendanceRequestAuthority` must share the operation context's authorization
epochs, including invalidation on logout intent, account switching and same-user
relogin. Its asynchronous acquisition must settle its local work and return a
memory-only scope for the exact five-field binding and generation. The scope
pins a usable access token, independently trusted base project URI/publishable
key and a current-authorization observation. UUID/token presence and a decoded
JWT do not establish authorization or deployment provenance. C3.3 below adds an
opt-in lifecycle-backed issuer; production composition and ownership/fencing
remain gated.

The adapter checks authority currency before acquisition, then checks both
currency observations, all five binding fields, generation and exact trusted
endpoint after acquisition and immediately before HTTP submission. An invalid or
unavailable authority cannot fall back to another account/project. Credential
headers must be nonempty visible ASCII and are bounded to 8 KiB for the token and
4 KiB for the project key. Nothing persists or logs these credentials.

Each operation calls the injected client's `send` once, with redirects disabled
and maximum redirects zero. The caller must provide a non-retrying client that
honors these request settings, contains no hidden timeout/work wrapper and stays
open while requests are outstanding, without logging request/response data or
credentials. Installed `http` 1.6.0 provides streamed
send/response APIs and IO redirect control; no upgrade is needed. The installed
Supabase/PostgREST layer instead decodes response JSON and can retry GET/HEAD;
the existing repository also uses a non-cancelling 20-second Future timeout.
Neither path is reused here.

Initial POST bodies are the original frozen `parametersJson` encoded as UTF-8,
sent only to the derived `check_in_v2`/`check_out_v2` endpoint. Replay uses the
existing `rpcParameters(replayOnly: true)` map contract: only that operational
value changes; JSON whitespace/numeric spelling may be reserialized on the wire.
The stored original string, timestamps, evidence, key and final note intent/text
are untouched. No typed request, clock, location or note intent is regenerated.

Request and retained response bodies are bounded to 16 KiB each. The adapter
consumes response streams through termination, including error events, HTTP
errors and oversized bodies. It discards excess/error-body bytes rather than
buffering them or returning early. Content-Length does not substitute for the
actual byte bound; a mismatch on a successful bounded response is rejected.
The dependency owns incoming chunks; this bound does not control allocations
inside an injected client or total network traffic/time. A never-ending stream
keeps its future and C3.1 ownership outstanding. There is no internal timeout,
detached work, automatic retry, request cancellation or server-rollback claim.

Strict UTF-8 decoding retains the complete original successful response text,
including whitespace, escapes and timestamp representations. A leading UTF-8
BOM is rejected explicitly because Dart's decoder would silently strip it.
The adapter never rebuilds an acknowledgement from DTOs or a decoded map.
Only replay requests with a successful response containing the exact,
duplicate-free two-field object `{"contract_version":2,"status":"not_found"}`
produce `replayMiss`. Duplicate escaped keys, extra fields, noninteger versions,
HTTP 404/errors, truncated/non-object JSON and initial-write misses cannot do so.
Other successful UTF-8 bodies pass unchanged to C3.1's strict confirmation
validator; an `acknowledged` carrier alone does not confirm attendance.

After submission, dispatch deliberately finishes response processing even if
authorization invalidates. Only C3.1 can validate/persist that late receipt in its
original slot, under its existing receipt-only exception; no new request is
initiated for an invalidated epoch. Canonical reads additionally recheck
authorization after the full response and before returning a parsed session.

Canonical GET selects by session ID, company ID and employee profile ID, with no
active-session filter and a two-row limit to detect malformed multiplicity. The
selected owner fields and complete v2 display fields are validated before the
existing `WorkSession` parser is used. Active and closed rows are supported.
An empty/RLS-filtered result returns null; wrong-owner/malformed rows fail closed.
RLS still enforces active employee ownership or company-admin access on the
server; explicit employee authorization and owner filters remain necessary.
No service-role credential or RLS bypass is supplied. Null/error outcomes cannot
prove attendance failure, clear a session or alter a retained confirmation.

`AttendanceHttpFailure` exposes only these codes, never request URLs, credentials,
response bodies or underlying exception text:

| Code | Meaning |
| --- | --- |
| `contextInvalidated` | Authority/scope currency is false or cannot be observed. |
| `authorityUnavailable` | Scope acquisition failed. |
| `scopeMismatch` | Binding/generation/endpoint mismatch or invalid credential headers. |
| `invalidRequest` | Legacy protocol, invalid session ID or out-of-bound request. |
| `network` | Send or response-stream failure; server outcome remains unknown. |
| `http` | Non-2xx response, including redirects and authorization/backend errors. |
| `responseTooLarge` | Successful body exceeds the retained-byte limit. |
| `malformedResponse` | Invalid UTF-8/BOM/length or malformed canonical row. |

C3.1 remains unchanged: dispatch exceptions become `transportUncertain`, raw
invalid receipts become `malformedAcknowledgement`, exact misses remain unresolved,
and canonical null/errors retain confirmed receipts as `confirmedNeedsRefresh`.
Safe codes do not establish permanent account denial or justify session cleanup.
Actual host results are recorded in Development Status; native durability,
production auth, real RLS/runtime integration and deployment remain unvalidated.

## C3.3 combined auth owner and credential authority

`AttendanceAuthOwner` issues C3.1 contexts and implements C3.2 request authority
using the SAME application-lifetime generation source. It observes the existing
`AuthController` and its exact `SupabaseAuthRepository`; mismatched pairs and a
repository REST endpoint differing from trusted deployment configuration are
rejected. It is not instantiated in main, a screen or live attendance. No legacy
writer, coordinator/HTTP sequencing, migration, SQL or hosted setting changes.

The auth additions are read-only evidence: controller disposal/repository pairing;
repository operation number, current SDK session identity, public auth events and
an attendance-only successful-authorization attestation. That attestation joins
the exact returned AuthorizedUser, employee role, operation number and SDK session
object. It is withheld if the SDK session changes during the authorization lookup.
Existing login/restore/denial/logout results, query counts and UI decisions are
unchanged. New attendance authority is blocked rather than repairing ambiguous
auth state or granting access using matching user UUIDs.

Lifecycle hooks:

- The controller publishes `signingOut` synchronously BEFORE awaiting the
  repository. The owner invalidates immediately, including while SDK sign-out is
  still queued. `authenticating` similarly invalidates at login/switch initiation.
- Repository `_operation` changes synchronously at restore, login and logout
  entry. Guards reject old authority immediately even for repository-direct
  logout before the SDK removes its session or emits `signedOut`.
- Resume/revalidation `checkingSession`, blocked states and employee authorization
  loss invalidate old attempts. Later successful authorization creates a fresh
  epoch, never revives old ones; administrator-only authorization cannot issue.
  Server-side revocation is observed through existing authorization checks, not
  new polling/realtime monitoring; server authorization/RLS still applies between
  those checks.
- Exact SDK session-object comparison blocks unobserved replacements BEFORE the
  asynchronous public event arrives. Signed-in/out, initial-session, recovery and
  user-update events revoke the old epoch. No SDK internal synchronous stream or
  private session-version API is used.
- A `tokenRefreshed` event alone is insufficient: installed gotrue `setSession`
  can emit it for another login. Continuity also requires the approved login's
  nonempty UUID `session_id`, matching subject/user, unchanged authorization
  operation/user attestation and exact current event-session object. Only then
  may credentials advance within the same generation. Existing scopes retain
  their original token bytes. Supabase documents `session_id` as the unique user
  session identifier in [User Sessions](https://supabase.com/docs/guides/auth/sessions).

Claim decoding is bounded and supplies a continuity marker/expiry only; it does
NOT verify signatures, independently authorize an employee or establish project
identity. Authority also requires successful existing server profile/role queries.
Subsequent reads/RPCs remain subject to server JWT validation and RLS. No new
server session-revocation check or immediate server JWT invalidation is claimed.

`AttendanceTrustedDeployment` supplies the environment ID, base project URI and
publishable key independently of journals/current accounts/JWT issuer claims.
Bindings are derived from that configuration plus the approved auth user,
company and employee profile. URI/key validation and exact repository endpoint
matching fail with safe codes. There is no file/environment loader, persisted
credential, Session stringification, token logging or inference of legacy origin.

Acquisition checks the captured generation BEFORE calling SDK `getSession`,
allows submitted refresh work to settle, then checks generation and exact
resolved/current/observed session identity again. Stale refresh responses or SDK
fallback to another login cannot produce a scope. Missing/unusable expiry fails
closed. Scope currency checks the original generation and pinned token expiry;
refresh never rewrites an issued scope. No timeout detaches auth or HTTP work.

Each issued context counts as an outstanding attempt until idempotent `release`.
Release is not logout and leaves auth currency observable for stale-result guards.
Screen disposal/timeout must not call it on submitted work. Application `close`
revokes issuance and detaches listeners, but waits for normal context release;
it neither cancels requests nor force-releases ownership. Existing C3.1 can
therefore persist a valid late receipt in the original slot after logout/relogin
or owner shutdown, without stale refresh/publication. Unsubmitted contexts must
also be released by their issuer/caller. Never-ending work can keep shutdown
pending. Generations are unique across owner replacement within this Dart
isolate only; attempt counts are not native, process or restart fencing.

Deliberately blocked cases and remaining composition requirements:

- Missing/malformed login marker, wrong subject or ambiguous replacement during
  profile/role lookup: no attendance authority despite a possibly authenticated
  existing UI. A fresh successful validation must establish exact evidence.
- Late attachment after an already-unobserved refresh cannot reconstruct login
  continuity from UUIDs or the SDK's replayed last event. Attach before startup
  validation, or perform fresh authorization before issuing contexts.
- Pending refresh-event delivery temporarily blocks requests; observing proven
  same-login refresh does not create a new generation. Different/unknown login
  continuity revokes rather than silently adopting it.
  Superseded refresh events cannot establish or revoke current session evidence;
  exact-current guards keep an unobserved replacement blocked.
- Current application auth mutations use controller/repository entrypoints.
  Future SDK login/session-setter entrypoints must join the initiation boundary.
  Arbitrary direct SDK login calls have no application initiation callback; only
  actual session replacement can be observed. This is not universal interception
  of SDK calls or other engines/processes.
- A root application owner, trusted deployment/environment identity provisioning,
  HTTP-client lifetime, durable writer/source ownership/fencing, migration
  provenance, native recovery, reviewed backup policy, receipt consumption and
  approved backend deployment/cutover remain uncomposed. No live v2 activation.

`AttendanceAuthFailure` exposes only `configuration`, `contextInvalidated` or
`credentialsUnavailable`, without credentials, identifiers or underlying errors.
Real lifecycle behavior is host-tested using mocked Supabase auth/profile/role
HTTP and fictional records; Android, hosted auth/RLS and native durability were
not retested. Results are recorded in Development Status.

## C5.2 serialized confirmation consumption

`consumeConfirmed(context)` freezes the coordinator's complete confirmed proof
at invocation, joins the full-binding queue, applies current-generation and
journal/migration gates, compares the complete record and freshly reads the
acknowledged session through the scoped canonical port. No UI boolean/session
object authorizes cleanup. Guarded CAS writes confirmed -> empty at revision + 1;
full reread must match before `consumed` can be returned. Queued duplicates cannot
consume an intervening new command. No direct file deletion or reset is added.

Successful CAS/readback plus reread establishes per-instance exact-empty proof.
Before-write, after-commit, readback and post-CAS-read failures do not. The complete
original receipt remains in volatile failed-attempt evidence; storage may already
hold an empty tombstone. Both new submit and serialized `readActive` gate unproved
persisted empty state. Known disappearance fails closed. Initial, previously unseen
absence retains its existing meaning. Ownership lasts through normal release.

`recoverEmpty` is explicit and never writes: validate the full empty record,
invoke `JournalVerifier` with frozen raw bytes, then require exact reread after
the file/directory synchronization and authenticated-readback barrier. A local
unresolved attempt also requires its exact expected tombstone. Missing verifier,
keys, unreadable/ambiguous or changed records preserve the gate. Replacement/app
restart needs the same barrier. `emptyVerified` proves current state rather than
retrospective success of an earlier failed cleanup. The original receipt cannot
survive restart if an authorized compaction already replaced it; verified current
tombstone state is recovered instead.

Only a new captured-owner `readActive` supplies the next active/no-active selection,
with complete journal comparison before/after scoped SELECT. Receipt fields and
replay-only not_found cannot supply it. New positive outcomes mask publication
after invalidation. See [Employee Workflow](employee-attendance-workflow.md).

No durable writer lease, journal schema or cross-process queue is introduced.
Native CAS still relies on immutable-command and monotonic revision/key discipline
under its lock; Dart compares full records around it. Global production fencing,
writer retirement and provenance remain required. App-data/key/device loss and
arbitrary rollback are not solved. Host fault simulations do not prove Android
runtime behavior or power-loss durability.

## C3.4 durable confirmed-record recovery

The isolated coordinator now accepts an optional `JournalVerifier`. Existing
submit/replay/refresh paths retain their successful confirmation-CAS evidence
requirement. `recoverConfirmed(context)` is a separate explicit attempt for a
fully validated stored confirmed attendance-v2 record, including after restart,
coordinator replacement or a failed confirmation CAS which actually committed.
Missing verifier is `recoveryRequired`, never verification success.

Recovery captures the original generation/full binding, reads and freezes the
complete original record bytes, gates invalid/legacy/blocked/pending-migration
records, and invokes the verifier. It checks authorization before/after awaits
and rereads exact bytes after verification. Failed barriers or changed/missing
records return unresolved with no snapshot or canonical lookup. Byte equality
covers revision, phase, command key/request text, full receipt text and migration
metadata, not just semantic IDs. The verifier validates both input and readback;
the native operation independently authenticates and compares complete bytes.

Only a successful barrier populates per-instance exact-record refresh evidence.
The existing refresh path rereads the complete record again and performs only
the scoped canonical read of the original receipt's session ID. Failure/absence
of canonical state returns `confirmedNeedsRefresh` without altering the receipt;
later explicit refresh may retry. Neither this evidence nor canonical absence
authorizes an attendance resend, new key, cleanup or compaction. Another instance
requires its own fresh barrier. Prepared/may-have-sent/uncertain behavior, late
receipt-only finalization, one-attempt contexts and queue/release timing remain
unchanged. This queue is still only within one Dart isolate.

`AndroidJournalVerifier` calls `verifyRecordV1` with bounded, validated frozen
bytes and requires exact authenticated readback from the native barrier. There
is no default composition, timer, network call, legacy import, live-controller
change, provenance approval or writer fencing. Migration-specific barriers and
the isolated cleanup namespace restriction remain separate and unchanged.
See Android Journal Storage and Development Status for actual validation and
remaining platform/power-loss limitations.

## Native C2b implementation and activation boundary

C2b implements Android Keystore AES-GCM and AtomicFile under
`noBackupFilesDir`, fresh nonces/authenticated context, bounded encrypted
containers, shared locking, descriptor/directory synchronization and independent
readback. Missing/invalidated keys and authentication failures preserve
ciphertext and block; there is no automatic reset or delete-all API. These are
implemented safeguards; see Android Journal Storage for actual runtime coverage
and the remaining durability/platform validation limits.

C2b.1 adds limited recovery without changing format 2 or its state machine.
Main plus exactly one .new/.bak may normalize only after both authenticated
plaintexts pass complete Dart validation and are byte-identical. A native content
snapshot is rechecked under the same process/OS locks; both copies are
reauthenticated and compared with the exact validated bytes before mutation.
Main file/name synchronization precedes checked duplicate deletion; directory
sync and full readback follow it. Original key/payload, phase, receipt and revision
are preserved, including blocked records. No attendance is confirmed by recovery.
Different records, sidecar-only states, three artifacts and invalid/unverifiable
candidates remain preserved and blocked. There is no highest-revision selection,
automatic promotion, plaintext fallback or ambiguous-command deletion.

C2b.1 continuation validation passed all 583 serial Flutter tests and analysis;
the isolated app/test APKs built offline. On Android 17/API 37 x86_64 with 16 KiB
pages, fresh 15/15 and restart 4/4 checks passed. Restart compares the complete
expected original record, including binding, idempotency key, frozen command,
phase and revision, after force-stopping only the isolated app without clearing
its data/key. A fixture-only canonical-parent check was fixed; production journal
policy was preserved. Native cleanup/sync failure injection, older AtomicFile
writers, multi-process and mid-write-kill tests, reboot/power loss, permanent key
invalidation, OEM/physical-device and backup/transfer validation remain pending.
These focused results do not establish power-loss durability or production readiness.

Backup/device-transfer exclusions must cover new storage and legacy originals.
Keys remain independent of logout/session tokens; unresolved records survive
logout and account switching. No guarantee is possible after app-data deletion,
reinstall, key loss, arbitrary rollback or physical storage loss. Retention,
capacity without eviction, authorized blocked-state resolution and operational
recovery need explicit policies before real employee use.

The future C3 coordinator must own authorization generations, dispatch/replay,
receipt capture, canonical SELECT refresh and cleanup conditions outside screen
lifecycle. The current legacy repository returns WorkSession rather than the
complete acknowledgement; receipt-preserving integration remains C3 work.
Standalone note saves must remain outside the attendance outbox.

C2a does not activate storage, migrate actual files, dispatch v2 RPCs, acquire
location, modify authentication, or approve hosted deployment/cutover. Native
encryption, atomicity, process-death and backup checks need actual Android evidence;
host simulations are not evidence that those checks passed. C2b.1 authorizes a
separate fictional runtime harness; this does not activate the live controller
or authorize C2c migration, production use or hosted cutover.

See [Android Journal Storage](android-journal-storage.md) for the implemented C2b
channel, binary container, encryption/AAD, locks, failure codes and conservative
interruption policy. The API-36 native compile check does not replace Android tests.

## C2a Host Validation

`flutter analyze --no-pub` passed without issues. The full
`flutter test --no-pub --concurrency=1` suite passed 469 tests, with zero failures
or skips: 227 existing tests and 242 new tests (codec 101, transitions/storage 86,
confirmation 30, legacy preparation 25). The first focused core run passed 205;
additional coverage was included in the final full run. The initial analysis
reported brace-style findings, which were corrected before the final clean run.
`git diff --check` and whitespace checks of all newly added files passed.

No dependencies were installed. Android, Docker, hosted Supabase and actual
legacy journal files were not used for this validation.
