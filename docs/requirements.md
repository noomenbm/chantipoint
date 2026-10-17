# ChantiPoint Requirements Specification v0.1

This document defines draft product requirements for ChantiPoint. Documentation version `v0.1` is not the application software version and is not a signed specification. See [Development Status](development-status.md) for the implemented subset and completed verification; the full target scope below is not yet implemented.

ChantiPoint is a French-language employee attendance and worksite-presence verification application for one company operating primarily in the Montreal, Quebec region. It initially targets approximately 31-100 employees using personal smartphones. Android is the initial development and deployment priority; iOS remains a future target.

The application has two related purposes. First, it replaces manual paper attendance sheets by recording digital check-ins and check-outs at the company's factory/premises and at external worksites. Second, when technically validated and authorized, it uses location information for external-worksite verification so an authorized manager can review whether an employee's phone remained near the declared worksite during an active session. Device location must not be presented as certain proof of physical employee presence or actual work performed.

## Approved Attendance Target and Current Boundary

The developer-approved M2.3b target replaces authoritative employee mode selection and the previous factory-no-GPS rule. Future foreground check-in/checkout will attempt location acquisition at both factory and external locations. The backend will classify check-in as `factory`, `external_worksite`, or `location_unverified`; insufficient evidence must not become verified factory attendance or prevent otherwise authorized attendance. Check-in and checkout evidence are independent.

M2.3b.1 prepares schema foundations only: optional factory configuration, a third context value, an employee note column, and context-independent observation validation. The migration has been applied and tested locally; it has not been deployed to hosted development. M2.3b.2a now implements v2 attendance RPCs, classification and reason/review writes locally behind a server-controlled legacy-mode gate; hosted deployment and coordinated Flutter acquisition remain pending. M2.3b.2b implements owner-only overwrite notes and atomic final-note checkout locally, with no edit history; Flutter note UI/journal support remains pending. See [Attendance Backend Contract](attendance-backend-contract.md). Current M2.3a RPCs and the factory-only Flutter flow retain their legacy behavior. The current client cannot parse `location_unverified`; do not introduce such client-visible records until the coordinated next-stage changes.

This target is approved for development, not for real employee deployment. Client/privacy approval, employee notice, retention, and technical validation remain release gates.

## Approval Classification

| Classification | Meaning |
| --- | --- |
| Developer-reported requirement | Requirement reported by the developer after business discussions. It is usable for planning, but not a signed client approval. |
| Proposed technical design | Development-team proposal that requires feasibility testing, client approval, or both. |
| Developer-approved target | Approved development direction; implementation and client/privacy approval for deployment may still be pending. |
| Provisional development policy | Agreed for planning only; client, privacy, and technical approval and implementation are required before production. |
| Formal client approval | Explicitly approved by the client for production scope. No requirement in this draft is currently marked with this classification. |
| Open decision | A business, legal, privacy, or technical decision remains unresolved. |

| Priority | Meaning |
| --- | --- |
| P0 | Required for the initial usable product or a release gate. |
| P1 | Important for V1, but can follow the first proof of concept. |
| P2 | Useful improvement or future refinement. |

## Assumptions

- Initial deployment is for one company with approximately 31-100 employees.
- Employees use personal smartphones (BYOD), and the Android/iOS mix is not yet known.
- Android is the first deployment priority; iOS remains a later target requiring separate validation.
- Supabase Auth and PostgreSQL/RLS are implemented for the initial foundation; the first migration is deployed to `chantipoint-dev` and Flutter authentication is complete for M2.2.
- Public signup is disabled; V1 uses administrator-invited accounts. Current hosted-development checks use a fictional employee account. Application administrator provisioning and invitation management remain to be implemented.
- Flutter Web is the initial preferred candidate for administration.
- One designated administrator initially reviews employee sessions, anomalies, automatic checkouts, and correction requests.
- The role model should allow additional authorized administrators later without major restructuring.
- Employees must not choose authoritative attendance classification; the future backend derives it from usable evidence and trusted factory configuration.
- Future foreground location fixes may be collected for both factory and external check-in/checkout. Geofencing and background monitoring are separate, later features.
- Real employee monitoring must not begin until privacy, security, platform, and client approval gates are satisfied.

The factory/external-worksite distinction and monthly employee-hours report are developer-reported client requirements from business discussions. They are not formal written client approval.

## Actors

