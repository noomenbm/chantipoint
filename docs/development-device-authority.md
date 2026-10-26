# Bounded development installation authority

This implementation starts from clean `15c4ca0613ef13da6fad006302cc6530c939c07c`.
The latest verified hosted baseline supersedes older deployment-preparation text:
six migrations, gate 1, 52 strict postchecks and authenticated capability GET passed.
No hosted checks, changes or attendance requests were performed in this slice.

## Integrated boundary

`DevelopmentAttendanceAuthority` implements `AttendanceCutoverAuthority`. Its
verification combines native enrollment evidence, the exact current C3 auth
generation/full binding, and a separately supplied fresh capability check. It
clears approval during verification, rejects invalidation across every await,
and cannot let an earlier concurrent completion overwrite a newer observation.
It does not issue credentials, derive an epoch or persist auth generations.

`AndroidDevelopmentEnrollment` only verifies. Native methods are registered on
the existing journal channel, without changing journal schemas or transitions.
Merely registering the channel creates no files or keys. Normal `main.dart`
already owns `NormalAttendanceComposition`; that composition now selects the
development verifier only in DEBUG with an independently supplied canonical
epoch and structurally valid public trust anchor. Missing configuration, profile
authorization or native approval denies. Release/default builds still use
`UnapprovedAttendanceCutover`. No real trust anchor/configuration was provisioned.

Refresh bootstraps asynchronous verification before asking synchronous
`isApproved()`, so the approval cache cannot prevent initial verification.
Existing legacy/note inspections run first. Development preflight is **native
evidence → fresh matching gate-2 capability → native evidence again**, with
current binding/generation checks across every await. Only then may enriched
reads or action controls proceed. It repeats before GPS, after capture before
journal handoff, and after credential acquisition immediately before POST/replay.
HTTP still checks the captured scope and approval synchronously before its single
send. No timeout, fallback writer, new JSON field, hash or receipt transformation.

Observed denial before capture produces no GPS, new command or POST. Withdrawal
after an already authorized intent was persisted prevents POST but retains the
original `may_have_sent` record and its uncertainty. Once submitted, late valid
receipts still settle to the original binding without stale publication/refresh.
The enrolled revision-1 empty slot needs the existing explicit empty-record
verification before a fresh action; it is not silently treated as absent storage.

Retained file-store save/clear, legacy/old DTO attendance dispatch, legacy note
update and keyed standalone note submit/replay now invoke native retirement.
Reads remain available, failures retain evidence, unavailable checks fail closed.
Normal composition constructs no legacy writer. The subsequent
[active-session note integration](active-session-note-save.md) composes the
note coordinator and admits only the epoch-bound v2 note endpoint.

Historical approval-review rejections stopped the earlier patches. The operator
subsequently approved these local hooks directly in chat, and integration was
then applied. No actual enrollment or hosted activation approval followed.

## Approval, storage and inventory

Only debuggable normal and explicitly isolated validation packages may use
enrollment. Release builds deny, even with a valid signed fixture. An operator
must independently provision a P-256 public trust anchor and the expected server
epoch. Neither comes from HTTP capability, a journal, URL or account identity.
No real operator key or device approval was provisioned in this implementation.

The native operator request creates a non-exportable Android Keystore P-256
installation key. Its public-key SHA-256 identifies the installation. Preparation
now validates references, epoch and namespace eligibility **before** creating the
retirement directory/key, then repeats eligibility under its lock. Failed
preflight does not newly retire otherwise usable old work. Once deliberate
preparation begins, its marker is retained on later failure. There is no cleanup/
unretire path, and earlier markers are preserved. Every retained old adapter
checks the marker/key; even a dangling marker entry denies. This is admission
checking, not a lock held across HTTP: already admitted work must be drained,
as must requests from old APKs.

An external operator signs the **original request bytes**, SHA256withECDSA,
DER signature. The strict duplicate-free signed object contains exactly:

- `enrollment_version = 1`, `package_id`, `install_id`;
- the original five-field `binding` (epoch, project base URL, auth user, company,
  employee profile);
