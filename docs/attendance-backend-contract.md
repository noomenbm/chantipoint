# Attendance Backend Contract — M2.3b.2a and M2.3b.2b

## Current local activation boundary

The four attendance schema migrations are now deployed to development, with gate
1 and normal History verified. The newer
[activation contract](attendance-activation-contract.md) is **local only**:
`20261025000100` preserves gate-1 behavior, adds server-owned epoch/capability and
the `x-chantipoint-attendance-epoch` requirement for every v2 call, and makes both
legacy attendance and both standalone note endpoints reject all calls at gate 2.
This supersedes historical gate-2 legacy-checkout/note availability described in
the implementation records below. RPC arguments, hashes and receipt shapes are
unchanged; no client wiring, Save activation or hosted control deployment occurred.

The following sections retain the earlier implementation/validation records. Their local-only deployment and old gate-2 writer statements are historical; use the current activation boundary above for present status.

## Exact Public Signatures

Both functions return a JSON object (`jsonb`), use security-definer execution, a fixed empty search path, UTC response formatting, and authenticated-only execution grants.

```sql
public.check_in_v2(
  p_idempotency_key text,
  p_device_observed_at timestamptz default null,
  p_site_description text default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_accuracy_meters numeric default null,
  p_location_observed_at timestamptz default null,
  p_permission text default 'unknown',
  p_services_enabled boolean default null,
  p_location_result text default 'unknown',
  p_provider text default 'unknown',
  p_replay_only boolean default false
) returns jsonb

public.check_out_v2(
  p_work_session_id uuid,
  p_idempotency_key text,
  p_device_observed_at timestamptz default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_accuracy_meters numeric default null,
  p_location_observed_at timestamptz default null,
  p_permission text default 'unknown',
  p_services_enabled boolean default null,
  p_location_result text default 'unknown',
  p_provider text default 'unknown',
  p_replay_only boolean default false,
  p_note_action text default 'preserve',
  p_employee_note text default null
) returns jsonb
```

The caller supplies no authoritative classification, employee/company/actor identity, server timestamp, review status, or JSON metadata.

| Input | Contract |
| --- | --- |
| Key | Trimmed, 8-160 characters; new clients should generate it once without surrounding spaces. |
| Action time | `p_device_observed_at`: untrusted employee-action time. Use a frozen ISO-8601 timestamp with an explicit UTC offset; never relative expressions such as `now`. |
| Fix time | `p_location_observed_at`: untrusted GPS-fix time, independently captured. |
| Description | Blank becomes NULL; at most 500 characters. Server-derived factory attendance uses the trusted company name; external/unverified attendance uses the optional submitted description. |
| Permission | `precise`, `approximate`, `denied`, `unknown`; NULL normalizes to `unknown`. |
| Services | TRUE, FALSE, or NULL for unknown. |
| Acquisition result | `fix`, `permission_denied`, `location_services_disabled`, `timeout`, `provider_error`, `unavailable`, `unknown`; NULL normalizes to `unknown`. |
| Provider | `gps`, `network`, `fused`, `emulator`, `unknown`; NULL normalizes to `unknown`. A provider label confers no trust. |
| Replay-only | Boolean, default FALSE. TRUE performs hash-checked reconciliation with no attendance writes. Explicit NULL is an invalid request. |
| Checkout note action | `preserve` (default), `replace`, or `clear`; explicit NULL is invalid. Preserve/clear require NULL note text; replace requires non-NULL text of at most 1,000 characters. |

Malformed protocol values, unauthorized access, conflicting commands and backend failures remain distinct from insufficient location evidence. Invalid/partial/non-finite coordinates, insufficient accuracy and unusable timestamps do not themselves reject otherwise authorized attendance.

## Development Classification Policy

`private.attendance_location_policy()` contains deployment-controlled defaults with policy identifier `dev-v1`. Changes require trusted SQL and a new policy identifier. There is no client or company-settings UI for these values.

