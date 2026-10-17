# ChantiPoint Development Status

M2.3b.1 database-foundation work on `feature/manual-attendance`, starting from committed M2.3a `2bcbe87`. The developer reports that factory check-in and checkout succeeded against hosted `chantipoint-dev`. The business-timezone refactor has not been retested on Android; the earlier manual authentication checks below remain developer-reported.

## Completed Slices

| Slice | Result | Verification |
| --- | --- | --- |
| M2.1 - Supabase backend foundation | Initial migration deployed to hosted `chantipoint-dev`; profiles, roles, RLS, attendance RPCs, idempotency, single-active-session protection, and administrative audit safeguards are implemented. | 70 local pgTAP tests passed. |
| M2.2 - Flutter authentication | French password login, active-profile/role authorization, session restoration, resume revalidation, auth-event handling, safe retry states, stale-response protection, and reliable logout are implemented. Android's main manifest includes INTERNET permission. | 62 Flutter automated tests passed; `flutter analyze` passed; developer-reported Android and hosted checks below succeeded. |
| M2.3a - Manual factory attendance | French employee-only active-session, check-in and manual checkout workflow using existing RPCs and RLS reads; configured America/Montreal business time; durable pending-command recovery. | 118 Flutter tests passed, including all 62 authentication tests, RPC response-shape compatibility, and business-timezone coverage; static analysis passed. The developer verified hosted factory check-in and checkout before this timezone refactor. |

M2 as a whole still needs the revised evidence/classification RPCs and client workflow. No production geofencing or automatic checkout is implemented.

## M2.3b.1 Locally Validated Database Foundations

New forward-only migration: `20261016000100_attendance_location_foundations.sql`. It adds nullable all-or-none factory coordinates/radius with range/positive-radius constraints, adds location_unverified to the session context check, adds nullable employee_note text with a 1,000-character limit, and removes the external-only observation guard while preserving active-session/identity checks and all existing coordinate/evidence relationships. No configuration values are seeded. The initial migration, RLS/grants, event types, public RPC signatures/responses, and Flutter files remain unchanged. checkout_reason_code is retained pending a historical data/closure-event audit before later removal.

The approved target is foreground arrival/departure evidence, automatic server classification (factory/external_worksite/location_unverified), non-blocking unavailable GPS with technical event reasons and review, independent outcomes, and a general employee note editable while active/read-only after checkout with eventual edit auditing. Revised RPCs, classification, event/review writes, note updates, and Flutter acquisition are not implemented in this stage. The current Flutter client rejects location_unverified; do not expose new-context records before a coordinated upgrade. Legacy contexts are not retroactively verified location evidence.

Final review applied the migration successfully to the existing local database using `supabase migration up --local`, after confirming only the initial migration was recorded. `supabase test db` passed both suites: M2.1 70/70 and M2.3b.1 71/71, 141 total with zero failures; separate suite runs confirmed each count. The cached PostgreSQL 17.11 and pg_prove images and existing volume were used without reset, data/volume replacement, or downloads. All seven application tables and auth.users were empty before and after validation; test fixtures rolled back. Both migrations remain recorded locally, the database stopped cleanly, and Docker Desktop is stopped. Hosted development was not changed. No SQL, Flutter, or Android changes were made during final review; Flutter/Android integration was not retested. See [Backend Setup](backend-setup.md#m23b1-foundations-and-compatibility) for compatibility and test details.

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

M2.3a validation (historical): `flutter analyze --no-pub`, `flutter test --no-pub --concurrency=1` (118 tests), and `git diff --check` passed. Android integration was not retested.

## Next Implementation Slice

Complete human approval of the locally validated M2.3b.1 foundations, obtain separate authorization before any hosted deployment, then approve M2.3b.2 RPC contracts, evidence quality/boundary/freshness rules, independent outcomes, technical reasons/review updates, active-only note updates/auditing, and pending-command compatibility. The legacy external check-in still raises external_worksite_location_required_pending_policy without coordinates; its replacement must implement the approved non-blocking target. Factory coordinates/radius remain unconfigured until trusted approval. Android business-time display and real process-kill recovery remain separate unverified checks.

After the full manual attendance slice, M3 covers administrator account management, session review, and maps where approved coordinates exist. See [Backlog](backlog.md).

## Outstanding Work and Decisions

- Administrator bootstrap, invitations, account management, and their audit requirements; review/closure of active sessions when an employee is disabled.
- Implement the approved non-blocking location target: quality/boundary/freshness/configuration rules, independent evidence/reason/review contracts, note-edit auditing, and coordinated legacy journal/client migration.
- Audit historical checkout_reason_code values and closure-event consistency before removal.
- Corrections, notifications, monthly attendance reports, and CSV exports; break rules and monthly approval requirements remain open. Separate provisional location-failure, geofence-exit, and configurable 16-hour duration policies are documented in Requirements; client, privacy, and technical approval and implementation remain pending. GPS failure/silence alone never triggers checkout. No notification, timer, geofence, or automatic checkout is implemented in M2.3b.1.
- Real-device location feasibility, approved geofence/evidence rules, automatic-checkout policy, and Android/iOS delivery decisions.
- Formal client scope approval, privacy/EFVP review, employee notice, BYOD expectations, retention by data category, and operational/release validation.

The draft planning documents describe a larger target product than the implemented subset. Completion of M2.1 and M2.2 does not mark these remaining features or production release gates complete.

## Related Documentation

- [Run Flutter with build-time configuration](../README.md#run-the-flutter-app)
- [Backend setup and deployed migration](backend-setup.md)
- [Requirements](requirements.md)
- [Security and Privacy](security-privacy.md)
