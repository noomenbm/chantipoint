# Development attendance cutover assessment

**Scope clarification after review:** this document proposes the later **v2
activation/legacy-writer retirement**, not the intervening schema-only deployment.
The [legacy-mode schema checklist](development-schema-deployment.md) prepares the
four existing pending migrations with gate 1 and legacy RPC grants retained. Its
deployment does not require this document's proposed control migration, API
maintenance fence or device enrollment, and does not approve activation. Keep
the original cutover findings/sequence below for that later review.

Assessed 2026-10-24 on clean `feature/attendance-live-integration` at
`86aeb7199e5af8f5baf5bea09c17de134f772de7`. This document proposes later work;
**no deployment, activation, attendance write, migration execution, device journal
inspection/cleanup, account creation or hosted configuration change was performed.**

The shortest safe path is an attendance-only, supervised development cutover:
deploy the reviewed foundations/contracts, retire old server writers, establish
trusted deployment/device ownership, and compose a real approval authority.
Keep standalone Save disabled. Existing components already cover foreground GPS,
description, atomic final-note checkout, complete receipts and supported recovery.
A boolean flag, an empty directory or changing the default projection is not a
substitute for those prerequisites.

## Verified hosted evidence

The authenticated `supabase projects list --output json` result matched the
linked reference and name **chantipoint-dev**, before querying. The linked
`.temp/project-ref` also matched cached project metadata. References, keys and
personal values are omitted here.

`supabase db query --linked` uses the Management API; no database password or
Docker was needed. The reusable
[inspection SQL](../supabase/inspection/development_attendance_cutover.sql) runs
inside `BEGIN READ ONLY` / `ROLLBACK`, with a 10-second statement timeout. It
returns catalog metadata and aggregate booleans, not rows, identifiers, note text
or coordinates. It does not invoke even the private gate: a recognized constant
SQL body is classified through catalogs. Its results are evidence, never an
activation authorization.

Verified results:

- Migration history contains **only `20261013000100`**.
- Authenticated callers can execute legacy `check_in` / `check_out`; anonymous
  callers cannot. V2 attendance RPCs, the private gate, both note RPCs and the
  private note-operation table are absent.
- `work_sessions.review_status` exists. `employee_note`, company factory
  configuration columns and `session_events.metadata` are absent.
- Relevant application tables have RLS enabled, authenticated SELECT and no
  authenticated table-wide INSERT/UPDATE/DELETE grants. The two composite foreign
  keys used by the scoped reader are present.
- Existing sessions are present; no active sessions were present **at the
  inspection instant**. No incompatible baseline shapes were found by the
  inspection's bounded-type/time/lifecycle checks. These facts establish neither
  device intent absence nor future quiescence.

The exact enriched SELECT currently fails schema compatibility because
`employee_note` is missing. It must not be enabled or interpreted as empty history.
After the nullable column migration, old sessions should parse without rewriting
their classification/timestamps: their new note is NULL and existing review state
is retained. This is supported by the schema/aggregate checks, not an authenticated
PostgREST v2 integration test. Verify actual owner-scoped active AND closed reads,
RLS/grants, strict JSON shapes and notes after deployment; do not invent notes or
claim old rows have v2 GPS evidence.

## Blockers, required change and verification

