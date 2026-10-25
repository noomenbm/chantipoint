# Development schema deployment with legacy attendance retained

This is the historical **five-migration** stage and its 19-check contract.
For the later sixth migration, use the separate
[activation-contract gate-1 procedure and 52-check inspection](attendance-activation-deployment.md).

Prepared 2026-10-24 on `feature/attendance-live-integration`, HEAD `86aeb71`.
**Review package only: no hosted deployment or attendance/note RPC was run.**
This stage applies the four existing pending migrations with **gate 1** and
authenticated legacy RPC execution retained. No additional control migration is
needed for this stage. No applied migration was edited, and no schema defect
requiring a forward migration was found in this review.

The [cutover assessment](development-attendance-cutover.md) concerns a later
activation stage. Its writer revocations, maintenance fence, deployment identity
and device enrollment must not be applied as part of this schema-only checklist.
The guarded normal app remains unable to write attendance; deploying schema does
not restore its temporarily removed legacy panel or approve v2. Existing clients
using the legacy RPC contract retain that server path.

## Evidence and ordered effects

The remote project name/reference were matched to the existing link before
read-only Management API queries. `chantipoint-dev` still records **only
`20261013000100`**. Both deployed legacy function bodies match the committed
initial migration byte-for-byte after LF normalization (SHA-256), with empty
search paths, security-definer execution, authenticated grants and no anonymous
execution. Existing session shapes pass the aggregate compatibility checks.
No active session was present at inspection; that is not a deployment requirement
or evidence about any device's pending commands.

| Pending migration, in order | Changes and legacy-mode effect |
| --- | --- |
| `20261016000100_attendance_location_foundations.sql` | Adds nullable, all-or-none/range-checked company factory coordinates/radius and nullable, 1,000-character `employee_note`. Extends location context with `location_unverified`; relaxes the observation trigger's external-only restriction while retaining ownership/active-session checks. No RPC body/grant change, no coordinate seeding. Old rows gain NULL fields. |
| `20261017000100_attendance_v2_contract.sql` | Adds nullable bounded object event metadata; moves the exact initial legacy functions into private helpers and denies direct client execution of those helpers. Public wrappers keep the same argument names/types/defaults and six-field acknowledgements, take a shared deployment lock, and delegate to the original bodies at gate 1. Creates the private constant gate as **1**, classification helpers and v2 RPCs. New v2 submissions reject with `attendance_contract_not_enabled` until gate 2; replay-only misses remain non-mutating, inconclusive results. |
| `20261017000200_employee_session_notes.sql` | Replaces the private v2 submit implementation; replaces the 12-argument v2 checkout overload with the 14-argument version including preserve/replace/clear final-note intent. Adds owner-only, active-session `update_employee_note(uuid,text)`. Legacy wrappers/bodies, hashes and signatures stay unchanged; gate stays 1. Experimental pre-note v2 checkout hashes are incompatible, but hosted development has never deployed that intermediate v2 contract. |
| `20261021000100_settled_employee_note_operations.sql` | Adds the private terminal note-operation ledger and keyed `save_employee_note(uuid,text,text,text,boolean)` with atomic receipts/replay fences. Retains unkeyed note RPC, all attendance functions and gate 1. Ledger starts empty; existing attendance rows are not backfilled or edited. |

These migrations do not close sessions, rewrite UTC instants or original request
hashes/keys, relabel old classifications, delete history, change retention, or
alter existing read policies/indexes/composite History relationships. Existing
active legacy sessions can still close; original accepted keys can still replay
with their original payloads. New legacy factory attendance remains GPS-free;
legacy external check-in still requires its original location evidence.

Both standalone note RPCs become **callable by authenticated clients even at
gate 1**, subject to owner/authorization/session checks. They are not globally
disabled by the attendance gate. The normal app's Save button stays disabled;
this checklist does not activate the separate client note foundation. Do not
describe schema deployment as disabling those server note APIs. Retirement of
unkeyed writers/shared client coordination remains later cutover work.

History's current explicit baseline projection omits enriched note/review fields;
the added columns therefore require no query or capability change. Existing
notes are not invented. The normal composition's legacy read projection and
default-deny write authority stay unchanged. A post-deployment owner-scoped
PostgREST/app check is still necessary; SQL joins alone do not test its schema
cache or HTTP relationship embedding.

## Operator checklist (commands prepared, not executed against hosted)

1. Obtain separate approval for this **schema-only chantipoint-dev deployment**
   and choose a quiet interval. Confirm the existing approved backup/recovery
   arrangement without exporting employee data or credentials into this package.
   DDL takes locks: compatibility does not guarantee zero latency. Do not revoke
   legacy EXECUTE/schema USAGE, stop auth/History, switch gate, or touch device
   journals. No new account, session, factory configuration or seed is needed.

