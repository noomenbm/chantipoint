# ChantiPoint Requirements Specification v0.1

This document defines draft product requirements for ChantiPoint before feature development. Documentation version `v0.1` is not the application software version and is not a signed specification.

ChantiPoint is a French-language employee attendance and worksite-presence verification application for one company operating primarily in the Montreal, Quebec region. It initially targets approximately 31-100 employees using personal smartphones. Android is the initial development and deployment priority; iOS remains a future target.

The application records manual check-ins and check-outs and uses location information to help an authorized manager review whether an employee's phone remained near the declared worksite during an active session. Device location must not be presented as certain proof of physical employee presence or actual work performed.

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
- Real employee monitoring must not begin until privacy, security, platform, and client approval gates are satisfied.

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
| REQ-EMP-001 | Employees can manually check in at a workplace. | P0 | Developer-reported requirement | Check-in records employee identity, check-in time, latitude, longitude, accuracy when available, optional site description, and server/device timestamps. |
| REQ-EMP-002 | Employees receive check-in confirmation only after server acknowledgement. | P0 | Developer-reported requirement | A failed or unacknowledged check-in does not silently create an active local-only session. |
| REQ-EMP-003 | Employees can manually check out. | P0 | Developer-reported requirement | Checkout records the source as manual, attempts to capture checkout location when available, closes the session, and stops monitoring. |
| REQ-EMP-004 | Employees can have multiple work sessions per day. | P0 | Developer-reported requirement | Separate sessions can represent separate sites; overlapping active sessions for the same employee are prevented. |
| REQ-EMP-005 | Employees can optionally enter a site or project description. | P1 | Developer-reported requirement | The description is stored with the session and remains distinct from GPS coordinates. |
| REQ-EMP-006 | Employees can submit requests to correct missing or inaccurate punches. | P1 | Developer-reported requirement | A correction request preserves the original record and awaits administrator review. |
| REQ-EMP-007 | After eight hours of an active session, notify the employee and offer `Terminer la session` and `Continuer la session`. | P1 | Developer-reported requirement | Checkout uses the normal validated workflow; continuing preserves the active session and authorized monitoring. No automatic checkout occurs solely because eight hours elapsed. |
| REQ-EMP-008 | Employees are informed when on-duty location monitoring is active, disabled, or unavailable. | P0 | Developer-reported requirement | The employee UI shows monitoring state during active sessions and does not hide unavailable monitoring. |
| REQ-ADM-001 | Administrators can create and manage employee accounts. | P0 | Developer-reported requirement | Only authorized administrators can create, disable, or update employee profiles. |
| REQ-ADM-002 | Administrators can review work sessions. | P0 | Developer-reported requirement | Sessions can be filtered by employee and date and include duration, lifecycle status, review status, checkout source, and relevant events. |
| REQ-ADM-003 | Administrators can review check-in/check-out locations on a map. | P1 | Developer-reported requirement | Session detail includes coordinates and map display for recorded check-in/check-out points. |
| REQ-ADM-004 | Administrators can review departure, return, monitoring unavailable, and automatic-checkout events. | P1 | Developer-reported requirement | Event history distinguishes exit, return, disabled/unavailable monitoring, and automatic closure reasons. |
| REQ-ADM-005 | Administrators can review and resolve correction requests. | P1 | Developer-reported requirement | Approved or rejected requests create audit entries and never overwrite history without trace. |
| REQ-ADM-006 | Administrators can export basic records as CSV. | P1 | Developer-reported requirement | Routine export includes employee ID/name, session ID, optional site description, check-in/out time, duration, checkout source, session status, and review status. Detailed location trails are excluded. |
| REQ-ADM-007 | Start with one designated administrator while keeping the role model extensible. | P1 | Developer-reported requirement | Additional authorized administrators can be added later without redesigning core data access. |
| REQ-LOC-001 | Check-in coordinates define the provisional geofence center. | P0 | Proposed technical design | The active session stores the check-in coordinate as the candidate center unless feasibility testing rejects the approach. |
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
| REQ-DATA-006 | Record GPS accuracy where available. | P0 | Developer-reported requirement | Location evidence includes accuracy metadata or an explicit unavailable value. |
| REQ-DATA-007 | Separate session lifecycle status, correction/review status, and monitoring availability/status. | P0 | Proposed technical design | The logical data model avoids overloading one status field for unrelated concerns. |
| REQ-SEC-001 | Never expose Supabase service-role credentials in Flutter clients. | P0 | Developer-reported requirement | Mobile and web clients use user-scoped credentials only. |
| REQ-PRIV-001 | Treat privacy approval as a release gate. | P0 | Developer-reported requirement | EFVP, employee notice, retention, and access-control decisions are complete before real monitoring. |
| REQ-PRIV-002 | Employee consent alone is not assumed sufficient for tracking. | P0 | Developer-reported requirement | Release documentation records employer responsibility for lawful, necessary, and proportionate monitoring. |
| REQ-PRIV-003 | Separate retention policy by data category. | P0 | Developer-reported requirement | Raw location observations, work sessions, correction requests, administrator decisions, audit logs, and backups have separately approved retention rules. |
| REQ-PRIV-004 | Use approximately 30 days as a candidate retention period for detailed GPS/geofence evidence. | P1 | Open decision | Final retention remains pending business/legal validation; administrator-generated records are still personal information and are not assumed indefinite. |