| Setting | Development value |
| --- | --- |
| Maximum horizontal accuracy | 50 metres |
| Maximum fix age | 120 seconds |
| Future clock allowance | 30 seconds |
| Maximum action-time age | 300 seconds |
| Effective uncertainty | 2 x reported accuracy + 10 metres |

These are conservative development settings, not production approval. Reported accuracy, permissions, service state and times remain client claims; a passing result does not prove physical presence or work performed.

The server requires a complete valid coordinate pair, positive usable accuracy, plausible action/fix times, reported precise permission, enabled services, successful acquisition, and complete trusted factory configuration. Missing configuration always prevents factory/external classification. No coordinates or radius are seeded.

Distance uses Haversine with Earth radius 6,371,008.8 metres and a clamped intermediate value. Raw coordinate ranges are checked before rounding to the existing six-decimal storage precision. Positive representable accuracy rounds upward to two decimals. Zero accuracy is retained as an invalid-quality report; negative/non-finite/unrepresentable accuracy becomes NULL.

For distance `d`, configured radius `R`, and effective uncertainty `u`:

- `d + u < R`: `factory`.
- `d - u > R`: `external_worksite`.
- Overlap/equality: `location_unverified`, `boundary_uncertain`.

All applicable issues are recorded in deterministic order: permission denied, disabled services, timeout, provider error, approximate permission, invalid coordinates, invalid/missing action time, invalid/stale fix time, invalid/insufficient/missing accuracy, missing fix time, missing coordinates, unavailable acquisition, unknown diagnostics, missing factory configuration, then boundary uncertainty. Accuracy/fix-time quality issues apply when a valid coordinate pair exists. The first issue is the event's primary reason.

Codes include `permission_denied`, `location_services_disabled`, `location_timeout`, `provider_error`, `approximate_only`, `coordinates_invalid`, `device_time_invalid`, `device_time_missing`, `location_time_invalid`, `location_stale`, `accuracy_invalid`, `accuracy_insufficient`, `accuracy_missing`, `location_time_missing`, `coordinates_missing`, `location_unavailable`, `unknown`, `factory_configuration_missing`, and `boundary_uncertain`.

## Writes, Timestamps and Responses

Check-in atomically creates a session, `check_in` event and linked observation. Checkout locks the owned session, writes a `manual_checkout` event and observation while it is active, then closes it atomically. There is no monitoring, geofencing, timer, notification or automatic closure implementation.

- `work_sessions.location_context` describes arrival and is never rewritten at checkout.
- The operation's event metadata stores `contract_version`, `operation`, `location_classification`, `policy_version`, and a bounded list of `location_issues`.
- `session_events.reason_code` stores the primary issue; ordinary successful v2 check-in/checkout uses NULL. `notes` remains NULL for these technical writes.
- Complete valid coordinates use `check_in_location` or `checkout_location`, including genuine stale/inaccurate/approximate fixes. Missing/invalid pairs use `unavailable` with both coordinates NULL.
- Observation `raw_metadata` contains only server-constructed `client` diagnostics and `evaluation` provenance: policy/configuration snapshot, distance, uncertainty, and validity statuses. It is limited to 4 KiB. Employee coordinates occur only in their existing columns, not event metadata.
- Event metadata is a nullable JSON object limited to 16 KiB. No arbitrary client JSON or raw vendor errors are accepted.
- The action time goes in the event and existing session device-time column. The fix time goes in observation `device_observed_at`. Non-finite device times become NULL, with invalidity recorded; finite implausible claims remain distinguishable from server times.
- Database statement-receipt time goes in `server_received_at`. One acceptance instant, captured after locks, supplies the attendance start/end and event acceptance time. Callback time remains NULL when unavailable.
- New sessions use monitoring `not_applicable`; checkout uses `stopped`. These fields do not start monitoring.
- Checkout source stays `manual`. The deprecated `checkout_reason_code` and its legacy `manual_checkout` summary remain pending the separate historical audit; the event reason explains technical evidence quality.