2. From this repository, recheck the link and read-only preflight:

   ```powershell
   Set-Location C:\Projects\chantipoint
   supabase projects list --output json
   supabase db query --linked --file supabase/inspection/development_attendance_cutover.sql --output json --log-level error
   supabase db push --linked --skip-vault --dry-run
   ```

   Match the project reference in `supabase/.temp/project-ref` to the remote entry
   named **chantipoint-dev**; cached name alone is insufficient. Require exactly
   the initial remote migration, expected legacy body fingerprints/grants, and
   exactly the four files above in dry-run order. Any drift, extra migration,
   incompatible row shape, unknown link or error is a **stop**, not an invitation
   to repair history or re-link automatically. Keep identifiers/keys out of review
   logs. The dry-run command was **not** exercised in this assessment.

3. Only after that review/approval, apply those pending files:

   ```powershell
   supabase db push --linked --skip-vault
   ```

   `--skip-vault` avoids the installed CLI's default Vault-secret synchronization.
   Do not add seed/role/include-all flags or use reset/repair. Use normal CLI
   transactional migration application, not piecemeal SQL pasting; these files
   have no nontransactional directive or concurrent-index statement. A failure
   can leave earlier migration files committed: inspect actual history before
   deciding how to continue. See the [Supabase migration workflow](https://supabase.com/docs/guides/deployment/database-migrations)
   and [transaction behavior](https://supabase.com/docs/guides/local-development/cli-workflows#cleaning-up-generated-migrations).

4. Immediately run the non-mutating postchecks:

   ```powershell
   supabase db query --linked --file supabase/inspection/legacy_schema_deployment_check.sql --output json --log-level error
   supabase db query --linked --file supabase/inspection/development_attendance_cutover.sql --output json --log-level error
   supabase db push --linked --skip-vault --dry-run
   ```

   Require all **19** postcheck rows `passed=true`, exactly five total migrations,
   recognized constant gate 1, original legacy body fingerprints, expected public
   signatures/grants, no stale v2 checkout overload, RLS/read-only table grants and
   retained History FKs. These queries inspect catalogs; they call no gate,
   attendance or note function. Final dry-run must have nothing pending. The
   migrations request PostgREST schema reload; verify the API rather than assuming
   a notification proves cache readiness.

5. With an existing authorized development login, verify auth, sign-out and
   History/active-and-closed baseline reads through the actual API/app without
   creating/editing records. Errors must stay visible, never become empty History.
   Do not enable enriched capabilities, normal v2 writes, replay dispatch or Save.
   A hosted mutating legacy smoke test would require **separate explicit approval**;
   the local compatibility suite supplies the write regression evidence here.

Stop immediately on migration/lock errors or sustained lock waits, any failed
postcheck, denied/changed legacy RPC contract, or degraded auth/History. Do not
continue to activation, revoke a working legacy path, change gate, wipe journals,
reset/repair migration history or remove data. Have the operator cancel a stalled
deployment transaction if necessary, inspect committed versions and forward-fix
the concrete defect after review. There is no unattended rollback command here.

## Actual validation and limits

Only the existing cached PostgreSQL container was started, with its unchanged
**768 MiB** cap and retained volume; no image pull, reset or full stack startup.
It already recorded all five migrations and gate 1 before this task. Therefore
**no migration was applied/reapplied**, and this is not a fresh populated-baseline
upgrade rehearsal. The approved files were reviewed in order against the actual
hosted initial function bodies and tested at the existing local final schema.

```powershell
supabase test db --local supabase/tests/database --log-level error
supabase test db --local supabase/tests/database/legacy_schema_compatibility_test.sql --log-level error
```

| Local check | Actual result |
| --- | --- |
| M2.1 / location foundations / v2 contract / employee notes / settled notes | 70 / 71 / 427 / 96 / 97 retained assertions; all passed in the full run. |
| New legacy schema compatibility suite | 29 assertions; passed in the full run and in a separate focused run. Original-body seeded active/closed records, exact replay receipts, changed-payload rejection, new legacy factory/external writes, preserved hash/start instant, GPS rules, v2 rejection at gate 1, History SQL joins/projection and cross-owner/company RLS. |
| Full database run | **6 files, 790 assertions, zero failures.** All fixtures and simulated gate changes in retained suites roll back. The new suite never changes the gate. |
| Read-only deployment postcheck | **19/19 passed locally**: 11 function body/security/grant checks and 8 schema checks. Hosted baseline legacy fingerprints also matched independently. |
| Final local state | Same five migration versions, gate 1, same zero counts in nine checked tables including Auth/ledger; pgTAP absent before/after. Database stopped cleanly (exit 0), container/volume retained. Docker engine was already running and was left in its original running state. |

C: free space was **20.54 GiB before local startup / 20.50 GiB after**; E: **17.22
GiB** at both checks. Initial RAM was insufficient, then recovered to **1.25 GiB**
before database-only startup. No emulator, Android build, download or destructive
cleanup ran. Concurrent committed-fixture harnesses, fresh DDL upgrade/lock-wait
rehearsal, hosted post-upgrade API/History and hosted legacy writes were **not run**.
Flutter was not rerun for this SQL/documentation slice; the preserved assessment's
38 focused / 1,600 full Flutter tests and analysis are earlier results.

The prior seven review files are preserved in the source package, including the
mixed-writer guard/tests and the complete later cutover assessment. Device pending
commands remain untouched; a missing file is still no proof of a safe cutover.