| Actor | Description |
| --- | --- |
| Employee | Authenticated worker who starts and ends work sessions, can submit correction requests, receives active-session notifications, and must be informed about monitoring status. |
| Administrator / Manager | Designated person who manages employee accounts, reviews sessions, anomalies, location evidence, automatic checkouts, correction requests, filters, maps, and CSV exports. |

The administrator makes human decisions concerning disputed or unusual situations. The system should not automate business judgment unnecessarily.

## Requirements

| ID | Requirement | Priority | Classification | Acceptance / Validation |
| --- | --- | --- | --- | --- |
| REQ-PV-001 | Provide location-based evidence for declared attendance at remote workplaces. | P0 | Developer-reported requirement | A manager can review session time, check-in/check-out coordinates, checkout source, anomalies, and relevant location-related events. |
| REQ-PV-002 | Avoid claiming that device location proves physical presence or work activity. | P0 | Developer-reported requirement | User-facing and internal documentation describe location evidence as limited evidence from a device. |
| REQ-UI-001 | Provide a French-language application experience. | P0 | Developer-reported requirement | Employee-facing actions include French labels such as `Terminer la session` and `Continuer la session`. |
| REQ-AUTH-001 | Employees and administrators authenticate with personal accounts. | P0 | Developer-reported requirement | Session operations are tied to authenticated identities. |
| REQ-EMP-001 | Employees can manually check in with a server-derived attendance classification. | P0 | Developer-approved target | The target backend records authenticated identity, server/device times, optional description, and factory/external_worksite/location_unverified classification from usable evidence; missing GPS does not prevent otherwise authorized check-in. |
| REQ-EMP-002 | Employees receive check-in confirmation only after server acknowledgement. | P0 | Developer-reported requirement | A failed or unacknowledged check-in does not silently create an active local-only session. |
| REQ-EMP-003 | Employees can manually check out even when location evidence is unavailable. | P0 | Developer-approved target | The target workflow attempts a foreground fix, records a checkout outcome independently of arrival, closes manually after server acknowledgement, and flags insufficient evidence for review without fabricating coordinates. |
| REQ-EMP-004 | Employees can have multiple work sessions per day. | P0 | Developer-reported requirement | Separate sessions can represent morning and afternoon work periods, lunch/break punch patterns if later approved, or work at different sites; overlapping active sessions for the same employee are prevented. |
| REQ-EMP-005 | Employees can optionally describe an external or unverified workplace. | P1 | Developer-approved target | Factory name is filled automatically from trusted configuration; employee-entered site_description remains distinct from a general employee note and technical reasons. This behavior awaits revised RPC/UI implementation. |
| REQ-EMP-006 | Employees can submit requests to correct missing or inaccurate punches. | P1 | Developer-reported requirement | A correction request preserves the original record and awaits administrator review. |
| REQ-EMP-007 | After eight hours of an active session, notify the employee and offer `Terminer la session` and `Continuer la session`. | P1 | Developer-reported requirement | Checkout uses the normal validated workflow; continuing preserves the active session and authorized monitoring. No automatic checkout occurs solely because eight hours elapsed. |
| REQ-EMP-008 | Employees are informed when on-duty location monitoring is active, disabled, or unavailable. | P0 | Developer-reported requirement | The employee UI shows monitoring state during active sessions and does not hide unavailable monitoring. |
| REQ-EMP-009 | The backend determines authoritative attendance classification. | P0 | Developer-approved target | Employees do not select authoritative factory/external mode. Usable evidence and trusted factory configuration yield factory, external_worksite, or location_unverified; missing evidence never means verified factory attendance. |
| REQ-EMP-010 | Factory attendance may use foreground check-in/checkout location evidence. | P0 | Developer-approved target | Individual fixes are distinct from future geofencing/background monitoring. The current legacy factory RPC/UI still collect no GPS; deployment of the revised collection model requires client/privacy approval. |
| REQ-EMP-011 | Location acquisition failures do not prevent otherwise authorized attendance. | P0 | Developer-approved target | The gated M2.3b.2a RPCs preserve independent arrival/departure outcomes, set an appropriate review flag, and use session_events.reason_code for observable technical reasons. Backend connectivity and authorization remain required; location failures do not establish intent or absence. |
| REQ-EMP-012 | Each session has one optional general-purpose business/work-session note. | P1 | Developer-approved target | employee_note supports up to 1,000 characters. Owner-authorized active-session saves overwrite the previous value without edit history; v2 manual checkout atomically preserves, replaces or clears the final note, then makes it read-only. Enforce employee ownership and active-session restrictions. No note versions, correction events, revision metadata or history table. Note RPCs are locally implemented in M2.3b.2b; Flutter editing UI and journal support remain pending. Standalone saves have no exactly-once recovery or version check; last serialized active save wins. |
| REQ-ADM-001 | Administrators can create and manage employee accounts. | P0 | Developer-reported requirement | Only authorized administrators can create, disable, or update employee profiles. |
| REQ-ADM-002 | Administrators can review work sessions. | P0 | Developer-reported requirement | Sessions can be filtered by employee and date and include duration, lifecycle status, review status, checkout source, and relevant events. |
| REQ-ADM-003 | Administrators can review check-in/check-out locations on a map. | P1 | Developer-reported requirement | Session detail includes coordinates and map display for recorded check-in/check-out points. |
| REQ-ADM-004 | Administrators can review departure, return, monitoring unavailable, and automatic-checkout events. | P1 | Developer-reported requirement | Event history distinguishes exit, return, disabled/unavailable monitoring, and automatic closure reasons. |
| REQ-ADM-005 | Administrators can review and resolve correction requests. | P1 | Developer-reported requirement | Approved or rejected requests create audit entries and never overwrite history without trace. |
| REQ-ADM-006 | Administrators can export basic records as CSV. | P1 | Developer-reported requirement | Routine export includes employee ID/name, session ID, optional site description, check-in/out time, duration, checkout source, session status, and review status. Detailed location trails are excluded. |
| REQ-ADM-007 | Start with one designated administrator while keeping the role model extensible. | P1 | Developer-reported requirement | Additional authorized administrators can be added later without redesigning core data access. |
| REQ-ADM-008 | Administrators can view total completed-session hours for each employee in a selected calendar month. | P0 | Developer-reported requirement | The report allows month/year selection, uses the configured business timezone (currently America/Montreal) for DST-aware calendar-month boundaries, supports multiple sessions per day, handles sessions crossing midnight or month boundaries without double-counting, and displays totals in hours and minutes. |
| REQ-ADM-009 | Administrators can export the monthly employee-hours report as CSV. | P0 | Developer-reported requirement | CSV export includes employee identity fields, selected month/year, total hours and minutes, and flags for incomplete, disputed, or corrected sessions; it remains operational attendance reporting, not payroll submission. |
| REQ-ADM-010 | Attendance reports identify incomplete, disputed, and administratively corrected sessions. | P0 | Developer-reported requirement | Monthly totals exclude incomplete sessions from completed-session duration unless an approved correction supplies valid effective times; original records and administrator decisions remain auditable. |
| REQ-LOC-001 | External-worksite check-in coordinates define the provisional geofence center. | P0 | Proposed technical design | External-worksite sessions can store the check-in coordinate as the candidate center unless feasibility testing rejects the approach; factory sessions have no geofence center. |
| REQ-LOC-002 | Geofencing is the preferred initial technical candidate for on-duty verification. | P1 | Proposed technical design | An isolated Android feasibility prototype validates or rejects the approach before production implementation. |
| REQ-LOC-003 | Use a candidate 100-150 meter geofence radius and a 10-minute grace period after the application/backend receives an exit event. | P1 | Proposed technical design | The grace period is measured from reliable receipt/callback, not from the physical departure time; final rules depend on feasibility results. |
| REQ-LOC-004 | A credible geofence exit starts a proposed grace/notification workflow, separate from location failure. | P1 | Provisional development policy | Proposed 10-minute receipt-based grace, checkout notification, and another hour before reevaluation if the employee continues. No response after 30 minutes permits automatic checkout only if approved evidence requirements still hold; preserve evidence and require administrator review. No production use without client, privacy, and technical approval. |
| REQ-LOC-005 | A single inaccurate GPS measurement must not automatically close a session. | P0 | Developer-reported requirement | Automatic closure evidence rules require sufficient reliable evidence and must be validated by the feasibility study. |
| REQ-LOC-006 | Monitoring failures are recorded as inconclusive or unavailable unless a reliable cause is detected. | P0 | Developer-reported requirement | Missing permissions, disabled location, OS suppression, connectivity loss, device shutdown, or service failure do not silently become absence findings. |
| REQ-LOC-007 | Location data is not collected after a work session ends. | P0 | Developer-reported requirement | Manual, automatic, or administrator-closed sessions remove or stop active monitoring. |
| REQ-LOC-008 | Loss of location permission, services, or monitoring availability alone must never trigger automatic checkout. | P1 | Provisional development policy | Record the reliably observed reason, unavailable/inconclusive state, review flag, and employee notification. After 30 minutes without acknowledgment, record that fact and keep the session active; remind again after approximately one hour if the problem persists. Detection and delivery are not guaranteed; future implementation requires client, privacy, and technical approval. |
| REQ-DATA-001 | Prevent overlapping active work sessions for the same employee. | P0 | Developer-reported requirement | Server-side constraints reject a second active session for one employee. |
| REQ-DATA-002 | Use server-controlled authorization. | P0 | Developer-reported requirement | Privileged decisions are enforced by backend policies and server-side logic, not only client UI. |
| REQ-DATA-003 | Protect duplicate operations and retries. | P0 | Developer-reported requirement | Check-in, checkout, location event, and correction operations use idempotency or equivalent duplicate handling. |
| REQ-DATA-004 | Store timestamps in UTC and display the configured business time, currently America/Montreal for JMService. | P0 | Developer-reported requirement | Centralized IANA conversion handles DST and accepts other regions; separate French labels show local time and UTC offset. Formatting preserves stored UTC timestamps; elapsed duration uses UTC instants. Database-configurable company timezones remain unimplemented. |
| REQ-DATA-005 | Preserve device-observed timestamps, callback/receipt timestamps, and server-accepted timestamps separately. | P0 | Developer-reported requirement | Records distinguish when a device observed an event, when the app/backend received it, and when the server accepted state changes. |
| REQ-DATA-006 | Preserve usable location evidence and observable technical limitations. | P0 | Developer-approved target | Future attendance records factory/external/unverified evidence, accuracy when available, and machine-readable failure reasons without fabricating coordinates. Existing event/observation names are retained; structured reason and review writes are implemented by the gated M2.3b.2a RPCs. |
| REQ-DATA-007 | Separate session lifecycle status, correction/review status, and monitoring availability/status. | P0 | Proposed technical design | The logical data model avoids overloading one status field for unrelated concerns. |
| REQ-DATA-008 | Calculate attendance totals from validated attendance records rather than manually maintained duplicate totals. | P0 | Developer-reported requirement | Monthly reporting derives totals from completed sessions and approved corrections using shared calculation logic that can later support daily or weekly reports. |
| REQ-SEC-001 | Never expose Supabase service-role credentials in Flutter clients. | P0 | Developer-reported requirement | Mobile and web clients use user-scoped credentials only. |
| REQ-PRIV-001 | Treat privacy approval as a release gate. | P0 | Developer-reported requirement | EFVP, employee notice, retention, and access-control decisions are complete before real monitoring. |
| REQ-PRIV-002 | Employee consent alone is not assumed sufficient for tracking. | P0 | Developer-reported requirement | Release documentation records employer responsibility for lawful, necessary, and proportionate monitoring. |
| REQ-PRIV-003 | Separate retention policy by data category. | P0 | Developer-reported requirement | Raw location observations, work sessions, correction requests, administrator decisions, audit logs, and backups have separately approved retention rules. |
| REQ-PRIV-004 | Support configurable retention by data category without assuming a universal deletion period. | P1 | Open decision | No automatic deletion rule is approved yet; future policies must separately address GPS observations, attendance sessions, approved monthly summaries, corrections, administrator decisions, audit logs, and backups. |