| Blocker and concrete evidence | Required work | Verification |
| --- | --- | --- |
| Hosted baseline lacks four migrations and all v2 endpoints; the gate is **absent**, not observed as mode 1. | Deploy the four pending committed migrations in order during approved maintenance, plus a new reviewed cutover-control migration. Keep v2 disabled until all other checks pass. | Repeat the inspection; compare exact function signatures/bodies, grants, schema and migration history. Run pgTAP/concurrency checks on a suitable local development database before deployment. |
| Gate 2 deliberately leaves legacy checkout writable. `20261017000100...` public `check_out` calls `submit_attendance(1,...,false)`; note migration retains that wrapper. `20261017000200...` grants unkeyed `update_employee_note`; `20261021000100...` deliberately retains it and grants keyed Save independently of the gate. | New reviewed control migration must deny all old/new standalone note mutations for this attendance-only stage and retire legacy new checkout too. Either revoke legacy EXECUTE or provide a strictly read-only original-key/hash replay adapter for approved reconciliation. Never turn a legacy command into v2. | Test old check-in AND checkout and both note endpoints under gate 1/maintenance/2, including already-submitted requests. Prove no new event/session/note mutation via retired endpoints. Match complete replay payload/hash, not keys alone. |
| Initial hosted v1 function bodies predate the deployment shared advisory lock. Removing the writer from main or taking `(174811,2)` alone cannot drain those already-running bodies. | Approved maintenance must block new API entry and **drain pre-fence transactions** before activation. Then use the exclusive deployment advisory lock for the new wrappers/gate and preserve that fence through settlement. | Maintenance rehearsal with paused pre-upgrade v1 request, queued request, gate switch and stale APK. No old mutation may commit after the certified boundary. No caller timeout is cancellation. |
| `ATTENDANCE_ENVIRONMENT_ID` is an optional build define; no server deployment-instance record, capability RPC or real `AttendanceCutoverAuthority` exists. Normal uses `UnapprovedAttendanceCutover`. | Add a trusted deployment instance/restore epoch and a narrow authenticated, read-only capability contract, plus an authority checking that exact ID, trusted URL/key, auth generation, compatible contracts/gate and local ownership/checkpoint. Rotation blocks old bindings, never rebinds commands. | Wrong project/epoch/owner/generation, unavailable or malformed capability, gate rollback and stale capability must deny before GPS/POST. Recheck after credential acquisition. No arbitrary client claim grants approval. |
| Legacy files encode company/profile only, lack backend provenance and transmission phase, and may have `.tmp`/other artifacts. Inspection is per binding; absence and server-empty/not_found are not proof. | Inventory every enrolled device/owner's relevant legacy, encrypted attendance/note and restored/orphaned artifacts without logging contents. Establish externally trusted historical provenance and durable one-source/one-destination assignment; hold an exclusive writer/source lease. Positively certify a clean cutover checkpoint or keep that device/owner blocked. | Source-change, conflicting binding/target, restore, alternate environment, wrong owner, missing key and interrupted assignment tests. Include missing-file and unknown-artifact cases. Never enroll a fresh namespace to hide old pending work. |
| C2c migration is isolated: coordinator requires `requireIsolatedExecution`; native cleanup accepts only `.journalvalidation`. It imports but does not settle attendance; C3 gates legacy protocol and transport refuses it. | Either enroll only positively certified clean device/owner pairs and quarantine all unresolved pairs, or implement a separate reviewed normal-namespace migration AND legacy-resolution slice. Reuse exact bytes/key, digest, CAS, verified durable encrypted readback, checked cleanup and directory barriers. Do not simply remove the package restriction. | Restart/fault tests at every native boundary; original request/receipt retained through lost replies, cleanup failure and already-deleted boundary. Provenance approval precedes any import or cleanup. |
| No production durable retirement/source registry or backup/restore enrollment policy exists. Native per-file CAS and isolate queues do not fence older APKs, other processes or backups. Manifest has no explicit backup/transfer rules for root legacy files; secure stores use no-backup storage. | Add durable enrollment/retirement metadata outside ordinary restored plaintext, checked on resume/restart before reads/actions. Establish backup/restore handling and server endpoint retirement; constrain the development test population explicitly. | Downgrade/old APK, process/engine contention, restore, new key/device, lost marker and unknown files fail closed. A missing known file/key must not look like first install. No wipe/reinstall-as-reset procedure. |
| V2 replay miss is only `{"contract_version":2,"status":"not_found"}`. It does not consume a key or fence a late original; C3 correctly remains unresolved. | Preserve that behavior for the shortest supervised development stage: recovery works for committed receipts and verified confirmed/tombstone records, while misses require retained/manual review. If automatic bounded non-application recovery is required, separately review an attendance terminal-fence ledger contract. | Original-before-replay, replay-before-delayed-original, lost responses before/after commit and exact same-key payload tests. A miss may never release the gate or cause a new-key retry. |

Local source references: [normal composition](../lib/src/attendance/integration/normal_attendance_composition.dart),
[guard](../lib/src/attendance/integration/attendance_integration_guard.dart),
[auth owner](../lib/src/attendance/attendance_auth_owner.dart),
[legacy file store](../lib/src/attendance/file_pending_command_store.dart),
[migration coordinator](../lib/src/attendance/journal/legacy_migration_coordinator.dart),
[native migration](../android/app/src/main/kotlin/com/example/chantipoint/journal/LegacyMigration.kt),
[C3 coordinator](../lib/src/attendance/attendance_operation_coordinator.dart),
[transport/projection](../lib/src/attendance/supabase_attendance_operation_transport.dart).

