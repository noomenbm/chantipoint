# ChantiPoint Backlog v0.1

This backlog is intentionally small and incremental for one developer working approximately 5-7 hours per week. It describes the target scope; see [Development Status](development-status.md) for the implemented subset and verification results. M2.1 backend foundation and M2.2 Flutter authentication are complete; the full M2 attendance slice remains open.

## Milestone Order

| Milestone | Goal | Primary Requirements | Exit Criteria |
| --- | --- | --- | --- |
| M0 | Engineering requirements and documentation | REQ-PV-001, REQ-PV-002, REQ-PRIV-001 | Draft docs reviewed; approval classification and open decisions are clear. |
| M1 | Android geofencing technical feasibility prototype | REQ-LOC-001 through REQ-LOC-008, REQ-DATA-005 | Completed on `spike/android-geofencing` at commit `96e27bb`; emulator findings are documented, but real-device background reliability remains unresolved. |
| M2 | Supabase authentication and manual attendance vertical slice | REQ-AUTH-001, REQ-EMP-001 through REQ-EMP-005, REQ-EMP-009 through REQ-EMP-012, REQ-DATA-001 through REQ-DATA-008, REQ-SEC-001 | Target: authenticated employee checks in/out without selecting authoritative mode; backend classifies factory/external_worksite/location_unverified, missing evidence permits attendance with review, and commands remain atomic/idempotent with no overlapping active sessions. M2.3b.1 provides foundations only. |
| M3 | Administrator account management, session review, and map | REQ-ADM-001 through REQ-ADM-004, REQ-ADM-007 | Designated administrator can manage employee accounts and review sessions, statuses, anomalies, location context, and check-in/out map points where coordinates exist. |
| M4 | Corrections, notifications, and operational reports | REQ-EMP-006, REQ-EMP-007, REQ-ADM-005, REQ-ADM-006, REQ-ADM-008 through REQ-ADM-010 | Corrections, eight-hour notification, monthly employee-hours report, and approved CSV export fields work without detailed location trails. |
| M5 | Approved location-verification integration | REQ-LOC-001 through REQ-LOC-008, REQ-PRIV-001 through REQ-PRIV-004 | Starts only if feasibility, privacy, platform, and client approval gates pass. |
| M6 | Security, privacy, testing, pilot hardening, and release | All approved P0/P1 requirements | Pilot-ready Android build, documented operations, validated access controls, retention rules, and support process. |

## Next Implementation Slice

M2.1 is deployed to `chantipoint-dev` with 70 local pgTAP tests passed. M2.2 authentication is complete with 62 Flutter tests, static analysis, and developer-verified Android/hosted login checks. Public signup is disabled; the current development account is fictional. Administrator provisioning and invitation management remain future M3 work.

M2.3a implements the legacy factory check-in/check-out flow and server-confirmed display; developer-hosted checks succeeded. Its Flutter/RPC behavior remains unchanged and collects no GPS. M2.3b.1 prepares nullable factory configuration, location_unverified schema support, employee_note storage, and active-session observations for all contexts. Final-review local application succeeded without a reset; both pgTAP suites passed (70 + 71 = 141, zero failures). Hosted deployment remains pending separate approval, and local database/Docker resources are stopped with the existing volume retained.

M2.3b.2a implements gated server-authoritative RPCs, atomic event/evidence/reason/review writes, independent outcomes and hash-checked replay. Local validation passed 568 pgTAP assertions plus four real concurrency scenarios (26 assertions). Next, M2.3b.2b covers overwrite-only employee notes without history, followed by coordinated Flutter/journal integration and approved deployment/cutover. Revised Flutter acquisition/classification UI is not implemented. The current client rejects location_unverified; coordinate the cutover rather than expose new-context records prematurely. Reuse original pending payloads/keys, and audit historical checkout_reason_code values and closure events before a later removal.

Business-time handling is centralized in application configuration and reusable IANA conversion/formatting, with `America/Montreal` for JMService and a separate French display label. Other IANA regions can use the same logic; database-configurable company timezones and timezone settings UI are not implemented. Future reports must use this configured timezone policy.

