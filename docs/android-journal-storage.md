# Android Encrypted Journal Storage — C2b

C2b implements the Android backend for the [format-2 journal](secure-command-journal.md).
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

There is no arbitrary path, key export, general encryption, reset, delete-all,
migration or network method. Channel bytes are plaintext inside the application
process; native files contain encrypted containers only. Unsupported platforms,
missing plugins, malformed responses and unknown native errors fail explicitly.
No preferences or plaintext file fallback exists.

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

**Conservative interruption policy:** existing `.new` or `.bak` for the target
slot blocks with `journal_unreadable`, preserving all copies. AtomicFile's
`openRead` can delete `.new` or restore `.bak`, so it is not called on ambiguous
artifacts. Failed writes close descriptors/release locks but do not call
`failWrite` to erase partial ciphertext. This may block despite a valid older
base file. A tested, explicitly approved artifact-recovery procedure is still
required before C3/production use; no recovery/deletion API is supplied here.

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

Native encryption/tag failure, invalidation/key loss, multi-process locks, atomic
interruption recovery, descriptor/directory sync, process death, Force stop,
reboot and cloud/device-transfer behavior remain **UNVERIFIED on Android**.
Do not activate based only on host mocks/static inspection/compilation.

C2c still needs trusted legacy provenance, approved source binding, actual SHA-256
verification, stopped legacy writers, verified encrypted replacement before
deletion, interrupted migration and conflicting/wrong-account copy handling.
C3 needs the shared owner/auth-generation-bound coordinator, receipt-preserving
repository integration, dispatch/replay, refresh, safe cleanup and separately
approved hosted deployment/cutover. No GPS, employee UI or attendance RPC behavior
is changed by C2b.
