# Employee client beta and remote activation

Baseline: `feature/attendance-live-integration`,
`001eebd677b54316b3339aebe828a77e11a19478`, initially clean. The existing
`chantipoint-dev` seven-migration/gate-2 deployment and original epoch are retained.
No migration deployment, gate change, account creation or hosted attendance write
is part of this work. The dedicated employee account and Samsung enrollment remain
pending; an APK installation or successful login alone cannot authorize attendance.

**Pre-production blocker:** interrupted durable checkout reservation before C3
command preparation can leave an orphan requiring reviewed operator recovery.
Preserve the evidence. No reset, deletion or generic recovery is authorized.

## Distributable artifacts

Artifacts are under
`E:\ChantiPointReviews\client-beta-jamal-20261025\deliverables`:

| File | Purpose |
| --- | --- |
| `ChantiPoint-beta-universal.apk` | Normal `lib/main.dart` employee application. |
| `ChantiPoint-activation-universal.apk` | Separate temporary activation target, used first. |
| `ChantiPoint-guide-beta-fr.pdf` | Standalone two-page French guide; never embedded in either app. |

Final SHA-256 values:

```text
3aa5056421383ab1f56f9ad67fd533ab29a2d8888007de9f57d0dd66b5b6dbd6  ChantiPoint-beta-universal.apk
fa70dad92daf2835a0a887afe7e2e35394104bac2c7f55ff5a5936e3d30d4dcc  ChantiPoint-activation-universal.apk
d2c0ec1d9a53d1767c186e338be5b75afbbdf729a35089227ce833062d8c7abc  ChantiPoint-guide-beta-fr.pdf
```

The adjacent `DELIVERY-SHA256SUMS.txt` repeats these hashes. The source review is
`E:\ChantiPointReviews\client-beta-jamal-20261025\chantipoint-client-beta-review-20261025.zip`,
with its own adjacent `.zip.sha256`, complete 18-file `SOURCE-INVENTORY.txt` and
relative-path `REVIEW-SHA256SUMS.txt` manifest. APKs remain separate from the ZIP;
the PDF is included. The archive excludes all private task material.

Both APKs intentionally use `com.example.chantipoint`, version 1 / 1.0.0 and the
same Android debug signing certificate. They are successive installations of the
same application, rather than two side-by-side packages: install the utility on
the certified fresh device, then **update it with the normal APK without
uninstalling or clearing data**. This retains Supabase login, installation key,
original request and native approval. The utility UI disappears after the update.
Do not install either APK over the working developer phone for this review.

Both include `armeabi-v7a`, `arm64-v8a` and `x86_64` Flutter engines, minSdk 24
(Android 7.0), targetSdk 36. ARM64 packaging is verified; Jamal's exact Samsung
model, OS, installation policy and actual runtime remain to be checked. Android 6
and earlier and unsupported ABIs are incompatible. Samsung Auto Blocker or an
organization's policy can prevent sideloading; contact the developer if blocked.

Certificate SHA-256:
`ce2feaac8182380c4cd09577f868132a09cbace8548bbb422d2c7f54be405008`.
APK Signature Scheme v2 verification passes. This widely scoped debug identity is
appropriate only to this bounded development beta, not production distribution.
The existing native development authority continues to deny release builds.

Private reviewed build JSON files contain only the hosted HTTPS URL, public
publishable key, independently provisioned original epoch and existing operator
public SPKI, plus the two explicit History booleans. The utility additionally
contains the actual maintenance reference. They contain no employee credentials,
service-role/secret key or operator private key. Real private key/session bytes
were checked absent from the deliverable Dart kernels. The employee kernel does
not contain `DevelopmentActivationController`; neither employee UI nor its normal
entry point imports the utility or the PDF. Both targets disable the Flutter
debug banner. Do not rebuild from an unreviewed URL or adopt an epoch from HTTP.

To reproduce, use the approved external JSON with literal JSON booleans `true`
for `HISTORY_NOTES_ENABLED` and `HISTORY_REVIEW_ENABLED`:

```powershell
flutter build apk --debug --target lib/main.dart --target-platform android-arm,android-arm64,android-x64 --dart-define-from-file=<private-main.json>
flutter build apk --debug --target tool/remote_development_activation.dart --target-platform android-arm,android-arm64,android-x64 --dart-define-from-file=<private-activation.json> --android-project-arg=activationUtility=true
```

