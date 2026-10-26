# Active-session note Save

Baseline: `feature/attendance-live-integration`,
`e07cf45626f4a30359acba6ca13a7a9fb8187861`; initially clean.
This local implementation wires the existing settled-note coordinator and secure
Android storage into the normal application. Hosted deployment and activation
are not part of this change.

**Normal-app Save is working in the approved local seven-migration development
environment.** Creation, editing, empty text, explicit clearing, cold recovery
and checkout/preserve completed through real local Auth/PostgREST and Android
encrypted storage. Default/release and hosted activation remain guarded.

## Server protocol

The forward migration `20261025000200_active_session_notes_v2.sql` adds
`public.save_employee_note_v2` with the same five RPC arguments as settled notes.
It requires gate 2 and the independently provisioned epoch in
`x-chantipoint-attendance-epoch`. The existing transaction-level deployment locks
remain held through commit, followed by the existing profile/role/company/session
lock order. The wrapper calls the unchanged private settled-note implementation
for exact validation, fingerprinting, mutation, replay fences and terminal proof.

The existing employee/key evidence namespace now has protocol and deployment-epoch
metadata. Legacy rows remain protocol 1 with a null epoch. A v2 call rejects an
existing legacy key or another epoch's key, including replay; it never adopts or
reapplies that evidence. New v2 operations are tagged atomically in the same
transaction. A gate-1 legacy call rejects a v2 key after a gate rollback, while
original legacy keys keep their exact receipts and behavior. Both old public note
endpoints remain retired at gate 2. No committed migration, attendance hash,
attendance request, receipt, outbox schema or final-note semantics were edited.

V2 note receipts add `deployment_epoch` and use `note_contract_version=2`.
The other nine field meanings remain the settled-note contract. The client
requires the exact ten-field set and original key, binding/session and epoch.
The server fingerprint remains opaque to the client; protocol/epoch checks are
additional private evidence checks, not a replacement client hash algorithm.
Note text is never copied into operation evidence or receipts.

Save/checkout still serialize on the same profile and session locks. Save before
checkout/preserve keeps the saved value; replace/clear uses the checkout's frozen
intent. Save admitted after closure settles `not_applied/session_closed`.
Replay-only misses install a terminal `replay_fenced` result, so a delayed initial
request cannot later apply it. Exact whitespace, Unicode and empty-string versus
NULL semantics and the 1,000-code-point limit are preserved.

## Client and employee interface

The application-lifetime composition owns one `SessionNoteCoordinator`, sharing
the existing attendance coordinator, authority, pinned transport and binding
queue. It uses `AndroidSessionNoteStorage`; no second attendance outbox is added.
The existing format-1 note envelope gains an optional `note_protocol=2` command
tag. Old command bytes remain readable as protocol 1 and are blocked for normal
v2 dispatch/recovery rather than converted. Unknown formats or corrupt evidence
fail closed. The native mechanical codec accepts both supported forms without
rewriting existing records.

Every new explicit Save freezes exact text/clear intent, session and a fresh
secure key before awaits. It does not call GPS. Pending CAS, exact native
verification and reread precede POST. Recovery is explicit and replay-only with
the original key/body under newly authorized same-binding contexts. A late valid
receipt persists under its original binding even after logout; stale results
cannot authorize actions or publish session data.

Checkout takes the existing durable note-slot reservation before entering C3.
Matching retained uncertain/confirmed C3 evidence recovers through C3's original
replay/proof paths. The reservation is released by verified CAS only after durable
confirmation and canonical closure. Normal receipt consumption joins the same
note queue and cannot bypass a checkout reservation. Note Save additionally
requires the attendance outbox to be clear and verified.

