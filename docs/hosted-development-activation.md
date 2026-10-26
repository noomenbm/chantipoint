# Hosted development activation and physical phone acceptance

Completed 2026-10-25 on `feature/attendance-live-integration`, HEAD
`7da09e126d61389db873cdc6d91829a31519dcb3`. **The existing hosted development
backend is active at gate 2 and the normal employee app passed acceptance on the
physical ARM32 Redmi A2.** The phone ends signed out, with enrollment and journal
data retained. No production/release deployment or Git mutation occurred.

**Pre-production blocker:** interruption after durable checkout reservation but
before durable C3 attendance-command preparation can leave an orphaned reservation
requiring reviewed recovery/operator intervention. Controlled developer testing
does not resolve this. No generic reset or evidence-deletion path is approved.

## Hosted database

The authenticated CLI project list matched the existing link to exactly
`chantipoint-dev`, status `ACTIVE_HEALTHY`, region `ca-central-1`. Branch, full HEAD,
clean initial working tree and reviewed sources matched. Initial state was six
migrations, gate 1; **52/52 strict checks passed**. Before activation there was one
fictional Auth user/profile/company, one active employee role, two closed legacy
sessions, four events, no locations and no note-operation evidence. Three retained
Auth sessions were observed; their existence was not interpreted as settled work.

The dry run listed exactly `20261025000200_active_session_notes_v2.sql`. Deployment
used the supported CLI with `--linked --skip-vault`, without seeds, role changes,
history repair or modification of any reviewed migration. **57/57 gate-1 postchecks
passed**, with the original server-generated epoch preserved. Actual HTTP verified
the exact gate-1 capability, both already-accepted legacy attendance replays and
v2 note denial before mutation. Auth, employee authorization and owner-scoped
History returned the two original closed rows.

| Stage | Migration versions | Gate | Epoch |
| --- | --- | --- | --- |
| Before | `20261013000100`, `20261016000100`, `20261017000100`, `20261017000200`, `20261021000100`, `20261025000100` | 1 | Independently captured privately through the database operator connection |
| After | The same six plus `20261025000200` | 2 | Exact original value preserved throughout |

### Private recovery backup

Supabase reported no available backup and PITR disabled. The developer explicitly
authorized a private backup. Existing native PostgreSQL 18.6 tools used the CLI's
private connection recipe to create a custom logical archive of `public`, `private`,
`auth` and `supabase_migrations`, including schema, data, ownership and ACL entries.
Credentials remained in private process/file state, never shell output or Git.

Private archive: `E:\ChantiPointReviews\hosted-development-activation-20261025\private\recovery-backup\chantipoint-dev-preactivation.dump`

SHA-256: `a21b8ce45a55a1fc0eb91aed802ee3a5fe3fb9525201ac0d122af9262729de6e`.

It is a scoped preactivation logical recovery archive, not a physical/PITR/full
platform backup. It predates the new phone session and its GPS records. It is
excluded from shared artifacts because it contains Auth and application data.
It does not authorize restoring over the live project or reopening gate 1. A
restored/clone deployment must undergo the reviewed epoch and device-ownership
procedure before API admission; the isolated validation copy had no API admission.
A fresh restore in the retained isolated rehearsal container passed **52/52 strict
checks** and matched the original application counts. The first non-superuser
restore could not restore managed ownership; its partial database was retained.
A second fresh database restored successfully using the existing isolated restore
administrator. No existing database was reset, dropped or replaced. Only creation
of the already-present template0 public schema was omitted from the restore list;
its actual ownership/grants and every table/function/data entry were retained.
The restored copy also rehearsed migration 7 and the maintenance sequence. No API
service was admitted against this validation copy. Both validation databases remain
retained; the rehearsal PostgreSQL container was stopped after verification.

### Client inventory and maintenance

