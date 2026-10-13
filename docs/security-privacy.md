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

ChantiPoint processes employee attendance information and, for approved external-worksite verification only, sensitive employee location information. Factory/company-premises attendance is digital time attendance and must not request, collect, or store GPS coordinates. The employer is expected to lead employee notices, monitoring policy, EFVP, and legal/HR validation. The developer remains responsible for implementing agreed technical security and privacy safeguards.

Employee consent or app permission prompts alone must not be treated as sufficient authorization for monitoring. Privacy approval, retention rules, employee notices, and BYOD expectations remain pending formal validation.

No real employee monitoring may begin before applicable privacy, security, platform, and client approvals.

## Privacy Requirements

| ID | Requirement | Status |
| --- | --- | --- |
| PR-001 | Complete a Privacy Impact Assessment / EFVP where required before real employee monitoring. | Release gate |
| PR-002 | Define the lawful business purpose and necessity of on-duty location verification. | Release gate |
| PR-003 | Provide clear employee notice describing when location is collected, why, by whom, and for how long. | Release gate |
| PR-004 | Limit location collection to authorized active external-worksite sessions. | Required |
| PR-005 | Stop monitoring immediately after checkout or approved session closure. | Required |
| PR-006 | Record unavailable monitoring as inconclusive, not as absence. | Required |
| PR-007 | Define retention and deletion rules separately by data category. | Unresolved |
| PR-008 | Define access and correction procedures for employees. | Unresolved |
| PR-009 | Confirm BYOD expectations, reimbursement/support assumptions, and consequences when permissions are refused or revoked. | Unresolved |
| PR-010 | Confirm Google Play and Apple background-location requirements before store distribution. | Release gate |
| PR-011 | Treat administrator-generated records about identifiable employees as personal information. | Required |
| PR-012 | Do not collect GPS or use geofencing for factory/company-premises attendance. | Required |
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

- Location is collected only during active external-worksite sessions when authorized and technically supported.
- Factory/company-premises attendance does not use location permissions, GPS coordinates, geofences, or background location monitoring.
- No route tracking is included in V1.
- No productivity surveillance is included in V1.
- No location collection occurs after checkout.
- Automatic checkout is disabled until approved evidence rules, privacy gates, and feasibility tests are complete.
- The proposed 10-minute grace period starts from reliable callback/app/backend receipt of exit evidence, not physical departure time.
- Location disabled or permission revoked can trigger closure only when reliably detected under approved rules.
- Missing, delayed, or unavailable evidence is not converted into an absence finding.
- The eight-hour notification is not automatic checkout.

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
- Collecting GPS for factory/company-premises attendance would violate the current product requirement and data-minimization stance.
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
- Exact behavior when GPS is unavailable during external-worksite check-in.
- Exact handling when location permission or services are disabled but detection is delayed.
- Lunch and break handling, including whether employees punch out or whether any deduction applies.
- Whether monthly attendance totals require formal administrator approval before use.
- Whether daily and weekly reports are added after V1.
- Eight-hour notification no-response behavior.
- Absolute maximum monitoring duration for long sessions.
- Retention period for each data category.
- Correction approval authority and escalation path.
- Android-only pilot versus parallel iOS planning.

## Related Documents

- [Requirements](requirements.md)
- [Architecture](architecture.md)
- [Logical Data Model](data-model.md)
- [Location Feasibility Study](location-feasibility.md)
- [Client Questions in French](client-questions-fr.md)
