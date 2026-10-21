# ChantiPoint Architecture v0.1

This document describes ChantiPoint's target architecture. M2.1 backend foundation is deployed to `chantipoint-dev`, and M2.2 Flutter authentication is complete. See [Development Status](development-status.md) for verification and remaining work; the broader components and workflows below include planned features and do not establish production readiness.

## M2.3b Implementation Boundary

The developer has approved a revised attendance target: foreground fixes at arrival and departure, server-derived `factory` / `external_worksite` / `location_unverified`, no authoritative employee mode choice, and attendance with a review flag when location evidence is missing or insufficient. Departure outcome is independent of arrival. This development approval does not authorize real employee deployment without client/privacy approval.

M2.3b.1 prepares `20261016000100_attendance_location_foundations.sql`: nullable all-or-none factory coordinates/radius on `companies`, the third session context, a nullable 1,000-character `employee_note`, and observation validation for any supported active-session context. Foreign keys, coordinate/accuracy checks, RLS, grants, and existing RPC signatures/responses remain unchanged. No coordinates/radius are seeded. The migration is not applied to hosted development in this stage.

The M2.3a Flutter client is still factory-only and cannot parse `location_unverified`. In the initial legacy mode, RPCs retain their old context input and factory/external GPS restrictions. After approved v2 activation, legacy new check-in is blocked and its checkout adapter records unverified departure evidence. Schema support does not enable the revised workflow: do not expose new-context sessions to this client. M2.3b.2a implements server authority and atomic event/evidence/reason/review writes behind a legacy-mode gate; [Attendance Backend Contract](attendance-backend-contract.md) documents signatures and local validation. M2.3b.2b implements owner-only active-session note updates and atomic final-note checkout; coordinated Flutter/journal integration and cutover remain pending. Historical contexts are not retroactively GPS-verified. Current findCommand recovery also rejects non-null site descriptions, so automatic factory names and expanded payloads need a coordinated recovery change in the next stage.

Reuse `session_events.event_type`, `reason_code`, `notes`, `source`, `work_sessions.review_status`, and linked `location_observations`. Keep `site_description` for workplace identity and `employee_note` for one general employee-authored note. Target note policy is owner-authorized overwrite-only saves while active, including a final edit atomic with manual checkout, then read-only. It is general business text with no edit history, note versions, correction events or revision metadata. M2.3b.2b implements note writes using the existing column; standalone Save remains gated, while C5/C6.2 provide isolated atomic checkout-note UI. Note saves share profile/role/company/session locks with attendance, use last serialized write wins, and add no note history or independent command journal. An uncertain standalone save needs reconciliation before retry; final-note checkout is hash-bound and idempotent. `geofence_enter`/`geofence_exit` are `location_observations.observation_type` values; their associated session events use the existing `location_observation` umbrella. Ordinary new attendance events need no redundant reason label. Technical reasons include permission_denied, location_services_disabled, approximate_only, accuracy_insufficient, location_timeout, provider_error, and unknown; the v2 contract also defines boundary_uncertain, location_stale and factory_configuration_missing. Development thresholds remain subject to production approval. Do not infer intent from unavailable evidence.

Retain `checkout_source`. Retain `checkout_reason_code` in this migration too, despite its approved removal from the target: actual historical values and closure-event consistency must be audited before a later cleanup migration.

## C6.3a server-only settled note contract

`save_employee_note(uuid,text,text,text,boolean)` adds an independent, keyed
active-note operation; it is absent from Flutter composition. It reuses the
existing deployment/profile/role/company/session lock order. The profile lock
serializes original and replay requests before evidence lookup. Original-first
commit produces `applied`; replay-first commit produces a durable
`not_applied/replay_fenced`, preventing waiting and later originals from writing.
A new original for an owned closed session settles `not_applied/session_closed`.
Matching requests return the original terminal record, never reapply historical
text. Changed inputs conflict; authorization errors stay unresolved to the client.