Cold recovery also restores C3's own exact empty-state proof through its existing
`recoverEmpty` verifier under a separately issued same-generation/binding child
context. An independent note-side file check cannot substitute for that proof.
After note settlement the workflow makes a fresh scoped active-session selection
before enabling another Save or checkout; a receipt is never used to fabricate
the reader's current-session observation. Two true cold-composition regressions
failed before this correction and passed afterward. This closes a gap found in
the first device recovery run, where the receipt recovered but subsequent actions
did not yet have their required observation/proof.

The French active-session editor shows the saved canonical value separately from
the draft. `Enregistrer la note` replaces with exact text, including an explicitly
submitted empty string; `Effacer la note enregistrée` stores NULL. The checkout
editor and preserve/replace/clear choices remain separate. Save success appears
only after receipt persistence/verification and a fresh canonical read. That
value may include a later authorized edit; a historical receipt does not assert
that the current note equals the original submitted text.

Pending operations disable competing Save/checkout and expose `Vérifier la note
conservée` or `Vérifier la sortie conservée`. A validation failure preserves the
draft. Authorization invalidation clears visible drafts and suppresses stale
data. Route disposal does not abandon already submitted work; app shutdown drains
contexts and persistence before closing transport.

Signed development enrollment remains mandatory in normal DEBUG composition,
with the configured trust anchor, original full binding and fresh gate-2 check.
Default/release denial remains. Preparation/installation still require a clean
note namespace. Subsequent verification admits only the approved binding's
authenticated supported v2 note slot and its own Keystore alias. Legacy slots,
other bindings, missing key/ciphertext, unknown files and sidecars still deny.
The signed approval bytes, policy and original clean-checkpoint digest are not
rewritten; permitting this subsequent slot does not enroll or adopt old work.

## Remaining conservative boundaries

**Pre-production blocker: orphaned checkout reservation.** An interruption after
durable checkout reservation but before durable C3 attendance-command preparation
can require reviewed recovery/operator intervention. Controlled developer-only
testing does not resolve this limitation. Do not ship production attendance until
a reviewed recovery procedure exists; generic resets or evidence deletion are
not a recovery procedure.

A crash after checkout reservation but before C3 preparation can leave only its
reference. Missing, prepared, consumed, mismatched or unreadable attendance
evidence cannot prove confirmed canonical closure, so the reservation remains
blocked for review. The UI identifies absent/different/incomplete proof; it does
not invent a command, release the lease or clear a journal. This pre-existing
foundation boundary remains a recovery limitation, not an automatic reset path.
If reservation release committed but its acknowledgement was lost, refresh reads
the retained states before offering C3's explicit confirmation/empty recovery.

The binding queue covers cooperating instances in one Dart isolate; native CAS
provides durable note/checkout exclusion. This does not fence arbitrary modified
clients, old APKs or already admitted requests. Existing server retirement and
operator maintenance/drain requirements remain. Power-loss and multi-process/OEM
storage guarantees beyond prior validation are not newly certified.

## Validation status

- Full serial Flutter suite after the cold-recovery correction: **1,764 passed**.
  The affected note/normal/development integration rerun passed **122 tests**.
- Isolated Android app/test APK build: passed offline, 1m 18s.
- Final configured normal `lib/main.dart` APK build: passed offline, 1m 39s;
  final analyzer reported no issues. The APK was installed as an update only,
  with approval, attendance and note ciphertext hashes unchanged by installation.
- Dedicated AVD, new isolated enrollment package: **27 fresh checks + 4 restart
  checks passed**, including own v2 note admission and legacy/unknown/sidecar/
  missing key/missing ciphertext denial. The existing normal installation was
  not reset or used by these native fixtures.
- All eight rollback-only database suites passed **896 assertions**, including
  **37** new v2 note assertions. All **eight real SQL concurrency scenarios**
  passed with observed lock waits: three Save-before-checkout note intents,
  checkout-before-Save, replay-first fencing, original-first replay, changed-key
  payload conflict and epoch-change serialization.
