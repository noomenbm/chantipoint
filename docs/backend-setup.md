# ChantiPoint Backend Setup v0.1

This guide covers the deployed M2.1 baseline, M2.2/M2.3a client, and the locally validated M2.3b.1 foundations/M2.3b.2a gated attendance contract. The initial migration has been deployed to the hosted development project `chantipoint-dev`. See [Development Status](development-status.md) for completed checks, remaining implementation work, and release limitations.

## Current State

- Branch: `feature/manual-attendance`.
- The initial migration `20261013000100_initial_attendance_foundation.sql` is deployed to hosted `chantipoint-dev`; 70 local pgTAP tests passed.
- Flutter authentication is complete for M2.2; 62 automated Flutter tests and static analysis passed.
- The developer verified Android launch, hosted login, active employee profile/role recognition, logout, session restoration after task removal and Force stop, access removal on resume after profile disabling, and login after re-enabling the profile.
- The account used for hosted-development checks is fictional. The app's administrator provisioning and employee invitation workflow are not implemented.
- Public signup is disabled. V1 uses administrator-invited accounts.
- M2.3a factory check-in and checkout are implemented and developer-verified against hosted `chantipoint-dev`; external-worksite attendance and later administrator features remain pending. These checks do not establish production readiness.

Official Supabase guidance used for this slice:

- Supabase tracks schema changes through SQL files in `supabase/migrations/`.
- Database tests can be written as pgTAP SQL files under `supabase/tests/database/` and run with `supabase test db`.
- RLS policies should name the intended role and use authenticated identity checks such as `auth.uid()`.
- Security-definer functions need a fixed `search_path`, schema-qualified SQL, and explicit `execute` grants.

## Migration Order

The initial migration is already deployed to `chantipoint-dev`:

1. `supabase/migrations/20261013000100_initial_attendance_foundation.sql`

Additional migrations applied and validated locally; not deployed to hosted development:

2. `supabase/migrations/20261016000100_attendance_location_foundations.sql`
3. `supabase/migrations/20261017000100_attendance_v2_contract.sql` (applied/tested locally; legacy gate remains 1).

Keep the initial committed migration unchanged as the baseline. Future schema changes require new migrations, local validation, and explicit approval before hosted deployment.

This first migration creates only the minimal M2 foundation:

- `companies`
- `user_profiles`
- `role_assignments`
- `work_sessions`
- `session_events`
- `location_observations`
- `admin_audit_events`

Future tables for correction requests, anomaly review, reporting snapshots, retention automation, notifications, and production geofencing are intentionally deferred.

## M2.3b.1 Foundations and Compatibility

The new migration adds nullable `companies.factory_latitude numeric(9,6)`, `factory_longitude numeric(9,6)`, and `factory_radius_meters integer`. They must be all NULL or all present, with valid coordinate ranges and a positive radius. No actual coordinates, default coordinates, or production radius are seeded. Existing SELECT/RLS scope is retained; neither employees nor administrator clients gain direct configuration writes.

`work_sessions.location_context` additionally accepts `location_unverified`. `employee_note text` is nullable and limited to 1,000 characters; it is separate from site descriptions and event notes. The latest target is owner-authorized overwrite-only saves while active, a final edit atomic with manual checkout, and read-only after closure, without note versions/history/correction events. Note writes/UI are deferred to M2.3b.2b. No client write grant or note RPC is added.

The private observation validator no longer requires external_worksite. It still checks matching session/company/employee identity and active lifecycle on INSERT/UPDATE. Existing coordinate pairs, ranges, nonnegative accuracy, evidence foreign keys, RLS, and grants remain unchanged. Checkout evidence must be inserted before the transaction closes the session. The factory monitoring constraint stays: foreground fixes do not imply background monitoring.