Broader M2 acceptance criteria:

- Target employees do not select authoritative mode; backend classification uses evidence and trusted factory configuration, with factory, external_worksite, or location_unverified outcomes.
- Future foreground fixes may be captured at both factory and external arrival/departure; classification and acquisition are not part of M2.3b.1.
- Missing/insufficient location must permit otherwise authorized attendance with technical event reasons and review flags; the gated v2 backend implements independent arrival/departure outcomes, with client cutover pending. Future geofencing/monitoring is separate and deferred.
- Server acknowledgement is required before the employee sees an active session.
- Overlapping active sessions and duplicate commands are rejected or deduplicated server-side.

Production geofencing and automatic checkout remain deferred. M1 emulator findings support investigation only; real-device reliability and approval gates remain open. M3 administrator account management and review follow the manual attendance slice.

## Detailed Tasks

| ID | Task | Requirement Trace | Dependencies | Acceptance Criteria |
| --- | --- | --- | --- | --- |
| BL-001 | Review documentation with the human developer. | M0 | Current docs | Confirm assumptions, approval classification, and unresolved requirements. |
| BL-002 | Review client questions and approval status. | REQ-LOC-004, REQ-PRIV-001, REQ-PRIV-004 | [client-questions-fr.md](client-questions-fr.md) | Open decisions are reviewed without treating questions as approval. |
| BL-003 | Confirm privacy and legal release gates. | REQ-PRIV-001 through REQ-PRIV-004 | Client/legal input | EFVP, notice, BYOD, retention, and access responsibilities have owners. |
| BL-004 | Create isolated Android geofence prototype plan. | REQ-LOC-001, REQ-LOC-002 | M0 review | Prototype scope excludes production data and real employees. |
| BL-005 | Configure emulator simulated GPS test workflow. | REQ-LOC-002 | BL-004 | Simulated location movement can be repeated and documented. |
| BL-006 | Test geofence registration at both 100m and 150m. | REQ-LOC-001, REQ-LOC-003 | BL-005 | Record registration success/failure for both radii. 100m: tested in M1; 150m: still pending validation. |
| BL-007 | Test simulated exit and return callbacks. | REQ-LOC-003, REQ-DATA-005 | BL-006 | Callback/receipt timestamp is captured; original event timestamp is recorded only if supplied and otherwise marked unavailable. |
| BL-008 | Test delayed event and 10-minute grace simulation. | REQ-LOC-003, REQ-LOC-004 | BL-007 | Simulated grace-period behavior is measurable and documented. |
| BL-009 | Test disabled or unavailable monitoring states. | REQ-LOC-006, REQ-LOC-008 | BL-006 | Permission/location-disabled/unavailable states do not become false absence assertions or automatic checkout triggers. Future tests must cover reason/review/notification, no acknowledgment at 30 minutes with the session active, and a reminder after approximately one hour. |
| BL-010 | Test simulated automatic checkout candidate. | REQ-LOC-004, REQ-LOC-005 | BL-008, BL-009 | Candidate closure records source, reason, and evidence summary; no production closure is implemented. |
| BL-011 | Test geofence cleanup/unregistration. | REQ-LOC-007 | BL-006 | Prototype demonstrates cleanup after simulated checkout. |
| BL-012 | Produce feasibility report and recommendation. | REQ-LOC-001 through REQ-LOC-008 | BL-005 through BL-011 | Recommendation covers geofence, periodic GPS, hybrid, or manual-review-only path and identifies real-device field tests. |
| BL-013 | Create approved Supabase development project. | REQ-AUTH-001, REQ-DATA-002 | Human approval after M1 | Dev project exists; secrets are not committed. |
| BL-014 | Define initial schema migrations. | REQ-DATA-001 through REQ-DATA-008 | [data-model.md](data-model.md), BL-013 | Schema supports profiles, roles, sessions, location context, events, monitoring status, corrections, retention, report calculations, and audit without circular mandatory event references. |
| BL-015 | Implement RLS and server-side command boundaries. | REQ-DATA-002, REQ-SEC-001 | BL-014 | Employees cannot access other employees' records; admin access is scoped. |
| BL-016 | Add Flutter authentication flow. | REQ-AUTH-001 | BL-013, BL-015 | User can sign in and sign out on Android. |
| BL-017 | Add manual check-in command and UI. | REQ-EMP-001, REQ-EMP-002, REQ-EMP-005, REQ-EMP-009 through REQ-EMP-011 | BL-015, BL-016 | Target: server acknowledgement, server-derived three-way classification, automatic factory name, optional external/unverified description, and non-blocking unavailable evidence with technical reason/review. The v2 backend is implemented behind the legacy gate; coordinated Flutter cutover remains pending. |
| BL-018 | Add manual checkout command and UI. | REQ-EMP-003, REQ-LOC-007 | BL-017 | Target: manual atomic closure with independent foreground departure evidence; unavailable GPS does not block checkout, and reason/review state remains auditable. The v2 backend is implemented behind the legacy gate; coordinated Flutter cutover remains pending. |
| BL-019 | Add basic employee active-session and monitoring-status display. | REQ-EMP-008 | BL-017 | Employee sees active, pending, disabled, unavailable, not-applicable, or closed state clearly. |
| BL-020 | Add session overlap and idempotency protections. | REQ-EMP-004, REQ-DATA-001, REQ-DATA-003 | BL-014, BL-017 | Duplicate commands and overlapping active sessions are rejected or deduplicated server-side while allowing multiple non-overlapping sessions per day. |
| BL-032 | Add employee general business/session-note editing. | REQ-EMP-012 | BL-017, BL-018 | One optional note, at most 1,000 characters; owner-authorized saves overwrite while active, including a final edit atomic with manual checkout, then read-only. No note history, versions, correction/audit events or revision metadata. Deferred to M2.3b.2b; M2.3b.2a does not edit notes. |
| BL-031 | Build administrator employee-account management. | REQ-ADM-001, REQ-ADM-007 | BL-015 | Designated administrator can create, disable, and update employee profiles; the role model remains extensible for additional administrators later. |
| BL-021 | Build admin session list and filters. | REQ-ADM-002 | BL-015 | Manager filters by employee/date/location context and sees lifecycle/review status. |
| BL-022 | Add map display for check-in/check-out points. | REQ-ADM-003 | BL-021 | Target: manager can inspect genuine recorded arrival/departure evidence for factory or external attendance without implying certainty; unavailable location never fabricates a map point. Revised collection remains pending. |
| BL-023 | Add anomaly and automatic-checkout review view. | REQ-ADM-004, REQ-LOC-004 | BL-021 | Manager can review source, reason, and evidence summary. |
| BL-024 | Add correction request submission. | REQ-EMP-006 | BL-018 | Employee can submit a request without altering original records. |
| BL-025 | Add correction review and audit. | REQ-ADM-005 | BL-024 | Administrator approval/rejection creates audit history and review status. |
| BL-026 | Add active-session notifications and approved duration safeguards. | REQ-EMP-007, REQ-LOC-004, REQ-LOC-008 | BL-019, notification channel decision, client/privacy/technical approval | Separate failure, exit, and duration workflows follow the provisional requirements. Location failure/silence never closes a session; exit uses proposed 10-minute grace, checkout notification, another hour after continue, and a 30-minute no-response evidence gate. Proposed configurable 16-hour maximum: warnings at 8h, 12h, 15h30; automatic closure at 16h requires administrator review and does not prove time worked. Planning only in M2.3b.1. |
| BL-027 | Add monthly employee-hours report and CSV export. | REQ-ADM-006, REQ-ADM-008 through REQ-ADM-010, REQ-DATA-008 | BL-021, BL-025 | Administrator selects month/year; calendar-month boundaries use the configured business timezone (currently America/Montreal) and IANA DST rules before conversion to UTC. Totals use elapsed UTC intervals, handle cross-month sessions, flag incomplete/disputed/corrected sessions, and export CSV without detailed location trails. |
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
| REQ-EMP-012 | BL-032 |
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