- The real normal app/local backend passed creation, editing, empty text and
  explicit clearing, and original-key note replay after a suppressed committed
  acknowledgement and process restart. Save did not add attendance events or
  location observations. On the corrected final build, cold note recovery was
  followed immediately by successful checkout/preserve, without a manual refresh
  to repair selection. Receipt consumption, three closed History rows and logout
  also passed. Both lost-ack cases recorded exactly one original and one replay
  with identical frozen intent; neither replay added a note operation.

| Normal-app acceptance | Observed result |
| --- | --- |
| Create / edit / explicit empty / clear | Four distinct applied v2 operations; canonical value categories and UI confirmation agreed. Empty and NULL remained distinct. |
| First lost acknowledgement | Committed operation 5 stayed pending locally; restart preserved approval, attendance and note ciphertext bytes; explicit original-key replay recovered its proof. |
| Final-build cold recovery | A deliberate second lost acknowledgement produced operation 6. Restart sent no note request automatically; explicit replay preserved the same frozen intent and count. |
| Save versus GPS | All six Save operations left attendance events and location observations at five; only the subsequent checkout increased each to six. |
| Checkout / preserve / consume | Closed the third session with the saved note retained, released the note reservation, then consumed the verified C3 receipt through normal controls. Home returned to verified no-active-session state. |
| Retained evidence / logout | Original two-session rows and original signed approval bytes remained unchanged; History showed three closed rows and logout showed the login screen. |

Final main rehearsal aggregates: **three closed sessions, zero active sessions,
six attendance events, six location observations and six applied v2 note
operations**. No runtime note contents or coordinates are in the review package.
Emulator location delivery was fictional; no new physical-phone test was run.
The normal app is signed out. The dedicated AVD, task-owned proxy and four
rehearsal containers are stopped; their data, isolated native fixtures and the
disposable SQL test database are retained. The development database stayed stopped.

Docker startup was initially rejected by automatic approval review because it
could start retained containers. The developer explicitly authorized startup and
state checks. The retained development database remained stopped. The existing
fictional rehearsal baseline was verified before use; applying the new migration
preserved its original two sessions, four events, four observations, gate, epoch
and private implementation bodies. Only its local migration count changed to seven.
The separate `cp_notes_validation` database contains an empty application-schema
clone and fictional SQL fixtures. Clone setup used template0, cached crypto
extensions and explicit object grants; unrelated role ownership/default-privilege
templates were omitted. An initial empty test clone was replaced during setup;
neither retained database was reset. Initial clone setup failures and the old
two-endpoint assertion were test-environment/expectation corrections, not SQL
production defects.

See review evidence for final analyzer/test results and any subsequent acceptance.
No hosted RPC/migration/gate change, real account operation or real device enrollment,
retained journal cleanup/rebinding, commit, push or branch creation is authorized
or performed by this implementation.

## Reproduction and review

The executed Flutter commands used the installed Dart executable and
`C:\dev\flutter\bin\cache\flutter_tools.snapshot` directly with `test --no-pub
--concurrency=1` and `analyze --no-pub`. Conventional Flutter wrappers provide
the equivalent commands. Offline Gradle built the existing enrollment-validation
package/app tests, then normal `lib/main.dart` with the independently checked
private loopback configuration. No SDK/image/package downloads were needed.

Database suites ran against `cp_notes_validation` in the verified local rehearsal
container, with each fixture/gate change rolled back. Real overlap coverage used:

```powershell
python -B supabase/tests/integration/active_session_notes_v2_concurrency_test.py --container supabase_db_chantipoint_e2e_20261025
```

That driver accepts only the named disposable test database and retains its
fictional fixtures. Do not substitute the retained development database. Runtime
UI drivers, credentials/configuration, APKs and raw logs remain private and are
excluded from the review archive. Evidence contains counts, safe state categories,
hashes and whitelisted control observations only. The complete changed/new file
inventory, final Git status, test summary, SHA-256 manifest and ZIP hash are under
`E:\ChantiPointReviews\active-session-note-save-20261025`.
