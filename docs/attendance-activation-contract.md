# Local v2 activation contract

Active-session notes now have a forward-only local extension in migration
`20261025000200`. `save_employee_note_v2` requires locked gate 2 and the same
independently provisioned header epoch; it does not reopen either retired legacy
note writer. Existing keys are separated by protocol and epoch. Normal client
Save/recovery is composed under the signed development boundary; the historical
disabled-Save statements below predate that follow-up. Hosted deployment is not
included. See [note contract and validation](active-session-note-save.md).

Baseline: `36d1ab4`, `feature/attendance-live-integration`. Migration
`20261025000100_attendance_activation_contract.sql` is **local only**. The four
earlier attendance migrations are now deployed to `chantipoint-dev`; its five
migration baseline passed 19 schema postchecks and the normal-app History smoke.
Hosted gate remains 1. The server slice made **no hosted request or change** and
no activation. The client follow-up below also makes no hosted request or change.
All previously applied migrations remain unchanged.

## Server state and read-only capability

`private.attendance_deployment` contains one server-generated UUID
`deployment_epoch` and `write_contract` (1 or 2). The forward migration requires
gate 1 and leaves the new state at **1**. The private gate function now reads this
state through the transaction lock helper; replacing its SQL body to change modes
is no longer the control mechanism. Missing state fails writes closed.

The table has RLS, no API-role grants/policies and no public setter. This migration
does not add an administrator API/UI. An epoch is public deployment metadata,
not a credential. Never derive it from a journal, URL or matching owner UUIDs.
Restore/clone operators must rotate it before API admission; restoration of a
database also restores its metadata, so restore detection is **not automatic**.
Do not reuse epochs or rebind unresolved commands to the newly observed identity.

Authenticated active employee profiles can GET
`/rest/v1/rpc/attendance_capability` (no arguments). Administrator-only, disabled,
revoked and unauthenticated callers cannot obtain the capability. It is STABLE,
security-definer with an empty search path, reads without row/advisory locks, and
executes inside READ ONLY. Its exact four fields are:

```json
{
  "capability_version": 1,
  "deployment_epoch": "<server-generated canonical UUID>",
  "write_contract": 1,
  "v2_available": false
}
```

Gate 2 advertises `v2_available=true`; missing state reports null identity/mode
and false. The flag describes server contract availability for an authorized
employee, not per-operation success, active-company permission to check in, device
enrollment or a client dispatch lease. The original operation authorization and
company/session rules still apply. A capability snapshot can become stale.

## Epoch binding and serialization

Every `check_in_v2` / `check_out_v2` call, including replay, must carry the exact
canonical UUID in **`x-chantipoint-attendance-epoch`**. The wrappers validate it
from PostgREST's transaction-local, lowercased `request.headers`. No epoch field
is added to RPC parameters, command hashes, stored attendance, events or receipts.
Original immutable request bytes, keys, hash functions, final-note intent and
the ten-field v2 acknowledgement contract are unchanged. The existing private
submit/hash/receipt bodies are reused, not rebuilt.

Safe errors contain only fixed codes/messages: `attendance_epoch_required`,
`attendance_epoch_invalid`, `attendance_epoch_mismatch`, or
`attendance_deployment_unavailable` (`P0001`). Invalid JSON/non-object metadata,
wrong value types/noncanonical UUIDs and request-header metadata over 64 KiB are
rejected without echoing headers, keys or values. A correct epoch does not change
gate 1, bypass employee authorization, or authorize a foreign session.

All guarded writers take shared transaction advisory lock `(174811,2)` and a
`FOR SHARE` lock on the singleton **before** profile/role/company/session locks.
A BEFORE STATEMENT trigger takes the exclusive advisory lock before ordinary
state INSERT/UPDATE/DELETE row locks. Thus gate/epoch updates wait for already
submitted transactions through commit/rollback, and queued writers recheck the
resulting state. Repeatable-read snapshots cannot silently retain an old row:
`FOR SHARE` raises serialization failure when the row changed after their snapshot.
Lock/serialization/transport failures remain failures to establish an outcome,
not permission to replace a pending command or claim server rollback.

