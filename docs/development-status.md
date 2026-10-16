# ChantiPoint Development Status

M2.2 completion snapshot, recorded 2026-10-15 on `feature/manual-attendance`. Automated results and manual checks below reflect the development work and the developer's verification report.

## Completed Slices

| Slice | Result | Verification |
| --- | --- | --- |
| M2.1 - Supabase backend foundation | Initial migration deployed to hosted `chantipoint-dev`; profiles, roles, RLS, attendance RPCs, idempotency, single-active-session protection, and administrative audit safeguards are implemented. | 70 local pgTAP tests passed. |
| M2.2 - Flutter authentication | French password login, active-profile/role authorization, session restoration, resume revalidation, auth-event handling, safe retry states, stale-response protection, and reliable logout are implemented. Android's main manifest includes INTERNET permission. | 62 Flutter automated tests passed; `flutter analyze` passed; developer-reported Android and hosted checks below succeeded. |

The authenticated screen remains a placeholder. M2 as a whole still needs the Flutter manual attendance workflow. No production geofencing or automatic checkout is implemented.

## Manual Authentication Verification

The developer verified the following using a fictional development account:

- The app launched successfully on the Android emulator.
- Real login against hosted `chantipoint-dev` succeeded and recognized the active employee profile and role.
- Logout succeeded.
- The session survived Android app task removal and Force stop, and was restored when the app reopened.
- Disabling the employee profile removed application access when the app resumed.
- Re-enabling the profile allowed login again.

These checks cover development authentication. Production release and real-device background location reliability remain unvalidated.

## Accounts and Session Boundaries

Public signup is disabled. V1 account policy is administrator invitation only. The current hosted-development account used for testing is fictional and was provisioned through trusted backend administration. Application workflows for initial administrator provisioning, inviting employees, and managing account activation are still to be implemented. No account identifiers or credentials belong in this document.

Application access requires an active profile and at least one active recognized role. Authorization is checked after login, during session restoration, on resume, and on relevant authentication events. Definitive profile/role denial removes access and clears the session. Temporary network, backend, or query-permission failures hide authenticated content and preserve an otherwise valid session for retry. Logout prevents repeated actions and distinguishes a retained session from local logout whose server confirmation failed.

Revocations are rechecked on resume and relevant events; this is not continuous role monitoring. The app does not introduce polling, GPS collection, or background tracking through authentication.

## Next Implementation Slice

Continue M2 with **manual factory attendance** (BL-017 through BL-020):

- Use the deployed `check_in` and `check_out` RPCs through a Flutter repository/controller boundary.
- Show server-confirmed active-session state and support manual checkout.
- Reuse the original idempotency key and request payload for retries, and handle overlap or duplicate-command errors in French.
- Keep factory attendance independent of location permissions, GPS, and geofencing.

External-worksite attendance remains part of the broader M2 scope. Its missing-GPS business rule needs resolution before the client flow is finalized. The backend currently requires external-worksite check-in coordinates and raises `external_worksite_location_required_pending_policy` when they are absent; this is a temporary implementation boundary.

After the manual attendance slice, M3 covers administrator account management, session review, and maps where approved coordinates exist. See [Backlog](backlog.md).

## Outstanding Work and Decisions

- Administrator bootstrap, invitations, account management, and their audit requirements; review/closure of active sessions when an employee is disabled.
- External-worksite check-in behavior when GPS is unavailable, and whether checkout location is mandatory or optional.
- Corrections, notifications, monthly attendance reports, and CSV exports; break rules, monthly approval requirements, and eight-hour notification no-response behavior remain open.
- Real-device location feasibility, approved geofence/evidence rules, automatic-checkout policy, and Android/iOS delivery decisions.
- Formal client scope approval, privacy/EFVP review, employee notice, BYOD expectations, retention by data category, and operational/release validation.

The draft planning documents describe a larger target product than the implemented subset. Completion of M2.1 and M2.2 does not mark these remaining features or production release gates complete.

## Related Documentation

- [Run Flutter with build-time configuration](../README.md#run-the-flutter-app)
- [Backend setup and deployed migration](backend-setup.md)
- [Requirements](requirements.md)
- [Security and Privacy](security-privacy.md)
