# C6.3b isolated client note recovery foundation

This foundation is opt-in and has no production workflow or navigation wiring.
`Enregistrer la note` remains disabled. The live legacy controller, unkeyed
repository calls, attendance journal semantics, SQL and hosted v2 gate are unchanged.
The reviewed [C6.3a server contract](attendance-backend-contract.md#c63a-settled-note-operations-server-only)
is local only; all C6.3b HTTP tests use fictional identities and mocked HTTP.

## Immutable note intent and receipts

`SessionNoteCommand` freezes the original five-field `JournalBinding`, captured
auth generation, session UUID, operation key, replace/clear intent and exact text
in original `parameters_json`. This is a separate schema, never a
`JournalCommand`. Unicode code-point limit 1,000, valid Unicode/NUL checks, and
null/empty distinctions apply before persistence; nothing trims or normalizes.
Initial POST retains exact bytes. Replay changes only outgoing `p_replay_only`,
never stored intent or its original generation. Caller supplies a securely
generated fresh key; this foundation does not generate timestamps/keys or GPS.

The typed `SessionNoteTransport` is implemented by the existing scoped HTTP
adapter, sharing only its pinned request authority and bounded one-attempt HTTP
machinery. It does not use `SupabaseAttendanceRepository` or attendance DTOs.
Scope acquisition and immediate pre-send checks require exact authorized binding/
generation and trusted deployment URL/key. No current-account fallback, redirects,
retry or internal timeout. The entire bounded strict-UTF-8 response stream settles
before return, including errors/oversized streams. Safe exceptions contain codes,
never credentials, notes, raw error bodies or provider messages.

`SessionNoteReceipt` requires exactly C6.3a's nine duplicate-free fields: version 1,
original key/profile/company/session, a lowercase SHA-256 fingerprint, valid
timestamp, and either applied/null-reason or not_applied with replay_fenced or
session_closed. Extra fields, absent fields, malformed timestamps, not_found,
changed bindings and HTTP errors cannot confirm anything. Original complete JSON
and timestamp spelling are retained. The PostgreSQL fingerprint is opaque to the
client: the trusted scoped server recomputes it from supplied frozen inputs and
checks conflicts. The client validates its shape, not a reimplementation of
PostgreSQL jsonb::text hashing. A receipt proves that operation, never note equality
or the current note value.

## Separate durable record and exclusion

`SessionNoteRecord` format 1 stores revision, full binding, phase, optional frozen
note command, original terminal receipt JSON and optional checkout reference.
Captured generations are evidence, never persisted credentials or restart login
authority. There are no access/refresh tokens or publishable keys in the record.

| State | New note | Checkout | Explicit recovery |
| --- | --- | --- | --- |
| Fresh absence / empty | Persist and verify pending before note POST. | Persist and verify checkout reservation before entering C3. | No retained note to replay; block. |
| Pending (send may or may not have started) | Block, including another key. | Block. | Verify exact record, then replay-only original note. |
| Terminal | Verify proof and freshly read original canonical session before replacing with a different note key. Same key/exact command returns retained proof; changed intent conflicts. | Verify proof/current state, then reserve checkout. | Verify proof, read canonical state; no note POST. |
| Checkout reservation | Block. | Block new attempts. | Match full original C3 command reference and use approved C3 replay/confirmed recovery. |
| Unreadable/corrupt/key loss/ambiguous sidecars | Block. | Block. | Preserve artifacts; no guessed empty state, new key, reset or cleanup. |

`SessionNoteCoordinator` is application-lifetime. A shared full-binding isolate
queue covers note save/recovery/checkout and context release. Durable native CAS
reservations provide exclusion for cooperating instances beyond that queue:
competing pending/reservation writes from the same empty/terminal revision cannot
both succeed. All future participants must use this boundary; it does not fence
legacy or arbitrary direct callers of C3/native APIs.

Preparation is CAS + exact native verification + reread before POST. A preparation
failure sends nothing but can leave a committed pending record. Recovery then
uses replay-only, potentially fencing an operation never actually submitted.
After any uncertain send or process restart, pending records are **never** resent
as an initial write. Valid terminal proof is CAS-persisted and independently
verified/read back before canonical SELECT or local gate release. Persistence
failure can follow commit; readable bytes alone do not prove durability. A later
explicit recovery must repeat exact verification. Canonical failure retains
terminal evidence and blocks another note save/checkout until state is readable.
An old SELECT, matching note text, network error or conflict cannot release an
unsettled operation. Recovery acts on retained intent, never a replacement draft.

Note mutations also require the existing attendance journal to be clear. Stored
empty attendance state needs its exact verifier/reread; pending, confirmed,
legacy, migration-pending or unreadable attendance state blocks note submission.
No attendance command is compacted or interpreted as failed by this foundation.

Checkout reservation stores only session/key/generation and SHA-256 of the complete
original serialized `JournalCommand`, including original parameters JSON. Full
attendance intent, GPS and final-note payload stay solely in the attendance outbox.
A child context is issued in the exact parent generation/binding for C3; C3 owns
it through its unchanged sequencing. The original parent remains owned through
reservation cleanup. Only durable C3 confirmation plus the scoped canonical closed
original session permits reservation release via verified CAS. Lost cleanup can
leave either the original reservation or its released tombstone; no success is
inferred from failure. Retained C3 confirmation/replay can recover the reservation.

Prepared, missing, consumed, mismatched or unreadable C3 evidence cannot prove how
to release a leftover checkout reservation. These deliberately remain blocked for
review, including a process death between reservation and C3 preparation. There
is no force-reset API. A later integration slice must supply a reviewed resolution
for these boundaries; direct C3 consumption must not race reservation recovery.

## Authorization and lifetime

Each explicit call consumes one context and rechecks it after queueing/awaits.
Logout/relogin/account/environment changes cannot retarget intent or publish stale
results. A submitted valid late receipt is persisted under its **original** binding,
without a stale canonical refresh. Result getters suppress receipt/session data
after invalidation. Caller timeout, discarded futures and route disposal do not
cancel work, free its queue reservation or release ownership early. The app owns
storage, authority, HTTP client and C3 coordinator beyond route lifetimes.

Explicit recovery after restart or relogin needs newly attested authorization for
the **same full binding**. Its new memory-only generation authorizes replay, not a
fresh initial send of old intent; stored generation/parameters remain unchanged.
This does not infer provenance from a file, UUID equality, configured current user
or missing server record. Future composition must use the exact C3.3 owner/authority
and close resources only after outstanding contexts drain.

## Android storage and limits

The narrow `chantipoint/secure_session_notes` channel exposes read, CAS and exact
verify only. It reuses encryption/locking/AtomicFile/sync primitives through a
separate note codec, directory, AAD domain and per-binding Keystore alias:

- `noBackupFilesDir/session_note_operations/slot_<binding SHA-256>.bin`
- `<package>.session_note_operations.<binding SHA-256>.aes.v1`
- AAD domain `chantipoint-session-note-aad-v1`, binding and package framed exactly.

AES-256-GCM, fresh IV, authenticated full record, process mutex/OS file lock,
revision/key CAS, file/directory sync and complete encrypted readback apply.
Attendance's schema, directory, key, AAD and recovery policy remain unchanged.
Native checks mechanical transitions and immutable content; Dart validates complete
note/receipt semantics. MainActivity registers the extra channel lazily: registration
alone opens no files, creates no keys and dispatches no work.

The no-backup directory is [excluded by Android Auto Backup](https://developer.android.com/identity/data/autobackup#Files).
No plaintext preferences/files, note/body logs, credential persistence or key export
are added. This does not resolve backup policy for the old plaintext attendance
journal or prove OEM/device-transfer behavior. The encrypted slot retains one
current operation and its terminal evidence until safely replaced; retention of
that sensitive operation text/metadata still needs approval before real use.

A surviving per-binding key with missing ciphertext fails closed, including failed
initialization after key creation. Ciphertext without its key also blocks; keys are
not regenerated over evidence. Sidecars remain unavailable and untouched: this
slice adds no note normalization/promotion/deletion policy. Complete app-data/key
loss, arbitrary rollback, device loss and rooted/modified clients are outside the
guarantees. Removing both key and all evidence is indistinguishable from a fresh
installation. Limits remain 32 slot filesets and 64 KiB per record; no automatic
pruning or backup/device-loss recovery is provided.

Host simulations and actual Android build/runtime evidence are recorded separately
in [Development Status](development-status.md). Power-loss durability, older
AtomicFile implementations, actual multi-process contention, permanent key
invalidation and OEM/backup-transfer behavior need further validation. C6.3a
hosted deployment, unkeyed-writer retirement/fencing, client workflow integration,
privacy/retention approval and Save activation remain separate review gates.
