# ChantiPoint Requirements Specification v0.1

This document defines draft product requirements for ChantiPoint before feature development. Documentation version `v0.1` is not the application software version and is not a signed specification.

ChantiPoint is a French-language employee attendance and worksite-presence verification application for one company operating primarily in the Montreal, Quebec region. It initially targets approximately 31-100 employees using personal smartphones. Android is the initial development and deployment priority; iOS remains a future target.

The application has two related purposes. First, it replaces manual paper attendance sheets by recording digital check-ins and check-outs at the company's factory/premises and at external worksites. Second, when technically validated and authorized, it uses location information for external-worksite verification so an authorized manager can review whether an employee's phone remained near the declared worksite during an active session. Device location must not be presented as certain proof of physical employee presence or actual work performed.

## Approval Classification

| Classification | Meaning |
| --- | --- |
| Developer-reported requirement | Requirement reported by the developer after business discussions. It is usable for planning, but not a signed client approval. |
| Proposed technical design | Development-team proposal that requires feasibility testing, client approval, or both. |
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
- Supabase is the planned backend candidate, but no Supabase project, schema, or migration exists yet.
- Flutter Web is the initial preferred candidate for administration.
- One designated administrator initially reviews employee sessions, anomalies, automatic checkouts, and correction requests.
- The role model should allow additional authorized administrators later without major restructuring.
- At check-in, employees must select whether the session is at the factory/company premises or at an external worksite.
- Factory attendance is digital time attendance only and must not request, collect, or store GPS coordinates.
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
| REQ-EMP-001 | Employees can manually check in for factory/company-premises attendance or external-worksite attendance. | P0 | Developer-reported requirement | Check-in records employee identity, selected location context, check-in time, optional site description, and server/device timestamps; GPS fields are only recorded for external-worksite sessions when collected. |
| REQ-EMP-002 | Employees receive check-in confirmation only after server acknowledgement. | P0 | Developer-reported requirement | A failed or unacknowledged check-in does not silently create an active local-only session. |
| REQ-EMP-003 | Employees can manually check out. | P0 | Developer-reported requirement | Checkout records the source as manual, closes the session, stops monitoring when applicable, and does not fabricate checkout coordinates. Factory checkouts do not request GPS. |
| REQ-EMP-004 | Employees can have multiple work sessions per day. | P0 | Developer-reported requirement | Separate sessions can represent morning and afternoon work periods, lunch/break punch patterns if later approved, or work at different sites; overlapping active sessions for the same employee are prevented. |
| REQ-EMP-005 | Employees can optionally enter a site or project description. | P1 | Developer-reported requirement | The description is stored with the session and remains distinct from GPS coordinates. |
| REQ-EMP-006 | Employees can submit requests to correct missing or inaccurate punches. | P1 | Developer-reported requirement | A correction request preserves the original record and awaits administrator review. |
| REQ-EMP-007 | After eight hours of an active session, notify the employee and offer `Terminer la session` and `Continuer la session`. | P1 | Developer-reported requirement | Checkout uses the normal validated workflow; continuing preserves the active session and authorized monitoring. No automatic checkout occurs solely because eight hours elapsed. |
| REQ-EMP-008 | Employees are informed when on-duty location monitoring is active, disabled, or unavailable. | P0 | Developer-reported requirement | The employee UI shows monitoring state during active sessions and does not hide unavailable monitoring. |
| REQ-EMP-009 | Employees explicitly select a work location type at check-in. | P0 | Developer-reported requirement | The UI presents simple choices equivalent to `À l'usine` and `Chantier extérieur`; the selected value is stored as factory/company premises, external worksite, or unspecified only for legacy/admin-repair cases. |
| REQ-EMP-010 | Factory/company-premises attendance does not use GPS or geofencing. | P0 | Developer-reported requirement | Factory sessions record check-in/check-out timestamps without requesting location permissions, storing coordinates, registering geofences, or starting background location monitoring. |
| REQ-EMP-011 | External-worksite attendance captures location evidence at check-in and may use authorized verification. | P0 | Developer-reported requirement | External-worksite check-in captures latitude, longitude, and accuracy when available; geofencing or other verification applies only after technical validation and approval. The policy for unavailable GPS at external-worksite check-in remains unresolved and must not be silently approved or rejected. |
| REQ-ADM-001 | Administrators can create and manage employee accounts. | P0 | Developer-reported requirement | Only authorized administrators can create, disable, or update employee profiles. |
| REQ-ADM-002 | Administrators can review work sessions. | P0 | Developer-reported requirement | Sessions can be filtered by employee and date and include duration, lifecycle status, review status, checkout source, and relevant events. |
| REQ-ADM-003 | Administrators can review check-in/check-out locations on a map. | P1 | Developer-reported requirement | Session detail includes coordinates and map display for recorded check-in/check-out points. |
| REQ-ADM-004 | Administrators can review departure, return, monitoring unavailable, and automatic-checkout events. | P1 | Developer-reported requirement | Event history distinguishes exit, return, disabled/unavailable monitoring, and automatic closure reasons. |
| REQ-ADM-005 | Administrators can review and resolve correction requests. | P1 | Developer-reported requirement | Approved or rejected requests create audit entries and never overwrite history without trace. |
| REQ-ADM-006 | Administrators can export basic records as CSV. | P1 | Developer-reported requirement | Routine export includes employee ID/name, session ID, optional site description, check-in/out time, duration, checkout source, session status, and review status. Detailed location trails are excluded. |
| REQ-ADM-007 | Start with one designated administrator while keeping the role model extensible. | P1 | Developer-reported requirement | Additional authorized administrators can be added later without redesigning core data access. |
| REQ-ADM-008 | Administrators can view total completed-session hours for each employee in a selected calendar month. | P0 | Developer-reported requirement | The report allows month/year selection, uses America/Toronto business time, supports multiple sessions per day, handles sessions crossing midnight or month boundaries without double-counting, and displays totals in hours and minutes. |
| REQ-ADM-009 | Administrators can export the monthly employee-hours report as CSV. | P0 | Developer-reported requirement | CSV export includes employee identity fields, selected month/year, total hours and minutes, and flags for incomplete, disputed, or corrected sessions; it remains operational attendance reporting, not payroll submission. |
| REQ-ADM-010 | Attendance reports identify incomplete, disputed, and administratively corrected sessions. | P0 | Developer-reported requirement | Monthly totals exclude incomplete sessions from completed-session duration unless an approved correction supplies valid effective times; original records and administrator decisions remain auditable. |
| REQ-LOC-001 | External-worksite check-in coordinates define the provisional geofence center. | P0 | Proposed technical design | External-worksite sessions can store the check-in coordinate as the candidate center unless feasibility testing rejects the approach; factory sessions have no geofence center. |
| REQ-LOC-002 | Geofencing is the preferred initial technical candidate for on-duty verification. | P1 | Proposed technical design | An isolated Android feasibility prototype validates or rejects the approach before production implementation. |
| REQ-LOC-003 | Use a candidate 100-150 meter geofence radius and a 10-minute grace period after the application/backend receives an exit event. | P1 | Proposed technical design | The grace period is measured from reliable receipt/callback, not from the physical departure time; final rules depend on feasibility results. |
| REQ-LOC-004 | If a departure persists beyond the grace period and sufficient reliable evidence exists, proposed behavior is automatic checkout followed by employee notification. | P1 | Proposed technical design | Automatic closure records source, reason, evidence, and review status; the employee must manually check in again. No production use occurs without approval. |
| REQ-LOC-005 | A single inaccurate GPS measurement must not automatically close a session. | P0 | Developer-reported requirement | Automatic closure evidence rules require sufficient reliable evidence and must be validated by the feasibility study. |
| REQ-LOC-006 | Monitoring failures are recorded as inconclusive or unavailable unless a reliable cause is detected. | P0 | Developer-reported requirement | Missing permissions, disabled location, OS suppression, connectivity loss, device shutdown, or service failure do not silently become absence findings. |
| REQ-LOC-007 | Location data is not collected after a work session ends. | P0 | Developer-reported requirement | Manual, automatic, or administrator-closed sessions remove or stop active monitoring. |
| REQ-LOC-008 | If location services are disabled or required permissions are revoked during an active session and reliable detection occurs, initiate the appropriate closure procedure and record the reason. | P1 | Developer-reported requirement | Documentation and implementation do not promise immediate detection; undetected or unclear failures remain inconclusive for review. |
| REQ-DATA-001 | Prevent overlapping active work sessions for the same employee. | P0 | Developer-reported requirement | Server-side constraints reject a second active session for one employee. |
| REQ-DATA-002 | Use server-controlled authorization. | P0 | Developer-reported requirement | Privileged decisions are enforced by backend policies and server-side logic, not only client UI. |
| REQ-DATA-003 | Protect duplicate operations and retries. | P0 | Developer-reported requirement | Check-in, checkout, location event, and correction operations use idempotency or equivalent duplicate handling. |
| REQ-DATA-004 | Store timestamps in UTC and display local business time in America/Toronto. | P0 | Developer-reported requirement | Stored values are timezone-safe; UI labels make displayed local time clear. |
| REQ-DATA-005 | Preserve device-observed timestamps, callback/receipt timestamps, and server-accepted timestamps separately. | P0 | Developer-reported requirement | Records distinguish when a device observed an event, when the app/backend received it, and when the server accepted state changes. |
| REQ-DATA-006 | Record GPS accuracy where available for location-based evidence. | P0 | Developer-reported requirement | External-worksite location evidence includes accuracy metadata or an explicit unavailable value; factory sessions do not create location observations. |
| REQ-DATA-007 | Separate session lifecycle status, correction/review status, and monitoring availability/status. | P0 | Proposed technical design | The logical data model avoids overloading one status field for unrelated concerns. |
| REQ-DATA-008 | Calculate attendance totals from validated attendance records rather than manually maintained duplicate totals. | P0 | Developer-reported requirement | Monthly reporting derives totals from completed sessions and approved corrections using shared calculation logic that can later support daily or weekly reports. |
| REQ-SEC-001 | Never expose Supabase service-role credentials in Flutter clients. | P0 | Developer-reported requirement | Mobile and web clients use user-scoped credentials only. |
| REQ-PRIV-001 | Treat privacy approval as a release gate. | P0 | Developer-reported requirement | EFVP, employee notice, retention, and access-control decisions are complete before real monitoring. |
| REQ-PRIV-002 | Employee consent alone is not assumed sufficient for tracking. | P0 | Developer-reported requirement | Release documentation records employer responsibility for lawful, necessary, and proportionate monitoring. |
| REQ-PRIV-003 | Separate retention policy by data category. | P0 | Developer-reported requirement | Raw location observations, work sessions, correction requests, administrator decisions, audit logs, and backups have separately approved retention rules. |
| REQ-PRIV-004 | Support configurable retention by data category without assuming a universal deletion period. | P1 | Open decision | No automatic deletion rule is approved yet; future policies must separately address GPS observations, attendance sessions, approved monthly summaries, corrections, administrator decisions, audit logs, and backups. |