Unverified check-in opens `anomaly_open`. Successful checkout preserves the existing review status. Unverified checkout reopens `normal`, `reviewed` or `corrected` as `anomaly_open`, while preserving `anomaly_open`, `correction_pending` or `disputed`. No previous issue is erased by a good departure fix.

Acknowledgements retain all six legacy fields and add `contract_version`, current `review_status`, the operation's `event_id`, and `location_outcome`:

```json
{
  "contract_version": 2,
  "status": "closed",
  "session_id": "<session UUID>",
  "lifecycle_status": "closed_manual",
  "location_context": "factory",
  "started_at": "2026-10-17T12:00:00+00:00",
  "ended_at": "2026-10-17T20:00:00+00:00",
  "review_status": "anomaly_open",
  "event_id": "<checkout event UUID>",
  "location_outcome": {
    "classification": "location_unverified",
    "reason_code": "permission_denied",
    "policy_version": "dev-v1"
  }
}
```

`created`, `closed` and `idempotent_replay` acknowledge attendance. Replay-only misses return exactly `{"contract_version":2,"status":"not_found"}`; this is not proof that an in-flight uncertain request can never commit.

Administrators use existing company-scoped RLS to read sessions/events and join observations by event/session/company/employee identity. Show arrival and departure independently. Old rows without v2 evidence must remain visibly legacy/unassessed. `geofence_enter`/`geofence_exit` remain observation subtypes; the session-event umbrella remains `location_observation`.

## Idempotency and Authorization

Attendance and note-update RPCs lock the authenticated profile, active employee role, company and target session in that order. The profile lock serializes attendance per employee; existing unique indexes remain the final protection. Disabled/revoked employees cannot replay protected data. A suspended company blocks new check-in while authorized checkout of an existing session remains possible.

V2 request hashes include protocol/operation, resolved employee/company, target session, normalized submitted description, original action/fix times, coordinates, accuracy, provider and diagnostic values. They exclude the operational replay flag, current policy/configuration, derived outcome and server timestamps. Numeric tokens remove insignificant scale; timestamp tokens use epoch microseconds. Invalid evidence is hashed before sanitizing its stored representation. M2.3b.2b wraps the base hash for every v2 checkout, including `preserve`, in SHA-256 over the PostgreSQL JSONB serialization of `attendance_hash`, `note_action`, and `employee_note`. It binds the exact final-note intent/content without storing a note copy in event/evidence metadata. Check-in and all legacy hashes remain unchanged.

This finalizes an undeployed, unactivated v2 contract: a pre-M2.3b.2b v2 checkout hash is not compatible, including one that preserved the note. No old v2 checkout receipts existed in the inspected local database, and v2 has never been deployed to or activated on hosted development. Local cutover simulations restore gate 1. Do not silently backfill hashes or reconcile old experimental receipts as new commands; any such data needs explicit transition review.

A replay-only request must carry the complete original semantic payload. Missing or changed evidence/diagnostics conflicts with the stored hash. Missing stored hashes fail closed; an unavailable original outcome raises `attendance_receipt_unavailable` instead of being reconstructed. Matching receipts are returned before freshness evaluation or new-write gating, preserving the original event, classification and policy after configuration changes, policy changes, or subsequent checkout. Current session lifecycle/review fields may have advanced. There is no GPS reacquisition or evidence regeneration on replay.

The original v1 bodies are relocated to private functions without changing their hashing semantics. No client can execute them directly. V1 hashes retain their original timestamp serialization; do not apply v2 canonicalization to legacy commands.

Expected errors retain stable machine messages: `authentication_required`, `employee_role_required`, `company_not_active`, `active_session_not_found_for_employee`, `active_session_exists`, `session_not_active`, `idempotency_key_conflict`, `invalid_idempotency_key`, `invalid_attendance_request`, `invalid_employee_note_operation`, `employee_note_too_long`, `attendance_receipt_unavailable`, `attendance_contract_not_enabled`, and `attendance_client_update_required`. Future Flutter code must map these to safe French messages, without exposing raw database exceptions.

## Gate and Legacy Compatibility

