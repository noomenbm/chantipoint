# M2.3b.2a Attendance Backend Contract

Implemented in `20261017000100_attendance_v2_contract.sql`, after both existing migrations. Applied and tested locally only. Hosted `chantipoint-dev` is unchanged. The deployment gate remains **legacy mode (1)**; new v2 writes require a separately approved cutover. Flutter remains on its current GPS-free factory workflow.

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
  p_replay_only boolean default false
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

New RPCs lock the authenticated profile, active employee role, company and target session in that order. The profile lock serializes attendance per employee; existing unique indexes remain the final protection. Disabled/revoked employees cannot replay protected data. A suspended company blocks new check-in while authorized checkout of an existing session remains possible.

V2 request hashes include protocol/operation, resolved employee/company, target session, normalized submitted description, original action/fix times, coordinates, accuracy, provider and diagnostic values. They exclude the operational replay flag, current policy/configuration, derived outcome and server timestamps. Numeric tokens remove insignificant scale; timestamp tokens use epoch microseconds. Invalid evidence is hashed before sanitizing its stored representation.

A replay-only request must carry the complete original semantic payload. Missing or changed evidence/diagnostics conflicts with the stored hash. Missing stored hashes fail closed; an unavailable original outcome raises `attendance_receipt_unavailable` instead of being reconstructed. Matching receipts are returned before freshness evaluation or new-write gating, preserving the original event, classification and policy after configuration changes, policy changes, or subsequent checkout. Current session lifecycle/review fields may have advanced. There is no GPS reacquisition or evidence regeneration on replay.

The original v1 bodies are relocated to private functions without changing their hashing semantics. No client can execute them directly. V1 hashes retain their original timestamp serialization; do not apply v2 canonicalization to legacy commands.

Expected errors retain stable machine messages: `authentication_required`, `employee_role_required`, `company_not_active`, `active_session_not_found_for_employee`, `active_session_exists`, `session_not_active`, `idempotency_key_conflict`, `invalid_idempotency_key`, `invalid_attendance_request`, `attendance_contract_not_enabled`, and `attendance_client_update_required`. Future Flutter code must map these to safe French messages, without exposing raw database exceptions.

## Gate and Legacy Compatibility

`private.attendance_write_contract()` is initially 1 and cannot be executed/replaced by clients. It reads no client-controlled setting. Unexpected NULL/non-v2 values fail closed for new v2 writes.

Every attendance writer takes shared transaction advisory lock `(174811, 2)`. A future trusted cutover must take the exclusive transaction lock with the same key before replacing the gate in the same transaction. This drains writers that entered through the guarded wrappers before activating v2. Calls started before this migration installed those wrappers must already have completed; plan operational quiescence and reconcile old journals before cutover. This document does not authorize activation or hosted deployment.

- Mode 1: legacy public signatures, default arguments, writes and six-field responses remain functional; new v2 writes are rejected.
- Mode 2: existing legacy check-in keys still hash-check and replay; new legacy check-ins are rejected for both supplied contexts.
- Mode 2: legacy checkout remains possible, with a new unverified departure event carrying `legacy_location_evidence`; it never claims v2-quality GPS verification. Its original hashing and six-field response remain available for retries.
- There is one public signature for each attendance endpoint. Private implementations/helpers deny PUBLIC, anon and authenticated execution. No client table-write permissions or RLS scope are widened.

Flutter still cannot parse `location_unverified`, accept factory names during reconciliation, persist GPS in journal version 1, or check out all contexts. Upgrade those paths and reconcile/drain old journals before cutover. Do not blindly convert, discard or resubmit an old pending command with a new payload/key. Real-location journals need strict version/owner/environment binding, device-protected encryption, backup/log exclusion and an approved retention/recovery policy before real employee use. No such client changes are implemented here.

## Employee Note Boundary

The approved note is general business/work-session text, maximum 1,000 characters. Future active-session saves overwrite the previous value without history. The employee can make a final edit atomically with manual checkout, after which the final note is read-only. No note versions, correction events, audit/revision metadata or history tables are planned. Ownership and active-session checks remain required. Future checkout must distinguish preserve/clear/replace and coordinate its request hash and client journal contract.

M2.3b.2a does not implement note writes or alter existing note values. M2.3b.2b and Flutter integration remain separate work.

## Actual Local Validation

- `supabase migration up --local` applied this migration without reset or image pulls. Subsequent local function-body updates hardened NULL-gate, missing-hash and missing-outcome handling without resetting the database. All final function bodies were compared with the migration, allowing Windows line endings only.
- `supabase test db`: 568 passing assertions across three suites: M2.1 70, M2.3b.1 71, M2.3b.2a 427. The original 141 assertions/files are unchanged. The new suite was also run separately to verify its count.
- `python -B supabase/tests/integration/m2_3b_2a_concurrency_test.py`: four real multi-connection scenarios, 26 passing assertions. Both workers were observed waiting at the employee lock before release. Same/different-key check-in and checkout races were tested.
- The first concurrency run passed its races but cleanup failed with SQLSTATE 42601 because `pg_get_functiondef` output needed a terminating semicolon. The harness was corrected, its own fixtures were verified and removed, and the entire test passed on rerun. No attendance migration or pgTAP assertion failed.
- The pgTAP configuration/cutover fixtures roll back. The concurrency harness commits only newly generated fictional IDs with no factory configuration, cleans only those IDs in `finally`, restores the exact original gate, and verifies all eight table counts return to their initial values.
- Disk checks: C: had 12.16 GiB free before database startup and 11.48 GiB at the final shutdown check; observed free space remained above the 5 GiB stop threshold. No images were pulled.
- Final local state: three migrations recorded, gate 1, all eight checked tables empty, temporary pgTAP extension removed, database/Docker stopped with the existing volume retained. Hosted development is unchanged. Flutter and Android were not retested.

Tests cover location failures without automatic closure, quality/time boundaries, all nine arrival/departure combinations, review preservation, atomic rollback on evidence-write failure, semantic hash conflicts, policy/configuration replay, authorization/RLS, private helper ACLs, and future gate behavior. No production readiness is claimed.
