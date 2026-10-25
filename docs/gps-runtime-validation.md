# Foreground location runtime validation

On 2026-10-25, the isolated location-validation package obtained a real physical
phone fix through the unchanged production foreground channel. The dedicated
emulator timed out without a supplied location, then returned a fix after one
explicit fictional location delivery. A timeout is not a successful fix test.

Baseline: branch `feature/attendance-live-integration`, HEAD
`3060a85c8765d2787121fc5fddf7c468edeebac8`; working tree initially clean.
The [normal-app rehearsal](normal-app-attendance-rehearsal.md) remains historical
evidence of four timeout captures; none of its attendance records were changed.

## Runtime results

All acquisitions used the existing 15-second, single-foreground-attempt model.
The strict `acquire` scenario requires a returned fix with finite, in-range
coordinates and an observation time. It reports only safe status, fix presence,
accuracy availability, provider category and elapsed time. Elapsed time includes
service/permission handling and is not a satellite acquisition measurement.

| Device / explicit test | Result | Safe observations |
| --- | --- | --- |
| Dedicated `ChantiPoint_E2E_20261025`, no injection, legacy `allow` | Timeout; harness FAIL | Precise permission; fused/gps/passive enabled; no fix; native signal cancelled and ownership idle. An existing grant meant no permission-dialog click, so the legacy prompt requirement also failed. |
| Same emulator, no injection, strict `acquire` | Timeout; strict FAIL | Services enabled, precise permission; no fix after 15,079 ms; native signal cancelled and ownership idle. |
| Same emulator, one fictional simulated delivery, strict `acquire` | Fix; PASS | Services enabled, precise permission; returned provider fused, accuracy available, 286 ms; native ownership idle. The fast attempt's signal was not observed by the polling harness. |
| Physical Android 13 / API 33, ARM 32-bit, strict `acquire` | Real positioning fix; PASS | Services enabled, precise permission; fused/gps/network/passive enabled; returned provider fused, accuracy available, 4,545 ms; native ownership idle. The observed signal was not cancelled because the one-shot callback completed. |
| Physical phone, separate confirmation invocation | Harness unavailable at first-frame stage | Acquisition was not reached; this is not a location timeout. A later read-only power-state check found the phone asleep; the exact first-frame failure cause was not established. |

The developer manually handled the phone's permission controls. The harness did
not click them. Actual coordinates, accuracy values, fix timestamps, device
identifiers, account data and raw phone logs are absent from the review evidence.
The returned fused provider does not prove a satellite-only GPS solution.
The initial three evidence files have a null instrumentation exit code because
the external collector did not account for CRLF when parsing that line; their
app-authored diagnostics remain intact. The collector was corrected before the
simulated emulator test (code -1 / PASS) and phone confirmation (code 0 / harness
unavailable). No raw phone output was saved to recover the earlier code.

## Diagnosis and limits

Precise permission and enabled services alone did not supply an emulator fix.
Explicit simulated delivery made the same production channel succeed, and a
physical phone succeeded without simulation. This supports missing emulator
location delivery as the cause of this run's baseline timeout. It does not
establish exactly why the earlier attendance rehearsal's simulated delivery
failed. No general foreground acquisition defect was reproduced.

The production native bridge selects the first enabled provider from
fused/gps/network for precise permission and fused/network otherwise. It invokes
AndroidX `LocationManagerCompat.getCurrentLocation` with a cancellation signal.
Its timeout cancels that signal before releasing attempt ownership; a completed
one-shot callback settles without needing cancellation. Runtime observation
confirmed cancellation plus idle ownership on timeout and idle ownership on
success. This observes the bridge's signal/ownership boundary, not every internal
OS provider operation. Lifecycle interruption was not newly exercised here.

The AndroidX current-location API can return a very recent fix. The fictional
delivery was sent during the instrumentation invocation, without synchronizing
to the native request; its 286 ms result is delivery/mapping evidence, not a
fresh sensor measurement or a freshness-policy test. No manual last-known lookup,
retry, tracking stream or longer deadline was introduced.

## Changes and validation

Production Dart, Kotlin, provider selection and build configuration are unchanged.
Two existing test harnesses were extended:

- `test/device/foreground_location_probe.dart`: location-only strict `acquire`,
  with no attendance context, key, persistence, authentication or backend calls.
- `ForegroundLocationInstrumentation.kt`: accept that scenario without permission
  automation; report whitelisted enabled providers and test-only observation of
  native idle/cancellation state. Reflection reads ownership/signal fields only.

Focused Flutter coverage passed **97 tests**:

```powershell
flutter test --no-pub --concurrency=1 test/foreground_location_test.dart test/android_foreground_location_test.dart test/attendance_action_capture_test.dart
flutter analyze --no-pub
```

Analysis reported no issues. The existing isolated app/test build passed offline
with the ARM and x64 targets:

```powershell
# From android/, with Android Studio's JBR as JAVA_HOME:
.\gradlew.bat :app:assembleDebug :app:assembleDebugAndroidTest --offline --no-daemon --max-workers=1 '-PlocationValidation=true' '-Ptarget=test/device/foreground_location_probe.dart' '-Ptarget-platform=android-arm,android-x64'
```

APK inspection confirmed application ID
`com.example.chantipoint.locationvalidation`, its matching instrumentation target,
minimum API 24 and an `armeabi-v7a` library for the physical API 33 device.
Only those isolated app/test packages were installed. No normal app reinstall,
reset, data deletion, attendance/enrollment operation, Supabase call or database
change was performed. No hosted resources were used.
Read-only before/after hashes of version code and installation/update timestamps
matched for both pre-existing normal and demo phone packages. This is metadata
confirmation, not a byte-for-byte audit of private app data. Location services
remained enabled. The isolated test packages and all existing app data were
retained. The dedicated emulator was stopped after testing.

## Next step and review

For future emulator fix tests, explicitly supply a fictional location to the
verified dedicated AVD before or during the attempt, then require `acquire` to
report `has_fix=true`. Keep an independent no-fix timeout case. A mock emulator
fix remains simulated evidence; use supervised physical foreground testing for
real-device coverage. There is no production GPS correction to apply from this
run, and this isolated probe does not replace a future authorized normal-app
test with a successful fix.

Coordinate-free runtime evidence, validation logs, all changed repository files,
a SHA-256 manifest and a separate ZIP hash are delivered under
`E:\ChantiPointReviews\gps-runtime-20261025`. Private device mapping, APKs and
emulator logs are excluded from the ZIP. No Git commit, push or branch change
was made.
