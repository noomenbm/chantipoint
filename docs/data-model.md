# ChantiPoint Logical Data Model v0.1

This document defines the initial logical model only. It is not a SQL migration, Supabase schema, or final database design.

## Design Principles

- Keep employees, roles, sessions, events, observations, monitoring status, review status, corrections, retention, and audit history separate.
- Store timestamps in UTC and display business time in America/Toronto.
- Preserve device-observed timestamps, callback/receipt timestamps, and server-accepted timestamps separately.
- Record GPS accuracy where available for external-worksite location evidence.
- Support factory/company-premises sessions without GPS coordinates or location observations.
- Avoid unnecessary location history and exclude detailed location trails from routine CSV exports.
- Preserve enough history to review departures, returns, automatic closures, corrections, and administrative changes.
- Calculate attendance reports from validated sessions and approved corrections rather than manually maintained duplicate totals.
- Enforce authorization server-side with RLS and privileged server operations where needed.

## Status Separation

Three concepts must not share one overloaded field:

| Concept | Stored On | Purpose |
| --- | --- | --- |
| Session lifecycle status | `work_sessions.lifecycle_status` | Whether the session is active or closed and how it closed. |
| Review/correction status | `work_sessions.review_status`, `correction_requests.status`, `session_anomalies.status` | Whether the session or request needs human review. |
| Monitoring availability/status | `work_sessions.current_monitoring_status`, `monitoring_status_events.status` | Whether location verification is applicable, available, disabled, inconclusive, or stopped. |

## Circular Reference Approach

`work_sessions` should be the aggregate root. `session_events` should reference `work_sessions`, not the other way around with mandatory cyclic foreign keys.

Implementation approach:

- Create the `work_sessions` row and its check-in `session_events` row in one transaction.
- Use `session_events.event_type` to identify check-in, checkout, automatic checkout, monitoring, notification, and correction events.
- Keep denormalized summary fields on `work_sessions` for query performance, such as `started_at`, `ended_at`, `checkout_source`, `lifecycle_status`, and `review_status`.
- Avoid mandatory `check_in_event_id` / `check_out_event_id` references from `work_sessions` to `session_events` in the first schema.
- If direct event references are later needed, add nullable or deferred references only after the basic event stream is stable.

## Entities

### `companies`

Represents the initial employer account and keeps future multi-company isolation possible.

| Field | Notes |
| --- | --- |
| `id` | Stable company identifier. |
| `name` | Employer name. |
| `status` | Active, suspended, archived. |
| `created_at`, `updated_at` | Server timestamps in UTC. |

### `user_profiles`

Represents application users tied to authentication identities.

| Field | Notes |
| --- | --- |
| `id` | Stable profile identifier. |
| `auth_user_id` | Supabase Auth user reference. |
| `company_id` | Company scope. |
| `employee_number` | Optional employer employee ID. |
| `display_name` | Employee-visible name. |
| `email` | Login/contact email. |
| `status` | Active, disabled, invited, or archived. |
| `created_at`, `updated_at` | Server timestamps in UTC. |

### `role_assignments`

Defines access rights.

| Field | Notes |
| --- | --- |
| `id` | Stable role assignment identifier. |
| `user_profile_id` | User profile reference. |
| `role` | `employee` or `administrator` for V1. |
| `company_id` | Company scope. |
| `status` | Active or revoked. |
| `created_at`, `created_by` | Audit-friendly metadata. |

V1 starts with one designated administrator, but this table allows additional authorized administrators later.

### `work_sessions`

Represents one declared work period at one workplace.

| Field | Notes |
| --- | --- |
| `id` | Stable session identifier. |
| `employee_profile_id` | Employee who owns the session. |
| `company_id` | Company scope. |
| `lifecycle_status` | Active, closed_manual, closed_automatic, closed_admin, voided. |
| `review_status` | Normal, anomaly_open, correction_pending, reviewed, corrected, disputed. |
| `current_monitoring_status` | Not applicable, pending, enabled, disabled_detected, permission_revoked_detected, unavailable, inconclusive, stopped. |
| `location_context` | Factory/company premises, external worksite, or unspecified for legacy/admin-repair cases. |
| `site_description` | Optional employee-entered workplace/project description. |
| `started_at` | Server-accepted session start time in UTC. |
| `ended_at` | Server-accepted session end time in UTC, nullable while active. |
| `checkout_source` | Manual, automatic, administrator correction, or null while active. |
| `checkout_reason_code` | Optional reason such as manual, geofence_exit_persisted, permission_revoked_detected, location_disabled_detected, admin_correction. |
| `automatic_checkout_evidence_summary` | Nullable short summary for administrator review. |
| `created_at`, `updated_at` | Server timestamps in UTC. |

