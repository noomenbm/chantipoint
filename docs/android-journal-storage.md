# Android Encrypted Journal Storage — C2b / C2b.1 / C2c.2

C2b implements the Android backend for the [format-2 journal](secure-command-journal.md).

C5.2 reuses the existing phase-agnostic `verifyRecordV1` barrier to prove an exact
empty tombstone after uncertain compaction or coordinator/app replacement. This
adds no native API/storage/schema change. Full-byte comparison, existing locks,
file/directory sync and authenticated readback are required; a plain empty read
is insufficient. C5.2 validation is host-only: the new empty-recovery composition
was not instrumented on Android and makes no power-loss durability claim.
The Dart schema/state machine and live version-1 attendance flow are unchanged.
MainActivity registers the channel; registration alone opens no journal files and
creates no key. Actual legacy migration and coordinated activation remain pending.

## Exact platform boundary

`AndroidJournalStorage` implements `JournalStorage`. Dart validates the complete
replacement before sending and the complete returned record before exposing it.
Native code checks routing/CAS metadata, not attendance policy or full receipt
semantics. Exact native readback-byte comparison links verification to the
already validated Dart replacement.

Channel: `chantipoint/secure_command_journal`, StandardMethodCodec. All arguments
listed below are required, including NULL. Unexpected fields fail explicitly.

| Method | Arguments | Success |
| --- | --- | --- |
| `read` | `api_version: 1`, `binding: <five format-2 identity fields>` | `{status: absent}` or `{status: stored, record: Uint8List}` |
| `compareAndSwap` | `api_version: 1`, `binding`, `expected_revision: int`, `expected_key: String or NULL`, `replacement: Uint8List` | `{status: written, revision: int}` |
| `inspectRecoveryV1` | `api_version: 1`, `binding` | `{recovery_version: 1, snapshot: <SHA-256 hex>, candidates: [{kind: main/new/bak, record: Uint8List}]}` |
| `normalizeRecoveryV1` | `api_version: 1`, `binding`, `snapshot`, `validated_record: Uint8List` | `{status: stored, record: Uint8List}` |
| `inspectLegacySourceV1` | `api_version: 1`, `binding` | `{inspection_version: 1, binding, snapshot, basename, source: Uint8List or NULL, artifacts: [{suffix, bytes: Uint8List}]}` |
| `verifyMigrationTargetV1` | `api_version: 1`, `binding`, `expected_record: Uint8List` | `{status: target_verified, record: Uint8List}` |
| `cleanupLegacySourceV1` | `api_version: 1`, `binding`, `expected_record`, `source_snapshot` | `{status: source_absent, record: Uint8List}`; plaintext cleanup is validation-package-only. |
| `requireMigrationValidationV1` | `api_version: 1` only | `{status: validation_namespace}`; real native package check, no filesystem/key access. |
| `verifyCompletedMigrationV1` | `api_version: 1`, `binding`, `expected_record` | `{status: target_verified, record: Uint8List}`; completed metadata, verification only, validation namespace only. |

When sidecars exist, `read` returns `{status: recovery_required}`. The adapter
performs one inspection, complete Dart validation and, only if permitted, one
normalization. It does not loop on conflicts or errors. Direct CAS still blocks
on sidecars; it never performs recovery implicitly. A concurrent reader that has
already normalized may leave a valid main-only inspection, which needs no cleanup.

There is no arbitrary path, key export, general encryption, reset, delete-all,
coordinator or network method. Channel bytes are plaintext inside the application
process; native files contain encrypted containers only. Unsupported platforms,
missing plugins, malformed responses and unknown native errors fail explicitly.
No preferences or plaintext file fallback exists.

## C2c.2 isolated migration primitives

`AndroidLegacyMigration.inspect`, `verifyTarget` and `cleanup` are opt-in mechanical
operations. They do not issue approvals, run the migration planner/coordinator,
change journal state, mark cleanup complete or activate startup integration.
The live legacy writer/controller and backup configuration remain unchanged.