Legacy `check_in`/`check_out` signatures, request hashes, writes, and six-field acknowledgements remain unchanged. They still reject factory GPS payloads and missing external check-in coordinates; `check_in` still rejects a client-supplied `location_unverified`. The current Flutter client also rejects that context. Do not introduce client-visible new-context sessions until M2.3b.2 coordinates revised RPCs and client parsing/recovery. The migration does not create a new client-authoritative classification path.

The approved target is server classification from foreground evidence, non-blocking location failures with `review_status` and technical `session_events.reason_code`, independent arrival/departure outcomes, and employee note updates. None of those revised workflows is implemented in M2.3b.1. Existing records are not relabeled as GPS-verified.

`checkout_source` and `checkout_reason_code` are retained. Removal of the latter requires a later migration after actual historical reasons and closure-event consistency have been audited.

Final-review local validation used the existing `supabase_db_chantipoint` volume and cached PostgreSQL 17.11 image, with only the database service started and initialization bypassed. Before application, migration history contained only `20261013000100`; all seven application tables and `auth.users` were empty. `supabase migration up --local` successfully applied only `20261016000100`. No reset, data/volume replacement, image pull, or hosted operation occurred.

`supabase/tests/database/m2_3b_1_location_foundations_test.sql` adds rollback-only coverage for configuration completeness/ranges, all contexts, note limits, observation identity/event/coordinate/accuracy/active-session guards, unchanged RPC acknowledgements, and client role/tenant boundaries. Its synthetic coordinates and radius are constraint fixtures only.

One assertion in `m2_1_attendance_foundation_test.sql` changes from rejecting a trusted factory observation to accepting it, because the external-only guard is intentionally removed. The independent legacy factory RPC/no-GPS assertions, idempotency tests, and existing authorization/audit coverage are retained. Final review did not alter either SQL test suite or the migration.

Actual final-review results from `supabase test db`, with separate per-file runs confirming the counts:

| Suite | Passed | Failed |
| --- | --- | --- |
| M2.1 attendance foundation | 70 | 0 |
| M2.3b.1 location foundations | 71 | 0 |
| Combined | 141 | 0 |

Post-validation inspection confirmed both migration versions are recorded, all eight checked tables remain empty after rollback-only tests, and the temporarily enabled pgTAP extension was removed by the CLI. PostgreSQL stopped cleanly; Docker Desktop is stopped. The database container and existing volume are retained with both migrations applied. Hosted `chantipoint-dev` remains on its previously deployed migration. Flutter/Android integration was not retested.

## M2.3b.2a Gated Attendance Contract

See [Attendance Backend Contract](attendance-backend-contract.md) for exact check_in_v2/check_out_v2 signatures, development thresholds, event/evidence storage, replay guarantees, cutover safeguards, and remaining client work. The new migration adds only bounded session_events.metadata and attendance/helper/compatibility functions. Both committed migrations, the original 141 tests, table-write restrictions, RLS and employee-note storage are unchanged.

Local validation passed all 568 pgTAP assertions: M2.1 70, M2.3b.1 71, M2.3b.2a 427. Four true concurrency scenarios passed 26 assertions. Final gate is 1, all eight checked tables are empty, and database/Docker resources are stopped with the existing volume retained. An initial concurrency-harness cleanup syntax error was corrected and its scoped fixtures removed before successful full reruns; no migration or pgTAP assertion failed. Hosted development is unchanged.

Do not enable v2 before upgrading Flutter and reconciling/draining legacy journals. The private gate is not client-settable; approved activation must acquire the exclusive transaction advisory lock (174811, 2). Legacy new check-in is blocked after cutover, accepted legacy keys replay, and legacy checkout remains available with unverified evidence. No factory configuration is seeded.

Repeat the separate integration test only against the deliberately started local database:

```powershell
python -B supabase/tests/integration/m2_3b_2a_concurrency_test.py
```

It temporarily enables v2 locally, commits fresh fictional fixtures without factory configuration for independent connections, restores the exact original gate and deletes only its own fixture IDs. It verifies all eight table counts afterward. Stop local resources after validation. No hosted deployment or cutover is authorized by these commands.