## Main Workflows

### Check-In

Target client workflow (v2 backend implemented in M2.3b.2a behind the legacy gate; revised Flutter acquisition/cutover are pending):

1. The employee authenticates and taps the French check-in action; no authoritative factory/external selector is offered.
2. The app attempts a bounded foreground location fix and records observable permission, service, precision, timeout, or provider conditions when available.
3. The backend evaluates evidence against trusted factory configuration and classifies the arrival as factory, external_worksite, or location_unverified.
4. The factory name is filled automatically; an external or unverified workplace can have an optional description. One optional general employee note is separate from this description and technical diagnostics.
5. Missing/insufficient evidence still permits attendance with normal connectivity and authorization; record a review flag and technical reason.
6. The backend atomically accepts the session, event, and evidence, rejects overlapping active sessions, and acknowledges the result before the UI confirms attendance.

Technical reasons use `session_events.reason_code`, including `permission_denied`, `location_services_disabled`, `approximate_only`, `accuracy_insufficient`, `location_timeout`, `provider_error`, and `unknown`. The gated v2 implementation also uses boundary_uncertain, location_stale and factory_configuration_missing, with other bounded evidence-quality codes documented in the backend contract. Do not create an event type for every failure or repeat ordinary check-in/checkout labels as new reason codes. OS-observed conditions are client-reported evidence; they do not identify deliberate interference.

