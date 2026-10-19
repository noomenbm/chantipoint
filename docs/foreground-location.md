# C4 foreground location and immutable action capture

This is an isolated implementation, not a live attendance cutover. Main/screens
and the legacy controller still use their original GPS-free factory path.
Hosted Supabase, the deployment gate, journal migration and C3 sequencing are
unchanged. Real employee collection and production release remain unapproved.

## Platform choice

The local cache contains geolocator 14.1.1 and geolocator_android 5.1.1+1. Their
actual source was inspected before implementation. Android `getCurrentPosition`
wraps its platform future in `Future.timeout` and sends cancellation without
awaiting it. The native cancellation reply does not complete the original
position call; fused-client removal also returns a task without awaiting it.
`GeolocatorPlugin.onAttachedToEngine` automatically binds its location service.
These boundaries do not meet this slice's settled-timeout/no-service contract.
No geolocator dependency, fork, cache patch or package upgrade was added.

Instead, a narrow foreground MethodChannel uses the already cached AndroidX
Core 1.17.0 `LocationManagerCompat.getCurrentLocation` single-fix operation and
`android.os.CancellationSignal`. The [AndroidX API contract](https://developer.android.com/reference/androidx/core/location/LocationManagerCompat#getCurrentLocation(android.location.LocationManager,java.lang.String,android.os.CancellationSignal,java.util.concurrent.Executor,androidx.core.util.Consumer%3Candroid.location.Location%3E))
supports a cancellable one-shot request and can return a very recent fix; this
does not manually fall back to a last-known-position lookup. The fix's own time
is preserved for server age/quality evaluation. AndroidX compatibility supports
the project's existing minimum SDK; older Android behavior still needs runtime
validation. The cached Core version is explicitly declared in the app build.

## Acquisition and diagnostics

`ForegroundLocationService` observes services and granted permission, requests
foreground permission only after an ordinary denial, and asks for one fix with
a proposed **15-second** deadline after permission handling. Optional currency
guards are checked between observations, before requesting a fix and after it
settles. The service never classifies attendance or constructs coordinates/time.

`AndroidForegroundLocation` calls the version-1 native channel. There is no Dart
timeout wrapper. Native success, unavailable/error and timeout replies represent
single-fix settlement or successful cancellation; activity pause/detach cancels
the outstanding fix. Timer, native callback and lifecycle share one attempt and
cannot publish duplicate or late fixes. If cancellation throws, the bridge keeps
the attempt busy/unresolved until the one-shot callback settles or lifecycle
cancellation succeeds; it does not report an early settled timeout. Platform/main
thread delays can exceed the proposed deadline. This unusual cleanup-error path
is not a tested hardware guarantee or a reason to start another request.

Only coarse/fine foreground permissions are declared. There is no background
permission, position stream, foreground tracking service, geofence, polling or
automatic checkout. Registering the channel in MainActivity performs no location
request; nothing in live Dart attendance invokes it.

Permission precision comes from the actual Android fine/coarse grants. A denial
with the platform's no-rationale response after an observed denial is reported
as denied-forever for request suppression; no permission history is persisted.
After activity replacement the next explicit request can reestablish that state.
Both denial forms become the existing SQL `denied` diagnostic. Unknown precision
stays unknown, regardless of requested provider or accuracy metres.

Coordinates, horizontal accuracy and fix time come from the returned Location.
Missing accuracy remains null. The provider is the returned provider name when
it is gps/network/fused, otherwise unknown; neither a fused request nor a mock
flag is relabelled as GPS/emulator provenance. All are device claims, not proof.
Finite poor/partial/out-of-range evidence remains available for server evaluation;
non-finite numeric fields become null because JSON cannot represent them.
Denied permission, disabled services, timeout, provider error and unavailable fix
produce diagnostics with absent fix fields. They do not independently prevent an
otherwise authorized action. No raw exception messages or fix contents are logged.

## Action ownership and handoff

`AttendanceActionCapture` requires an original operation context, an injected
clock/key source and acquisition service. System defaults use UTC and 192 bits
from `Random.secure`; there is no insecure key fallback. Each accepted action
captures its time, one key and the original input synchronously before permission
or fix awaits. Checkout captures the original active-session ID and a copy of
preserve/replace/clear note intent. Description/note text is not trimmed or Unicode
normalized. Invalid protocol inputs are rejected before acquisition.

After settlement, the existing v2 request and JournalCommand constructors freeze
the complete original parameters once. Acquisition failures remain evidence; no
retry key, timestamp update, employee-selected mode or replacement session is
invented. Standalone note saves remain outside this API and the attendance outbox.

The exact captured generation and five-field binding must remain current.
Checkout additionally requires a supplied current-session observation against
the captured ID. Future composition must supply the canonical, owner-scoped
active session; matching UUIDs do not establish ownership. Capture establishes
no deployment provenance, backend authorization or global writer fencing.

One capture instance stays busy through acquisition, the ready command and the
submitted attempt. Duplicate taps do not generate keys or acquire another fix;
fresh rejected contexts are released, but an already consumed context is never
released twice. Returned ready results suppress stale access. `handoff()` is
single-use and returns the immutable command plus an original-owner context
wrapper. Only the future coordinator releases that wrapper after all submitted
work, including late receipt finalization. It does not dispatch anything itself.
Abandon/close before handoff releases the original context after acquisition
settles; after handoff they cannot release it early. Close waits for settlement.
A caller-facing timeout does not cancel acquisition or free ownership.
Malformed contexts fail closed; the busy/drain state is cleared even if identity
access and release both fail, without starting acquisition or generating a key.

After a submitted context releases, future UI must still respect canonical and
outbox state before enabling a new action. This is not a replacement for C3's
journal gates or application-lifetime composition. No controller/UI is wired.

The unchanged AuthGate revalidates on resume, and C3.3 invalidates its epoch while
authorization is checking. A system permission dialog can therefore invalidate
a real capture context on resume. C4 correctly abandons that attempt instead of
adopting a new generation. Future UI must resolve permission setup before an
attendance action, or require a fresh authorized explicit action after such an
invalidation. Do not suppress auth revalidation or silently retarget the frozen
intent to avoid it. The isolated native probe uses fictional contexts and does
not establish end-to-end compatibility with the live auth/resume flow.

## Validation and isolated Android probe

Host coverage uses fictional platform responses and clocks/keys. Native runtime
observations, build results and remaining limits are recorded in Development
Status; host mocks alone do not prove Android cancellation or permission behavior.
The final C4 app/test APKs were reinstalled after the last host cleanup fix, and
all four isolated API 37 emulator scenarios passed again. Grant and approximate
acquisition returned timeout with no fix; successful native fix mapping remains
unvalidated. The rerun required no source change or rebuild.

The opt-in `locationValidation=true` build uses only application ID
`com.example.chantipoint.locationvalidation` and the framework runner
`com.example.chantipoint.location.ForegroundLocationInstrumentation`.
It is mutually exclusive with journalValidation. The Dart target is
`test/device/foreground_location_probe.dart`; its test channel simulates one
explicit action in a foreground Activity. It creates no Supabase client, journal
or RPC. Native UI automation is confined to androidTest and checks actual system
permission dialogs. Report only safe diagnostics and presence of a fix, not the
coordinates, timestamp, key or note. Emulator coordinates must be fictional.

From android/, after host tests, build sequentially with the existing caches:

```powershell
$env:JAVA_HOME = 'C:/Program Files/Android/Android Studio/jbr'
.\gradlew.bat :app:assembleDebug --offline --no-daemon --max-workers=1 '-Ptarget=lib/main.dart' '-Ptarget-platform=android-x64'
.\gradlew.bat :app:assembleDebug :app:assembleDebugAndroidTest --offline --no-daemon --max-workers=1 '-PlocationValidation=true' '-Ptarget=test/device/foreground_location_probe.dart' '-Ptarget-platform=android-x64'
```

Install only the isolated app/test APKs for runtime checks. The runner accepts
`-e scenario allow`, `deny`, `approximate`, or `services_off`. Prepare permissions
and service state only for that isolated emulator app. Restore services afterward
and stop the emulator. The allow/deny scenarios require an observed system-dialog
click; an existing grant must not be mistaken for testing the prompt. A real
emulator timeout/unavailable outcome is reported as such, never fabricated into
a fix. There is no physical-device/real employee approval from these checks.

Use existing one-worker/1 GiB Gradle limits. Keep host tests, builds and emulator
sequential; C4 restores the **5 GiB C: stop rule** (proactive 5.5 GiB startup stop).
Do not delete unrelated data, change pagefiles, download SDKs or start Docker.