Source inspection derives `attendance_<base64url(company:profile), no padding>.json`
from the binding under canonical Android `filesDir`. Callers supply no path,
basename or directory. Only that exact filename and names beginning with its full
name plus `.` are associated: `.tmp` is temporary; other dotted suffixes are
unexpected artifacts. Unrelated app files are ignored. Up to eight sidecars and
64 KiB of aggregate source/artifact bytes are accepted. Inspection does not touch
Keystore, create a journal/key, repair artifacts, rename or delete anything.

Native code rejects links, non-regular files, hard-linked source/artifact files,
canonical escapes, unreadable directories/files and unstable observations. It
uses lstat, no-follow opens and descriptor/path identity checks; bounded reads
and a repeated associated-name scan avoid treating an IO failure as absence.
The snapshot token is SHA-256 over domain/package/full-binding-slot/basename
framing, source presence/length/exact bytes and sorted artifact suffix/length/exact
bytes. It is a content identity, not provenance or proof of writer quiescence.
Native hashing uses JDK MessageDigest; Dart source snapshots use existing crypto.

Every successful `Os.open` has an explicit `Os.close` in `finally`, including
stream-construction, descriptor-check, bounded-read and post-read failures.
Android's [`FileInputStream(FileDescriptor)` contract](https://developer.android.com/reference/java/io/FileInputStream#FileInputStream(java.io.FileDescriptor))
leaves ownership with the caller; closing the borrowed stream is insufficient.
A close-only failure returns the safe typed `journal_unreadable` error. If an
earlier operation failed, its failure is retained and only a data-free typed
close failure is suppressed onto it. Protected opens and snapshot checks remain
unchanged; neither garbage collection nor a pathname stream owns these descriptors.

The Dart adapter strictly validates wire shapes, full returned binding, derived
basename and artifact bounds/order; it copies source bytes into the immutable
C2c.1 snapshot and reuses strict legacy parsing. Malformed content or a mismatched
owner raises a typed error while native evidence stays untouched. A returned
snapshot with artifact observations cannot be passed to adapter cleanup.

For target operations, Dart fully validates the expected record before invoking
native code. Only pending legacy migration records in `uncertain` or `confirmed`
are eligible. Under the existing process mutex and OS journal lock, native code
reopens/authenticates actual ciphertext, requires exact complete expected plaintext,
checks pending metadata/derived basename/owner and legacy command shape, syncs the
main descriptor and directories, then reopens/authenticates and compares all bytes
again. Revision, command, key, timestamp strings, phase, receipt and migration
identity remain unchanged. This fresh barrier is required even after a successful
read following an earlier reported write failure. No encryption key is created.

Target sidecars return `recovery_required`. The adapter delegates to existing
C2b.1 fully validated recovery and retries the native operation once, only if the
entire recovered record matches the expected bytes. A second race or ambiguous
history blocks. No new AtomicFile recovery/promotion/revision-selection policy is
introduced.

**Plaintext cleanup is rejected natively unless the actual Context package is
exactly `com.example.chantipoint.journalvalidation`.** The normal app is rejected
before locks, directory creation, key access or source inspection. The source
cleanup helper checks the namespace as well. There is no Dart boolean or request
field that bypasses this gate. The test-only normal-namespace check uses a native
Context wrapper; the normal application is not installed or launched by this test.

Within the shared locks, cleanup repeats the target barrier, reinspects the source
and artifacts, requires its exact snapshot token and no sidecars, and compares the
actual SHA-256, owner, version, operation and complete payload with the target's
pending migration identity/command. A caller digest is not deletion authority.
Only the derived finalized source is unlinked with its Boolean result checked.
The source directory and app-data parent are synchronized, and absence of source
and associated artifacts is checked again. An already absent source still requires
the fresh target barrier, matching absence snapshot, directory sync and recheck.

Success means only mechanically verified durable absence under these operations;
the record still has cleanup pending. A future coordinator must use the existing
cleanup-completion CAS. A failed reply/sync can occur after unlink. Reinspect on
retry and repeat target durability and durable absence checks; never assume
rollback, recreate plaintext, reset a command or manufacture confirmation.

The unchanged legacy Dart writer does not honor these native locks. Namespace
gating confines destructive execution to fictional tests; it does not solve
production writer fencing. Trusted origin approval, full authorization generation,
global one-source/one-destination enforcement, writer retirement, restart
coordination, backup exclusions and activation remain integration requirements.