Mutation and terminal evidence are one transaction. Evidence in the private RLS
table has no client grants/policies and no historical note text/action. It binds
Auth/profile/company/session, operation key and exact-intent fingerprint, plus
outcome/reason/time. SHA-256 is not anonymization; metadata access, retention and
anti-replay-safe retirement require approval. No evidence pruning is implemented.

The unkeyed RPC remains compatible and can independently overwrite a note; its
retirement/fencing and draining remain pre-activation work. Checkout keeps its
immutable note intent, keys, receipts and journal rules. An applied note receipt
proves that operation, not current note equality or worked hours. The later client
still needs separate encrypted durable pending-note storage and shared save/
reconcile/checkout gates, frozen owner/generation/session and stale-publication
guards. C6.2 Save stays disabled. No live-controller wiring, attendance v2 gate
change, hosted deployment, legacy-file migration activation or Flutter changes are included.
See [RPC contract](attendance-backend-contract.md#c63a-settled-note-operations-server-only)
for exact responses, locking, errors, privacy and recovery requirements.

## C6.2 note UI and explicit standalone-save fallback

The isolated C5 screen has a prominent `Note de la session` section with the
canonical saved value, including distinct null and empty states. `Enregistrer
la note` is explicitly disabled with French availability guidance. No active
draft field is offered for a write that cannot safely run. `Note à la sortie`
shows the current canonical value, three visible radio choices and a visible
multiline final draft, enabled for explicit replacement only. A draft remains
unsaved and is never used by preserve/clear. Existing C4 validation, immutable
capture and C3 confirmation/consumption gates are unchanged. Description du lieu
is labelled as worksite description, separate from note and classification.

This is the C6.2 request's authorized safety fallback, not completed standalone
note saving. `update_employee_note` takes only session ID/text, locks the owned
active session and returns status/session/note. It has no request identity,
durable operation receipt or terminal lookup. A read can precede a delayed
write; a matching value can belong to another write. Neither establishes
settlement after a lost response. The DTO is not durable proof. The C3 queue is
isolate-local and its ports/storage accept attendance commands, not separate
note operations. Reusing its single format-2 slot would change settled journal
invariants and violate the separate-outbox requirement. A route's busy flag
would lose unresolved ownership at restart and would not gate other instances.

A safe standalone implementation therefore requires a separately reviewed
server operation-identity/hash/replay/settlement contract, a separate encrypted
durable pending-note store with verified recovery, and shared note/checkout
coordination. Lookup must resolve a specific operation without allowing an
earlier unseen write to commit after the gate is released; ordinary read or
replay miss is insufficient. Preserve frozen full binding/generation/session/text
and any uncertain result through restart before enabling another write/checkout.
This concerns operation recovery, not an employee note-edit history feature.
That was the C6.2 boundary: no SQL or native storage changed in its fallback.
C6.3a now supplies the separate server contract above; client storage/coordination
and native tests remain deferred. Production deployment,
composition, writer fencing and privacy/backup gates remain in force.

Own-session history for the preceding six months is a future read-only,
owner-scoped paginated slice (REQ-EMP-013 / BL-033), including times, description,
canonical note, classification and review state. Use configured business-timezone
boundaries with UTC storage; the six-month window is not a deletion policy.

## C6.1 scoped active reads and auth notifications (not composed)

`SupabaseAttendanceOperationTransport.readActiveSession` supplies a C5 read using
the exact C3.3 `AttendanceAuthOwner` authority, captured generation and five-field
binding. It reuses C3.2's pinned credentials, independently trusted endpoint/key,
one-attempt bounded strict-UTF-8 HTTP boundary and pre/post-await guards. Canonical
acknowledged-session reads still include closed sessions; dispatch and receipt
handling are unchanged. No current-account SDK attendance lookup is used.

A bare empty `work_sessions` response cannot distinguish no session from RLS
hiding a disabled/revoked employee. One `user_profiles` SELECT therefore embeds
the active employee role and active sessions through the existing named composite
foreign keys. The parent and both children are explicitly company/profile scoped;
the parent is also auth-user scoped. Exactly one active owned profile and employee
role must validate. Only its empty sessions array means no active session. Missing
authorization, owner mismatch, multiple/inactive/malformed sessions, missing v2
fields, HTTP/schema/network failures and expired/stale scopes are failures, never
an empty selection. This checks the SELECT snapshot, not continuous authorization.
The query follows [PostgREST resource embedding](https://docs.postgrest.org/en/stable/references/api/resource_embedding.html);
actual deployment/schema-cache compatibility remains a pre-composition check.

`ScopedAttendanceActiveSessionReader` supplies C5's observation port over that
same transport. Reads establish a checkout baseline without changing its public
revision or notifying listeners. An explicit authorized `invalidateSession`
advances revision, clears the baseline and requires refresh. It grants no new
session or authorization. Revision and read-sequence guards reject older results;
`isSessionCurrent` checks the original identity and session. No production source
of independent session notifications is connected, and there is no subscription
or polling. Disposal rejects publication but leaves submitted HTTP work settling
and does not close borrowed auth/client resources.

The existing application-lifetime auth owner now implements `Listenable`.
Notifications cover existing synchronous controller boundaries and additive
repository operation-initiation hooks, including direct repository operations.
Auth queue order is reserved before callbacks can initiate newer logout. Complete
owner transitions publish atomically, after profile/role attestation for a grant;
proven same-login token refresh neither rotates generation nor notifies C5.
`close()` revokes synchronously, removes controller/repository/SDK listeners and
waits for issued contexts' normal release. Routes only detach their own listeners;
the application must close the owner before disposing its auth controller.
Supported mutations stay in AuthController/the repository. Direct SDK invocation
has no universal initiation hook; exact-session guards reject replaced credentials
and the ordered SDK event notifies the owner. No global interceptor is claimed.

These adapters remain absent from main/AuthGate/live attendance. Hosted schema,
v2 activation, trusted deployment composition, legacy provenance and durable
writer retirement/fencing, storage/backup/privacy approvals remain cutover gates.
No journal recovery, note-save action, GPS or backend change is introduced.

## C5.1/C5.2 isolated French employee workflow

`EmployeeAttendanceWorkflow` connects the existing C4 immutable capture and C3
operation coordinator through injected ownership, authorization notifications and
an owner-scoped active-session read/observation port. `EmployeeAttendanceScreen`
provides French check-in, manual checkout with preserve/replace/clear final-note
intent, canonical saved-note/review display and Montréal business time. It is
absent from main/AuthGate/navigation; the live legacy path remains unchanged.

The workflow serializes presentation operations, suppresses stale generation/
binding/session observations and leaves submitted work owned by C3 through normal
settlement. It confirms only from durable coordinator proof plus canonical data;
uncertainty, replay miss and storage gates block new intent. Recovery reuses the
original command. C5.2 adds an explicit French verification step. Only the shared
coordinator consumes its exact durable confirmation after a fresh scoped canonical
read, through revision/key/full-record guarded CAS to an empty tombstone. Failed
compaction stays gated; unproved/restarted empty state requires exact verification.
A fresh owner-scoped active SELECT under the same queue decides the next action.
Consumption authority freezes before waiting, so queued duplicates cannot consume
newer commands. No presentation-layer compaction or direct deletion is introduced;
cross-process production ownership remains unresolved. Standalone note saves
wait for uncertain-save reconciliation. See
[Employee Attendance Workflow](employee-attendance-workflow.md) for the injected
port contracts, safe composition boundary, testing and remaining C5/cutover work.

## C4 isolated foreground action capture

`ForegroundLocationService` and an Android versioned channel collect a single
foreground fix only on an explicit action. The cached geolocator timeout/service
behavior did not meet the required boundary, so the adapter uses the cached
AndroidX cancellable single-fix API. Native cancellation settles before timeout
publication, and activity pause cancels the request. Only foreground coarse/fine
permissions are declared; no tracking service, stream or background monitoring.

`AttendanceActionCapture` captures the original UTC action time, secure key,
description/session/note intent before acquisition awaits. It preserves native
fix time and finite low-quality evidence for server evaluation. Permission or fix
failure remains diagnostic evidence and does not independently reject attendance.
Complete v2 parameters freeze once in the existing JournalCommand. No device
classification or standalone note-save command is introduced.

Captured generation/full binding and the original checkout-session observation
gate handoff. Duplicate taps cannot replace intent, and close/abandon cannot
release submitted ownership before coordinator settlement. This layer dispatches
and persists nothing. MainActivity only registers an inert channel; the live
legacy controller/screens and hosted gate remain unchanged. Application-lifetime
composition, backend cutover, real employee privacy approval and C3 migration/
fencing prerequisites remain pending. See [Foreground Location](foreground-location.md)
for cancellation, handoff, native probe and platform limitations.

## C3.4 isolated confirmed-record recovery

`AttendanceOperationCoordinator.recoverConfirmed` is an explicit, opt-in path
for stored confirmed v2 records after restart/replacement or a reported
confirmation CAS failure that may have committed. An injected `JournalVerifier`
must freshly synchronize and authenticate the exact complete record. The Android
`verifyRecordV1` barrier uses the established native process/file locks, file and
directory synchronization, and complete authenticated readback. Dart validates
the full schema and rereads exact bytes across the barrier, checking the captured
authorization generation and five-field binding throughout.

Only canonical session refresh is authorized by this recovery. Receipt and
immutable command bytes remain unchanged; no attendance RPC, replay, cleanup,
compaction or migration occurs. Missing verifiers, changed/unverifiable records
and ambiguous sidecars fail closed. Canonical failures retain the confirmed
receipt for later explicit refresh. Existing successful-CAS and late-receipt
paths remain unchanged. Prepared and uncertain command recovery is unchanged.

This composition remains outside main/screens and the legacy live controller.
Production provenance, durable ownership/fencing, backup review and approved
backend deployment/cutover remain prerequisites. Synchronization/readback is not
a guarantee against arbitrary power loss, device loss or storage rollback. See
[Secure Command Journal](secure-command-journal.md#c34-durable-confirmed-record-recovery)
and [Android Journal Storage](android-journal-storage.md#c34-general-exact-record-verification).

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
- The revised target allows foreground factory fixes; geofencing/background monitoring remains separate and deferred. Real employee collection requires client/privacy approval; M2.3b.1 changes no client acquisition behavior.

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
| `checkIn` | Start a work session after server validation. | Target: authenticated employee, evidence/technical conditions, optional external/unverified description, and idempotency key. The server derives classification and fills the factory name; unavailable evidence permits attendance with review. V2 backend implemented behind the legacy gate; client cutover pending. |
| `checkOut` | Manually close an active session. | Target: foreground evidence independent of arrival, non-blocking location failure with review, manual closure, and stop any later approved monitoring. V2 backend implemented behind the legacy gate; client cutover pending. |
| `recordLocationEvent` | Store geofence or location-verification evidence. | Foreground attendance evidence belongs to its arrival/departure RPC for any supported context; later geofence/monitoring evidence remains separately approved and active-session scoped. |
| `recordMonitoringStatus` | Store monitoring enabled, disabled, unavailable, delayed, or stopped status. | Does not automatically prove absence. |
| `evaluateAutomaticCheckout` | Server-side evaluation of approved automatic checkout rules. | Disabled until feasibility and approval gates pass. |
| `notifyEightHourSession` | Notify an employee after eight hours of an active session. | Offers `Terminer la session` and `Continuer la session`; no automatic checkout solely from an unanswered eight-hour reminder. |
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

Automatic checkout remains proposed. Before production use, rules must be approved and tested. The following evidence principles govern geofence-exit closure; location failure and maximum-duration handling are separate workflows:

- The session must be active.
- Monitoring must have been enabled or a monitoring status must explain why evidence is incomplete.
- Exit evidence must be tied to the session and include source, device-observed time, callback or receipt time, server accepted time where applicable, and accuracy or platform metadata.
- The candidate grace period is 10 minutes after the application/backend receives reliable exit evidence, not 10 minutes after physical departure.
- A single low-accuracy GPS point must not close a session.
- If return evidence arrives during the approved rule window, the session remains active and both departure and return are retained.
- Loss of location services, permission, or monitoring availability is not exit evidence and cannot, by itself, close a session. Record the observed technical reason and unavailable/inconclusive status, flag for review, and notify the employee when the future feature exists. No acknowledgment after 30 minutes is recorded while the session stays active; remind again after approximately one hour if the issue persists.
- If evidence is missing, delayed, contradictory, or unavailable, the session is marked inconclusive or for review rather than silently inferring absence.
- No checkout timestamp may be fabricated. The chosen timestamp rule must be explicit, auditable, and approved.
- The provisional exit workflow sends a checkout notification. Continue allows another hour before reevaluation and another notification; no response after 30 minutes allows automatic closure only while approved exit-evidence requirements remain satisfied. Grace expiry and silence alone are insufficient. Preserve evidence and require administrator review; work after closure requires a new manual check-in.

Keep three separate reasons/workflows: technical monitoring failure (no automatic closure from failure or silence), credible geofence exit (receipt-based grace and evidence-gated notification workflow), and excessive duration (proposed configurable 16-hour limit). A session remains active until authorized checkout or a separately approved closure based on sufficient independent evidence. The duration proposal uses authoritative UTC elapsed time, not an assumed departure or failed GPS signal, and does not prove that all elapsed time was worked.

These policies are provisional, requiring client, privacy, and technical approval before production. Timing origins, notification/grace interaction, delivery/acknowledgment handling, duration exceptions, and closure timestamps still need an approved contract. M2.3b.1 adds no notification, timer, geofencing, or automatic-closure implementation.

## Data Flow

### Check-In

Target client flow, supported by the gated M2.3b.2a backend; Flutter acquisition/cutover remain pending:

1. Employee authenticates and requests check-in without selecting authoritative classification.
2. Client attempts a bounded foreground fix and captures observable technical conditions for factory or external attendance.
3. Backend evaluates usable evidence against trusted company factory configuration; output is factory, external_worksite, or location_unverified. M2.3b.2a implements conservative development accuracy, boundary, freshness and policy-provenance rules behind the legacy gate. Production thresholds and coordinated client acquisition remain pending approval.
4. Factory name is filled automatically; external/unverified sessions may have an optional workplace description. General employee notes remain separate.
5. Backend atomically writes the session, attendance event, and event-linked observation/diagnostics. Insufficient evidence sets review status and a reason without rejecting otherwise authorized attendance.
6. Client confirms only after server acknowledgement; retries retain the original evidence/payload/key.

Arrival and departure outcomes live with their respective evidence/events. One missing fix does not determine the other. Optional unavailable observations need the correct event association so their phase is unambiguous.

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
5. An unanswered eight-hour reminder alone does not close the session. The separate proposed configurable 16-hour maximum adds a stronger warning at 12 hours, a final warning at 15 hours 30 minutes, and automatic closure at 16 hours with mandatory administrator review.
6. Record the duration-policy reason/evidence separately from monitoring failure and geofence exit. Client, privacy, and technical approval, delivery behavior, and exceptions remain pending; no notifications or duration enforcement are implemented in M2.3b.1.

### Check-Out

Target client flow, supported by the gated M2.3b.2a backend; M2.3b.2b supports atomic final-note save; Flutter acquisition/note UI remain pending:

1. Client requests checkout and attempts a bounded foreground fix regardless of arrival classification.
2. Backend records an independent departure outcome; missing or insufficient evidence records a technical reason/review flag and does not block an otherwise authorized operation.
3. Evidence is written before closure under the active-session guard; event/evidence changes and manual closure commit atomically.
4. Preserve arrival classification, authoritative UTC times, source, existing review issues, and idempotency guarantees.
5. Client confirms only after acknowledgement and stops any later approved monitoring. No background monitoring is introduced here.

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
