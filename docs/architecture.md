# ChantiPoint Architecture v0.1

This document describes the proposed technical architecture for ChantiPoint before feature development. It is a planning artifact, not an implementation record or signed specification.

## Goals

- Support a French-language, single-company attendance and worksite-presence verification workflow.
- Keep security and privacy controls server-enforced.
- Prioritize Android development while preserving a later iOS path.
- Move geofencing feasibility forward before major administrator-application investment.
- Keep the data access layer modular enough for possible future offline support.
- Avoid unnecessary infrastructure for one developer working approximately 5-7 hours per week.

## System Components

| Component | Candidate Technology | Responsibility |
| --- | --- | --- |
| Employee mobile app | Flutter and Dart | Authentication, manual check-in/out, active-session status, monitoring status, eight-hour notification, correction requests. |
| Administrator app | Flutter Web | Employee management, session review, map review, anomaly review, automatic checkout review, correction approval, CSV export. |
| Feasibility prototype | Isolated Android prototype using emulator simulated GPS | Validate geofence registration, exit/return events, candidate radii, delayed callback handling, simulated grace period, and cleanup before production investment. |
| Authentication | Supabase Auth | User identity and session authentication after project approval. |
| Database | Supabase PostgreSQL | Durable records for profiles, roles, sessions, events, correction requests, retention metadata, and audit history. |
| Authorization | PostgreSQL Row Level Security and server-side operations | Enforce employee/admin access rules and protect location data. |
| Secure operations | Supabase Edge Functions or Postgres RPC where appropriate | Idempotent session commands, automatic closure candidates, exports, and privileged administrative operations. |

## Approval Boundaries

- Developer-reported requirements can guide planning but do not equal signed client approval.
- Proposed technical designs, including geofencing and automatic checkout, require feasibility results and explicit approval before production use.
- No real employee monitoring may begin before privacy, security, platform, and client release gates are satisfied.
- The private feasibility prototype must use emulator or test data only.

## Security Boundaries

- Flutter clients must never contain Supabase service-role credentials.
- Clients may request operations, but the backend must enforce who can read, create, update, close, correct, and export records.
- Employees can access their own sessions and correction requests.
- One designated administrator initially can access employee records for the company.
- The role model should allow additional authorized administrators later without redesigning access control.
- Location records are sensitive and require least-privilege access, audit logging, and retention rules.
- CSV exports are controlled administrative actions and exclude detailed location trails by default.

## Logical API Boundaries

The exact Supabase implementation can use RPC, Edge Functions, or direct table operations protected by RLS. The logical command boundary should remain stable:

| Operation | Purpose | Notes |
| --- | --- | --- |
| `checkIn` | Start a work session after server validation. | Requires authenticated employee, location payload, optional description, and idempotency key. |
| `checkOut` | Manually close an active session. | Records checkout source as manual and stops monitoring. |
| `recordLocationEvent` | Store geofence or location-verification evidence. | Used only during an active session and subject to minimization and retention rules. |
| `recordMonitoringStatus` | Store monitoring enabled, disabled, unavailable, delayed, or stopped status. | Does not automatically prove absence. |
| `evaluateAutomaticCheckout` | Server-side evaluation of approved automatic checkout rules. | Disabled until feasibility and approval gates pass. |
| `notifyEightHourSession` | Notify an employee after eight hours of an active session. | Offers `Terminer la session` and `Continuer la session`; no automatic checkout solely from timeout. |
| `requestCorrection` | Employee submits a correction request. | Does not alter original history directly. |
| `resolveCorrection` | Administrator approves or rejects a request. | Creates audit history and adjusted session facts if approved. |
| `listSessions` | Review sessions by employee and date. | Admin scoped; employee scoped for self-view. |
| `exportSessionsCsv` | Export basic operational records. | Includes employee ID/name, session ID, site description, times, duration, checkout source, session status, and review status. |

## Status Model

Separate statuses avoid overloading a single field:

| Status Type | Example Values | Purpose |
| --- | --- | --- |
| Session lifecycle status | `active`, `closed_manual`, `closed_automatic`, `closed_admin`, `voided` | Describes whether the work session is active or closed and how it closed. |
| Review status | `normal`, `anomaly_open`, `correction_pending`, `reviewed`, `corrected`, `disputed` | Describes human review and correction workflow. |
| Monitoring status | `pending`, `enabled`, `disabled_detected`, `permission_revoked_detected`, `unavailable`, `inconclusive`, `stopped` | Describes whether on-duty verification can provide evidence. |

