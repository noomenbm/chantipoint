# Local v2 activation contract

Baseline: `36d1ab4`, `feature/attendance-live-integration`. Migration
`20261025000100_attendance_activation_contract.sql` is **local only**. The four
earlier attendance migrations are now deployed to `chantipoint-dev`; its five
migration baseline passed 19 schema postchecks and the normal-app History smoke.
Hosted gate remains 1. This slice made **no hosted request or change**, no client
change, and no activation. All previously applied migrations remain unchanged.

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
Actual PostgREST header forwarding for this new contract was not runtime-tested.

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

The normal Save button remains disabled and attendance remains guarded. This
slice supplies no client header adapter, capability consumer/authority, trusted
configuration issuer, device enrollment, legacy migration or UI changes.

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
postcheck contract for six migrations. Updated operator postchecks and actual
GET/header-forwarding API checks are prerequisites for a later approved deployment.

No Flutter/analyzer/Android test was run: no client/native code changed. No hosted
RPC/deployment, activation, enrollment, GPS/UI work or real employee data was used.

## Remaining cutover prerequisites

Review/deploy this migration separately while retaining gate 1, with new operator
postchecks and a supervised withdrawal plan. Implement the client pinned-scope
epoch header/capability authority without mutating command bytes or rebinding work.
Establish independent legacy provenance, durable device/source ownership and old
writer fencing; resolve/quarantine every pending legacy/note/attendance state.
Inventory/restore/backup policy and pre-upgrade drain proof remain necessary.
Rehearse the eventual maintenance boundary and active/closed owner reads, auth
changes, late receipts, process restart and actual HTTP header behavior before
any approved v2 test write. Standalone Save stays a separate reviewed cutover.