## Security Model

Supabase Auth remains the source of login identity. `user_profiles.auth_user_id` links each application user to `auth.users.id`.

V1 serves one employer, JMService. The `companies` table remains as an employer boundary for data integrity and future-proofing, but M2.1 does not add multi-company administration features or worksite management.

Application roles are held in `role_assignments`:

- `employee`
- `administrator`

Direct client writes to application tables are not granted. Authenticated users receive read access only where RLS permits it. Attendance mutations use the guarded legacy RPCs `public.check_in(...)` / `public.check_out(...)`, or the new v2 RPCs after an approved contract cutover.

Active employees can read their own attendance records. Revoking the employee role removes that employee-role access even if the profile remains active. Active administrators can read company-scoped historical records. Revoking the administrator role removes company-wide access; if the same person also has an active employee role, they keep only their own employee access. Disabled profiles lose protected attendance access. Anonymous users receive no table access.

Privileged helper functions live in the non-exposed `private` schema. The public RPC functions are security-definer functions because they must perform atomic writes while direct table writes stay blocked. They use `set search_path = ''`, schema-qualified references, ownership checks inside the function body, and grants only to `authenticated`.

The migration includes narrow administrative RPCs for role revocation and profile disabling so future account-management screens do not need direct table writes. Database triggers prevent normal administrative operations from revoking or disabling the last active administrator for a company, including self-revocation. Trusted recovery remains an operational bootstrap procedure, not a permanent application bypass.

Administrative role revocation and profile disabling append rows to `admin_audit_events` in the same database transaction as the privileged operation. Each audit row records the company, acting administrator profile, action, target profile or role assignment, server timestamp, and minimal JSON details such as the revoked role or previous profile status. Only active company administrators can read their company's audit rows through RLS. Authenticated employees receive no insert, update, or delete grants on the audit table, and an append-only trigger rejects direct update/delete attempts so audit records are not silently removed when a role is revoked or a profile is disabled.

## Attendance Operations

`check_in`:

- Requires an authenticated active employee role.
- Accepts `factory` or `external_worksite`.
- Uses server time as the authoritative session start.
- Stores device-observed time only as untrusted metadata when supplied.
- Creates the `work_sessions` row and the check-in `session_events` row in one transaction.
- Creates a `location_observations` row only for external-worksite check-ins with coordinates.
- Uses a client idempotency key and a database unique index for duplicate protection.
- Returns the original result for an exact retry, but rejects reuse of the same key with materially different request details.
- Rejects new sessions when the employer record is not `active`.
- Relies on a partial unique index to enforce one active session per employee under concurrent requests.

`check_out`:

- Requires an authenticated active employee role.
- Requires ownership of the target active session.
- Uses server time as the authoritative checkout time.
- Creates a manual checkout event.
- Closes the session as `closed_manual` with `checkout_source = 'manual'`.
- Supports idempotent retries.
- Returns the original result for an exact retry, but rejects reuse of the same key with materially different request details.
- Does not allow one employee, or an administrator acting through this employee RPC, to close another employee's session.
- Allows an authorized employee to safely check out an already-active session even if the employer has since become suspended.

Legacy attendance RPCs reject factory GPS/location payloads and create no factory observations. After the M2.3b.1 migration, trusted database operations may insert factory observations under the same identity, active-session, coordinate, and evidence constraints. External-worksite sessions can store check-in and checkout coordinates when provided.

Flutter retry behavior must reuse both the original idempotency key and the original request payload for a command. Retrying with the same key but changed command details is treated as a conflict, not as a replay.

## External-Worksite GPS-Unavailable Boundary

The approved target allows otherwise authorized attendance when GPS is unavailable or insufficient, with a technical event reason and review flag. Missing evidence never means verified factory attendance. The M2.3b.2a RPCs enforce this target behind the legacy-mode gate; Flutter acquisition and coordinated cutover remain pending.

