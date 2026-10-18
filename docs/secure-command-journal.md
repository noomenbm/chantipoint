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
does not prove the failed synchronization succeeded. A native durability barrier,
lost-response handling and restart coordination are still required. Planner
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
