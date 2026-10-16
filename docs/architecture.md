# ChantiPoint Architecture v0.1

This document describes ChantiPoint's target architecture. M2.1 backend foundation is deployed to `chantipoint-dev`, and M2.2 Flutter authentication is complete. See [Development Status](development-status.md) for verification and remaining work; the broader components and workflows below include planned features and do not establish production readiness.

## Goals

- Support a French-language, single-company attendance and worksite-presence verification workflow.
- Support digital attendance at both the company's factory/premises and external worksites.
- Keep security and privacy controls server-enforced.
- Prioritize Android development while preserving a later iOS path.
- Move geofencing feasibility forward before major administrator-application investment.
- Keep the data access layer modular enough for possible future offline support.
- Avoid unnecessary infrastructure for one developer working approximately 5-7 hours per week.

## System Components

| Component | Candidate Technology | Responsibility |
| --- | --- | --- |
| Employee mobile app | Flutter and Dart | Authentication, manual check-in/out, active-session status, monitoring status, eight-hour notification, correction requests. |
| Administrator app | Flutter Web | Employee management, session review, map review where coordinates exist, anomaly review, automatic checkout review, correction approval, monthly hours report, CSV export. |
| Feasibility prototype | Isolated Android prototype using emulator simulated GPS | Validate geofence registration, exit/return events, candidate radii, delayed callback handling, simulated grace period, and cleanup before production investment. |
| Authentication | Supabase Auth | Implemented Flutter login, session restoration, authorization revalidation, and logout; public signup is disabled and administrator invitation/provisioning workflows remain planned. |
| Database | Supabase PostgreSQL | Durable records for profiles, roles, sessions, events, correction requests, retention metadata, and audit history. |
| Authorization | PostgreSQL Row Level Security and server-side operations | Enforce employee/admin access rules and protect location data. |
| Secure operations | Supabase Edge Functions or Postgres RPC where appropriate | Idempotent session commands, automatic closure candidates, exports, and privileged administrative operations. |

## Approval Boundaries

- Developer-reported requirements can guide planning but do not equal signed client approval.
- Proposed technical designs, including geofencing and automatic checkout, require feasibility results and explicit approval before production use.
- No real employee monitoring may begin before privacy, security, platform, and client release gates are satisfied.
- The private feasibility prototype must use emulator or test data only.
- Factory/company-premises attendance is digital time attendance only; it must not request location permissions, collect GPS coordinates, or register geofences.

## Security Boundaries

- Flutter clients must never contain Supabase service-role credentials.
- Clients may request operations, but the backend must enforce who can read, create, update, close, correct, and export records.
- Employees can access their own sessions and correction requests.
- One designated administrator initially can access employee records for the company.
- The role model should allow additional authorized administrators later without redesigning access control.
- Location records are sensitive and require least-privilege access, audit logging, and retention rules.
- CSV exports are controlled administrative actions and exclude detailed location trails by default.

## Logical API Boundaries

M2.1 implements attendance mutations through `check_in` and `check_out` Postgres RPCs, with RLS-protected reads; M2.3a implements their factory attendance Flutter UI. The external-worksite client flow remains planned. Later operations may use RPCs or Edge Functions as appropriate. The table below describes target logical boundaries, including future features:

| Operation | Purpose | Notes |
| --- | --- | --- |
| `checkIn` | Start a work session after server validation. | Requires authenticated employee, selected location context, optional description, and idempotency key. Factory sessions do not include a location payload; external-worksite sessions include GPS payload when available. The external-worksite GPS-unavailable policy remains unresolved. |
| `checkOut` | Manually close an active session. | Records checkout source as manual and stops monitoring if monitoring was active. Factory sessions do not request checkout GPS. |
| `recordLocationEvent` | Store geofence or location-verification evidence. | Used only during an active external-worksite session and subject to minimization and retention rules. |
| `recordMonitoringStatus` | Store monitoring enabled, disabled, unavailable, delayed, or stopped status. | Does not automatically prove absence. |
| `evaluateAutomaticCheckout` | Server-side evaluation of approved automatic checkout rules. | Disabled until feasibility and approval gates pass. |
| `notifyEightHourSession` | Notify an employee after eight hours of an active session. | Offers `Terminer la session` and `Continuer la session`; no automatic checkout solely from timeout. |
| `requestCorrection` | Employee submits a correction request. | Does not alter original history directly. |
| `resolveCorrection` | Administrator approves or rejects a request. | Creates audit history and adjusted session facts if approved. |
| `listSessions` | Review sessions by employee and date. | Admin scoped; employee scoped for self-view. |
| `exportSessionsCsv` | Export basic operational records. | Includes employee ID/name, session ID, site description, times, duration, checkout source, session status, and review status. |
| `listMonthlyEmployeeHours` | Calculate per-employee completed-session totals for a selected month. | Uses the configured business timezone (currently America/Montreal), DST-aware calendar-month boundaries, approved corrections, and shared attendance calculation logic. |
| `exportMonthlyEmployeeHoursCsv` | Export the monthly employee-hours report. | Operational attendance export only; excludes detailed GPS trails and does not perform payroll calculations. |