The existing normal phone package's readable support/no-backup inventory had no
attendance or note journal files. This absence was not accepted as clean provenance.
The developer then **explicitly authorized uninstalling only that normal package**.
Its verified fresh installation supplied independent provenance for enrollment.
The separate `com.example.chantipoint.jamaldemo` package was not debuggable; its
private work remains unknown and preserved. It was stopped and disabled for this
cutover. Existing Pixel_9 and rehearsal AVDs stayed offline, unlaunched and
unenrolled; their retained journals were not declared empty or settled. The
controlled development scope admits only the selected fresh fictional installation.
The retired endpoints now fence future old-client submissions and replays; no
unknown client evidence was adopted, cleared or rebound.

Three reviewable development operator SQL files implement the boundary:

- `development_attendance_fence.sql` verifies the expected epoch/gate and exact
  original schema ACL, then commits withdrawal of public-schema USAGE from PUBLIC,
  anon, authenticated and service_role. Effective inherited access must also deny.
- `development_attendance_activate.sql` requires the already-committed fence,
  zero API transactions, zero prepared transactions and the exclusive deployment
  advisory lock. It updates exactly the expected singleton from gate 1 to 2,
  preserving its epoch through the protected deployment-state trigger.
- `development_attendance_restore_acl.sql` restores only original usage grants
  under their original grantors and requires exact original ACL equality before
  commit. The renderer supplies the privately captured epoch/ACL settings and
  original grant statements; these inputs are not committed.

These operations passed locally as the same postgres operator role, including
rejection of unfenced activation. Hosted execution verified committed fence state,
actual HTTP entry denial, a fresh post-fence transaction drain, protected gate
transition and exact restoration of grants **and grantors**. All **57/57 gate-2
checks** passed immediately and again after phone acceptance. No gate-1 rollback
was attempted; returning to gate 1 would reopen old writers. Any future activation
withdrawal must retain original work and use reviewed fencing/forward recovery.

### Hosted API acceptance

- Fresh authenticated capability returned exactly version 1, original epoch,
  `write_contract=2`, `v2_available=true`.
- Seven retirement checks rejected legacy check-in/out with fresh keys and actual
  accepted replay keys, old keyed note submit/replay and unkeyed note update.
  The original note ledger was empty, so no accepted legacy note receipt was
  invented solely to test retirement; its replay-only attempt was rejected.
- All three v2 RPCs rejected missing/wrong epoch headers: **six checks**. Matching
  attendance replay-only misses returned the exact non-mutating `not_found`
  contract for check-in/out; they were not treated as proof of non-application.
- Anonymous capability was denied. All three v2 endpoints rejected an unprovisioned
  fictional Auth subject with exact `employee_role_required / 42501` errors under
  the authenticated role in rollback-only transactions; no account was created.
- Actual employee writes were exercised through the normal phone app, including
  strict receipt parsing and four stored protocol-2 note operations bound to the
  original epoch. No service credentials were embedded in a client.

Final data is **three closed sessions, zero active sessions, six events, two
location observations and four applied v2 note operations**. Hashes of both
original session rows match their predeployment values exactly. Existing
application records were not reset or deleted. Additional Auth session activity
came from the approved login, restore and ordinary local-scope sign-out; the final
retained Auth session count is three. No migration remains pending.

## Physical Android acceptance

ADB verified model `23026RN54G` (Redmi A2), Android 13/API 33,
`armeabi-v7a,armeabi`. The supported fresh normal debug install is
`com.example.chantipoint`, version `1.0.0`/code `1`, min SDK 24, target SDK 36.
The APK signature and ARM32 Flutter engine/native dependencies were verified.
The installed package's SHA-256 matches the stable normal APK below exactly.

The four normal-build defines contain only the verified hosted HTTPS URL,
publishable/anonymous client key, independently provisioned original epoch and
P-256 public trust anchor. The operator private key is external to Git, device
and shared archive. No service-role credential, password or access/refresh token
was supplied to any build. Private request/install tool APKs were not shared.

The approved fresh-install evidence and completed maintenance records underpin the
signed references. Exact original request bytes/full binding were checked and
signed externally; signature verification preceded private transfer. Native
installation persisted approval and the required empty attendance slot. Normal
composition then verified approval and fresh capability; the explicit empty-record
verification enabled real v2 actions. No journal protocol or binding was changed.
Supported ADB grants enabled precise foreground permission. Temporary keep-awake
settings were restored; no lock security or unrelated apps were modified.

