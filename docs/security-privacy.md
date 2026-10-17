# ChantiPoint Security and Privacy v0.1

This document records security and privacy requirements, risks, and release gates. It is not legal advice and does not conclude that employee monitoring is lawful or approved.

## Primary References

- Quebec legislation: [Act respecting the protection of personal information in the private sector](https://www.legisquebec.gouv.qc.ca/en/document/cs/P-39.1)
- Commission d'acces a l'information du Quebec: [Information for private enterprises](https://www.cai.gouv.qc.ca/protection-renseignements-personnels/information-entreprises-privees)
- Commission d'acces a l'information du Quebec: [Collecte de renseignements personnels - entreprises](https://www.cai.gouv.qc.ca/protection-renseignements-personnels/information-entreprises-privees/collecte-renseignements-personnels_entreprises)
- Commission d'acces a l'information du Quebec: [Incidents de confidentialite et mesures de securite - entreprises](https://www.cai.gouv.qc.ca/protection-renseignements-personnels/information-entreprises-privees/incidents-confidentialite-mesures-securite-entreprises)
- Google Play Help: [Understanding location in the background permissions](https://support.google.com/googleplay/android-developer/answer/9799150)
- Apple Developer Documentation: [Core Location](https://developer.apple.com/documentation/corelocation)

## Privacy Position

ChantiPoint processes employee attendance information and sensitive employee location evidence. The developer-approved M2.3b target supersedes the factory-no-GPS rule: foreground fixes may support factory/external classification at arrival and departure, with a third location_unverified outcome. This development approval does not authorize real employee deployment; client/privacy approval, necessity, employee notice, retention, and BYOD safeguards remain release gates. M2.3b.1 adds database foundations only; the legacy factory RPC/Flutter flow still collects no GPS. The employer is expected to lead employee notices, monitoring policy, EFVP, and legal/HR validation. The developer remains responsible for implementing agreed technical security and privacy safeguards.

Employee consent or app permission prompts alone must not be treated as sufficient authorization for monitoring. Privacy approval, retention rules, employee notices, and BYOD expectations remain pending formal validation.

No real employee monitoring may begin before applicable privacy, security, platform, and client approvals.

## Privacy Requirements

| ID | Requirement | Status |
| --- | --- | --- |
| PR-001 | Complete a Privacy Impact Assessment / EFVP where required before real employee monitoring. | Release gate |
| PR-002 | Define the lawful business purpose and necessity of on-duty location verification. | Release gate |
| PR-003 | Provide clear employee notice describing when location is collected, why, by whom, and for how long. | Release gate |
| PR-004 | Target foreground fixes only at authorized attendance actions; future external-worksite monitoring remains separately approved and bounded to active sessions. | Target; revised acquisition/RPCs pending |
| PR-005 | Stop monitoring immediately after checkout or approved session closure. | Required |
| PR-006 | Record unavailable monitoring as inconclusive, not as absence. | Required |
| PR-007 | Define retention and deletion rules separately by data category. | Unresolved |
| PR-008 | Define access and correction procedures for employees. | Unresolved |
| PR-009 | Confirm BYOD expectations, reimbursement/support assumptions, and consequences when permissions are refused or revoked. | Unresolved |
| PR-010 | Confirm Google Play and Apple background-location requirements before store distribution. | Release gate |
| PR-011 | Treat administrator-generated records about identifiable employees as personal information. | Required |
| PR-012 | Factory foreground evidence may support server classification after client/privacy approval; unavailable evidence permits attendance with review and does not prove intent or absence. Factory geofencing/background monitoring is not introduced. | Developer-approved target; deployment approval pending |
| PR-013 | Preserve attendance records, approved corrections, and any approved monthly summaries according to a validated retention policy. | Unresolved |

## Security Requirements

- Use secure authentication for all users.
- Enforce authorization with backend policies and server-side checks.
- Never expose Supabase service-role credentials in Flutter mobile or web clients.
- Use least privilege for administrator access to employee location records.
- Start with one designated administrator and allow more authorized administrators later through scoped roles.
- Use Row Level Security for employee self-access and administrator scoped access.
- Encrypt data in transit through HTTPS/TLS.
- Store secrets outside source control.
- Audit administrative access, correction decisions, automatic checkout review, role changes, session closures, retention actions, and CSV exports.
- Protect duplicate check-in/check-out/location-event requests with idempotency.
- Preserve original records when corrections are approved.
- Validate emulator behavior first, then real-device behavior before any pilot with employee data.
- Keep attendance calculations reproducible from validated sessions and approved corrections.

## Monitoring Boundaries

- The target attempts foreground fixes at check-in and checkout for factory and external attendance; independent outcomes and observable technical reasons must be recorded without blocking otherwise authorized attendance. M2.3b.1 does not implement acquisition or those event/review writes.
- Later continuous/geofence monitoring remains separate, external-worksite scoped, and subject to approval. The foreground target does not add factory geofencing or background tracking.
- No route tracking is included in V1.
- No productivity surveillance is included in V1.
- No location collection occurs after checkout.
- Automatic checkout is disabled until approved evidence rules, privacy gates, and feasibility tests are complete.
- The proposed 10-minute grace period starts from reliable callback/app/backend receipt of exit evidence, not physical departure time.
- Loss of permission, location services, or monitoring availability alone must never trigger automatic checkout. Reliably detected causes are recorded as technical reasons with unavailable/inconclusive status, administrator review, and employee notification when the future feature exists. Record no acknowledgment after 30 minutes while keeping the session active; remind again after approximately one hour if the problem persists. Failure or silence alone is never exit evidence.
- Missing, delayed, or unavailable evidence is not converted into an absence finding.
- The eight-hour notification is not automatic checkout.

Three separate provisional workflows require client, privacy, and technical approval before production:

- **Location failure:** keep the session active until authorized checkout or a separately approved closure supported by sufficient independent evidence; do not treat failure, unanswered notifications, or inability to monitor as absence or intent.
- **Credible geofence exit:** proposed 10-minute grace from reliable receipt of sufficiently credible exit evidence, with a checkout notification. Continue allows another hour before reevaluation and another notification. No response after 30 minutes permits automatic checkout only if approved evidence requirements still hold. Preserve evidence and flag automatic closure for administrator review.
- **Excessive duration:** proposed configurable 16-hour maximum, reminder at 8 hours, stronger warning at 12 hours, final warning at 15 hours 30 minutes, and automatic closure at 16 hours with mandatory administrator review. This administrative duration limit does not prove that all elapsed time was worked.

Exact timing/delivery, exceptions, evidence requirements, and closure timestamps remain subject to approval. These are planning decisions only: M2.3b.1 implements no monitoring, notifications, timers, geofencing, or automatic checkout.

## Retention Design

Retention must be approved before production monitoring or deployment with real employee information. The previously discussed 30-day GPS/geofence period is only an unapproved planning example, not a universal deletion rule.

| Data Category | Candidate Position |
| --- | --- |
| Raw location observations | Configurable period pending legal/business approval. |
| Detailed geofence evidence | Configurable period pending legal/business approval. |
| Work sessions | Pending legal/business approval; must support historical attendance reporting. |
| Monthly attendance summaries | Pending legal/business approval; may need preservation after detailed GPS evidence expires. |
| Correction requests | Pending legal/business approval. |
| Administrator decisions | Pending legal/business approval; not assumed indefinite. |
| Security/audit logs | Pending legal/business approval. |
| Backups | Pending legal/business and operational approval. |

Routine CSV exports should exclude detailed location trails. Monthly employee-hours exports are operational attendance reports, not payroll submissions. Exported files can become sensitive uncontrolled copies and require handling rules.

## Release Gates

| Gate | Required Outcome |
| --- | --- |
| G1 - Client approval | Client approves V1 scope, monitoring model, and unresolved business rules. |
| G2 - Privacy / EFVP | EFVP and privacy review are complete where required. |
| G3 - Employee notice | Monitoring policy and employee-facing notice are approved. |
| G4 - BYOD policy | Device, permission, support, and refusal/revocation expectations are defined. |
| G5 - Retention | Retention and deletion rules are approved separately by data category. |
| G6 - Access controls | RLS, role checks, and audit logging are tested. |
| G7 - Platform permissions | Android/iOS background-location and store requirements are satisfied if used. |
| G8 - Technical validation | Emulator feasibility and later real-device background monitoring behavior are documented. |
| G9 - Incident process | Confidentiality incident and access/correction workflows have owners. |

## Major Risks

- Location monitoring may be considered disproportionate without clear business justification and safeguards.
- The revised factory foreground collection target needs updated necessity, privacy, employee-notice, and retention review before real employee deployment; development approval alone is insufficient.
- BYOD tracking can create employee trust, support, and privacy concerns.
- Background location permissions may be denied by employees or restricted by operating systems.
- Permission revocation, device shutdown, connectivity loss, or background-service termination may not be detected immediately.
- Store review may require prominent disclosure and a strong core-functionality justification.
- Excessive retention or broad admin access could increase legal and security risk.
- CSV exports may create uncontrolled copies of sensitive employee information.
- Automatic checkout could create employment consequences from unreliable evidence if not carefully reviewed.

## Open Decisions

- Formal client approval of monitoring model.
- Whether automatic checkout is allowed in production, and what exceptions apply.
- Thresholds and review presentation for the approved non-blocking foreground workflow; missing/insufficient evidence must not become verified factory attendance.
- Exact handling when location permission or services are disabled but detection is delayed.
- Lunch and break handling, including whether employees punch out or whether any deduction applies.
- Whether monthly attendance totals require formal administrator approval before use.
- Whether daily and weekly reports are added after V1.
- Approval and technical validation of the provisional reminder/acknowledgment rules and configurable 16-hour maximum, including exceptions, notification delivery limits, and auditable closure timestamps.
- Retention period for each data category.
- Correction approval authority and escalation path.
- Android-only pilot versus parallel iOS planning.

## Related Documents

- [Requirements](requirements.md)
- [Architecture](architecture.md)
- [Logical Data Model](data-model.md)
- [Location Feasibility Study](location-feasibility.md)
- [Client Questions in French](client-questions-fr.md)