## Business Time

`lib/src/config/business_time_config.dart` centralizes JMService's IANA identifier `America/Montreal` and its separate French display label `heure de Montréal`. `lib/src/time/business_time.dart` resolves IANA locations, converts UTC instants through `toBusinessTime`, and formats employee timestamps through `formatBusinessTime`. Both conversion and formatting accept an explicit IANA identifier; formatting can receive a separate display label. Device timezone settings do not select the business clock.

The existing `timezone` package uses `latest_all.dart` because its default database excludes `America/Montreal`, an IANA backward-compatible alias for `America/Toronto`. The configured identifier stays `America/Montreal`. An unknown identifier fails explicitly; configuration is never silently changed to another zone. Database initialization occurs once per Dart isolate. There is no timezone settings UI, database timezone configuration, or multi-company timezone workflow.

Persisted session timestamps and command payloads stay in UTC. Conversion is a display/calendar view of the same instant. Elapsed durations must use UTC instants rather than naive local clock subtraction; local hours may be skipped or repeated at DST transitions. Future reporting must use the same configured IANA timezone policy for calendar boundaries and display.

## Status Model

Separate statuses avoid overloading a single field:

| Status Type | Example Values | Purpose |
| --- | --- | --- |
| Session lifecycle status | `active`, `closed_manual`, `closed_automatic`, `closed_admin`, `voided` | Describes whether the work session is active or closed and how it closed. |
| Review status | `normal`, `anomaly_open`, `correction_pending`, `reviewed`, `corrected`, `disputed` | Describes human review and correction workflow. |
| Monitoring status | `not_applicable`, `pending`, `enabled`, `disabled_detected`, `permission_revoked_detected`, `unavailable`, `inconclusive`, `stopped` | Describes whether on-duty verification can provide evidence. |

Factory/company-premises sessions should normally use `stopped` or `not_applicable` monitoring semantics in implementation rather than pretending location monitoring is enabled.

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
2. Client requires the employee to choose factory/company premises or external worksite.
3. For factory/company-premises sessions, the client records attendance data without requesting GPS.
4. For external-worksite sessions, the client obtains location when available and an optional site description.
5. If GPS is unavailable for an external-worksite session, the client must follow an approved business rule once defined rather than silently approving or rejecting the check-in.
6. Client sends `checkIn` with an idempotency key.
7. Backend validates identity, rejects overlapping active sessions, stores the session and event, and returns confirmation.
8. Client displays active session state and attempts to configure monitoring only when the session is eligible for location verification.

### On-Duty Verification

1. Client registers candidate monitoring only for approved external-worksite sessions.
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

1. Client sends `checkOut` with an idempotency key.
2. Factory/company-premises checkout does not request GPS.
3. External-worksite checkout may include checkout location when available and authorized.
4. Backend closes the active session and records checkout source.
5. Client unregisters geofences or stops monitoring if monitoring was active.

### Monthly Employee-Hours Reporting

1. Administrator selects a calendar month and year.
2. Backend derives the selected month's local start and the next month's local start in the configured business timezone (currently America/Montreal), then converts each boundary to UTC for a half-open reporting interval. Apply IANA DST rules rather than a fixed offset or a fixed number of 24-hour days.
3. Backend calculates elapsed completed-session durations from UTC instants in validated sessions and approved corrections.
4. Sessions crossing midnight or month boundaries contribute only the portion inside the selected month.
5. Incomplete, disputed, or administratively corrected sessions are flagged for review.
6. Administrator views totals in hours and minutes and can export the same report as CSV.

The calculation logic should be reusable for possible future daily or weekly reports without creating separate reporting systems.

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
- Monthly attendance reports should be reproducible from validated attendance records and approved corrections; if approved monthly summaries are later preserved, they should reference the calculation inputs and approval decision.

## Related Documents

- [Requirements](requirements.md)
- [Logical Data Model](data-model.md)
- [Security and Privacy](security-privacy.md)
- [Location Feasibility Study](location-feasibility.md)
