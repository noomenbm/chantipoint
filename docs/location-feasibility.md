# ChantiPoint Location Feasibility Study v0.1

Geofencing is the preferred initial candidate for on-duty location verification, but it is not yet technically validated or contractually approved. This document defines an isolated proof-of-concept plan before any production automatic checkout feature is built.

No real employee monitoring is authorized by this task.

## Primary References

- Android Developers: [Create and monitor geofences](https://developer.android.com/develop/sensors-and-location/location/geofencing)
- Android Developers: [Access location in the background](https://developer.android.com/develop/sensors-and-location/location/background)
- Android Developers: [Background location limits](https://developer.android.com/about/versions/oreo/background-location-limits)
- Google Play Help: [Understanding location in the background permissions](https://support.google.com/googleplay/android-developer/answer/9799150)
- Apple Developer Documentation: [Core Location](https://developer.apple.com/documentation/corelocation)
- Apple Developer Documentation: [Monitoring the user's proximity to geographic regions](https://developer.apple.com/documentation/corelocation/monitoring-the-user-s-proximity-to-geographic-regions)

## Feasibility Stages

### Stage 1: Android Emulator and Simulated GPS Movement

Purpose: Determine whether the development environment and Android APIs can support a controlled geofencing prototype.

Scope:

- Isolated prototype only.
- No production Supabase data.
- No real employee data.
- Simulated GPS movement through the Android emulator.
- Candidate radii of 100m and 150m.
- Simulated 10-minute grace period.
- Simulated automatic checkout candidate, not production closure.

The developer cannot currently perform outdoor field tests personally, so Stage 1 is not sufficient for production validation.

### Stage 2: Planned Real-Device Field Testing

Purpose: Validate behavior on personal-device-like conditions before any employee pilot.

Scope:

- Real Android devices.
- Different OS versions and manufacturer battery restrictions.
- Outdoor and indoor/urban accuracy checks.
- Permission revocation, location disabled, device reboot, app restart, connectivity loss, and background restrictions.

Stage 2 must be planned separately and approved before any real employee monitoring.

### Stage 3: iOS Investigation

Purpose: Preserve a future iOS path.

Scope:

- Core Location and region monitoring constraints.
- Apple permission and background behavior.
- Separate build and real-device testing plan.

iOS is not the first deployment priority.

## Candidate Options

### Option A: Geofence Exit and Re-Entry Events

Description: Register a temporary circular geofence around the check-in coordinate and listen for exit/re-entry events during the active session.

Potential advantages:

- Matches the business problem of detecting departure from the declared workplace area.
- Can reduce battery use compared with frequent GPS polling.
- Android and iOS both provide region/geofence concepts.

Known constraints:

- Android geofencing requires fine location, and background geofencing requires background location permission on modern Android targets.
- Android background delivery can be delayed; official documentation notes background geofence responsiveness can be every couple of minutes.
- Android recommends larger radii for reliable geofencing; official guidance cites 100-150 meters as a best-results minimum in typical cases.
- Device reboot, app reinstall, app data clearing, Google Play services data clearing, or `GEOFENCE_NOT_AVAILABLE` can require re-registration.
- iOS region monitoring can wake the app for region changes, but behavior still depends on authorization, device state, and platform restrictions.
- Indoor or dense urban GPS accuracy may be insufficient for small worksites.

### Option B: Periodic GPS Observations Every 5-10 Minutes

Description: During an active session, request periodic location observations and compare distance from the check-in coordinate.

Potential advantages:

- Produces explicit sampled coordinates and accuracy metadata.
- Easier to reason about than missing geofence events.
- Can be used to confirm or supplement geofence events.

Known constraints:

- Higher battery and privacy impact.
- Background location access may face stronger platform and store scrutiny.
- A 5-10 minute interval cannot prove continuous presence between samples.
- Poor accuracy could create false departures or inconclusive results.
- Requires strict stopping at checkout and a maximum monitoring duration.

### Option C: Hybrid Approach

Description: Use geofence events as the primary signal, with limited periodic observations or foreground checks to confirm uncertain states.

Potential advantages:

- May reduce false positives from one unreliable signal.
- Allows unavailable or delayed monitoring to be recorded explicitly.
- Can defer automatic checkout while still producing administrator-review evidence.

Known constraints:

- More complex state management.
- More privacy review because multiple signal types are collected.
- Still cannot guarantee immediate exit detection.

## Stage 1 Test Matrix

| Test ID | Scenario | Measurement | Pass Criteria | Fail Criteria |
| --- | --- | --- | --- | --- |
| LF-001 | Emulator simulated GPS setup | Repeatability of simulated route | A route can be repeated with documented coordinates. | Simulated movement cannot be made repeatable enough for testing. |
| LF-002 | Geofence registration at 100m | Registration success/failure and error code | 100m geofence registers or produces a clear documented failure. | Registration fails without actionable diagnostics. |
| LF-003 | Geofence registration at 150m | Registration success/failure and error code | 150m geofence registers or produces a clear documented failure. | Registration fails without actionable diagnostics. |
| LF-004 | Simulated exit event | Event timestamp, callback/receipt timestamp, radius, source | Exit callback is received and timestamps are captured separately. | Exit cannot be triggered or timestamps cannot be separated. |
| LF-005 | Simulated return event | Event timestamp, callback/receipt timestamp, radius, source | Return callback is received and timestamps are captured separately. | Return cannot be triggered or timestamps cannot be separated. |
| LF-006 | Delayed event handling | Simulated delay and state transition | Delayed callback is recorded as delayed evidence, not exact physical departure time. | State machine treats delayed callback as exact real-world time without caveat. |
| LF-007 | Simulated 10-minute grace period | Grace start time and expiry basis | Grace period starts from reliable callback/app/backend receipt timestamp. | Grace period is modeled as starting from unknown physical departure time. |
| LF-008 | Return during grace period | Session state after exit/return sequence | Session remains active and exit/return events are retained. | Prototype closes the session despite return within grace. |
| LF-009 | Departure persists past grace period | Automatic checkout candidate behavior | Candidate closure records source, reason, and evidence summary. | Candidate closure lacks evidence or reason. |
| LF-010 | Monitoring disabled or unavailable | Status and reason | Prototype records disabled/unavailable/inconclusive status without false absence assertion. | Prototype silently treats unavailable verification as absence. |
| LF-011 | Permission revoked simulation | Detection timing and status | Reliable detection, if available, records reason; non-detection remains a documented limitation. | Prototype promises immediate detection. |
| LF-012 | Cleanup/unregistering geofences | Post-checkout monitoring state | Geofence is unregistered after simulated checkout and no further events are accepted for the closed session. | Geofence remains active or events continue after closure. |
| LF-013 | Evidence export for review | Test log completeness | Test log includes event type, radius, timestamps, status, and result. | Results cannot support a feasibility decision. |

## Proposed State Machine for the Spike

| State | Entry Condition | Exit Condition |
| --- | --- | --- |
| `monitoring_pending` | Session is active and registration is in progress. | Registration succeeds or fails. |
| `monitoring_enabled` | Geofence or observation strategy is active. | Exit evidence, permission/location loss, service failure, or checkout. |
| `exit_observed_grace` | Exit event or candidate outside observation is received. | Return evidence, grace expiry, or evidence becomes inconclusive. |
| `return_observed` | Return event or credible inside observation is received. | Session returns to monitoring enabled. |
| `auto_checkout_candidate` | Test evidence threshold would be met in the prototype. | Test-only closure simulation or administrator-review simulation. |
| `monitoring_unavailable` | Location disabled, permission revoked, app unable to register, service unavailable, or evidence too poor. | Monitoring becomes available or session closes. |
| `monitoring_stopped` | Manual checkout, simulated automatic closure, or cleanup. | No further location collection. |

## Evidence Principles

- Record device-observed time, callback/app receipt time, server receipt time, and server-accepted time separately where applicable.
- Record accuracy when available.
- Treat delayed geofence events as delayed evidence, not exact departure times.
- Treat missing or unavailable evidence as inconclusive.
- Do not close a session from a single inaccurate GPS point.
- Do not collect data after checkout.
- During the spike, automatic checkout must be simulated or clearly marked test-only.

## Later Real-Device Test Plan

| Test ID | Scenario | Measurement | Draft Pass Criteria |
| --- | --- | --- | --- |
| RF-001 | Foreground check-in location acquisition | Time to fix, accuracy, failure rate | Location can be captured reliably enough for manual check-in on supported Android devices. |
| RF-002 | Android exit event in background | Event delivery latency and accuracy context | Most planned exits produce events within a client-approved operational window; missing events are recorded as failures. |
| RF-003 | Android re-entry event in background | Event delivery latency | Returns are detected often enough to avoid obvious false automatic closures. |
| RF-004 | Location disabled mid-session | App/backend status | Session becomes disabled/unavailable or inconclusive, not silently absent. |
| RF-005 | Permission revoked mid-session | Detection timing | Detection limits are documented and user/admin status is clear. |
| RF-006 | App killed, restarted, or device rebooted | Monitoring recovery behavior | Required re-registration strategy is identified before production. |
| RF-007 | Battery optimization restrictions | Event delivery impact | Known device restrictions and user guidance are documented. |
| RF-008 | Indoor and urban accuracy | Accuracy distribution | Radius recommendations account for observed accuracy. |
| RF-009 | Checkout stops monitoring | Post-checkout observations | No further location events are collected after checkout. |
| RF-010 | Periodic GPS 5-10 minute sample | Battery, accuracy, delivery reliability | Sampling value is compared against privacy and battery cost. |

## Spike Deliverables

- Emulator setup notes and simulated route definitions.
- Results for 100m and 150m geofence registration.
- Exit/return callback logs with separate timestamps.
- Simulated delayed-event behavior.
- Simulated 10-minute grace-period behavior.
- Simulated monitoring disabled/unavailable behavior.
- Simulated automatic checkout candidate log.
- Cleanup/unregistration result.
- Recommendation: geofence, periodic GPS, hybrid, manual review only, or no automatic checkout.
- Real-device field-test plan and constraints.

## Open Risks

- Emulator success does not prove real-device reliability.
- Android and iOS may delay or suppress background events.
- Personal-device settings and battery optimization may differ widely.
- The developer cannot currently perform outdoor field tests personally.
- Store review may reject or delay background location access if justification is insufficient.
- Urban and indoor accuracy may require a radius too large for some worksites.
- Automatic checkout may create unacceptable false positives without administrator review.
- Privacy approval may limit or reject continuous on-duty monitoring.

## Related Documents

- [Requirements](requirements.md)
- [Architecture](architecture.md)
- [Security and Privacy](security-privacy.md)
- [ADR 0002: Location Monitoring](decisions/0002-location-monitoring.md)