`private.attendance_write_contract()` is initially 1 and cannot be executed/replaced by clients. It reads no client-controlled setting. Unexpected NULL/non-v2 values fail closed for new v2 writes.

Every attendance writer takes shared transaction advisory lock `(174811, 2)`. A future trusted cutover must take the exclusive transaction lock with the same key before replacing the gate in the same transaction. This drains writers that entered through the guarded wrappers before activating v2. Calls started before this migration installed those wrappers must already have completed; plan operational quiescence and reconcile old journals before cutover. This document does not authorize activation or hosted deployment.

- Mode 1: legacy public signatures, default arguments, writes and six-field responses remain functional; new v2 writes are rejected.
- Mode 2: existing legacy check-in keys still hash-check and replay; new legacy check-ins are rejected for both supplied contexts.
- Mode 2: legacy checkout remains possible, with a new unverified departure event carrying `legacy_location_evidence`; it never claims v2-quality GPS verification. Its original hashing and six-field response remain available for retries.
- There is one public signature for each attendance endpoint. Private implementations/helpers deny PUBLIC, anon and authenticated execution. No client table-write permissions or RLS scope are widened.

Flutter still cannot parse `location_unverified`, accept factory names during reconciliation, persist GPS in journal version 1, or check out all contexts. Upgrade those paths and reconcile/drain old journals before cutover. Do not blindly convert, discard or resubmit an old pending command with a new payload/key. Real-location journals need strict version/owner/environment binding, device-protected encryption, backup/log exclusion and an approved retention/recovery policy before real employee use. No such client changes are implemented here.

## C6.3a settled note operations (server only)

Forward migration: `20261021000100_settled_employee_note_operations.sql`. No earlier
migration, attendance RPC/key/receipt/hash, final-note intent, journal rule,
Flutter client or hosted resource changes. The deployment gate stays 1. This
endpoint is independent of that gate; it does not enable Save or client cutover.

```sql
public.save_employee_note(
  p_work_session_id uuid,
  p_operation_key text,
  p_note_action text,
  p_employee_note text,
  p_replay_only boolean default false
) returns jsonb
```

The first four arguments are required. `replace` requires non-null text (including
empty text); `clear` requires null. There is no standalone preserve operation;
replacing with the unchanged value is allowed as its own identified operation.
The limit is 1,000 Unicode code points, with exact spaces/combining sequences and
no normalization. Keys are 8–160 characters with no leading/trailing ASCII spaces,
never trimmed. Freeze and reuse original owner, session, key, action and text.

Every response has exactly nine fields:

```json
{
  "note_contract_version": 1,
  "operation_key": "fictional-note-operation-001",
  "employee_profile_id": "<original employee profile>",
  "company_id": "<original company>",
  "session_id": "<original session>",
  "request_fingerprint": "<64 lowercase hexadecimal characters>",
  "outcome": "applied",
  "reason": null,
  "settled_at": "<original server timestamp in UTC>"
}
```

Note contract **1** is separate from attendance contract 2. The response never
contains note text/action, location or attendance confirmation. Replay returns
the original terminal fields, fingerprint and time, not the current note.

| First serialized request for employee/key | Outcome | Reason | Mutation |
| --- | --- | --- | --- |
| Original, owned active session | `applied` | null | Exact replacement or clear, atomic with evidence. |
| Replay-only, no completed operation | `not_applied` | `replay_fenced` | No note write; durably consume key against late originals. |
| Original, owned closed session | `not_applied` | `session_closed` | No note write; durably consume key. |
| Matching existing operation, either flag, active or closed | Original outcome | Original reason | None; return original receipt. |

There is **no not_found state**. Changed valid inputs under a used key fail
`23505 / note_operation_conflict` without mutation. Invalid inputs fail `22023`;
absent/foreign sessions and missing/inactive employee authorization fail `42501`.
Anonymous and administrator-only callers cannot save/replay. Authorized owners
can recover receipts after closure, but cannot edit closed sessions. A suspended
company permits annotation of an existing active session, matching the old RPC.
Authorization, transport, transaction and replay errors are not terminal outcomes.