Temporary M2.1 behavior: `check_in('external_worksite', ...)` requires coordinates. If no coordinates are supplied, the RPC raises `external_worksite_location_required_pending_policy`. This is an implementation boundary for review, not a final business decision.

The functioning M2.3a factory flow remains independent of GPS in this foundation stage; future foreground acquisition applies at both factory and external check-in/checkout, subject to client/privacy approval before real employee deployment.

## Local Prerequisites

- Flutter/Dart is required for app development.
- Supabase CLI and Docker are needed only for local database work and pgTAP validation. Hosted-development login does not require a local stack.
- On the 8 GB development computer, keep Docker and the emulator stopped unless needed; stop expensive operations if C: free space falls below 5 GB.

## Flutter Configuration

Pass `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` using `flutter run --dart-define` as shown in [Run the Flutter App](../README.md#run-the-flutter-app). These are compile-time Dart values; setting shell variables without forwarding them does not configure the app.

**Use the base Supabase project URL, such as `https://<project-ref>.supabase.co`, without `/rest/v1/` or any other API endpoint path.** Use the project's publishable client key. The existing code also accepts `SUPABASE_ANON_KEY` as a legacy fallback, but new run instructions use `SUPABASE_PUBLISHABLE_KEY`.

Never pass service-role keys, database passwords, or user access tokens to Flutter. Keep actual configuration values and all account credentials out of documentation and source control.

Business time is application-configured in `lib/src/config/business_time_config.dart` as `America/Montreal`; its French display label is separate. The shared `business_time.dart` module uses the installed IANA `latest_all.dart` data to resolve this alias and accepts explicit identifiers for future regions. Keep database/session timestamps in UTC; this display configuration does not require a migration or a hosted setting. Database-configurable company timezones are not implemented. Future monthly reports must derive calendar-month boundaries in the configured timezone with DST rules, convert those boundaries to UTC for filtering, and calculate elapsed durations from UTC instants.

## Invitation-Only Authentication

Public signup is disabled in hosted `chantipoint-dev`, and V1 uses administrator-invited accounts. Local `supabase/config.toml` also disables public signup with `auth.enable_signup = false` and `auth.email.enable_signup = false`; SMS signup is disabled too. Hosted Auth settings are managed separately: database deployment does not apply the local Auth configuration.

Current implementation:

- Flutter supports password login and logout for accounts already provisioned through trusted backend administration, with active profile/role authorization and session revalidation.
- The account used for hosted-development checks is fictional. Do not record its email, identifiers, password, or tokens here.
- Initial administrator provisioning, administrator-driven invitations, and account activation/credential-management screens are not implemented in the app.

Planned V1 account flow:

- Bootstrap the primary administrator through a controlled backend procedure, with no hardcoded identity or recovery credential.
- Let administrators invite employees through trusted backend functionality; employees activate invited accounts and manage their own credentials through Supabase Auth.
- Keep clients on user-scoped authentication, with no service-role credentials in Flutter.
- Use only fictional accounts in development.

## Local Validation Commands

For repeat local validation, first inspect the existing database and migration state. Once the database-only service is deliberately running, apply only pending local migrations without resetting data, then run all three pgTAP files:

```powershell
supabase migration up --local
supabase test db
```

These commands passed during M2.3b.2a validation (568 pgTAP assertions, zero failures); all three migrations are already applied locally. Do not reset the database without explicit approval. If it is stopped, use only already available local resources for a deliberate database-only start; do not pull images or start the full stack for this validation. Keep C: above the 5 GB threshold. Stop local services when finished, preserving the database volume.

Do not run `supabase link`, `supabase db push`, or any hosted mutation without explicit human approval for that operation.

## Future Hosted Dev Changes

The initial migration is already deployed. For future changes, after review and explicit approval:

1. Confirm the target is the intended development project, `chantipoint-dev`, and use only fictional test data.
2. Prepare a new versioned migration and validate it with the existing migrations and pgTAP suite against a disposable local database.
3. Check the intended project link and pending migration history before applying reviewed changes through the approved workflow.
4. Validate affected behavior using fictional development accounts. Review hosted Auth settings separately if authentication configuration changes are approved.

## Safe Provisioning Plan

The application administrator provisioning workflow is not implemented. Until a reviewed workflow exists, any explicitly approved initial provisioning must be performed only by a trusted backend operator using Supabase Dashboard SQL, a reviewed migration/seed for non-production, or a future controlled admin-provisioning function. The mobile and web clients must never receive service-role credentials.

The company must always retain at least one active administrator. If ordinary admin operations accidentally remove every administrator or the primary administrator loses access, recovery should use trusted Supabase/backend administration after identity verification and audit logging. Do not create a hidden permanent bypass account or hardcoded recovery credential.

For future development-account provisioning, when explicitly approved:

- Create fictional Supabase Auth users.
- Insert matching `user_profiles`.
- Assign the first administrator through a controlled SQL operation.
- Assign employee roles for fictional employee users.
- Verify that employees cannot create profiles, change company IDs, or assign roles.

For production:

- Use employer-approved employee identity data.
- Keep an audit trail of administrator creation and role changes.
- Disable or archive departed employees instead of deleting attendance history.
- Review active work sessions before disabling an employee profile; M2.1 does not yet implement an administrator closure/review workflow for sessions that remain active at disable time.

## RLS Verification Checklist

With the reviewed migrations applied to the verified local database without a reset, run the database tests:

```powershell
supabase test db
```

The tests cover:

- Factory check-in and checkout without GPS.
- Multiple sessions in one day.
- Rejection of simultaneous active sessions.
- Idempotent check-in and checkout retries.
- Conflicting idempotency-key reuse.
- Database-level active-session protection for concurrent attempts.
- Employee A cannot read or modify Employee B's data.
- Employees cannot self-assign administrator.
- Revoked employee roles losing attendance access.
- Revoked administrators losing company-wide access.
- Disabled profiles losing protected attendance access.
- Active administrators retaining historical access for former employees.
- Administrative audit rows for role revocation and profile disabling.
- Employees and revoked or disabled users being unable to read or forge administrative audit records.
- Append-only protection for administrative audit records.
- Suspended employers rejecting new sessions while allowing authorized checkout of existing active sessions.
- Last-active-administrator revocation and disablement protection.
- Anonymous users cannot read attendance records.
- Administrator company scoping.
- Trusted factory observations are accepted after M2.3b.1, while legacy factory RPCs still acquire/create no GPS evidence.
- Factory configuration is nullable/all-or-none, range-checked, and protected from client writes.
- All three schema contexts and nullable/1,000-character employee notes are covered.
- Observation identity, event linkage, coordinate, accuracy, active-session, and role/tenant protections remain covered.
- External-worksite check-in and checkout can record location observations.
- Unauthorized checkout attempts.

## Open Decisions

- Production approval of evidence-quality, boundary and freshness thresholds; conservative development rules are implemented in the gated M2.3b.2a backend.
- Coordinated client support for the implemented independent arrival/departure outcome and reason contracts; the gated backend permits otherwise authorized checkout with insufficient location.
- Coordinated client/RPC cutover and existing version-1 pending-command recovery.
- M2.3b.2b owner-authorized overwrite-only notes, including atomic final checkout edit without note history/versions; historical checkout_reason_code cleanup audit remains separate.
- Formal administrator provisioning workflow and audit requirements.
- Administrator closure/review workflow when a profile is disabled while the employee has an active work session.
- Correction-request, anomaly, retention, notification, and reporting schemas.
- Future admin correction/import operations need explicit validation for historical overlapping intervals; M2.1 enforces one active session and the RPC flow creates sequential sessions.
- Production geofencing, automatic checkout, and real-device background reliability.
- Retention periods by data category.