## Session Lifecycle

Proposed lifecycle:

| State | Meaning |
| --- | --- |
| `no_active_session` | Employee has no active session. |
| `check_in_pending` | Client is submitting check-in and waiting for server acknowledgement. |
| `active_monitoring_pending` | Session is active; monitoring is being configured. |
| `active_monitoring_enabled` | Session is active and monitoring appears available. |
| `active_monitoring_unavailable` | Session is active, but monitoring cannot currently provide reliable evidence. |
| `exit_observed_grace` | Exit evidence was received and the candidate 10-minute grace period is in progress. |
| `auto_checkout_candidate` | Evidence may support automatic closure, pending approved server rules. |
| `closed_manual` | Employee manually checked out. |
| `closed_automatic` | System closed the session under approved and tested rules. |
| `closed_admin` | Administrator closed or corrected the session with audit history. |

Correction requests and review statuses are modeled separately so original session history remains auditable.

## Automatic Checkout Evidence Rules

Automatic checkout remains proposed. Before production use, rules must be approved and tested. Minimum evidence principles:

- The session must be active.
- Monitoring must have been enabled or a monitoring status must explain why evidence is incomplete.
- Exit evidence must be tied to the session and include source, device-observed time, callback or receipt time, server accepted time where applicable, and accuracy or platform metadata.
- The candidate grace period is 10 minutes after the application/backend receives reliable exit evidence, not 10 minutes after physical departure.
- A single low-accuracy GPS point must not close a session.
- If return evidence arrives during the approved rule window, the session remains active and both departure and return are retained.
- If location services are disabled or permission is revoked and reliable detection occurs, the approved closure procedure records that reason.
- If evidence is missing, delayed, contradictory, or unavailable, the session is marked inconclusive or for review rather than silently inferring absence.
- No checkout timestamp may be fabricated. The chosen timestamp rule must be explicit, auditable, and approved.
- Automatic closure must notify the employee and require a new manual check-in if work resumes.

## Data Flow

### Check-In

1. Employee authenticates.
2. Client obtains location and optional site description.
3. Client sends `checkIn` with an idempotency key.
4. Backend validates identity, rejects overlapping active sessions, stores the session and event, and returns confirmation.
5. Client displays active session state and attempts to configure monitoring.

### On-Duty Verification

1. Client registers candidate monitoring for the active session.
2. Geofence or location events are submitted only while the session is active.
3. Backend stores minimized evidence and monitoring status.
4. Automatic closure remains disabled until feasibility and approval gates are complete.

### Eight-Hour Notification

1. Backend or client detects an active session that has reached eight hours.
2. Employee receives a notification with `Terminer la session` and `Continuer la session`.
3. Checkout follows the normal validated workflow if selected.
4. Continue preserves the active session and authorized monitoring.
5. No-response behavior and absolute maximum monitoring duration remain open decisions.

### Check-Out

1. Client obtains checkout location when available.
2. Client sends `checkOut` with an idempotency key.
3. Backend closes the active session and records checkout source.
4. Client unregisters geofences or stops monitoring.

## Future Offline Extension Points

Offline synchronization is out of scope for V1. To avoid blocking future support:

- Keep session commands behind a repository/service layer in Flutter.
- Use idempotency keys for commands that could be retried.
- Separate local command state from server-accepted state.
- Make UI confirmation depend on server acknowledgement.
- Keep conflict resolution server-led if offline support is added later.

## Observability and Audit

- Session commands should create audit records for security-sensitive changes.
- Automatic closures must record source, reason, evidence summary, and review status.
- Correction approvals and administrative edits must preserve who changed what, when, and why.
- Monitoring failures should be observable as session events, not hidden client logs only.
- Export operations should be auditable because they may expose employee data.

## Related Documents

- [Requirements](requirements.md)
- [Logical Data Model](data-model.md)
- [Security and Privacy](security-privacy.md)
- [Location Feasibility Study](location-feasibility.md)