If the installed Flutter wrapper does not support passing the custom Gradle
property, invoke `android/gradlew.bat :app:assembleDebug` with
`-PactivationUtility=true`, `-Ptarget=tool/remote_development_activation.dart`,
`-Ptarget-platform=android-arm,android-arm64,android-x64` and the Flutter
base64-encoded `-Pdart-defines` from the same reviewed configuration. Encode
boolean values as lowercase `true`; PowerShell `True` is not the Dart define.
Copy each resulting APK to a distinct stable path immediately after its build.
Verify the actual kernel target, manifest, ABIs and certificate of each copy.

## Hosted History

The strict source-pinned seven-migration inspection passed **57 distinct true
checks** for the existing gate 2 and original epoch. A signed-in existing employee
session supplied by the developer then passed both the exact enriched owner-scoped
HTTP projection and `SupabaseSessionHistoryRepository.load` against hosted data.
The actual response contained one active owned profile, one active employee role,
three owned sessions, one nonempty saved note and nonnull canonical review fields.
A different parent ID was invisible. No token refresh/logout or attendance writes
were used for the HTTP check; the Flutter check used an unexpired initial session
with auto-refresh disabled and disposed the client without sign-out.

Normal composition now passes `config.historyCapabilities`. Default flags remain
false for unreviewed deployments; this beta's reviewed configuration enables both.
Notes/review are read from the canonical session row. Permission/schema/malformed
response/authorization failures remain errors with no weaker query retry. Existing
six-calendar-month pagination, exact timestamps, French formatting, Montréal time,
owner/company/session validation and auth-gated navigation are unchanged.

The optional `test/hosted_beta_history_smoke_test.dart` is read-only and skipped
unless `BETA_PRIVATE_CONFIG` and `BETA_PRIVATE_SESSION` are explicitly supplied as
external file paths. It expects this known three-session developer fixture. Never
put those inputs, tokens or raw employee responses in a review archive.

## Dedicated employee provisioning: prepared, not executed

The user's supplied email is recorded privately. No password was invented, no
invitation/email was sent, no existing identity was reused, and no Auth/profile/
role was created. Account creation still requires the approved initial credential
and the trusted hosted provisioning action. The utility uses the existing normal
password login; an invitation/reset callback flow has not been implemented or
certified for this mobile beta.

1. Independently verify the existing project link, original expected epoch,
   approved company and intended email/display name. Check whether that email
   already exists; stop for review rather than adopting or changing an account.
2. After approval, create the distinct Auth identity using supported Supabase
   Auth administration (`auth.admin.createUser`) from a trusted server/operator
   context. Obtain the initial credential through the agreed private procedure;
   verify the intended owner before marking email confirmed. Never insert directly
   into `auth.users`, expose the admin credential to a phone, or publish a password.
   Do not assume this step delivers a working mobile invitation or credential.
3. In a private copy of
   `supabase/operations/provision_beta_employee.sql`, set these transaction-local
   GUCs immediately after `BEGIN`, using independently reviewed exact values:

   ```sql
   select set_config('chantipoint.beta.expected_epoch','<original-epoch>',true);
   select set_config('chantipoint.beta.auth_user_id','<new-auth-uuid>',true);
   select set_config('chantipoint.beta.company_id','<approved-company-uuid>',true);
   select set_config('chantipoint.beta.email','<approved-email>',true);
   select set_config('chantipoint.beta.display_name','<approved-name>',true);
   ```

   Run the default **ROLLBACK** rehearsal first through the trusted database
   connection. It verifies gate/epoch, confirmed exact Auth identity, active
   company and absence of an existing profile, inserts an active profile and only
   an employee role, then impersonates authenticated claims to probe own-profile
   visibility, no administrator role and no visible foreign/preexisting sessions.
   Missing inputs and existing profiles fail closed. The reviewed source template
   is not a migration and never commits by default.