- `inventory_digest`, `approval_ref`, `maintenance_ref`;
- `policy = certified-clean-development-v1`.

The two references identify actual externally reviewed clean-install provenance
and server-maintenance approval records. Arbitrary references or matching UUIDs
are not evidence; the trusted signer must refuse to attest unknown history. This
limited implementation supports **certified clean installations only**, not
adoption/migration of existing legacy, note or v2 work. The deterministic digest
binds the observed empty namespace and full binding; it is not a history log or
proof that transmission never occurred. The operator's independent evidence is
essential. Do not select a new directory/environment to evade retained work.

Inventory examines all legacy `attendance_*` entries in application support and
all encrypted attendance/note namespace entries, including sidecars/unknown
names/other owners. Preparation/installation still reject all retained note
evidence and keys. Subsequent verification admits only the approved binding's
authenticated supported v2 note slot and its own matching alias; missing files
or keys, legacy commands, unknown entries and sidecars continue to block.
It returns only counts/booleans, never payloads or paths. Missing files are
observations, explicitly reported as insufficient for provenance.

Approval installation requires an exact clean checkpoint and original binding;
it initializes and verifies one format-2 empty attendance slot (revision 1), then
persists signed metadata. This is an explicit future operator mutation, never a
startup action. An interruption after slot creation permits retry using the same
signed request and exact empty slot. Existing commands/other slots are never
overwritten. A lost install response permits exact idempotent retry, not approval
replacement. There is no un-enroll, reset, cleanup or rebind method.

Metadata lives in `noBackupFilesDir/development_attendance/approval.bin`, protected
by an operator signature and installation key proof, not AES encryption. It
contains no token, password, note or GPS. The already encrypted attendance/note
stores retain their own keys/schema/AAD. Metadata writes use AtomicFile, explicit
file sync, parent/directory sync and exact readback, under process/OS locks.
Truncated/modified records, missing keys, replaced identities, unknown files,
`.new`/`.bak`, wrong owner/project/epoch, and a missing required attendance slot
deny and retain evidence. No newest-file/revision selection or normalization.

After enrollment, the one original attendance slot may hold pending, uncertain
or confirmed work. Native verification does not settle it; the full Dart codec
and C3/C5 sequencing must still block new commands or recover the original key,
bytes and receipt as appropriate. No attendance replay miss proves non-application.
Same-binding supported v2 note evidence requires the composed note coordinator's
exact verification/recovery and checkout fencing. Any legacy source, legacy note
command, other binding, ambiguous note artifact or additional attendance slot
continues to block. Signed approval bytes and the original clean checkpoint are
not changed by subsequent note operations.

No backup-policy change is included. The operator staging request/signature in
application support contains identifiers and must stay outside shared archives.
It cannot authorize another installation, and is not a backup recovery strategy.
Power-loss durability, device loss, enterprise tamper resistance and restored
historical provenance are not claimed.

## Operator entry point (not executed on the normal installation)

`tool/development_attendance_enrollment.dart` is a separate explicit debug target,
never imported by main. It has no Supabase initialization, HTTP or GPS. Its
default `inspect` action is read-only and displays only native inventory counts.
`request` and `install` are mutating actions requiring separate operator approval.
Do not run them on the current emulator just to unblock attendance.

Use an external operator define JSON (no secrets in Git), explicit selected
device, the normal package and retained signing identity. Build/install as an
update without clearing app data. For example, after approval:

```powershell
flutter run --debug --no-pub -d <approved-device> -t tool/development_attendance_enrollment.dart --dart-define-from-file=<external-operator-json>
```

The JSON selects `DEVELOPMENT_ENROLLMENT_ACTION` (`inspect`, `request`, `install`).
Request/install additionally need `DEVELOPMENT_ENROLLMENT_BINDING_JSON` (the
complete independently verified binding, serialized JSON string). Request needs
`DEVELOPMENT_ENROLLMENT_APPROVAL_REF` and
`DEVELOPMENT_ENROLLMENT_MAINTENANCE_REF`. Install needs
`DEVELOPMENT_ATTENDANCE_OPERATOR_PUBLIC_KEY` (base64 SPKI DER for P-256).