### Serialization and checkout

Lock order: shared deployment advisory `(174811,2)` -> existing
`attendance_employee()` profile `FOR UPDATE` -> employee role `FOR SHARE` ->
company `FOR SHARE` -> exact owned session `FOR UPDATE` -> evidence lookup/insert.
The profile lock serializes all same-employee operations **before** any lookup,
including absent-key replays. The evidence primary key is employee/profile plus
operation key, across sessions. Company, Auth identity and session are checked
and fingerprint-bound. Identical key text for another employee is independent;
there is no cross-employee key lock, conflict or existence lookup.

Original-first commit makes replay return the original applied receipt. Replay-
first commit installs a non-applied fence observed by waiting and late originals.
Mutation and evidence commit in one transaction; evidence failure rolls back the
note. Original rollback lets a waiting replay fence; fence rollback lets a waiting
original apply. Default Read Committed sees evidence after waiting. Higher
isolation, serialization/deadlock errors or aborted transactions can fail instead
of returning an outcome: retain uncertainty and retry the frozen operation. See
PostgreSQL 17 [transaction isolation](https://www.postgresql.org/docs/17/transaction-iso.html)
and [row locking](https://www.postgresql.org/docs/17/explicit-locking.html).

Save and checkout retain the existing profile/session lock order. Save first:
preserve checkout keeps that serialized note; explicit final replace/clear wins
atomically. Checkout first: a new original settles `session_closed`; prior applied
operations remain replayable without changing the final note. Lost checkout
responses use unchanged attendance recovery/keys; lost note responses use this
operation. Canonical note equality or an ordinary SELECT cannot prove settlement.

### Evidence, privacy and remaining gates

`private.employee_note_operations` retains only employee/company/Auth/session
identity, exact key, fingerprint, terminal outcome/reason and settlement time.
Constraints enforce key/digest/terminal shapes, with Auth and full session-owner
foreign keys using RESTRICT. RLS is enabled, with no client policies/table grants,
including for administrators. The SECURITY DEFINER RPC has empty search_path,
UTC output and no caller-supplied company/employee identity. Trusted privileged
operators remain outside the client threat model; deliberate evidence removal
is not protected against.

SHA-256 frames version, operation, key, Auth/profile/company, session, action and
exact nullable text as JSONB; replay mode is excluded. It fingerprints semantic
intent, not lexical HTTP JSON. No historical note text/action, edit events or note
versions are stored. This still creates personal operation metadata. Hashes are
not anonymization: an evidence holder can test candidate notes. Privacy review,
access/log/backup protections and a retention duration are production dependencies.
No automatic deletion/TTL/cascade is added. Pruning evidence can permit old
originals to write again; safe retirement requires an independent anti-replay
protocol and explicit approval. Retention is not yet decided.

`update_employee_note(uuid,text)` remains callable and unchanged. It does not
consult keyed fences and can overwrite notes independently; keyed receipt replay
never undoes that later edit. A fence blocks only that keyed original, not all
writers. Activation requires reviewed retirement/fencing of unkeyed writers and
draining their submitted work under the deployment lock. No silent revocation.

The later client must supply separate encrypted durable pending-note storage,
trusted environment/owner/generation/session binding, persistence before send,
scoped one-attempt HTTP, validated durable receipt/readback, and a shared save/
reconcile/checkout gate through settlement and restart. Auth changes suppress UI
publication, never retarget work. Persist terminal proof before releasing the gate;
read canonical state afterward for the **current** note. Network failure does not
prove rollback. Keep standalone notes outside the attendance journal. Save stays
disabled; hosted deployment, v2 cutover, client durability, writer retirement and
privacy/backup/retention approvals remain outstanding.

C6.3a local validation: the single forward migration applied to the retained
database without reset or image pulls. Focused pgTAP **97 passed**; final full
pgTAP **761 passed** (664 retained + 97 new). The `--settled` concurrency mode
passed **7 overlapping scenarios / 36 assertions**, using the enabled legacy
checkout; both request orders and both rollback orders were observed waiting.
The gate definition remained unchanged throughout that harness. Existing v2
final-note tests run rollback-only in pgTAP, not as a committed v2 cutover.
Before/after hashes of the five existing public attendance/unkeyed RPCs match;
the new function body matches its source. Five migrations, gate 1 and empty
application/operation tables are retained locally; database/Docker are stopped.
See [Development Status](development-status.md) for the initial inventory-test
correction, clock-discontinuity failures and successful unchanged reruns after a
clean local Docker restart. No Flutter, Android or hosted validation is claimed.

## Employee Notes — M2.3b.2b (compatible unkeyed contract)

```sql
public.update_employee_note(
  p_work_session_id uuid,
  p_employee_note text
) returns jsonb
```

Both arguments are required; omitting the note argument cannot accidentally clear it. A non-NULL value adds/replaces the note, and explicit SQL/JSON NULL clears it. An empty string remains empty text; whitespace and Unicode are preserved exactly without trimming or normalization. Limits use PostgreSQL `char_length`: 1,000 Unicode code points, not UTF-8 bytes or grapheme clusters. Combining marks count separately; future client validation must match this rule.

An accepted response is `{"status":"updated","session_id":"<session UUID>","employee_note":"<current note>"}`; cleared notes return JSON NULL. The RPC authenticates an active profile with an active employee role, requires session ownership/company identity, and locks an active session. Administrator-only, revoked, disabled and anonymous users cannot edit. All closure statuses make the note read-only. A suspended company does not prevent an otherwise authorized owner from annotating an existing active session. The standalone RPC is available in legacy mode and grants no direct table-write access.

This is one general business/work-session note, unrelated to correction requests or technical GPS reasons. Saves overwrite `work_sessions.employee_note`; only the existing row `updated_at` changes alongside it. There are no note versions, edit/correction/audit events, revision metadata, history tables or copies of prior note text. Existing company-scoped administrator read access is retained.

V2 checkout uses these explicit commands:

| Intent | Arguments | Effect |
| --- | --- | --- |
| Preserve | Omit both new arguments, or `p_note_action='preserve'` with NULL note | Keep the value present when the locked checkout executes. |
| Replace | `p_note_action='replace'`, non-NULL `p_employee_note` | Save the supplied exact text, including empty text. |
| Clear | `p_note_action='clear'`, NULL note | Store SQL NULL. |

Supplying text with preserve/clear, NULL with replace, an unknown/NULL action, or oversized text is rejected without attendance writes. The old 12-argument checkout function is dropped without CASCADE; the single 14-argument signature accepts old-shaped calls through defaults. There is no callable overload bypass. The private implementation is similarly replaced with one non-client-executable signature; existing wrappers resolve its preserve defaults. Checkout acknowledgements retain their existing ten fields; no note is duplicated into the receipt/event metadata.

The final note and closure use one UPDATE under the session lock, in the same transaction as the event, evidence and stored command hash. Any failure rolls back all of them. Replay validates the original full payload, including note action/text, then returns the original receipt without applying the note again. Changed intent/text conflicts. A successful checkout leaves the final note read-only.

Standalone saves have no idempotency key, independent command journal, version check or history. Active saves serialize; the last serialized save wins, including a delayed retry of older text. Repeating the same value is allowed but is not exactly-once acknowledgment. After an uncertain response, an ordinary reload or matching note text cannot establish settlement: the earlier request may execute after that read. Do not blindly replay or enable another save/checkout on that evidence. There is no server mechanism to recover overwritten text or identify a specific note operation. C6.2 therefore keeps standalone Save disabled under its authorized fallback. Enabling it requires a reviewed server operation identity/hash/replay/terminal-settlement contract and separate durable owner/session-scoped client uncertainty storage and checkout coordination, outside the attendance command journal. C6.3a now supplies the separate server contract above; durable client storage/coordination remain unimplemented. Freeze final checkout note intent/text with the entire immutable checkout payload/key in its existing protected journal. A note save actually serialized before preserve checkout is kept; a save serialized after closure fails. These database ordering facts do not prove that a pending network request has settled and do not weaken attendance checkout idempotency.

No Flutter note UI, journal extension, hosted deployment or v2 activation is implemented in this slice.

## M2.3b.2b Local Validation

- `supabase migration up --local` applied only `20261017000200`, without changing committed migrations or resetting data. Final function bodies match the migration sources; original legacy bodies remain unchanged.
- Final `supabase test db --local`: **664 passed, zero failures** across M2.1 70, M2.3b.1 71, M2.3b.2a 427 and M2.3b.2b 96. The existing 568 assertions are retained. The old “no note RPC” assertion now expects exactly one dedicated note RPC; its preserve-note test description was updated. This is the intentional M2.3b.2b contract change, not weakened authorization coverage.
- The first new-suite run stopped on a missing quote in the test SQL after 39 passing assertions. The quote was fixed; the dedicated suite passed 96 and the complete rerun passed 664. The migration and production functions did not fail.
- Both integration harnesses passed: existing attendance 4 scenarios/26 assertions; new notes 5 scenarios/28 assertions. Each uses real overlapping transactions, proves lock waiting, removes only checked-new fictional fixture IDs, and restores the exact gate/table counts. No committed factory configuration is used.
- Note races cover save-before-preserve-checkout, checkout-before-late-save, concurrent active saves, identical final-note checkouts, and conflicting final-note checkouts. Rollback-only SQL tests additionally inject failure after the final update to verify rollback of the note, closure, event, evidence and stored receipt.
- Disk checks: C: free space was 12.43 GiB before startup, 9.82 GiB at the running-service check, and 11.90 GiB after shutdown; all checks stayed above the 5 GiB stop threshold. No images were pulled.
- Final database state: four migrations recorded, gate 1, all eight checked tables empty, temporary pgTAP removed. PostgreSQL stopped cleanly; Docker Desktop is stopped with the existing container/volume retained. Hosted development and Flutter are unchanged; Android was not retested.

## M2.3b.2a Validation Record (Historical)

- `supabase migration up --local` applied this migration without reset or image pulls. Subsequent local function-body updates hardened NULL-gate, missing-hash and missing-outcome handling without resetting the database. All final function bodies were compared with the migration, allowing Windows line endings only.
- `supabase test db`: 568 passing assertions across three suites: M2.1 70, M2.3b.1 71, M2.3b.2a 427. The original 141 assertions/files are unchanged. The new suite was also run separately to verify its count.
- `python -B supabase/tests/integration/m2_3b_2a_concurrency_test.py`: four real multi-connection scenarios, 26 passing assertions. Both workers were observed waiting at the employee lock before release. Same/different-key check-in and checkout races were tested.
- The first concurrency run passed its races but cleanup failed with SQLSTATE 42601 because `pg_get_functiondef` output needed a terminating semicolon. The harness was corrected, its own fixtures were verified and removed, and the entire test passed on rerun. No attendance migration or pgTAP assertion failed.
- The pgTAP configuration/cutover fixtures roll back. The concurrency harness commits only newly generated fictional IDs with no factory configuration, cleans only those IDs in `finally`, restores the exact original gate, and verifies all eight table counts return to their initial values.
- Disk checks: C: had 12.16 GiB free before database startup and 11.48 GiB at the final shutdown check; observed free space remained above the 5 GiB stop threshold. No images were pulled.
- State at the end of M2.3b.2a: three migrations recorded, gate 1, all eight checked tables empty, temporary pgTAP extension removed, database/Docker stopped with the existing volume retained. Hosted development is unchanged. Flutter and Android were not retested.

Tests cover location failures without automatic closure, quality/time boundaries, all nine arrival/departure combinations, review preservation, atomic rollback on evidence-write failure, semantic hash conflicts, policy/configuration replay, authorization/RLS, private helper ACLs, and future gate behavior. No production readiness is claimed.