4. After reviewing the dry run and approving the exact mutation, use the same
   private transaction with COMMIT. Verify it independently. Record the resulting
   full Auth/company/profile binding privately, then test password login and an
   empty personal History under the new employee JWT. Compare the developer's
   known rows/authorization to confirm no cross-employee exposure. These new-user
   hosted checks cannot yet be claimed as completed.
5. Deliver the credential and guide privately through the agreed channel. Do not
   embed credentials/email in the APK, PDF, source, manifest or shared archive.

## Remote enrollment: operator procedure

The new utility reuses the existing signed request/install/read native methods;
it changes neither their signed schema nor their certification policy. The only
native addition is bounded Android Storage Access Framework document IO. It
requires explicit user selection and adds no broad storage permission. Preparing
a request deliberately creates an installation key and retirement marker; it
grants no approval. Import merely stages a maximum-128-byte signature in memory.
Only the separate install action revalidates Auth, employee authorization and
fresh matching gate-2 capability, then asks native code to verify the signed
request and install the exact revision-1 empty checkpoint.

1. Establish and retain **independent certified-clean provenance** for Jamal's
   specific installation. Confirm whether any ChantiPoint/old demo/development
   client already exists or could have pending requests under this account.
   Unknown retained history is a blocker. File absence, an empty server list,
   successful login and a matching inventory digest are not provenance. Do not
   authorize reinstall/reset, a new directory/epoch or a different account to
   bypass evidence. Reconcile/drain any prior client before approval.
2. Independently confirm the actual maintenance record applies to this new
   client and the gate/epoch/key remain approved. The utility's compiled
   `hosted-dev-maintenance-20261025` reference names the retained maintenance
   record; it does not create a new approval. If that record is no longer
   sufficient, stop and obtain/review the needed maintenance approval and rebuild
   the utility with its real reference. Do not fabricate references.
3. Send both verified APKs and the separate French PDF manually. Jamal installs
   **Activation ChantiPoint** first, signs in to his separate employee account,
   chooses **Préparer la demande**, then **Enregistrer la demande**, and privately
   returns the exported JSON. Never send him the operator private key or admin
   credentials. No connected messaging action has been performed by this task.
4. Retain the received **original bytes**, SHA-256 and provenance record privately.
   Strictly inspect the bounded duplicate-free request: exactly the eight fields
   documented in [development-device-authority](development-device-authority.md),
   policy `certified-clean-development-v1`, version 1, normal package ID,
   installation-key identifier, inventory digest, exact approved full binding,
   approval reference and genuine maintenance reference. Independently compare
   the Auth/profile/company to the newly provisioned employee and compare URL,
   epoch and public trust anchor to the reviewed deployment. Map the generated
   approval reference to this actual external review; randomness is not approval.
5. Only after those checks, sign the **unchanged bytes** externally with the
   existing matching P-256 operator key (never reserialize JSON):

   ```powershell
   openssl dgst -sha256 -sign <private-operator.pem> -out <activation.der> <original-request.json>
   openssl dgst -sha256 -verify <matching-public.pem> -signature <activation.der> <original-request.json>
   ```

   Retain key/bytes/signature outside shared artifacts. Return only the small DER
   signature privately; it carries no private key and cannot approve a different
   binding/installation. The operator must refuse unknown provenance even if the
   request would pass native structural checks.
6. Jamal chooses **Choisir le fichier d’activation**, then **Installer
   l’activation**. Native verification must confirm approval. He then installs
   the normal beta as an update, retaining the same package/signature/data. The
   normal app independently verifies native evidence and fresh capability; it
   still requires the existing explicit empty-record verification before a new
   action. Follow the separate PDF for normal pointage and notes.
7. After interruption/lost acknowledgement, retain everything and retry with the
   same account, original request and exact signature. Restarting the utility
   clears staged signature RAM; prepare reloads the exact stored request, then
   choose the original signature again. Native installation is idempotent only
   at its exact approved checkpoint. No reset, rebind or replacement enrollment
   is added. If retained work blocks installation, stop for reviewed recovery.

Jamal's actual device request, provenance review, signature and installation have
not happened. This delivery makes that remote sequence available; it does not
claim an unenrolled Samsung is ready for attendance.

## Validation and preservation