Request writes `files/development-enrollment-request.json`. Retrieve privately
using authorized debug `run-as`; do not put its contents in reports or shell logs.
The operator reviews its exact bytes against independent device provenance,
owner/environment and maintenance evidence, then signs them externally. Put only
the DER signature at `files/development-enrollment-signature.der` through the
authorized app-private debug transfer. Keep the private signing key outside Git,
the device and review ZIP. Do not regenerate request bytes while signing.
Install verifies everything natively and does not contact the server. Retry an
uncertain install with the same files; never delete artifacts to make it pass.

## Subsequent supervised sequence

1. Review the integrated local changes and validation. Confirm default/debug/
   gate-1 denial and retained-work behavior. No hosted gate/configuration change
   or actual enrollment is part of this local implementation approval.
2. Name the fictional device/employee population, trusted approver/key custody,
   and independent expected epoch. Inventory the **existing** installation and
   its historical/restored queues. Current emulator provenance was not inspected
   or certified here. Unknown/retained work stays blocked, requiring a separately
   reviewed resolution/migration; absence is insufficient. Do not wipe/reinstall.
3. Stop all selected clients and obtain a separately approved server maintenance
   operation: block new old-writer entry, drain already submitted/pre-fence work,
   reconcile/quarantine original legacy and standalone-note uncertainty, and retain
   independent evidence. Local markers cannot certify this server boundary.
4. Only for a positively certified clean installation, explicitly authorize the
   request/sign/install process above. The signer attests real approval records;
   no self-certification from build config or API. Enrollment alone grants no
   normal action at gate 1.
5. Separately review and authorize gate 2. Confirm epoch, strict six-state schema
   compatibility, owner-scoped enriched active/closed reads and retirement of
   both legacy attendance and both standalone note endpoints. Do not simply
   revert to gate 1 as rollback: that reopens the old writers.
6. Install the reviewed normal debug build with independent `ATTENDANCE_ENVIRONMENT_ID`
   and `DEVELOPMENT_ATTENDANCE_OPERATOR_PUBLIC_KEY` (base64 P-256 SPKI DER), through
   supported external define JSON; verify identity and the retained slot. Only
   then authorize supervised fictional GPS check-in, receipt verification,
   consumption, final-note checkout and original-key recovery. This step writes
   fictional attendance/location evidence and needs explicit separate permission.

The shortest next step is review plus a certification/maintenance decision for
the selected fictional installation. Unknown current-emulator provenance remains
blocked. Then separately authorize provisioning/enrollment, gate 2 and supervised
GPS attendance validation. No current hosted employee attendance, hosted GPS test
or production readiness is claimed.

## Validation

Current integration follow-up: **257 focused** and **1,744 full serial Flutter
tests passed**; analyzer and diff checks passed. Mocked normal-composition tests
use the real development authority with explicit fictional enrollment evidence
and HTTP; native signatures/persistence are separate Android runtime evidence.
The normal entry point compiled in isolated debug app/test APKs, offline.
Pixel_9 Android 17/API 37 (16 KiB pages): **21 fresh**, then **4 restart checks
twice**, all passed with keys/data retained between restart phases. The earlier
unexplained restart crash did not recur; no root-cause conclusion follows.
One initial fresh failure was traced to test cleanup skipping a dangling symlink;
only the isolated fixture cleanup changed, then the full native phases passed.
No normal-package install/enrollment, hosted GPS/RPC, release APK, old Android/
OEM, actual fsync/rename fault, concurrent-process or power-loss validation ran.

Validation results and remaining platform limits are recorded in the review
report and current development-status entry. Host mocks are not Android/runtime
or server-maintenance evidence. The isolated Android runner uses a separate
`.enrollmentvalidation` package with fictional identities and test-only keys;
fixture reset is restricted to that package. No normal app data is reset.