The instrumentation source set alone owns fault-control state. An ordinary native
IO seam defaults to real synchronization/deletion and has no channel controls.
The runner injects a target-barrier failure before deletion, a false deletion
result, and a failure after unlink before source-directory sync. These are
deterministic injected failures, not kernel faults or power interruption. Restart
fixtures deliberately stage source-present and already-deleted boundaries before
force-stop; they are not actual termination during an operation. Original runtime
tests remain, with fictional key loss last.

Descriptor regressions use test-only `/proc/self/fd` inspection filtered to the
exact fictional source and its dotted sidecars, including kernel ` (deleted)`
targets. Counts are checked after each operation, rather than comparing totals
for the Flutter/VM process. Positive controls prove that the counter observes a
descriptor after closing a borrowed stream, for a source, a sidecar and an
unlinked sidecar, and that explicit close releases it. Repeated checks cover
finalized reads, source-plus-sidecar reads, oversized source/artifact rejection
after open, all three cleanup-failure/retry boundaries, and already-absent cleanup
before and after force-stop. Complete encrypted records must remain unchanged.
These controls exist only in the isolated instrumentation source set and its
runtime probe; results expose counts/static assertions, not paths or file bytes.

C2c.2 descriptor-review validation passed analysis and all 739 serial host tests.
Both isolated APKs rebuilt offline in 2 minutes 32 seconds; actual Android 17/API
37 x86_64 with 16 KiB pages passed fresh **36/36** and restart **6/6**, zero
failures, both `INSTRUMENTATION_CODE: -1`. This adds four descriptor-regression
checks to the initial 32 fresh checks and extends both migration restart checks.
The three native injections and both staged migration restart boundaries passed
with fixture-descriptor and complete-record comparisons. The normal
namespace guard was exercised via a native Context wrapper. Only the isolated app
was force-stopped; no data/key clearing or reinstall occurred between phases.
The final original key-loss check remains last. The emulator was stopped after
validation. Native descriptor-close failures were not injected. The first
emulator startup was stopped at the C: disk threshold; validation ran only after
resource recovery. See Development Status for measurements and remaining limits;
these results do not establish power-loss durability.

## C2c.3 coordinator extensions

The isolated Dart coordinator uses native preflight before any import/read that
could normalize artifacts. It cannot enable production execution with a flag.
`verifyCompletedMigrationV1` separately checks completed metadata, binding and
the exact fully Dart-validated record under existing locks, authenticates actual
ciphertext, synchronizes the file/directories, then authenticates and compares
the full record again. It creates no key, changes no state, deletes no source,
and uses only existing C2b.1 duplicate recovery if needed. Pending-source cleanup
continues to reject completed records. A readable completed record after a failed
CAS never establishes a fresh successful durability claim without this barrier.

