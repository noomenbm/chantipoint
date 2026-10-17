# ChantiPoint

ChantiPoint is an Android-first, French-language Flutter attendance application for JMService, using Supabase Auth and PostgreSQL with Row Level Security (RLS).

The current Flutter app provides authentication and a manual factory attendance screen for M2.3a. Employees can read their active session, check in at the factory, and manually check out after server acknowledgement. The developer verified factory check-in and checkout against hosted `chantipoint-dev`; the business-timezone refactor has not been retested on Android. This legacy Flutter flow still collects no GPS. The approved M2.3b target instead attempts foreground fixes for factory and external attendance, derives classification on the backend, and permits unavailable evidence with review. The v2 RPCs are implemented locally behind a legacy-mode gate; Flutter acquisition and coordinated cutover remain pending. Location evidence is limited evidence from a device, not certain proof of employee presence or work performed.

## Current Development State

- **M2.1 complete:** the initial database foundation is deployed to the hosted development project `chantipoint-dev`; 70 local pgTAP tests passed.
- **M2.2 complete:** Flutter authentication and reliability improvements are implemented; 62 automated Flutter tests and static analysis passed.
- Android emulator launch, hosted login, profile/role recognition, logout, session persistence, and disabled-profile checks were verified by the developer. See [Development Status](docs/development-status.md) for the recorded checks and remaining work.
- Public signup is disabled. V1 uses administrator-invited accounts. The account used for current development checks is fictional; administrator provisioning and the employee invitation workflow are not implemented in the app.

M2.3b.1 adds nullable factory configuration, `location_unverified`, employee note storage, and observations for any supported active-session context. The forward-only migration was applied to the existing local database without a reset; both pgTAP suites passed (70 + 71 = 141 tests). It is not deployed to hosted development and changes no attendance RPCs, client write grants, or Flutter behavior. See [Backend Setup](docs/backend-setup.md#m23b1-foundations-and-compatibility) for validation and compatibility details.

M2.3b.2a implements the gated server-authoritative attendance contract locally: 568 pgTAP assertions passed (the original 141 plus 427 new), along with four real concurrency scenarios. Hosted resources and Flutter are unchanged; v2 writes remain disabled until an approved cutover. See [Attendance Backend Contract](docs/attendance-backend-contract.md) for exact signatures, evidence handling, replay and deployment boundaries.

M2.3b.2b adds owner-only overwrite notes and atomic preserve/replace/clear at v2 checkout. All 664 pgTAP assertions passed (568 existing plus 96 new); both concurrency harnesses passed nine scenarios and 54 assertions. No note history is retained. Note UI/journal integration and hosted deployment remain pending; the gate is still legacy mode 1.

Requirements v0.1 remain a draft. Completed development checks do not establish production readiness; privacy, business rules, operational controls, and location feasibility still have open decisions.

## Run the Flutter App

Use an existing, trusted-provisioned fictional development account. Install Flutter/Dart and resolve dependencies:

```powershell
flutter pub get
```

Supply the project URL and publishable client key as build-time Dart defines. Replace these placeholders locally; do not put account credentials or actual configuration values into this documentation:

```powershell
$env:SUPABASE_URL = 'https://<project-ref>.supabase.co'
$env:SUPABASE_PUBLISHABLE_KEY = '<publishable-key>'
flutter run `
  --dart-define="SUPABASE_URL=$env:SUPABASE_URL" `
  --dart-define="SUPABASE_PUBLISHABLE_KEY=$env:SUPABASE_PUBLISHABLE_KEY"
```

**`SUPABASE_URL` must be the base project URL, with no `/rest/v1/` or other API endpoint path.** The SDK constructs its Auth and database endpoints from this base URL. Shell environment variables alone are not Dart defines; the command above forwards them explicitly.

Without the required defines, the app displays the French `Configuration requise` screen. Use only the publishable client key in Flutter; never supply service-role keys, database passwords, or user access tokens.

Hosted-development authentication does not require local Docker. Start an Android target only when needed for an app check. Avoid unnecessary Gradle builds, SDK downloads, and cache cleaning on the development computer.

## Business Time

JMService uses `America/Montreal`, configured centrally in [business_time_config.dart](lib/src/config/business_time_config.dart), with the separate French display label `heure de Montréal`. Attendance timestamps remain authoritative UTC instants; [business_time.dart](lib/src/time/business_time.dart) converts them only for display or calendar interpretation using IANA daylight-saving rules. For example: `15/10/2026 à 23:45 (heure de Montréal, UTC−04:00)`.

The installed `timezone` package's `latest_all.dart` database resolves the Montréal backward-compatible alias; the default database omits it. Conversion and formatting accept an explicit IANA identifier for future regions. This is application configuration for one company; database-configurable company timezones and a settings UI are not implemented.

Future monthly attendance reports must derive calendar-month boundaries in the configured business timezone, including DST, then convert those boundaries to UTC for filtering. Calculate elapsed durations from UTC instants, never by subtracting naive local clock times. Reporting is still planned.

## Validation

With dependencies already resolved:

```powershell
flutter analyze --no-pub
flutter test --no-pub --concurrency=1
git diff --check
```

The single test worker limits memory use. Local database tests require a separate database-only Supabase stack; see [Backend Setup](docs/backend-setup.md). Keep Docker and the emulator stopped when they are not needed, and stop expensive operations if C: free space falls below 5 GB.

## Engineering Documentation

- [Development Status](docs/development-status.md)
- [Backend Setup](docs/backend-setup.md)
- [Requirements](docs/requirements.md)
- [Architecture](docs/architecture.md)
- [Logical Data Model](docs/data-model.md)
- [Backlog](docs/backlog.md)
- [Location Feasibility Study](docs/location-feasibility.md)
- [Security and Privacy](docs/security-privacy.md)
- [Client Questions in French](docs/client-questions-fr.md)
- [ADR 0001: Technology Stack](docs/decisions/0001-technology-stack.md)
- [ADR 0002: Location Monitoring](docs/decisions/0002-location-monitoring.md)