The proposed control boundary must also bind requests to the deployment epoch.
Today's v2 body does not carry it; a capability GET followed by POST has a race
if the server deployment changes. A narrow reviewed solution is an expected-epoch
HTTP header derived from the immutable journal binding, checked against trusted
private server metadata **inside each v2 transaction under the deployment lock**.
Missing/mismatched epochs reject before mutation. This preserves frozen RPC body,
key, hash and acknowledgement shape; it does not turn a client header into gate
authority. The server-controlled gate and owner authorization remain independent.
Review this boundary and its reset/rotation/late-request tests before implementing
the new control migration/transport header. Do not reuse the current public RPCs
as a capability probe or treat an observed mode as a durable operation lease.

GPS acquisition is already one foreground attempt with permission/services/error
evidence, not continuous tracking. Factory configuration is **not required to
record attendance**: missing configuration or unusable evidence results in
`location_unverified` plus review under the existing v2 policy. Genuine factory
classification needs separately approved company coordinates/radius and credible
evidence. Do not insert invented factory coordinates into the existing company.
Final preserve/replace/clear note is already immutable checkout intent; it does
not require enabling standalone Save.

## Exact proposed development sequence (not executed)

1. Review this plan and select the bounded test device/employee population.
   Inventory and quarantine ambiguous pending states first. No wipe, source
   deletion, key rotation or fresh-binding bypass. Choose the trusted provenance
   approver and acceptable evidence; current URL, matching UUIDs, no active session
   or a missing file are insufficient. Do not reopen the old normal UI to drain
   intents automatically. The old repository loses raw acknowledgements, permits
   timeouts while work continues and only reconciles a narrow factory shape.
2. Implement and review the missing control/capability, durable device ownership
   and authority code above. Resolve or quarantine legacy intents using original
   protocol and full request evidence. Unknown/missing results remain uncertain.
   Retain native normal-package cleanup restriction until its own approved slice.
3. Rehearse the full staged upgrade on a retained local database using fictional
   fixtures, without reset. Run all five pgTAP suites and three concurrency
   harnesses plus new cutover/old-writer/ownership tests. Verify existing rows,
   hashes, timestamps and nullable-note compatibility before/after. The new control
   migration must be forward-only; do not edit committed migrations.
4. Obtain separate approval for a short **chantipoint-dev maintenance window**,
   the reviewed migrations/control SQL and later fictional attendance tests. Verify
   remote name/reference again and save the existing relevant ACL/gate/schema
   definitions through the approved backup process, without exporting employee
   data into the repository. Stop all enrolled clients.
5. Establish a reviewed maintenance fence that pending migration grants cannot
   reopen. One concrete option is temporarily withholding public-schema USAGE
   from API roles, including inherited PUBLIC access, with exact original ACLs
   preserved. This temporarily blocks app authorization/history as well. Drain
   **all pre-fence API transactions**, including old v1 bodies, and check for
   prepared transactions. Do not infer drain from stopped screens or idle clients.
   This needs an operator-reviewed script; this assessment supplies no modifying SQL.
6. Review `supabase db push --linked --dry-run`, then, only with the above approval
   and fence, use `supabase db push --linked` to apply, in order:
   `20261016000100`, `20261017000100`, `20261017000200`, `20261021000100`, followed
   by the **new reviewed control migration** (not implemented in this assessment).
   That control must retain gate 1 initially, provision the independent deployment
   epoch/capability and transactional epoch check, and revoke authenticated legacy
   `check_in`/`check_out` and both standalone note RPCs (including inherited grants).
   For this first stage prefer complete legacy RPC retirement; a later read-only
   legacy-resolution adapter is a separate reviewed slice, not implicit permission
   to dispatch imported legacy commands through C3.
   Do not run today's push before that new migration and maintenance script exist.
7. Repeat read-only metadata inspection and verify exact checkout signature with
   `p_note_action` / `p_employee_note`, grants/RLS/relationships, no accidental old
   overloads, and unchanged baseline data. The added note column is NULL on old
   rows; do not relabel old sessions as GPS-verified or rewrite idempotency hashes.
   Once old/note writers are certified retired and v2 remains disabled at gate 1,
   restore the exact approved schema USAGE/read access so app authorization and
   read-only compatibility/enrollment checks can run before activation.