Keep UTC timestamps authoritative, retain the original command payload/key for retries, and preserve legacy records without relabeling them as GPS-verified.

### On-Duty Location Verification

Geofencing is the preferred candidate for external-worksite verification, but not yet validated or approved for production. Foreground factory fixes belong to the revised attendance target; factory geofencing/background monitoring is not introduced by that change or by M2.3b.1.

Proposed behavior:

- Establish a temporary geofence centered on the external-worksite check-in location.
- Test candidate radii of 100 meters and 150 meters.
- Record exit and return events when supported.
- Start a candidate 10-minute grace period after reliable application/backend receipt of an exit event.
- Continue the session if return evidence is received during the grace period.
- Retain departure and return events in session history.
- Notify the employee with a checkout action under the proposed exit workflow. Choosing continue allows another hour before reevaluation and another notification.
- If there is no response after 30 minutes, automatic checkout may proceed only if the approved exit-evidence requirements are still satisfied; grace expiry or silence alone is insufficient.
- Preserve source, reason, and evidence, flag any automatic closure for mandatory administrator review, and retain the correction path.
- Mark monitoring as unavailable or inconclusive if permissions, OS behavior, service availability, connectivity, or signal quality prevents reliable verification.

This behavior is provisional and requires client, privacy, and technical approval before production. Exact notification timing relative to the grace period, acknowledgment handling, and evidence thresholds still need an approved contract. Background events can be delayed or missed; the grace period does not guarantee closure 10 minutes after physical departure. M2.3b.1 implements none of these notifications, timers, geofencing, or automatic checkout.