Focused Flutter History/controller/screen and activation tests passed **76
checks**, including exact Unicode/whitespace, absent optional fields, role/owner
errors, backend 403 with one enriched query, existing pagination and auth logout,
cancelled/oversized signature imports, account changes across awaits, concurrent
actions, corrupt/duplicate requests and exact lost-install-ack retries. Completed
and staged activation messages are scoped to their original account/login;
changing accounts or logging in again suppresses stale success text. Another
**73 normal-app integration checks** passed for authorization,
enrollment, lifecycle, note Save and logout. Together with the real hosted
repository smoke test, **150 Flutter checks** passed. Analyzer reports no issues. Universal
and isolated Android builds, manifest/ABI/kernel-target and signing checks pass.

Runtime acceptance and final artifact hashes are recorded in the sanitized review
evidence and delivery manifest. The existing normal developer phone APK and
native approval are preserved; tests use a newly installed
`com.example.chantipoint.enrollmentvalidation` package against the local rehearsal
backend. This package was proven absent before installation. No app data is
cleared. Existing demo data and offline AVDs are retained. The new beta AVD was
created separately but not launched: only about 1.1 GiB of physical RAM was free
after builds. No Samsung
runtime or ARM64 device execution is implied by ABI packaging verification.

| Physical Redmi, isolated local package | Actual acceptance |
| --- | --- |
| Unsigned request / normal app | Login survives the update; personal History works; no approval and no enabled entry action. |
| Android request export | User-selected system document contains the exact original request bytes. |
| Android signature import | Picker cancellation returns without approval. DER selection stages bytes; approval still absent until explicit install. |
| Native installation | Local fixture signature, full binding, independent local epoch and clean provenance pass existing native install/read verification. |
| Update to normal app | Login, installation key and signed approval survive; explicit existing empty-checkpoint verification enables entry. |
| Normal employee cycle | One fictional check-in, explicit receipt consumption, canonical note Save, checkout/preserve and receipt consumption pass. Note Save adds no location observation. |
| Cold History | Four closed owned sessions, exact newly saved note, review status and Montréal formatting appear after process restart. |
| Logout / restart | Isolated account returns to login and remains signed out after restart. Native approval bytes and all data remain. |

The isolated runtime copy uses the same normal/utility source with an allowed
validation package suffix and the existing **local** fixture URL/epoch/public key.
It does not replace the hosted developer installation. The final utility was
rebuilt after the message-ownership polish; the affected 76-check suite passed
again. Native document/signature/authority behavior did not change in that polish.
The local database ends with **4 closed sessions, 0 active, 8 events, 8 location
observations and 7 applied note operations** (one added session, two events/two
observations and one Save). Its four rehearsal services are stopped with all data
retained. The isolated app is stopped, signed out; its data and exported test
documents are retained. The task's local ADB reverse was removed.

The provisioning template also passed a real local transaction with a distinct
synthetic Auth fixture: own profile/employee role visible, no admin role, all four
existing other-employee sessions hidden and new personal History empty. Everything,
including the synthetic Auth/profile/role, rolled back. This SQL fixture does not
claim supported Auth administration or Jamal's actual account creation occurred.

Final hosted authenticated History remains **3 sessions / 1 nonempty note**;
the developer account remains signed in. The normal phone APK hash remains
`c6e9f5e8766a8d364d713500af1096ebf58b83d34432607221c3c2c840ccbf8c`,
and native approval remains
`a690d3e29941b5c563715c0ac81d4f790bdc190abf9edb406535f3bac6db27c4`.
The old demo remains disabled with its data retained. No unrelated service or
existing AVD was started/reset, and no Android application data was removed.

The two-page PDF was rendered and both pages visually inspected. It covers
installation/activation, precise foreground location, entry/exit, note
save/edit/clear, personal History, Montréal time, review status and reporting.

References: [Android document selection](https://developer.android.com/training/data-storage/shared/documents-files),
[Supabase trusted Auth createUser](https://supabase.com/docs/reference/javascript/auth-admin-createuser),
[Samsung installation protections](https://www.samsung.com/us/support/answer/ANS10003636/).

No commit, push or branch mutation is performed. The complete changed/new source
inventory, relative-path ZIP and SHA-256 manifest accompany the review. Confidential
keys, sessions, account email, enrollment requests/signatures and raw logs/UI are
excluded.
