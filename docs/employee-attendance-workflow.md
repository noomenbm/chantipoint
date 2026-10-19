# C5.1/C5.2 isolated employee attendance workflow

This is an injectable, host-tested employee workflow and French screen, not a
production cutover. `AuthGate`, main/application routes, the live factory screen
and legacy controller are unchanged. Hosted v2 is still inactive. No real files,
accounts, attendance RPCs or employee location were used for C5.1.

## Composition and ownership

`EmployeeAttendanceWorkflow` receives the existing `AttendanceActionCapture`,
`AttendanceOperationCoordinator`, an original-context issuer, authorization
notifications and an `AttendanceActiveSessionReader`. There are no production
defaults. The screen owns its workflow/capture; the shared coordinator, storage,
request authority and C3.3 auth owner must outlive the route.

The context issuer can eventually be the application-lifetime C3.3 owner's
`issueContext`. The notification input must cover all authorization-generation
boundaries, including session events, revalidation and logout initiation. Merely
watching UUID equality or assuming every SDK event becomes an AuthController
notification is insufficient. Context currency is rechecked synchronously at
use and after awaits, against the exact generation and five-field binding.
Token refresh within the same authorized generation needs no presentation reset.
Production composition of these inputs is deliberately absent.

The new active-session read port is necessary because C3.2's canonical reader
reads an acknowledged session by ID, including closed sessions; it is not an
active-session discovery API. The injected port must use captured credentials,
owner/environment scope and authorization guards, validate the active selection,
and reject wrong-owner or stale results. No adapter to the legacy repository's
current-account lookup is supplied. Its synchronous original-session observation
and monotonic revision/listenable describe independently known session changes.
Reading alone must not advance the revision; delayed reads cannot supersede newer
observations. This is presentation currency, not a new authorization authority,
proof of server state, background listener or polling implementation.

One workflow operation runs at a time. Buttons and refresh/recovery are disabled
during acquisition, read, dispatch, canonical refresh and context release. A
changed known session invalidates pending presentation without retargeting its
command. The coordinator still performs its own journal gates, including when
the outbox changes after the screen's earlier read. This does not supply global
legacy-writer fencing or cross-process ownership.

Disposal detaches presentation listeners and closes unsubmitted capture. It
does not cancel submitted coordinator work or release its context early. Submitted
work may finish canonical refresh if still authorized, or persist only its late
receipt after invalidation. Neither path publishes to the disposed screen.
`settled` observes the current operation through its normal settlement.

Integration review found one C4 cleanup gap: currency can hide `result.action`
before a caller obtains it, leaving an unsubmitted ready capture owned until
close. `AttendanceCaptureResult.abandon()` now releases that original capture
without exposing stale intent. C5 calls it in finally. It remains a no-op after
handoff, so it cannot release submitted ownership. Two regressions verify cleanup
without an acquired action handle, a fresh subsequent attempt and no early release
after handoff. No native location logic or immutable command contract changed.

## Actions and employee states

- Check-in has one action and an optional description. There is no employee
  factory/external mode selector. C4 freezes the original time, secure key and
  inputs before permission/location awaits; the server classifies attendance.
- Checkout binds the original active session and an explicit preserve/replace/
  clear final-note intent. Replace with empty text remains different from clear
  (null) and preserve. No trimming, timestamp regeneration or key replacement is
  introduced. UTC remains authoritative; display uses the existing configured
  America/Montreal formatter and its IANA/DST offset.
- Only canonical data supplies session classification, times, description,
  review state and saved note. Null and empty saved notes are labelled separately.
  Final-note text is labelled as a draft and is never shown as a saved note.
- Loading, one-shot acquisition, awaiting server confirmation, confirmed,
  pending, blocked, unavailable authorization and recoverable refresh have
  distinct safe French messages. No coordinates, IDs, credentials, raw receipts
  or exception messages are rendered. Location failure does not mean attendance
  failed. Live-region status, progress semantics, disabled actions and a scrolling
  keyboard-friendly phone layout are covered by widget tests.

An RPC return, completed future, readable receipt or storage failure followed by
readable bytes does not confirm attendance. Confirmed presentation requires C3's
durability evidence and canonical session. Durable confirmation with unavailable
canonical details has a separate state, hides session details and blocks actions.

`Actualiser le pointage` reads gates and active canonical state, or requests C3
confirmed refresh; it never submits/replays. `Vérifier le pointage conservé`
uses only C3 replay or explicit confirmed-record recovery. Replay preserves the
original command/key/evidence and uses replay-only lookup; a miss stays unresolved.
Prepared, blocked, legacy, pending-migration, unreadable and ambiguous states never
authorize a fresh attendance command. There is no forced reset or evidence-delete
control. C5.2 adds only the guarded verification step below.

Permission dialogs may trigger unchanged auth-resume revalidation. An invalidated
capture is abandoned. The employee is told to wait for authorization, explicitly
refresh, and choose a fresh action. No automatic recapture or context adoption is
performed. Private form drafts are cleared on authorization invalidation.

## Input-validation review correction