Integrity rule: one employee must not have more than one active session at a time.

Factory/company-premises sessions must be valid without GPS coordinates and should use monitoring status semantics equivalent to not applicable. External-worksite sessions may have check-in/check-out observations and later geofence evidence when approved.

### `session_events`

Auditable event stream for each work session.

| Field | Notes |
| --- | --- |
| `id` | Stable event identifier. |
| `work_session_id` | Session reference. |
| `event_type` | Check-in, manual checkout, automatic checkout, admin closure, geofence exit, geofence enter, monitoring status, eight-hour notification, correction, report export, or similar. |
| `source` | Employee app, admin app, system, backend, or platform callback. |
| `device_observed_at` | Device timestamp when applicable. |
| `callback_received_at` | App/backend callback or receipt timestamp when applicable. |
| `server_accepted_at` | Server timestamp when the state change is accepted. |
| `actor_profile_id` | User who caused the event, nullable for system or platform events. |
| `reason_code` | Machine-readable reason. |
| `notes` | Short reason or context where appropriate. |
| `idempotency_key` | Optional duplicate-protection key for command events. |

### `location_observations`

Minimized location evidence associated with a session event or monitoring state.

| Field | Notes |
| --- | --- |
| `id` | Stable observation identifier. |
| `work_session_id` | Session reference. |
| `session_event_id` | Optional event reference. |
| `observation_type` | Check-in location, checkout location, geofence exit, geofence enter, periodic observation, unavailable. |
| `latitude`, `longitude` | Nullable when unavailable. |
| `accuracy_meters` | Nullable if not provided. |
| `geofence_radius_meters` | Radius used for geofence evidence, such as 100 or 150 meters. |
| `provider` | GPS, network, fused, geofence, platform event, emulator, or unknown. |
| `device_observed_at` | Device timestamp when applicable. |
| `callback_received_at` | Callback or app/backend receipt timestamp when applicable. |
| `server_received_at` | Server receipt timestamp in UTC. |
| `raw_metadata` | Limited diagnostic metadata, only if needed and approved. |

Location observations are not route tracking and should be collected only during active external-worksite sessions or approved verification workflows. Factory/company-premises sessions should not create location observations. If GPS is unavailable at external-worksite check-in, the record can represent that unavailability only after the business rule is approved; missing GPS must not be silently interpreted as verified attendance or automatic refusal.

### `monitoring_status_events`

Tracks whether on-duty verification is available.

| Field | Notes |
| --- | --- |
| `id` | Stable status event identifier. |
| `work_session_id` | Session reference. |
| `status` | Not applicable, pending, enabled, disabled_detected, permission_revoked_detected, unavailable, delayed, inconclusive, stopped. |
| `reason_code` | Machine-readable reason. |
| `device_observed_at` | Device timestamp when applicable. |
| `callback_received_at` | Callback or app/backend receipt timestamp when applicable. |
| `server_received_at` | Server receipt timestamp in UTC. |
| `details` | Short human-readable context. |

### `session_anomalies`

Highlights conditions requiring review.

| Field | Notes |
| --- | --- |
| `id` | Stable anomaly identifier. |
| `work_session_id` | Session reference. |
| `anomaly_type` | Prolonged departure, automatic checkout, monitoring unavailable, long active session, missing checkout, conflicting evidence. |
| `severity` | Low, medium, high, or review_required. |
| `status` | Open, reviewed, resolved, dismissed. |
| `created_at`, `resolved_at` | Server timestamps in UTC. |

### `correction_requests`

Employee-submitted request to correct inaccurate or missing punches.

| Field | Notes |
| --- | --- |
| `id` | Stable request identifier. |
| `employee_profile_id` | Requesting employee. |
| `work_session_id` | Nullable if the session is missing. |
| `requested_change_type` | Add checkout, adjust time, add missing session, revise description, or other approved type. |
| `requested_start_at`, `requested_end_at` | Proposed corrected timestamps where applicable. |
| `employee_reason` | Employee explanation. |
| `status` | Submitted, approved, rejected, needs_information, cancelled. |
| `reviewed_by`, `reviewed_at` | Administrator review metadata. |
| `review_notes` | Administrator decision reason. |

### `admin_decisions`

Records administrator decisions about disputed, unusual, or automatically closed sessions.

| Field | Notes |
| --- | --- |
| `id` | Stable decision identifier. |
| `work_session_id` | Session reference. |
| `correction_request_id` | Nullable correction request reference. |
| `administrator_profile_id` | Decision maker. |
| `decision_type` | Confirm automatic checkout, approve correction, reject correction, mark reviewed, adjust session, or similar. |
| `decision_reason` | Human-readable reason. |
| `created_at` | Server timestamp in UTC. |