`AndroidLegacyMigrationBackend` scopes the existing adapters through a channel
that checks the external operation context around every async call, including
error/recovery paths. There is no live application wiring or production context
provider. See [Secure Command Journal](secure-command-journal.md#c2c3-isolated-migration-coordinator)
for interfaces, outcomes, exact restart sequence, external lease lifetime and
global writer/source-binding obligations. Runtime fixture controls remain solely
in the isolated harness; the added `completed_sync` checkpoint is an injected
pre-barrier error, not a kernel or power-loss test.

## C3.1 historical host-only boundary

The isolated attendance operation core depends on `JournalStorage` but supplies
no Android composition or new channel/native method. Existing migration-only
barriers cannot establish durability for arbitrary C3 prepared/transmission/
confirmation records. C3.1 treats failed CAS as unresolved, even when matching
bytes are readable, and uses only volatile per-instance successful-confirmation
evidence for refresh retries. A later native recovery integration is still needed.
See [Secure Command Journal](secure-command-journal.md#c31-isolated-attendance-operation-core)
for exact context, receipt-only finalization and serialization limits. C3.1 host
simulations do not extend the Android/runtime validation results above. No APK
build, emulator/native test, actual journal write or power-loss test was run for
this slice; the live legacy controller and storage remain unchanged. C3.4 below
adds a separate generic verification barrier and isolated runtime composition.

## C3.4 general exact-record verification

`verifyRecordV1` accepts exactly `api_version: 1`, the five-field `binding`, and
`expected_record: Uint8List` (at most 64 KiB). Its only successful response is
`{status: record_verified, record: Uint8List}`. Dart validates the complete schema
before the call and after readback, then compares all original bytes. Native
validates bounded envelope/binding metadata, authenticates the stored container,
and compares the complete expected plaintext before and after the fresh barrier.

The existing process monitor and OS file lock enclose authentication, exact
comparison, file descriptor synchronization, directory synchronization and a
fresh authenticated readback. No AtomicFile recovery, sidecar normalization,
deletion, phase transition, import or network call occurs. Even a byte-identical
sidecar is rejected by this operation and retained; it does not select a revision.
Missing records/keys, wrong binding, corrupt/authentication failures and changed
records fail safely. Stable issue codes cross the channel; no private native
exception details or record content are logged. Full request/receipt semantics
remain Dart's authority, as in the existing native contract.

This API is distinct from `verifyMigrationTargetV1` and
`verifyCompletedMigrationV1`. It neither weakens their namespace guard nor grants
legacy deletion permission. The optional coordinator verifier permits only
explicit confirmed-v2 canonical refresh; it is never composed into live app
attendance. Successful-CAS and late receipt behavior remain unchanged.

The isolated Android harness injects failures at file-sync, directory-sync and
readback boundaries and corrupts a target before authenticated readback. Controls
and mutable fault state exist only in androidTest. These injections prove
fail-closed control flow, not a real kernel fsync error or arbitrary power loss.
Actual API/runtime counts are recorded in Development Status. Older AtomicFile
implementations, permanent key invalidation, multi-process hostile mutation,
mid-instruction process kill, reboot/power loss, OEM hardware and backup/transfer
remain outside this validation. A fresh barrier cannot recover lost keys or data.

The first C3.4 runtime retry reported 54 passes and one altered-readback fixture
failure. The fixture attempted `AtomicReference.compareAndSet` using a string
literal, while the channel supplied a distinct string object; reference identity
prevented the tamper action from firing. The androidTest-only control now checks
the value and consumes the exact observed reference. The Dart runtime assertion
also requires the encrypted-artifact fingerprint to change during tampering,
then requires authentication failure and preservation of the altered evidence.
Production verification behavior and assertions were not weakened. Final rerun
on API 37 x86_64, 16 KiB pages passed **fresh 55/55 and restart 11/11**, both
`INSTRUMENTATION_CODE: -1`. Only the isolated app was force-stopped between
phases, retaining its data/key; the emulator was stopped afterward. Host tests,
builds and runtime phases were sequential. These are actual runtime results,
separate from the 1064 passing host tests and successful offline APK builds.
See Development Status for resource measurements and validation history.

## Slots, keys and AAD

Files live under `context.noBackupFilesDir/attendance_journal/` and are named
`slot_<64 lowercase SHA-256 hex characters>.bin`. Identifiers never appear in
filenames. Initial capacity is 32 bindings, each retaining one command/tombstone
slot; exhaustion fails without eviction.

Canonical binding bytes contain these strings, in this exact order, each
preceded by its UTF-8 byte length as a positive 32-bit big-endian integer:

1. `chantipoint-binding-v1`
2. environment ID
3. exact Supabase base URL
4. Auth user ID
5. company ID
6. employee profile ID

The slot ID is standard SHA-256 of those bytes. Framing is independent of
Dart/Java JSON escaping and preserves exact Unicode. Native routing does not
normalize URLs or infer origin; Dart owns URL/protocol rules. Dart's in-memory
`storageIdentity` JSON string is not the native hash input.

The installation-scoped Android Keystore AES-256 key has alias
`<application package>.attendance_journal.aes.v1`, encrypt/decrypt purposes,
GCM/no padding, randomized-encryption enforcement and no biometric requirement.
No StrongBox/hardware backing is assumed. Keys are never exported or derived
from passwords. No new cryptography dependency is used.

Each write creates a new `AES/GCM/NoPadding` cipher initialized with native
`SecureRandom`. Keystore generates the fresh IV with its own random entropy; a
provider may ignore the supplied JCA random instance. Code checks
the 96-bit nonce and 128-bit tag; Dart cannot supply either. Caller-supplied IVs
would require disabling randomized-encryption enforcement, so that path is not
used. Decryption uses the stored nonce and `GCMParameterSpec(128, nonce)`.

AAD uses the same length-prefixed UTF-8 framing for these strings:

1. `chantipoint-journal-aad-v1`
2. actual application package name
3. derived slot ID

Container version and key version then follow as two big-endian 32-bit integers,
both currently 1. Encryption/decryption construct identical AAD.

## Binary container version 1

| Offset | Bytes | Content |
| --- | --- | --- |
| 0 | 4 | ASCII `CPJR` |
| 4 | 4 | Container version 1, big-endian |
| 8 | 4 | Key version 1, big-endian |
| 12 | 4 | Ciphertext-plus-tag length, big-endian |
| 16 | 12 | Nonce |
| 28 | variable | Ciphertext followed by the 16-byte authentication tag |

Plaintext remains limited to 65,536 bytes. Ciphertext/tag is at most 65,552 bytes;
the complete container is at most 65,580 bytes. Reads are bounded. Magic, versions,
minimum/declared/exact total lengths are checked. Unknown versions do not select
a fallback cipher/key or trigger reset. Frozen request and receipt JSON strings
remain byte-for-byte unchanged in the encrypted plaintext.

## Worker, locks and persistence

One process-scoped worker uses one thread and a bounded queue of 32 pending tasks.
Filesystem, parsing and cryptographic work run off the UI thread; results return
on the main thread. Engine detachment stops result publication but queued writes
may finish. A lost reply therefore remains uncertain; detachment deletes nothing.

Every read/CAS uses a process mutex plus an exclusive OS file lock on
`journal.lock`. Backend instances, engines and cooperating processes share this
lock strategy. CAS retains the locks throughout current-record decryption,
revision/key comparison, encryption, atomic replacement and readback.

A write succeeds only after:

1. Checking exact binding, expected revision/key, and replacement revision = old + 1.
2. Protecting the current immutable command and retained confirmation. Command
   removal requires confirmed -> empty; blocked recovery cannot be overwritten.
   Full transition policy and cleanup attestations remain in Dart.
3. Encrypting and writing through AtomicFile.
4. Flushing and explicitly synchronizing the output descriptor.
5. Finishing replacement and synchronizing directory metadata.
6. Reopening, authenticating/decrypting, validating binding/revision and comparing
   every plaintext byte with the requested replacement.

CAS is one native operation, not a Dart read plus unconditional native write.
C2a's storage interface/schema needed no redesign; added issue codes preserve
native failure distinctions.

Installed Android sources show that AtomicFile may log sync/rename failures
without throwing. `finishWrite` alone is insufficient. Directory sync uses public
`Os.open(O_RDONLY)`, `Os.fstat`/`S_ISDIR`, `Os.fsync` and `Os.close`; `O_DIRECTORY`
is not public in the API-36 SDK. App-data/no-backup parent metadata is also
synchronized, including after failed initialization. Unsupported/failed sync
returns `journal_sync_failure`, never a weaker-success fallback.

## C2b.1 approved limited recovery

Inspection uses bounded FileInputStream reads, never AtomicFile.openRead,
startWrite or another mutating AtomicFile recovery method. Under the existing
process/OS locks, native code authenticates every candidate using the existing
key and expected AAD, and validates routing metadata. Invalid candidates fail
without deleting anything. Only fixed main/new/bak identifiers cross the channel.

| Artifacts | Decision |
| --- | --- |
| Valid main only | Read normally. |
| Main + .new, or main + .bak | Normalize only if BOTH complete records pass JournalCodec and have byte-identical plaintext. |
| Different bytes, revisions, phases, commands, payloads or receipts | Preserve every artifact and block. |
| Only .new or only .bak | Preserve and block; no promotion. |
| All three artifacts | Preserve and block, including identical triples; outside the approved pair-only procedure. |
| Invalid/truncated ciphertext, tag failure, absent/invalidated key, unsupported container/schema or incomplete validation | Preserve and block. No fallback/reset. |

Dart owns policy and validates the complete schema, binding, frozen request,
phase/flag relationships and receipt before requesting normalization. Header
equality alone is insufficient. Ciphertexts may differ because their nonces differ;
the decrypted bytes must be identical, including original request/receipt strings.
No revision or filesystem timestamp is used to choose a winner. A blocked journal
record remains blocked after removing an identical duplicate.

The snapshot hashes framed package/slot context and, in fixed main/new/bak order,
each artifact's presence, length and complete encrypted bytes. It is a content
snapshot, not proof of freshness or commit. Native normalization reacquires both
locks, rereads/reauthenticates all candidates, checks the snapshot and pair-only
shape, and compares both plaintexts against the exact Dart-validated bytes.
Stale/changed snapshots block; the adapter never retries automatically.

Before deletion, native code synchronizes the retained main file and journal
directory. It then checks deletion of the sole redundant sidecar, synchronizes
the directory again, reopens/authenticates main and compares every plaintext byte.
This keeps main durable before cleanup: interruption can leave the identical pair
or main alone, with the same command, phase, receipt and revision. A reported
cleanup/sync error is never treated as success, even if the duplicate is gone.
Directory synchronization failure remains an explicit failure on unsupported
filesystems. Recovery neither confirms attendance nor compacts a command.

Writes now use unconditional scoped stream closure, including after finishWrite
swallows a close error. Failed writes still do not call failWrite or delete to
erase evidence. Keystore initialization, CAS and encryption/AAD are unchanged.

A reported failure may follow a committed replacement. Reread before deciding
the next action; do not infer rollback or generate another key. OS synchronization
cannot guarantee survival of defective hardware or arbitrary device rollback.

## Failures and key loss

PlatformException messages are constant `Journal storage unavailable.` with NULL
details. Component logs contain no payloads, locations, notes or tokens; code
does not log raw exceptions. Wrapped key/tag exception types are classified
without examining their messages.

| Native code | Dart issue |
| --- | --- |
| `journal_corrupt` | `corrupt` |
| `journal_unreadable` | `unreadable` |
| `journal_missing_key` | `missingKey` |
| `journal_invalidated_key` | `invalidatedKey` |
| `journal_authentication_failed` | `authenticationFailed` |
| `journal_unsupported_container` | `unsupportedContainer` |
| `journal_unsupported_format` | `unsupportedFormat` |
| `journal_identity_mismatch` | `identityMismatch` |
| `journal_revision_conflict` | `revisionConflict` |
| `journal_command_conflict` | `commandConflict` |
| `journal_illegal_transition` | `illegalTransition` |
| `journal_storage_failure` | `storageFailure` |
| `journal_sync_failure` | `synchronizationFailure` |
| `journal_native_failure` | `nativeFailure` |
| `journal_unsupported_platform` | `unsupportedPlatform` |

Queue rejection/unexpected native failures block explicitly. Capacity exhaustion
is a storage failure. Only a correctly shaped native `absent` response means no
slot; corruption, invalidated keys and authentication failures never mean absence.

Key creation requires the same locks, no existing alias, and inspection finding
no journal base/new/backup artifacts. An existing key is reused even before its
first record. Any ciphertext without the key blocks regeneration, including
another owner's remaining ciphertext. Unknown directory entries block inspection.
Decryption failures delete neither files nor aliases.

Keys remain independent of logout/tokens. Device-local recovery is not guaranteed
after key loss, reinstall, app-data deletion, storage destruction or arbitrary
deletion/rollback. App-process compromise can still use app-authorized keys.

## Backup, validation and remaining work

Android's normal backup framework excludes `noBackupFilesDir`. Manifest/backup
configuration is unchanged to preserve the current legacy path. Legacy files in
`filesDir` and existing auth preferences are not made backup-safe by this new
directory; C2c/C3 need reviewed legacy backup/device-transfer exclusions.

Host MethodChannel tests cover exact mapping, typed errors, immutable snapshots,
protocol-level CAS races, record preservation and absence of reset/fallback.
They do not execute native Keystore, crypto, AtomicFile or OS locks.

A direct cached compile uses API-36 Android stubs, cached Flutter embedding,
Kotlin 2.4.0, JVM target 17 and a 256 MiB compiler heap. No Gradle, SDK download or
Android build is involved. Its first run found the unavailable `O_DIRECTORY`
symbol; public descriptor validation replaced it. Compilation passed afterward.
Compiler/JDK deprecation warnings concern compiler tooling, not app runtime tests.

C2b local validation: `flutter analyze --no-pub` passed without issues.
`flutter test --no-pub --concurrency=1` passed 538 tests (469 existing plus 69 new),
with zero failures or skips. The focused channel run passed all 69 tests. The
direct compile passed all three native journal files and MainActivity; its initial
API-symbol failure was corrected without changing Gradle settings. Initial Dart
analysis style findings were also corrected. `git diff --check` and added-file
whitespace checks passed. C: remained above 5 GiB (9.66 GiB before, 9.85 GiB after).

### Isolated Android runtime harness

`test/device/journal_runtime_probe.dart` is a non-UI Dart entrypoint driven by
framework `JournalRuntimeInstrumentation` under androidTest. No AndroidX Test or
JUnit dependency is required. Gradle property `journalValidation=true` selects
application ID `com.example.chantipoint.journalvalidation` and the custom runner.
The runner refuses another application ID. Its fixture channel exists only in
the test APK; production JournalChannel has no fixture/reset/key-deletion API.
Fresh runs clear only this isolated fictional fixture directory/key. Restart runs
retain them. No Supabase initialization, attendance RPC, GPS or live controller
is executed. The normal application target and application ID are unchanged.

Focused debug/test APKs use the existing SDK and Gradle, one worker, no parallel
builds, a 1 GiB JVM heap, 512 MiB metaspace, 128 MiB code cache and in-process Kotlin.
Use the existing emulator with command-line RAM/core limits, no saved snapshots
or data wipe. Verify effective RAM: this image raises a requested 1.5 GiB to
4 GiB. Keep host testing, builds and emulator execution sequential to limit RAM usage.
For the C3.4 runtime retry, the developer revised the C: stop threshold to
3 GiB (previously 5 GiB). Monitor free space throughout startup, installation and
both phases; never clean unrelated caches or data.

The fresh/restart phases exercise real MethodChannel messages, Keystore, independently
encrypted identical copies, ambiguous/orphan artifacts, actual unfinished
AtomicFile writes, corruption/AAD failures, ciphertext snapshot conflicts, CAS
and preserved blocked records. Host simulations remain separate evidence.
Sudden power loss, reboot, OEM behavior, older backup-writing Android releases,
multi-process contention, permanent key invalidation and backup/device transfer
require further validation. A staged unfinished write/process restart does not
prove sudden-power-loss durability or device-loss recovery.

### C2b.1 completed host and focused Android validation

The continuation preserved all existing uncommitted changes and the approved
pair-only recovery policy. `flutter analyze --no-pub` passed with no issues.
The complete `flutter test --no-pub --concurrency=1` suite passed **583 tests**,
zero failures/skips: the 538-test C2b baseline plus 45 recovery tests. This
supersedes the previous incomplete 570-test run stopped below the disk gate.
The earlier 256 MiB direct Kotlin compile remains historical compile evidence;
the successful Android Gradle build now also compiles MainActivity and the runner.

Both isolated debug APKs built successfully **offline**, reusing API 36,
Gradle 9.3.1, AGP 9.1.0, Kotlin 2.4.0 and the installed JBR. No dependency/SDK
download, cache cleanup or pagefile change was needed. Existing Gradle/Kotlin
deprecation warnings did not fail the build. App/test manifest inspection verified
`com.example.chantipoint.journalvalidation` and its `.test` package/target before
installation; the normal ChantiPoint app was not installed or launched.

Runtime used the existing Pixel_9 API-37.2 x86_64 image with WHPX. Android reported
**Android 17 / API 37 / 16,384-byte pages**. Execution was headless with two cores,
software graphics, no snapshots, no boot animation and no data wipe. The emulator
overrode the requested 1,536 MiB RAM to **4,096 MiB**; this is not a verified
1.5 GiB guest run. An initial startup attempt was killed by Android's low-memory
killer before journal results; the settled run exposed a fixture-only path check.
The helper now canonicalizes Android's app-data parent, matching production,
while retaining the slot-directory symlink check. Static stage/source diagnostics
contain no raw exception messages or journal data. Production recovery code and
the approved policy needed no changes in this continuation.

| Android phase | Actual result |
| --- | --- |
| Fresh | **15 passed, 0 failed**, INSTRUMENTATION_CODE -1. |
| Restart | **4 passed, 0 failed**, INSTRUMENTATION_CODE -1. |

Fresh checks exercised Keystore encryption/decryption, exact main reads,
independently encrypted identical .new/.bak normalization, blocked orphans and
different records, full Dart validation before cleanup, tag/AAD failures,
actual unfinished AtomicFile writes with truncated containers, stale ciphertext
snapshots, native CAS conflicts, and retained blocked-state receipts.

Only the isolated validation app was explicitly force-stopped between phases.
No data/key clearing or reinstallation occurred between them. Restart assertions
compare every stored byte against the expected original record, including the
complete binding, original idempotency key, protocol/operation/full frozen command,
phase, revision, flags and nullable receipt/block/migration fields. Both main-only
restoration and duplicate recovery use this check. The incomplete write stayed
blocked with identical artifacts. The final restart check deliberately deleted
only the fictional fixture key, verified missing-key blocking without regeneration
or ciphertext deletion, and left the encrypted fixture artifacts retained.
Runtime commands were fictional legacy-V1 factory intents in format-2 records;
no attendance RPC or live-controller workflow was exercised.

The emulator was stopped after testing. All measured C: values during this
continuation remained above 5 GiB; initial free space was 13.37 GiB on C: and
23.68 GiB on E:. The initial running emulator left almost no available RAM;
stopping it provided 3.21 GiB before host validation. Resource checks were repeated
throughout the sequential run. The prior below-5-GiB resource stop was not repeated.
After emulator shutdown, final measured free space was **11.63 GiB C: / 23.68 GiB
E:**, with **2.99 GiB available RAM**. No emulator, Gradle JVM or Docker process
remained in the final process check.

**Still untested:** actual native cleanup/delete and synchronization failure
injection (before/after duplicate deletion), older Android backup-writing AtomicFile
implementations, multi-process contention, killing a process during a write,
OS reboot, sudden power interruption, permanent Keystore invalidation, physical
devices/OEM filesystems, and backup/device transfer. Host failure simulations
are not native fault-injection results. A .bak fixture on API 37 does not validate
older startWrite/finishWrite behavior. These results establish the listed modern
emulator cases, not power-loss durability, device-loss recovery or production readiness.

The focused offline build from `android/` is:

```powershell
.\gradlew.bat :app:assembleDebug :app:assembleDebugAndroidTest --offline --no-daemon --max-workers=1 '-PjournalValidation=true' '-Ptarget=test/device/journal_runtime_probe.dart' '-Ptarget-platform=android-x64'
```

Build before starting the emulator. Install only the resulting isolated app/test
APKs, run `com.example.chantipoint.journalvalidation.test/com.example.chantipoint.journal.JournalRuntimeInstrumentation`
with phase `fresh`, force-stop only `com.example.chantipoint.journalvalidation`,
then run phase `restart` without clearing data. The fresh phase intentionally
resets only its fictional fixture namespace; the restart phase tests persistence
and finally removes only that fixture key to test missing-key preservation.
This configuration and both runner phases have been executed successfully.

After installing the verified isolated APKs, the exact phase sequence is:

```powershell
adb -s emulator-5554 shell am instrument -w -r -e phase fresh com.example.chantipoint.journalvalidation.test/com.example.chantipoint.journal.JournalRuntimeInstrumentation
adb -s emulator-5554 shell am force-stop com.example.chantipoint.journalvalidation
adb -s emulator-5554 shell am instrument -w -r -e phase restart com.example.chantipoint.journalvalidation.test/com.example.chantipoint.journal.JournalRuntimeInstrumentation
```

C2c still needs trusted legacy provenance, approved source binding, actual SHA-256
verification, stopped legacy writers, verified encrypted replacement before
deletion, interrupted migration and conflicting/wrong-account copy handling.
C3 needs the shared owner/auth-generation-bound coordinator, receipt-preserving
repository integration, dispatch/replay, refresh, safe cleanup and separately
approved hosted deployment/cutover. No GPS, employee UI or attendance RPC behavior
is changed by C2b.