## Main Workflows

### Check-In

1. The employee arrives at the assigned workplace.
2. The employee opens ChantiPoint and authenticates if necessary.
3. The employee taps the French UI check-in action.
4. The app obtains a GPS location fix and optional site description.
5. The app submits the check-in to the backend.
6. The backend validates the request, records the event, and acknowledges success.
7. The employee receives confirmation and the work session becomes active.

Acceptance criteria:

- No active session is created without server acknowledgement.
- Check-in records authenticated identity, location, accuracy, optional description, server receipt time, and device-observed time.
- The server rejects overlapping active sessions for the same employee.

### On-Duty Location Verification

Geofencing is the preferred candidate, but not yet validated or approved for production.

Proposed behavior:

- Establish a temporary geofence centered on the check-in location.
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

Desired business behavior is automatic checkout when the employee disables location services or revokes required permissions during an active work session. The technical design must also record the limitation that the application may not immediately detect permission revocation, device shutdown, connectivity loss, or background-service termination.

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
2. The app obtains the current location when available.
3. The backend records the checkout event and closes the session.
4. Location monitoring stops.
5. The employee receives confirmation.

Acceptance criteria:

- Checkout source is recorded as manual.
- Monitoring stops after the server accepts session closure.
- Missing checkout location does not fabricate coordinates.

### Multiple Work Locations

Each physical work location is normally represented by a separate work session. GPS coordinates and optional descriptions help the administrator interpret where the employee worked, but coordinates alone do not identify an employer-assigned project.

### Forgotten or Incorrect Check-Outs

The earlier concept of a separate 10-minute forgotten-checkout reminder is removed because V1 has no scheduled shift-end time from which to calculate it. The departure grace period and eight-hour notification are separate mechanisms.

Forgotten or incorrect punches are handled through correction requests, administrator review, and audit history.

## V1 Exclusions

The initial version does not include:

- Payroll integration or automated payroll calculations.
- Employee scheduling.
- Customer invoicing.
- Sophisticated project management.
- Route tracking.
- Full-time employee tracking outside work sessions.
- Automatic site-to-site transfers.
- Offline synchronization.
- Complex geolocation anti-spoofing.
- Attendance biometrics.
- Employee productivity surveillance.

Basic session duration totals and operational CSV exports are allowed. They are not payroll integration.

## Open Requirements

- Formal client approval of the draft specification.
- Final automatic checkout approval, exceptions, and dispute workflow.
- Final geofence radius and tolerance after feasibility testing.
- Final evidence requirements for automatic checkout.
- Behavior when the employee does not respond to the eight-hour notification.
- Absolute maximum monitoring duration for long sessions.
- Correction approval process and escalation rules.
- Final retention and deletion periods by data category.
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
