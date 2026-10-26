# Normal-app attendance integration

## Signed development authority follow-up

The application-lifetime normal composition now supports a debug-only signed
development enrollment verifier. Default/release denial remains; independently
trusted epoch/public-key configuration cannot authorize attendance alone. Native
approval, original full binding/current auth generation and a fresh matching
gate-2 capability must pass before enriched reads/actions. Refresh bootstraps
verification; capture and pre-POST repeat it. Active-session Save now uses the
shared note/checkout coordinator described [here](active-session-note-save.md).
Old adapters check durable local retirement without deleting retained work.
See [development device authority](development-device-authority.md) for exact
configuration, operator approval, native recovery, admission/drain limits and
remaining separately authorized steps. Historical integration evidence below
predates these hooks. No real device was enrolled or hosted write/gate performed.

The subsequent [development cutover assessment](development-attendance-cutover.md)
verified the hosted baseline and records the remaining code/database work and
proposed staged sequence. This integration's default-deny boundary is unchanged;
mixed legacy/v2 factories are now rejected in release builds too.

Baseline: `90432ec`, branch `feature/attendance-live-integration`. This is a
guarded composition for review, **not hosted v2 activation**. The developer
explicitly approved replacing the legacy attendance panel while all attendance
writes remain unavailable pending safe cutover. History, authentication, role
restrictions and sign-out remain available. The legacy implementation is retained
in source for existing tests; normal `main.dart` does not construct its writer.
An error never selects that writer as a fallback.

## Composition and lifetime

`NormalAttendanceComposition` owns one `AttendanceAuthOwner`, pinned HTTP client,
scoped active-session reader, C3 operation coordinator and note coordinator for the application
lifetime. Each employee home owns a C5 workflow/screen, C4 foreground capture
and drafts. History is a sibling in the authenticated subtree and does not
dispose attendance during navigation. Non-employee roles receive no workflow.
Auth revalidation recreates the route; logout initiation, authorization loss,
account changes and same-user relogin invalidate old contexts. Same-login token
refresh preserves the generation under the existing owner rules.

Screen disposal abandons only unsubmitted capture. Submitted work retains its
context, pinned transport and original journal until settlement. Application
shutdown invalidates authority immediately, then drains workflows/contexts before
closing the HTTP client and disposing auth. A late valid receipt may be persisted
for its original command, without publishing stale session data.

The existing sequencing is retained: validate frozen text, acquire one foreground
fix (or technical unavailable evidence), securely prepare the immutable command,
mark possible submission, make one HTTP attempt, retain the complete raw receipt,
and read canonical session state. Confirmation does not itself release the gate;
explicit reviewed consumption/recovery uses the existing C3 verifier. Check-in
description and preserve/replace/clear final checkout-note intent stay immutable.
There is no polling, automatic retry, continuous GPS or background tracking.

## Fail-closed deployment boundary

`ATTENDANCE_ENVIRONMENT_ID` is optional trusted build configuration for an
independently provisioned deployment-instance/restore epoch. Capability/v2 HTTP
now requires its canonical UUID spelling; historical journal bindings remain
unchanged and readable. It is not derived
from the URL, user IDs, a journal or the current account. Its absence leaves login
and History functional but blocks pointage **before local slot access, GPS or
attendance HTTP**. No value is supplied in source. Supplying this identifier does
not enable writes or certify server capability.

Normal composition defaults to `UnapprovedAttendanceCutover`; there is no production
approval issuer and no activation build flag. Every new submit, replay and receipt
consumption is disabled by default. A future issuer must establish compatible
server migrations/contracts and gate, trusted environment, approved migration
provenance where required, durable source assignment and retirement/fencing of
all old writers across restart/processes, held through settlement. A failed or
absent check is denial, never permission. The transport rechecks approval after
async credential acquisition, immediately before POST. Submitted responses are
still allowed to settle after invalidation/approval withdrawal.

