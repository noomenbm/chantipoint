# ChantiPoint Backlog v0.1

This backlog is intentionally small and incremental for one developer working approximately 5-7 hours per week. It is documentation for planning only; no production feature implementation starts until these documents are reviewed.

## Milestone Order

| Milestone | Goal | Primary Requirements | Exit Criteria |
| --- | --- | --- | --- |
| M0 | Engineering requirements and documentation | REQ-PV-001, REQ-PV-002, REQ-PRIV-001 | Draft docs reviewed; approval classification and open decisions are clear. |
| M1 | Android geofencing technical feasibility prototype | REQ-LOC-001 through REQ-LOC-008, REQ-DATA-005 | Completed on `spike/android-geofencing` at commit `96e27bb`; emulator findings are documented, but real-device background reliability remains unresolved. |
| M2 | Supabase authentication and manual attendance vertical slice | REQ-AUTH-001, REQ-EMP-001 through REQ-EMP-005, REQ-EMP-009 through REQ-EMP-011, REQ-DATA-001 through REQ-DATA-008, REQ-SEC-001 | Authenticated Android employee can select factory or external worksite, check in, and manually check out with server acknowledgement and no overlapping active sessions; factory sessions require no GPS. |
| M3 | Administrator account management, session review, and map | REQ-ADM-001 through REQ-ADM-004, REQ-ADM-007 | Designated administrator can manage employee accounts and review sessions, statuses, anomalies, location context, and check-in/out map points where coordinates exist. |
| M4 | Corrections, notifications, and operational reports | REQ-EMP-006, REQ-EMP-007, REQ-ADM-005, REQ-ADM-006, REQ-ADM-008 through REQ-ADM-010 | Corrections, eight-hour notification, monthly employee-hours report, and approved CSV export fields work without detailed location trails. |
| M5 | Approved location-verification integration | REQ-LOC-001 through REQ-LOC-008, REQ-PRIV-001 through REQ-PRIV-004 | Starts only if feasibility, privacy, platform, and client approval gates pass. |
| M6 | Security, privacy, testing, pilot hardening, and release | All approved P0/P1 requirements | Pilot-ready Android build, documented operations, validated access controls, retention rules, and support process. |

## Suggested Next Implementation Milestone

M1 is complete as an emulator feasibility spike on `spike/android-geofencing` at commit `96e27bb`. The spike supports continued investigation but does not validate production geofencing.

Start M2 next: Supabase authentication and the manual attendance vertical slice.

Acceptance criteria:

- Authenticated employee can select `À l'usine` or `Chantier extérieur` at check-in.
- Factory/company-premises sessions record timestamps only and do not request location permissions or GPS.
- External-worksite sessions can capture check-in GPS coordinates when available, while production geofencing remains deferred; GPS-unavailable behavior remains unresolved pending a business rule.
- Server acknowledgement is required before the employee sees an active session.
- Overlapping active sessions and duplicate commands are rejected or deduplicated server-side.

This milestone intentionally does not implement production geofencing or automatic checkout.

## Detailed Tasks