## Main Workflows

### Check-In

1. The employee arrives at the assigned workplace.
2. The employee opens ChantiPoint and authenticates if necessary.
3. The employee taps the French UI check-in action.
4. The employee selects the work location type: factory/company premises or external worksite.
5. For a factory/company-premises session, the app records attendance timestamps only and does not request GPS permission, capture coordinates, or register geofencing.
6. For an external-worksite session, the app obtains a GPS location fix when available and collects an optional site description.
7. If GPS is unavailable for an external-worksite check-in, the application follows an approved business rule once defined; until then, documentation must not assume silent approval or silent rejection.
8. The app submits the check-in to the backend.
9. The backend validates the request, records the event, and acknowledges success.
10. The employee receives confirmation and the work session becomes active.

Acceptance criteria:

- No active session is created without server acknowledgement.
- Check-in records authenticated identity, selected location context, optional description, server receipt time, and device-observed time.
- Factory/company-premises check-in does not request, collect, or store GPS coordinates.
- External-worksite check-in records location and accuracy when available.
- External-worksite GPS-unavailable behavior remains a business decision; the system must not silently treat missing GPS as verified attendance or as automatic refusal without an approved rule.
- The server rejects overlapping active sessions for the same employee.

### On-Duty Location Verification

Geofencing is the preferred candidate for external-worksite verification, but not yet validated or approved for production. Factory/company-premises attendance does not use GPS, geofencing, or background location monitoring in V1.

