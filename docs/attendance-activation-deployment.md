# Gate-1 activation-contract deployment preparation

Assessed on `feature/attendance-live-integration`, baseline `a679e02`.
**Prepared and locally validated only: no hosted migration, gate change,
attendance/note RPC, account creation or record mutation was performed.**

The linked remote reference was matched against the live project list entry
named `chantipoint-dev` before read-only queries. It has exactly these five
versions: `20261013000100`, `20261016000100`, `20261017000100`, `20261017000200`,
`20261021000100`. The constant legacy gate is 1 and the deployment table is absent.
The five-migration preflight passed **19/19**. The dry run lists **only**
`20261025000100_attendance_activation_contract.sql`. Nothing was pushed.

## Separate inspection contracts

- `legacy_schema_deployment_check.sql`: **19 checks for the five-migration
  state only**. Useful before this deployment; not a six-migration postcheck.
- `attendance_activation_deployment_check.sql`: **52 checks for exactly six
  migrations at gate 1**. All 52 named rows must exist and `passed=true`.
  SQL errors, missing/extra results, nulls or false values are a stop condition.
  Do not treat a successful CLI exit alone as a successful inspection.

The new script uses `BEGIN READ ONLY`, bounded statement/lock timeouts, catalog
reads and aggregate compatibility booleans. It invokes no capability, gate,
attendance, note or authorization helper function. It emits no epoch value,
identity, note text, coordinates, key or session contents. It pins bodies and
metadata for **37 functions** to the six ordered migration sources: argument
names/types/defaults, return type, language, volatility, security-definer owner,
search path/timezone settings, API/PUBLIC execution and grant options. This also
covers relocated legacy/note implementations, hashes, receipts and RLS helpers.

Remaining checks cover exact migration history; one canonical server epoch and
gate 1; no contract overloads; private-table RLS/no policies/no API table or column
grants; private schema permissions; state columns/defaults/constraints; the enabled
statement fence trigger; application RLS/read-only grants; nonprivileged API roles;
exact owner-scoped SELECT policies; validated composite History FK columns and
targets; baseline/enriched column types/nullability; existing session shapes.
Policy deparsing is pinned to the reviewed PostgreSQL 17 form. Unexpected platform
metadata is a reviewable failure, not permission to relax checks automatically.
These checks do not certify device provenance, inspect journals, prove restore
identity freshness or replace actual API/schema-cache verification.

## Ordered operator procedure — future approval required

1. Review this package and obtain separate approval for the **single gate-1
   schema deployment**. Confirm the approved backup/recovery arrangement and a
   quiet interval. DDL and its deployment fence can wait for running transactions;
   compatibility is not a guarantee of zero latency. Do not revoke a working
   legacy path, change API settings, enable v2 or touch device journals.

2. Recheck the link against the live project name and exact five-version state:

   ```powershell
   Set-Location C:\Projects\chantipoint
   supabase projects list --output json --log-level error
   supabase db query --linked --file supabase/inspection/legacy_schema_deployment_check.sql --output json --log-level error
   supabase db push --linked --skip-vault --dry-run --log-level error
   ```

   Privately match `supabase/.temp/project-ref` to **chantipoint-dev**; keep
   references/credentials out of review output. Require all **19 five-state
   preflight** checks true and only the activation migration pending. Unknown
   link, extra/missing migration, drift, query error or failed check means stop.
   Do not repair migration history or re-link to force a match.

3. Only after explicit deployment approval, apply that one pending migration:

   ```powershell
   supabase db push --linked --skip-vault --log-level error
   ```

   **This command was not executed in this assessment.** Keep `--skip-vault` to
   avoid the installed CLI's default secret synchronization. Do not add
   seed/role/include-all flags or reset/repair commands. The migration requires
   gate 1, creates one server-generated deployment epoch, and leaves gate 1.
   It uses the transaction deployment fence before changing function definitions;
   use normal transactional migration application, not piecemeal SQL.

4. Immediately run the **new six-state** inspection and confirm nothing pending:

   ```powershell
   supabase db query --linked --file supabase/inspection/attendance_activation_deployment_check.sql --output json --log-level error
   supabase db push --linked --skip-vault --dry-run --log-level error
   ```

   Require **52/52 true**, six recorded versions, gate 1 and no pending migration.
   The epoch must be non-null/canonical, but its observation does not enroll a
   client or authorize adopting it as a pending command's identity. Independent
   provisioning remains a later reviewed operation.

5. Check actual API readiness with an **existing authorized development session**:
   authenticated read-only `GET /rest/v1/rpc/attendance_capability` must return
   exactly version 1, the operator-verified server epoch, gate 1 and
   `v2_available=false`. Verify the normal app's auth/session restoration,
   employee authorization, owner-scoped History, navigation and disabled attendance
   state. Preserve explicit API errors; never convert them to empty History.
   Use existing records only; an empty result does not exercise an active/closed
   session read. Do not create an account or invoke hosted attendance/note RPCs
   for this stage. Record any unexercised path. The migration requests a schema
   reload, but its notification alone is not proof of HTTP readiness.

Stop on any migration/lock failure or sustained wait, failed/unknown inspection,
unexpected gate/epoch state, changed legacy contract or degraded auth/History/API.
Do not enable writes, clear journals, reset data or reopen old writers by changing
the gate as an improvised rollback. Inspect committed state and prepare a reviewed
forward correction. Hosted replay-only HTTP/header tests, if later required,
need separate approval; the results below are **local**, not hosted evidence.