| ID | Task | Requirement Trace | Dependencies | Acceptance Criteria |
| --- | --- | --- | --- | --- |
| BL-001 | Review documentation with the human developer. | M0 | Current docs | Confirm assumptions, approval classification, and unresolved requirements. |
| BL-002 | Review client questions and approval status. | REQ-LOC-004, REQ-PRIV-001, REQ-PRIV-004 | [client-questions-fr.md](client-questions-fr.md) | Open decisions are reviewed without treating questions as approval. |
| BL-003 | Confirm privacy and legal release gates. | REQ-PRIV-001 through REQ-PRIV-004 | Client/legal input | EFVP, notice, BYOD, retention, and access responsibilities have owners. |
| BL-004 | Create isolated Android geofence prototype plan. | REQ-LOC-001, REQ-LOC-002 | M0 review | Prototype scope excludes production data and real employees. |
| BL-005 | Configure emulator simulated GPS test workflow. | REQ-LOC-002 | BL-004 | Simulated location movement can be repeated and documented. |
| BL-006 | Test geofence registration at 100m and document 150m status. | REQ-LOC-001, REQ-LOC-003 | BL-005 | 100m registration success/failure is recorded; if 150m is not separately tested, that limitation is explicit. |
| BL-007 | Test simulated exit and return callbacks. | REQ-LOC-003, REQ-DATA-005 | BL-006 | Callback/receipt timestamp is captured; original event timestamp is recorded only if supplied and otherwise marked unavailable. |
| BL-008 | Test delayed event and 10-minute grace simulation. | REQ-LOC-003, REQ-LOC-004 | BL-007 | Simulated grace-period behavior is measurable and documented. |
| BL-009 | Test disabled or unavailable monitoring states. | REQ-LOC-006, REQ-LOC-008 | BL-006 | Permission/location-disabled/unavailable states do not become false absence assertions. |
| BL-010 | Test simulated automatic checkout candidate. | REQ-LOC-004, REQ-LOC-005 | BL-008, BL-009 | Candidate closure records source, reason, and evidence summary; no production closure is implemented. |
| BL-011 | Test geofence cleanup/unregistration. | REQ-LOC-007 | BL-006 | Prototype demonstrates cleanup after simulated checkout. |
| BL-012 | Produce feasibility report and recommendation. | REQ-LOC-001 through REQ-LOC-008 | BL-005 through BL-011 | Recommendation covers geofence, periodic GPS, hybrid, or manual-review-only path and identifies real-device field tests. |
| BL-013 | Create approved Supabase development project. | REQ-AUTH-001, REQ-DATA-002 | Human approval after M1 | Dev project exists; secrets are not committed. |
| BL-014 | Define initial schema migrations. | REQ-DATA-001 through REQ-DATA-008 | [data-model.md](data-model.md), BL-013 | Schema supports profiles, roles, sessions, location context, events, monitoring status, corrections, retention, report calculations, and audit without circular mandatory event references. |
| BL-015 | Implement RLS and server-side command boundaries. | REQ-DATA-002, REQ-SEC-001 | BL-014 | Employees cannot access other employees' records; admin access is scoped. |
| BL-016 | Add Flutter authentication flow. | REQ-AUTH-001 | BL-013, BL-015 | User can sign in and sign out on Android. |
| BL-017 | Add manual check-in command and UI. | REQ-EMP-001, REQ-EMP-002, REQ-EMP-005, REQ-EMP-009 through REQ-EMP-011 | BL-015, BL-016 | Server acknowledgement is required before active session state is shown; employee selects factory or external worksite; factory check-in does not request GPS. |
| BL-018 | Add manual checkout command and UI. | REQ-EMP-003, REQ-LOC-007 | BL-017 | Checkout closes the session and records source as manual; factory checkout does not request GPS. |
| BL-019 | Add basic employee active-session and monitoring-status display. | REQ-EMP-008 | BL-017 | Employee sees active, pending, disabled, unavailable, not-applicable, or closed state clearly. |
| BL-020 | Add session overlap and idempotency protections. | REQ-EMP-004, REQ-DATA-001, REQ-DATA-003 | BL-014, BL-017 | Duplicate commands and overlapping active sessions are rejected or deduplicated server-side while allowing multiple non-overlapping sessions per day. |
| BL-031 | Build administrator employee-account management. | REQ-ADM-001, REQ-ADM-007 | BL-015 | Designated administrator can create, disable, and update employee profiles; the role model remains extensible for additional administrators later. |
| BL-021 | Build admin session list and filters. | REQ-ADM-002 | BL-015 | Manager filters by employee/date/location context and sees lifecycle/review status. |
| BL-022 | Add map display for check-in/check-out points. | REQ-ADM-003 | BL-021 | Manager can inspect recorded external-worksite coordinates without implying certainty; factory sessions show no map point. |
| BL-023 | Add anomaly and automatic-checkout review view. | REQ-ADM-004, REQ-LOC-004 | BL-021 | Manager can review source, reason, and evidence summary. |
| BL-024 | Add correction request submission. | REQ-EMP-006 | BL-018 | Employee can submit a request without altering original records. |
| BL-025 | Add correction review and audit. | REQ-ADM-005 | BL-024 | Administrator approval/rejection creates audit history and review status. |
| BL-026 | Add eight-hour active-session notification. | REQ-EMP-007 | BL-019, notification channel decision | Employee can choose checkout or continue; no-response behavior remains controlled by approved policy. |
| BL-027 | Add monthly employee-hours report and CSV export. | REQ-ADM-006, REQ-ADM-008 through REQ-ADM-010, REQ-DATA-008 | BL-021, BL-025 | Administrator selects month/year, sees per-employee totals in hours/minutes, flags incomplete/disputed/corrected sessions, and exports CSV without detailed location trails. |
| BL-028 | Define and implement approved retention controls. | REQ-PRIV-003, REQ-PRIV-004 | Privacy/legal approval | Retention rules are recorded by data category. |
| BL-029 | Integrate approved location-verification behavior. | REQ-LOC-001 through REQ-LOC-008 | BL-012, BL-028, client approval | Production behavior matches approved evidence rules and monitoring boundaries. |
| BL-030 | Pilot access-control, privacy, and release validation. | REQ-SEC-001, REQ-PRIV-001, REQ-PRIV-002 | M2-M5 as applicable | RLS, audit logs, notices, retention, and platform requirements are verified. |