Proposed behavior:

- Establish a temporary geofence centered on the external-worksite check-in location.
- Test candidate radii of 100 meters and 150 meters.
- Record exit and return events when supported.
- Start a candidate 10-minute grace period after reliable application/backend receipt of an exit event.
- Continue the session if return evidence is received during the grace period.
- Retain departure and return events in session history.
- If the departure persists beyond the grace period and sufficient reliable evidence exists, initiate automatic checkout and notify the employee.
- Record source, reason, and evidence for administrator review and correction.
- Mark monitoring as unavailable or inconclusive if permissions, OS behavior, service availability, connectivity, or signal quality prevents reliable verification.

This behavior is a proposed business and technical direction, not a production commitment. Background events can be delayed or missed, and a 10-minute grace period does not guarantee closure 10 minutes after the employee physically leaves.

### Location Permissions Disabled or Unavailable

Desired external-worksite verification behavior is automatic checkout when the employee disables location services or revokes required permissions during an active monitored work session. The technical design must also record the limitation that the application may not immediately detect permission revocation, device shutdown, connectivity loss, or background-service termination.

Acceptance criteria:

- When reliable detection occurs, the system initiates the approved closure procedure and records the reason.
- When verification becomes unavailable without a reliably detected cause, the session remains inconclusive for administrator review.
- The product does not promise immediate automatic checkout.