Description and replacement-note limits count Unicode code points, using C4's
shared 500/1,000 limits and exact `journalText` validation, including supported
Unicode and NUL restrictions. Both the field feedback and frozen action input
use this contract. Counters show code points rather than grapheme clusters;
pasted text is never truncated, trimmed or normalized. Decomposed accents can
count for several code points even when rendered as a single character.

Invalid drafts have specific French input feedback and retain the canonical
session and editable draft. Editing clears the submitted error feedback; every
fresh explicit action validates again before context issuance, key generation
or location acquisition. Invalid text cannot dispatch or write a journal command
and owns no new context. A defensive C4 `invalidInput` result is also presented
as an input error, after C4 has released its context, rather than as a refresh or
server failure. Existing auth, session and journal gates still apply. Tests cover
both limits just below/at/above the boundary, unchanged French text, malformed
Unicode, no truncation and correction followed by one successful fresh action.

## C5.2 confirmed-receipt consumption and next work

C5.1 intentionally retained receipts. C5.2 supplies the deferred coordinator
capability. `Terminer la vérification` is available after canonical confirmation.
It calls `consumeConfirmed`: core-owned durable proof freezes before joining the
binding queue, current owner/generation and complete record are checked, and the
exact acknowledged session is freshly read. Guarded CAS then replaces confirmed
with an empty tombstone at revision + 1, followed by complete reread. The screen
supplies no primitive booleans and deletes no files. A queued duplicate cannot
consume a newer command. Submitted work retains ownership through settlement.

An uncertain write may leave confirmation OR empty state; neither rollback nor
cleanup success is inferred. `Actualiser le pointage` determines the stored phase.
Confirmed state with lost proof needs confirmed recovery then explicit consumption.
Unproved empty state offers `Réessayer la vérification sur cet appareil`: exact-byte
file/directory sync, authenticated readback and exact reread via `recoverEmpty`.
A missing/failed verifier or changed record keeps actions gated. Local failed
attempts accept only their exact expected tombstone, never a newer-looking record.
This proves CURRENT empty state, not historical success of the failed attempt.

After proven consumption/recovery, a fresh context in the same captured generation
performs an owner-scoped active SELECT via coordinator `readActive`. The binding
queue and context cover the whole read and journal recheck. No receipt or replay
miss supplies the active/no-active answer. Failed reads and changed known sessions
keep actions disabled. The fictional full cycle reaches revisions 3 (check-in
confirmed), 4 (consumed), 7 (checkout confirmed), 8 (consumed), with two dispatches.

Proof and original failed-attempt receipt retention are volatile and per instance.
A replacement coordinator/app must verify persisted empty state explicitly before
selection/submission. Known disappearance is blocked; after restart, fresh absence
cannot be distinguished from out-of-contract data deletion without a durable
inventory. Key/device/data loss and arbitrary rollback remain outside existing
guarantees. The queue is isolate-local; production fencing/writer retirement and
durable provenance remain prerequisites. No schema or native API changed.

Standalone note saving is deferred. Its next slice must scope the save to the
original authorized owner/generation/session, retain uncertain-save state through
settlement, reconcile a lost response with canonical server data before another
save/checkout can assume its outcome, and suppress stale publication. It stays
outside the attendance outbox. Atomic immutable final checkout notes are supported
now; there is no standalone Save button.

Other pre-cutover gates remain: production active-session adapter and auth/session
notification composition, trusted legacy
provenance/assignment and coordinated writer retirement/fencing, backup/transfer
policy, approved deployment/activation, privacy approval and successful native fix
validation. C4's actual API 37 grant/approximate runs returned timeout without a
fix. C5 widget tests do not close that gap or test live auth-resume composition.

There are no notifications, timers, automatic checkout, background monitoring,
legacy migration, fallback RPCs, new dependencies or Android changes in C5.2.
Android UI/storage testing was not performed for this slice; existing native C4
observations are preserved rather than relabelled as C5 validation.

## Bounded local Git audit

At baseline `fb765edc015bceead730fb90240508a4a5c8721b`, the tree was clean on
`feature/manual-attendance`. Both `git fsck --full --unreachable` (normal reflog
reachability) and `git fsck --full --unreachable --no-reflogs` exited zero and
reported the same **156 unreachable objects: 103 trees and 53 blobs; no commits
or tags**. There were no other fsck diagnostic lines.

All 53 blobs were scanned, 799,613 bytes total, with a 512 KiB per-blob/8 MiB
aggregate bound; nothing was skipped. A heuristic scan for private-key headers,
common secret-key forms, JWTs and password-bearing URLs found no candidates.
Unreachable-tree path checks found no environment/key/timesheet filename matches.
No object contents, secret values or personal data were printed or archived.
This is a bounded heuristic check, not a comprehensive secret audit.

These are unreachable objects in the local object database, outside all locally
known refs and reflogs. No concerning object was found to trace to a pushed ref.
Local remote-tracking refs and fsck do not establish remote contents or historical
pushes; no claim of historical remote absence is made. No fetch, cleanup/prune,
history rewrite, Git mutation or hosted operation was performed.

Validation counts and resource observations are recorded in
[Development Status](development-status.md).
