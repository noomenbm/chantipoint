# ChantiPoint Backend Setup v0.1

This guide covers the local Supabase database foundation prepared for M2.1. It is a review artifact: do not apply it to `chantipoint-dev` until the migration and tests have been reviewed.

## Current State

- Branch: `feature/manual-attendance`.
- Supabase CLI v2.120.0 is available locally and `supabase/config.toml` has been created with `supabase init`.
- The migration and tests were created manually under the standard `supabase/` directory before applying them to the local stack.
- No hosted Supabase project was linked or modified.
- No application code, real employee accounts, secrets, or Supabase resources were changed.

Official Supabase guidance used for this slice:

- Supabase tracks schema changes through SQL files in `supabase/migrations/`.
- Database tests can be written as pgTAP SQL files under `supabase/tests/database/` and run with `supabase test db`.
- RLS policies should name the intended role and use authenticated identity checks such as `auth.uid()`.
- Security-definer functions need a fixed `search_path`, schema-qualified SQL, and explicit `execute` grants.

## Migration Order

Apply migrations in filename order:

1. `supabase/migrations/20261013000100_initial_attendance_foundation.sql`

This first migration creates only the minimal M2 foundation:

- `companies`
- `user_profiles`
- `role_assignments`
- `work_sessions`
- `session_events`
- `location_observations`
- `admin_audit_events`

Future tables for correction requests, anomaly review, reporting snapshots, retention automation, notifications, and production geofencing are intentionally deferred.

## Security Model

Supabase Auth remains the source of login identity. `user_profiles.auth_user_id` links each application user to `auth.users.id`.

V1 serves one employer, JMService. The `companies` table remains as an employer boundary for data integrity and future-proofing, but M2.1 does not add multi-company administration features or worksite management.

Application roles are held in `role_assignments`:

- `employee`
- `administrator`

Direct client writes to application tables are not granted. Authenticated users receive read access only where RLS permits it. Attendance mutations go through the RPC functions `public.check_in(...)` and `public.check_out(...)`.

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

Factory sessions reject GPS/location payloads and cannot receive `location_observations`. External-worksite sessions can store check-in and checkout coordinates when provided.

Flutter retry behavior must reuse both the original idempotency key and the original request payload for a command. Retrying with the same key but changed command details is treated as a conflict, not as a replay.

## External-Worksite GPS-Unavailable Boundary

The business policy for external-worksite check-in when GPS is unavailable is unresolved. This migration does not silently approve or silently treat missing GPS as verified attendance.

Temporary M2.1 behavior: `check_in('external_worksite', ...)` requires coordinates. If no coordinates are supplied, the RPC raises `external_worksite_location_required_pending_policy`. This is an implementation boundary for review, not a final business decision.

Factory attendance remains independent of GPS permissions and availability.

## Local Prerequisites

Install later, outside this task:

- Supabase CLI
- Docker or a Docker-compatible local runtime
- Flutter/Dart tooling for later app work

Environment variable names that may be needed later:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_DB_PASSWORD`

Do not commit service-role keys or access tokens.

## Invitation-Only Authentication

Local `supabase/config.toml` disables public signup with `auth.enable_signup = false` and `auth.email.enable_signup = false`. SMS signup is also disabled. Hosted Supabase Auth settings must be reviewed separately before applying migrations; do not assume the local config has changed `chantipoint-dev`.

Account flow for V1:

- The trusted primary administrator is bootstrapped through a controlled Supabase/backend procedure.
- Jamel is the intended primary administrator for JMService, but the database does not hardcode his identity or credentials.
- Administrators invite employee accounts using trusted admin/backend functionality.
- Employees activate invited accounts and set or reset their own credentials through Supabase Auth.
- Mobile and web clients use user-scoped credentials only; never embed service-role keys in Flutter clients.
- Development test users must be fictional and created locally or through reviewed non-production procedures.

## Local Validation Commands

After installing the Supabase CLI and Docker:

```powershell
supabase start --exclude gotrue,realtime,storage-api,imgproxy,kong,mailpit,postgrest,postgres-meta,studio,edge-runtime,logflare,vector,supavisor
supabase db reset
supabase test db
```

The long `--exclude` list starts only the local database container needed for migrations and pgTAP tests.

Do not run `supabase link`, `supabase db push`, or any remote mutation until the human developer approves the reviewed migration.

## Hosted Dev Apply Procedure

After review only:

1. Confirm the target project is the intended development project, `chantipoint-dev`.
2. Confirm no real employee data is present.
3. Link the project locally with the Supabase CLI.
4. Apply migrations to the development project through the approved Supabase workflow.
5. Run the RLS and attendance tests against a disposable local database first; remote validation should use fictional accounts only.

## Safe Provisioning Plan

Initial administrator provisioning should be performed only by a trusted backend operator using Supabase Dashboard SQL, a reviewed migration/seed for non-production, or a future controlled admin-provisioning function. The mobile and web clients must never receive service-role credentials.

The company must always retain at least one active administrator. If ordinary admin operations accidentally remove every administrator or the primary administrator loses access, recovery should use trusted Supabase/backend administration after identity verification and audit logging. Do not create a hidden permanent bypass account or hardcoded recovery credential.

For development testing:

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

Run the prepared database tests after a local reset:

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
- Factory sessions cannot create location observations.
- External-worksite check-in and checkout can record location observations.
- Unauthorized checkout attempts.

## Open Decisions

- Final policy when GPS is unavailable during external-worksite check-in.
- Whether external-worksite checkout location is mandatory, optional, or unavailable-tolerant.
- Formal administrator provisioning workflow and audit requirements.
- Administrator closure/review workflow when a profile is disabled while the employee has an active work session.
- Correction-request, anomaly, retention, notification, and reporting schemas.
- Future admin correction/import operations need explicit validation for historical overlapping intervals; M2.1 enforces one active session and the RPC flow creates sequential sessions.
- Production geofencing, automatic checkout, and real-device background reliability.
- Retention periods by data category.