Privileged DDL/TRUNCATE, disabling triggers and replacing private functions are
outside API-role protections. A later operator procedure must take the deployment
fence before such maintenance and drain pre-upgrade transactions; no hosted
maintenance or activation operation is supplied/executed here.

PostgREST behavior is documented in its [transaction settings](https://postgrest.org/en/stable/references/transactions.html)
and [RPC reference](https://postgrest.org/en/stable/references/api/functions.html).
The original server/client slices did not runtime-test HTTP forwarding. The
[gate-1 deployment follow-up](attendance-activation-deployment.md) now verifies it
through actual local PostgREST 16.4; hosted forwarding remains unverified.

## Writer and replay policy

| Operation | Gate 1 | Gate 2 |
| --- | --- | --- |
| Legacy `check_in` / `check_out` | Original implementations, parameters, hashes and six-field receipts; no epoch required. | **All calls rejected**, including accepted-key replays, with `attendance_client_update_required`. Legacy checkout cannot create a closure. |
| `update_employee_note` / `save_employee_note` | Exact relocated implementations and current grants, including terminal note receipt/fence behavior; no epoch required. | **All calls rejected** with `standalone_notes_not_enabled`, including replay-only misses that would otherwise write a fence and existing terminal receipt replays. |
| New v2 attendance | Matching epoch still cannot authorize a new write. | Matching epoch plus the existing employee/session/company authorization permits the original v2 implementation. |
| V2 accepted-key replay | Matching epoch can return retained proof even though new writes are disabled. | Matching epoch can return retained proof. Original payload/hash must match; changed intent conflicts. |
| V2 replay miss | Exact `{"contract_version":2,"status":"not_found"}`; no mutation/fence. | Same inconclusive response; never proof that an original failed or cannot arrive later. |

Complete retirement is the smallest policy from the assessment; no new legacy
read-only replay adapter is introduced. Retained legacy/note evidence is not
deleted or treated as failed. Settle or quarantine those commands before gate 2;
their endpoints cannot recover them afterward. Original receipts/notes remain
stored and canonical reads remain subject to existing RLS.

Returning to gate 1 would reopen all four old writers by design. It is **not an
emergency stop or approved rollback plan**. A separately reviewed maintenance/
withdrawal procedure is required before actual activation. Client receipt-only
finalization of submitted work and uncertain outcomes must remain intact.

The normal Save button remains disabled and attendance remains guarded. The
server migration supplies no trusted configuration issuer, device enrollment,
legacy migration or UI changes. The client boundary is described next.

## Client capability and epoch boundary

The client follow-up is based on `de3ef11`. `AttendanceCapability` validates an
exact, duplicate-free four-field object: integer version 1, canonical lowercase
UUID, integer gate 1/2 and a Boolean availability consistent with that gate.
The explicit null-epoch/null-gate/false missing-state response is recognized as
unavailable. Unknown fields, types, versions, duplicates (including escaped key
aliases), truncation, trailing data and inconsistent availability are rejected.

`SupabaseAttendanceOperationTransport.readCapability` makes one authenticated GET
using the captured, memory-only request scope. It reuses the existing non-retrying,
redirect-disabled HTTP boundary, strictly decodes UTF-8, retains at most 1 KiB and
consumes the response stream through settlement. HTTP/schema/auth/network errors
remain safe typed failures; no raw body or credential enters exception text.
Authorization, complete five-field binding, generation and trusted endpoint are
checked after asynchronous credential acquisition, before sending and after the
complete read. A stale observation cannot be published. No capability is cached,
persisted or promoted into a dispatch approval.

`ATTENDANCE_ENVIRONMENT_ID` remains the independently provisioned deployment
identity. Its former arbitrary-text model is compatible with historical journal
decoding but insufficient for this UUID server contract. The smallest compatible
change requires a canonical UUID **at normal composition and capability/v2 HTTP
boundaries**, without changing the journal schema or rewriting any binding.
`AttendanceAuthOwner` supplies `expectedAttendanceEpoch` from its independently
trusted deployment configuration in each pinned scope. Missing, noncanonical or
different scope identity fails closed. Neither a capability response nor a
journal, URL or account supplies the expected value. This is configuration
validation, not a production provisioning/enrollment workflow; no actual epoch or
configuration value is added to source by this slice.

Each v2 check-in, checkout and replay sends
`x-chantipoint-attendance-epoch` only after verifying that the trusted scope epoch
equals the command operation's original binding. Frozen RPC JSON, hashes, keys,
timestamps, final-note intent and raw receipts are untouched. Older arbitrary
environment labels stay readable but cannot be sent as epochs. A changed server
epoch blocks the old binding; it never causes automatic adoption or rebinding.
Changing build configuration cannot prove that a prior namespace contains no
pending work: cross-namespace inventory/reconciliation remains a cutover gate.

Normal composition still defaults to `UnapprovedAttendanceCutover`, uses its
existing conservative projection, and supplies no approval issuer. The capability
check is an **additional denial boundary**: with an explicit fictional approval,
it runs before capture and again before submit/replay. Each check is a fresh GET;
no polling or automatic retries are added. Approval and pinned authorization are
rechecked immediately before POST. A capability can change after the GET; the
server transaction's epoch/gate guards remain authoritative. Its rejection or a
lost response retains uncertainty, not proof of rollback.

The isolated raw transport can be tested with explicit fictional authorities
without a capability callback; normal composition always installs that callback
and its separate approval check. Gate 1 remains a valid unavailable capability.
Although the server can replay retained v2 proof at gate 1, this slice does not
unlock normal-app replay or receipt consumption. Original pending commands and
bindings survive mismatch, network error, logout and rotation; already-submitted
responses still settle for C3 receipt-only finalization without stale refresh.
Legacy dispatch and standalone Save remain disabled. No native storage, device
enrollment, migration, active-company permission or production cutover authority
is implemented here.

Client validation (mocked HTTP and fictional identities only):

```powershell
flutter test --no-pub --concurrency=1 test/attendance_capability_test.dart test/supabase_attendance_operation_transport_test.dart test/normal_attendance_integration_test.dart test/attendance_auth_owner_test.dart test/scoped_attendance_active_session_reader_test.dart test/session_note_http_test.dart
flutter analyze --no-pub
flutter test --no-pub --concurrency=1
git diff --check
```

Final focused suite: **331 passed**. Full serial suite: **1,673 passed**, zero
failures/skips. Analysis: **no issues**. Tests cover strict parsing, gate 1/2,
missing/wrong epochs, rotation, wrong-project scopes, logout/same-user relogin/
account switching during acquisition/read, initial/replay headers, preserved
frozen note/evidence/receipt data, retained pending bytes and old text bindings,
and a server rejection after a matching snapshot. Existing late-response tests
still retain complete receipts without a stale canonical refresh. Initial new
test compilation and analyzer findings were corrected before these final runs.
C: remained above 14.95 GiB at sampled checks (15.07 GiB initially); E: 17.22 GiB.
No native code changed; Android/emulator, hosted API/header forwarding, SQL/pgTAP
and deployment checks were not rerun for this client slice. No actual journals,
employee data or external services were read/written.

## Local validation

The existing PostgreSQL 17 container/volume was reused at its unchanged 768 MiB
cap; no reset, image pull or full-stack startup. Initially it had five migrations,
gate 1, no pgTAP and zero rows in nine checked application/Auth/evidence tables.

```powershell
# Before applying the new migration; all seeded data and DDL roll back:
python -B supabase/tests/integration/attendance_activation_upgrade_test.py
supabase migration up --local --log-level error
supabase test db --local supabase/tests/database/attendance_activation_contract_test.sql --log-level error
python -B supabase/tests/integration/attendance_activation_lock_test.py
supabase test db --local supabase/tests/database --log-level error
```

- Populated-baseline rehearsal: **7 passed**. Active/closed sessions, notes and
  terminal proof survived the actual DDL unchanged; original private core and
  relocated implementation bodies/argument metadata matched; old keys replayed.
- Actual local migration: **only `20261025000100` applied**, with gate 1 retained.
- Focused pgTAP: **69 passed**, including real READ ONLY capability, authorization,
  gate-1 compatibility, header validation, rotation/gate changes, retired writers,
  exact receipts, wrong-owner replay isolation and unchanged evidence.
- Full pgTAP: **7 files / 859 passed** (790 retained assertions + 69 new).
  Earlier gate-2 legacy-checkout adapter expectations now assert retirement.
  Final-note test setup uses privileged fictional fixture updates rather than
  calling a retired standalone writer. Gate-1 authorization assertions remain.
- Multi-connection fence test: **7 passed**, proving two blocked overlaps and
  repeatable-read `40001` rejection. Gate/epoch changes roll back. One no-op
  metadata UPDATE commits solely to advance the tuple version; all stored values
  are verified equal afterward. It creates no employee/attendance fixtures.
- Initial focused/full attempts stopped on missing `revoked_at` in a new fixture
  and an older fixture's temporary NULL gate. Both test setups were corrected;
  no migration edit, data reset or weakened server check was used.

Final local verification found six recorded migrations, gate 1, one deployment
row and the original epoch retained. All eleven new/replaced function bodies
match the forward migration. The nine checked Auth/application/evidence table
counts remain zero, pgTAP is absent, and PostgreSQL stopped cleanly (exit 0) with
the container/volume retained. Docker was already running and was left running.
C: free space was 15.17 GiB before work and 15.04 GiB after shutdown; E: 17.22 GiB
at both checks. RAM recovered from 0.40 GiB initially to 1.03 GiB before startup.
No destructive cleanup, image pull, SDK download or device startup occurred.

The old concurrency harnesses target historical gate-2 behavior (legacy checkout
and standalone notes still writable, or no epoch header). They were not run or
adapted in this slice; use the new focused fence harness. The upgrade rehearsal
requires the five-migration baseline and deliberately refuses an upgraded database;
do not reset the retained database to rerun it.

The previous **19 strict schema postchecks describe the deployed five-migration
stage**. They intentionally cease matching once this forward migration changes
function bodies/history/gate storage; do not treat those old fingerprints as the
postcheck contract for six migrations. The follow-up now supplies **52 strict
six-state postchecks**, validated locally with drift probes and actual local HTTP.
See the [ordered deployment/postcheck procedure](attendance-activation-deployment.md).
These new checks have not been run against a hosted six-migration state: the
activation migration is still not deployed, and hosted API checks remain pending.

No Flutter/analyzer/Android test was run in the server slice: no client/native code changed. No hosted
RPC/deployment, activation, enrollment, GPS/UI work or real employee data was used.

## Remaining cutover prerequisites

Review/deploy this migration separately while retaining gate 1, with new operator
postchecks and a supervised withdrawal plan. Review the client pinned-scope
header/capability boundary above and provision its expected UUID through an
independent trusted configuration/enrollment process, without rebinding work.
Establish independent legacy provenance, durable device/source ownership and old
writer fencing; resolve/quarantine every pending legacy/note/attendance state.
Inventory/restore/backup policy and pre-upgrade drain proof remain necessary.
Rehearse the eventual maintenance boundary and active/closed owner reads, auth
changes, late receipts, process restart and actual HTTP header behavior before
any approved v2 test write. Standalone Save stays a separate reviewed cutover.