| Functional step | Actual result |
| --- | --- |
| Launch and login | Normal hosted APK launched; developer signed in with the approved fictional account; Auth user and active employee role verified. |
| Authorization and History | Two original closed rows loaded in the normal History UI and through owner-scoped HTTP. |
| Native and empty state | Signature/native approval and explicit empty verification passed; existing login was preserved across operator-tool updates. |
| Employee actions | Actual check-in/out and active-note controls became enabled under the verified authority. |
| Foreground location | Check-in and checkout each stored a fused fix. Both were honestly marked `accuracy_insufficient`/review required; factory configuration is also absent. No numeric coordinates or raw metadata were requested for the report. |
| Description and check-in | Exactly one normal-UI check-in preserved the entered fictional worksite description; its receipt was explicitly consumed. |
| Canonical active session | Actual active-session UI and canonical employee-owned server row matched. |
| Note Save/edit/clear | Initial save, edit, clear and final save passed with exact canonical values. Four v2 operations; no additional GPS observation during note work. |
| Checkout/preserve | Explicit preserve retained the final saved note exactly; canonical manual closure, reservation release and receipt consumption passed. |
| Closed History | Three closed rows displayed after checkout. |
| Restart and sign-out | Idle cold restart restored Auth, native authority and closed History; explicit empty verification passed. Normal sign-out returned to login; approval bytes remained unchanged. |

Final phone state is signed out with application/enrollment/journal data retained.
The old demo package remains disabled with its data intact. No deliberate lost-ack,
ambiguous, destructive or reset recovery test ran on the real phone. Those earlier
isolated suites were not repeated or presented as new phone evidence.

Stable normal APK:
`E:\ChantiPointReviews\hosted-development-activation-20261025\deliverables\chantipoint-hosted-dev-arm32-debug.apk`

SHA-256: `c6e9f5e8766a8d364d713500af1096ebf58b83d34432607221c3c2c840ccbf8c`.

## Inspection, validation and review inventory

The new seven-state SQL retains every applicable prior inspection invariant and
pins **38 functions** to all seven reviewed sources. It expects **57 distinct true
rows**, including original epoch preservation, explicit approved gate, exact new
protocol columns/constraint and compatible note evidence. The private caller must
set `chantipoint.inspection.expected_gate` and
`chantipoint.inspection.expected_epoch` immediately after `BEGIN READ ONLY`.
Missing settings error and mismatches fail. Never reuse the six-state inspection
as seven-state acceptance or adopt an epoch from capability/a retained journal.

Offline inspection source audit: **PASS** (all prior applicable checks retained).
Analyzer: **no issues**. Normal ARM32 debug build, both private operator builds,
APK signature/configuration checks and the above database/API/native/UI acceptance
passed. Full Flutter/pgTAP/native regression suites were not rerun: no application,
native or migration source changed in this activation task. Final diff check passes.

Automatic approval review rejected a proposed raw location-metadata save; it was
not executed. The successful safer checks requested only observation type/provider
and coordinate-presence booleans. No raw metadata or coordinate values enter shared
evidence. Raw UI snapshots, account/configuration state, backup and signing material
remain private and are excluded from the review ZIP.

Every changed/new repository file is included:

- `docs/active-session-note-save.md`
- `docs/development-status.md`
- `docs/hosted-development-activation.md`
- `supabase/inspection/active_session_notes_v2_deployment_check.sql`
- `supabase/operations/development_attendance_fence.sql`
- `supabase/operations/development_attendance_activate.sql`
- `supabase/operations/development_attendance_restore_acl.sql`
- `supabase/tests/integration/active_session_notes_inspection_source_test.py`

The completed review ZIP contains these eight files, sanitized evidence, inventory
and SHA-256 manifest, with a separate ZIP hash. The APK is separate with its own
hash. No new Supabase project/migration, production rollout, unrelated refactor,
Git commit/push/branch operation or generic cleanup/rebinding was performed.
