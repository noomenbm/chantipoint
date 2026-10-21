# Employee session history

The normal signed-in employee home has a read-only **Historique** entry. It shows
owned sessions, including active and closed sessions, newest first, with expandable
details and French loading/empty/error/retry/load-more states. Returning home keeps
the existing attendance controller mounted. History/details are children of the
auth gate, not independent routes that can remain above a logout screen.

## Business calendar and pagination

Opening history captures one instant `untilUtc` from the device clock (injected
in tests); it does not fetch a server clock. In the configured
`America/Montreal` calendar, subtract six calendar months from that local date,
clamp its day to the target month's last day, and use **00:00 local time** for the
inclusive lower bound. Convert that midnight through the installed IANA rules to
`fromUtc`. Query `started_at >= fromUtc AND started_at < untilUtc`.

For example, opening at `2026-10-21T16:00:00Z` (21 October at noon in Montréal)
uses `[2026-04-21T04:00:00Z, 2026-10-21T16:00:00Z)`. Opening on 31 August clamps
the lower calendar date to 28/29 February. The boundary uses the local date, not
the UTC date, a fixed 180-day duration or a fixed offset. Sessions are included by
**entry time**, not by overlap with the period: a session that began earlier is
not included merely because its exit falls in the interval. This is a display
window, not a deletion/retention policy.

The window stays frozen across retries and pages. Each explicit visit from home
starts a fresh window and first page, so returning after attendance activity can
show new sessions or closures. The old controller is disposed and cannot publish
late results. There is no polling or automatic refresh. The server orders embedded sessions by
`started_at DESC, id DESC`, returns at most **21 rows** (20 displayed and one
lookahead), and applies the strict cursor:

```text
started_at < cursor.started_at OR
(started_at = cursor.started_at AND id < cursor.id)
```

The cursor preserves timestamp microseconds and canonical UUID order. The next
cursor is the last displayed row, so tied entry timestamps neither skip nor
duplicate sessions. There is no offset pagination, unbounded SELECT, total-count
query or automatic page drain. Every returned row, including lookahead, must have
the correct owner/company, expected selected fields, valid timestamps/statuses,
window membership and strict cursor order. Invalid pages do not advance the cursor.
Retries reuse the same window/cursor. Concurrent server edits can change values
between pages; this is not a database-wide historical snapshot or note-version
history. A frozen upper bound excludes later ordinary new check-ins.

## Hosted compatibility and authorization

The recorded hosted baseline is the initial migration
`20261013000100_initial_attendance_foundation.sql`. History uses that migration's
profile/role tables, named composite foreign keys and legacy session fields.
**No hosted introspection or hosted runtime test was performed for this slice.**

The source initial migration already defines `review_status`; `employee_note` is
added later locally. This differs from treating both as newly added columns.
Nevertheless, neither optional column is assumed present in hosted composition:
`HistoryCapabilities(notes: false, review: false)` is the explicit conservative
default. Independent capability flags may be enabled in reviewed application
composition only after that deployment's columns/grants have been confirmed.
There is no schema probe, failed-query fallback, `SELECT *`, environment inference
or schema deployment. Tests cover each capability separately and together.

When enabled, fields are read from the canonical work-session row and validated;
an explicit null note means no canonical note, an empty string stays empty, and
missing/invalid fields are errors. When unavailable, the screen says so and does
not manufacture a note or a normal review state. A schema/permission/query error
never becomes empty history or silently retries a weaker projection. Stored
location classification is displayed as recorded; it is not new GPS verification.

Each page is a single GET of the exact authorized `user_profiles` row with embedded
active employee-role evidence and scoped work sessions. Parent and role limits are
two each (unexpected duplicates fail), and session limit is 21. Profile/auth-user/
company/status and employee-role owner/company/status are validated before an
empty child list can mean **Aucune session**. An RLS-hidden/disabled profile or
revoked/missing employee role is an error, including for administrator accounts
whose employee role was removed. Both relation filters and returned-row checks
scope sessions to the employee and company. No admin-wide history path is added.

The repository captures the authorized SDK login; requests and responses check
the original auth-state observation, owning home lifetime and SDK session/login
continuity. Same-login token refresh is allowed; logout initiation, revalidation,
same-user relogin and account changes invalidate the original observation. A later
response cannot populate a new history controller. Disposed/invalidated controller
getters suppress loaded rows; no session/note is written to local files or logs.
Read errors expose only a safe French retry message, never backend exception text.
Previously verified rows remain visible after a load-more error while the same
local authorization observation is valid; auth invalidation removes the subtree.

## Unchanged boundaries and validation

Attendance writes, standalone note Save (still disabled), command journals, v2
gate, SQL, retention and hosted services are unchanged. History performs no RPC,
GPS acquisition, device permission request or background work. All tests use
fictional data and mocked HTTP; see [Development Status](development-status.md)
for exact host results. Android builds/runtime and hosted schema/RLS/PostgREST
integration were not run in this Dart-only slice. Confirm hosted relationships,
grants and optional capabilities with approved development validation before
claiming deployment verification.
