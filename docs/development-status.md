# ChantiPoint Development Status

M2.3a implementation snapshot on `feature/manual-attendance`. The developer reports that factory check-in and checkout succeeded against hosted `chantipoint-dev`. The business-timezone refactor has not been retested on Android; the earlier manual authentication checks below remain developer-reported.

## Completed Slices

| Slice | Result | Verification |
| --- | --- | --- |
| M2.1 - Supabase backend foundation | Initial migration deployed to hosted `chantipoint-dev`; profiles, roles, RLS, attendance RPCs, idempotency, single-active-session protection, and administrative audit safeguards are implemented. | 70 local pgTAP tests passed. |
| M2.2 - Flutter authentication | French password login, active-profile/role authorization, session restoration, resume revalidation, auth-event handling, safe retry states, stale-response protection, and reliable logout are implemented. Android's main manifest includes INTERNET permission. | 62 Flutter automated tests passed; `flutter analyze` passed; developer-reported Android and hosted checks below succeeded. |
| M2.3a - Manual factory attendance | French employee-only active-session, check-in and manual checkout workflow using existing RPCs and RLS reads; configured America/Montreal business time; durable pending-command recovery. | 118 Flutter tests passed, including all 62 authentication tests, RPC response-shape compatibility, and business-timezone coverage; static analysis passed. The developer verified hosted factory check-in and checkout before this timezone refactor. |

M2 as a whole still needs the external-worksite attendance workflow and its business decisions. No production geofencing or automatic checkout is implemented.

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

## Factory Attendance Reliability

M2.3a uses server acknowledgements and RLS-protected session reads. The app persists a single pending command per employee in app support storage before sending its RPC, including the original idempotency key and device-observed timestamp. Retries and restart recovery reconcile that intent against server state and reuse its exact payload. An unresolved outcome blocks new commands; it is not full offline synchronization.

The journal contains no auth credentials or GPS data. App-data deletion/uninstall removes it. A corrupt record or an unresolved key conflict blocks new pointages and may require operator assistance; do not clear an uncertain record merely to bypass recovery. Storage access and timezone conversion use the focused `path_provider` and `timezone` dependencies.

The developer verified hosted factory check-in and checkout. Real process-kill recovery on a device remains unverified; local tests include a new controller and file store reading the persisted intent. Android integration was not repeated for the business-timezone refactor.

## Business Timezone

JMService's application configuration now uses `America/Montreal` and the separate French label `heure de Montréal`. The shared business-time module accepts an explicit IANA identifier and optional display label for future regions. The installed `timezone` 0.11.2 default database excludes the Montréal alias; `latest_all.dart` resolves it successfully without a package upgrade. Tests verified alias resolution, winter/summer offsets, spring-forward and fall-back behavior, distinguishable repeated local times, differing UTC/local dates, Vancouver formatting, and preservation of UTC session timestamps and elapsed time.

UTC remains authoritative for stored session timestamps and pending-command payloads. Conversion occurs only for display/calendar interpretation and follows IANA DST rules. Future monthly reports must derive local calendar-month boundaries in the configured business timezone, convert those boundaries to UTC, and use elapsed UTC intervals for totals. Monthly reporting, a timezone settings UI, database timezone configuration, and multi-company timezone workflows are not implemented.

Local validation: `flutter analyze --no-pub`, `flutter test --no-pub --concurrency=1` (118 tests), and `git diff --check` passed. Android integration was not retested.

## Next Implementation Slice

Validate the business-time display on Android and real process-kill recovery using fictional data when authorized. Resolve the external-worksite missing-GPS policy before finalizing that client flow. The backend currently requires check-in coordinates and raises `external_worksite_location_required_pending_policy` when they are absent; this remains a temporary implementation boundary.

After the full manual attendance slice, M3 covers administrator account management, session review, and maps where approved coordinates exist. See [Backlog](backlog.md).

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