The [activation-contract client boundary](attendance-activation-contract.md#client-capability-and-epoch-boundary)
adds a fresh authenticated capability GET before capture and before attendance
POST when an explicit test authority or the signed DEBUG development boundary
approves. Strict parsing, matching
independently trusted epoch and gate-2 availability are additional prerequisites,
never a substitute for that approval. Every v2 initial/replay POST carries the
original binding's epoch in its header, without modifying frozen RPC data.
No production approval, capability cache, automatic epoch adoption or journal
rebinding is provided. The real default stays blocked without these HTTP calls.

Existing backup/device-transfer and client/privacy approval obligations also
remain prerequisites; this composition does not approve or change backup policy.

When a trusted namespace exists, read-only legacy source inspection and separate
encrypted note-slot inspection precede C3 reads. Any source, temporary/unexpected
artifact or unreadable inspection blocks pointage and is preserved. Verified
same-binding v2 note evidence is handled by the composed recovery coordinator;
legacy note evidence still blocks. File absence is not provenance or durable
fencing proof. No migration, source binding, deletion or reset is performed. The source
inspector and native storage retain their existing reviewed recovery policies.
Missing namespace does not guess which binding to inspect.

The unapproved default active/canonical projection omits `employee_note` and
`review_status`; enriched reads require the verified development boundary. Missing
fields appear as unavailable, not invented absence. The scoped reader still
checks profile/employee authorization and full owner binding. Schema, permission,
network and malformed responses remain errors, never an empty active session.
The v2 enriched projection is selected for the signed DEBUG boundary or explicit
fictional test ports; changing the projection alone cannot enable writes.

## Active-session note Save

`Enregistrer la note` and explicit clear use the application-lifetime
`SessionNoteCoordinator`. Pending notes and checkout reservations expose explicit
recovery and disable conflicting actions. Terminal proof must be verified and
canonically refreshed. Normal transport admits only `save_employee_note_v2`,
under the same signed authorization/capability/epoch checks as attendance. The
legacy note RPC is still denied. Local use additionally requires the new
`20261025000200` migration; no hosted deployment is included. Final-note intent
remains in the immutable checkout command. See [contract and limits](active-session-note-save.md).

## Current hosted development behavior

The existing development URL/public key are sufficient for login, authorization,
History and sign-out. They do not establish the new deployment identity or v2
capability. With that existing configuration, employees see a French pointage
configuration notice and disabled attendance actions. No check-in, checkout,
replay, note save or GPS capture is performed. Pending legacy/v2 data remains
untouched. This deliberate temporary loss of legacy attendance actions was
approved for this reviewable integration; do not distribute as an attendance
release before cutover approval.

Validation results are recorded in [Development status](development-status.md).
Host RAM fixtures do not prove Android durability, hosted RLS/contract behavior,
production fencing, backup policy, power-loss safety or deployment readiness.

## Normal-app Android smoke check (2026-10-24)

The existing temporary development configuration contains only public client
configuration and stays outside Git. Actual build/install commands were:

```powershell
$devConfig = Join-Path $env:TEMP 'ChantiPointHistorySmoke/development.json'
flutter build apk --debug --no-pub --target lib/main.dart --target-platform android-x64 --dart-define-from-file="$devConfig"
adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5554 shell am start -W -n com.example.chantipoint/.MainActivity
adb -s emulator-5554 shell am force-stop com.example.chantipoint
adb -s emulator-5554 shell am start -W -n com.example.chantipoint/.MainActivity
```

Package/activity and signature were checked with installed `aapt dump badging`
and `apksigner verify --verbose`. This was a normal **debug validation APK**, not
a release or demo distribution. The existing Pixel_9 emulator was selected; the
physical phone was not used. Install preserved application data and the existing
authorized session restored. History loaded canonical hosted summaries; C5
displayed its deployment notice and a disabled check-in. Return navigation,
restart and sign-out to login succeeded. No permission prompt or attendance
submission was exercised. Session text and credentials are excluded from reports.

One initial Android not-responding dialog cleared after **Wait**. Its root cause
was not established; a subsequent restart showed no dialog. Memory pressure and
slow cold launches limit this smoke check. It does not validate enabled v2 GPS,
RPCs, native receipt/recovery, note saving, fresh login or post-logout relogin.
The emulator and build daemon were stopped, retaining application data and keys.