8. Provision the matching trusted identity outside Git and install the reviewed
   guarded build as an update on certified devices. It must use the enriched
   projection **only after capability verification**. Verify local durable
   enrollment/retirement checkpoints and retained queues; client activation remains
   denied on unknown proof. Stage incapable/ambiguous clients separately.
9. In one reviewed transaction, take exclusive advisory lock `(174811,2)`, confirm
   retired endpoints and legacy drain proof, and set the private attendance contract
   to 2 while publishing the matching capability/fence epoch. Grant only the
   approved v2 execution permissions; preserve the restored least-privilege reads.
   No authenticated standalone note Save or legacy mutation permission is restored.
   Reload PostgREST's schema cache and confirm capability/grants using read-only
   checks. Lost acknowledgement of this operation requires inspection, not redoing
   a guessed gate transition.
10. With the existing fictional development employee, test authenticated active and
    closed canonical reads first, then an explicitly approved check-in with optional
    description and real/simulated foreground evidence, durable confirmation,
    explicit consumption, checkout with each final-note choice, and canonical
    closed state. Check permission denied/services off/timeout/approximate fixes,
    honest review/classification, Montréal display and unchanged UTC storage. These
    later tests intentionally create fictional attendance/events/evidence and may
    store coordinates; approve their test location/data beforehand. No seed or
    account creation is required unless the selected test population needs one.
11. Exercise lost replies, process restart in every journal phase, committed replay,
    confirmed recovery/consumption, session expiration, logout/relogin, account
    switching, revoked roles, concurrent actions, old APK calls and restored files.
    Unknown/miss states stay blocked. Verify native files remain encrypted and
    final note/request bytes/keys/receipts unchanged. Re-run History/sign-out and
    verify standalone Save is still disabled and both note RPCs reject API writes.
12. If any check fails, withdraw v2 approval and stop new writes while retaining
    all queued work and allowing receipt-only finalization of submitted work.
    **Do not reset the database, delete journals, replace keys, blindly switch
    back to legacy gate 1 or install an old writer.** Investigate and forward-fix;
    v2 rows/receipts must remain readable and recoverable under their original
    contracts/bindings. Re-enabling writes needs renewed verified approval.

Existing data is retained throughout. The committed schema changes are additive
or replace constraints/functions; they do not close active sessions, erase history
or seed factory configuration. The note-operation table begins empty. Gate/ACL
changes alter which clients may write, not past attendance. Migration deployment
can still block on locks or incompatible data; preflight and maintenance drain
are required. Existing no-active-session observation is only a point-in-time fact.

## Decisions that actually need review

- Approve the proposed development-only maintenance population/window and choose
  the trusted provenance/enrollment approver. Supply evidence for any ambiguous
  old device command; there is no technical way to infer historical origin from
  today's configuration. Clean certified pairs may proceed while unresolved pairs
  remain blocked, if that supervised scope is accepted.
- Accept retained/manual review on attendance replay misses for the first stage,
  or require a new terminal-fence attendance contract before enabling any writes.
  Existing code already settles that a miss cannot be treated as failure.
- Decide whether the first development test deliberately accepts unverified
  location/review, or needs genuine factory classification with explicitly approved
  configuration. Foreground permission failure alone must not close a session.

No new decision is needed to keep Save disabled, preserve original keys/payloads,
use Montréal/UTC correctly, reject unknown capability, or keep production cleanup
disabled: those are already settled boundaries. Deployment and attendance testing
remain subject to separate explicit approval; this assessment is not that approval.

## Safe local changes and validation

Mixed legacy/v2 home factories now fail before either is called in **all build
modes**. Previously the mutual-exclusion check was only a debug assertion. A new
widget regression proves no writer acquires ownership. A second regression uses
the real constructor default and proves trusted identity, enriched projection and
absent files still cannot authorize GPS, journal preparation or POST.

The reusable read-only inspection SQL was successfully executed against the
verified linked project, including a final repeat after tightening gate metadata
classification. No attendance/note RPC was called. Flutter validation results are
recorded in [Development status](development-status.md). No Android/native source
changed; no Android build, emulator or Docker was started for this assessment.