### Eight-Hour Active-Session Notification

After eight hours of an active session, notify the employee and offer:

- `Terminer la session`
- `Continuer la session`

Choosing checkout closes the session through the normal validated checkout workflow. Choosing continue preserves the active session and authorized monitoring. If the employee does not respond, the behavior remains unresolved and requires approval before production.

### Manual Check-Out

1. The employee taps the French UI checkout action.
2. For factory/company-premises sessions, checkout records attendance timestamps only.
3. For external-worksite sessions, the app may obtain the current location when available and authorized.
4. The backend records the checkout event and closes the session.
5. Location monitoring stops if it was active.
6. The employee receives confirmation.

Acceptance criteria:

- Checkout source is recorded as manual.
- Monitoring stops after the server accepts session closure.
- Missing checkout location does not fabricate coordinates.
- Factory/company-premises checkout does not request, collect, or store GPS coordinates.

### Multiple Work Locations

Each physical work period is normally represented by a separate work session. A day can contain separate morning and afternoon sessions, multiple external worksites, factory/company-premises work, or a mix of factory and external sessions. GPS coordinates and optional descriptions help the administrator interpret external-worksite sessions, but coordinates alone do not identify an employer-assigned project. No predefined project/site management module is required for V1.

### Monthly Attendance Reporting

Administrators need an operational monthly report that totals completed working time for each employee.

Proposed behavior:

- The administrator selects a calendar month and year.
- The report uses America/Toronto business time for filtering and display.
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
- Exact policy when GPS is unavailable during external-worksite check-in.
- Behavior when the employee does not respond to the eight-hour notification.
- Absolute maximum monitoring duration for long sessions.
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