## Requirement Traceability Summary

| Requirement | Backlog Tasks |
| --- | --- |
| REQ-PV-001, REQ-PV-002 | BL-001, BL-021, BL-022, BL-023 |
| REQ-UI-001 | BL-017, BL-018, BL-026 |
| REQ-AUTH-001 | BL-013, BL-016 |
| REQ-EMP-001, REQ-EMP-002, REQ-EMP-005, REQ-EMP-009 through REQ-EMP-011 | BL-017 |
| REQ-EMP-003 | BL-018 |
| REQ-EMP-004 | BL-020, BL-027 |
| REQ-EMP-006 | BL-024, BL-025 |
| REQ-EMP-007 | BL-026 |
| REQ-EMP-008 | BL-019 |
| REQ-ADM-001, REQ-ADM-007 | BL-031 |
| REQ-ADM-002 | BL-021 |
| REQ-ADM-003 | BL-022 |
| REQ-ADM-004 | BL-023 |
| REQ-ADM-005 | BL-025 |
| REQ-ADM-006, REQ-ADM-008 through REQ-ADM-010 | BL-027 |
| REQ-LOC-001, REQ-LOC-002 | BL-004, BL-006, BL-012, BL-029 |
| REQ-LOC-003 | BL-006, BL-007, BL-008, BL-012, BL-029 |
| REQ-LOC-004, REQ-LOC-005 | BL-008, BL-010, BL-023, BL-029 |
| REQ-LOC-006, REQ-LOC-008 | BL-009, BL-012, BL-029 |
| REQ-LOC-007 | BL-011, BL-018, BL-029 |
| REQ-DATA-001, REQ-DATA-003 | BL-020 |
| REQ-DATA-002, REQ-SEC-001 | BL-015, BL-030 |
| REQ-DATA-004, REQ-DATA-005, REQ-DATA-006 | BL-007, BL-014, BL-017, BL-018 |
| REQ-DATA-007 | BL-014 |
| REQ-DATA-008 | BL-014, BL-027 |
| REQ-PRIV-001, REQ-PRIV-002 | BL-003, BL-030 |
| REQ-PRIV-003, REQ-PRIV-004 | BL-002, BL-003, BL-028 |

## Technical Dependencies

- Flutter and Dart development environment.
- Android emulator with simulated GPS movement for first feasibility stage.
- Real Android devices for later field validation before production.
- Supabase development project after human approval.
- Map provider decision and API key handling.
- Notification delivery decision for the eight-hour notification.
- Client-approved privacy notice, retention, EFVP, and BYOD expectations.

## Release Gates

- Privacy Impact Assessment / EFVP is completed where required.
- Employee notice and monitoring policy are approved.
- Background location permissions and store requirements are satisfied if used.
- Real-device monitoring behavior is measured and documented after emulator feasibility.
- Security review confirms no service-role secrets in clients.
- RLS and audit behavior are tested.
- Retention and deletion rules are approved by data category.

## Related Documents

- [Requirements](requirements.md)
- [Architecture](architecture.md)
- [Location Feasibility Study](location-feasibility.md)
- [Security and Privacy](security-privacy.md)