### Location Permissions Disabled or Unavailable

Foreground acquisition failures at check-in/checkout must not prevent otherwise authorized attendance or prove intent. During an active session, loss of permission, location services, or monitoring availability is a technical failure, not a geofence EXIT event. Neither that failure nor unanswered notifications may, by itself, cause automatic checkout.

Provisional future workflow:

- Record the technical reason when reliably observed; otherwise retain an unknown cause. Mark monitoring unavailable/inconclusive as appropriate and flag the session for administrator review. Do not infer absence or deliberate interference.
- Notify the employee when the future monitoring/notification feature supports it. If there is no acknowledgment after 30 minutes, record the lack of acknowledgment and keep the session active.
- Send another reminder after approximately one hour if the problem persists.
- Keep the session active until authorized checkout or a separately approved closure supported by sufficient independent evidence. The maximum-duration proposal below has a distinct basis; a GPS failure must never stand in for exit evidence.
- Record detection/delivery limitations: permission revocation, device shutdown, connectivity loss, or background-service termination may not be detected immediately.

This is documentation only, subject to client, privacy, and technical approval before production; M2.3b.1 implements no monitoring, notifications, timers, or automatic checkout.

### Eight-Hour Active-Session Notification

After eight hours of an active session, notify the employee and offer:

- `Terminer la session`
- `Continuer la session`

Choosing checkout closes the session through the normal validated checkout workflow. Choosing continue preserves the active session and authorized monitoring. Eight hours elapsed or an unanswered reminder alone does not trigger checkout.

### Excessively Long Sessions

A separate provisional workflow proposes a configurable 16-hour maximum session duration, measured from authoritative UTC instants:

- Reminder at 8 hours with the checkout/continue actions above.
- Stronger warning at 12 hours.
- Final warning at 15 hours 30 minutes.
- At 16 hours, proposed automatic closure with mandatory administrator review, preserved duration-policy reason/evidence, and an auditable timestamp.

This is distinct from both location failure and geofence exit; continuing after a reminder does not silently reset the proposed maximum. Automatic closure does not prove that all elapsed time was actually worked. Configuration, exceptions, closure timestamps, and notification delivery require client, privacy, and technical approval before production. No maximum-duration configuration, timer, notification, or automatic closure is implemented in M2.3b.1.

### Manual Check-Out

Target workflow:

1. The employee taps the French checkout action for any supported active-session context.
2. The app attempts a bounded foreground fix; unavailable, denied, approximate, or insufficient evidence does not block an otherwise authorized checkout.
3. The backend records the independent departure outcome and technical reason/review flag when needed, without changing the stored arrival classification.
4. Event/evidence writes and manual session closure are atomic; evidence is written while the session is active, before closure.
5. The UI confirms closure only after server acknowledgement. Any later approved monitoring stops after closure.

M2.3b.2a implements the v2 backend transaction behind the legacy gate. M2.3b.2b adds atomic final-note preserve/replace/clear; the revised client flow remains future work; the current legacy Flutter factory flow remains unchanged.

### Multiple Work Locations

Each physical work period is normally represented by a separate work session. A day can contain separate morning and afternoon sessions, multiple external worksites, factory/company-premises work, or a mix of factory and external sessions. GPS coordinates and optional descriptions help the administrator interpret external-worksite sessions, but coordinates alone do not identify an employer-assigned project. No predefined project/site management module is required for V1.

### Monthly Attendance Reporting

Administrators need an operational monthly report that totals completed working time for each employee.

Proposed behavior:

- The administrator selects a calendar month and year.
- The future report uses the configured business timezone (currently America/Montreal) for filtering and display. Derive local calendar-month boundaries with IANA DST rules, convert them to UTC, and calculate elapsed durations from UTC instants rather than naive local clock times.
- Totals are calculated from completed sessions and approved corrections, not from manually maintained duplicate total fields.
- Multiple sessions per day are included without double-counting.
- Sessions crossing midnight or month boundaries contribute only the portion inside the selected month.
- Incomplete, disputed, and administratively corrected sessions are flagged.
- Totals display in hours and minutes.
- CSV export is supported for the monthly report.

This is operational attendance reporting, not payroll integration. Wage calculations, tax deductions, payroll submission, automatic overtime calculations, and paid/unpaid break rules are excluded unless separately approved.

### Forgotten or Incorrect Check-Outs

The earlier concept of a separate 10-minute forgotten-checkout reminder is removed because V1 has no scheduled shift-end time from which to calculate it. The departure grace period and eight-hour notification are separate mechanisms.

Forgotten or incorrect punches are handled through correction requests, administrator review, and audit history.

## V1 Exclusions

The initial version does not include:

- Payroll integration or automated payroll calculations.
- Wage calculations, tax deductions, payroll submission, or automated overtime calculations.
- Automatic lunch deductions, mandatory midday checkouts, or paid/unpaid break rules without client confirmation.
- Employee scheduling.
- Customer invoicing.
- Sophisticated project management.
- Route tracking.
- Full-time employee tracking outside work sessions.
- Automatic site-to-site transfers.
- Daily and weekly attendance reports as confirmed V1 deliverables.
- Offline synchronization.
- Complex geolocation anti-spoofing.
- Attendance biometrics.
- Employee productivity surveillance.

Monthly employee-hours totals and operational CSV exports are allowed. They are not payroll integration.

## Open Requirements

- Formal client approval of the draft specification.
- Final automatic checkout approval, exceptions, and dispute workflow.
- Final geofence radius and tolerance after feasibility testing.
- Final evidence requirements for automatic checkout.
- Whether employees punch out and back in during lunch/breaks, whether breaks are deducted, and what approval evidence is required.
- Whether monthly totals are automatically calculated from completed sessions only or require formal administrator approval before use.
- Whether daily and weekly reports should be added after V1.
- Evidence-quality, boundary, freshness, and missing-configuration thresholds for the approved non-blocking location workflow; RPC/client cutover and independent outcome contracts.
- Client, privacy, and technical approval of the separate provisional location-failure, geofence-exit, and configurable 16-hour duration workflows; acknowledgment/delivery semantics, timer origins, evidence thresholds, exceptions, and auditable closure timestamps remain to be specified.
- Correction approval process and escalation rules.
- Final retention and deletion periods by data category.
- Required retention period for approved monthly attendance summaries after detailed GPS evidence expires.
- Android/iOS rollout priorities based on employee devices.
- Privacy approval, employee notice, EFVP, and BYOD expectations.

## Related Documents

- [Architecture](architecture.md)
- [Logical Data Model](data-model.md)
- [Backlog](backlog.md)
- [Location Feasibility Study](location-feasibility.md)
- [Security and Privacy](security-privacy.md)
- [Client Questions in French](client-questions-fr.md)
- [ADR 0001: Technology Stack](decisions/0001-technology-stack.md)
- [ADR 0002: Location Monitoring](decisions/0002-location-monitoring.md)