Administrator-generated records about identifiable employees are still personal information and require approved retention rules.

### Monthly attendance report calculation

The V1 monthly employee-hours report should be calculated from `work_sessions`, approved `correction_requests`, `admin_decisions`, and relevant `session_events`.

Calculation rules:

- Filter and display by America/Toronto business time while storing timestamps in UTC.
- Include completed sessions and approved corrections.
- Support multiple sessions per day.
- Allocate only the portion of a session that falls inside the selected calendar month.
- Flag incomplete, disputed, and administratively corrected sessions.
- Avoid double-counting corrected sessions by using one approved effective interval per session for reporting.
- Do not calculate wages, taxes, payroll submission, automatic overtime, or unapproved break deductions.

If the client later requires formal monthly approval, an approved summary or snapshot can be added to preserve the calculation result after detailed GPS evidence expires. Such a snapshot should reference the source records and approval decision rather than replacing the underlying audit trail.

### `audit_log`

Security and administrative audit trail.

| Field | Notes |
| --- | --- |
| `id` | Stable audit entry identifier. |
| `actor_profile_id` | User or system actor. |
| `action` | Created employee, changed role, approved correction, exported CSV, closed session, changed retention rule, etc. |
| `target_type`, `target_id` | Record affected. |
| `company_id` | Company scope. |
| `created_at` | Server timestamp in UTC. |
| `metadata` | Minimal structured context. |

### `retention_policies`

Logical representation of retention rules once approved.

| Field | Notes |
| --- | --- |
| `id` | Stable policy identifier. |
| `data_category` | Raw location observations, work sessions, monthly attendance summaries, correction requests, administrator decisions, security/audit logs, backups. |
| `retention_days` | Nullable until approved. |
| `policy_status` | Draft, approved, retired. |
| `approved_by`, `approved_at` | Approval metadata when available. |

## Relationships

- One `company` has many `user_profiles`, `role_assignments`, and `work_sessions`.
- One `user_profile` can have one or more `role_assignments`.
- One employee `user_profile` can have many `work_sessions`.
- One `work_session` can have many `session_events`, `location_observations`, `monitoring_status_events`, `session_anomalies`, `correction_requests`, and `admin_decisions`.
- One `correction_request` can create additional `session_events`, `admin_decisions`, and `audit_log` entries.
- `session_events` and `location_observations` are child evidence records, not mandatory parents of `work_sessions`.

## Integrity and Security Rules

- Reject overlapping active sessions per employee.
- Use server-side role checks for administrator access.
- Use RLS policies to prevent employees from reading other employees' location data.
- Require idempotency or duplicate protection for check-in, checkout, location event, notification, and correction commands.
- Preserve original records when corrections are approved.
- Do not store Supabase service-role credentials in mobile or web clients.
- Stop creating location observations after a session is closed.
- Do not create location observations for factory/company-premises sessions.
- Treat unavailable location as a recorded status, not as absence.
- Exclude detailed location trails from routine CSV exports.
- Calculate monthly attendance totals from validated session intervals and approved corrections.

## Retention Design

Retention must be approved by business/legal stakeholders before production monitoring:

| Data Category | Candidate Rule |
| --- | --- |
| Raw location observations | Configurable period pending business/legal approval; no universal 30-day deletion rule is approved. |
| Work sessions | Pending business/legal validation; must support historical attendance reporting. |
| Monthly attendance summaries | Pending business/legal validation; may need preservation after detailed GPS evidence expires. |
| Correction requests | Pending business/legal validation. |
| Administrator decisions | Pending business/legal validation; not assumed indefinite. |
| Security/audit logs | Pending business/legal validation. |
| Backups | Pending operational and legal validation. |

## CSV Export Scope

Routine CSV exports should provisionally include:

- Employee ID and name.
- Session ID.
- Optional site description.
- Check-in and check-out time.
- Duration.
- Checkout source.
- Session lifecycle status.
- Review status.
- Work location context.

Routine exports should exclude detailed GPS/geofence trails unless a later approved export process specifically authorizes them.

Monthly employee-hours CSV exports should include employee identity fields, selected month/year, total hours and minutes, and flags for incomplete, disputed, or corrected sessions.

## Open Data Decisions

- Final retention period for each data category.
- Exact automatic checkout evidence schema after feasibility testing.
- Whether `company_id` remains explicit in every table for future tenant isolation.
- How much diagnostic metadata can be stored without exceeding data minimization goals.
- Whether monthly attendance summaries require formal administrator approval before preservation.
- Final lunch/break handling and whether unpaid break deductions are part of attendance reporting.
- Backup retention and deletion workflow.

## Related Documents

- [Requirements](requirements.md)
- [Architecture](architecture.md)
- [Security and Privacy](security-privacy.md)