## Existing-data and gate-1 effects

The only new stored application-control data is the private singleton deployment
row. Existing sessions, UTC instants, classifications, notes, request hashes,
idempotency keys and terminal evidence are not rewritten, closed, deleted or
backfilled. History columns, read policies and composite relationships are
retained. No retention or factory configuration changes occur.

At gate 1, legacy check-in **and checkout** still delegate to the original
implementations, with the existing signatures, grants and receipt semantics.
Both standalone note RPCs remain available under their original authorization and
session rules; the normal app's Save stays disabled. V2 new submissions remain
disabled. Every v2 call, including replay, now requires the expected-epoch header;
matching-epoch replay misses retain their exact, non-mutating, **inconclusive**
response. This schema deployment does not approve usable employee attendance in
the guarded normal app.

## Actual local validation

Only the retained PostgreSQL container/volume was started, at its unchanged
**768 MiB** cap. It already had all six migrations: none was applied/reapplied.
No reset, volume replacement, image pull, emulator or full Supabase stack ran.

```powershell
docker start supabase_db_chantipoint
python -B supabase/tests/integration/attendance_activation_inspection_test.py
supabase test db --local supabase/tests/database/attendance_activation_contract_test.sql supabase/tests/database/legacy_schema_compatibility_test.sql --log-level error
python -B supabase/tests/integration/attendance_activation_http_test.py
docker stop --time 20 supabase_db_chantipoint
git diff --check
```

- **52 strict postchecks passed locally**, in an actual read-only transaction;
  source-derived expectations matched all 37 functions. **13 rollback-only drift
  probes** rejected gate/missing state, extra migration, changed body, anonymous or
  grant-option execution, overload, private-table exposure, disabled/widened/renamed
  RLS policy, missing History FK and missing deployment fence. Final baseline
  inspection matched the original. An initial test expectation incorrectly used
  numeric for the radius; it was corrected to the migration's existing integer.
- **2 pgTAP suites / 98 assertions passed**: activation **69**, legacy compatibility
  **29**. Their original-RPC compatibility fixtures and simulated gate changes run
  inside rollback-only fictional test transactions. These are separate from the
  HTTP smoke, which sends **no original attendance or note request**.
- **Actual cached PostgREST 16.4 HTTP/JWT: 13 assertions passed.** Authenticated
  capability GET returned the exact gate-1 contract; anonymous GET returned HTTP
  **401 / 42501**. For **both** check-in and checkout, fresh-key replay-only
  requests returned HTTP **200** with exactly the two-field `not_found` object
  for the matching epoch; wrong/missing headers returned HTTP **400 / P0001**
  with `attendance_epoch_mismatch` / `attendance_epoch_required`. An actual
  owner-scoped empty History relationship embedding also passed. No active or
  closed session existed; neither populated read nor a complete six-month app
  walkthrough was exercised.
- HTTP requests used the image's existing curl over real loopback HTTP into a
  disposable **96 MiB / 0.5 CPU / one DB connection** PostgREST service. No HTTP
  port was exposed on Windows. The retained DB's bridge authentication requires
  an unavailable password; the initial bridge attempt failed with **PGRST000**.
  Sharing only its network namespace used the existing loopback authenticator
  policy without changing roles, passwords or HBA. JWT signing material existed
  only in memory/disposable container configuration; Docker logging was disabled.
  Windows text-mode CRLF initially broke curl's config pipe (exit 2); sending
  explicit UTF-8 bytes fixed the test harness. Final HTTP runs passed twice.
- One uniquely owned fictional local employee/company/role fixture was committed
  solely for cross-connection visibility and removed by checked cleanup. Counts
  and in-database evidence digests proved no attendance/note/evidence change;
  the original gate/epoch and data counts were restored exactly. No output or
  archive contains tokens, connection credentials or row contents.

Final local state: six migrations, gate **1**, one deployment row, original epoch;
all nine checked Auth/application/evidence tables empty, pgTAP absent. The
disposable services/fixtures are removed. PostgreSQL stopped cleanly (exit 0),
with its existing container/volume retained; Docker's already-running engine was
left running and unrelated containers were untouched. C: **15.05 GiB initially /
14.91 GiB after shutdown**; E: **17.22 GiB**. RAM recovered from 0.48 to 1.08 GiB
before database startup; no 3 GiB disk guard was reached. No Flutter/native test
was rerun because no app/native source changed. The full 859-assertion DB suite
and concurrency/upgrade rehearsals are earlier evidence, not new runs here.

## Gate 2 and usable attendance remain separate

Still required: approved hosted deployment and six-state/API postchecks;
independent trusted epoch provisioning; durable device enrollment/ownership;
inventory and reconciliation/quarantine of pending legacy, note and v2 commands
across namespaces; trusted migration provenance and durable old-writer fencing;
reviewed cutover/withdrawal authority and supervised device/recovery validation.
A missing file, no active server session, capability availability or supplied
UUID proves none of these. Keep `UnapprovedAttendanceCutover` as the normal default.

Gate 2 retires **all** calls to the legacy attendance and both standalone note
endpoints, including legacy checkout and accepted-key replays. Do not strand their
retained work. Returning to gate 1 reopens them and is not an emergency stop.
Standalone Save and administrator workflows remain outside this deployment slice.
